#!/bin/bash
set -e

# =============================================================================
# check_ecn_survival.sh  (v2 -- captura via nsenter desde el host)
#
# Verifica si las marcas ECN (ECT(1) puesto por Prague, CE puesto por
# dualpi2 en oaitun_ue1) sobreviven el trayecto a traves de la pila
# PDCP/RLC/MAC de OAI hasta llegar al UPF.
#
# NOTA v2: oaitun_ue1 es una interfaz TUN creada DENTRO del namespace de
# red del contenedor de la UE por el propio softmodem -- no es una
# interfaz veth visible desde el host, y el contenedor tiene capacidades
# restringidas que impiden instalar tcpdump dentro (apt falla por
# setgroups/seteuid). La solucion es usar nsenter para entrar en el
# namespace de red del contenedor desde el host, y capturar alli con el
# tcpdump DEL HOST -- sin necesidad de instalar nada dentro de los
# contenedores.
#
# Captura pcap SIMULTANEAMENTE en:
#   - oaitun_ue1 (namespace de la UE)   -- justo tras el marcado de dualpi2
#   - eth0 (namespace del UPF)          -- tras pasar por toda la pila de radio
#
# Requiere sudo (nsenter necesita privilegios de root para entrar en el
# namespace de red de otro proceso).
#
# Uso:
#   ./check_ecn_survival.sh [duracion_segundos]
# =============================================================================

DURATION="${1:-30}"

UE_CONTAINER="oai-nr-ue-basic"
UPF_CONTAINER="oai-upf"
EXTDN_CONTAINER="oai-ext-dn"
EXT_DN_IP="192.168.70.135"
UPLINK_PORT="5001"
RATE_MBIT="2"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTDIR=~/resultados_5g_l4s/ecn_survival_check_${TIMESTAMP}
mkdir -p "$OUTDIR"

echo "=================================================="
echo " Verificacion de supervivencia de marcas ECN/CE"
echo " Captura en: oaitun_ue1 (UE) y eth0 (UPF), via nsenter desde el host"
echo " Duracion:   ${DURATION}s"
echo " Salida en:  $OUTDIR"
echo "=================================================="

if ! command -v tcpdump > /dev/null 2>&1; then
    echo "ERROR: este script necesita tcpdump instalado en el HOST (no en los"
    echo "contenedores). Instalalo con: sudo apt install -y tcpdump"
    exit 1
fi

echo "Solicitando privilegios de sudo (necesarios para nsenter)..."
sudo -v

UE_TUNNEL_IP=$(docker exec "$UE_CONTAINER" ip -4 addr show oaitun_ue1 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "")
if [ -z "$UE_TUNNEL_IP" ]; then
    echo "ERROR: no se pudo detectar la IP de oaitun_ue1. ¿Esta la UE registrada?"
    exit 1
fi
echo "IP del UE detectada: $UE_TUNNEL_IP"

UE_PID=$(docker inspect --format '{{.State.Pid}}' "$UE_CONTAINER")
UPF_PID=$(docker inspect --format '{{.State.Pid}}' "$UPF_CONTAINER")
echo "PID del contenedor UE:  $UE_PID"
echo "PID del contenedor UPF: $UPF_PID"

if [ "$UE_PID" = "0" ] || [ "$UPF_PID" = "0" ]; then
    echo "ERROR: no se pudo obtener el PID de alguno de los contenedores."
    echo "¿Estan corriendo? docker ps"
    exit 1
fi

clean_point_if_needed() {
    local container="$1"
    local iface="$2"
    local q
    q=$(docker exec "$container" tc qdisc show dev "$iface" 2>/dev/null | head -1)
    if echo "$q" | grep -q "qdisc htb"; then
        echo "Limpiando AQM residual en $container:$iface..."
        docker exec "$container" tc qdisc del dev "$iface" root
    fi
}
clean_point_if_needed "$UPF_CONTAINER" "eth0"
clean_point_if_needed "$UPF_CONTAINER" "tun0"

CURRENT_QDISC=$(docker exec "$UE_CONTAINER" tc qdisc show dev oaitun_ue1 | head -1)
if ! echo "$CURRENT_QDISC" | grep -q "qdisc htb"; then
    echo "Aplicando HTB (${RATE_MBIT}mbit) + dualpi2 en oaitun_ue1 de la UE..."
    docker exec "$UE_CONTAINER" tc qdisc add dev oaitun_ue1 root handle 1: htb default 1
    docker exec "$UE_CONTAINER" tc class add dev oaitun_ue1 parent 1: classid 1:1 htb rate "${RATE_MBIT}mbit" ceil "${RATE_MBIT}mbit"
    docker exec "$UE_CONTAINER" tc qdisc add dev oaitun_ue1 parent 1:1 handle 10: dualpi2
else
    echo "AQM ya presente en oaitun_ue1, se reutiliza."
fi

if ! docker exec "$EXTDN_CONTAINER" pgrep -f "iperf -s -p $UPLINK_PORT" > /dev/null 2>&1; then
    docker exec -d "$EXTDN_CONTAINER" iperf -s -p "$UPLINK_PORT"
    sleep 1
fi

UE_PCAP="$OUTDIR/ue_oaitun_capture.pcap"
UPF_PCAP="$OUTDIR/upf_eth0_capture.pcap"

echo "Iniciando captura pcap en oaitun_ue1 (namespace de la UE)..."
sudo nsenter -t "$UE_PID" -n tcpdump -i oaitun_ue1 -w "$UE_PCAP" host "$EXT_DN_IP" > /dev/null 2>&1 &
UE_TCPDUMP_PID=$!

echo "Iniciando captura pcap en eth0 (namespace del UPF)..."
sudo nsenter -t "$UPF_PID" -n tcpdump -i eth0 -w "$UPF_PCAP" host "$EXT_DN_IP" > /dev/null 2>&1 &
UPF_TCPDUMP_PID=$!

sleep 2

echo "Lanzando iperf UPLINK con TCP Prague durante ${DURATION}s..."
docker exec "$UE_CONTAINER" iperf -c "$EXT_DN_IP" -p "$UPLINK_PORT" -B "$UE_TUNNEL_IP" --tcp-cca prague -i 1 -t "$DURATION" > "$OUTDIR/iperf_output.txt" 2>&1 &
IPERF_PID=$!

wait "$IPERF_PID" 2>/dev/null || true
sleep 3

echo "Deteniendo capturas..."
sudo kill "$UE_TCPDUMP_PID" 2>/dev/null || true
sudo kill "$UPF_TCPDUMP_PID" 2>/dev/null || true
sleep 1
sudo chmod 644 "$UE_PCAP" "$UPF_PCAP" 2>/dev/null || true

echo ""
echo "=================================================="
echo " ANALISIS DE MARCAS ECN"
echo "=================================================="

if command -v tshark > /dev/null 2>&1; then
    for f in "$UE_PCAP" "$UPF_PCAP"; do
        if [ -f "$f" ]; then
            echo ""
            echo "--- $(basename "$f") ---"
            echo "Distribucion de codepoints ECN (0=Not-ECT, 1=ECT(1)/L4S, 2=ECT(0), 3=CE):"
            tshark -r "$f" -T fields -e ip.dsfield.ecn 2>/dev/null | sort | uniq -c
        else
            echo "AVISO: no se genero el fichero $f"
        fi
    done
else
    echo "tshark no esta instalado. Instala con: sudo apt install -y tshark"
    echo "Pcaps guardados en:"
    echo "  $UE_PCAP"
    echo "  $UPF_PCAP"
    echo "Filtro util en Wireshark: ip.dsfield.ecn == 1 (ECT-1/L4S) o == 3 (CE)"
fi

echo ""
echo "=================================================="
echo " Resultados guardados en: $OUTDIR"
echo "=================================================="
ls -lh "$OUTDIR"

