#!/usr/bin/env python3
"""Figuras de evolución temporal de la fase 5G, una por celda.

Uso:  python3 scripts/5g/analisis/figura_series.py [series_40.txt series_10.txt [carpeta_de_salida]]

Lee la salida de texto de series_temporales.py (una fila por segundo y caso). Sin argumentos usa
metricas/5g/series/series_40.txt y series_10.txt y escribe en figuras/.
"""
import math
import re
import sys
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter, NullFormatter

ROJO, NARANJA, AZUL, GRIS = "#d62728", "#ff7f0e", "#1f77b4", "#555555"
plt.rcParams.update({"font.size": 11, "axes.grid": True, "grid.alpha": 0.3, "figure.dpi": 150,
                     "axes.axisbelow": True, "savefig.bbox": "tight"})

COLS = ["caso", "rep", "t", "goodput", "cwnd", "rtt", "ping", "ce", "estancia", "cola", "marcas", "l4s"]


def coma(x):
    return f"{x:g}".replace(".", ",")


FMT = FuncFormatter(lambda v, _p: coma(v))


def leer(fichero):
    """Devuelve {caso: {columna: [valores]}} y {caso: (repetición, goodput de la prueba)}."""
    datos, info = {}, {}
    for linea in Path(fichero).read_text(errors="ignore").splitlines():
        linea = linea.strip()
        m = re.match(r"#\s*(\S+): repetici\S+n (\d+) \(([\d.]+) Mbit/s\)", linea)
        if m:
            info[m.group(1)] = (int(m.group(2)), float(m.group(3)))
            continue
        c = linea.split(",")
        if len(c) != 12 or not c[0].startswith(("dl_", "ul_")):
            continue
        try:
            v = [float(x) for x in c[1:]]
        except ValueError:
            continue
        d = datos.setdefault(c[0], {k: [] for k in COLS[1:]})
        if v[1] >= 60:   # las pruebas duran 60 s; se descartan los segundos de cierre
            continue
        for k, x in zip(COLS[1:], v):
            d[k].append(x)
    return datos, info


def positivo(v):
    return [x if x > 0 else float("nan") for x in v]


def figura(datos, casos, titulo, salida, umbral_ms=10):
    """casos: lista de (nombre en el fichero, etiqueta, color, marcador)."""
    fig, ejes = plt.subplots(2, 2, figsize=(9.2, 6.4), sharex=True)
    paneles = [(ejes[0][0], "goodput", "Datos confirmados por segundo (Mbit/s)", False),
               (ejes[0][1], "cwnd", "Ventana de congestión (segmentos)", True),
               (ejes[1][0], "rtt", "RTT de TCP (ms)", True),
               (ejes[1][1], "estancia", "Estancia en la cola RLC del gNB (ms)", True)]
    for ax, col, etiqueta, log in paneles:
        for nombre, leyenda, color, marcador in casos:
            if nombre not in datos:
                continue
            d = datos[nombre]
            y = positivo(d[col]) if log else d[col]
            ax.plot(d["t"], y, color=color, marker=marcador, markersize=2.8, linewidth=1.4, label=leyenda)
        if log:
            ax.set_yscale("log")
            ax.yaxis.set_minor_formatter(NullFormatter())
            vals = [v for n, *_ in casos if n in datos for v in datos[n][col] if v > 0]
            if vals:  # límites en décadas completas, para que siempre haya varias marcas con número
                ax.set_ylim(10 ** math.floor(math.log10(min(vals))), 10 ** math.ceil(math.log10(max(vals) * 1.001)))
        else:
            ax.set_ylim(bottom=0)
        ax.yaxis.set_major_formatter(FMT)
        ax.set_title(etiqueta, fontsize=11)
        ax.set_xlim(0, 60)
        ax.set_xticks(range(0, 61, 10))
    ax = ejes[1][1]
    ax.axhline(umbral_ms, color=GRIS, linestyle=":", linewidth=1.2)
    ax.annotate("umbral de marcado", xy=(59, umbral_ms), xytext=(0, 3), textcoords="offset points",
                ha="right", va="bottom", fontsize=8.5, color=GRIS)
    for ax in ejes[1]:
        ax.set_xlabel("Tiempo (s)")
    asas, etiquetas = ejes[0][0].get_legend_handles_labels()
    fig.legend(asas, etiquetas, loc="upper center", ncol=3, fontsize=10, frameon=False, bbox_to_anchor=(0.5, 0.96))
    fig.suptitle(titulo, fontsize=12, y=0.995)
    fig.tight_layout(rect=(0, 0, 1, 0.94))
    fig.savefig(f"{salida}.pdf")
    fig.savefig(f"{salida}.png", dpi=150)
    plt.close(fig)


def resumen(datos, info, casos):
    """Imprime los rangos que se citan en el texto (desde t = 10 s)."""
    for nombre, leyenda, _c, _m in casos:
        if nombre not in datos:
            print(f"  {leyenda}: SIN DATOS"); continue
        d = datos[nombre]
        i = [k for k, t in enumerate(d["t"]) if t >= 10]
        r = lambda col: (min(d[col][k] for k in i), max(d[col][k] for k in i))
        rep = info.get(nombre, ("?", "?"))
        print(f"  {leyenda} (rep. {rep[0]}, {rep[1]} Mbit/s; {len(d['t'])} s): "
              f"goodput {r('goodput')}, cwnd {r('cwnd')}, rtt {r('rtt')}, estancia {r('estancia')}, "
              f"cola_kB {r('cola')}, marcas/s {r('marcas')}, l4s/s {r('l4s')}, CE final {d['ce'][-1]:.0f}")


if __name__ == "__main__":
    repo = Path(__file__).resolve().parents[3]
    f40, f10 = (sys.argv[1], sys.argv[2]) if len(sys.argv) > 2 else (repo / "metricas/5g/series/series_40.txt", repo / "metricas/5g/series/series_10.txt")
    out = Path(sys.argv[3]) if len(sys.argv) > 3 else repo / "figuras"
    out.mkdir(parents=True, exist_ok=True)
    c40 = [("dl_cubic_sinmarcado", "Cubic", ROJO, "o"),
           ("dl_prague_sinmarcado", "Prague sin marcado", NARANJA, "s"),
           ("dl_prague_marcado", "Prague con marcado en el gNB", AZUL, "D")]
    c10 = [("dl_r04_cubic", "Cubic", ROJO, "o"),
           ("dl_r04_prague_sin", "Prague sin marcado", NARANJA, "s"),
           ("dl_r04_prague_marc", "Prague con marcado en el gNB", AZUL, "D")]
    for fichero, casos, titulo, nombre in (
            (f40, c40, "Evolución temporal en la celda de 40 MHz sin ruido (bajada)", "5g_serie_40mhz"),
            (f10, c10, "Evolución temporal en la celda de 10 MHz con ruido de −4 dB (bajada)", "5g_serie_10mhz")):
        datos, info = leer(fichero)
        print(nombre, {k: len(v["t"]) for k, v in datos.items()})
        resumen(datos, info, casos)
        figura(datos, casos, titulo, str(out / nombre))
