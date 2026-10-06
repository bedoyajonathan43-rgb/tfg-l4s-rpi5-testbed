#!/usr/bin/env python3
"""Figuras de resultados de la fase 5G: calibración del umbral, celda de 40 MHz,
celda de 10 MHz con ruido y retardo por tramos.

Uso:  python3 scripts/5g/analisis/figuras_5g.py

Los valores están copiados a mano de los resúmenes de las campañas (metricas/5g/<campaña>/casos.csv
y pruebas.csv, y retardo_tramos.csv en las de capturas). El script no lee ningún fichero.
Escribe cuatro figuras, en PDF y PNG, en figuras/.
"""
import random
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter, NullFormatter, FixedLocator

OUT = Path(__file__).resolve().parents[3] / "figuras"
OUT.mkdir(exist_ok=True)
ROJO, NARANJA, AZUL = "#d62728", "#ff7f0e", "#1f77b4"      # Cubic, Prague sin marcado, Prague con marcado
C_NUCLEO, C_BAJADA, C_SUBIDA = "#17becf", "#2ca02c", "#9467bd"
GRIS = "#555555"

plt.rcParams.update({"font.size": 11, "axes.grid": True, "grid.alpha": 0.3, "figure.dpi": 150,
                     "axes.axisbelow": True, "savefig.bbox": "tight"})

def coma(x, dec=None):
    s = f"{x:.{dec}f}" if dec is not None else f"{x:g}"
    return s.replace(".", ",")

FMT = FuncFormatter(lambda v, _p: coma(v))

def guardar(fig, nombre):
    fig.savefig(OUT / f"{nombre}.pdf")
    fig.savefig(OUT / f"{nombre}.png", dpi=150)
    plt.close(fig)

# ---------------------------------------------------------------------------
# 1. Calibración del umbral de marcado (celda de 40 MHz, bajada, 5 repeticiones)
# ---------------------------------------------------------------------------
def fig_calibracion():
    b1 = {"u": [2, 3, 4, 6], "g": [43.52, 50.10, 53.48, 59.36], "gi": [0.50, 0.46, 0.22, 0.14],
          "r": [14.5, 14.5, 15.0, 15.1], "ri": [0.4, 0.4, 0.2, 0.3]}
    b2 = {"u": [6, 8, 10, 15, 20], "g": [59.58, 64.98, 69.96, 78.04, 78.44], "gi": [0.30, 0.20, 0.32, 0.31, 0.27],
          "r": [15.2, 15.8, 16.1, 21.0, 26.9], "ri": [0.2, 0.3, 0.3, 0.6, 0.2]}
    cubic_g, sin_g, sin_gi, sin_r = 82.34, 20.96, 7.86, 13.1
    fig, (a, b) = plt.subplots(1, 2, figsize=(8.6, 4.1))
    for ax, k, ki in ((a, "g", "gi"), (b, "r", "ri")):
        ax.errorbar(b1["u"], b1[k], yerr=b1[ki], color=AZUL, marker="D", markersize=6, linewidth=1.8,
                    capsize=3, label="Prague con marcado, 1.er barrido")
        ax.errorbar(b2["u"], b2[k], yerr=b2[ki], color=AZUL, marker="D", markersize=6, linewidth=1.8,
                    capsize=3, markerfacecolor="white", label="Prague con marcado, 2.º barrido")
        ax.axvline(10, color=GRIS, linestyle=":", linewidth=1.2)
        ax.set_xlabel("Umbral de marcado (ms)")
        ax.set_xticks([2, 3, 4, 6, 8, 10, 15, 20])
        ax.yaxis.set_major_formatter(FMT)
    a.axhline(cubic_g, color=ROJO, linestyle="--", linewidth=1.5, label="Cubic, sin marcado")
    a.axhline(sin_g, color=NARANJA, linestyle="--", linewidth=1.5, label="Prague, sin marcado")
    a.axhspan(sin_g - sin_gi, sin_g + sin_gi, color=NARANJA, alpha=0.12, linewidth=0)
    a.set_ylim(0, 90)
    a.set_ylabel("Goodput (Mbit/s)")
    a.set_title("Goodput")
    a.text(10.3, 4, "umbral elegido", color=GRIS, fontsize=9)
    a.legend(loc="center right", fontsize=8, bbox_to_anchor=(1.0, 0.47))
    b.axhline(sin_r, color=NARANJA, linestyle="--", linewidth=1.5, label="Prague, sin marcado")
    b.set_ylim(10, 30)
    b.set_ylabel("RTT medio (ms)")
    b.set_title("RTT medio")
    b.text(0.03, 0.96, "Cubic, sin marcado:\n181,6 ms (fuera de escala)", transform=b.transAxes,
           fontsize=9, color=ROJO, va="top", ha="left")
    b.legend(loc="center left", fontsize=8, bbox_to_anchor=(0.0, 0.60))
    fig.suptitle("Calibración del umbral de marcado en el gNB (celda de 40 MHz, bajada)", y=1.0, fontsize=12)
    fig.tight_layout()
    guardar(fig, "5g_calibracion_umbral")

# ---------------------------------------------------------------------------
# 2. Celda de 10 MHz con ruido (bajada, 10 repeticiones por punto)
# ---------------------------------------------------------------------------
RUIDO = [-50, -20, -15, -10, -8, -6, -4, -2]
CUBIC_G = [(17.40, 17.40, 17.50), (17.40, 17.40, 17.40), (17.40, 17.40, 17.50), (13.90, 13.90, 15.80),
           (11.20, 11.10, 11.30), (7.72, 7.70, 7.73), (4.81, 4.70, 4.95), (2.36, 2.33, 2.70)]
CUBIC_R = [(924.6, 904.2, 977.2), (927.3, 815.6, 961.1), (933.1, 909.1, 948.2), (1134.2, 912.5, 1319.7),
           (1552.9, 1374.9, 1775.2), (2645.4, 2057.2, 2935.5), (3889.2, 3296.8, 4434.2), (9674.0, 4318.4, 9949.5)]
MARC_G = [(17.00, 17.00, 17.10), (17.05, 17.00, 17.10), (17.10, 17.00, 17.10), (13.50, 13.40, 15.10),
          (11.00, 10.90, 11.00), (7.56, 7.49, 7.58), (4.75, 4.57, 4.85), (2.28, 2.24, 3.33)]
MARC_R = [(18.9, 18.5, 19.1), (18.8, 18.0, 19.2), (18.9, 18.6, 19.6), (21.4, 19.3, 22.7),
          (21.5, 20.3, 23.0), (23.3, 22.9, 23.6), (24.5, 23.2, 25.6), (28.4, 28.0, 29.0)]
# Prague sin marcado: las 80 pruebas una a una, (goodput Mbit/s, RTT ms)
SIN = {
    -50: [(17.3, 936), (15.9, 14), (17.3, 953), (17.3, 949), (17.3, 960), (12.4, 12), (17.3, 910), (14.9, 13), (17.3, 925), (17.3, 886)],
    -20: [(17.3, 912), (17.3, 902), (10.6, 12), (15.5, 13), (15.1, 13), (17.3, 899), (15.8, 13), (17.3, 899), (17.3, 205), (17.3, 940)],
    -15: [(17.3, 862), (17.3, 910), (17.3, 961), (16.3, 14), (16.1, 14), (17.3, 867), (17.3, 902), (17.3, 968), (17.3, 233), (17.3, 945)],
    -10: [(13.7, 1190), (13.7, 1232), (13.8, 1277), (13.8, 1198), (13.8, 1224), (13.9, 1217), (13.7, 1273), (13.7, 1231), (13.8, 1163), (13.8, 1181)],
    -8: [(11.1, 1614), (11.1, 1674), (10.9, 73), (11.1, 1672), (11.1, 1117), (11.0, 1643), (9.5, 18), (11.2, 1629), (11.2, 1616), (11.2, 202)],
    -6: [(7.7, 2480), (7.7, 2394), (7.7, 2473), (7.7, 2476), (7.7, 2485), (7.7, 2543), (7.7, 1505), (7.7, 2475), (7.7, 2288), (7.7, 1515)],
    -4: [(4.8, 4096), (4.8, 4175), (4.8, 3154), (4.7, 4231), (4.8, 4124), (4.9, 4068), (4.7, 4224), (4.8, 4184), (4.8, 4217), (4.8, 4213)],
    -2: [(3.1, 4682), (3.1, 2437), (2.4, 8867), (2.4, 8791), (2.4, 626), (2.4, 8823), (2.3, 6347), (2.9, 5955), (2.3, 4666), (3.0, 6474)],
}

def fig_ruido():
    x = list(range(len(RUIDO)))
    etiquetas = [f"−{abs(r)}" for r in RUIDO]
    rnd = random.Random(7)
    fig, (a, b) = plt.subplots(2, 1, figsize=(7.4, 7.8), sharex=True)
    for ax, cub, mar, idx in ((a, CUBIC_G, MARC_G, 0), (b, CUBIC_R, MARC_R, 1)):
        for datos, color, marca, nombre, dx in ((cub, ROJO, "o", "Cubic", -0.08),
                                                (mar, AZUL, "D", "Prague con marcado en el gNB", 0.08)):
            med = [d[0] for d in datos]
            err = [[d[0] - d[1] for d in datos], [d[2] - d[0] for d in datos]]
            ax.errorbar([i + dx for i in x], med, yerr=err, color=color, marker=marca, markersize=6,
                        linewidth=1.8, capsize=3, label=f"{nombre} (mediana y rango)", zorder=3)
        px, py = [], []
        for i, r in enumerate(RUIDO):
            for prueba in SIN[r]:
                px.append(i + rnd.uniform(-0.05, 0.05)); py.append(prueba[idx])
        ax.scatter(px, py, s=26, marker="s", facecolors="none", edgecolors=NARANJA, linewidths=1.3,
                   label="Prague sin marcado (cada prueba)", zorder=4)
        ax.set_xticks(x); ax.set_xticklabels(etiquetas)
    b.set_xlabel("Potencia de ruido en bajada (dB)")
    a.set_ylabel("Goodput (Mbit/s)")
    a.set_ylim(0, 19)
    a.yaxis.set_major_formatter(FMT)
    a.set_title("Goodput")
    asas, nombres = a.get_legend_handles_labels()
    orden = [1, 2, 0]
    fig.legend([asas[i] for i in orden], [nombres[i] for i in orden], loc="lower center", ncol=1,
               fontsize=10, frameon=False, bbox_to_anchor=(0.5, -0.09))
    b.set_yscale("log")
    b.set_ylim(8, 20000)
    b.yaxis.set_major_locator(FixedLocator([10, 100, 1000, 10000]))
    b.yaxis.set_major_formatter(FuncFormatter(lambda v, _p: {10: "10", 100: "100", 1000: "1000", 10000: "10 000"}.get(int(v), "")))
    b.yaxis.set_minor_formatter(NullFormatter())
    b.grid(True, which="minor", alpha=0.15)
    b.set_ylabel("RTT medio (ms, escala logarítmica)")
    b.set_title("RTT medio")
    fig.suptitle("Celda de 10 MHz con ruido en bajada", y=0.995, fontsize=12)
    fig.tight_layout()
    guardar(fig, "5g_10mhz_ruido")

# ---------------------------------------------------------------------------
# 3. Celda de 40 MHz sin ruido (bajada, 10 repeticiones, media e IC 95 %)
# ---------------------------------------------------------------------------
def fig_40mhz():
    casos = ["Cubic", "Prague,\nsin marcado", "Prague,\ndualpi2\nen la UPF", "Prague,\nmarcado\nen el gNB"]
    color = [ROJO, NARANJA, NARANJA, AZUL]
    g, gi = [82.33, 17.77, 21.27, 69.96], [0.03, 1.71, 4.26, 0.13]
    r, ri = [180.3, 13.0, 13.2, 16.3], [18.6, 0.2, 0.3, 0.3]
    fig, (a, b) = plt.subplots(1, 2, figsize=(8.6, 4.1))
    x = list(range(4))
    barras = a.bar(x, g, yerr=gi, color=color, width=0.6, capsize=4, edgecolor="white", linewidth=1.5)
    barras[2].set_hatch("///")
    for i, v in enumerate(g):
        a.text(i, v + gi[i] + 1.5, coma(v, 1), ha="center", fontsize=9.5)
    a.set_xticks(x); a.set_xticklabels(casos, fontsize=9)
    a.set_ylim(0, 95); a.set_ylabel("Goodput (Mbit/s)"); a.set_title("Goodput")
    a.grid(axis="x", visible=False)
    for i in x:
        b.errorbar([i], [r[i]], yerr=[ri[i]], color=color[i], marker="osD"[min(i, 2)] if i != 2 else "s",
                   markersize=8, capsize=4, linewidth=1.8, markerfacecolor="white" if i == 2 else color[i])
        b.text(i + 0.14, r[i], coma(r[i], 1) + " ms", va="center", fontsize=9.5)
    b.set_yscale("log"); b.set_ylim(8, 400)
    b.yaxis.set_major_locator(FixedLocator([10, 20, 50, 100, 200]))
    b.yaxis.set_major_formatter(FuncFormatter(lambda v, _p: f"{int(v)}"))
    b.yaxis.set_minor_formatter(NullFormatter())
    b.set_xticks(x); b.set_xticklabels(casos, fontsize=9); b.set_xlim(-0.5, 4.05)
    b.set_ylabel("RTT medio (ms, escala logarítmica)"); b.set_title("RTT medio")
    b.grid(axis="x", visible=False)
    fig.suptitle("Celda de 40 MHz sin ruido, bajada", y=1.0, fontsize=12)
    fig.tight_layout()
    guardar(fig, "5g_40mhz_resumen")

# ---------------------------------------------------------------------------
# 4. Reparto del retardo por tramos (capturas, celda de 40 MHz)
# ---------------------------------------------------------------------------
def fig_tramos():
    # (celda, caso, núcleo + respuesta de la UE, bajada, subida, total), medias en ms
    filas = [("40 MHz, sin ruido", "En reposo", 0.874 + 0.051, 2.386, 9.742, 13.053),
             ("40 MHz, sin ruido", "Prague sin marcado", 0.518 + 0.028, 2.632, 12.486, 15.664),
             ("40 MHz, sin ruido", "Prague con marcado", 0.621 + 0.024, 5.973, 11.351, 17.968),
             ("10 MHz, ruido de −4 dB", "En reposo", 0.406 + 0.046, 2.921, 9.475, 12.847),
             ("10 MHz, ruido de −4 dB", "Prague con marcado", 0.387 + 0.028, 12.192, 12.583, 25.190)]
    y = [5.2, 4.2, 3.2, 1.6, 0.6]
    fig, ax = plt.subplots(figsize=(7.6, 4.8))
    izq = [0.0] * len(filas)
    for k, color, nombre in ((2, C_NUCLEO, "Núcleo (servidor y UPF): 0,4–0,9 ms"),
                             (3, C_BAJADA, "Bajada: UPF → gNB → UE"),
                             (4, C_SUBIDA, "Subida: UE → gNB → UPF")):
        datos = [f[k] for f in filas]
        ax.barh(y, datos, left=izq, color=color, height=0.6, edgecolor="white", linewidth=2, label=nombre)
        for i, d in enumerate(datos):
            if d >= 2:
                ax.text(izq[i] + d / 2, y[i], coma(d, 1), ha="center", va="center", color="white",
                        fontsize=10, fontweight="bold")
        izq = [izq[i] + datos[i] for i in range(len(filas))]
    for i, f in enumerate(filas):
        ax.text(f[5] + 0.4, y[i], f"total {coma(f[5], 1)} ms", va="center", fontsize=10)
    ax.set_yticks(y); ax.set_yticklabels([f[1] for f in filas])
    ax.text(0.0, 5.85, "Celda de 40 MHz, sin ruido", fontsize=10, fontweight="bold", color=GRIS)
    ax.text(0.0, 2.25, "Celda de 10 MHz, ruido de −4 dB", fontsize=10, fontweight="bold", color=GRIS)
    ax.set_ylim(0.1, 6.3)
    ax.set_xlim(0, 33); ax.set_xlabel("Retardo medio de ida y vuelta de un ping (ms)")
    ax.xaxis.set_major_formatter(FMT)
    ax.grid(axis="y", visible=False)
    ax.legend(loc="upper center", bbox_to_anchor=(0.42, -0.17), ncol=1, fontsize=10, frameon=False)
    ax.set_title("Reparto del retardo por tramos")
    fig.tight_layout()
    guardar(fig, "5g_retardo_tramos")

if __name__ == "__main__":
    fig_calibracion(); fig_ruido(); fig_40mhz(); fig_tramos()
    print("Figuras generadas en", OUT)
