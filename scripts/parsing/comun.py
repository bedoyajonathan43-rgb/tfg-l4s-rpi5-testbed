#!/usr/bin/env python3
"""Funciones comunes de los scripts de red fija: lectura de las salidas de iperf2 y estilo de las figuras.

Los datos son las salidas de texto de iperf2 (cliente y servidor) de cada prueba. Se leen de una
carpeta con las campañas descomprimidas o, si no existe, del fichero resultados/red_fija_iperf.zip.
"""
import re
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DIR_DATOS = REPO / "resultados"
DIR_METRICAS = REPO / "metricas" / "red_fija"
DIR_FIGURAS = REPO / "figuras"
NOMBRE_ZIP = "red_fija_iperf.zip"

BW = ["baseline", "1mbit", "2mbit", "5mbit", "10mbit", "20mbit", "50mbit", "100mbit", "200mbit", "500mbit"]
ESC = {"E1": "E1_pfifo", "E2": "E2_fq_codel", "E3": "E3_fq_codel_ecn", "E4": "E4_dualpi2_prague"}
BUFFERS = ["0.5xBDP", "1xBDP", "2xBDP", "4xBDP", "8xBDP"]

# Línea de intervalo o de resumen del cliente (iperf2 -e) y del servidor
CL = re.compile(r'^\[\s*(\d+)\]\s+(\d+\.\d+)-(\d+\.\d+) sec\s+([\d.]+) (\w?)Bytes\s+([\d.]+) (\w?)bits/sec'
                r'\s+(\d+)/(\d+)\s+(\d+)\s+.*?/(\d+)\((\d+)\) us')
SV = re.compile(r'^\[\s*(\d+|SUM-\d+)\]\s+(\d+\.\d+)-(\d+\.\d+) sec\s+([\d.]+) (\w?)Bytes\s+([\d.]+) (\w?)bits/sec')
U = {"": 1e-6, "K": 1e-3, "M": 1.0, "G": 1e3}      # a Mbit/s


class Datos:
    """Acceso a los ficheros en bruto, estén en una carpeta o dentro del zip."""

    def __init__(self, ruta=None):
        ruta = Path(ruta) if ruta else DIR_DATOS
        self.zip = None
        if ruta.is_file():
            self.zip = zipfile.ZipFile(ruta)
        elif not (ruta / "resultadosFinales_1_flujoC").is_dir() and (ruta / NOMBRE_ZIP).is_file():
            self.zip = zipfile.ZipFile(ruta / NOMBRE_ZIP)
        self.raiz = ruta
        self.nombres = set(self.zip.namelist()) if self.zip else None

    def lineas(self, rel):
        """Líneas del fichero, o lista vacía si no existe."""
        if self.zip:
            if rel not in self.nombres:
                return []
            return self.zip.read(rel).decode("utf-8", errors="ignore").splitlines()
        p = self.raiz / rel
        return p.read_text(errors="ignore").splitlines() if p.is_file() else []


def medir(datos, base):
    """Métricas de una prueba. `base` es la ruta sin el sufijo _cliente.txt / _servidor.txt.

    - Throughput: línea final de resumen del servidor. Con dos flujos, línea [SUM-2];
      si falta, suma de los totales de cada flujo.
    - RTT: media de los intervalos de 1 s del cliente con inicio en t >= 2 s y fin en t <= 60 s.
      Se cuentan todos, también los de 0 bytes, y no el último intervalo parcial.
      Con dos flujos, media de las medias de cada flujo.
    - Retransmisiones: columna Rtry de la línea de resumen del cliente (suma de flujos).
    """
    flujos, rtry = {}, 0
    for l in datos.lineas(base + "_cliente.txt"):
        m = CL.match(l)
        if not m:
            continue
        t0, t1 = float(m.group(2)), float(m.group(3))
        if t0 == 0.0 and t1 > 1.5:
            rtry += int(m.group(10))
            continue
        flujos.setdefault(int(m.group(1)), []).append((t0, t1, int(m.group(11)) / 1000.0))
    medias, n = [], []
    for k in sorted(flujos):
        v = [r for (t0, t1, r) in flujos[k] if t0 >= 2 and abs(t1 - t0 - 1) < 1e-6 and t1 <= 60.001]
        if v:
            medias.append(sum(v) / len(v))
            n.append(len(v))
    suma, porflujo = None, []
    for l in datos.lineas(base + "_servidor.txt"):
        m = SV.match(l)
        if not m:
            continue
        if float(m.group(2)) == 0.0 and float(m.group(3)) > 1.5:
            v = float(m.group(6)) * U[m.group(7)]
            if m.group(1).startswith("SUM"):
                suma = v
            else:
                porflujo.append(v)
    thr = suma if suma is not None else (sum(porflujo) if porflujo else None)
    return {"throughput_mbit": thr, "rtt_ms": (sum(medias) / len(medias) if medias else None),
            "intervalos": "/".join(map(str, n)), "rtry": rtry,
            "origen_thr": "SUM" if suma is not None else ("flujo" if len(porflujo) == 1 else "suma_de_flujos")}


def intervalos_cliente(datos, rel):
    """Intervalos de 1 s completos del cliente: lista de (t0, Mbit/s, RTT en ms, bytes)."""
    out = []
    for l in datos.lineas(rel):
        m = CL.match(l)
        if not m:
            continue
        t0, t1 = float(m.group(2)), float(m.group(3))
        if abs(t1 - t0 - 1) > 1e-6:
            continue                      # resumen o intervalo final parcial
        out.append((t0, float(m.group(6)) * U[m.group(7)], int(m.group(11)) / 1000.0, float(m.group(4))))
    return out


def intervalos_servidor(datos, rel):
    """Intervalos de 1 s completos del servidor: lista de (t0, Mbit/s)."""
    out = []
    for l in datos.lineas(rel):
        m = SV.match(l)
        if not m or m.group(1).startswith("SUM"):
            continue
        t0, t1 = float(m.group(2)), float(m.group(3))
        if abs(t1 - t0 - 1) > 1e-6:
            continue
        out.append((t0, float(m.group(6)) * U[m.group(7)]))
    return out
