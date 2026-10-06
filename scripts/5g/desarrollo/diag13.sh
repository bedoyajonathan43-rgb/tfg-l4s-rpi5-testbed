#!/bin/bash
# Diagnóstico 13: ¿por qué el gNB parcheado pierde el tiempo real con carga?
set -u
D=~/oai-cn5g-fed/docker-compose; R=$D/rfsim-rt; SRC=~/oai-src
UE=oai-nr-ue-basic; EXT=oai-ext-dn; GNB=oai-gnb-basic
echo "== CPU de la VM: $(nproc) núcleos; $(lscpu | grep -m1 'Model name' | sed 's/ \+/ /g')"
if [ ! -f $R/nr-softmodem-vanilla ]; then
  echo "== Compilando nr-softmodem SIN parche (mismas opciones que el parcheado)"
  cp -n $R/nr-softmodem-tfg $R/nr-softmodem-tfg.parcheado
  cd $SRC && git checkout -- openair2/LAYER2/nr_rlc/nr_rlc_entity_am.c openair2/LAYER2/nr_rlc/nr_rlc_entity_am.h
  docker run --rm -v "$SRC":/oai-ran -w /oai-ran/build_rt ran-base:tfg bash -c \
    "ninja nr-softmodem 2>&1 | tail -2 && chown -R $(id -u):$(id -g) /oai-ran/build_rt" || exit 1
  cp $SRC/build_rt/nr-softmodem $R/nr-softmodem-vanilla
  python3 ~/tfg-l4s-rpi5-testbed/scripts/5g/l4s_gnb/parche_l4s_rlc.py $SRC > /dev/null
  cd - > /dev/null
fi
cp -n $R/nr-softmodem-tfg $R/nr-softmodem-tfg.parcheado
grep -aq TFG_L4S_UMBRAL_US $R/nr-softmodem-vanilla && { echo "ERROR: la versión sin parche contiene el parche"; exit 1; }
lanzar() {
  cd $D && docker compose -f docker-compose-oai-rfsim-basic.yaml down >/dev/null 2>&1
  docker compose -f docker-compose-oai-rfsim-basic.yaml.antes_l4s down >/dev/null 2>&1
  [ "$2" != "-" ] && cp "$2" $R/nr-softmodem-tfg
  TFG_LOG_MS=$3 RFSIM_REALTIME=1 docker compose -f "$1" up -d >/dev/null 2>&1; cd - >/dev/null
  for i in $(seq 1 24); do sleep 5; docker exec $UE ping -I oaitun_ue1 -c 1 -W 2 192.168.70.135 >/dev/null 2>&1 && break; done
  sleep 20
  UEIP=$(docker exec $UE ip -4 addr show oaitun_ue1 | grep -oP 'inet \K[\d.]+')
}
carga() {
  for c in $EXT $UE; do docker exec $c sysctl -qw net.ipv4.tcp_ecn=3; done
  docker exec $EXT sysctl -qw net.ipv4.tcp_congestion_control=cubic
  docker exec $UE pkill -x iperf >/dev/null 2>&1; sleep 1; docker exec -d $UE iperf -s -p 5002 -B $UEIP; sleep 2
  G=$(docker exec $EXT iperf -c $UEIP -p 5002 -t 30 -e -i 30 2>&1 | grep -E "^\[ *1\] 0\.0+-3[0-9]" | tail -1 | grep -oE "[0-9.]+ Mbits/sec")
  echo -n "$G; "
}
variante() {
  echo "######## $1"; lanzar "$2" "$3" "$4"
  echo -n "  binario: "; docker exec $GNB grep -aq TFG_L4S_UMBRAL_US /opt/oai-gnb/bin/nr-softmodem && echo parcheado || echo "sin parche"
  echo -n "  CPU del gNB en reposo: "; docker stats --no-stream --format "{{.CPUPerc}}" $GNB
  T0=$(date +%s); echo -n "  goodput Cubic: "; carga; carga; carga; echo
  echo -n "  tiempo real con carga: "
  docker logs --since $T0 $GNB 2>&1 | grep -oE "bloques=[0-9]+ tarde\(>1ms\)=[0-9]+|reanclajes=[0-9]+" | \
    awk -F'[= ]' '/bloques/{b+=$2; t+=$4; n++} /reanclajes/{r+=$2} END{printf "%.2f%% bloques tarde, %d reanclajes (%d tramos de 10 s)\n", (b?100*t/b:0), r, n}'
}
variante "V0 binario oficial de la imagen"      docker-compose-oai-rfsim-basic.yaml.antes_l4s -                            10
variante "V1 recompilado SIN parche"            docker-compose-oai-rfsim-basic.yaml          $R/nr-softmodem-vanilla       10
variante "V2 parcheado, registro casi apagado"  docker-compose-oai-rfsim-basic.yaml          $R/nr-softmodem-tfg.parcheado 100000000
variante "V3 parcheado, registro cada 10 ms"    docker-compose-oai-rfsim-basic.yaml          $R/nr-softmodem-tfg.parcheado 10
docker exec $EXT sysctl -qw net.ipv4.tcp_congestion_control=cubic; for c in $EXT $UE; do docker exec $c sysctl -qw net.ipv4.tcp_ecn=2; done
docker exec $UE pkill -x iperf >/dev/null 2>&1
echo "######## fin (en marcha: V3, gNB parcheado con registro)"
