#!/usr/bin/env python3
"""
Extrae throughput medio y RTT medio del flujo PRINCIPAL (por escenario E1-E4)
y del flujo de RUIDO (Cubic, sin ECN) concurrente, para la campaña de
coexistencia.

Uso:
    Ejecutar desde la raíz del repositorio, con los resultados ya
    descargados en ./resultados/resultados_flujo_ruidoCD/<lote_bw>/...

    python3 scripts/parsing/extraer_metricas_ruido.py

Genera: ./metricas/metricas_ruido.csv
"""
import re
import csv
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BASE = REPO_ROOT / "resultados" / "resultados_flujo_ruidoCD"
OUT_CSV = REPO_ROOT / "metricas" / "metricas_ruido.csv"

ESCENARIOS = {
    "E1_pfifo": "E1 (pfifo)",
    "E2_fq_codel": "E2 (fq_codel, sin ECN)",
    "E3_fq_codel_ecn": "E3 (fq_codel, ECN)",
    "E4_dualpi2_prague": "E4 (dualpi2 + Prague)",
}

BW_ORDER = ["1mbit", "2mbit", "5mbit", "10mbit", "20mbit", "50mbit", "100mbit", "200mbit", "500mbit"]
BW_NUMERIC = {b: float(b.replace("mbit", "")) for b in BW_ORDER}

INTERVAL_RE = re.compile(
    r"\[\s*\d+\]\s+([\d.]+)-([\d.]+)\s+sec\s+.*?(\d+)\((\d+)\)\s+us"
)
SUMMARY_RE = re.compile(
    r"\[\s*\d+\]\s+0\.00-([\d.]+)\s+sec\s+[\d.]+\s+[KMG]Bytes\s+([\d.]+)\s+(Mbits|Kbits|Gbits)/sec\s+(\d+)/(\d+)"
)

def to_mbits(value, unit):
    value = float(value)
    if unit == "Kbits":
        return value / 1000
    if unit == "Gbits":
        return value * 1000
    return value

def parse_client_file(path: Path):
    if not path.exists():
        return None
    text = path.read_text(errors="ignore")
    lines = text.splitlines()

    avg_thr_mbps = None
    retries = None
    for line in lines:
        m = SUMMARY_RE.search(line)
        if m:
            avg_thr_mbps = to_mbits(m.group(2), m.group(3))
            retries = int(m.group(5))
    if avg_thr_mbps is None:
        return None

    rtts_us = []
    for line in lines:
        m = INTERVAL_RE.search(line)
        if not m:
            continue
        t0, t1 = float(m.group(1)), float(m.group(2))
        rtt_us = int(m.group(3))
        if t0 < 2.0:
            continue
        if (t1 - t0) < 0.99:
            continue
        rtts_us.append(rtt_us)

    avg_rtt_ms = (sum(rtts_us) / len(rtts_us) / 1000) if rtts_us else None

    return {
        "avg_throughput_mbps": round(avg_thr_mbps, 3),
        "avg_rtt_ms": round(avg_rtt_ms, 3) if avg_rtt_ms is not None else None,
        "retries": retries,
    }

def main():
    if not BASE.exists():
        raise SystemExit(
            f"[ERROR] No existe la carpeta de resultados: {BASE}\n"
            f"Copia ahí los resultados de la campaña de coexistencia con ruido "
            f"(estructura: resultados/resultados_flujo_ruidoCD/<lote_bw>/...)."
        )

    rows = []
    bw_dirs = sorted(BASE.iterdir(), key=lambda p: (p.name != "baseline", BW_NUMERIC.get(p.name, 0)))
    for bw_dir in bw_dirs:
        if not bw_dir.is_dir():
            continue
        bw_label = bw_dir.name
        for prefix, nombre_legible in ESCENARIOS.items():
            main_file = bw_dir / f"{prefix}_cliente.txt"
            noise_file = bw_dir / f"{prefix}_ruido_cliente.txt"
            main_res = parse_client_file(main_file)
            noise_res = parse_client_file(noise_file)
            if main_res is None:
                print(f"[!] No se pudo parsear (principal): {main_file}")
                continue
            row = {
                "bw_lote": bw_label,
                "escenario_id": prefix,
                "escenario": nombre_legible,
                "principal_thr_mbps": main_res["avg_throughput_mbps"],
                "principal_rtt_ms": main_res["avg_rtt_ms"],
                "principal_retries": main_res["retries"],
            }
            if noise_res:
                row.update({
                    "ruido_thr_mbps": noise_res["avg_throughput_mbps"],
                    "ruido_rtt_ms": noise_res["avg_rtt_ms"],
                    "ruido_retries": noise_res["retries"],
                })
            else:
                row.update({"ruido_thr_mbps": None, "ruido_rtt_ms": None, "ruido_retries": None})
            rows.append(row)

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
