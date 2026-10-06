#!/bin/bash
# Diagnóstico 14: parche v2 (registro asíncrono). Compila y comprueba el tiempo real con carga.
set -u
D=~/oai-cn5g-fed/docker-compose; R=$D/rfsim-rt; SRC=~/oai-src; DIR=$(cd "$(dirname "$0")" && pwd)
UE=oai-nr-ue-basic; EXT=oai-ext-dn; GNB=oai-gnb-basic
[ -f $R/nr-softmodem-vanilla ] || { echo "ERROR: falta nr-softmodem-vanilla (ejecuta antes diag13)"; exit 1; }
echo "== Compilando el parche v2"
cd $SRC && git checkout -- openair2/LAYER2/nr_rlc/nr_rlc_entity_am.c openair2/LAYER2/nr_rlc/nr_rlc_entity_am.h
python3 $DIR/parche_l4s_rlc.py $SRC || exit 1
docker run --rm -v "$SRC":/oai-ran -w /oai-ran/build_rt ran-base:tfg bash -c \
  "ninja nr-softmodem 2>&1 | tail -2 && chown -R $(id -u):$(id -g) /oai-ran/build_rt" || exit 1
cp $SRC/build_rt/nr-softmodem $R/nr-softmodem-tfg.v2
grep -aq "L4S v2" $R/nr-softmodem-tfg.v2 && echo "   OK: binario v2" || { echo "ERROR: el binario no es el v2"; exit 1; }
cd - > /dev/null
lanzar() {
  cd $D && docker compose -f docker-compose-oai-rfsim-basic.yaml down >/dev/null 2>&1
  cp "$1" $R/nr-softmodem-tfg
  RFSIM_REALTIME=1 docker compose -f docker-compose-oai-rfsim-basic.yaml up -d >/dev/null 2>&1; cd - >/dev/null
  for i in $(seq 1 24); do sleep 5; docker exec $UE ping -I oaitun_ue1 -c 1 -W 2 192.168.70.135 >/dev/null 2>&1 && break; done
  sleep 20
  UEIP=$(docker exec $UE ip -4 addr show oaitun_ue1 | grep -oP 'inet \K[\d.]+')
}
carga() {
  for c in $EXT $UE; do docker exec $c sysctl -qw net.ipv4.tcp_ecn=3; done
  docker exec $EXT sysctl -qw net.ipv4.tcp_congestion_control=$1
  docker exec $UE pkill -x iperf >/dev/null 2>&1; sleep 1; docker exec -d $UE iperf -s -p 5002 -B $UEIP; sleep 2
  docker exec $EXT sh -c "iperf -c $UEIP -p 5002 -Z $1 -t 30 -e -i 30 > /tmp/ip.txt 2>&1" &
  sleep 25; C=$(docker exec $EXT ss -tin dst $UEIP:5002 | grep bytes_acked | grep -oE "\brtt:[0-9.]+|delivered_ce:[0-9]+" | tr '\n' ' ')
  wait
  G=$(docker exec $EXT sh -c 'grep -E "^\[ *1\] 0\.0+-3[0-9]" /tmp/ip.txt | tail -1' | grep -oE "[0-9.]+ Mbits/sec")
  echo "    $1: $G  $C"
}
rt() {
  echo -n "  tiempo real con carga: "
  docker logs --since $1 $GNB 2>&1 | grep -oE "bloques=[0-9]+ tarde\(>1ms\)=[0-9]+|reanclajes=[0-9]+" | \
    awk -F'[= ]' '/bloques/{b+=$2; t+=$4; n++} /reanclajes/{r+=$2} END{printf "%.2f%% bloques tarde, %d reanclajes (%d tramos de 10 s)\n", (b?100*t/b:0), r, n}'
}
echo "######## V1 recompilado SIN parche"; lanzar $R/nr-softmodem-vanilla
T0=$(date +%s); carga cubic; carga cubic; carga cubic; rt $T0
echo "######## V4 parche v2, registro 10 ms, umbral 0"; lanzar $R/nr-softmodem-tfg.v2
T0=$(date +%s); carga cubic; carga cubic; carga cubic; rt $T0
docker logs $GNB 2>&1 | grep -m1 "L4S v2"
echo "######## V4m parche v2, registro 10 ms, umbral 2 ms (Prague)"
docker exec $GNB sh -c 'echo 2000 > /tmp/tfg_umbral'; sleep 2
T0=$(date +%s); carga prague; carga prague; carga prague; rt $T0
docker exec $GNB sh -c 'echo 0 > /tmp/tfg_umbral'
echo -n "  líneas de registro: "; docker exec $GNB sh -c 'wc -l < /opt/oai-gnb/tfg_rlc.csv'
docker exec $EXT sysctl -qw net.ipv4.tcp_congestion_control=cubic; for c in $EXT $UE; do docker exec $c sysctl -qw net.ipv4.tcp_ecn=2; done
docker exec $UE pkill -x iperf >/dev/null 2>&1
echo "######## fin (en marcha: parche v2, umbral 0)"
