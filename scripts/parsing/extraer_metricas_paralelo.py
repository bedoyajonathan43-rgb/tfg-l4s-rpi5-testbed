#!/usr/bin/env python3
"""
Extrae throughput agregado (SUM) y RTT medio (promediado entre los 2 flujos)
de los ficheros _cliente.txt de la campaña de flujos paralelos homogéneos.

Uso:
    Ejecutar desde la raíz del repositorio, con los resultados ya
    descargados en ./resultados/resultadosFinales_paraleloC/<lote_bw>/...

    python3 scripts/parsing/extraer_metricas_paralelo.py

Genera: ./metricas/metricas_paralelo.csv
"""
import re
import csv
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BASE = REPO_ROOT / "resultados" / "resultadosFinales_paraleloC"
OUT_CSV = REPO_ROOT / "metricas" / "metricas_paralelo.csv"

ESCENARIOS = {
    "E1_pfifo": "E1 (pfifo)",
    "E2_fq_codel": "E2 (fq_codel, sin ECN)",
    "E3_fq_codel_ecn": "E3 (fq_codel, ECN)",
    "E4_dualpi2_prague": "E4 (dualpi2 + Prague)",
}

BW_ORDER = ["1mbit", "2mbit", "5mbit", "10mbit", "20mbit", "50mbit", "100mbit", "200mbit", "500mbit"]
BW_NUMERIC = {b: float(b.replace("mbit", "")) for b in BW_ORDER}

# Línea de intervalo por flujo individual: [  1] 0.00-1.00 sec ... RTT(var)) us
INTERVAL_RE = re.compile(
    r"\[\s*(\d+)\]\s+([\d.]+)-([\d.]+)\s+sec\s+.*?(\d+)\((\d+)\)\s+us"
)

# Línea resumen agregada: [SUM-2] 0.00-XX.XX sec  Transfer  Bandwidth  Write/Err  Rtry
SUM_SUMMARY_RE = re.compile(
    r"\[SUM-\d+\]\s+0\.00-([\d.]+)\s+sec\s+[\d.]+\s+[KMG]Bytes\s+([\d.]+)\s+(Mbits|Kbits|Gbits)/sec\s+(\d+)/(\d+)"
)

def to_mbits(value, unit):
    value = float(value)
    if unit == "Kbits":
        return value / 1000
    if unit == "Gbits":
        return value * 1000
    return value

def parse_client_file(path: Path):
    text = path.read_text(errors="ignore")
    lines = text.splitlines()

    # --- Throughput agregado y reintentos: línea SUM resumen final ---
    avg_thr_mbps = None
    retries = None
    for line in lines:
        m = SUM_SUMMARY_RE.search(line)
        if m:
            avg_thr_mbps = to_mbits(m.group(2), m.group(3))
            retries = int(m.group(5))
    if avg_thr_mbps is None:
        return None

    # --- RTT medio: promedio de los RTT por intervalo de ambos flujos,
    #     descartando warm-up (t<2s) y el intervalo final parcial ---
    rtts_us = []
    for line in lines:
        m = INTERVAL_RE.search(line)
        if not m:
            continue
        t0, t1 = float(m.group(2)), float(m.group(3))
        rtt_us = int(m.group(4))
        if t0 < 2.0:
            continue
        if (t1 - t0) < 0.99:
            continue
        rtts_us.append(rtt_us)

    avg_rtt_ms = (sum(rtts_us) / len(rtts_us) / 1000) if rtts_us else None

    return {
        "avg_throughput_mbps": round(avg_thr_mbps, 3),
        "avg_rtt_ms": round(avg_rtt_ms, 3) if avg_rtt_ms is not None else None,
        "retries_total": retries,
        "n_intervals_rtt": len(rtts_us),
    }

def main():
    if not BASE.exists():
        raise SystemExit(
            f"[ERROR] No existe la carpeta de resultados: {BASE}\n"
            f"Copia ahí los resultados de la campaña de flujos paralelos "
            f"(estructura: resultados/resultadosFinales_paraleloC/<lote_bw>/...)."
        )

    rows = []
    bw_dirs = sorted(BASE.iterdir(), key=lambda p: (p.name != "baseline", BW_NUMERIC.get(p.name, 0)))
    for bw_dir in bw_dirs:
        if not bw_dir.is_dir():
            continue
        bw_label = bw_dir.name
        for prefix, nombre_legible in ESCENARIOS.items():
            client_file = bw_dir / f"{prefix}_cliente.txt"
            if not client_file.exists():
                continue
            result = parse_client_file(client_file)
            if result is None:
                print(f"[!] No se pudo parsear: {client_file}")
                continue
            rows.append({
                "bw_lote": bw_label,
                "escenario_id": prefix,
                "escenario": nombre_legible,
                **result,
            })

    OUT_CSV.parent.mkdir(parents=True, exist_ok=True)
    with OUT_CSV.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    print(f"[OK] {len(rows)} filas escritas en {OUT_CSV}")
    for r in rows:
        print(r)

if __name__ == "__main__":
    main()
