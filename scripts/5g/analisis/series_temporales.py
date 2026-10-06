#!/usr/bin/env python3
# TFG L4S - serie temporal (1 s) de una repeticion representativa de cada caso. Solo lee ficheros.
import sys, os, re, csv, statistics as st

def representativa(camp, caso):
    f = [r for r in csv.DictReader(open(os.path.join(camp, 'pruebas.csv'))) if r['caso'] == caso]
    med = st.median(float(r['goodput_mbps']) for r in f)
    r = min(f, key=lambda r: abs(float(r['goodput_mbps']) - med))
    d = r.get('prueba') or ''
    if not os.path.isdir(os.path.join(camp, d)):
        d = next(x for x in sorted(os.listdir(camp)) if x.endswith('%s_rep%02d' % (caso, int(float(r['rep'])))))
    return os.path.join(camp, d), int(float(r['rep'])), float(r['goodput_mbps'])

def leer_ss(d):
    out, t = [], None
    for l in open(os.path.join(d, 'ss.txt'), errors='ignore'):
        m = re.match(r'=== t=([\d.]+)', l)
        if m:
            t = float(m.group(1)); continue
        if 'cwnd:' in l and t is not None:
            g = lambda k, c=float: (lambda x: c(x.group(1)) if x else 0)(re.search(k + r':([\d.]+)', l))
            out.append((t, g('cwnd'), g('rtt'), g('bytes_acked'), g('delivered_ce')))
            t = None
    return out

def leer_rlc(d):
    try:
        filas = list(csv.DictReader(open(os.path.join(d, 'rlc.csv'))))
    except OSError:
        return []
    ents = {}
    for f in filas:
        try:
            ents.setdefault(f['ent'], []).append(f)
        except KeyError:
            return []
    if not ents:
        return []
    return max(ents.values(), key=lambda v: max(int(x['ip_pkts']) for x in v))

def leer_ping(d, fn):
    out = []
    for m in re.finditer(r'^\[(\d+\.\d+)\].*time=([\d.]+) ms', open(os.path.join(d, fn), errors='ignore').read(), re.M):
        out.append((float(m.group(1)), float(m.group(2))))
    return out

def main():
    camp, casos = sys.argv[1], sys.argv[2:]
    print('caso,rep,t_s,goodput_mbps,cwnd_seg,rtt_tcp_ms,ping_l_ms,ce_acum,rlc_estancia_ms,rlc_cola_kB,marcas_seg,l4s_seg')
    for caso in casos:
        d, rep, gp = representativa(camp, caso)
        ss, rlc, pl = leer_ss(d), leer_rlc(d), leer_ping(d, 'ping_l.txt')
        if not ss:
            print(f'# {caso}: sin datos de ss en {d}'); continue
        t0 = ss[0][0]
        print(f'# {caso}: repeticion {rep} ({gp:.2f} Mbit/s), carpeta {os.path.basename(d)}, {len(ss)} muestras de ss, {len(rlc)} de RLC')
        for s in range(0, 62):
            a, b = t0 + s, t0 + s + 1
            v = [x for x in ss if a <= x[0] < b]
            sig = [x for x in ss if x[0] >= b]
            if not v:
                continue
            ref = sig[0] if sig else v[-1]
            dt = ref[0] - v[0][0]
            gput = (ref[3] - v[0][3]) * 8 / dt / 1e6 if dt > 0 else 0
            p = [x[1] for x in pl if a <= x[0] < b]
            r = [x for x in rlc if a <= int(x['t_us']) / 1e6 < b]
            n = sum(int(x['n_deq']) for x in r)
            est = sum(int(x['soj_media_us']) * int(x['n_deq']) for x in r) / n / 1000 if n else 0
            cola = st.mean(int(x['cola_bytes']) for x in r) / 1000 if r else 0
            mk = int(r[-1]['marcas']) - int(r[0]['marcas']) if len(r) > 1 else 0
            l4 = int(r[-1]['l4s_pkts']) - int(r[0]['l4s_pkts']) if len(r) > 1 else 0
            print(f"{caso},{rep},{s},{gput:.2f},{st.mean(x[1] for x in v):.0f},{st.mean(x[2] for x in v):.1f},"
                  f"{(st.mean(p) if p else 0):.1f},{v[-1][4]:.0f},{est:.2f},{cola:.0f},{mk},{l4}")

if __name__ == '__main__':
    main()
