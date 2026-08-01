#!/bin/bash

# ==========================================================
# Script de Experimentos TFG: AQM & L4S (v7.0 - RPi Testbed)
# Objetivo: Comparativa pfifo, fq_codel y L4S (DualPI2)
# Testbed: rp51 (cliente) <-> rp50 (router AQM) <-> rp52 (servidor)
# ==========================================================

# --- CONFIGURACIÓN DE RED ---
SERVIDOR="192.168.10.2"         # rp52
CLIENTE="192.168.20.2"          # rp51
INTERFAZ="eth0"                 # Interfaz de rp50 hacia rp52
IPERF_PATH="~/iperf2_sf/src/iperf"
IPERF_SERVER_USER="rpiuser"

# --- PARÁMETROS DE EXPERIMENTO ---
DURACION=60
VENTANA="256K"
RESULTADOS=~/resultados_bel


mkdir -p $RESULTADOS

# ============================================
# Función: Aplicar Jerarquía de Colas (tc)
# ============================================
aplicar_qdisc() {
    local escenario=$1
    local bw_limit=$2
    echo "[*] Configurando TC para $escenario a $bw_limit..."

    # 1. Limpiar raíz
    sudo tc qdisc del dev $INTERFAZ root 2>/dev/null

    if [[ "$bw_limit" == "sin_limite" ]]; then
        # Sin HTB, aplicar AQM directamente en la raíz
        case $escenario in
            "E1_pfifo")
                sudo tc qdisc add dev $INTERFAZ root handle 100: pfifo limit 1000
                ;;
            "E2_fq_codel")
                sudo tc qdisc add dev $INTERFAZ root handle 100: fq_codel noecn
                ;;
            "E3_fq_codel_ecn")
                sudo tc qdisc add dev $INTERFAZ root handle 100: fq_codel ecn
                ;;
            "E4_dualpi2_prague")
                echo "[!] Aplicando DualPI2..."
                sudo tc qdisc add dev $INTERFAZ root handle 100: dualpi2 2>/dev/null
                if [ $? -ne 0 ]; then
                    echo "[W] Falló DualPI2. Usando fq_codel ECN como fallback..."
                    sudo tc qdisc add dev $INTERFAZ root handle 100: fq_codel ecn ce_threshold 1ms
                else
                    echo "[✓] DualPI2 aplicado correctamente (sin límite de BW)."
                fi
                ;;
        esac
    else
        # 2. Crear Jerarquía HTB (cuello de botella)
        sudo tc qdisc add dev $INTERFAZ root handle 1: htb default 10
        sudo tc class add dev $INTERFAZ parent 1: classid 1:10 htb rate $bw_limit ceil $bw_limit

        # 3. Añadir el AQM específico bajo HTB
        case $escenario in
            "E1_pfifo")
                sudo tc qdisc add dev $INTERFAZ parent 1:10 handle 100: pfifo limit 1000
                ;;
            "E2_fq_codel")
                sudo tc qdisc add dev $INTERFAZ parent 1:10 handle 100: fq_codel noecn
                ;;
            "E3_fq_codel_ecn")
                sudo tc qdisc add dev $INTERFAZ parent 1:10 handle 100: fq_codel ecn
                ;;
            "E4_dualpi2_prague")
                echo "[!] Aplicando DualPI2..."
                sudo tc qdisc add dev $INTERFAZ parent 1:10 handle 100: dualpi2 2>/dev/null
                if [ $? -ne 0 ]; then
                    echo "[W] Falló DualPI2. Usando fq_codel ECN como fallback..."
                    sudo tc qdisc add dev $INTERFAZ parent 1:10 handle 100: fq_codel ecn ce_threshold 1ms
                else
                    echo "[✓] DualPI2 aplicado correctamente bajo $bw_limit."
                fi
                ;;
        esac
    fi

    # Verificar configuración aplicada
    echo "[*] Configuración TC activa:"
    sudo tc qdisc show dev $INTERFAZ
}

# ============================================
# Función: Ejecutar Escenario
# ============================================
ejecutar_escenario() {
    local escenario=$1
    local bw_limit=$2
    local dir_resultados=$3

    # Determinación de CCA, ECN y flags extra de iperf
    if [[ "$escenario" == "E4_dualpi2_prague" ]]; then
        cca="prague"
        ecn_val=3
        IPERF_EXTRA="--tcp-cca prague"
    elif [[ "$escenario" == "E3_fq_codel_ecn" ]]; then
        cca="cubic"
        ecn_val=1
        IPERF_EXTRA=""
    else
        cca="cubic"
        ecn_val=0
        IPERF_EXTRA=""
    fi

    echo ""
    echo "=========================================================="
    echo " EJECUTANDO: $escenario (CCA=$cca | ECN=$ecn_val | BW=$bw_limit)"
    echo "=========================================================="

    # Aplicar qdisc
    aplicar_qdisc $escenario $bw_limit

    # Limpiar stats previas en cliente
    ssh ${IPERF_SERVER_USER}@${CLIENTE} "rm -f /tmp/ss_stats.txt" 2>/dev/null

    # Configurar CCA y ECN en servidor (rp52) y cliente (rp51)
    echo "[*] Configurando CCA=$cca y ECN=$ecn_val en rp51 y rp52..."
    ssh ${IPERF_SERVER_USER}@${SERVIDOR} \
        "sudo sysctl -w net.ipv4.tcp_congestion_control=$cca net.ipv4.tcp_ecn=$ecn_val" 2>/dev/null
    ssh ${IPERF_SERVER_USER}@${CLIENTE} \
        "sudo sysctl -w net.ipv4.tcp_congestion_control=$cca net.ipv4.tcp_ecn=$ecn_val" 2>/dev/null

    # Monitor AQM en segundo plano (tc -s cada 1s)
    (while true; do
        echo "--- $(date +%T) ---" >> $dir_resultados/${escenario}_aqm.txt
        sudo tc -s qdisc show dev $INTERFAZ >> $dir_resultados/${escenario}_aqm.txt
        sleep 1
    done) &
    MON_PID=$!

    # Captura tcpdump en segundo plano
    sudo timeout $((DURACION+5)) tcpdump -i $INTERFAZ -s 100 host $SERVIDOR \
        -w $dir_resultados/${escenario}.pcap > /dev/null 2>&1 &
    TCPDUMP_PID=$!

    sleep 2

    # Arrancar servidor iperf en rp52
    echo "[*] Arrancando servidor iperf en rp52..."
    ssh ${IPERF_SERVER_USER}@${SERVIDOR} \
        "${IPERF_PATH} -s -e -i 1 -t $((DURACION+5))" \
        > $dir_resultados/${escenario}_servidor.txt 2>&1 &
    SERVER_PID=$!
    sleep 2

    # Captura ss en cliente (rp51) cada 0.5s en segundo plano
    echo "[*] Capturando métricas ss en rp51..."
    ssh ${IPERF_SERVER_USER}@${CLIENTE} \
        "for i in \$(seq 1 $((DURACION*2))); do
            ss -tiom dst $SERVIDOR >> /tmp/ss_stats.txt
            sleep 0.5
        done" &
    SS_PID=$!

    # Ejecutar iperf cliente en rp51
    echo "[*] Lanzando iperf cliente en rp51..."
    ssh ${IPERF_SERVER_USER}@${CLIENTE} \
        "${IPERF_PATH} -c $SERVIDOR -e -i 1 -t $DURACION -w $VENTANA $IPERF_EXTRA" \
        > $dir_resultados/${escenario}_cliente.txt 2>&1

    # Esperar a que termine la captura ss
    wait $SS_PID 2>/dev/null

    # Recoger stats ss del cliente
    scp ${IPERF_SERVER_USER}@${CLIENTE}:/tmp/ss_stats.txt \
        $dir_resultados/${escenario}_ss.txt 2>/dev/null

    # Limpiar procesos
    kill $MON_PID 2>/dev/null
    kill $TCPDUMP_PID 2>/dev/null
    ssh ${IPERF_SERVER_USER}@${SERVIDOR} "pkill -f iperf" 2>/dev/null

    echo "[✓] Escenario $escenario completado. Archivos guardados en $dir_resultados/"
    echo "    - ${escenario}_cliente.txt"
    echo "    - ${escenario}_servidor.txt"
    echo "    - ${escenario}_aqm.txt"
    echo "    - ${escenario}_ss.txt"
    echo "    - ${escenario}.pcap"

    sleep 5
}

# ============================================
# Función: Ejecutar lote completo de escenarios
# ============================================
ejecutar_lote() {
    local bw_limit=$1
    local dir_resultados=$2

    mkdir -p "$dir_resultados"

    echo ""
    echo "######################################################"
    echo "  LOTE: BW=$bw_limit -> $dir_resultados"
    echo "######################################################"

    ejecutar_escenario "E1_pfifo"          "$bw_limit" "$dir_resultados"
    ejecutar_escenario "E2_fq_codel"       "$bw_limit" "$dir_resultados"
    ejecutar_escenario "E3_fq_codel_ecn"   "$bw_limit" "$dir_resultados"
    ejecutar_escenario "E4_dualpi2_prague" "$bw_limit" "$dir_resultados"

    echo ""
    echo "[✓] Lote $bw_limit completado. Resultados en: $dir_resultados"
    echo ""
}

# ============================================
# Entrada interactiva de valores de BW
# ============================================
echo "=========================================================="
echo " TFG - Testbed AQM con Raspberry Pi"
echo " rp51 (cliente: $CLIENTE) <-> rp50 (router) <-> rp52 (servidor: $SERVIDOR)"
echo "=========================================================="
echo ""
echo "[*] Introduce los valores de limitación de ancho de banda (en Mbps)."
echo "    Pulsa Enter tras cada valor. Deja la línea vacía y pulsa Enter para comenzar."
echo "    Ejemplo: 1 → Enter, 5 → Enter, 10 → Enter, Enter (vacío para terminar)"
echo ""

BW_VALUES=()
while true; do
    read -rp "  BW (Mbps) [Enter vacío para terminar]: " valor
    if [[ -z "$valor" ]]; then
        if [[ ${#BW_VALUES[@]} -eq 0 ]]; then
            echo "[!] No se introdujo ningún valor. Se ejecutará solo la medida baseline."
        fi
        break
    fi
    # Validar que sea un número entero o decimal positivo
    if ! [[ "$valor" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "[!] Valor no válido: '$valor'. Introduce solo números (ej: 10, 2.5)."
        continue
    fi
    BW_VALUES+=("${valor}mbit")
    echo "    [+] Añadido: ${valor} Mbps"
done

echo ""
echo "[*] Valores de BW a medir: ${BW_VALUES[*]:-ninguno (solo baseline)}"
echo ""

# ============================================
# Verificación previa del entorno
# ============================================
echo "[*] Verificando conectividad..."

ping -c 2 $SERVIDOR > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "[✗] ERROR: No hay conectividad con el servidor ($SERVIDOR)"
    exit 1
fi

ping -c 2 $CLIENTE > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "[✗] ERROR: No hay conectividad con el cliente ($CLIENTE)"
    exit 1
fi

echo "[✓] Conectividad OK"
echo ""
echo "[*] Iniciando experimentos..."

# ============================================
# 1. SIEMPRE: Medida baseline (sin límite de BW)
# ============================================
echo ""
echo "######################################################"
echo "  BASELINE: Sin limitación de ancho de banda"
echo "######################################################"
ejecutar_lote "sin_limite" "$RESULTADOS/baseline"

# ============================================
# 2. Lotes por cada valor de BW introducido
# ============================================
for bw in "${BW_VALUES[@]}"; do
    # Nombre de carpeta limpio: 1mbit -> 1mbit
    nombre_carpeta="${bw}"
    ejecutar_lote "$bw" "$RESULTADOS/${nombre_carpeta}"
done

# ============================================
# Resumen final
# ============================================
echo ""
echo "=========================================================="
echo " EXPERIMENTOS COMPLETADOS"
echo " Resultados guardados en: $RESULTADOS"
echo ""
echo " Estructura de carpetas generada:"
ls -lh $RESULTADOS/
echo "=========================================================="
