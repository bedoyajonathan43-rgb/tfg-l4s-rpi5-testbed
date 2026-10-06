#!/bin/bash
# =============================================================================
# build_gnb_l4s.sh - TFG L4S: compila nr-softmodem (gNB) con el parche de marcado L4S
# y registro en la RLC, a partir del MISMO commit de OAI que la imagen en uso (1143f75).
#
# Reutiliza lo preparado para el parche de tiempo real: fuente en ~/oai-src,
# imagen de compilación ran-base:tfg y directorio build_rt.
# Resultado: ~/oai-cn5g-fed/docker-compose/rfsim-rt/nr-softmodem-tfg
# Tarda ~15-40 min la primera vez (compila todo el gNB).
# =============================================================================
set -euo pipefail
COMMIT=1143f7500e5e5a9cd258148f8429230cc2759554
SRC=~/oai-src
OUTDIR=~/oai-cn5g-fed/docker-compose/rfsim-rt
BASE_IMG=ran-base:tfg
DIR=$(cd "$(dirname "$0")" && pwd)

echo "== 1. Fuente de OAI en $COMMIT =="
[ -d "$SRC/.git" ] || { echo "ERROR: no existe $SRC (ejecuta antes build_rfsim_rt.sh)"; exit 1; }
cd "$SRC"
[ "$(git rev-parse HEAD)" = "$COMMIT" ] || git checkout --quiet "$COMMIT"
git checkout -- openair2/LAYER2/nr_rlc/nr_rlc_entity_am.c openair2/LAYER2/nr_rlc/nr_rlc_entity_am.h

echo "== 2. Parche L4S en la RLC =="
python3 "$DIR/parche_l4s_rlc.py" "$SRC"
git diff --stat

echo "== 3. Compilando nr-softmodem en $BASE_IMG =="
docker image inspect "$BASE_IMG" > /dev/null 2>&1 || { echo "ERROR: falta la imagen $BASE_IMG"; exit 1; }
docker run --rm -v "$SRC":/oai-ran -w /oai-ran "$BASE_IMG" bash -c "
  mkdir -p build_rt && cd build_rt &&
  cmake -GNinja -DCMAKE_BUILD_TYPE=RelWithDebInfo .. > cmake_l4s.log 2>&1 || { tail -30 cmake_l4s.log; exit 1; } &&
  ninja nr-softmodem 2>&1 | tail -5 &&
  chown -R $(id -u):$(id -g) /oai-ran/build_rt"

echo "== 4. Copiando y comprobando =="
mkdir -p "$OUTDIR"
cp "$SRC/build_rt/nr-softmodem" "$OUTDIR/nr-softmodem-tfg"
grep -aq "TFG_L4S_UMBRAL_US" "$OUTDIR/nr-softmodem-tfg" && echo "   OK: el binario contiene el parche." \
  || { echo "   ERROR: el binario no contiene el parche."; exit 1; }
echo "   Librerías dentro de la imagen del gNB (no debe salir 'not found'):"
docker run --rm --entrypoint ldd -v "$OUTDIR/nr-softmodem-tfg":/x oaisoftwarealliance/oai-gnb:develop /x \
  | grep -i "not found" && { echo "   ERROR: faltan librerías"; exit 1; } || echo "   OK: todas las librerías se encuentran."
sha256sum "$OUTDIR/nr-softmodem-tfg"
