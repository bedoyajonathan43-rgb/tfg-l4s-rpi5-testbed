#!/usr/bin/env python3
# actualizar_campana.py - TFG L4S: adapta campana_oai.sh y resumen_campana.py al gNB con marcado L4S (v2).
import sys, os, shutil

d = sys.argv[1] if len(sys.argv) > 1 else '.'
S = os.path.join(d, 'campana_oai.sh')
R = os.path.join(d, 'resumen_campana.py')


def sust(txt, viejo, nuevo, nombre):
    n = txt.count(viejo)
    if n != 1:
        sys.exit(f'ERROR: ancla "{nombre}" aparece {n} veces (se esperaba 1). No se ha cambiado nada.')
    return txt.replace(viejo, nuevo)


s = open(S).read()
r = open(R).read()
if 'tfg_umbral' in s or 'leer_rlc' in r:
    sys.exit('Ya estaba actualizado: no se cambia nada.')

# ---- campana_oai.sh ----
s = sust(s, "print('n,caso,modo,dir,cca,punto,rate,qdisc,rep,ruido')",
         "print('n,caso,modo,dir,cca,punto,rate,qdisc,rep,ruido,umbral')", 'cabecera del plan')
s = sust(s, "{r},{(c.get('ruido') or '').strip()}\")",
         "{r},{(c.get('ruido') or '').strip()},{(c.get('umbral') or '').strip()}\")", 'fila del plan')
s = sust(s, 'while IFS=, read -r -u 3 N CASO MODO DIR CCA PUNTO RATE QD REP RUIDO_CASO; do',
         'while IFS=, read -r -u 3 N CASO MODO DIR CCA PUNTO RATE QD REP RUIDO_CASO UMBRAL_CASO; do', 'lectura del plan')
s = sust(s, '"$MODO" "${RUIDO_CASO:-}" < /dev/null', '"$MODO" "${RUIDO_CASO:-}" "${UMBRAL_CASO:-}" < /dev/null', 'llamada a ejecutar_prueba')
s = sust(s, '  local OUT=$1 DIR=$2 CCA=$3 PUNTO=$4 RATE=$5 QD=$6 MODO=$7 RUIDO="${8:-${RUIDO_DB:-}}"\n',
         '  local OUT=$1 DIR=$2 CCA=$3 PUNTO=$4 RATE=$5 QD=$6 MODO=$7 RUIDO="${8:-${RUIDO_DB:-}}"\n'
         '  local UMBRAL="${9:-}"; UMBRAL=$(echo "${UMBRAL:-0}" | tr -dc "0-9"); [ -z "$UMBRAL" ] && UMBRAL=0\n', 'argumentos de ejecutar_prueba')
s = sust(s, '  aplicar_aqm "$PUNTO" "$RATE" "$QD" || { echo "fallo_aqm" > "$OUT/motivo"; return 1; }\n',
         '  aplicar_aqm "$PUNTO" "$RATE" "$QD" || { echo "fallo_aqm" > "$OUT/motivo"; return 1; }\n'
         '  # umbral de marcado L4S del gNB (parche TFG v2): se cambia en caliente; 0 = sin marcado\n'
         '  local GNB_L4S=no; docker exec "$GNB" grep -aq "L4S v2" /opt/oai-gnb/bin/nr-softmodem 2> /dev/null && GNB_L4S=si\n'
         '  if [ "$GNB_L4S" = si ]; then\n'
         '    docker exec "$GNB" sh -c "echo $UMBRAL > /tmp/tfg_umbral"; sleep 2\n'
         '  elif [ "$UMBRAL" != 0 ]; then\n'
         '    echo "gnb_sin_parche_l4s" > "$OUT/motivo"; return 1\n'
         '  fi\n', 'aplicar_aqm')
s = sust(s, '    echo "ruido_dB=${RUIDO:-ninguno}"\n',
         '    echo "ruido_dB=${RUIDO:-ninguno}"\n    echo "umbral_us=$UMBRAL"; echo "gnb_parche_l4s=$GNB_L4S"\n', 'meta ruido')
s = sust(s, '  local T0; T0=$(date +%s)\n',
         '  local T0; T0=$(date +%s)\n  local T0US; T0US=$(docker exec "$GNB" date +%s%6N)\n', 'T0')
s = sust(s, '  local T1; T1=$(date +%s)\n',
         '  local T1; T1=$(date +%s)\n'
         '  # tramo del registro RLC del gNB correspondiente a esta prueba (parche TFG v2)\n'
         '  if [ "$GNB_L4S" = si ]; then\n'
         '    docker exec "$GNB" awk -F, -v a="$T0US" -v b="$(docker exec "$GNB" date +%s%6N)" \'NR==1 || ($1>=a && $1<=b)\' /opt/oai-gnb/tfg_rlc.csv > "$OUT/rlc.csv" 2> /dev/null\n'
         '  fi\n', 'T1')
s = sust(s, '    docker update --cpuset-cpus "$all" --cpus 0 "$GNB" "$UE" > /dev/null\n',
         '    # núcleos fijos: gNB y UE en el mismo nodo NUMA; núcleo 5G y servidor en el otro (FIJAR_NUCLEOS=0 lo desactiva)\n'
         '    if [ "${FIJAR_NUCLEOS:-1}" = 1 ] && [ "$NCPU" -ge 32 ]; then\n'
         '      if [ "$(docker inspect -f \'{{.HostConfig.CpusetCpus}}\' "$GNB")" != "${CPUSET_GNB_RT:-0-7}" ]; then\n'
         '        docker update --cpuset-cpus "${CPUSET_GNB_RT:-0-7}" --cpus 0 "$GNB" > /dev/null\n'
         '        docker update --cpuset-cpus "${CPUSET_UE_RT:-8-15}" --cpus 0 "$UE" > /dev/null\n'
         '        for c in "$UPF" "$EXTDN" oai-smf oai-amf oai-nrf oai-udm oai-udr oai-ausf mysql; do\n'
         '          docker update --cpuset-cpus "${CPUSET_RESTO_RT:-16-31}" "$c" > /dev/null 2>&1\n'
         '        done\n'
         '      fi\n'
         '    else\n'
         '      docker update --cpuset-cpus "$all" --cpus 0 "$GNB" "$UE" > /dev/null\n'
         '    fi\n', 'cpuset modo rt')

# ---- resumen_campana.py ----
r = sust(r, "def factor_desde_log(path):", '''def leer_rlc(path, descarte):
    """Registro RLC del gNB (parche TFG v2): cola, estancia, retransmisiones y marcas L4S."""
    res = {}
    if not os.path.exists(path):
        return res
    filas = list(csv.DictReader(open(path, errors='ignore')))
    if len(filas) < 2:
        return res
    try:
        t0 = int(filas[0]['t_us'])
        est = [f for f in filas if int(f['t_us']) - t0 >= descarte * 1e6] or filas
        cola = [int(f['cola_bytes']) for f in est]
        hol = [int(f['hol_us']) / 1000 for f in est]
        vuelo = [int(f['en_vuelo']) for f in est]
        n = sum(int(f['n_deq']) for f in est)
        res['rlc_cola_kB_media'] = statistics.mean(cola) / 1000
        res['rlc_cola_kB_max'] = max(cola) / 1000
        res['rlc_hol_ms_media'] = statistics.mean(hol)
        res['rlc_hol_ms_p95'] = percentil(hol, 95)
        res['rlc_en_vuelo_media'] = statistics.mean(vuelo)
        if n:
            res['rlc_estancia_ms_media'] = sum(int(f['soj_media_us']) * int(f['n_deq']) for f in est) / n / 1000
        res['rlc_estancia_ms_max'] = max(int(f['soj_max_us']) for f in est) / 1000
        a, b = est[0], est[-1]
        dif = lambda k: int(b[k]) - int(a[k])
        res['rlc_pdu_tx'] = dif('tx_pdu')
        res['rlc_pdu_retx'] = dif('retx_pdu')
        res['rlc_descartes_buffer'] = dif('descartes_llena')
        res['l4s_paquetes'] = dif('l4s_pkts')
        res['l4s_marcas'] = dif('marcas')
        if res['l4s_paquetes'] > 0:
            res['l4s_marcas_pct'] = 100.0 * res['l4s_marcas'] / res['l4s_paquetes']
        if res['rlc_pdu_tx'] > 0:
            res['rlc_retx_pct'] = 100.0 * res['rlc_pdu_retx'] / res['rlc_pdu_tx']
        res['umbral_us'] = int(b['umbral_us'])
    except (KeyError, ValueError):
        return {}
    return res


def factor_desde_log(path):''', 'factor_desde_log')
r = sust(r, "        f.update(leer_tc(os.path.join(full, 'tc.txt')))\n",
         "        f.update(leer_tc(os.path.join(full, 'tc.txt')))\n"
         "        f.update(leer_rlc(os.path.join(full, 'rlc.csv'), descarte))\n", 'llamada a leer_tc')
r = sust(r, "    print(f\"\\nFicheros: {os.path.join(base, 'pruebas.csv')} y {os.path.join(base, 'casos.csv')}\")",
         "    if any(f.get('rlc_cola_kB_media_media') is not None for f in salida):\n"
         "        print(f\"\\n{'caso':28} {'umbral us':>10} {'cola RLC kB':>16} {'estancia RLC ms':>18} {'espera 1.º ms p95':>18} {'retx RLC %':>12} {'marcas %':>12} {'tarde %':>10} {'retraso max ms':>15}\")\n"
         "        for f in salida:\n"
         "            u = f\"{f['umbral_us_media']:.0f}\" if f.get('umbral_us_media') is not None else '-'\n"
         "            print(f\"{f['caso']:28} {u:>10} {fmt(f, 'rlc_cola_kB_media'):>16} {fmt(f, 'rlc_estancia_ms_media', 2):>18} {fmt(f, 'rlc_hol_ms_p95'):>18} \"\n"
         "                  f\"{fmt(f, 'rlc_retx_pct', 2):>12} {fmt(f, 'l4s_marcas_pct', 2):>12} {fmt(f, 'pacing_tarde_pct', 2):>10} {fmt(f, 'pacing_max_ms'):>15}\")\n"
         "    print(f\"\\nFicheros: {os.path.join(base, 'pruebas.csv')} y {os.path.join(base, 'casos.csv')}\")", 'línea final de ficheros')

for p in (S, R):
    shutil.copy(p, p + '.antes_l4s')
open(S, 'w').write(s)
open(R, 'w').write(r)
print('Actualizados', S, 'y', R, '(copias .antes_l4s)')
