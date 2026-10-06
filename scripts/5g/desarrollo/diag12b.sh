#!/bin/bash
# Diagnóstico 12: A/B gNB ORIGINAL frente a PARCHEADO (umbral 0, registro activo), bajada sin límite.
D=~/oai-cn5g-fed/docker-compose; UE=oai-nr-ue-basic; EXT=oai-ext-dn; GNB=oai-gnb-basic
lanzar() {
  cd $D && docker compose -f docker-compose-oai-rfsim-basic.yaml down >/dev/null 2>&1
  docker compose -f "$1" down >/dev/null 2>&1
  RFSIM_REALTIME=1 docker compose -f "$1" up -d >/dev/null 2>&1; cd - >/dev/null
  for i in $(seq 1 24); do sleep 5; docker exec $UE ping -I oaitun_ue1 -c 1 -W 2 192.168.70.135 >/dev/null 2>&1 && break; done
  sleep 20
  UEIP=$(docker exec $UE ip -4 addr show oaitun_ue1 | grep -oP 'inet \K[\d.]+')
}
prueba() {
  for c in $EXT $UE; do docker exec $c sysctl -qw net.ipv4.tcp_ecn=3; done
  docker exec $EXT sysctl -qw net.ipv4.tcp_congestion_control=$1
  docker exec $UE pkill -x iperf >/dev/null 2>&1; sleep 1; docker exec -d $UE iperf -s -p 5002 -B $UEIP; sleep 2
  docker exec $EXT sh -c "iperf -c $UEIP -p 5002 -Z $1 -t 30 -e -i 10 > /tmp/ip.txt 2>&1" &
  docker exec $EXT sh -c "ping -Q 0 -c 250 -i 0.1 $UEIP | tail -1 > /tmp/pc.txt" &
  sleep 24
  S=$(docker exec $EXT ss -tin dst $UEIP:5002 | grep bytes_acked | grep -oE "\brtt:[0-9.]+|rwnd_limited:[0-9a-z]+\([0-9.]+%\)|cwnd:[0-9]+" | tr '\n' ' ')
  wait
  G=$(docker exec $EXT sh -c 'grep -E "^\[ *1\] 0\.0+-3[0-9]" /tmp/ip.txt | tail -1' | grep -oE "[0-9.]+ Mbits/sec")
  P=$(docker exec $EXT cat /tmp/pc.txt | grep -oE "= [0-9.]+/[0-9.]+" | cut -d/ -f2)
  printf "  %-7s goodput=%-14s ping_medio=%-8s ms  %s\n" "$1" "$G" "$P" "$S"
}
for V in parcheado; do
  F=docker-compose-oai-rfsim-basic.yaml; [ $V = original ] && F=docker-compose-oai-rfsim-basic.yaml.antes_l4s
  echo "######## gNB $V ($F)"; lanzar $F
  docker exec $GNB grep -aq TFG_L4S_UMBRAL_US /opt/oai-gnb/bin/nr-softmodem && echo "  binario: parcheado" || echo "  binario: original"
  T0=$(date +%s)
  for r in 1 2 3; do echo " rep $r"; prueba cubic; prueba prague; done
  echo -n "  tiempo real durante las pruebas: "
  docker logs --since $T0 $GNB 2>&1 | grep -oE "bloques=[0-9]+ tarde\(>1ms\)=[0-9]+|reanclajes=[0-9]+" | \
    awk -F'[= ]' '/bloques/{b+=$2; t+=$4} /reanclajes/{r+=$2} END{printf "%.2f%% bloques tarde, %d reanclajes\n", (b?100*t/b:0), r}'
done
docker exec $EXT sysctl -qw net.ipv4.tcp_congestion_control=cubic; for c in $EXT $UE; do docker exec $c sysctl -qw net.ipv4.tcp_ecn=2; done
docker exec $UE pkill -x iperf >/dev/null 2>&1
echo "######## fin (queda en marcha el gNB parcheado, umbral 0)"
