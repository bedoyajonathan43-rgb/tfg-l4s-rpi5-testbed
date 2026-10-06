#!/usr/bin/env python3
# =============================================================================
# activar_gnb_l4s.py - TFG L4S: prepara el compose de la RAN para usar el gNB parcheado.
# Añade al servicio oai-gnb-basic:
#   volumes:     ./rfsim-rt/nr-softmodem-tfg:/opt/oai-gnb/bin/nr-softmodem
#   environment: TFG_L4S_UMBRAL_US (0 = sin marcado), TFG_L4S_CTRL, TFG_RLC_LOG, TFG_LOG_MS
# Guarda una copia <compose>.antes_l4s. Uso:
#   python3 activar_gnb_l4s.py ~/oai-cn5g-fed/docker-compose/docker-compose-oai-rfsim-basic.yaml [otro.yaml ...]
# =============================================================================
import sys, os, re, shutil

BIN = os.path.expanduser('~/oai-cn5g-fed/docker-compose/rfsim-rt/nr-softmodem-tfg')
if not os.path.isfile(BIN):
    sys.exit(f'ERROR: no existe {BIN}. Ejecuta antes build_gnb_l4s.sh')

VOL = './rfsim-rt/nr-softmodem-tfg:/opt/oai-gnb/bin/nr-softmodem'
ENV = [('TFG_L4S_UMBRAL_US', '${TFG_L4S_UMBRAL_US:-0}'),
       ('TFG_L4S_CTRL', '/tmp/tfg_umbral'),
       ('TFG_RLC_LOG', '${TFG_RLC_LOG:-/opt/oai-gnb/tfg_rlc.csv}'),
       ('TFG_LOG_MS', '${TFG_LOG_MS:-10}')]

for path in sys.argv[1:]:
    lines = open(path).read().split('\n')
    if any('nr-softmodem-tfg' in l for l in lines):
        print(f'{path}: ya estaba preparado, sin cambios.'); continue
    # bloque del servicio del gNB
    ini = next(i for i, l in enumerate(lines) if re.match(r'^\s+oai-gnb-basic:\s*$', l))
    ind_srv = len(lines[ini]) - len(lines[ini].lstrip())
    fin = next((i for i in range(ini + 1, len(lines))
                if lines[i].strip() and len(lines[i]) - len(lines[i].lstrip()) <= ind_srv), len(lines))

    def clave(nombre):
        return next(i for i in range(ini, fin) if re.match(rf'^\s+{nombre}:\s*$', lines[i]))

    # environment (formato "CLAVE: valor" o "- CLAVE=valor")
    e = clave('environment'); sig = lines[e + 1]
    ind = ' ' * (len(sig) - len(sig.lstrip()))
    nuevas = [f'{ind}- {k}={v}' if sig.strip().startswith('- ') else f'{ind}{k}: {v}' for k, v in ENV]
    lines[e + 1:e + 1] = nuevas
    fin += len(nuevas)
    # volumes
    v = clave('volumes'); sig = lines[v + 1]
    ind = ' ' * (len(sig) - len(sig.lstrip()))
    lines.insert(v + 1, f'{ind}- {VOL}')
    shutil.copy(path, path + '.antes_l4s')
    open(path, 'w').write('\n'.join(lines))
    print(f'{path}: preparado (copia en {path}.antes_l4s).')
