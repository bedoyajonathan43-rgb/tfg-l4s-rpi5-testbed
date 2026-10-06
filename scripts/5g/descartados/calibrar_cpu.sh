#!/bin/bash
# =============================================================================
# calibrar_cpu.sh - TFG L4S, fase 1 (ajuste grueso por CPU)
# Con la red en modo SIN ritmo (RFSIM_REALTIME=0), limita la CPU del gNB y de
# la UE y mide durante 60 s el factor de escala (tiempo real / simulado).
# Cada valor de la lista puede ser:
#   N      -> N núcleos enteros por contenedor (gNB 0..N-1, UE N..2N-1)
#   0.X    -> 1 núcleo por contenedor (gNB en 0, UE en 1) con cuota de CPU 0.X
# Uso: ./calibrar_cpu.sh "8 4 2 1 0.8 0.6 0.5 0.4"
# =============================================================================
set -uo pipefail
GNB=oai-gnb-basic; UE=oai-nr-ue-basic
LISTA="${1:-8 4 2 1 0.8 0.6 0.5 0.4}"
NCPU=$(nproc)
OUT=~/campanas_oai/calibracion_cpu_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
[ "$(docker exec $GNB printenv RFSIM_REALTIME 2>/dev/null)" = "1" ] && {
  echo "La red está en modo tiempo real. Relánzala con RFSIM_REALTIME=0 antes de calibrar."; exit 1; }
printf "%-8s %-8s %-8s %-7s %-8s %-8s %-8s %-6s\n" "valor" "gNB" "UE" "cuota" "mediana" "p10" "p90" "UE_ok" | tee "$OUT/resultado.txt"
for v in $LISTA; do
  if [[ "$v" == *.* ]]; then G=0; U=1; Q=$v; else G="0-$((v-1))"; U="$v-$((2*v-1))"; Q=0; fi
  docker update --cpuset-cpus "$G" --cpus "$Q" $GNB > /dev/null
  docker update --cpuset-cpus "$U" --cpus "$Q" $UE > /dev/null
  sleep 15
  T0=$(date +%s); sleep 60; T1=$(date +%s)
  docker logs --since "$T0" --until "$T1" $UE > "$OUT/ue_${v}.log" 2>&1
  F=$(python3 - "$OUT/ue_${v}.log" <<'PY'
import re, sys, statistics
e = []
for l in open(sys.argv[1], errors='ignore'):
    m = re.match(r'^\s*(\d+\.\d+)\s+\[NR_MAC\].*stats sfn:\s*(\d+)\.', l)
    if m: e.append((float(m.group(1)), int(m.group(2))))
f = []
for (t0, s0), (t1, s1) in zip(e, e[1:]):
    d = s1 - s0 + (1024 if s1 <= s0 else 0)
    if t1 > t0: f.append((t1 - t0) / (d * 0.01))
if len(f) >= 3:
    f.sort(); p = lambda q: f[int(q * (len(f) - 1))]
    print(f"{statistics.median(f):.2f} {p(0.1):.2f} {p(0.9):.2f}")
else:
    print("sin_datos - -")
PY
)
  OK=no; docker exec $UE ping -I oaitun_ue1 -c 3 -W 2 192.168.70.135 > /dev/null 2>&1 && OK=si
  read -r MED P10 P90 <<< "$F"
  printf "%-8s %-8s %-8s %-7s %-8s %-8s %-8s %-6s\n" "$v" "$G" "$U" "$Q" "$MED" "$P10" "$P90" "$OK" | tee -a "$OUT/resultado.txt"
  [ "$OK" = "no" ] && { echo "La UE ha dejado de responder: se para aquí (reinicia la red)."; break; }
done
docker update --cpuset-cpus "0-$((NCPU-1))" --cpus 0 $GNB $UE > /dev/null
echo "CPUs restauradas. Resultados en $OUT/resultado.txt"
