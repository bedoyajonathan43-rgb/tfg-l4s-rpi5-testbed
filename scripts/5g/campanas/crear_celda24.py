#!/usr/bin/env python3
"""
crear_celda24.py - TFG L4S, fase 4: crea una segunda celda de 24 PRB (~10 MHz)
para las pruebas con ruido, SIN tocar la de 106 PRB (40 MHz).

Parte de tu gnb.conf actual y cambia solo los parámetros de celda, con los
valores de la configuración de referencia de OAI (commit 1143f75):
ci-scripts/conf_files/gnb.sa.band78.24prb.rfsim.conf
  absoluteFrequencySSB 640320, dl_absoluteFrequencyPointA 640032,
  dl/ul_carrierBandwidth 24, initialDL/ULBWPlocationAndBandwidth 6325,
  initialDLBWPcontrolResourceSetZero 2, zeroCorrelationZoneConfig 13,
  ssb_perRACH_OccasionAndCB_PreamblesPerSSB 14.
UE (como en la referencia de OAI): --rfsim -r 24 --ssb 24 --numerology 1 -C 3604800000 (sin -E).

Crea:
  ran-conf/gnb_24prb.conf
  docker-compose-oai-rfsim-24prb.yaml  (mismos contenedores; monta gnb_24prb.conf)
Uso: python3 crear_celda24.py
"""
import os, re, sys

D = os.path.expanduser('~/oai-cn5g-fed/docker-compose')
SRC_CONF = os.path.join(D, 'ran-conf', 'gnb.conf')
DST_CONF = os.path.join(D, 'ran-conf', 'gnb_24prb.conf')
SRC_YAML = os.path.join(D, 'docker-compose-oai-rfsim-basic.yaml')
DST_YAML = os.path.join(D, 'docker-compose-oai-rfsim-24prb.yaml')

CAMBIOS = {
    'absoluteFrequencySSB': '640320',
    'dl_absoluteFrequencyPointA': '640032',
    'dl_carrierBandwidth': '24',
    'ul_carrierBandwidth': '24',
    'initialDLBWPlocationAndBandwidth': '6325',
    'initialULBWPlocationAndBandwidth': '6325',
    'initialDLBWPcontrolResourceSetZero': '2',
    'zeroCorrelationZoneConfig': '13',
    'ssb_perRACH_OccasionAndCB_PreamblesPerSSB': '14',
}

s = open(SRC_CONF).read()
for k, v in CAMBIOS.items():
    s, n = re.subn(r'^(\s*' + k + r'\s*=\s*)[^;#\n]+', r'\g<1>' + v, s, flags=re.M)
    print(f'{k:45} -> {v:8} ({n} línea/s)')
    if n != 1:
        sys.exit(f'ERROR: se esperaba 1 línea con {k} y hay {n}. No se crea nada.')
open(DST_CONF, 'w').write(s)
print('Creado', DST_CONF)

y = open(SRC_YAML).read()
y = y.replace('./ran-conf/gnb.conf:/opt/oai-gnb/etc/gnb.conf', './ran-conf/gnb_24prb.conf:/opt/oai-gnb/etc/gnb.conf')
out, svc = [], None
for l in y.split('\n'):
    m = re.match(r'^\s{4}(oai-gnb-basic|oai-nr-ue-basic):\s*$', l)
    if m: svc = m.group(1)
    if 'USE_ADDITIONAL_OPTIONS:' in l:
        l = l.replace(' -E ', ' ')
        if svc == 'oai-nr-ue-basic':
            l = re.sub(r'-r 106', '-r 24 --ssb 24', l)
            l = re.sub(r'-C \d+', '-C 3604800000', l)
    out.append(l)
y = '\n'.join(out)
if 'gnb_24prb.conf' not in y or '-r 24' not in y or ' -E ' in y:
    sys.exit('ERROR: el compose no tiene el formato esperado. No se crea.')
open(DST_YAML, 'w').write(y)
print('Creado', DST_YAML)
print('\nComprobación:')
for l in y.split('\n'):
    if 'USE_ADDITIONAL_OPTIONS' in l or 'gnb_24prb' in l: print('  ' + l.strip())
