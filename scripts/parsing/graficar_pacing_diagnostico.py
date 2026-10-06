#!/usr/bin/env python3
"""Dibuja la evolución del pacing_rate de Prague con y sin RTT emulado (figura sarpkaya_diagnostico_rtt_pacing).

Uso:
    python3 scripts/parsing/graficar_pacing_diagnostico.py <ss_prague_sin_rtt.txt> <ss_prague_con_rtt.txt> [carpeta_de_salida]

Los dos ficheros son los que guarda el script de diagnóstico en rp51 (scripts/diagnostico/): una línea
cada 0,5 s con el formato  <segundos>;<salida de ss -tiom en una línea>.
El primero es la captura sin netem (RTT de unos 0,4 ms) y el segundo la captura con 10 ms de RTT emulado.
Estas capturas no están en resultados/red_fija_iperf.zip.
"""
import re
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from comun import DIR_FIGURAS

U = {"": 1e-6, "K": 1e-3, "M": 1.0, "G": 1e3}


def leer(path):
    """Lista de (t, pacing en Mbit/s, etiqueta del algoritmo, cwnd, retransmisiones acumuladas)."""
    out = []
    for l in Path(path).read_text(errors="ignore").splitlines():
        t, _, resto = l.partition(";")
        m = re.search(r"pacing_rate ([\d.]+)([KMG]?)bps", resto)
        try:
            t = float(t)
        except ValueError:
            continue
        if not m:
            continue
        alg = re.search(r"\b(prague(?:-reno)?)\b", resto)
        cwnd = re.search(r"cwnd:(\d+)", resto)
        retr = re.search(r"retrans:\d+/(\d+)", resto)
        out.append((t, float(m.group(1)) * U[m.group(2)], alg.group(1) if alg else "?",
                    int(cwnd.group(1)) if cwnd else None, int(retr.group(1)) if retr else 0))
    return out


def resumen(nombre, v):
    p = [x[1] for x in v]
    print(f"  {nombre}: {len(v)} muestras, de t = {v[0][0]:.1f} a {v[-1][0]:.1f} s; pacing_rate de {min(p):.1f} a {max(p):.1f} Mbit/s; "
          f"etiquetas {sorted({x[2] for x in v})}; cwnd de {v[0][3]} a {v[-1][3]}; retransmisiones {v[-1][4]}")


def main(sin_rtt, con_rtt, out):
    matplotlib.rcdefaults()
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 11, "figure.dpi": 150})
    a, b = leer(sin_rtt), leer(con_rtt)
    resumen("sin RTT emulado", a)
    resumen("con RTT de 10 ms", b)
    fig, ax = plt.subplots(figsize=(8.5, 5))
    ax.plot([x[0] for x in a], [x[1] for x in a], marker="o", markersize=3, linewidth=1.3, color="#1f77b4",
            label="Sin RTT emulado (RTT≈0,4 ms) - etiqueta prague-reno")
    ax.plot([x[0] for x in b], [x[1] for x in b], linewidth=1.5, color="#d62728",
            label="Con RTT emulado 10 ms (netem) - etiqueta prague (sin fallback)")
    ax.set_xlim(0, 25)
    ax.set_ylim(0, 300)
    ax.set_xlabel("Tiempo de prueba (s)")
    ax.set_ylabel("pacing_rate del flujo Prague (Mbit/s)")
    ax.set_title("Evolución del pacing_rate de Prague bajo fq_codel (E2, 1xBDP):\nefecto del RTT base sobre la heurística de respaldo ECN")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper right", fontsize=9)
    fig.tight_layout()
    Path(out).mkdir(parents=True, exist_ok=True)
    fig.savefig(Path(out) / "sarpkaya_diagnostico_rtt_pacing.pdf")
    fig.savefig(Path(out) / "sarpkaya_diagnostico_rtt_pacing.png")
    print("figura escrita en", out)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else DIR_FIGURAS)
