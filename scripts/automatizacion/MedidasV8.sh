#!/bin/bash

# ==========================================================
# Script de Experimentos TFG: AQM & L4S (v8.0 - RPi Testbed)
# Objetivo: Comparativa pfifo, fq_codel y L4S (DualPI2)
#           + Flujo de ruido paralelo para análisis de coexistencia
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
VENTANA="2000K"
RESULTADOS=~/resultados_flujo_ruidoCDFa1

# --- PUERTO DEL FLUJO DE RUIDO ---
PUERTO_RUIDO=5002

mkdir -p $RESULTADOS

# ============================================
# Entrada interactiva: configuración del flujo de ruido
# ============================================
echo "=========================================================="
echo " CONFIGURACIÓN DEL FLUJO DE RUIDO (paralelo al flujo principal)"
echo " Este flujo se lanzará en los 4 escenarios (E1-E4) para"
echo " analizar la coexistencia con el flujo principal de cada uno."
echo "=========================================================="
echo ""

read -rp "  [Ruido] Algoritmo de congestión (ej: cubic, reno, prague, dctcp): " CCA_RUIDO
CCA_RUIDO=${CCA_RUIDO:-cubic}

while true; do
    read -rp "  [Ruido] Valor de tcp_ecn (0=desactivado, 1=ECN clásico, 3=AccECN): " ECN_RUIDO
    if [[ "$ECN_RUIDO" =~ ^(0|1|3)$ ]]; then
        break
    else
        echo "  [!] Valor no válido. Debe ser 0, 1 o 3."
    fi
done

echo ""
echo "[*] Flujo de ruido configurado: CCA=$CCA_RUIDO | ECN=$ECN_RUIDO | puerto=$PUERTO_RUIDO"
echo "    Se ejecutará en paralelo al flujo principal en TODOS los escenarios."
echo ""

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
# Función: Ejecutar Escenario (con flujo de ruido paralelo)
# ============================================
ejecutar_escenario() {
    local escenario=$1
    local bw_limit=$2
    local dir_resultados=$3

    # Determinación de CCA, ECN y flags extra de iperf (flujo PRINCIPAL)
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
    echo " RUIDO PARALELO: CCA=$CCA_RUIDO | ECN=$ECN_RUIDO | puerto=$PUERTO_RUIDO"
    echo "=========================================================="

    # Aplicar qdisc
    aplicar_qdisc $escenario $bw_limit

    # Limpiar stats previas en cliente
    ssh ${IPERF_SERVER_USER}@${CLIENTE} "rm -f /tmp/ss_stats.txt /tmp/ss_stats_ruido.txt" 2>/dev/null

    # Monitor AQM en segundo plano (tc -s cada 1s)
    (while true; do
        echo "--- $(date +%T) ---" >> $dir_resultados/${escenario}_aqm.txt
        sudo tc -s qdisc show dev $INTERFAZ >> $dir_resultados/${escenario}_aqm.txt
        sleep 1
    done) &
    MON_PID=$!

    # Captura tcpdump en segundo plano (incluye ambos flujos, mismo host destino)
    sudo timeout $((DURACION+5)) tcpdump -i $INTERFAZ -s 100 host $SERVIDOR \
        -w $dir_resultados/${escenario}.pcap > /dev/null 2>&1 &
    TCPDUMP_PID=$!

    sleep 2

    # Arrancar servidor iperf PRINCIPAL en rp52 (puerto por defecto 5001)
    echo "[*] Arrancando servidor iperf PRINCIPAL en rp52 (puerto 5001)..."
    ssh ${IPERF_SERVER_USER}@${SERVIDOR} \
        "${IPERF_PATH} -s -e -i 1 -t $((DURACION+5)) -w $VENTANA" \
        > $dir_resultados/${escenario}_servidor.txt 2>&1 &
    SERVER_PID=$!

    # Arrancar servidor iperf de RUIDO en rp52 (puerto dedicado)
    echo "[*] Arrancando servidor iperf de RUIDO en rp52 (puerto $PUERTO_RUIDO)..."
    ssh ${IPERF_SERVER_USER}@${SERVIDOR} \
        "${IPERF_PATH} -s -e -i 1 -p $PUERTO_RUIDO -t $((DURACION+5)) -w $VENTANA" \
        > $dir_resultados/${escenario}_ruido_servidor.txt 2>&1 &
    SERVER_RUIDO_PID=$!
    sleep 2

    # Captura ss en cliente (rp51) cada 0.5s en segundo plano — flujo principal
    echo "[*] Capturando métricas ss en rp51 (flujo principal)..."
    ssh ${IPERF_SERVER_USER}@${CLIENTE} \
        "for i in \$(seq 1 $((DURACION*2))); do
            ss -tiom dst $SERVIDOR >> /tmp/ss_stats.txt
            sleep 0.5
        done" &
    SS_PID=$!

    # --------------------------------------------------------
    # SECUENCIA CRÍTICA: ECN se fija en el connect() del socket.
    # 1) Fijamos ECN del escenario -> lanzamos flujo PRINCIPAL (bg)
    # 2) Esperamos a que el handshake ocurra (~1s)
    # 3) Cambiamos ECN al valor del RUIDO -> lanzamos flujo RUIDO (bg)
    # 4) Esperamos a que ambos terminen
    # --------------------------------------------------------

    echo "[*] (1/4) Fijando CCA=$cca ECN=$ecn_val para flujo PRINCIPAL..."
    ssh ${IPERF_SERVER_USER}@${SERVIDOR} \
        "sudo sysctl -w net.ipv4.tcp_congestion_control=$cca net.ipv4.tcp_ecn=$ecn_val" 2>/dev/null
    ssh ${IPERF_SERVER_USER}@${CLIENTE} \
        "sudo sysctl -w net.ipv4.tcp_congestion_control=$cca net.ipv4.tcp_ecn=$ecn_val" 2>/dev/null

    echo "[*] (2/4) Lanzando flujo PRINCIPAL en rp51 (background)..."
    ssh ${IPERF_SERVER_USER}@${CLIENTE} \
        "${IPERF_PATH} -c $SERVIDOR -e -i 1 -t $DURACION -w $VENTANA $IPERF_EXTRA" \
        > $dir_resultados/${escenario}_cliente.txt 2>&1 &
    CLIENTE_PRINCIPAL_PID=$!

    sleep 1

    echo "[*] (3/4) Fijando CCA=$CCA_RUIDO ECN=$ECN_RUIDO para flujo de RUIDO..."
    ssh ${IPERF_SERVER_USER}@${SERVIDOR} \
        "sudo sysctl -w net.ipv4.tcp_congestion_control=$CCA_RUIDO net.ipv4.tcp_ecn=$ECN_RUIDO" 2>/dev/null
    ssh ${IPERF_SERVER_USER}@${CLIENTE} \
        "sudo sysctl -w net.ipv4.tcp_congestion_control=$CCA_RUIDO net.ipv4.tcp_ecn=$ECN_RUIDO" 2>/dev/null

    echo "[*] Capturando métricas ss en rp51 (flujo de ruido)..."
    ssh ${IPERF_SERVER_USER}@${CLIENTE} \
        "for i in \$(seq 1 $((DURACION*2))); do
            ss -tiom dst $SERVIDOR | grep -A5 \":$PUERTO_RUIDO \" >> /tmp/ss_stats_ruido.txt
            sleep 0.5
        done" &
    SS_RUIDO_PID=$!

    echo "[*] Lanzando flujo de RUIDO en rp51 (background)..."
    ssh ${IPERF_SERVER_USER}@${CLIENTE} \
        "${IPERF_PATH} -c $SERVIDOR -p $PUERTO_RUIDO -e -i 1 -t $DURACION -w $VENTANA --tcp-cca $CCA_RUIDO" \
        > $dir_resultados/${escenario}_ruido_cliente.txt 2>&1 &
    CLIENTE_RUIDO_PID=$!

    echo "[*] (4/4) Esperando a que ambos flujos terminen..."
    wait $CLIENTE_PRINCIPAL_PID 2>/dev/null
    wait $CLIENTE_RUIDO_PID 2>/dev/null

    # Esperar a que terminen las capturas ss
    wait $SS_PID 2>/dev/null
    wait $SS_RUIDO_PID 2>/dev/null

    # Recoger stats ss del cliente (ambos flujos)
    scp ${IPERF_SERVER_USER}@${CLIENTE}:/tmp/ss_stats.txt \
        $dir_resultados/${escenario}_ss.txt 2>/dev/null
    scp ${IPERF_SERVER_USER}@${CLIENTE}:/tmp/ss_stats_ruido.txt \
        $dir_resultados/${escenario}_ruido_ss.txt 2>/dev/null

    # Limpiar procesos
    kill $MON_PID 2>/dev/null
    kill $TCPDUMP_PID 2>/dev/null
    ssh ${IPERF_SERVER_USER}@${SERVIDOR} "pkill -f iperf" 2>/dev/null

    echo "[✓] Escenario $escenario completado. Archivos guardados en $dir_resultados/"
    echo "    Flujo principal:"
    echo "    - ${escenario}_cliente.txt"
    echo "    - ${escenario}_servidor.txt"
    echo "    - ${escenario}_ss.txt"
    echo "    Flujo de ruido:"
    echo "    - ${escenario}_ruido_cliente.txt"
    echo "    - ${escenario}_ruido_servidor.txt"
    echo "    - ${escenario}_ruido_ss.txt"
    echo "    Común:"
    echo "    - ${escenario}_aqm.txt"
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
echo "[*] Recuerda: flujo de ruido = CCA=$CCA_RUIDO | ECN=$ECN_RUIDO | puerto=$PUERTO_RUIDO"

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
echo " Flujo de ruido usado en todos los escenarios: CCA=$CCA_RUIDO | ECN=$ECN_RUIDO"
echo ""
echo " Estructura de carpetas generada:"
ls -lh $RESULTADOS/
echo "=========================================================="
