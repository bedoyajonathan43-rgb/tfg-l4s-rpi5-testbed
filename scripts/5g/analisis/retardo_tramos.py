#!/usr/bin/env python3
# TFG L4S - retardo por tramos a partir de capturas en tres puntos (mismo reloj).
# Uso: python3 retardo_tramos.py <dir_capturas> <dir_campana> [descarte_s=20]
import sys, os, re, struct, glob, bisect, csv, statistics as st

def leer_pcap(path):
    out = []
    with open(path, 'rb') as f:
        gh = f.read(24)
        if len(gh) < 24:
            return out
        magic = gh[:4]
        if magic in (b'\xd4\xc3\xb2\xa1', b'\x4d\x3c\xb2\xa1'):
            e = '<'
        elif magic in (b'\xa1\xb2\xc3\xd4', b'\xa1\xb2\x3c\x4d'):
            e = '>'
        else:
            sys.exit(f'{path}: no es un pcap clasico')
        nano = magic in (b'\x4d\x3c\xb2\xa1', b'\xa1\xb2\x3c\x4d')
        link = struct.unpack(e + 'I', gh[20:24])[0]
        div = 1e9 if nano else 1e6
        while True:
            rh = f.read(16)
            if len(rh) < 16:
                break
            s, us, incl, _orig = struct.unpack(e + 'IIII', rh)
            d = f.read(incl)
            if len(d) < incl:
                break
            out.append((s + us / div, d, link))
    return out

def ip_desde_enlace(d, link):
    if link == 1:
        if len(d) < 14: return None
        et = struct.unpack('!H', d[12:14])[0]; off = 14
        if et == 0x8100 and len(d) >= 18:
            et = struct.unpack('!H', d[16:18])[0]; off = 18
        return d[off:] if et == 0x0800 else None
    if link in (101, 12, 14, 228):
        return d
    if link == 113:
        return d[16:] if len(d) > 16 and d[14:16] == b'\x08\x00' else None
    if link == 276:
        return d[20:] if len(d) > 20 and d[0:2] == b'\x08\x00' else None
    return None

def icmp_de_ip(ip):
    if ip is None or len(ip) < 28 or ip[0] >> 4 != 4: return None
    ihl = (ip[0] & 0x0f) * 4
    if ip[9] != 1 or len(ip) < ihl + 8: return None
    if struct.unpack('!H', ip[6:8])[0] & 0x1fff: return None
    tipo = ip[ihl]
    if tipo not in (0, 8): return None
    ident, seq = struct.unpack('!HH', ip[ihl + 4:ihl + 8])
    return (tipo, ident, seq, ip[12:16], ip[16:20], ip[1])

def interior_gtp(ip):
    if ip is None or len(ip) < 36 or ip[0] >> 4 != 4 or ip[9] != 17: return None
    ihl = (ip[0] & 0x0f) * 4
    sp, dp = struct.unpack('!HH', ip[ihl:ihl + 4])
    if 2152 not in (sp, dp): return None
    g = ip[ihl + 8:]
    if len(g) < 8 or g[1] != 0xff: return None
    off = 8
    if g[0] & 0x07:
        if len(g) < 12: return None
        sig = g[11]; off = 12
        while sig != 0:
            if len(g) < off + 1: return None
            n = g[off] * 4
            if n == 0 or len(g) < off + n: return None
            sig = g[off + n - 1]; off += n
    return g[off:]

def cargar(dircap):
    pts = {k: {} for k in ('A', 'Bp', 'Bg', 'C')}
    cuenta = {k: 0 for k in pts}
    def anota(p, t, ic):
        pts[p].setdefault(ic[:5], []).append((t, ic[5])); cuenta[p] += 1
    for t, d, link in leer_pcap(os.path.join(dircap, 'a.pcap')):
        ic = icmp_de_ip(ip_desde_enlace(d, link))
        if ic: anota('A', t, ic)
    for t, d, link in leer_pcap(os.path.join(dircap, 'b.pcap')):
        ip = ip_desde_enlace(d, link)
        ic = icmp_de_ip(ip)
        if ic: anota('Bp', t, ic); continue
        ic = icmp_de_ip(interior_gtp(ip))
        if ic: anota('Bg', t, ic)
    for t, d, link in leer_pcap(os.path.join(dircap, 'c.pcap')):
        ic = icmp_de_ip(ip_desde_enlace(d, link))
        if ic: anota('C', t, ic)
    for p in pts:
        for k in pts[p]: pts[p][k].sort()
    return pts, cuenta

def siguiente(lista, t, margen=30.0):
    if not lista: return None
    i = bisect.bisect_left(lista, (t - 0.0005, -1))
    if i < len(lista) and lista[i][0] - t < margen: return lista[i]
    return None

TRAMOS = ['red_baj', 'upf_baj', 'radio_baj', 'giro', 'radio_sub', 'upf_sub', 'red_sub', 'total']
NOMBRE = {'red_baj': 'servidor -> UPF', 'upf_baj': 'UPF (encapsulado GTP)', 'radio_baj': 'UPF -> UE (gNB + radio)',
          'giro': 'respuesta en la UE', 'radio_sub': 'UE -> UPF (radio + gNB)', 'upf_sub': 'UPF (desencapsulado)',
          'red_sub': 'UPF -> servidor', 'total': 'total (ida y vuelta)'}

def ventanas(dircamp, descarte):
    v = []
    for d in sorted(glob.glob(os.path.join(dircamp, 'p[0-9]*'))):
        nom = os.path.basename(d)
        caso = re.sub(r'^p\d+_|_rep\d+$', '', nom)
        def ts(fn):
            try:
                return [float(x) for x in re.findall(r'^\[(\d+\.\d+)\]', open(os.path.join(d, fn), errors='ignore').read(), re.M)]
            except OSError:
                return []
        r, c = ts('ping_reposo.txt'), ts('ping_c.txt')
        if r: v.append((r[0] - 1.0, r[-1] + 0.2, nom, caso, 'reposo'))
        if c: v.append((c[0] + descarte, c[-1] + 0.2, nom, caso, 'carga'))
    return v

def estancia_rlc(dirprueba, t0, t1):
    try:
        s = n = 0
        for f in csv.DictReader(open(os.path.join(dirprueba, 'rlc.csv'))):
            t = int(f['t_us']) / 1e6
            if t0 <= t <= t1 and int(f['n_deq']) > 0:
                s += int(f['soj_media_us']) * int(f['n_deq']); n += int(f['n_deq'])
        return s / n / 1000 if n else None
    except (OSError, KeyError, ValueError):
        return None

def resumen(v):
    v = sorted(v)
    return st.mean(v), st.median(v), v[int(0.95 * (len(v) - 1))]

def main():
    if len(sys.argv) < 3: sys.exit('uso: retardo_tramos.py <dir_capturas> <dir_campana> [descarte_s]')
    dircap, dircamp = sys.argv[1], sys.argv[2]
    descarte = float(sys.argv[3]) if len(sys.argv) > 3 else 20.0
    pts, cuenta = cargar(dircap)
    print('Ecos ICMP capturados: servidor', cuenta['A'], '| UPF sin encapsular', cuenta['Bp'], '| UPF en GTP', cuenta['Bg'], '| UE', cuenta['C'])
    vent = ventanas(dircamp, descarte)
    datos = {}
    ce = {}
    usados = incompletos = 0
    for k, lst in pts['A'].items():
        tipo, ident, seq, src, dst = k
        if tipo != 8: continue
        kr = (0, ident, seq, dst, src)
        for tA1, tos in lst:
            w = next((x for x in vent if x[0] <= tA1 <= x[1]), None)
            if w is None: continue
            pasos = [siguiente(pts['Bp'].get(k), tA1)]
            for p, kk in (('Bg', k), ('C', k), ('C', kr), ('Bg', kr), ('Bp', kr), ('A', kr)):
                pasos.append(siguiente(pts[p].get(kk), pasos[-1][0]) if pasos[-1] else None)
            if any(x is None for x in pasos):
                incompletos += 1; continue
            t = [tA1] + [x[0] for x in pasos]
            if t[-1] - tA1 > 30: incompletos += 1; continue
            usados += 1
            clase = 'ECT(1)' if tos & 3 == 1 else 'clasico'
            d = datos.setdefault((w[3], w[4], clase), {x: [] for x in TRAMOS})
            for i, nom in enumerate(TRAMOS[:-1]):
                d[nom].append((t[i + 1] - t[i]) * 1000)
            d['total'].append((t[-1] - tA1) * 1000)
            if clase == 'ECT(1)':
                c = ce.setdefault((w[3], w[4]), [0, 0]); c[0] += 1
                if pasos[2][1] & 3 == 3: c[1] += 1
    print(f'Pings completos en los siete puntos de paso: {usados}; descartados por faltar algun punto: {incompletos}')
    rlc = {}
    for t0, t1, nom, caso, fase in vent:
        e = estancia_rlc(os.path.join(dircamp, nom), t0, t1)
        if e is not None: rlc.setdefault((caso, fase), []).append(e)
    filas = []
    for (caso, fase, clase) in sorted(datos):
        d = datos[(caso, fase, clase)]
        print(f'\n{caso} | {fase} | ping {clase} | n = {len(d["total"])}')
        print(f'  {"tramo":28} {"media":>9} {"mediana":>9} {"p95":>9}   (ms)')
        for nom in TRAMOS:
            m, md, p = resumen(d[nom])
            print(f'  {NOMBRE[nom]:28} {m:9.3f} {md:9.3f} {p:9.3f}')
            filas.append([caso, fase, clase, nom, len(d[nom]), f'{m:.4f}', f'{md:.4f}', f'{p:.4f}'])
        if (caso, fase) in rlc:
            print(f'  {"cola RLC del gNB (registro)":28} {st.mean(rlc[(caso, fase)]):9.3f}   media de {len(rlc[(caso, fase)])} pruebas')
        if clase == 'ECT(1)' and (caso, fase) in ce:
            n, m = ce[(caso, fase)]
            print(f'  pings ECT(1) que llegan a la UE con CE: {m} de {n} ({100.0 * m / n:.1f} %)')
    with open(os.path.join(dircap, 'capas.csv'), 'w', newline='') as f:
        w = csv.writer(f); w.writerow(['caso', 'fase', 'ping', 'tramo', 'n', 'media_ms', 'mediana_ms', 'p95_ms']); w.writerows(filas)
    print(f'\nFichero: {os.path.join(dircap, "capas.csv")}')

if __name__ == '__main__':
    main()
