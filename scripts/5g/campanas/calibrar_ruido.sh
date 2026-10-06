#!/bin/bash
# =============================================================================
# calibrar_ruido.sh - TFG L4S, fase 4: calibración de los niveles de ruido.
# Mide UN sentido cada vez, con ruido solo en ese sentido (el otro a -50 dB):
#   - fija el ruido, espera 15 s (adaptación de MCS / control de potencia),
#   - 30 s de Cubic sin límite en ese sentido,
#   - recoge SINR/MCS/BLER solo del intervalo de esa medida, goodput y pacing.
# Se detiene si la UE deja de responder. Al final deja el ruido en -50 dB.
# Uso: ./calibrar_ruido.sh dl "-50 -8 -6 -4 -2"
#      ./calibrar_ruido.sh ul "-50 0 2 4 6 8 10"
# Requiere modo rt y chanmod+telnet activos en gNB y UE (RUIDO_OPTS_GNB / RUIDO_OPTS_UE).
# =============================================================================
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
GNB=oai-gnb-basic; UE=oai-nr-ue-basic; EXTDN=oai-ext-dn; EXT_IP=192.168.70.135
S="${1:-}"; LISTA="${2:-}"
[[ "$S" =~ ^(dl|ul)$ && -n "$LISTA" ]] || { sed -n '2,11p' "$0"; exit 1; }
OTRO=ul; [ "$S" = ul ] && OTRO=dl
OUT=~/campanas_oai/calibracion_ruido_${S}_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
UEIP=$(docker exec $UE ip -4 addr show oaitun_ue1 | grep -oP 'inet \K[\d.]+')

medir() {  # $1 fichero salida
  if [ "$S" = dl ]; then
    docker exec $UE pkill -f "iperf -s" >/dev/null 2>&1; sleep 1
    docker exec $UE sh -c "iperf -s -p 5002 -B $UEIP" > "$1.srv" 2>&1 & local P=$!; sleep 2
    docker exec $EXTDN timeout 45 iperf -c $UEIP -p 5002 --tcp-cca cubic -t 30 > "$1" 2>&1
    docker exec $UE pkill -f "iperf -s" >/dev/null 2>&1; wait $P 2>/dev/null
  else
    docker exec $EXTDN pkill -f "iperf -s" >/dev/null 2>&1; sleep 1
    docker exec $EXTDN sh -c "iperf -s -p 5001" > "$1.srv" 2>&1 & local P=$!; sleep 2
    docker exec $UE timeout 45 iperf -c $EXT_IP -p 5001 -B $UEIP --tcp-cca cubic -t 30 > "$1" 2>&1
    docker exec $EXTDN pkill -f "iperf -s" >/dev/null 2>&1; wait $P 2>/dev/null
  fi
}

"$DIR/ruido.sh" $OTRO -50 > /dev/null 2>&1
printf "%-8s %-4s %-8s %-7s %-8s %-10s %-7s %-6s\n" ruido_dB dir SNR_dB MCS BLER goodput tarde% UE_ok | tee "$OUT/resultado.txt"
for n in $LISTA; do
  "$DIR/ruido.sh" $S "$n" > "$OUT/ruido_${n}.txt" 2>&1
  sleep 15
  T0=$(date +%s)
  medir "$OUT/iperf_${n}.txt"
  T1=$(date +%s)
  docker logs --since "$T0" --until "$T1" $GNB > "$OUT/gnb_${n}.log" 2>&1
  docker logs --since "$T0" --until "$T1" $UE  > "$OUT/ue_${n}.log"  2>&1
  OK=no; docker exec $UE ping -I oaitun_ue1 -c 3 -W 2 $EXT_IP >/dev/null 2>&1 && OK=si
  python3 - "$OUT" "$n" "$OK" "$S" <<'PY' | tee -a "$OUT/resultado.txt"
import re, sys, statistics as st
o, n, ok, s = sys.argv[1:5]
def mean(v, d=1): return f"{st.mean(v):.{d}f}" if v else "-"
ue = open(f"{o}/ue_{n}.log", errors="ignore").read(); g = open(f"{o}/gnb_{n}.log", errors="ignore").read()
if s == "dl":
    snr = [float(x) for x in re.findall(r"SINR ([-\d.]+) dB", ue)]
    mcs = [int(x) for x in re.findall(r"dlsch_rounds.*?MCS \(\d+\) (\d+)", g)]
    bl  = [float(x) for x in re.findall(r"dlsch_rounds.*?BLER ([\d.]+)", g)]
else:
    snr = [float(x) for x in re.findall(r"ulsch_rounds.*?SNR ([-\d.]+)", g)]
    mcs = [int(x) for x in re.findall(r"ulsch_rounds.*?MCS \(\d+\) (\d+)", g)]
    bl  = [float(x) for x in re.findall(r"ulsch_rounds.*?BLER ([\d.]+)", g)]
pac = re.findall(r"RT pacing: bloques=(\d+) tarde\(>1ms\)=(\d+)", g)
b = sum(int(x) for x, _ in pac); t = sum(int(y) for _, y in pac)
def gp(f):  # solo informes de más de 20 s (descarta conexiones rotas)
    try:
        best = None
        for a, e, x, u in re.findall(r"\s([\d.]+)-\s*([\d.]+)\s+sec\s+[\d.]+\s+\w?Bytes\s+([\d.]+)\s+(\w?)bits/sec", open(f, errors="ignore").read()):
            if float(a) == 0 and float(e) >= 20: best = float(x) * {'': 1e-6, 'K': 1e-3, 'M': 1, 'G': 1e3}[u]
        return f"{best:.2f}" if best is not None else "fallo"
    except OSError: return "fallo"
print(f"{n:<8} {s:<4} {mean(snr):<8} {mean(mcs):<7} {mean(bl, 3):<8} {gp(f'{o}/iperf_{n}.txt.srv'):<10} {(100*t/b if b else 0):<7.2f} {ok:<6}")
PY
  [ "$OK" = no ] && { echo "La UE ha dejado de responder con ruido $n dB: se para aquí."; break; }
done
"$DIR/ruido.sh" $S -50 > /dev/null 2>&1
echo "Ruido restaurado a -50 dB. Resultados en $OUT/resultado.txt"
