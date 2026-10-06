#!/bin/bash
# =============================================================================
# build_rfsim_rt.sh  -  TFG L4S, fase 1 (tiempo real en el rfsimulator)
#
# Compila librfsimulator.so a partir del MISMO commit de OAI que la imagen
# oai-gnb:develop en uso (1143f75, 12/09/2026), con el parche TFG que anade
# un ritmo opcional en tiempo real (variable de entorno RFSIM_REALTIME=1).
#
# La compilacion se hace dentro de la imagen ran-base de OAI (Ubuntu 24.04,
# la misma base que la imagen del gNB) para que la libreria sea compatible.
# La primera vez tarda (hay que construir ran-base); despues solo segundos.
#
# Resultado: ~/oai-cn5g-fed/docker-compose/rfsim-rt/librfsimulator.so
# =============================================================================
set -euo pipefail

COMMIT=1143f7500e5e5a9cd258148f8429230cc2759554
SRC=~/oai-src
OUTDIR=~/oai-cn5g-fed/docker-compose/rfsim-rt
BASE_IMG=ran-base:tfg

echo "== 1. Codigo fuente de OAI en el commit $COMMIT =="
if [ ! -d "$SRC/.git" ]; then
  git clone https://gitlab.eurecom.fr/oai/openairinterface5g.git "$SRC" \
    || git clone https://github.com/OPENAIRINTERFACE/openairinterface5g.git "$SRC"
fi
cd "$SRC"
git cat-file -e "$COMMIT^{commit}" 2>/dev/null || git fetch --all --quiet
git checkout --quiet "$COMMIT"
git checkout -- radio/rfsimulator/simulator.cpp   # parte siempre del original

echo "== 2. Aplicando el parche de tiempo real =="
patch -p1 <<'PATCH_EOF'
--- a/radio/rfsimulator/simulator.cpp	2026-09-24 13:33:57.190525859 +0200
+++ b/radio/rfsimulator/simulator.cpp	2026-09-24 13:33:57.215953639 +0200
@@ -22,6 +22,7 @@
 #include <unistd.h>
 #include <stdbool.h>
 #include <errno.h>
+#include <time.h>
 #include <sys/epoll.h>
 #include <netdb.h>
 
@@ -1301,6 +1302,106 @@
   }
 }
 
+
+/* ======================================================================
+ * TFG L4S (J. Bedoya): ritmo opcional en tiempo real.
+ * Si la variable de entorno RFSIM_REALTIME=1 esta definida, cada bloque
+ * de muestras se entrega como pronto en el instante de reloj real que le
+ * corresponde segun su timestamp (ts / sample_rate). Asi la simulacion no
+ * puede ir por delante del tiempo real (factor de escala ~1). Si va por
+ * detras, no se espera y se contabiliza el retraso; con mas de 100 ms de
+ * retraso se re-ancla para no recuperar el tiempo con rafagas.
+ * Cada 10 s se escribe una linea "[TFG] RT pacing" en el log.
+ * ====================================================================== */
+typedef struct {
+  bool init;
+  bool enabled;
+  bool anchored;
+  struct timespec t0;
+  openair0_timestamp_t ts0;
+  uint64_t blocks;
+  uint64_t late_blocks;
+  uint64_t reanchors;
+  double max_late_ms;
+  double slept_s;
+  struct timespec last_report;
+} tfg_rt_pacer_t;
+
+static tfg_rt_pacer_t tfg_rt = {};
+
+static inline double tfg_ts_diff_s(const struct timespec &a, const struct timespec &b)
+{
+  return (double)(a.tv_sec - b.tv_sec) + (double)(a.tv_nsec - b.tv_nsec) * 1e-9;
+}
+
+static void tfg_rt_pace(double sample_rate, openair0_timestamp_t ts_end)
+{
+  if (!tfg_rt.init) {
+    const char *e = getenv("RFSIM_REALTIME");
+    tfg_rt.enabled = (e != NULL && atoi(e) == 1);
+    tfg_rt.init = true;
+    if (tfg_rt.enabled)
+      LOG_I(HW, "[TFG] RFSIM_REALTIME=1: ritmo en tiempo real activado\n");
+  }
+  if (!tfg_rt.enabled || sample_rate <= 0)
+    return;
+
+  struct timespec now;
+  clock_gettime(CLOCK_MONOTONIC, &now);
+  if (!tfg_rt.anchored) {
+    tfg_rt.t0 = now;
+    tfg_rt.ts0 = ts_end;
+    tfg_rt.last_report = now;
+    tfg_rt.anchored = true;
+    return;
+  }
+
+  const double target_s = (double)(ts_end - tfg_rt.ts0) / sample_rate;
+  const double elapsed_s = tfg_ts_diff_s(now, tfg_rt.t0);
+  tfg_rt.blocks++;
+
+  if (target_s > elapsed_s) {
+    const double whole = (double)(time_t)target_s;
+    struct timespec wake;
+    wake.tv_sec = tfg_rt.t0.tv_sec + (time_t)target_s;
+    long ns = tfg_rt.t0.tv_nsec + (long)((target_s - whole) * 1e9);
+    wake.tv_sec += ns / 1000000000L;
+    wake.tv_nsec = ns % 1000000000L;
+    tfg_rt.slept_s += target_s - elapsed_s;
+    while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &wake, NULL) == EINTR) {
+    }
+  } else {
+    const double late_ms = (elapsed_s - target_s) * 1e3;
+    if (late_ms > 1.0) {
+      tfg_rt.late_blocks++;
+      if (late_ms > tfg_rt.max_late_ms)
+        tfg_rt.max_late_ms = late_ms;
+    }
+    if (late_ms > 100.0) {
+      tfg_rt.t0 = now;
+      tfg_rt.ts0 = ts_end;
+      tfg_rt.reanchors++;
+    }
+  }
+
+  if (tfg_ts_diff_s(now, tfg_rt.last_report) >= 10.0) {
+    const double win_s = tfg_ts_diff_s(now, tfg_rt.last_report);
+    LOG_I(HW,
+          "[TFG] RT pacing: bloques=%lu tarde(>1ms)=%lu (%.2f%%) max_retraso=%.1f ms reanclajes=%lu dormido=%.1f%%\n",
+          (unsigned long)tfg_rt.blocks,
+          (unsigned long)tfg_rt.late_blocks,
+          tfg_rt.blocks ? 100.0 * tfg_rt.late_blocks / tfg_rt.blocks : 0.0,
+          tfg_rt.max_late_ms,
+          (unsigned long)tfg_rt.reanchors,
+          win_s > 0 ? 100.0 * tfg_rt.slept_s / win_s : 0.0);
+    tfg_rt.blocks = tfg_rt.late_blocks = tfg_rt.reanchors = 0;
+    tfg_rt.max_late_ms = 0;
+    tfg_rt.slept_s = 0;
+    tfg_rt.last_report = now;
+  }
+}
+/* ================== fin del bloque TFG ================== */
+
 static int rfsimulator_read(openair0_device_t *device, openair0_timestamp_t *ptimestamp, void **samplesVoid, int nsamps, int nbAnt)
 {
   rfsimulator_state_t *t = static_cast<rfsimulator_state_t *>(device->priv);
@@ -1332,6 +1433,7 @@
       if (((t->nextRxTstamp / nsamps) % 100) == 0)
         LOG_D(HW, "No UE, Generating void samples for Rx: %ld\n", t->nextRxTstamp);
 
+      tfg_rt_pace(t->sample_rate, t->nextRxTstamp); // TFG: tiempo real
       *ptimestamp = t->nextRxTstamp - nsamps;
       return nsamps;
     }
@@ -1358,6 +1460,8 @@
     } while (have_to_wait);
   }
 
+  tfg_rt_pace(t->sample_rate, t->nextRxTstamp + nsamps); // TFG: tiempo real
+
   struct timespec start_time;
   int ret = clock_gettime(CLOCK_REALTIME, &start_time);
   AssertFatal(ret == 0, "clock_gettime() failed: errno %d, %s\n", errno, strerror(errno));
PATCH_EOF
grep -q "tfg_rt_pace" radio/rfsimulator/simulator.cpp && echo "   Parche aplicado."

echo "== 3. Imagen de compilacion ($BASE_IMG) =="
if ! docker image inspect "$BASE_IMG" >/dev/null 2>&1; then
  echo "   No existe: se construye ahora (la primera vez tarda bastante)..."
  docker build --target ran-base -t "$BASE_IMG" -f docker/Dockerfile.base.ubuntu .
fi

echo "== 4. Compilando solo la libreria rfsimulator =="
docker run --rm -v "$SRC":/oai-ran -w /oai-ran "$BASE_IMG" bash -c "
  mkdir -p build_rt && cd build_rt &&
  cmake -GNinja -DCMAKE_BUILD_TYPE=RelWithDebInfo .. > cmake.log 2>&1 || { tail -30 cmake.log; exit 1; } &&
  ninja rfsimulator &&
  chown -R $(id -u):$(id -g) /oai-ran/build_rt"

echo "== 5. Copiando la libreria =="
mkdir -p "$OUTDIR"
cp "$SRC/build_rt/librfsimulator.so" "$OUTDIR/"
if strings "$OUTDIR/librfsimulator.so" | grep -q "RFSIM_REALTIME"; then
  echo "   OK: $OUTDIR/librfsimulator.so contiene el parche TFG."
else
  echo "   ERROR: la libreria no contiene el parche."; exit 1
fi
sha256sum "$OUTDIR/librfsimulator.so"
