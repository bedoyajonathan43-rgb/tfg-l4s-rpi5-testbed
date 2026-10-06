#!/usr/bin/env python3
"""
resumen_campana.py - TFG L4S: resumen estadístico de una campaña OAI.

Uso:
    python3 resumen_campana.py ~/campanas_oai/<campaña> [descarte_inicial_s=5]

Lee cada prueba válida (carpetas pNNN_* con fichero DONE) y genera:
  - pruebas.csv : una fila por prueba con todas las métricas
  - casos.csv   : por caso, n, media, desviación, IC 95 % y mediana
y muestra por pantalla una tabla resumen.

Métricas por prueba:
  goodput (servidor iperf), RTT del emisor (ss, régimen estable: se descartan
  los primeros segundos), percentil 95, marcas CE entregadas, retransmisiones,
  estadísticas de dualpi2 (tc -s), pacing en tiempo real, factor de escala,
  RSRP/SINR de la UE y BLER/MCS del gNB.
"""
import csv
import math
import os
import re
import statistics
import sys

T95 = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365,
       8: 2.306, 9: 2.262, 10: 2.228, 11: 2.201, 12: 2.179, 13: 2.160, 14: 2.145,
       15: 2.131, 16: 2.120, 17: 2.110, 18: 2.101, 19: 2.093, 20: 2.086,
       25: 2.060, 30: 2.042, 40: 2.021, 60: 2.000, 120: 1.980}


def t95(df):
    if df in T95:
        return T95[df]
    keys = sorted(T95)
    for k in keys:
        if k > df:
            return T95[k]
    return 1.96


def leer_meta(d):
    meta = {}
    p = os.path.join(d, 'meta.txt')
    if os.path.exists(p):
        for l in open(p, errors='ignore'):
            if '=' in l:
                k, v = l.rstrip('\n').split('=', 1)
                meta[k] = v
    return meta


UNIT = {'': 1e-6, 'K': 1e-3, 'M': 1.0, 'G': 1e3}


def goodput(path):
    """Throughput de la línea que cubre toda la prueba (0.0000-XX sec)."""
    if not os.path.exists(path):
        return None
    best = None
    for l in open(path, errors='ignore'):
        m = re.search(r'\s0\.0+-\s*([\d.]+)\s+sec\s+[\d.]+\s+\w?Bytes\s+([\d.]+)\s+(\w?)bits/sec', l)
        if m:
            dur = float(m.group(1))
            if best is None or dur >= best[0]:
                best = (dur, float(m.group(2)) * UNIT.get(m.group(3), 1.0))
    return best[1] if best and best[0] > 5 else None


def percentil(v, p):
    if not v:
        return None
    s = sorted(v)
    k = (len(s) - 1) * p / 100.0
    f, c = math.floor(k), math.ceil(k)
    return s[f] if f == c else s[f] + (s[c] - s[f]) * (k - f)


def leer_ss(path, descarte):
    res = {}
    if not os.path.exists(path):
        return res
    txt = open(path, errors='ignore').read()
    bloques = re.split(r'=== t=([\d.]+)', txt)
    muestras = []   # (t, rtt, ce, retrans)
    for i in range(1, len(bloques) - 1, 2):
        try:
            t = float(bloques[i])
        except ValueError:
            continue
        b = bloques[i + 1]
        rtt = re.search(r'\brtt:([\d.]+)/', b)
        ce = re.search(r'delivered_ce:(\d+)', b)
        rt = re.search(r'retrans:\d+/(\d+)', b)
        if rtt:
            muestras.append((t, float(rtt.group(1)),
                             int(ce.group(1)) if ce else None,
                             int(rt.group(1)) if rt else 0))
    if not muestras:
        return res
    t0 = muestras[0][0]
    est = [m for m in muestras if m[0] - t0 >= descarte] or muestras
    rtts = [m[1] for m in est]
    res['rtt_muestras'] = len(rtts)
    res['rtt_media_ms'] = statistics.mean(rtts)
    res['rtt_mediana_ms'] = statistics.median(rtts)
    res['rtt_p95_ms'] = percentil(rtts, 95)
    res['rtt_min_ms'] = min(rtts)
    res['rtt_max_ms'] = max(rtts)
    res['rtt_desv_ms'] = statistics.stdev(rtts) if len(rtts) > 1 else 0.0
    ces = [m[2] for m in muestras if m[2] is not None]
    res['ce_entregadas'] = (ces[-1] - ces[0]) if len(ces) > 1 else 0
    res['retransmisiones'] = muestras[-1][3]
    return res


def leer_tc(path):
    res = {}
    if not os.path.exists(path):
        return res
    txt = open(path, errors='ignore').read()
    bloques = [b for b in re.split(r'=== t=[\d.]+', txt) if 'qdisc' in b]
    if not bloques:
        return res

    def stats(b):
        d = {}
        for q in re.split(r'\nqdisc ', '\n' + b):
            if not q.startswith(('dualpi2', 'pfifo')):
                continue
            for k, rx in (('enviados_pkt', r'Sent \d+ bytes (\d+) pkt'),
                          ('descartes', r'dropped (\d+)'),
                          ('ecn_mark', r'ecn_mark (\d+)'),
                          ('step_marks', r'step_marks (\d+)')):
                m = re.search(rx, q)
                if m:
                    d[k] = int(m.group(1))
        return d
    a, b = stats(bloques[0]), stats(bloques[-1])
    for k in b:
        res['aqm_' + k] = b[k] - a.get(k, 0)
    # dualpi2 (tc de L4STeam): retardo de cola instantáneo de cada cola y probabilidad, media de las muestras
    dc, dl, pr, ql = [], [], [], []
    for bl in bloques[3:]:   # se descartan las 3 primeras muestras (arranque)
        m = re.search(r'prob ([\d.]+) delay_c (\d+)us delay_l (\d+)us', bl)
        if m:
            pr.append(float(m.group(1))); dc.append(int(m.group(2)) / 1000); dl.append(int(m.group(3)) / 1000)
        m = re.search(r'dualpi2.*?backlog (\d+)b (\d+)p', bl, re.S)
        if m:
            ql.append(int(m.group(2)))
    if dc:
        res['dualpi2_delay_c_ms'] = statistics.mean(dc)
        res['dualpi2_delay_l_ms'] = statistics.mean(dl)
        res['dualpi2_prob'] = statistics.mean(pr)
    if ql:
        res['cola_aqm_pkts'] = statistics.mean(ql)
    ini = [re.search(r'pkts_in_c (\d+) pkts_in_l (\d+)', x) for x in (bloques[0], bloques[-1])]
    if all(ini):
        res['dualpi2_pkts_c'] = int(ini[1].group(1)) - int(ini[0].group(1))
        res['dualpi2_pkts_l'] = int(ini[1].group(2)) - int(ini[0].group(2))
    return res


def leer_ping(path, descarte, pref):
    """Ping de fondo con -D: media, mediana, p95 y pérdidas (descartando los primeros segundos)."""
    res = {}
    if not os.path.exists(path):
        return res
    t, v = [], []
    tx = rx = None
    for l in open(path, errors='ignore'):
        m = re.search(r'^\[([\d.]+)\].*time=([\d.]+) ms', l)
        if m:
            t.append(float(m.group(1))); v.append(float(m.group(2)))
        m = re.search(r'(\d+) packets transmitted, (\d+) received', l)
        if m:
            tx, rx = int(m.group(1)), int(m.group(2))
    if v:
        est = [x for ti, x in zip(t, v) if ti - t[0] >= descarte] or v
        res[pref + '_media_ms'] = statistics.mean(est)
        res[pref + '_mediana_ms'] = statistics.median(est)
        res[pref + '_p95_ms'] = percentil(est, 95)
    if tx:
        res[pref + '_perdidas_pct'] = 100.0 * (tx - rx) / tx
    return res


def leer_rlc(path, descarte):
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


def factor_desde_log(path):
    """Factor de escala (tiempo real / simulado) a partir de las líneas 'stats sfn'."""
    if not os.path.exists(path):
        return None
    sfn = []
    for l in open(path, errors='ignore'):
        m = re.match(r'^\s*(\d+\.\d+)\s+\[NR_MAC\].*stats sfn:\s*(\d+)\.', l)
        if m:
            sfn.append((float(m.group(1)), int(m.group(2))))
    fac = []
    for (t0, s0), (t1, s1) in zip(sfn, sfn[1:]):
        d = s1 - s0
        if d <= 0:
            d += 1024
        if t1 > t0:
            f = (t1 - t0) / (d * 0.010)
            if f < 1000:
                fac.append(f)
    return statistics.median(fac) if fac else None


def leer_gnb(path):
    res = {}
    if not os.path.exists(path):
        return res
    bl = ta = ra = 0
    maxr = 0.0
    sfn = []
    bler_dl, mcs_dl, bler_ul, mcs_ul = [], [], [], []
    nprb_ul, snr_ul = [], []
    harq = {'dl': [], 'ul': []}   # (r1, r2, r3, r4, errores) acumulados
    ph = []
    for l in open(path, errors='ignore'):
        m = re.search(r'(dl|ul)sch_rounds (\d+)/(\d+)/(\d+)/(\d+), (?:dl|ul)sch_errors (\d+)', l)
        if m:
            harq[m.group(1)].append(tuple(int(x) for x in m.groups()[1:]))
        m = re.search(r'in-sync PH (-?\d+) dB', l)
        if m:
            ph.append(int(m.group(1)))
        m = re.search(r'RT pacing: bloques=(\d+) tarde\(>1ms\)=(\d+).*max_retraso=([\d.]+) ms reanclajes=(\d+)', l)
        if m:
            bl += int(m.group(1)); ta += int(m.group(2))
            maxr = max(maxr, float(m.group(3))); ra += int(m.group(4))
        m = re.match(r'^\s*(\d+\.\d+)\s+\[NR_MAC\].*stats sfn:\s*(\d+)\.', l)
        if m:
            sfn.append((float(m.group(1)), int(m.group(2))))
        m = re.search(r'dlsch_rounds.*BLER ([\d.]+) MCS \(\d+\) (\d+)', l)
        if m:
            bler_dl.append(float(m.group(1))); mcs_dl.append(int(m.group(2)))
        m = re.search(r'ulsch_rounds.*BLER ([\d.]+) MCS \(\d+\) (\d+)', l)
        if m:
            bler_ul.append(float(m.group(1))); mcs_ul.append(int(m.group(2)))
        m = re.search(r'ulsch_rounds.*NPRB (\d+) SNR ([-\d.]+)', l)
        if m:
            nprb_ul.append(int(m.group(1))); snr_ul.append(float(m.group(2)))
    # Retransmisiones HARQ (MAC) durante la prueba: diferencia entre la primera y la
    # última línea de estadísticas (los contadores del gNB son acumulados)
    for sd, v in harq.items():
        if len(v) >= 2:
            d = [b - a for a, b in zip(v[0], v[-1])]
            tx = sum(d[:4])
            if tx > 0 and min(d) >= 0:
                res[f'harq_retx_{sd}_pct'] = 100.0 * sum(d[1:4]) / tx
                res[f'harq_perdidos_{sd}'] = d[4]
    if ph:
        res['ph_ul_db'] = statistics.mean(ph)
    if bl:
        res['pacing_tarde_pct'] = 100.0 * ta / bl
        res['pacing_max_ms'] = maxr
        res['pacing_reanclajes'] = ra
    fac = []
    for (t0, s0), (t1, s1) in zip(sfn, sfn[1:]):
        d = s1 - s0
        if d <= 0:
            d += 1024
        if t1 > t0:
            f = (t1 - t0) / (d * 0.010)
            if f < 1000:
                fac.append(f)
    if fac:
        res['factor_escala'] = statistics.median(fac)
    for k, v in (('bler_dl', bler_dl), ('mcs_dl', mcs_dl), ('bler_ul', bler_ul), ('mcs_ul', mcs_ul), ('nprb_ul', nprb_ul), ('snr_ul_db', snr_ul)):
        if v:
            res[k] = statistics.mean(v)
    return res


def leer_ue(path):
    res = {}
    if not os.path.exists(path):
        return res
    sinr, rsrp = [], []
    for l in open(path, errors='ignore'):
        m = re.search(r'SINR ([-\d.]+) dB RSRP (-?\d+) dBm', l)
        if m:
            sinr.append(float(m.group(1))); rsrp.append(float(m.group(2)))
    if sinr:
        res['sinr_db'] = statistics.mean(sinr)
        res['rsrp_dbm'] = statistics.mean(rsrp)
    return res


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    base = os.path.expanduser(sys.argv[1])
    descarte = float(sys.argv[2]) if len(sys.argv) > 2 else 5.0
    filas = []
    for d in sorted(os.listdir(base)):
        full = os.path.join(base, d)
        if not (d.startswith('p') and os.path.isdir(full) and os.path.exists(os.path.join(full, 'DONE'))):
            continue
        m = re.match(r'p(\d+)_(.+)_rep(\d+)$', d)
        if not m:
            continue
        meta = leer_meta(full)
        f = {'prueba': d, 'caso': m.group(2), 'rep': int(m.group(3)),
             'modo': meta.get('modo'), 'dir': meta.get('dir'), 'cca': meta.get('cca'),
             'punto': meta.get('punto'), 'rate_mbit': meta.get('rate_mbit'), 'qdisc': meta.get('qdisc'),
             'ruido_dB': meta.get('ruido_dB', 'ninguno')}
        f['goodput_mbps'] = goodput(os.path.join(full, 'iperf_servidor.txt'))
        f['throughput_cliente_mbps'] = goodput(os.path.join(full, 'iperf_cliente.txt'))
        f.update(leer_ss(os.path.join(full, 'ss.txt'), descarte))
        f.update(leer_tc(os.path.join(full, 'tc.txt')))
        f.update(leer_rlc(os.path.join(full, 'rlc.csv'), descarte))
        f.update(leer_ping(os.path.join(full, 'ping_reposo.txt'), 0, 'ping_reposo'))
        f.update(leer_ping(os.path.join(full, 'ping_c.txt'), descarte, 'ping_clasico'))
        f.update(leer_ping(os.path.join(full, 'ping_l.txt'), descarte, 'ping_l4s'))
        f.update(leer_gnb(os.path.join(full, 'gnb.log')))
        f.update(leer_ue(os.path.join(full, 'ue.log')))
        if not f.get('factor_escala'):
            fu = factor_desde_log(os.path.join(full, 'ue.log'))
            if fu:
                f['factor_escala'] = fu
        if f.get('factor_escala') and f.get('rtt_media_ms') is not None:
            f['rtt_media_corregida_ms'] = f['rtt_media_ms'] / f['factor_escala']
        filas.append(f)
    if not filas:
        print('No hay pruebas válidas en', base)
        sys.exit(1)

    cols = []
    for f in filas:
        for k in f:
            if k not in cols:
                cols.append(k)
    with open(os.path.join(base, 'pruebas.csv'), 'w', newline='') as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        for f in filas:
            w.writerow({k: (f'{v:.4f}' if isinstance(v, float) else v) for k, v in f.items()})

    metricas = [c for c in cols if c not in ('prueba', 'caso', 'rep', 'modo', 'dir', 'cca', 'punto', 'rate_mbit', 'qdisc', 'ruido_dB')]
    casos = {}
    for f in filas:
        casos.setdefault(f['caso'], []).append(f)
    salida = []
    for caso, fs in sorted(casos.items()):
        base_f = {k: fs[0].get(k) for k in ('caso', 'modo', 'dir', 'cca', 'punto', 'rate_mbit', 'qdisc', 'ruido_dB')}
        base_f['n'] = len(fs)
        for mtr in metricas:
            v = [x[mtr] for x in fs if isinstance(x.get(mtr), (int, float))]
            if not v:
                continue
            media = statistics.mean(v)
            desv = statistics.stdev(v) if len(v) > 1 else 0.0
            h = t95(len(v) - 1) * desv / math.sqrt(len(v)) if len(v) > 1 else 0.0
            base_f[mtr + '_media'] = media
            base_f[mtr + '_desv'] = desv
            base_f[mtr + '_ic95'] = h
            base_f[mtr + '_mediana'] = statistics.median(v)
        salida.append(base_f)
    ccols = []
    for f in salida:
        for k in f:
            if k not in ccols:
                ccols.append(k)
    with open(os.path.join(base, 'casos.csv'), 'w', newline='') as fh:
        w = csv.DictWriter(fh, fieldnames=ccols)
        w.writeheader()
        for f in salida:
            w.writerow({k: (f'{v:.4f}' if isinstance(v, float) else v) for k, v in f.items()})

    def fmt(f, k, dec=1):
        if f.get(k + '_media') is None:
            return '-'
        return f"{f[k + '_media']:.{dec}f} ± {f[k + '_ic95']:.{dec}f}"
    print(f"\nCampaña: {base}   (pruebas válidas: {len(filas)}; IC 95 %)\n")
    print(f"{'caso':28} {'n':>3} {'goodput Mbit/s':>16} {'RTT medio ms':>16} {'RTT p95 ms':>16} {'CE':>14} {'factor':>8} {'HARQ DL %':>12} {'HARQ UL %':>12} {'ping C ms':>14} {'ping L ms':>14} {'cola C/L ms':>12}")
    for f in salida:
        fac = f"{f['factor_escala_media']:.2f}" if f.get('factor_escala_media') else '-'
        cola = (f"{f['dualpi2_delay_c_ms_media']:.1f}/{f['dualpi2_delay_l_ms_media']:.1f}" if f.get('dualpi2_delay_c_ms_media') is not None else '-')
        print(f"{f['caso']:28} {f['n']:>3} {fmt(f, 'goodput_mbps', 2):>16} {fmt(f, 'rtt_media_ms'):>16} "
              f"{fmt(f, 'rtt_p95_ms'):>16} {fmt(f, 'ce_entregadas', 0):>14} {fac:>8} {fmt(f, 'harq_retx_dl_pct', 2):>12} {fmt(f, 'harq_retx_ul_pct', 2):>12} "
              f"{fmt(f, 'ping_clasico_media_ms'):>14} {fmt(f, 'ping_l4s_media_ms'):>14} "
              f"{cola:>12}")
    if any(f.get('rlc_cola_kB_media_media') is not None for f in salida):
        print(f"\n{'caso':28} {'umbral us':>10} {'cola RLC kB':>16} {'estancia RLC ms':>18} {'espera 1.º ms p95':>18} {'retx RLC %':>12} {'marcas %':>12} {'tarde %':>10} {'retraso max ms':>15}")
        for f in salida:
            u = f"{f['umbral_us_media']:.0f}" if f.get('umbral_us_media') is not None else '-'
            print(f"{f['caso']:28} {u:>10} {fmt(f, 'rlc_cola_kB_media'):>16} {fmt(f, 'rlc_estancia_ms_media', 2):>18} {fmt(f, 'rlc_hol_ms_p95'):>18} "
                  f"{fmt(f, 'rlc_retx_pct', 2):>12} {fmt(f, 'l4s_marcas_pct', 2):>12} {fmt(f, 'pacing_tarde_pct', 2):>10} {fmt(f, 'pacing_max_ms'):>15}")
    print(f"\nFicheros: {os.path.join(base, 'pruebas.csv')} y {os.path.join(base, 'casos.csv')}")


if __name__ == '__main__':
    main()
