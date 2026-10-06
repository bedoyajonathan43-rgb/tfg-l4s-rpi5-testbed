#!/usr/bin/env python3
"""Genera las dos figuras de evolución temporal de red fija a partir de las salidas en bruto de iperf2.

Uso:  python3 scripts/parsing/graficar_series_temporales.py [carpeta_de_datos | fichero.zip] [carpeta_de_salida]

    serie_temporal_rtt_1mbit   un flujo a 1 Mbit/s: RTT de cada intervalo de 1 s del cliente en E1 y E4.
                               Se dibujan todos los intervalos de 0 a 60 s, también los de 0 bytes,
                               y no el intervalo final parcial (mismo criterio que calcular_metricas.py).
    ruido_caso_1mbit_colapso   convivencia a 1 Mbit/s en E4: throughput que recibe el servidor en cada
                               segundo, del flujo Prague y del flujo de ruido Cubic. Cada curva usa el
                               tiempo de su propio servidor; el ruido arranca en realidad unos segundos después.
"""
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from comun import DIR_FIGURAS, Datos, intervalos_cliente, intervalos_servidor


def estilo():
    matplotlib.rcdefaults()
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 11, "figure.dpi": 150})


def guardar(fig, out, nombre):
    fig.tight_layout()
    fig.savefig(Path(out) / f"{nombre}.pdf")
    fig.savefig(Path(out) / f"{nombre}.png")
    plt.close(fig)


def rtt_1mbit(d, out):
    series = [("E1_pfifo", "E1 - pfifo (Cubic, sin ECN)", "#d62728", "o"),
              ("E4_dualpi2_prague", "E4 - dualpi2 (Prague, AccECN)", "#1f77b4", "D")]
    fig, ax = plt.subplots(figsize=(7.5, 5))
    for nombre, etiqueta, color, marca in series:
        iv = [x for x in intervalos_cliente(d, f"resultadosFinales_1_flujoC/1mbit/{nombre}_cliente.txt") if x[0] < 60]
        t, rtt = [x[0] for x in iv], [x[2] for x in iv]
        ax.plot(t, rtt, marker=marca, color=color, label=etiqueta, linewidth=1.5, markersize=4)
        r2 = [r for x, r in zip(t, rtt) if x >= 2]
        print(f"  {nombre}: {len(t)} intervalos ({sum(1 for x in iv if x[3] == 0)} de 0 bytes); desde t = 2 s: n = {len(r2)}, "
              f"media = {sum(r2) / len(r2):.3f} ms, min = {min(r2):.3f}, max = {max(r2):.3f}; max total = {max(rtt):.3f}")
    ax.set_yscale("log")
    ax.set_xlabel("Tiempo (s)")
    ax.set_ylabel("RTT instantáneo (ms, escala log)")
    ax.set_title("Evolución temporal del RTT a 1 Mbit/s\n(flujo único TCP): E1 vs E4")
    ax.grid(True, which="both", linestyle="--", alpha=0.4)
    ax.legend(loc="center right", fontsize=9)
    guardar(fig, out, "serie_temporal_rtt_1mbit")


def colapso_1mbit(d, out):
    base = "resultados_flujo_ruidoCD/1mbit/E4_dualpi2_prague"
    pr = intervalos_servidor(d, base + "_servidor.txt")
    ru = intervalos_servidor(d, base + "_ruido_servidor.txt")
    fig, ax = plt.subplots(figsize=(7.5, 5))
    ax.plot([x[0] for x in pr], [x[1] for x in pr], marker="D", color="#1f77b4", label="Principal (Prague, cola L4S)",
            linewidth=1.5, markersize=4)
    ax.plot([x[0] for x in ru], [x[1] for x in ru], marker="o", color="#7f7f7f", label="Ruido (Cubic, cola clásica)",
            linewidth=1.5, markersize=4)
    ax.set_xlabel("Tiempo (s)")
    ax.set_ylabel("Throughput instantáneo recibido en servidor (Mbit/s)")
    ax.set_title("Colapso del flujo Prague a 1 Mbit/s en coexistencia\ncon ruido Cubic (datos de servidor)")
    ax.grid(True, linestyle="--", alpha=0.4)
    ax.legend(loc="center right", fontsize=9)
    guardar(fig, out, "ruido_caso_1mbit_colapso")
    p5 = [x[1] for x in pr if x[0] >= 5]
    print(f"  Prague: {len(pr)} intervalos; desde t = 5 s, media = {1000 * sum(p5) / len(p5):.2f} kbit/s, máx = {1000 * max(p5):.1f} kbit/s. "
          f"Cubic: {len(ru)} intervalos, media = {sum(x[1] for x in ru) / len(ru):.3f} Mbit/s")


if __name__ == "__main__":
    datos = Datos(sys.argv[1] if len(sys.argv) > 1 else None)
    salida = Path(sys.argv[2]) if len(sys.argv) > 2 else DIR_FIGURAS
    salida.mkdir(parents=True, exist_ok=True)
    estilo()
    rtt_1mbit(datos, salida)
    colapso_1mbit(datos, salida)
    print("figuras escritas en", salida)
