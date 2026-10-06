#!/bin/bash
# Diagnóstico 15: comparación INTERCALADA sin parche / v2, con el steal de CPU de la VM.
set -u
D=~/oai-cn5g-fed/docker-compose; R=$D/rfsim-rt; UE=oai-nr-ue-basic; EXT=oai-ext-dn; GNB=oai-gnb-basic
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
  docker exec $EXT sysctl -qw net.ipv4.tcp_congestion_control=cubic
  docker exec $UE pkill -x iperf >/dev/null 2>&1; sleep 1; docker exec -d $UE iperf -s -p 5002 -B $UEIP; sleep 2
  docker exec $EXT iperf -c $UEIP -p 5002 -t 30 -e -i 30 2>&1 | grep -E "^\[ *1\] 0\.0+-3[0-9]" | tail -1 | grep -oE "[0-9.]+ Mbits/sec" | tr '\n' ' '
}
for ronda in 1 2 3; do
  for V in vanilla v2; do
    B=$R/nr-softmodem-vanilla; [ $V = v2 ] && B=$R/nr-softmodem-tfg.v2
    lanzar $B
    vmstat 1 75 > /tmp/vm_$V.txt &
    VP=$!
    T0=$(date +%s); G="$(carga); $(carga)"
    wait $VP 2>/dev/null
    RT=$(docker logs --since $T0 $GNB 2>&1 | grep -oE "bloques=[0-9]+ tarde\(>1ms\)=[0-9]+|reanclajes=[0-9]+" | \
      awk -F'[= ]' '/bloques/{b+=$2; t+=$4} /reanclajes/{r+=$2} END{printf "%5.2f%% tarde, %2d reancl.", (b?100*t/b:0), r}')
    ST=$(awk 'NR>3 {us+=$13; sy+=$14; st+=$17; n++} END{printf "CPU us %.0f%% sy %.0f%% steal %.1f%%", us/n, sy/n, st/n}' /tmp/vm_$V.txt)
    printf "ronda %d  %-7s  %s | %s | %s\n" $ronda $V "$RT" "$ST" "$G"
  done
done
docker exec $EXT sysctl -qw net.ipv4.tcp_ecn=2; docker exec $UE sysctl -qw net.ipv4.tcp_ecn=2
docker exec $UE pkill -x iperf >/dev/null 2>&1
echo "fin (en marcha: v2, umbral 0)"
