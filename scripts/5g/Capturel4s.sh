#!/bin/bash
set -e

# =============================================================================
# capture_l4s_test.sh
#
# Automatiza una prueba L4S (TCP Prague sobre UPF con AQM configurable) y
# guarda de forma organizada:
#   - Captura pcap del trafico en la interfaz del UPF
#   - Estadisticas ss -tiom del lado del UE durante la prueba
#   - Estado del qdisc (tc -s qdisc show) antes y despues
#   - Un fichero de metadatos (metadata.txt) con la configuracion usada
#
# Uso:
#   ./capture_l4s_test.sh <nombre_escenario> [duracion_segundos]
#
# Ejemplos:
#   ./capture_l4s_test.sh baseline_sin_aqm 20
#   ./capture_l4s_test.sh dualpi2_2mbit 20
# =============================================================================

SCENARIO_NAME="${1:-test}"
DURATION="${2:-20}"

UE_CONTAINER="oai-nr-ue-basic"
UPF_CONTAINER="oai-upf"
UPF_IFACE="eth0"
EXT_DN_IP="192.168.70.135"
IPERF_PORT="5001"
UE_TUNNEL_IP="12.1.1.131"   # ajustar si la IP del UE cambia tras un restart

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTDIR=~/resultados_5g_l4s/${SCENARIO_NAME}_${TIMESTAMP}
mkdir -p "$OUTDIR"

echo "=================================================="
echo " Escenario:  $SCENARIO_NAME"
echo " Duracion:   ${DURATION}s"
echo " Salida en:  $OUTDIR"
echo "=================================================="

# -----------------------------------------------------------------------
# 1. Detectar IP real del UE dentro del contenedor (por si cambio tras un restart)
# -----------------------------------------------------------------------
DETECTED_UE_IP=$(docker exec "$UE_CONTAINER" ip -4 addr show oaitun_ue1 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "")
if [ -n "$DETECTED_UE_IP" ]; then
    UE_TUNNEL_IP="$DETECTED_UE_IP"
fi
echo "IP del UE detectada: $UE_TUNNEL_IP"

# -----------------------------------------------------------------------
# 2. Guardar estado del qdisc ANTES de la prueba
# -----------------------------------------------------------------------
{
    echo "=== tc qdisc show (antes) ==="
    docker exec "$UPF_CONTAINER" tc qdisc show dev "$UPF_IFACE"
    echo ""
    echo "=== tc class show (antes) ==="
    docker exec "$UPF_CONTAINER" tc class show dev "$UPF_IFACE"
} > "$OUTDIR/qdisc_antes.txt"

# -----------------------------------------------------------------------
# 3. Arrancar servidor iperf en ext-dn si no esta corriendo ya
# -----------------------------------------------------------------------
docker exec "$UPF_CONTAINER" true 2>/dev/null || { echo "ERROR: no se puede acceder a $UPF_CONTAINER"; exit 1; }
if ! docker exec oai-ext-dn pgrep -f "iperf -s" > /dev/null 2>&1; then
    echo "Arrancando servidor iperf en oai-ext-dn..."
    docker exec -d oai-ext-dn iperf -s -p "$IPERF_PORT"
    sleep 1
fi

# -----------------------------------------------------------------------
# 4. Lanzar captura pcap en el UPF (background)
# -----------------------------------------------------------------------
echo "Iniciando captura pcap en $UPF_CONTAINER ($UPF_IFACE)..."
docker exec "$UPF_CONTAINER" rm -f /tmp/capture.pcap
docker exec -d "$UPF_CONTAINER" tcpdump -i "$UPF_IFACE" -w /tmp/capture.pcap host "$EXT_DN_IP"
sleep 2   # dar tiempo a que tcpdump este listo

# -----------------------------------------------------------------------
# 5. Lanzar trafico iperf con TCP Prague (background)
# -----------------------------------------------------------------------
echo "Lanzando trafico iperf (TCP Prague) durante ${DURATION}s..."
docker exec -d "$UE_CONTAINER" iperf -c "$EXT_DN_IP" -p "$IPERF_PORT" -B "$UE_TUNNEL_IP" --tcp-cca prague -i 1 -t "$DURATION" > "$OUTDIR/iperf_stdout.txt" 2>&1

# -----------------------------------------------------------------------
# 6. Capturar ss -tiom en paralelo, una muestra por segundo
# -----------------------------------------------------------------------
echo "Capturando estadisticas ss -tiom (una muestra/segundo)..."
> "$OUTDIR/ss_stats.txt"
for i in $(seq 1 "$DURATION"); do
    {
        echo "=== t=${i}s ==="
        docker exec "$UE_CONTAINER" ss -tiom dst "$EXT_DN_IP"
    } >> "$OUTDIR/ss_stats.txt"
    sleep 1
done

# margen extra para que el iperf y la captura terminen de vaciar buffers
sleep 3

# -----------------------------------------------------------------------
# 7. Parar la captura pcap
# -----------------------------------------------------------------------
echo "Deteniendo captura pcap..."
docker exec "$UPF_CONTAINER" pkill tcpdump 2>/dev/null || true
sleep 1

# -----------------------------------------------------------------------
# 8. Guardar estado del qdisc DESPUES de la prueba
# -----------------------------------------------------------------------
{
    echo "=== tc -s qdisc show (despues) ==="
    docker exec "$UPF_CONTAINER" tc -s qdisc show dev "$UPF_IFACE"
} > "$OUTDIR/qdisc_despues.txt"

# -----------------------------------------------------------------------
# 9. Copiar el pcap generado
# -----------------------------------------------------------------------
docker cp "$UPF_CONTAINER":/tmp/capture.pcap "$OUTDIR/capture.pcap" 2>/dev/null || echo "AVISO: no se pudo copiar el pcap"

# -----------------------------------------------------------------------
# 10. Guardar metadatos de la prueba
# -----------------------------------------------------------------------
cat > "$OUTDIR/metadata.txt" << EOF
Escenario:       $SCENARIO_NAME
Fecha/hora:      $(date)
Duracion:        ${DURATION}s
UE IP (tunel):   $UE_TUNNEL_IP
Destino:         $EXT_DN_IP:$IPERF_PORT
Interfaz UPF:    $UPF_IFACE
Comando iperf:   iperf -c $EXT_DN_IP -p $IPERF_PORT -B $UE_TUNNEL_IP --tcp-cca prague -i 1 -t $DURATION
EOF

# -----------------------------------------------------------------------
# Resumen final
# -----------------------------------------------------------------------
echo ""
echo "=================================================="
echo " Prueba completada. Resultados guardados en:"
echo " $OUTDIR"
echo "--------------------------------------------------"
ls -lh "$OUTDIR"
echo "=================================================="
echo ""
echo "Para analizar el pcap con tshark, por ejemplo:"
echo "  tshark -r $OUTDIR/capture.pcap -Y \"ip.dsfield.ecn != 0\" -T fields -e frame.number -e ip.src -e ip.dst -e ip.dsfield.ecn"
