#!/usr/bin/env python3
"""
reclasificar_pacing.py - TFG L4S: aplica el criterio de validez revisado a una
campaña ya hecha, sin repetir pruebas.

Criterio revisado (modo rt): prueba válida si
  - bloques tarde (>1 ms) < 5 %   y
  - como mucho 1 re-sincronización (reanclaje de >100 ms).
Motivo: en subida sin límite el simulador acumula ~100 ms de retraso durante el
arranque del flujo (primeros ~20 s) una sola vez y luego sigue a tiempo real.

Para cada prueba sin versión válida, recupera el PRIMER intento descartado que
cumpla el criterio (el primero, para no elegir "el mejor" y sesgar la muestra).
Deja constancia en reclasificadas.csv.

Uso: python3 reclasificar_pacing.py ~/campanas_oai/<campaña> [--aplicar]
     (sin --aplicar solo muestra lo que haría)
"""
import os, re, sys, shutil

def pacing(path):
    b = t = r = 0
    for l in open(path, errors='ignore'):
        m = re.search(r'RT pacing: bloques=(\d+) tarde\(>1ms\)=(\d+).*reanclajes=(\d+)', l)
        if m:
            b += int(m.group(1)); t += int(m.group(2)); r += int(m.group(3))
    return b, t, r

base = os.path.expanduser(sys.argv[1]); aplicar = '--aplicar' in sys.argv
cands = {}
for d in sorted(os.listdir(base)):
    m = re.match(r'invalidas_(p\d+_.+_rep\d+)_intento(\d+)$', d)
    if m:
        cands.setdefault(m.group(1), []).append((int(m.group(2)), d))
filas = []
for nombre, lista in sorted(cands.items()):
    if os.path.exists(os.path.join(base, nombre, 'DONE')):
        continue
    for intento, d in sorted(lista):
        full = os.path.join(base, d)
        if os.path.exists(os.path.join(full, 'motivo')):
            continue
        b, t, r = pacing(os.path.join(full, 'gnb.log'))
        if b and r <= 1 and t / b < 0.05:
            filas.append((nombre, intento, d, 100 * t / b, r))
            if aplicar:
                shutil.move(full, os.path.join(base, nombre))
                open(os.path.join(base, nombre, 'DONE'), 'w').close()
                open(os.path.join(base, nombre, 'RECLASIFICADA'), 'w').write(
                    f'intento={intento} tarde={100*t/b:.2f}% reanclajes={r}\n')
            break
print(f"{'prueba':45} {'intento':>7} {'tarde %':>8} {'reancl':>6}")
for n, i, d, tp, r in filas:
    print(f"{n:45} {i:>7} {tp:>8.2f} {r:>6}")
print(f"\n{len(filas)} pruebas {'reclasificadas' if aplicar else 'se reclasificarían (usa --aplicar)'}")
if aplicar and filas:
    with open(os.path.join(base, 'reclasificadas.csv'), 'a') as fh:
        for n, i, d, tp, r in filas:
            fh.write(f"{n},{i},{tp:.2f},{r}\n")
