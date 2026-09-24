#!/bin/bash
set -e

# =============================================================================
# run_l4s_comparison.sh  (v3)
#
# Ejecuta una prueba de trafico (uplink o downlink) con TCP Prague o Cubic,
# aplicando HTB+dualpi2 en un punto de la red configurable:
#
#   PUNTOS DE AQM DISPONIBLES:
#   - upf-eth0   : UPF, interfaz hacia ext-dn (N6). Egress real de uplink.
#   - upf-tun0   : UPF, interfaz hacia el gNB (N3). Egress real de downlink.
#   - ue-oaitun  : la propia UE, en su interfaz de salida (oaitun_ue1).
#                  Solo tiene sentido para UPLINK: aqui la cola se forma
#                  en el origen, ANTES de que el paquete pase por el
#                  scheduler del gNB -- mas fiel a donde se forma realmente
#                  la congestion de subida en una red 5G real (la UE debe
#                  esperar su turno de transmision / grant del scheduler).
#
# Motivacion (discusion con el tutor): el UPF recibe el trafico de uplink
# DESPUES de todo el proceso de acceso al medio (peticion de recursos,
# concesion del scheduler, transmision radio). Si el AQM esta en el UPF,
# la senal de congestion (marcado CE) se genera y viaja de vuelta mas
# tarde que si se marcara justo en el origen (la UE). Este script permite
# comparar empiricamente ambos puntos.
#
# Un qdisc "root" en Linux solo controla el trafico de SALIDA (egress) de
# la interfaz donde se aplica -- por eso hay que elegir con cuidado tanto
# la interfaz como el contenedor (UPF o UE) segun lo que se quiera medir.
#
# Antes de cada prueba, el script limpia el AQM de TODOS los demas puntos
# conocidos, para garantizar que la prueba este aislada a un unico punto
# y no se produzca un doble cuello de botella en cascada.
#
# Captura ademas ss -tiom (RTT real, delivered_ce) y el output de iperf
# (throughput), organizado en una carpeta de resultados con resumen
# automatico al final.
#
# Uso:
#   ./run_l4s_comparison.sh <direccion> <cca> [duracion] [rate_mbit] [tag] [punto_aqm]
#
#   direccion:  uplink | downlink
#   cca:        prague | cubic
#   rate_mbit:  limite HTB en Mbit/s (por defecto 2)
#   punto_aqm:  upf-eth0 | upf-tun0 | ue-oaitun
#               (opcional; si se omite, se elige automaticamente:
#                upf-eth0 para uplink, upf-tun0 para downlink)
#
# Ejemplos:
#   ./run_l4s_comparison.sh uplink   prague 60                       # AQM en upf-eth0 (automatico)
#   ./run_l4s_comparison.sh uplink   prague 60 2 "" ue-oaitun        # AQM en la propia UE
#   ./run_l4s_comparison.sh uplink   cubic  60 2 "" ue-oaitun
#   ./run_l4s_comparison.sh downlink prague 60                       # AQM en upf-tun0 (automatico)
# =============================================================================

DIRECTION="$1"
CCA="$2"
DURATION="${3:-60}"
RATE_MBIT="${4:-2}"
EXTRA_TAG="${5:-}"
AQM_POINT="${6:-}"

if [[ "$DIRECTION" != "uplink" && "$DIRECTION" != "downlink" ]]; then
    echo "ERROR: direccion debe ser 'uplink' o 'downlink'"
    exit 1
fi

if [[ "$CCA" != "prague" && "$CCA" != "cubic" ]]; then
    echo "ERROR: cca debe ser 'prague' o 'cubic'"
    exit 1
fi

UE_CONTAINER="oai-nr-ue-basic"
UPF_CONTAINER="oai-upf"
EXTDN_CONTAINER="oai-ext-dn"
EXT_DN_IP="192.168.70.135"
UPLINK_PORT="5001"
DOWNLINK_PORT="5002"

if [[ -z "$AQM_POINT" ]]; then
    if [[ "$DIRECTION" == "uplink" ]]; then
        AQM_POINT="upf-eth0"
    else
        AQM_POINT="upf-tun0"
    fi
fi

case "$AQM_POINT" in
    upf-eth0)
        AQM_CONTAINER="$UPF_CONTAINER"
        AQM_IFACE="eth0"
        ;;
    upf-tun0)
        AQM_CONTAINER="$UPF_CONTAINER"
        AQM_IFACE="tun0"
        ;;
    ue-oaitun)
        AQM_CONTAINER="$UE_CONTAINER"
        AQM_IFACE="oaitun_ue1"
        if [[ "$DIRECTION" != "uplink" ]]; then
            echo "AVISO: 'ue-oaitun' controla el trafico que la UE ENVIA (uplink)."
            echo "       Para downlink no deberia tener efecto real sobre los datos"
            echo "       recibidos. Se continua porque se pidio explicitamente."
        fi
        ;;
    *)
        echo "ERROR: punto_aqm debe ser 'upf-eth0', 'upf-tun0' o 'ue-oaitun'"
        exit 1
        ;;
esac

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SCENARIO_NAME="${DIRECTION}_${CCA}_aqm-${AQM_POINT}${EXTRA_TAG:+_$EXTRA_TAG}"
OUTDIR=~/resultados_5g_l4s/${SCENARIO_NAME}_${TIMESTAMP}
mkdir -p "$OUTDIR"

echo "=================================================="
echo " Direccion:      $DIRECTION"
echo " CCA:            $CCA"
echo " Duracion:       ${DURATION}s"
echo " Punto AQM:      $AQM_POINT  (contenedor=$AQM_CONTAINER, iface=$AQM_IFACE)"
echo " Rate HTB:       ${RATE_MBIT}mbit"
echo " Salida en:      $OUTDIR"
echo "=================================================="

UE_TUNNEL_IP=$(docker exec "$UE_CONTAINER" ip -4 addr show oaitun_ue1 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "")
if [ -z "$UE_TUNNEL_IP" ]; then
    echo "ERROR: no se pudo detectar la IP de oaitun_ue1. ¿Esta la UE registrada?"
    exit 1
fi
echo "IP del UE detectada: $UE_TUNNEL_IP"

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

echo "Aislando el punto de AQM (limpiando los demas puntos conocidos)..."
if [[ "$AQM_POINT" != "upf-eth0" ]]; then clean_point_if_needed "$UPF_CONTAINER" "eth0"; fi
if [[ "$AQM_POINT" != "upf-tun0" ]]; then clean_point_if_needed "$UPF_CONTAINER" "tun0"; fi
if [[ "$AQM_POINT" != "ue-oaitun" ]]; then clean_point_if_needed "$UE_CONTAINER" "oaitun_ue1"; fi

CURRENT_QDISC=$(docker exec "$AQM_CONTAINER" tc qdisc show dev "$AQM_IFACE" | head -1)
if echo "$CURRENT_QDISC" | grep -q "qdisc htb"; then
    echo "AQM ya aplicado en $AQM_POINT, se reutiliza tal cual:"
    echo "  $CURRENT_QDISC"
else
    echo "Aplicando HTB (${RATE_MBIT}mbit) + dualpi2 en $AQM_POINT..."
    docker exec "$AQM_CONTAINER" tc qdisc add dev "$AQM_IFACE" root handle 1: htb default 1
    docker exec "$AQM_CONTAINER" tc class add dev "$AQM_IFACE" parent 1: classid 1:1 htb rate "${RATE_MBIT}mbit" ceil "${RATE_MBIT}mbit"
    docker exec "$AQM_CONTAINER" tc qdisc add dev "$AQM_IFACE" parent 1:1 handle 10: dualpi2
fi

{
    echo "=== upf-eth0 (egress uplink hacia ext-dn / N6) ==="
    docker exec "$UPF_CONTAINER" tc qdisc show dev eth0
    docker exec "$UPF_CONTAINER" tc class show dev eth0
    echo ""
    echo "=== upf-tun0 (egress downlink hacia gNB / N3) ==="
    docker exec "$UPF_CONTAINER" tc qdisc show dev tun0
    docker exec "$UPF_CONTAINER" tc class show dev tun0
    echo ""
    echo "=== ue-oaitun (egress de la propia UE) ==="
    docker exec "$UE_CONTAINER" tc qdisc show dev oaitun_ue1
    docker exec "$UE_CONTAINER" tc class show dev oaitun_ue1
} > "$OUTDIR/qdisc_antes.txt"

if [[ "$CCA" == "prague" ]]; then
    CCA_FLAG="--tcp-cca prague"
else
    CCA_FLAG="--tcp-cca cubic"
fi

# -----------------------------------------------------------------------
# Control de tcp_ecn en el contenedor EMISOR de esta prueba.
#
# tcp_ecn=3 permite negociar ECN en TODAS las conexiones salientes,
# necesario para que Prague/AccECN funcione. Pero si se deja fijo a 3
# tambien para Cubic, Cubic pasa a usar ECN "clasico" (RFC 3168): trata
# CUALQUIER numero de marcas CE en una ventana igual que UNA perdida de
# paquete (reduccion multiplicativa unica), muy distinto de como Prague
# reacciona a las marcas (de forma proporcional y gradual). Esto cambia
# el comportamiento de Cubic respecto al "Cubic clasico puro" (solo
# reacciona a perdidas reales) que se uso como baseline original.
#
# Para mantener la comparacion correcta:
#   - prague -> tcp_ecn=3 en el emisor (necesario para negociar AccECN)
#   - cubic  -> tcp_ecn=2 en el emisor (valor por defecto: no ofrece ECN
#               en conexiones salientes, Cubic reacciona solo a perdidas
#               reales, igual que el baseline original)
# -----------------------------------------------------------------------
if [[ "$DIRECTION" == "uplink" ]]; then
    ECN_CONTAINER="$UE_CONTAINER"
else
    ECN_CONTAINER="$EXTDN_CONTAINER"
fi

if [[ "$CCA" == "prague" ]]; then
    TCP_ECN_VALUE=3
else
    TCP_ECN_VALUE=2
fi

CURRENT_ECN=$(docker exec "$ECN_CONTAINER" sysctl -n net.ipv4.tcp_ecn 2>/dev/null || echo "")
if [[ "$CURRENT_ECN" != "$TCP_ECN_VALUE" ]]; then
    echo "Ajustando tcp_ecn=$TCP_ECN_VALUE en $ECN_CONTAINER (emisor de esta prueba, CCA=$CCA)..."
    docker exec "$ECN_CONTAINER" sysctl -w net.ipv4.tcp_ecn="$TCP_ECN_VALUE" > /dev/null 2>&1 || \
        echo "  AVISO: no se pudo cambiar tcp_ecn en caliente (sistema de solo lectura)."
    NEW_ECN=$(docker exec "$ECN_CONTAINER" sysctl -n net.ipv4.tcp_ecn 2>/dev/null || echo "")
    if [[ "$NEW_ECN" != "$TCP_ECN_VALUE" ]]; then
        echo "  ERROR: tcp_ecn sigue en $NEW_ECN, no en $TCP_ECN_VALUE."
        echo "  Añade 'sysctls: [net.ipv4.tcp_ecn=$TCP_ECN_VALUE]' al servicio $ECN_CONTAINER"
        echo "  en el compose y recrea el contenedor (--force-recreate) antes de repetir."
        exit 1
    fi
else
    echo "tcp_ecn ya está en $TCP_ECN_VALUE en $ECN_CONTAINER, correcto para CCA=$CCA."
fi

wait_for_listening_port() {
    local container="$1"
    local port="$2"
    local max_attempts=15
    local attempt=1
    while [ "$attempt" -le "$max_attempts" ]; do
        if docker exec "$container" ss -ltn 2>/dev/null | grep -q ":${port} "; then
            echo "  Puerto $port en escucha dentro de $container (intento $attempt)"
            return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
    done
    echo "  AVISO: puerto $port no parece estar en escucha en $container tras ${max_attempts}s"
    return 1
}

if [[ "$DIRECTION" == "uplink" ]]; then
    if ! docker exec "$EXTDN_CONTAINER" pgrep -f "iperf -s -p $UPLINK_PORT" > /dev/null 2>&1; then
        docker exec -d "$EXTDN_CONTAINER" iperf -s -p "$UPLINK_PORT"
    fi
    echo "Esperando a que el servidor iperf este listo en $EXTDN_CONTAINER..."
    wait_for_listening_port "$EXTDN_CONTAINER" "$UPLINK_PORT"
    echo "Lanzando iperf UPLINK (UE -> ext-dn), CCA=$CCA, AQM en $AQM_POINT..."
    docker exec "$UE_CONTAINER" iperf -c "$EXT_DN_IP" -p "$UPLINK_PORT" -B "$UE_TUNNEL_IP" $CCA_FLAG -i 1 -t "$DURATION" > "$OUTDIR/iperf_output.txt" 2>&1 &
    IPERF_PID=$!
    SS_CONTAINER="$UE_CONTAINER"
    SS_FILTER="dst $EXT_DN_IP"
else
    if ! docker exec "$UE_CONTAINER" pgrep -f "iperf -s -p $DOWNLINK_PORT" > /dev/null 2>&1; then
        docker exec -d "$UE_CONTAINER" iperf -s -p "$DOWNLINK_PORT" -B "$UE_TUNNEL_IP"
    fi
    echo "Esperando a que el servidor iperf este listo en $UE_CONTAINER..."
    wait_for_listening_port "$UE_CONTAINER" "$DOWNLINK_PORT"
    echo "Lanzando iperf DOWNLINK (ext-dn -> UE), CCA=$CCA, AQM en $AQM_POINT..."
    docker exec "$EXTDN_CONTAINER" iperf -c "$UE_TUNNEL_IP" -p "$DOWNLINK_PORT" $CCA_FLAG -i 1 -t "$DURATION" > "$OUTDIR/iperf_output.txt" 2>&1 &
    IPERF_PID=$!
    SS_CONTAINER="$EXTDN_CONTAINER"
    SS_FILTER="dst $UE_TUNNEL_IP"
fi

echo "Capturando ss -tiom durante ${DURATION}s (con timestamp real por muestra)..."
> "$OUTDIR/ss_stats.txt"
START_TS=$(date +%s.%N)
END_TS=$(python3 -c "print($START_TS + $DURATION)")
SAMPLE_NUM=0
while true; do
    NOW_TS=$(date +%s.%N)
    REACHED_END=$(python3 -c "print(1 if $NOW_TS >= $END_TS else 0)")
    if [ "$REACHED_END" = "1" ]; then
        break
    fi
    SAMPLE_NUM=$((SAMPLE_NUM + 1))
    ELAPSED=$(python3 -c "print(f'{$NOW_TS - $START_TS:.2f}')")
    {
        echo "=== muestra=${SAMPLE_NUM} t_real=${ELAPSED}s ==="
        docker exec "$SS_CONTAINER" ss -tiom $SS_FILTER
    } >> "$OUTDIR/ss_stats.txt"
    sleep 1
done
echo "Capturadas $SAMPLE_NUM muestras en $(python3 -c "print(f'{$(date +%s.%N) - $START_TS:.1f}')")s reales"

wait "$IPERF_PID" 2>/dev/null || true
sleep 2

{
    echo "=== upf-eth0 ==="
    docker exec "$UPF_CONTAINER" tc -s qdisc show dev eth0
    echo ""
    echo "=== upf-tun0 ==="
    docker exec "$UPF_CONTAINER" tc -s qdisc show dev tun0
    echo ""
    echo "=== ue-oaitun ==="
    docker exec "$UE_CONTAINER" tc -s qdisc show dev oaitun_ue1
} > "$OUTDIR/qdisc_despues.txt"

cat > "$OUTDIR/metadata.txt" << EOF
Escenario:        $SCENARIO_NAME
Direccion:        $DIRECTION
CCA:              $CCA
Punto AQM:        $AQM_POINT
Contenedor AQM:   $AQM_CONTAINER
Interfaz AQM:     $AQM_IFACE
Rate HTB:         ${RATE_MBIT}mbit
RTT medido en:    $SS_CONTAINER (lado emisor real del trafico en este sentido)
Fecha/hora:       $(date)
Duracion:         ${DURATION}s
UE IP (tunel):    $UE_TUNNEL_IP
Destino ext-dn:   $EXT_DN_IP
EOF

python3 - "$OUTDIR/ss_stats.txt" > "$OUTDIR/resumen.txt" << 'PYEOF'
import re
import sys
import statistics

path = sys.argv[1]
rtts = []
ce_values = []

with open(path) as f:
    content = f.read()

for m in re.finditer(r'rtt:([\d.]+)/', content):
    rtts.append(float(m.group(1)))

for m in re.finditer(r'delivered_ce:(\d+)', content):
    ce_values.append(int(m.group(1)))

print("=== Resumen de la prueba ===")
if rtts:
    print(f"Muestras de RTT: {len(rtts)}")
    print(f"RTT medio:   {statistics.mean(rtts):.1f} ms")
    print(f"RTT mediana: {statistics.median(rtts):.1f} ms")
    print(f"RTT min:     {min(rtts):.1f} ms")
    print(f"RTT max:     {max(rtts):.1f} ms")
    if len(rtts) > 1:
        print(f"RTT stdev:   {statistics.stdev(rtts):.1f} ms")
else:
    print("No se encontraron muestras de RTT (revisa ss_stats.txt)")

print()
if ce_values:
    print(f"delivered_ce inicial: {ce_values[0]}")
    print(f"delivered_ce final:   {ce_values[-1]}")
    print(f"Paquetes marcados CE durante la prueba: {ce_values[-1] - ce_values[0]}")
else:
    print("No se detecto ningun paquete marcado CE (delivered_ce ausente)")
    print("(Normal si CCA=cubic, ya que cubic no negocia ECN/L4S)")
PYEOF

cat "$OUTDIR/resumen.txt"

echo ""
echo "=================================================="
echo " Prueba completada. Resultados en: $OUTDIR"
echo "=================================================="
ls -lh "$OUTDIR"
