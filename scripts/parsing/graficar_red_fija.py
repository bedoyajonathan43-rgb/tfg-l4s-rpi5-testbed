#!/usr/bin/env python3
"""Genera las figuras de red fija de la memoria que salen de las tablas de metricas/red_fija/.

Uso:  python3 scripts/parsing/graficar_red_fija.py [carpeta_con_los_csv] [carpeta_de_salida]

Sin argumentos lee metricas/red_fija/ y escribe en figuras/, en PDF y PNG:

    baseline_comparativa         un flujo, sin límite: throughput y RTT por escenario
    comparativa_throughput       un flujo: throughput frente al ancho de banda
    comparativa_rtt              un flujo: RTT frente al ancho de banda
    paralelo_throughput          dos flujos: throughput agregado
    paralelo_rtt                 dos flujos: RTT
    ruido_reparto_throughput     convivencia: cuota del flujo principal
    ruido_rtt_colas_e4           convivencia: RTT de cada cola de dualpi2
    sarpkaya_reparto_throughput  Sarpkaya: cuota de Prague según el buffer

Antes hay que generar las tablas con calcular_metricas.py.
"""
import csv
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from comun import BUFFERS, DIR_FIGURAS, DIR_METRICAS

ESC = ["E1", "E2", "E3", "E4"]
LABELS = {"E1": "E1 - pfifo (Cubic, sin ECN)", "E2": "E2 - fq_codel (Cubic, sin ECN)",
          "E3": "E3 - fq_codel (Cubic, ECN)", "E4": "E4 - dualpi2 (Prague, AccECN)"}
COLORS = {"E1": "#d62728", "E2": "#ff7f0e", "E3": "#2ca02c", "E4": "#1f77b4"}
MARKERS = {"E1": "o", "E2": "s", "E3": "^", "E4": "D"}
BW = ["1mbit", "2mbit", "5mbit", "10mbit", "20mbit", "50mbit", "100mbit", "200mbit", "500mbit"]
X = [float(b.replace("mbit", "")) for b in BW]


def estilo():
    matplotlib.rcdefaults()
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 11, "figure.dpi": 150})


def rejilla(ax):
    ax.grid(True, which="both", linestyle="--", alpha=0.4)


def leer(path):
    d = {}
    with open(path) as f:
        for r in csv.DictReader(f):
            d.setdefault(r["serie"], {})[r["ancho_de_banda"]] = (float(r["throughput_mbit"]), float(r["rtt_ms"]))
    return d


def guardar(fig, out, nombre, ajustar=True):
    if ajustar:
        fig.tight_layout()
    fig.savefig(Path(out) / f"{nombre}.pdf")
    fig.savefig(Path(out) / f"{nombre}.png")
    plt.close(fig)


def por_escenario(datos, campo, ylabel, titulo, legend_loc, out, nombre):
    fig, ax = plt.subplots(figsize=(7.5, 5))
    for e in ESC:
        ys = [datos[e][b][campo] for b in BW]
        ax.plot(X, ys, marker=MARKERS[e], color=COLORS[e], label=LABELS[e], linewidth=2, markersize=7)
    ax.set_xscale("log"); ax.set_yscale("log")
    ax.set_xlabel("Ancho de banda limitado (Mbit/s, escala log)")
    ax.set_ylabel(ylabel)
    ax.set_title(titulo)
    ax.set_xticks(X); ax.set_xticklabels([b.replace("mbit", "") for b in BW])
    rejilla(ax)
    ax.legend(loc=legend_loc, fontsize=9)
    guardar(fig, out, nombre)


def baseline(datos, out):
    fig, ejes = plt.subplots(1, 2, figsize=(9.6, 4.6))
    for ax, campo, titulo, ylabel, tope, dec in (
            (ejes[0], 0, "Throughput medio — Baseline (sin límite HTB)", "Throughput medio (Mbit/s)", 1050, 0),
            (ejes[1], 1, "RTT medio — Baseline (sin límite HTB)", "RTT medio (ms)", 3.2, 2)):
        for i, e in enumerate(ESC):
            v = datos[e]["baseline"][campo]
            ax.plot([i], [v], marker=MARKERS[e], color=COLORS[e], markersize=11, linestyle="none", label=LABELS[e])
            ax.annotate(f"{v:.{dec}f}", (i, v), xytext=(0, 9), textcoords="offset points", ha="center", fontsize=10)
        ax.set_xticks(range(len(ESC))); ax.set_xticklabels(ESC)
        ax.set_xlim(-0.15, len(ESC) - 0.85)
        ax.set_ylim(0, tope)
        ax.set_ylabel(ylabel)
        ax.set_title(titulo)
        ax.grid(True, axis="y", linestyle="--", alpha=0.4)
    asas, etiquetas = ejes[0].get_legend_handles_labels()
    fig.legend(asas, etiquetas, loc="lower center", ncol=2, fontsize=9, frameon=False)
    fig.tight_layout(rect=(0, 0.13, 1, 1))
    guardar(fig, out, "baseline_comparativa", ajustar=False)


def ruido_reparto(csvdir, out):
    cuota = {}
    with open(Path(csvdir) / "tabla_ruido_reparto.csv") as f:
        for r in csv.DictReader(f):
            cuota.setdefault(r["escenario"], {})[r["ancho_de_banda"]] = float(r["cuota_principal_pct"])
    fig, ax = plt.subplots(figsize=(7.5, 5))
    for e in ESC:
        ax.plot(X, [cuota[e][b] for b in BW], marker=MARKERS[e], color=COLORS[e], label=LABELS[e], linewidth=2, markersize=7)
    ax.axhline(50, color="black", linestyle=":", linewidth=1)
    ax.set_xscale("log")
    ax.set_ylim(0, 100)
    ax.set_xlabel("Ancho de banda limitado (Mbit/s, escala log)")
    ax.set_ylabel("Cuota de throughput del flujo principal (%)")
    ax.set_title("Cuota de throughput del flujo principal sobre el total\n(principal + ruido Cubic sin ECN)")
    ax.set_xticks(X); ax.set_xticklabels([b.replace("mbit", "") for b in BW])
    rejilla(ax)
    ax.legend(loc="lower right", fontsize=9)
    guardar(fig, out, "ruido_reparto_throughput")


def ruido_e4(datos, out):
    cats = ["baseline"] + BW
    pos = list(range(len(cats)))
    fig, ax = plt.subplots(figsize=(7.5, 5))
    ax.plot(pos, [datos["E4_principal_Prague"][b][1] for b in cats], marker="D", color="#1f77b4",
            label="Principal (Prague, cola L4S)", linewidth=2, markersize=7)
    ax.plot(pos, [datos["E4_ruido_Cubic"][b][1] for b in cats], marker="o", color="#7f7f7f",
            label="Ruido (Cubic, cola clásica)", linewidth=2, markersize=7)
    ax.set_yscale("log")
    ax.set_xlabel("Ancho de banda limitado (Mbit/s)")
    ax.set_ylabel("RTT medio (ms, escala log)")
    ax.set_title("RTT medio por cola en E4 (dualpi2): Prague vs Cubic\ncoexistiendo en la misma disciplina")
    ax.set_xticks(pos); ax.set_xticklabels(["Sin\nlímite"] + [b.replace("mbit", "") for b in BW])
    rejilla(ax)
    ax.legend(loc="upper right", fontsize=9)
    guardar(fig, out, "ruido_rtt_colas_e4")


def sarpkaya(csvdir, out):
    cuota = {}
    with open(Path(csvdir) / "tabla_sarpkaya.csv") as f:
        for r in csv.DictReader(f):
            cuota.setdefault(r["escenario"], {})[r["buffer"]] = float(r["cuota_prague_pct"])
    etiquetas = {"E1": "E1 - pfifo", "E2": "E2 - fq_codel (sin ECN)", "E3": "E3 - fq_codel (ECN)", "E4": "E4 - dualpi2 + Prague"}
    pos = list(range(len(BUFFERS)))
    fig, ax = plt.subplots(figsize=(8, 5.2))
    for e in ESC:
        ax.plot(pos, [cuota[e][b] for b in BUFFERS], marker=MARKERS[e], color=COLORS[e], label=etiquetas[e], linewidth=2, markersize=7)
    ax.axhline(50, color="gray", linestyle="--", linewidth=1, label="Reparto equitativo (50%)")
    ax.set_ylim(0, 100)
    ax.set_xticks(pos); ax.set_xticklabels(BUFFERS)
    ax.set_xlabel("Tamaño de buffer")
    ax.set_ylabel("Cuota de throughput de Prague sobre el total (%)")
    ax.set_title("Reparto de throughput Prague/Cubic por escenario AQM\ny tamaño de buffer (100 Mbit/s, RTT=10 ms)")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper left", fontsize=9)
    guardar(fig, out, "sarpkaya_reparto_throughput")


def main(csvdir, out):
    estilo()
    Path(out).mkdir(parents=True, exist_ok=True)
    uno = leer(Path(csvdir) / "tabla_un_flujo.csv")
    dos = leer(Path(csvdir) / "tabla_dos_flujos.csv")
    rui = leer(Path(csvdir) / "tabla_ruido_E4.csv")
    baseline(uno, out)
    por_escenario(uno, 0, "Throughput medio (Mbit/s, escala log)",
                  "Throughput medio por escenario AQM\n(flujo único TCP, testbed rp51-rp50-rp52)",
                  "upper left", out, "comparativa_throughput")
    por_escenario(uno, 1, "RTT medio (ms, escala log)",
                  "RTT medio por escenario AQM\n(flujo único TCP, testbed rp51-rp50-rp52)",
                  "upper right", out, "comparativa_rtt")
    por_escenario(dos, 0, "Throughput agregado medio (Mbit/s, escala log)",
                  "Throughput agregado medio por escenario AQM\n(2 flujos TCP paralelos, testbed rp51-rp50-rp52)",
                  "upper left", out, "paralelo_throughput")
    por_escenario(dos, 1, "RTT medio (ms, escala log)",
                  "RTT medio por escenario AQM\n(2 flujos TCP paralelos, testbed rp51-rp50-rp52)",
                  "upper right", out, "paralelo_rtt")
    ruido_reparto(csvdir, out)
    ruido_e4(rui, out)
    sarpkaya(csvdir, out)
    print("figuras escritas en", out)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else DIR_METRICAS, sys.argv[2] if len(sys.argv) > 2 else DIR_FIGURAS)
