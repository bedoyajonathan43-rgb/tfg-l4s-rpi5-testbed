#!/usr/bin/env python3
"""Calcula las tablas de red fija de la memoria a partir de las salidas en bruto de iperf2.

Uso (desde cualquier carpeta):
    python3 scripts/parsing/calcular_metricas.py [carpeta_de_datos | fichero.zip]

Sin argumento lee resultados/ (o resultados/red_fija_iperf.zip). Escribe en metricas/red_fija/:

    tabla_un_flujo.csv       campaña de flujo individual (serie del 24/07/2026)
    tabla_dos_flujos.csv     campaña de dos flujos paralelos (24/07; fila sin límite, del 26/07)
    tabla_ruido_E4.csv       convivencia con ruido: RTT y throughput de cada cola de E4
    tabla_ruido_reparto.csv  convivencia con ruido: reparto de throughput en los cuatro escenarios
    tabla_sarpkaya.csv       reproducción de Sarpkaya et al.: Prague y Cubic por escenario y buffer

El método de throughput, RTT y retransmisiones está en comun.medir() y es el del capítulo 7 de la memoria.
"""
import csv
import sys

from comun import BUFFERS, BW, DIR_METRICAS, ESC, Datos, intervalos_cliente, medir


def escribir(nombre, campos, filas, formatos):
    DIR_METRICAS.mkdir(parents=True, exist_ok=True)
    with open(DIR_METRICAS / nombre, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=campos)
        w.writeheader()
        for r in filas:
            r = dict(r)
            for k, fmt in formatos.items():
                if r.get(k) is not None:
                    r[k] = format(r[k], fmt)
            w.writerow(r)
    print(f"  {nombre}: {len(filas)} filas")


def tablas_barrido(d):
    campos = ["ancho_de_banda", "serie", "throughput_mbit", "rtt_ms", "intervalos", "rtry", "origen_thr"]
    fmt = {"throughput_mbit": ".6g", "rtt_ms": ".3f"}
    uno, dos, ruido, reparto = [], [], [], []
    for bw in BW:
        for e, p in ESC.items():
            uno.append({"ancho_de_banda": bw, "serie": e, **medir(d, f"resultadosFinales_1_flujoC/{bw}/{p}")})
            # la fila sin límite de dos flujos es la repetición del 26/07 (resultadosFinales_paraleloCA)
            carpeta = "resultadosFinales_paraleloCA" if bw == "baseline" else "resultadosFinales_paraleloC"
            dos.append({"ancho_de_banda": bw, "serie": e, **medir(d, f"{carpeta}/{bw}/{p}")})
            # convivencia: flujo principal del escenario y flujo de ruido Cubic
            pr = medir(d, f"resultados_flujo_ruidoCD/{bw}/{p}")
            ru = medir(d, f"resultados_flujo_ruidoCD/{bw}/{p}_ruido")
            a, b = pr["throughput_mbit"], ru["throughput_mbit"]
            reparto.append({"ancho_de_banda": bw, "escenario": e, "principal_mbit": a, "ruido_mbit": b,
                            "cuota_principal_pct": 100 * a / (a + b) if a is not None and b else None})
            if e == "E4":
                ruido.append({"ancho_de_banda": bw, "serie": "E4_principal_Prague", **pr})
                ruido.append({"ancho_de_banda": bw, "serie": "E4_ruido_Cubic", **ru})
    escribir("tabla_un_flujo.csv", campos, uno, fmt)
    escribir("tabla_dos_flujos.csv", campos, dos, fmt)
    escribir("tabla_ruido_E4.csv", campos, ruido, fmt)
    escribir("tabla_ruido_reparto.csv", ["ancho_de_banda", "escenario", "principal_mbit", "ruido_mbit", "cuota_principal_pct"],
             reparto, {"principal_mbit": ".6g", "ruido_mbit": ".6g", "cuota_principal_pct": ".2f"})


def tabla_sarpkaya(d, serie="resultados_fairness_sarpkayaB", repeticiones=10):
    """Throughput de cada flujo: media de los intervalos de 1 s del cliente desde t = 2 s; después, media de las repeticiones."""
    def media(rel):
        v = [x[1] for x in intervalos_cliente(d, rel) if 2 <= x[0] < 60]
        return sum(v) / len(v) if v else None

    filas = []
    for e, p in ESC.items():
        for b in BUFFERS:
            pr, cu = [], []
            for r in range(1, repeticiones + 1):
                base = f"{serie}/{p}/{b}/{p}_{b}_rep{r}"
                x, y = media(base + "_principal_cliente.txt"), media(base + "_ruido_cliente.txt")
                if x is not None and y is not None:
                    pr.append(x)
                    cu.append(y)
            if not pr:
                continue
            mp, mc = sum(pr) / len(pr), sum(cu) / len(cu)
            filas.append({"escenario": e, "buffer": b, "repeticiones": len(pr), "prague_mbit": mp, "cubic_mbit": mc,
                          "cuota_prague_pct": 100 * mp / (mp + mc), "prague_min": min(pr), "prague_max": max(pr)})
    escribir("tabla_sarpkaya.csv", ["escenario", "buffer", "repeticiones", "prague_mbit", "cubic_mbit", "cuota_prague_pct",
                                    "prague_min", "prague_max"], filas,
             {k: ".2f" for k in ("prague_mbit", "cubic_mbit", "cuota_prague_pct", "prague_min", "prague_max")})


if __name__ == "__main__":
    datos = Datos(sys.argv[1] if len(sys.argv) > 1 else None)
    print("Tablas en", DIR_METRICAS)
    tablas_barrido(datos)
    tabla_sarpkaya(datos)
