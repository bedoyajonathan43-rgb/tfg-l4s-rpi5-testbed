#!/bin/bash
# =============================================================================
# campana_oai.sh  -  TFG L4S: campañas de medida en OAI con repeticiones
#
# Lee un fichero de casos (CSV), repite cada caso N veces en orden aleatorio
# y guarda por cada prueba todo lo necesario para el análisis estadístico.
#
# Uso:
#   ./campana_oai.sh <casos.csv> [repeticiones=10] [semilla=1] [duracion=60]
#
# Formato de casos.csv (con cabecera):
#   caso,modo,dir,cca,punto,rate,qdisc[,ruido]
#     modo : rt (RFSIM_REALTIME=1) | libre (sin ritmo) | cpu (sin ritmo + CPUs limitadas)
#     dir  : uplink | downlink
#     cca  : prague | cubic
#     punto: upf-eth0 | upf-tun0 | ue-oaitun | ninguno
#     rate : Mbit/s del HTB; 0 = sin HTB (sin límite)
#     qdisc: dualpi2 | pfifo | ninguno
#     ruido: (opcional) noise_power_dB AWGN SOLO en el sentido de la prueba; el
#            otro sentido se deja a -50 dB. Vacío = no se toca el ruido.
#            Usa -50 en los casos "sin ruido" para que el coste de CPU sea igual.
#
# Reanudable: si se vuelve a lanzar con el mismo casos.csv, se salta las
# pruebas ya terminadas (fichero DONE en su carpeta).
#
# Variables de entorno opcionales:
#   CPUSET_GNB / CPUSET_UE  CPUs para el modo "cpu" (p.ej. "0" y "1")
#   CPUS_GNB / CPUS_UE      cuota de CPU para el modo "cpu" (p.ej. 0.5 = medio núcleo)
#   RUIDO_DB=<dB>           ruido por defecto para casos sin columna "ruido"
#   RUIDO_OPTS_GNB / RUIDO_OPTS_UE  deben contener chanmod si hay ruido (ver LEEME)
#   RAN_COMPOSE             compose de la RAN (p.ej. docker-compose-oai-rfsim-24prb.yaml)
#   PCAP=1                  captura cabeceras (-s 128) en eth0 y tun0 de la UPF
#
# Comprobaciones por prueba (29/09/2026, tras detectar que iperf2 ignoraba --tcp-cca):
#   - algoritmo fijado con sysctl en el emisor + iperf -Z; tcp_ecn=3 en el receptor (AccECN)
#   - la prueba NO es válida si ss no muestra el algoritmo pedido o si Prague cae a "reno"
#   - estadísticas de dualpi2 con el tc de L4STeam (contenedor auxiliar tc-l4s en la red de la UPF)
#   - pings de fondo desde el emisor: clásico (-Q 0) y ECT(1) (-Q 1), 10/s, más 3 s de ping en reposo
#   DESCANSO=20             segundos de reposo entre pruebas
#   MAX_INTENTOS=3          intentos por prueba si no es válida (modo rt)
# =============================================================================
set -uo pipefail

CASOS="${1:?Uso: $0 <casos.csv> [repeticiones] [semilla] [duracion]}"
REPS="${2:-10}"
SEED="${3:-1}"
DUR="${4:-60}"
DESCANSO="${DESCANSO:-20}"
MAX_INTENTOS="${MAX_INTENTOS:-3}"
PCAP="${PCAP:-0}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
HAY_RUIDO=$(python3 -c "import csv,sys; print(int(any((c.get('ruido') or '').strip() for c in csv.DictReader(open(sys.argv[1])))))" "$CASOS")
if { [ "$HAY_RUIDO" = 1 ] || [ -n "${RUIDO_DB:-}" ]; } && \
   { [[ "${RUIDO_OPTS_GNB:-}" != *chanmod* ]] || [[ "${RUIDO_OPTS_UE:-}" != *chanmod* ]]; }; then
  echo "ERROR: hay casos con ruido pero RUIDO_OPTS_GNB / RUIDO_OPTS_UE no activan el modelo de canal."
  echo 'Exporta antes: export RUIDO_OPTS_GNB="--rfsimulator.[0].options chanmod --telnetsrv" RUIDO_OPTS_UE="$RUIDO_OPTS_GNB"'
  exit 1
fi

TCIMG=tc-l4s:img
if ! docker image inspect $TCIMG > /dev/null 2>&1; then
  if docker exec tc-l4s tc -V > /dev/null 2>&1; then
    docker commit tc-l4s $TCIMG > /dev/null && echo "Imagen $TCIMG creada a partir del contenedor tc-l4s."
  else
    echo "ERROR: falta el tc de L4STeam (contenedor tc-l4s). Ejecuta antes el diagnóstico 4."; exit 1
  fi
fi

COMPOSE_DIR=~/oai-cn5g-fed/docker-compose
CORE_COMPOSE="docker-compose-basic-nrf.yaml"
RAN_COMPOSE="${RAN_COMPOSE:-docker-compose-oai-rfsim-basic.yaml}"
GNB=oai-gnb-basic
UE=oai-nr-ue-basic
UPF=oai-upf
EXTDN=oai-ext-dn
EXT_DN_IP=192.168.70.135
PORT_UL=5001
PORT_DL=5002
NCPU=$(nproc)

BASE=~/campanas_oai/$(basename "$CASOS" .csv)
mkdir -p "$BASE"
LOG="$BASE/campana.log"
STATUS="$BASE/estado.csv"
[ -f "$STATUS" ] || echo "prueba,caso,modo,rep,intento,inicio,fin,valida,motivo" > "$STATUS"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

# -----------------------------------------------------------------------------
# 1. Plan de pruebas (aleatorio, agrupado por modo para no reiniciar la red
#    en cada prueba). Si ya existe, se reutiliza (reanudar).
# -----------------------------------------------------------------------------
if [ ! -f "$BASE/plan.csv" ]; then
  cp "$CASOS" "$BASE/casos.csv"
  python3 - "$CASOS" "$REPS" "$SEED" > "$BASE/plan.csv" <<'PY'
import csv, random, sys
casos = list(csv.DictReader(open(sys.argv[1])))
reps, seed = int(sys.argv[2]), int(sys.argv[3])
rnd = random.Random(seed)
modos = sorted({c['modo'] for c in casos})
rnd.shuffle(modos)
print('n,caso,modo,dir,cca,punto,rate,qdisc,rep,ruido,umbral')
n = 0
for m in modos:
    lista = [(c, r) for c in casos if c['modo'] == m for r in range(1, reps + 1)]
    rnd.shuffle(lista)
    for c, r in lista:
        n += 1
        print(f"{n},{c['caso']},{c['modo']},{c['dir']},{c['cca']},{c['punto']},{c['rate']},{c['qdisc']},{r},{(c.get('ruido') or '').strip()},{(c.get('umbral') or '').strip()}")
PY
  log "Plan creado: $(($(wc -l < "$BASE/plan.csv") - 1)) pruebas (reps=$REPS, semilla=$SEED, duracion=${DUR}s)"
else
  log "Reanudando campaña existente en $BASE"
fi

# -----------------------------------------------------------------------------
# 2. Funciones de la red
# -----------------------------------------------------------------------------
ue_ip() { docker exec "$UE" ip -4 addr show oaitun_ue1 2>/dev/null | grep -oP 'inet \K[\d.]+'; }

red_ok() {
  [ "$(docker inspect -f '{{.State.Running}}' "$GNB" 2>/dev/null)" = "true" ] || return 1
  [ "$(docker inspect -f '{{.State.Running}}' "$UE" 2>/dev/null)" = "true" ] || return 1
  local ip; ip=$(ue_ip) || return 1
  [ -n "$ip" ] || return 1
  docker exec "$UE" ping -I oaitun_ue1 -c 3 -W 2 "$EXT_DN_IP" > /dev/null 2>&1 || return 1
  docker exec "$EXTDN" ping -c 2 -W 2 "$ip" > /dev/null 2>&1 || return 1
}

modo_actual() {
  docker exec "$GNB" printenv RFSIM_REALTIME 2>/dev/null || echo "?"
}

arrancar_red() {   # $1 = valor de RFSIM_REALTIME (0/1)
  log "Reiniciando la red 5G con RFSIM_REALTIME=$1 ..."
  cd "$COMPOSE_DIR" || exit 1
  docker compose -f "$RAN_COMPOSE" down < /dev/null > /dev/null 2>&1
  docker compose -f "$CORE_COMPOSE" down > /dev/null 2>&1
  sleep 3
  docker compose -f "$CORE_COMPOSE" up -d > /dev/null 2>&1
  for i in $(seq 1 30); do
    local ok=1
    for s in oai-nrf oai-amf oai-smf oai-upf oai-udm oai-udr oai-ausf; do
      [ "$(docker inspect -f '{{.State.Health.Status}}' $s 2>/dev/null)" = "healthy" ] || ok=0
    done
    [ $ok = 1 ] && break
    sleep 5
  done
  sleep 5
  RFSIM_REALTIME="$1" docker compose -f "$RAN_COMPOSE" up -d > /dev/null 2>&1
  for i in $(seq 1 24); do
    [ -n "$(ue_ip)" ] && break
    sleep 5
  done
  sleep 15
  cd - > /dev/null
  if red_ok; then log "Red operativa (UE $(ue_ip))."; return 0; fi
  log "ERROR: la red no ha quedado operativa tras el reinicio."; return 1
}

asegurar_modo() {  # $1 = rt | libre | cpu
  local want=0; [ "$1" = "rt" ] && want=1
  if [ "$(modo_actual)" != "$want" ] || ! red_ok; then
    arrancar_red "$want" || { sleep 30; arrancar_red "$want" || exit 1; }
  fi
  local all="0-$((NCPU-1))"
  if [ "$1" = "cpu" ]; then
    docker update --cpuset-cpus "${CPUSET_GNB:?Define CPUSET_GNB para el modo cpu}" --cpus "${CPUS_GNB:-0}" "$GNB" > /dev/null
    docker update --cpuset-cpus "${CPUSET_UE:?Define CPUSET_UE para el modo cpu}" --cpus "${CPUS_UE:-0}" "$UE" > /dev/null
  else
    # núcleos fijos: gNB y UE en el mismo nodo NUMA; núcleo 5G y servidor en el otro (FIJAR_NUCLEOS=0 lo desactiva)
    if [ "${FIJAR_NUCLEOS:-1}" = 1 ] && [ "$NCPU" -ge 32 ]; then
      if [ "$(docker inspect -f '{{.HostConfig.CpusetCpus}}' "$GNB")" != "${CPUSET_GNB_RT:-0-7}" ]; then
        docker update --cpuset-cpus "${CPUSET_GNB_RT:-0-7}" --cpus 0 "$GNB" > /dev/null
        docker update --cpuset-cpus "${CPUSET_UE_RT:-8-15}" --cpus 0 "$UE" > /dev/null
        for c in "$UPF" "$EXTDN" oai-smf oai-amf oai-nrf oai-udm oai-udr oai-ausf mysql; do
          docker update --cpuset-cpus "${CPUSET_RESTO_RT:-16-31}" "$c" > /dev/null 2>&1
        done
      fi
    else
      docker update --cpuset-cpus "$all" --cpus 0 "$GNB" "$UE" > /dev/null
    fi
  fi
}

asegurar_tc() {   # contenedor auxiliar con el tc de L4STeam, unido a la red ACTUAL de la UPF
  local upid; upid=$(docker inspect -f '{{.State.Pid}}' "$UPF" 2>/dev/null)
  if [ "$(cat "$BASE/.tc_upf_pid" 2>/dev/null)" != "$upid" ] || ! docker exec tc-l4s true > /dev/null 2>&1; then
    docker rm -f tc-l4s > /dev/null 2>&1
    docker run -d --name tc-l4s --net container:"$UPF" $TCIMG sleep infinity > /dev/null || return 1
    echo "$upid" > "$BASE/.tc_upf_pid"
  fi
  docker exec tc-l4s tc -V > /dev/null 2>&1
}

limpiar_aqm() {
  docker exec "$UPF" tc qdisc del dev eth0 root 2> /dev/null
  docker exec "$UPF" tc qdisc del dev tun0 root 2> /dev/null
  docker exec "$UE"  tc qdisc del dev oaitun_ue1 root 2> /dev/null
  return 0
}

punto_a_cont_iface() {  # imprime "contenedor interfaz"
  case "$1" in
    upf-eth0)  echo "$UPF eth0" ;;
    upf-tun0)  echo "$UPF tun0" ;;
    ue-oaitun) echo "$UE oaitun_ue1" ;;
    *)         echo "" ;;
  esac
}

aplicar_aqm() {  # $1 punto  $2 rate  $3 qdisc
  local ci; ci=$(punto_a_cont_iface "$1")
  [ -z "$ci" ] || [ "$3" = "ninguno" ] && return 0
  local c=${ci% *} i=${ci#* }
  if [ "$2" != "0" ]; then
    docker exec "$c" tc qdisc add dev "$i" root handle 1: htb default 1 r2q 100 || return 1
    docker exec "$c" tc class add dev "$i" parent 1: classid 1:1 htb rate "${2}mbit" ceil "${2}mbit" || return 1
    docker exec "$c" tc qdisc add dev "$i" parent 1:1 handle 10: "$3" || return 1
  else
    docker exec "$c" tc qdisc add dev "$i" root "$3" || return 1
  fi
}

# -----------------------------------------------------------------------------
# 3. Una prueba
# -----------------------------------------------------------------------------
ejecutar_prueba() {  # $1 dir_salida  $2 dir  $3 cca  $4 punto  $5 rate  $6 qdisc  $7 modo  $8 ruido
  local OUT=$1 DIR=$2 CCA=$3 PUNTO=$4 RATE=$5 QD=$6 MODO=$7 RUIDO="${8:-${RUIDO_DB:-}}"
  local UMBRAL="${9:-}"; UMBRAL=$(echo "${UMBRAL:-0}" | tr -dc "0-9"); [ -z "$UMBRAL" ] && UMBRAL=0
  mkdir -p "$OUT"
  local UEIP; UEIP=$(ue_ip)

  local SND RCV DST PORT BIND_SRV BIND_CLI
  if [ "$DIR" = "uplink" ]; then
    SND=$UE; RCV=$EXTDN; DST=$EXT_DN_IP; PORT=$PORT_UL; BIND_SRV=""; BIND_CLI="-B $UEIP"
  else
    SND=$EXTDN; RCV=$UE; DST=$UEIP; PORT=$PORT_DL; BIND_SRV="-B $UEIP"; BIND_CLI=""
  fi
  local ECN=2; [ "$CCA" = "prague" ] && ECN=3

  limpiar_aqm
  if [ -n "$RUIDO" ]; then   # ruido solo en el sentido de la prueba; el otro a -50 dB
    local S=dl O=ul; [ "$DIR" = "uplink" ] && { S=ul; O=dl; }
    { "$SCRIPT_DIR/ruido.sh" $O -50; "$SCRIPT_DIR/ruido.sh" $S "$RUIDO"; } > "$OUT/ruido_aplicado.txt" 2>&1
    [ "$(grep -c "noise:" "$OUT/ruido_aplicado.txt")" -ge 2 ] || { echo "fallo_ruido" > "$OUT/motivo"; return 1; }
    sleep 15   # tiempo para que el enlace adapte MCS al nuevo ruido
  fi
  aplicar_aqm "$PUNTO" "$RATE" "$QD" || { echo "fallo_aqm" > "$OUT/motivo"; return 1; }
  # umbral de marcado L4S del gNB (parche TFG v2): se cambia en caliente; 0 = sin marcado
  local GNB_L4S=no; docker exec "$GNB" grep -aq "L4S v2" /opt/oai-gnb/bin/nr-softmodem 2> /dev/null && GNB_L4S=si
  if [ "$GNB_L4S" = si ]; then
    docker exec "$GNB" sh -c "echo $UMBRAL > /tmp/tfg_umbral"; sleep 2
  elif [ "$UMBRAL" != 0 ]; then
    echo "gnb_sin_parche_l4s" > "$OUT/motivo"; return 1
  fi
  asegurar_tc || { echo "fallo_tc_l4s" > "$OUT/motivo"; return 1; }
  # emisor: algoritmo por defecto = el pedido (iperf2 2.1.x no entiende --tcp-cca) y tcp_ecn;
  # receptor: tcp_ecn=3 para aceptar AccECN (sin él Prague cae a su modo "reno")
  docker exec "$SND" sysctl -qw net.ipv4.tcp_congestion_control=$CCA net.ipv4.tcp_ecn=$ECN > /dev/null 2>&1
  docker exec "$RCV" sysctl -qw net.ipv4.tcp_ecn=3 > /dev/null 2>&1
  # cada prueba empieza sin datos de la conexion anterior (cache de metricas TCP de Linux)
  for c in "$SND" "$RCV"; do
    docker exec "$c" sysctl -qw net.ipv4.tcp_no_metrics_save=1 > /dev/null 2>&1
    docker exec "$c" ip tcp_metrics flush all > /dev/null 2>&1
  done
  [ "$(docker exec "$SND" sysctl -n net.ipv4.tcp_ecn)" = "$ECN" ] || { echo "fallo_tcp_ecn" > "$OUT/motivo"; return 1; }
  [ "$(docker exec "$SND" sysctl -n net.ipv4.tcp_congestion_control)" = "$CCA" ] || { echo "fallo_cca_sysctl" > "$OUT/motivo"; return 1; }
  [ "$(docker exec "$RCV" sysctl -n net.ipv4.tcp_ecn)" = "3" ] || { echo "fallo_tcp_ecn_receptor" > "$OUT/motivo"; return 1; }

  local ci; ci=$(punto_a_cont_iface "$PUNTO")
  local AQC=${ci% *} AQI=${ci#* }
  {
    echo "dir=$DIR"; echo "cca=$CCA"; echo "punto=$PUNTO"; echo "rate_mbit=$RATE"; echo "qdisc=$QD"
    echo "modo=$MODO"; echo "rfsim_realtime=$(modo_actual)"
    echo "ruido_dB=${RUIDO:-ninguno}"
    echo "tcp_no_metrics_save=$(docker exec "$SND" sysctl -n net.ipv4.tcp_no_metrics_save 2> /dev/null)"
    echo "umbral_us=$UMBRAL"; echo "gnb_parche_l4s=$GNB_L4S"
    echo "ran_compose=$RAN_COMPOSE"
    echo "cpuset_gnb=$(docker inspect -f '{{.HostConfig.CpusetCpus}}' $GNB)"
    echo "cpuset_ue=$(docker inspect -f '{{.HostConfig.CpusetCpus}}' $UE)"
    echo "cuota_cpu_gnb=$(docker inspect -f '{{.HostConfig.NanoCpus}}' $GNB)"
    echo "cuota_cpu_ue=$(docker inspect -f '{{.HostConfig.NanoCpus}}' $UE)"
    echo "ue_ip=$UEIP"; echo "emisor=$SND"; echo "tcp_ecn=$ECN"; echo "tcp_ecn_receptor=3"; echo "duracion=$DUR"
    echo "gnb_imagen=$(docker inspect -f '{{.Image}}' $GNB)"
    echo "librfsim_sha256=$(sha256sum $COMPOSE_DIR/rfsim-rt/librfsimulator.so 2>/dev/null | cut -c1-16)"
  } > "$OUT/meta.txt"
  local TCC=$AQC; [ "$AQC" = "$UPF" ] && TCC=tc-l4s
  [ -n "$ci" ] && docker exec "$TCC" tc qdisc show dev "$AQI" > "$OUT/qdisc_aplicado.txt"

  # ping en reposo (3 s) antes del tráfico: referencia del RTT sin carga en esta prueba
  local PINGI=""; [ "$SND" = "$UE" ] && PINGI="-I oaitun_ue1"
  docker exec "$SND" ping $PINGI -D -c 30 -i 0.1 "$DST" > "$OUT/ping_reposo.txt" 2>&1

  # servidor iperf nuevo en cada prueba (así se guarda su salida: goodput real)
  docker exec "$RCV" pkill -f "iperf -s" > /dev/null 2>&1; sleep 1
  docker exec "$RCV" sh -c "iperf -s -p $PORT $BIND_SRV -e -i 1" > "$OUT/iperf_servidor.txt" 2>&1 &
  local SRV_PID=$!
  sleep 2

  local T0; T0=$(date +%s)
  local T0US; T0US=$(docker exec "$GNB" date +%s%6N)
  echo "t_inicio=$T0" >> "$OUT/meta.txt"
  # estadísticas acumuladas de L1 y MAC del gNB (OAI las reescribe cada ~1 s): foto al inicio y al final
  docker exec "$GNB" sh -c 'cd /opt/oai-gnb && cat nrMAC_stats.log nrL1_stats.log' > "$OUT/stats_gnb_ini.txt" 2>&1

  # muestreadores dentro de los contenedores (sin coste de docker exec por muestra)
  docker exec "$SND" sh -c "end=\$((\$(date +%s)+$DUR+3)); while [ \$(date +%s) -lt \$end ]; do echo \"=== t=\$(date +%s.%N)\"; ss -tiom dst $DST:$PORT; sleep 0.5; done" > "$OUT/ss.txt" 2>&1 &
  local SS_PID=$!
  local TC_PID=""
  local NP=$((DUR * 10 + 20))
  docker exec "$SND" ping $PINGI -D -Q 0 -c $NP -i 0.1 "$DST" > "$OUT/ping_c.txt" 2>&1 &
  local PC_PID=$!
  docker exec "$SND" ping $PINGI -D -Q 1 -c $NP -i 0.1 "$DST" > "$OUT/ping_l.txt" 2>&1 &
  local PL_PID=$!
  if [ -n "$ci" ] && [ "$QD" != "ninguno" ]; then
    docker exec "$TCC" sh -c "end=\$((\$(date +%s)+$DUR+3)); while [ \$(date +%s) -lt \$end ]; do echo \"=== t=\$(date +%s.%N)\"; tc -s qdisc show dev $AQI; sleep 1; done" > "$OUT/tc.txt" 2>&1 &
    TC_PID=$!
  fi
  if [ "$PCAP" = "1" ]; then
    docker exec -d "$UPF" sh -c "timeout $((DUR+5)) tcpdump -i eth0 -s 128 -w /tmp/eth0.pcap tcp port $PORT"
    docker exec -d "$UPF" sh -c "timeout $((DUR+5)) tcpdump -i tun0 -s 128 -w /tmp/tun0.pcap tcp port $PORT"
    sleep 1
  fi

  docker exec "$SND" iperf -c "$DST" -p "$PORT" $BIND_CLI -Z "$CCA" -e -i 1 -t "$DUR" > "$OUT/iperf_cliente.txt" 2>&1
  local RC=$?
  sleep 3
  wait "$SS_PID" 2> /dev/null
  [ -n "$TC_PID" ] && wait "$TC_PID" 2> /dev/null
  wait "$PC_PID" "$PL_PID" 2> /dev/null
  docker exec "$RCV" pkill -f "iperf -s" > /dev/null 2>&1
  wait "$SRV_PID" 2> /dev/null

  local T1; T1=$(date +%s)
  # tramo del registro RLC del gNB correspondiente a esta prueba (parche TFG v2)
  if [ "$GNB_L4S" = si ]; then
    docker exec "$GNB" awk -F, -v a="$T0US" -v b="$(docker exec "$GNB" date +%s%6N)" 'NR==1 || ($1>=a && $1<=b)' /opt/oai-gnb/tfg_rlc.csv > "$OUT/rlc.csv" 2> /dev/null
  fi
  echo "t_fin=$T1" >> "$OUT/meta.txt"
  docker exec "$GNB" sh -c 'cd /opt/oai-gnb && cat nrMAC_stats.log nrL1_stats.log' > "$OUT/stats_gnb_fin.txt" 2>&1
  docker logs --since "$T0" --until "$T1" "$GNB" > "$OUT/gnb.log" 2>&1
  docker logs --since "$T0" --until "$T1" "$UE"  > "$OUT/ue.log"  2>&1
  if [ "$PCAP" = "1" ]; then
    sleep 3
    docker cp "$UPF:/tmp/eth0.pcap" "$OUT/upf_eth0.pcap" > /dev/null 2>&1
    docker cp "$UPF:/tmp/tun0.pcap" "$OUT/upf_tun0.pcap" > /dev/null 2>&1
  fi
  limpiar_aqm

  [ $RC -eq 0 ] || { echo "fallo_iperf_rc$RC" > "$OUT/motivo"; return 1; }
  grep -q "sec" "$OUT/iperf_servidor.txt" || { echo "sin_salida_servidor" > "$OUT/motivo"; return 1; }
  # el algoritmo realmente usado por la conexión (iperf y ss)
  grep -q "congestion control set to $CCA" "$OUT/iperf_cliente.txt" || { echo "cca_no_aplicado_iperf" > "$OUT/motivo"; return 1; }
  grep -qw "$CCA" "$OUT/ss.txt" || { echo "cca_no_visto_en_ss" > "$OUT/motivo"; return 1; }
  if [ "$CCA" = "prague" ] && grep -qw "reno" "$OUT/ss.txt"; then echo "prague_en_modo_reno" > "$OUT/motivo"; return 1; fi
  return 0
}

# Validez: en modo rt, 0 reanclajes y < 5 % de bloques tarde durante la prueba
prueba_valida() {  # $1 dir_salida  $2 modo
  [ -f "$1/motivo" ] && return 1
  [ "$2" != "rt" ] && return 0
  python3 - "$1/gnb.log" <<'PY'
import re, sys
b = t = r = 0
for l in open(sys.argv[1], errors='ignore'):
    m = re.search(r'RT pacing: bloques=(\d+) tarde\(>1ms\)=(\d+).*reanclajes=(\d+)', l)
    if m:
        b += int(m.group(1)); t += int(m.group(2)); r += int(m.group(3))
if b == 0:
    print("sin_lineas_pacing"); sys.exit(1)
if r > 1 or t / b >= 0.05:
    print(f"pacing_invalido tarde={100*t/b:.2f}% reanclajes={r}"); sys.exit(1)
PY
}

# -----------------------------------------------------------------------------
# 4. Bucle principal
# -----------------------------------------------------------------------------
TOTAL=$(($(wc -l < "$BASE/plan.csv") - 1))
log "==== Inicio de la campaña $(basename "$BASE"): $TOTAL pruebas ===="
while IFS=, read -r -u 3 N CASO MODO DIR CCA PUNTO RATE QD REP RUIDO_CASO UMBRAL_CASO; do
  NOMBRE=$(printf "p%03d_%s_rep%02d" "$N" "$CASO" "$REP")
  [ -f "$BASE/$NOMBRE/DONE" ] && continue
  asegurar_modo "$MODO"
  for INT in $(seq 1 "$MAX_INTENTOS"); do
    OUT="$BASE/$NOMBRE"
    [ "$INT" -gt 1 ] && OUT="$BASE/${NOMBRE}_intento$INT"
    rm -rf "$OUT"
    if ! red_ok; then
      log "UE/red caída antes de $NOMBRE: reinicio."
      want=0; [ "$MODO" = "rt" ] && want=1
      arrancar_red "$want" || exit 1
      asegurar_modo "$MODO"
    fi
    INI=$(date '+%F %T')
    log "[$N/$TOTAL] $CASO rep $REP (modo $MODO, intento $INT)"
    ejecutar_prueba "$OUT" "$DIR" "$CCA" "$PUNTO" "$RATE" "$QD" "$MODO" "${RUIDO_CASO:-}" "${UMBRAL_CASO:-}" < /dev/null
    MOTIVO=$(prueba_valida "$OUT" "$MODO"); OK=$?
    [ -f "$OUT/motivo" ] && MOTIVO=$(cat "$OUT/motivo")
    FIN=$(date '+%F %T')
    if [ $OK -eq 0 ]; then
      echo "$NOMBRE,$CASO,$MODO,$REP,$INT,$INI,$FIN,si," >> "$STATUS"
      touch "$OUT/DONE"
      [ "$OUT" != "$BASE/$NOMBRE" ] && { rm -rf "$BASE/$NOMBRE"; mv "$OUT" "$BASE/$NOMBRE"; }
      touch "$BASE/$NOMBRE/DONE"
      log "   valida"
      sleep "$DESCANSO"
      break
    else
      echo "$NOMBRE,$CASO,$MODO,$REP,$INT,$INI,$FIN,no,$MOTIVO" >> "$STATUS"
      mv "$OUT" "$BASE/invalidas_${NOMBRE}_intento$INT" 2> /dev/null
      log "   NO valida ($MOTIVO)"
      sleep "$DESCANSO"
    fi
  done
done 3< <(tail -n +2 "$BASE/plan.csv")
docker update --cpuset-cpus "0-$((NCPU-1))" --cpus 0 "$GNB" "$UE" > /dev/null 2>&1
for c in "$EXTDN" "$UE"; do docker exec "$c" sysctl -qw net.ipv4.tcp_congestion_control=cubic net.ipv4.tcp_ecn=2 > /dev/null 2>&1; done
log "==== Campaña terminada. Resumen: python3 $(dirname "$0")/resumen_campana.py $BASE ===="
