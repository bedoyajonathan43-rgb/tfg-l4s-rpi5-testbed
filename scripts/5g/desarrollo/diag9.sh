#!/bin/bash
# Diagnóstico 9 (OAI/5G, SUBIDA): ¿por qué Prague solo saca ~4,9 de 20 Mbit/s en subida?
# H1: límite en la radio/UE (concesiones de subida) -> Prague sin AQM también saldría bajo.
# H2: ráfagas de la radio + umbral step 1 ms del dualpi2 -> con step 5 ms Prague subiría.
# 4 pruebas de 30 s (~4 min). Restaura todo al final.
UPF=oai-upf; UE=oai-nr-ue-basic; EXT=oai-ext-dn; GNB=oai-gnb-basic; EXT_IP=192.168.70.135
UEIP=$(docker exec $UE ip -4 addr show oaitun_ue1 | grep -oP 'inet \K[\d.]+')
docker rm -f tc-adm >/dev/null 2>&1
docker run -d --name tc-adm --cap-add NET_ADMIN --net container:$UPF tc-l4s:img sleep infinity >/dev/null
for c in $EXT $UE; do docker exec $c sysctl -qw net.ipv4.tcp_ecn=3; done
aqm() {
  docker exec $UPF tc qdisc del dev eth0 root 2>/dev/null
  [ "$1" = sinlim ] && return
  docker exec $UPF sh -c 'tc qdisc add dev eth0 root handle 1: htb default 1 r2q 100 && tc class add dev eth0 parent 1: classid 1:1 htb rate 20mbit ceil 20mbit'
  docker exec tc-adm tc qdisc add dev eth0 parent 1:1 handle 10: dualpi2 step_thresh ${2}ms || echo "ERROR: no se pudo poner dualpi2"
}
prueba() {
  echo "#### $1   [subida cca=$2 aqm=$3 step=${4}ms]"
  aqm $3 $4
  docker exec $UE sysctl -qw net.ipv4.tcp_congestion_control=$2
  docker exec $EXT pkill -x iperf >/dev/null 2>&1; sleep 1; docker exec -d $EXT iperf -s -p 5001
  sleep 2
  docker exec $UE sh -c "iperf -c $EXT_IP -p 5001 -B $UEIP -Z $2 -t 30 -e -i 10 > /tmp/ip.txt 2>&1" &
  sleep 22
  echo -n "  ss UE : "; docker exec $UE ss -tin dst $EXT_IP:5001 | grep -E "bytes_acked" | grep -oE "\b(prague|cubic|reno)\b|cwnd:[0-9]+|\brtt:[0-9./]+|pacing_rate [0-9.]+[a-zA-Z]*|delivery_rate [0-9.]+[a-zA-Z]*|delivered_ce:[0-9]+|retrans:[0-9/]+|notsent:[0-9]+|unacked:[0-9]+" | tr '\n' ' '; echo
  [ "$3" != sinlim ] && { echo -n "  AQM  : "; docker exec tc-adm tc -s qdisc show dev eth0 | grep -E "delay_c|ecn_mark|pkts_in|step_marks" | tr '\n' ' '; echo; }
  echo -n "  radio: "; docker exec $GNB grep -m1 -E "ulsch_rounds" /opt/oai-gnb/nrMAC_stats.log | tr -s ' '
  echo -n "        "; docker exec $GNB grep -m1 -E "ULSCH|ulsch_total_bytes|UL-SCH" /opt/oai-gnb/nrMAC_stats.log | tr -s ' '
  wait
  echo -n "  goodput: "; docker exec $UE sh -c 'grep -E "^\[ *[0-9]+\] 0\.0+-3[0-9]" /tmp/ip.txt | tail -1'
}
prueba A_cubic_sinlim   cubic  sinlim 1
prueba B_prague_sinlim  prague sinlim 1
prueba C_prague_step1   prague 20     1
prueba D_prague_step5   prague 20     5
docker exec $UPF tc qdisc del dev eth0 root 2>/dev/null
docker exec $UE sysctl -qw net.ipv4.tcp_congestion_control=cubic; for c in $EXT $UE; do docker exec $c sysctl -qw net.ipv4.tcp_ecn=2; done
docker exec $EXT pkill -x iperf >/dev/null 2>&1; docker rm -f tc-adm >/dev/null 2>&1
echo "#### fin (todo restaurado)"
