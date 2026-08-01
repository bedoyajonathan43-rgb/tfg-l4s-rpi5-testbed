#!/bin/bash

# ==========================================================
# Script de Experimentos TFG: Reproducción de Fairness
# Prague vs. CUBIC (metodología Sarpkaya, Fund & Panwar, 2024)
# Testbed: rp51 (cliente) <-> rp50 (router AQM) <-> rp52 (servidor)
#
# Diferencias respecto a MedidasV8.sh:
#   1. BW FIJO a 100 Mbps (no se barre) -> igual que el paper de referencia
#   2. RTT emulado de 10 ms mediante netem, aplicado en rp51 (cliente),
#      NO en rp50, para no interferir con el árbol HTB+AQM ya validado
#   3. Se barre el TAMAÑO DE BUFFER (5 puntos en múltiplos de BDP)
#      en lugar del ancho de banda
#   4. Cada combinación (escenario x buffer) se repite 10 veces
#   5. El flujo de "ruido" es siempre Cubic SIN ECN, igual que en
#      MedidasV8.sh, pero aquí se ejecuta EN PARALELO real (no con
#      el retardo de 1s que usábamos antes), porque aquí no estamos
#      midiendo el arranque de conexión sino el reparto en régimen
#      estacionario, como hace el paper de referencia
#
# NOVEDAD (post-diagnóstico ss -tiom, 28/07/2026):
#   Se añade una verificación de sanidad tc/iperf tras aplicar cada
#   configuración de AQM y tras cada repetición, para detectar
#   automáticamente si el qdisc no llegó a recibir tráfico real
#   (p. ej. por un problema de sincronización entre la aplicación
#   del AQM y el lanzamiento de iperf). Si se detecta, la repetición
#   se marca como INVALIDA en el log y NO se cuenta como válida.
# ==========================================================

# --- CONFIGURACIÓN DE RED ---
SERVIDOR="192.168.10.2"         # rp52
CLIENTE="192.168.20.2"          # rp51
INTERFAZ="eth0"                 # Interfaz de rp50 hacia rp52 (HTB + AQM)
INTERFAZ_CLIENTE="eth0"         # Interfaz de rp51 hacia rp50 (netem delay)
IPERF_PATH="$HOME/iperf2_sf/src/iperf"
IPERF_SERVER_USER="rpiuser"

# --- PARÁMETROS FIJOS (igual que el paper de referencia) ---
DURACION=60
VENTANA="2000K"
BW="100mbit"
RTT_MS=10                       # RTT total emulado
REPETICIONES=10                 # 10 repeticiones por punto, como en el paper
PUERTO_RUIDO=5002
RESULTADOS=~/resultados_fairness_sarpkaya

# --- BUFFERS A BARRER (en paquetes, múltiplos de BDP a 100Mbps/10ms) ---
declare -A BUFFERS=(
    ["0.5xBDP"]=43
    ["1xBDP"]=86
    ["2xBDP"]=173
    ["4xBDP"]=345
    ["8xBDP"]=691
)

# Cada ejecución del script crea su propio subdirectorio con timestamp,
# para no sobrescribir nunca resultados de ejecuciones anteriores.
TS_EJECUCION=$(date +%Y%m%d_%H%M%S)
RESULTADOS="${RESULTADOS}/ejecucion_${TS_EJECUCION}"

mkdir -p $RESULTADOS
LOG_SANIDAD="$RESULTADOS/log_sanidad_tc.csv"
if [ ! -f "$LOG_SANIDAD" ]; then
    echo "escenario;buffer;rep;bytes_antes;bytes_despues;delta_bytes;valido" > "$LOG_SANIDAD"
fi

# ============================================
# Función: Aplicar retardo RTT en el CLIENTE (rp51)
# ============================================
aplicar_rtt() {
    echo "[*] Aplicando netem delay=${RTT_MS}ms en rp51 (${INTERFAZ_CLIENTE})..."
    ssh ${IPERF_SERVER_USER}@${CLIENTE} \
        "sudo tc qdisc del dev ${INTERFAZ_CLIENTE} root 2>/dev/null; \
         sudo tc qdisc add dev ${INTERFAZ_CLIENTE} root netem delay ${RTT_MS}ms" 2>/dev/null
    echo "[*] Verificación:"
    ssh ${IPERF_SERVER_USER}@${CLIENTE} "tc qdisc show dev ${INTERFAZ_CLIENTE}"
}

limpiar_rtt() {
    ssh ${IPERF_SERVER_USER}@${CLIENTE} \
        "sudo tc qdisc del dev ${INTERFAZ_CLIENTE} root 2>/dev/null"
}

# ============================================
# Función: Aplicar Jerarquía de Colas (tc) en rp50, con buffer parametrizado
# ============================================
aplicar_qdisc() {
    local escenario=$1
    local buffer_pkts=$2

    echo "[*] Configurando TC para $escenario con buffer=${buffer_pkts}p..."
    sudo tc qdisc del dev $INTERFAZ root 2>/dev/null

    sudo tc qdisc add dev $INTERFAZ root handle 1: htb default 10
    sudo tc class add dev $INTERFAZ parent 1: classid 1:10 htb rate $BW ceil $BW

    case $escenario in
        "E1_pfifo")
            sudo tc qdisc add dev $INTERFAZ parent 1:10 handle 100: pfifo limit ${buffer_pkts}
            ;;
        "E2_fq_codel")
            sudo tc qdisc add dev $INTERFAZ parent 1:10 handle 100: fq_codel noecn limit ${buffer_pkts}
            ;;
        "E3_fq_codel_ecn")
            sudo tc qdisc add dev $INTERFAZ parent 1:10 handle 100: fq_codel ecn limit ${buffer_pkts}
            ;;
        "E4_dualpi2_prague")
            sudo tc qdisc add dev $INTERFAZ parent 1:10 handle 100: dualpi2 limit ${buffer_pkts} 2>/dev/null
            if [ $? -ne 0 ]; then
                echo "[W] Falló DualPI2 con ese límite. Usando fq_codel ECN como fallback..."
                sudo tc qdisc add dev $INTERFAZ parent 1:10 handle 100: fq_codel ecn limit ${buffer_pkts} ce_threshold 1ms
            fi
            ;;
    esac

    echo "[*] Configuración TC activa:"
    sudo tc qdisc show dev $INTERFAZ

    # --- VERIFICACIÓN DE SANIDAD: el qdisc debe partir de 0 bytes ---
    # Esto confirma que estamos midiendo desde un estado limpio, y sirve
    # de referencia para el chequeo posterior de "bytes_despues".
    BYTES_INICIALES=$(sudo tc -s qdisc show dev $INTERFAZ | grep -oP 'Sent \K[0-9]+' | tail -1)
    if [ "$BYTES_INICIALES" -ne 0 ]; then
        echo "[!] ADVERTENCIA: el qdisc no partió de 0 bytes ($BYTES_INICIALES). Verificar manualmente."
    fi
}

# ============================================
# Función: Ejecutar UNA repetición (Prague vs Cubic simultáneos)
# ============================================
ejecutar_repeticion() {
    local escenario=$1
    local buffer_label=$2
    local buffer_pkts=$3
    local rep=$4
    local dir_resultados=$5

    local nombre="${escenario}_${buffer_label}_rep${rep}"

    # --- Bytes ANTES de esta repetición (para el chequeo de sanidad) ---
    local bytes_antes
    bytes_antes=$(sudo tc -s qdisc show dev $INTERFAZ | grep -oP 'Sent \K[0-9]+' | tail -1)

    if [[ "$escenario" == "E4_dualpi2_prague" ]]; then
        ecn_principal=3
        IPERF_EXTRA="--tcp-cca prague"
    else
        ecn_principal=3
        IPERF_EXTRA="--tcp-cca prague"
    fi

    ssh ${IPERF_SERVER_USER}@${SERVIDOR} \
        "sudo sysctl -w net.ipv4.tcp_ecn=${ecn_principal}" 2>/dev/null
    ssh ${IPERF_SERVER_USER}@${CLIENTE} \
        "sudo sysctl -w net.ipv4.tcp_ecn=${ecn_principal}" 2>/dev/null

    (while true; do
        echo "--- $(date +%T) ---" >> $dir_resultados/${nombre}_aqm.txt
        sudo tc -s qdisc show dev $INTERFAZ >> $dir_resultados/${nombre}_aqm.txt
        sleep 1
    done) &
    MON_PID=$!

    ssh ${IPERF_SERVER_USER}@${SERVIDOR} \
        "${IPERF_PATH} -s -e -i 1 -t $((DURACION+5)) -w $VENTANA" \
        > $dir_resultados/${nombre}_principal_servidor.txt 2>&1 &

    ssh ${IPERF_SERVER_USER}@${SERVIDOR} \
        "${IPERF_PATH} -s -e -i 1 -p $PUERTO_RUIDO -t $((DURACION+5)) -w $VENTANA" \
        > $dir_resultados/${nombre}_ruido_servidor.txt 2>&1 &
    sleep 2

    ssh ${IPERF_SERVER_USER}@${CLIENTE} \
        "${IPERF_PATH} -c $SERVIDOR -e -i 1 -t $DURACION -w $VENTANA $IPERF_EXTRA" \
        > $dir_resultados/${nombre}_principal_cliente.txt 2>&1 &
    PID_PRINCIPAL=$!

    ssh ${IPERF_SERVER_USER}@${CLIENTE} \
        "sudo sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null; \
         ${IPERF_PATH} -c $SERVIDOR -p $PUERTO_RUIDO -e -i 1 -t $DURACION -w $VENTANA --tcp-cca cubic" \
        > $dir_resultados/${nombre}_ruido_cliente.txt 2>&1 &
    PID_RUIDO=$!

    wait $PID_PRINCIPAL $PID_RUIDO

    kill $MON_PID 2>/dev/null
    ssh ${IPERF_SERVER_USER}@${SERVIDOR} "pkill -f iperf" 2>/dev/null

    # --- CHEQUEO DE SANIDAD: bytes DESPUES de esta repetición ---
    local bytes_despues
    bytes_despues=$(sudo tc -s qdisc show dev $INTERFAZ | grep -oP 'Sent \K[0-9]+' | tail -1)
    local delta=$((bytes_despues - bytes_antes))

    # Umbral mínimo esperado: a 100 Mbps, 60s, con dos flujos, deberíamos
    # ver como mínimo varias decenas de MB. Usamos 10 MB como umbral
    # conservador de "hubo tráfico real por el qdisc".
    local umbral_minimo=$((10 * 1024 * 1024))
    local valido="SI"
    if [ "$delta" -lt "$umbral_minimo" ]; then
        valido="NO"
        echo "[!!!] ALERTA: $nombre - solo $delta bytes contabilizados en el qdisc (< 10MB)."
        echo "      Posible problema de sincronización tc/iperf. Repetición marcada como INVALIDA."
    fi

    echo "${escenario};${buffer_label};${rep};${bytes_antes};${bytes_despues};${delta};${valido}" >> "$LOG_SANIDAD"

    echo "    [✓] $nombre completado (delta_bytes=$delta, valido=$valido)"
}

# ============================================
# Bucle principal: escenario x buffer x repetición
# ============================================
echo "=========================================================="
echo " Reproducción de fairness Prague vs CUBIC (Sarpkaya et al.)"
echo " BW=100Mbps fijo | RTT=${RTT_MS}ms | 5 buffers | ${REPETICIONES} repeticiones"
echo " Log de sanidad tc/iperf: $LOG_SANIDAD"
echo "=========================================================="

ping -c 2 $SERVIDOR > /dev/null 2>&1 || { echo "[✗] Sin conectividad con $SERVIDOR"; exit 1; }
ping -c 2 $CLIENTE > /dev/null 2>&1 || { echo "[✗] Sin conectividad con $CLIENTE"; exit 1; }

aplicar_rtt

for escenario in "E1_pfifo" "E2_fq_codel" "E3_fq_codel_ecn" "E4_dualpi2_prague"; do
    for buffer_label in "${!BUFFERS[@]}"; do
        buffer_pkts=${BUFFERS[$buffer_label]}
        dir="$RESULTADOS/${escenario}/${buffer_label}"
        mkdir -p "$dir"

        aplicar_qdisc "$escenario" "$buffer_pkts"

        for rep in $(seq 1 $REPETICIONES); do
            echo ""
            echo ">>> $escenario | buffer=$buffer_label ($buffer_pkts pkts) | repetición $rep/$REPETICIONES"
            ejecutar_repeticion "$escenario" "$buffer_label" "$buffer_pkts" "$rep" "$dir"
            sleep 3
        done
    done
done

limpiar_rtt

echo ""
echo "=========================================================="
echo " EXPERIMENTOS COMPLETADOS. Resultados en: $RESULTADOS"
echo " Revisa $LOG_SANIDAD y filtra las filas con valido=NO antes"
echo " de procesar los resultados finales."
echo "=========================================================="

# Resumen rápido de repeticiones inválidas, si las hubiera
N_INVALIDAS=$(awk -F';' 'NR>1 && $7=="NO"' "$LOG_SANIDAD" | wc -l)
if [ "$N_INVALIDAS" -gt 0 ]; then
    echo ""
    echo "[!!!] Se detectaron $N_INVALIDAS repeticiones marcadas como INVALIDAS:"
    awk -F';' 'NR>1 && $7=="NO"' "$LOG_SANIDAD"
    echo "Deberás relanzar manualmente esos puntos concretos."
fi
