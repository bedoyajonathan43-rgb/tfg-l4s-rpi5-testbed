#!/bin/bash
UE=oai-nr-ue-basic; EXT=oai-ext-dn; GNB=oai-gnb-basic
RESTO="oai-upf oai-ext-dn oai-smf oai-amf oai-nrf oai-udm oai-udr oai-ausf mysql"
cd ~/tfg-l4s-rpi5-testbed/scripts/5g/campanas || exit 1
UEIP=$(docker exec $UE ip -4 addr show oaitun_ue1 2>/dev/null | grep -oP 'inet \K[\d.]+')
[ -n "$UEIP" ] || { echo "ERROR: la UE no tiene IP (red parada). No se hace nada."; exit 1; }
./ruido.sh ambos -50 > /dev/null 2>&1
echo "UE: $(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' $UE | grep -i 'OPTIONS' | cut -c1-160)"
fijar() {
  docker update --cpuset-cpus "$1" $GNB > /dev/null; docker update --cpuset-cpus "$2" $UE > /dev/null
  for c in $RESTO; do docker update --cpuset-cpus "$3" $c > /dev/null 2>&1; done
}
rt() {
  docker logs --since "$1" $GNB 2>&1 | grep "RT pacing" | sed -E 's/.*bloques=([0-9]+) tarde\(>1ms\)=([0-9]+).*max_retraso=([0-9.]+) ms reanclajes=([0-9]+) dormido=([0-9.]+)%.*/\1 \2 \3 \4 \5/' | \
    awk '{b+=$1; t+=$2; if($3>m)m=$3; r+=$4; d+=$5; n++} END{printf "%5.2f%% tarde, max %5.1f ms, %d reancl., dormido %2.0f%%, %d bloques/10 s", (b?100*t/b:0), m, r, (n?d/n:0), (n?b/n:0)}'
}
hilos() {
  LC_ALL=C top -H -b -n 2 -d 4 -p "$(pgrep -x nr-softmodem | head -1),$(pgrep -x nr-uesoftmodem | head -1)" 2>/dev/null | \
    awk '/^top -/{n++} n==2 && $1 ~ /^[0-9]+$/ {printf "%s %s\n", $9, $NF}' | sort -nr | head -6 | awk '{printf "%s(%s%%) ", $2, $1}'
}
prueba() {
  fijar "$2" "$3" "$4"; sleep 15
  local T0 T1 R0 R1 H G
  T0=$(date +%s); sleep 22; R0=$(rt $T0)
  docker exec $EXT sysctl -qw net.ipv4.tcp_congestion_control=cubic net.ipv4.tcp_ecn=2
  docker exec $UE pkill -x iperf > /dev/null 2>&1; sleep 1; docker exec -d $UE iperf -s -p 5002 -B $UEIP; sleep 2
  T1=$(date +%s)
  docker exec $EXT iperf -c $UEIP -p 5002 -Z cubic -t 32 -e -i 32 > /tmp/d17.txt 2>&1 &
  sleep 12; H=$(hilos); wait
  G=$(grep -E "^\[ *1\] 0\.0+-3[0-9]" /tmp/d17.txt | tail -1 | grep -oE "[0-9.]+ Mbits/sec")
  R1=$(rt $T1)
  echo "## $1  (gNB $2 | UE $3 | resto $4)"
  echo "   reposo : $R0"
  echo "   carga  : $R1 | $G"
  echo "   hilos  : $H"
}
prueba "A actual"            0-7  8-15  16-31
prueba "B sin fijar"         0-31 0-31  0-31
prueba "C un nodo cada uno"  0-15 16-31 0-31
prueba "D mas nucleos a UE"  0-3  4-15  16-31
fijar 0-7 8-15 16-31
docker exec $UE pkill -x iperf > /dev/null 2>&1
echo "fin (queda el reparto A)"
