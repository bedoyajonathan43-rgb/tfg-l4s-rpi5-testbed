#!/bin/bash
DIRA=$(cd "$(dirname "$0")" && pwd)
# TFG L4S - retardo por tramos: capturas en servidor, UPF y UE durante una campaña corta.
ET=${1:?falta la etiqueta, por ejemplo: 40mhz}
DIRC=~/tfg-l4s-rpi5-testbed/scripts/5g/campanas
CAP=~/capas_$ET
IMG=oaisoftwarealliance/trf-gen-cn5g:latest
CPUS=${CPUSET_RESTO_RT:-16-31}
RUIDO=${RUIDO_CAPAS:-}
[[ "${RAN_COMPOSE:-}" == *24prb* ]] && [ -z "$RUIDO" ] && RUIDO=-50
[ -e "$CAP" ] || [ -e ~/campanas_oai/capas_$ET ] && { echo "Ya existe capas_$ET: usa otra etiqueta"; exit 1; }
mkdir -p "$CAP" && chmod 777 "$CAP"
exec > "$CAP/diag18.log" 2>&1
cd "$DIRC" || exit 1
C="caso,modo,dir,cca,punto,rate,qdisc,ruido,umbral"
{ echo "$C"; echo "pre_prague_marcado,rt,downlink,prague,ninguno,0,ninguno,$RUIDO,10000"; } > capas_${ET}_pre.csv
{ echo "$C"
  echo "capas_prague_marcado,rt,downlink,prague,ninguno,0,ninguno,$RUIDO,10000"
  echo "capas_cubic,rt,downlink,cubic,ninguno,0,ninguno,$RUIDO,0"
  echo "capas_prague_sinmarcado,rt,downlink,prague,ninguno,0,ninguno,$RUIDO,0"; } > capas_$ET.csv

echo "[$(date '+%F %T')] 1/4 prueba previa (deja la red en la celda y el modo correctos)"
./campana_oai.sh capas_${ET}_pre.csv 1 > /dev/null 2>&1
tail -3 ~/campanas_oai/capas_${ET}_pre/campana.log

echo "[$(date '+%F %T')] 2/4 arranque de las capturas"
docker rm -f cap-ext cap-upf cap-ue > /dev/null 2>&1
captura() {
  docker run -d --rm --name "$1" --net "container:$2" --cap-add NET_ADMIN --cap-add NET_RAW --cpuset-cpus "$CPUS" \
    -v "$CAP":/cap --entrypoint tcpdump "$IMG" -Z root -n -p -U -i "$3" -s 160 -w "/cap/$4" $5 > /dev/null
}
captura cap-ext oai-ext-dn       eth0       a.pcap "icmp"
captura cap-upf oai-upf          eth0       b.pcap "icmp or (udp port 2152 and greater 126 and less 160)"
captura cap-ue  oai-nr-ue-basic  oaitun_ue1 c.pcap "icmp"
sleep 5
docker ps --format '{{.Names}} {{.Status}}' | grep '^cap-'
[ "$(docker ps --format '{{.Names}}' | grep -c '^cap-')" = 3 ] || { echo "ERROR: no han arrancado las tres capturas"; docker rm -f cap-ext cap-upf cap-ue > /dev/null 2>&1; exit 1; }
arranque() { for c in oai-ext-dn oai-upf oai-gnb-basic oai-nr-ue-basic; do docker inspect -f '{{.Name}} {{.State.StartedAt}}' $c; done; }
arranque > "$CAP/arranque_antes.txt"

echo "[$(date '+%F %T')] 3/4 campaña con capturas (9 pruebas, unos 20 minutos)"
./campana_oai.sh capas_$ET.csv 3 > /dev/null 2>&1
grep -c "   valida" ~/campanas_oai/capas_$ET/campana.log
grep "NO valida" ~/campanas_oai/capas_$ET/campana.log
arranque > "$CAP/arranque_despues.txt"
docker stop -t 5 cap-ext cap-upf cap-ue > /dev/null 2>&1
if cmp -s "$CAP/arranque_antes.txt" "$CAP/arranque_despues.txt"; then echo "La red no se ha reiniciado durante las capturas: correcto"
else echo "AVISO: la red se reinicio durante las capturas; faltaran pings a partir de ese momento"; fi
ls -l "$CAP"/*.pcap

echo "[$(date '+%F %T')] 4/4 analisis"
python3 "$DIRA/retardo_tramos.py" "$CAP" ~/campanas_oai/capas_$ET 20
python3 ./resumen_campana.py ~/campanas_oai/capas_$ET 20
echo "[$(date '+%F %T')] FIN"
