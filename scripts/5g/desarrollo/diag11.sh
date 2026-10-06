#!/bin/bash
# Diagnóstico 11: validación del gNB con marcado L4S en la RLC (bajada, SIN HTB ni AQM en la UPF).
UE=oai-nr-ue-basic; EXT=oai-ext-dn; GNB=oai-gnb-basic
UEIP=$(docker exec $UE ip -4 addr show oaitun_ue1 | grep -oP 'inet \K[\d.]+')
docker exec $GNB grep -aq TFG_L4S_UMBRAL_US /opt/oai-gnb/bin/nr-softmodem || { echo "ERROR: el gNB no es el parcheado"; exit 1; }
umbral() { docker exec $GNB sh -c "echo $1 > /tmp/tfg_umbral"; sleep 2; }
resumen() {
  docker exec $GNB awk -F, -v a=$(( $1 + 5000000 )) -v b=$2 '
    NR>1 && $1>=a && $1<=b { n++; q+=$7; h+=$11; if($13>mx)mx=$13; if($7>qm)qm=$7; sm+=$12*$14; sn+=$14;
      if(!f){f=1; r0=$16; m0=$21; l0=$20; d0=$17; t0=$15} r1=$16; m1=$21; l1=$20; d1=$17; t1=$15; tx=$10; u=$24 }
    END { if(!n){print "  RLC: sin muestras (¿TFG_RLC_LOG activo?)"; exit}
      printf "  RLC: muestras=%d cola_media=%.0f B (max %.0f B, limite %d B) hol_medio=%.1f ms estancia_media=%.1f ms estancia_max=%.1f ms\n", n, q/n, qm, tx, h/n/1000, (sn?sm/sn:0)/1000, mx/1000
      printf "       PDU=%d retx=%d descartes_buffer=%d paquetes_L4S=%d marcas=%d (%.1f%%) umbral=%d us\n", t1-t0, r1-r0, d1-d0, l1-l0, m1-m0, (l1>l0?100*(m1-m0)/(l1-l0):0), u }' /opt/oai-gnb/tfg_rlc.csv
}
prueba() {
  echo "#### $1   [bajada sin límite, cca=$2, umbral=$3 us]"
  umbral $3
  for c in $EXT $UE; do docker exec $c sysctl -qw net.ipv4.tcp_ecn=3; done
  docker exec $EXT sysctl -qw net.ipv4.tcp_congestion_control=$2
  docker exec $UE pkill -x iperf >/dev/null 2>&1; sleep 1; docker exec -d $UE iperf -s -p 5002 -B $UEIP; sleep 2
  T0=$(docker exec $GNB date +%s%6N)
  docker exec $EXT sh -c "iperf -c $UEIP -p 5002 -Z $2 -t 30 -e -i 10 > /tmp/ip.txt 2>&1" &
  docker exec $EXT sh -c "ping -Q 1 -c 250 -i 0.1 $UEIP | tail -1 > /tmp/pl.txt" &
  sleep 24
  echo -n "  ss   : "; docker exec $EXT ss -tin dst $UEIP:5002 | grep bytes_acked | grep -oE "\b(prague|cubic|reno)\b|cwnd:[0-9]+|\brtt:[0-9./]+|pacing_rate [0-9.]+[a-zA-Z]*|delivered_ce:[0-9]+|retrans:[0-9/]+" | tr '\n' ' '; echo
  wait; T1=$(docker exec $GNB date +%s%6N)
  echo -n "  goodput: "; docker exec $EXT sh -c 'grep -E "^\[ *1\] 0\.0+-3[0-9]" /tmp/ip.txt | tail -1'
  echo -n "  ping ECT(1): "; docker exec $EXT cat /tmp/pl.txt
  resumen $T0 $T1
}
echo "#### reposo: 10 s de ping ECT(1) con umbral 1 ms (esperado: pocas o ninguna marca)"
umbral 1000; T0=$(docker exec $GNB date +%s%6N)
docker exec $EXT ping -Q 1 -c 100 -i 0.1 $UEIP | tail -1; T1=$(docker exec $GNB date +%s%6N); resumen $((T0-5000000)) $T1
prueba A_cubic_sin_marcado   cubic  0
prueba B_prague_sin_marcado  prague 0
prueba C_prague_umbral_10ms  prague 10000
prueba D_prague_umbral_5ms   prague 5000
prueba E_prague_umbral_2ms   prague 2000
prueba F_cubic_umbral_5ms    cubic  5000
umbral 0
docker exec $EXT sysctl -qw net.ipv4.tcp_congestion_control=cubic; for c in $EXT $UE; do docker exec $c sysctl -qw net.ipv4.tcp_ecn=2; done
docker exec $UE pkill -x iperf >/dev/null 2>&1
echo "#### fin (umbral restaurado a 0)"
