#!/bin/bash

# ==========================================================
# Script de Diagnóstico TFG: Confirmación del sesgo RTT de Cubic
# frente a Prague (modo Reno) bajo fq_codel noecn, CON netem 10ms
#
# Objetivo: repetir el diagnóstico ss -tiom de coexistencia Prague
# vs Cubic (E2, 1xBDP) que ya hicimos, pero esta vez CON el RTT
# base de 10ms emulado (como en la campaña completa de
# Reproducciones_v2_con_sanidad.sh), para confirmar a nivel de
# kernel que la dominancia de Cubic sobre Prague observada en los
# 200 puntos de la campaña se debe al sesgo RTT de Cubic y no a
# otra causa. Comparar el ss_prague_*.txt / ss_cubic_*.txt
# resultantes con los que ya teníamos SIN netem (RTT~0.4ms) donde
# el reparto era ~50:50.
#
# Se ejecuta EN rp51 (cliente). Aplica el netem localmente antes
# de lanzar el test, y lo retira al finalizar.
# ==========================================================

# --- CONFIGURACIÓN ---
SERVIDOR="192.168.10.2"     # rp52
INTERFAZ_CLIENTE="eth0"     # eth0 de rp51 (hacia rp50)
PUERTO_PRAGUE=5001
PUERTO_CUBIC=5002
IPERF_PATH="$HOME/iperf2_sf/src/iperf"
VENTANA="2000K"
DURACION=60
RTT_MS=10
RESULTADOS=~/diagnostico_coexistencia_con_rtt
INTERVALO_SS=0.5

mkdir -p $RESULTADOS
TS=$(date +%Y%m%d_%H%M%S)
SALIDA_SS_PRAGUE="$RESULTADOS/ss_prague_conRTT_${TS}.txt"
SALIDA_SS_CUBIC="$RESULTADOS/ss_cubic_conRTT_${TS}.txt"

echo "=========================================================="
echo " Diagnóstico CON RTT emulado (10ms) - E2 (fq_codel noecn)"
echo " Salida ss Prague: $SALIDA_SS_PRAGUE"
echo " Salida ss Cubic:  $SALIDA_SS_CUBIC"
echo "=========================================================="

# Nota: este script asume que en rp50 YA tienes aplicado:
#   sudo tc qdisc del dev eth0 root 2>/dev/null
#   sudo tc qdisc add dev eth0 root handle 1: htb default 10
#   sudo tc class add dev eth0 parent 1: classid 1:10 htb rate 100mbit ceil 100mbit
#   sudo tc qdisc add dev eth0 parent 1:10 handle 100: fq_codel noecn limit 86
# verificado con: sudo tc -s qdisc show dev eth0  (Sent = 0 bytes)
#
# y que en rp52 tienes DOS servidores iperf escuchando:
#   iperf -s -e -i 1 -p 5001 -w 2000K   (Prague)
#   iperf -s -e -i 1 -p 5002 -w 2000K   (Cubic)

# ============================================
# 1) Aplicar netem delay=10ms en ESTA máquina (rp51)
#    (misma lógica que aplicar_rtt() en Reproducciones.sh)
# ============================================
echo "[*] Aplicando netem delay=${RTT_MS}ms en ${INTERFAZ_CLIENTE}..."
sudo tc qdisc del dev ${INTERFAZ_CLIENTE} root 2>/dev/null
sudo tc qdisc add dev ${INTERFAZ_CLIENTE} root netem delay ${RTT_MS}ms
echo "[*] Verificación:"
tc qdisc show dev ${INTERFAZ_CLIENTE}
sleep 1

# ============================================
# 2) Lanzar captura ss en bucle para AMBOS puertos simultáneamente
# ============================================
(
    echo "timestamp;raw_ss_line"
    START=$(date +%s.%N)
    while true; do
        NOW=$(date +%s.%N)
        ELAPSED=$(echo "$NOW - $START" | bc)
        LINE=$(ss -tiom dst $SERVIDOR:$PUERTO_PRAGUE 2>/dev/null | tr '\n' ' ')
        if [ -n "$LINE" ]; then
            echo "${ELAPSED};${LINE}"
        fi
        sleep $INTERVALO_SS
    done
) > "$SALIDA_SS_PRAGUE" &
SS_PID_PRAGUE=$!

(
    echo "timestamp;raw_ss_line"
    START=$(date +%s.%N)
    while true; do
        NOW=$(date +%s.%N)
        ELAPSED=$(echo "$NOW - $START" | bc)
        LINE=$(ss -tiom dst $SERVIDOR:$PUERTO_CUBIC 2>/dev/null | tr '\n' ' ')
        if [ -n "$LINE" ]; then
            echo "${ELAPSED};${LINE}"
        fi
        sleep $INTERVALO_SS
    done
) > "$SALIDA_SS_CUBIC" &
SS_PID_CUBIC=$!

echo "[*] Capturas ss iniciadas (Prague PID $SS_PID_PRAGUE, Cubic PID $SS_PID_CUBIC)."
sleep 1

# ============================================
# 3) Lanzar AMBOS flujos EN PARALELO REAL
# ============================================
sudo sysctl -w net.ipv4.tcp_ecn=3 >/dev/null

echo "[*] Lanzando flujo Prague (puerto $PUERTO_PRAGUE) durante ${DURACION}s..."
${IPERF_PATH} -c $SERVIDOR -p $PUERTO_PRAGUE -e -i 1 -t $DURACION -w $VENTANA --tcp-cca prague \
    > "$RESULTADOS/iperf_prague_conRTT_${TS}.txt" 2>&1 &
PID_PRAGUE=$!

echo "[*] Lanzando flujo Cubic (puerto $PUERTO_CUBIC) durante ${DURACION}s..."
sudo sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null
${IPERF_PATH} -c $SERVIDOR -p $PUERTO_CUBIC -e -i 1 -t $DURACION -w $VENTANA --tcp-cca cubic \
    > "$RESULTADOS/iperf_cubic_conRTT_${TS}.txt" 2>&1 &
PID_CUBIC=$!

wait $PID_PRAGUE $PID_CUBIC

echo "[*] Ambos tests finalizados. Deteniendo capturas ss..."
sleep 2
kill $SS_PID_PRAGUE $SS_PID_CUBIC 2>/dev/null

# ============================================
# 4) Retirar el netem (dejar rp51 limpio para no interferir
#    con otros experimentos posteriores)
# ============================================
echo "[*] Retirando netem de ${INTERFAZ_CLIENTE}..."
sudo tc qdisc del dev ${INTERFAZ_CLIENTE} root 2>/dev/null

echo ""
echo "=========================================================="
echo " DIAGNÓSTICO CON RTT COMPLETADO"
echo " - ss Prague: $SALIDA_SS_PRAGUE"
echo " - ss Cubic:  $SALIDA_SS_CUBIC"
echo " - iperf Prague: $RESULTADOS/iperf_prague_conRTT_${TS}.txt"
echo " - iperf Cubic:  $RESULTADOS/iperf_cubic_conRTT_${TS}.txt"
echo "=========================================================="
echo ""
echo "Comprueba en rp50 que 'Sent X bytes' del qdisc fq_codel ya no es 0"
echo "(sudo tc -s qdisc show dev eth0), y compara pacing_rate/cwnd/minrtt"
echo "de este ss_prague_conRTT_*.txt frente al ss_prague_*.txt SIN RTT"
echo "que ya teníais, para confirmar el sesgo RTT de Cubic."
