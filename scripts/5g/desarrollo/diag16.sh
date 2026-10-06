#!/bin/bash
# Diagnóstico 16: ¿fijar núcleos estabiliza el tiempo real con carga máxima?
set -u
D=~/oai-cn5g-fed/docker-compose; R=$D/rfsim-rt; UE=oai-nr-ue-basic; EXT=oai-ext-dn; GNB=oai-gnb-basic
fijar() {
  docker update --cpuset-cpus 0-7 $GNB >/dev/null; docker update --cpuset-cpus 8-15 $UE >/dev/null
  for c in oai-upf oai-ext-dn oai-smf oai-amf oai-nrf oai-udm oai-udr oai-ausf mysql; do docker update --cpuset-cpus 16-31 $c >/dev/null 2>&1; done
}
lanzar() {
  cd $D && docker compose -f docker-compose-oai-rfsim-basic.yaml down >/dev/null 2>&1
  cp "$1" $R/nr-softmodem-tfg
  RFSIM_REALTIME=1 docker compose -f docker-compose-oai-rfsim-basic.yaml up -d >/dev/null 2>&1; cd - >/dev/null
  fijar
  for i in $(seq 1 24); do sleep 5; docker exec $UE ping -I oaitun_ue1 -c 1 -W 2 192.168.70.135 >/dev/null 2>&1 && break; done
  sleep 20
  UEIP=$(docker exec $UE ip -4 addr show oaitun_ue1 | grep -oP 'inet \K[\d.]+')
}
carga() {
  for c in $EXT $UE; do docker exec $c sysctl -qw net.ipv4.tcp_ecn=3; done
  docker exec $EXT sysctl -qw net.ipv4.tcp_congestion_control=cubic
  docker exec $UE pkill -x iperf >/dev/null 2>&1; sleep 1; docker exec -d $UE iperf -s -p 5002 -B $UEIP; sleep 2
  docker exec $EXT iperf -c $UEIP -p 5002 -t 30 -e -i 30 2>&1 | grep -E "^\[ *1\] 0\.0+-3[0-9]" | tail -1 | grep -oE "[0-9.]+ Mbits/sec" | tr '\n' ' '
}
for ronda in 1 2; do
  for V in vanilla v2; do
    B=$R/nr-softmodem-vanilla; [ $V = v2 ] && B=$R/nr-softmodem-tfg.v2
    lanzar $B
    T0=$(date +%s); G="$(carga); $(carga)"
    RT=$(docker logs --since $T0 $GNB 2>&1 | grep "RT pacing" | sed -E 's/.*bloques=([0-9]+) tarde\(>1ms\)=([0-9]+).*max_retraso=([0-9.]+) ms reanclajes=([0-9]+) dormido=([0-9.]+)%.*/\1 \2 \3 \4 \5/' | \
      awk '{b+=$1; t+=$2; if($3>m)m=$3; r+=$4; if(d==""||$5<d)d=$5} END{printf "%5.2f%% tarde | retraso max %5.1f ms | %d reancl. | dormido min %s%%", (b?100*t/b:0), m, r, d}')
    printf "ronda %d  %-7s  %s | %s\n" $ronda $V "$RT" "$G"
  done
done
echo "cpuset final: gNB=$(docker inspect -f '{{.HostConfig.CpusetCpus}}' $GNB) UE=$(docker inspect -f '{{.HostConfig.CpusetCpus}}' $UE) UPF=$(docker inspect -f '{{.HostConfig.CpusetCpus}}' oai-upf)"
docker exec $EXT sysctl -qw net.ipv4.tcp_ecn=2; docker exec $UE sysctl -qw net.ipv4.tcp_ecn=2
docker exec $UE pkill -x iperf >/dev/null 2>&1
echo "fin (en marcha: v2, umbral 0, núcleos fijados)"
