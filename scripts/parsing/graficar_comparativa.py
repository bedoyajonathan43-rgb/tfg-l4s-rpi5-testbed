#!/usr/bin/env python3
"""
Genera las gráficas comparativas de throughput y RTT medio por escenario AQM
en función del ancho de banda limitado, a partir del CSV producido por
extraer_metricas.py (campaña de flujo individual).

Uso:
    Ejecutar desde la raíz del repositorio, tras haber generado
    ./metricas/metricas_individual.csv con extraer_metricas.py:

    python3 scripts/parsing/graficar_comparativa.py

Genera: ./figuras/comparativa_throughput.{png,pdf}
         ./figuras/comparativa_rtt.{png,pdf}
"""
import csv
from pathlib import Path
import matplotlib.pyplot as plt

REPO_ROOT = Path(__file__).resolve().parents[2]
CSV_PATH = REPO_ROOT / "metricas" / "metricas_individual.csv"
OUT_DIR = REPO_ROOT / "figuras"
OUT_DIR.mkdir(parents=True, exist_ok=True)

ESCENARIOS = ["E1_pfifo", "E2_fq_codel", "E3_fq_codel_ecn", "E4_dualpi2_prague"]
LABELS = {
    "E1_pfifo": "E1 – pfifo (Cubic, sin ECN)",
    "E2_fq_codel": "E2 – fq_codel (Cubic, sin ECN)",
    "E3_fq_codel_ecn": "E3 – fq_codel (Cubic, ECN)",
    "E4_dualpi2_prague": "E4 – dualpi2 (Prague, AccECN)",
}
COLORS = {
    "E1_pfifo": "#d62728",
    "E2_fq_codel": "#ff7f0e",
    "E3_fq_codel_ecn": "#2ca02c",
    "E4_dualpi2_prague": "#1f77b4",
}
MARKERS = {
    "E1_pfifo": "o",
    "E2_fq_codel": "s",
    "E3_fq_codel_ecn": "^",
    "E4_dualpi2_prague": "D",
}

BW_ORDER = ["1mbit", "2mbit", "5mbit", "10mbit", "20mbit", "50mbit", "100mbit", "200mbit", "500mbit"]
BW_X = {b: float(b.replace("mbit", "")) for b in BW_ORDER}

def main():
    if not CSV_PATH.exists():
        raise SystemExit(
            f"[ERROR] No existe {CSV_PATH}.\n"
            f"Ejecuta primero: python3 scripts/parsing/extraer_metricas.py"
        )

    # --- Cargar datos ---
    data = {e: {} for e in ESCENARIOS}
    with CSV_PATH.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row["bw_lote"] == "baseline":
                continue  # se trata aparte, no forma parte de la progresión de BW
            e = row["escenario_id"]
            bw = row["bw_lote"]
            if bw not in BW_X:
                continue
            data[e][bw] = {
                "thr": float(row["avg_throughput_mbps"]),
                "rtt": float(row["avg_rtt_ms"]) if row["avg_rtt_ms"] else None,
            }

    plt.rcParams.update({
        "font.size": 11,
        "axes.grid": True,
        "grid.alpha": 0.3,
        "figure.dpi": 150,
    })

    xs_ref = [BW_X[b] for b in BW_ORDER]

    # ============================================================
    # Gráfica 1: Throughput medio vs. ancho de banda limitado
    # ============================================================
    fig, ax = plt.subplots(figsize=(7.5, 5))
    for e in ESCENARIOS:
        xs = [BW_X[b] for b in BW_ORDER if b in data[e]]
        ys = [data[e][b]["thr"] for b in BW_ORDER if b in data[e]]
        ax.plot(xs, ys, marker=MARKERS[e], color=COLORS[e], label=LABELS[e], linewidth=1.8, markersize=6)

    # Línea de referencia y = x (throughput ideal = límite HTB)
    ax.plot(xs_ref, xs_ref, linestyle="--", color="gray", linewidth=1, label="Límite HTB (ideal)", zorder=0)

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("Ancho de banda limitado (Mbit/s, escala log)")
    ax.set_ylabel("Throughput medio (Mbit/s, escala log)")
    ax.set_title("Throughput medio por escenario AQM\n(flujo único TCP, testbed rp51–rp50–rp52)")
    ax.set_xticks(xs_ref)
    ax.set_xticklabels([b.replace("mbit", "") for b in BW_ORDER])
    ax.legend(loc="upper left", fontsize=9)
    fig.tight_layout()
    fig.savefig(OUT_DIR / "comparativa_throughput.png")
    fig.savefig(OUT_DIR / "comparativa_throughput.pdf")
    plt.close(fig)

    # ============================================================
    # Gráfica 2: RTT medio vs. ancho de banda limitado
    # ============================================================
    fig, ax = plt.subplots(figsize=(7.5, 5))
    for e in ESCENARIOS:
        xs = [BW_X[b] for b in BW_ORDER if b in data[e] and data[e][b]["rtt"] is not None]
        ys = [data[e][b]["rtt"] for b in BW_ORDER if b in data[e] and data[e][b]["rtt"] is not None]
        ax.plot(xs, ys, marker=MARKERS[e], color=COLORS[e], label=LABELS[e], linewidth=1.8, markersize=6)

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("Ancho de banda limitado (Mbit/s, escala log)")
    ax.set_ylabel("RTT medio (ms, escala log)")
    ax.set_title("RTT medio por escenario AQM\n(flujo único TCP, testbed rp51–rp50–rp52)")
    ax.set_xticks(xs_ref)
    ax.set_xticklabels([b.replace("mbit", "") for b in BW_ORDER])
    ax.legend(loc="upper right", fontsize=9)
    fig.tight_layout()
    fig.savefig(OUT_DIR / "comparativa_rtt.png")
    fig.savefig(OUT_DIR / "comparativa_rtt.pdf")
    plt.close(fig)

    print("Gráficas generadas en", OUT_DIR)

if __name__ == "__main__":
    main()
