#!/usr/bin/env python3
"""
Calcula el factor de ralentizacion de la simulacion 5G (OAI rfsimulator)
comparando el avance del SFN (System Frame Number) del gNB contra el
tiempo real (wall-clock) transcurrido entre lineas de estadisticas.

Uso:
    python3 calc_scale_factor.py gnb.log [ventana_segundos]
    docker logs oai-gnb-basic > gnb.log && python3 calc_scale_factor.py gnb.log
    python3 calc_scale_factor.py gnb.log 30   # ventanas de 30s en vez de 60s

El script busca lineas del tipo:
    646.055932 [NR_MAC] I UE 0 RNTI 4ad4 stats sfn: 256.8, cumulated bad DCI 0

Cada frame NR dura un tiempo fijo segun la numerologia (SCS):
    numerology 0 (15 kHz) -> 10 ms / frame  (igual siempre, 10 subframes de 1ms)
    En realidad la duracion de FRAME es SIEMPRE 10 ms independientemente de
    la numerologia (lo que cambia es el numero de slots por frame).

Ademas del resumen global (media/mediana/desviacion), el script ahora:
  - Calcula el MAD (Median Absolute Deviation), una medida de dispersion
    robusta frente a outliers, para dar un margen de error de la correccion.
  - Divide la prueba en ventanas de tiempo real (60s por defecto, ajustable)
    y calcula la mediana del factor en cada una, para ver como fluctua el
    jitter a lo largo de la prueba en vez de dar un unico numero global.
"""

import re
import sys
import statistics

FRAME_DURATION_MS = 10.0  # un frame NR siempre dura 10ms, independiente de la numerologia

LINE_RE = re.compile(
    r'^\s*(\d+\.\d+)\s+\[NR_MAC\].*stats sfn:\s*(\d+)\.(\d+)'
)


def parse_log(path):
    """Devuelve lista de (wall_clock_seconds, sfn_frame) en orden."""
    entries = []
    with open(path, 'r', errors='ignore') as f:
        for line in f:
            m = LINE_RE.match(line)
            if m:
                wall_time = float(m.group(1))
                sfn = int(m.group(2))
                entries.append((wall_time, sfn))
    return entries


def compute_scale_factors(entries):
    """
    Compara pares consecutivos. Como el SFN es modulo 1024 (10 bits),
    maneja el wraparound sumando 1024 si el siguiente sfn es menor.
    """
    results = []
    for (t0, sfn0), (t1, sfn1) in zip(entries, entries[1:]):
        frame_delta = sfn1 - sfn0
        if frame_delta <= 0:
            frame_delta += 1024  # wraparound del contador SFN (10 bits: 0-1023)
        expected_real_s = (frame_delta * FRAME_DURATION_MS) / 1000.0
        actual_wall_s = t1 - t0
        if expected_real_s <= 0 or actual_wall_s <= 0:
            continue
        scale = actual_wall_s / expected_real_s
        results.append({
            'sfn_from': sfn0,
            'sfn_to': sfn1,
            't_start': t0,
            'frames': frame_delta,
            'expected_s': expected_real_s,
            'actual_s': actual_wall_s,
            'scale_factor': scale,
        })
    return results


def median_absolute_deviation(values, med=None):
    """MAD: mediana de las desviaciones absolutas respecto a la mediana.
    Es una medida de dispersion robusta frente a outliers, analoga a la
    desviacion estandar pero sin dejarse arrastrar por picos extremos."""
    if med is None:
        med = statistics.median(values)
    deviations = [abs(v - med) for v in values]
    return statistics.median(deviations)


def windowed_analysis(normal_results, window_size_s):
    """
    Agrupa los intervalos "normales" (sin outliers) en ventanas de tiempo
    real de duracion 'window_size_s', y calcula la mediana del factor de
    escala dentro de cada ventana. Esto permite ver como fluctua el factor
    a lo largo de la prueba, en vez de dar un unico numero global.
    """
    if not normal_results:
        return []

    t_first = min(r['t_start'] for r in normal_results)
    windows = {}
    for r in normal_results:
        elapsed = r['t_start'] - t_first
        idx = int(elapsed // window_size_s)
        windows.setdefault(idx, []).append(r['scale_factor'])

    window_stats = []
    for idx in sorted(windows.keys()):
        vals = windows[idx]
        window_stats.append({
            'window_idx': idx,
            't_ini': idx * window_size_s,
            't_fin': (idx + 1) * window_size_s,
            'n': len(vals),
            'mediana': statistics.median(vals),
            'min': min(vals),
            'max': max(vals),
        })
    return window_stats


OUTLIER_THRESHOLD = 1000.0  # factores por encima de esto se consideran incidentes
                             # (pausas del sistema, congelacion de la VM, etc.),
                             # no jitter normal de la simulacion


def main():
    if len(sys.argv) < 2:
        print(f"Uso: python3 {sys.argv[0]} <fichero_log_gnb> [ventana_segundos]")
        sys.exit(1)

    log_path = sys.argv[1]
    window_size_s = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0

    entries = parse_log(log_path)

    if len(entries) < 2:
        print("No se encontraron suficientes lineas 'stats sfn:' en el log.")
        print("Asegurate de que el gNB ha corrido el tiempo suficiente para")
        print("generar varias lineas de estadisticas periodicas (cada ~30s aprox).")
        sys.exit(1)

    print(f"Lineas 'stats sfn:' encontradas: {len(entries)}\n")

    results = compute_scale_factors(entries)

    if not results:
        print("No se pudieron calcular intervalos validos.")
        sys.exit(1)

    normal = [r for r in results if r['scale_factor'] <= OUTLIER_THRESHOLD]
    outliers = [r for r in results if r['scale_factor'] > OUTLIER_THRESHOLD]

    print(f"{'SFN':>12}  {'Frames':>7}  {'Esperado(s)':>12}  {'Real(s)':>10}  {'Factor':>10}")
    print("-" * 62)
    for r in results:
        flag = "  <-- OUTLIER (excluido del resumen)" if r['scale_factor'] > OUTLIER_THRESHOLD else ""
        print(f"{r['sfn_from']:>4}->{r['sfn_to']:<6}  {r['frames']:>7}  "
              f"{r['expected_s']:>12.3f}  {r['actual_s']:>10.3f}  {r['scale_factor']:>9.2f}x{flag}")

    factors_all = [r['scale_factor'] for r in results]
    factors_normal = [r['scale_factor'] for r in normal]

    print("\n" + "=" * 62)
    print("RESUMEN — INCLUYENDO TODOS LOS INTERVALOS")
    print("=" * 62)
    print(f"  Muestras:           {len(factors_all)}")
    print(f"  Media (avg):        {statistics.mean(factors_all):.2f}x")
    print(f"  Mediana:            {statistics.median(factors_all):.2f}x")
    if len(factors_all) > 1:
        print(f"  Desviacion (stdev): {statistics.stdev(factors_all):.2f}x")
    print(f"  Minimo:             {min(factors_all):.2f}x")
    print(f"  Maximo:             {max(factors_all):.2f}x")

    if outliers:
        print(f"\n  >> Se detectaron {len(outliers)} outlier(es) con factor > {OUTLIER_THRESHOLD:.0f}x.")
        print("     Estos valores no representan jitter normal de la simulacion,")
        print("     sino incidentes puntuales (p.ej. pausa/congelacion de la VM,")
        print("     suspension del proceso, etc.) que detienen el reloj del")
        print("     softmodem mientras el tiempo real sigue avanzando.")
        for o in outliers:
            print(f"     - Intervalo SFN {o['sfn_from']}->{o['sfn_to']}: "
                  f"{o['actual_s']:.1f}s reales ({o['scale_factor']:.1f}x)")

    if normal:
        mediana_normal = statistics.median(factors_normal)
        mad_normal = median_absolute_deviation(factors_normal, mediana_normal)
        error_relativo_pct = (mad_normal / mediana_normal) * 100 if mediana_normal else 0

        print("\n" + "=" * 62)
        print(f"RESUMEN — EXCLUYENDO OUTLIERS (factor <= {OUTLIER_THRESHOLD:.0f}x)")
        print("=" * 62)
        print(f"  Muestras:           {len(factors_normal)}")
        print(f"  Media (avg):        {statistics.mean(factors_normal):.2f}x")
        print(f"  Mediana:            {mediana_normal:.2f}x")
        if len(factors_normal) > 1:
            print(f"  Desviacion (stdev): {statistics.stdev(factors_normal):.2f}x")
        print(f"  MAD (robusta):      {mad_normal:.2f}x")
        print(f"  Minimo:             {min(factors_normal):.2f}x")
        print(f"  Maximo:             {max(factors_normal):.2f}x")
        print()
        print("  --> Este es el rango representativo del comportamiento normal")
        print("      de la simulacion (sin incidentes de sistema). Se recomienda")
        print("      citar la MEDIANA como valor de referencia, ya que es mas")
        print("      robusta frente a picos puntuales de jitter que la media.")

        # -----------------------------------------------------------
        # Analisis por ventanas de tiempo: como fluctua el factor a lo
        # largo de la prueba, en vez de dar un unico numero global.
        # -----------------------------------------------------------
        windows = windowed_analysis(normal, window_size_s)
        if len(windows) > 1:
            window_medians = [w['mediana'] for w in windows]
            wmin = min(window_medians)
            wmax = max(window_medians)
            wmean = statistics.mean(window_medians)
            wstdev = statistics.stdev(window_medians) if len(window_medians) > 1 else 0.0
            cv_pct = (wstdev / wmean) * 100 if wmean else 0

            print("\n" + "=" * 62)
            print(f"FLUCTUACION POR VENTANAS DE {window_size_s:.0f}s (mediana en cada ventana)")
            print("=" * 62)
            print(f"{'Ventana (s)':>16}  {'Muestras':>9}  {'Mediana':>10}  {'Min':>8}  {'Max':>8}")
            print("-" * 62)
            for w in windows:
                print(f"{w['t_ini']:>7.0f}-{w['t_fin']:<7.0f}  {w['n']:>9}  "
                      f"{w['mediana']:>9.2f}x  {w['min']:>7.2f}x  {w['max']:>7.2f}x")

            print()
            print(f"  Mediana minima entre ventanas:  {wmin:.2f}x")
            print(f"  Mediana maxima entre ventanas:  {wmax:.2f}x")
            print(f"  Media de las medianas:          {wmean:.2f}x")
            print(f"  Desviacion entre ventanas:       {wstdev:.2f}x")
            print(f"  Coef. de variacion (CV):         {cv_pct:.1f}%")
            print()
            print("  Interpretacion: el CV indica cuanto fluctua el factor de")
            print("  escala de una ventana temporal a otra, en relacion a su")
            print("  valor medio. Un CV alto (p.ej. >30-40%) significa que el")
            print("  jitter del entorno varia bastante segun el momento, y por")
            print("  tanto la correccion aplicada con un unico factor global")
            print("  tiene un margen de error considerable.")

        print("\n" + "=" * 62)
        print("FACTOR RECOMENDADO PARA LA CORRECCION (con margen de error)")
        print("=" * 62)
        print(f"  Factor de escala:  {mediana_normal:.1f}x  ±{mad_normal:.1f}x  (~{error_relativo_pct:.0f}% de error relativo)")
        print(f"  Rango plausible:   [{max(mediana_normal - mad_normal, 0.1):.1f}x , {mediana_normal + mad_normal:.1f}x]")

    print()
    print("Interpretacion: un factor de Nx significa que la simulacion tarda")
    print("N veces mas tiempo real (wall-clock) del que tardaria una red 5G")
    print("real en avanzar la misma cantidad de frames/tiempo de aire.")


if __name__ == '__main__':
    main()
