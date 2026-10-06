#!/usr/bin/env python3
"""
activar_ruido.py - TFG L4S, fase 4 (ruido blanco AWGN en el canal radio).

Deja preparada la red para poder añadir ruido AWGN, SIN activarlo todavía:
  1. Añade al final de gnb.conf y nr-ue.conf la sección 'channelmod' con dos
     canales AWGN sin pérdidas (ploss 0 dB) y ruido muy bajo (-50 dB):
       - rfsimu_channel_ue0  -> lo aplica el gNB (servidor) a la SUBIDA
       - rfsimu_channel_enB0 -> lo aplica la UE (cliente) a la BAJADA
  2. Añade ${RUIDO_OPTS:-} al final de USE_ADDITIONAL_OPTIONS del gNB y de la UE
     en docker-compose-oai-rfsim-basic.yaml.
     - Sin exportar RUIDO_OPTS: la red arranca exactamente como antes.
     - Con RUIDO_OPTS="--rfsimulator.[0].options chanmod --telnetsrv": se activa
       el modelo de canal y el servidor telnet (puerto 9090) para cambiar el
       ruido en caliente.
Guarda copia .antes_ruido de cada fichero. Idempotente.
Uso: python3 activar_ruido.py            (aplica)
     python3 activar_ruido.py --deshacer (restaura las copias)
"""
import os, re, shutil, sys

D = os.path.expanduser('~/oai-cn5g-fed/docker-compose')
CONFS = [os.path.join(D, 'ran-conf', 'gnb.conf'), os.path.join(D, 'ran-conf', 'nr-ue.conf')]
COMPOSE = os.path.join(D, 'docker-compose-oai-rfsim-basic.yaml')
FILES = CONFS + [COMPOSE]

BLOQUE = '''
# ==== TFG L4S fase 4: modelo de canal AWGN (solo se usa con --rfsimulator.[0].options chanmod) ====
channelmod = {
  max_chan = 10;
  modellist = "modellist_tfg";
  modellist_tfg = (
    {
      model_name     = "rfsimu_channel_enB0";
      type           = "AWGN";
      ploss_dB       = 0;
      noise_power_dB = -50;
      forgetfact     = 0;
      offset         = 0;
      ds_tdl         = 0;
    },
    {
      model_name     = "rfsimu_channel_ue0";
      type           = "AWGN";
      ploss_dB       = 0;
      noise_power_dB = -50;
      forgetfact     = 0;
      offset         = 0;
      ds_tdl         = 0;
    }
  );
};
'''

if '--deshacer' in sys.argv:
    for f in FILES:
        if os.path.exists(f + '.antes_ruido'):
            shutil.copy(f + '.antes_ruido', f); print('Restaurado', f)
    sys.exit(0)

for f in FILES:
    if not os.path.exists(f):
        sys.exit(f'ERROR: no existe {f}')

for f in CONFS:
    s = open(f).read()
    if re.search(r'^\s*channelmod\s*=', s, re.M):
        print('Ya tiene channelmod, no se toca:', f); continue
    shutil.copy(f, f + '.antes_ruido')
    open(f, 'w').write(s.rstrip('\n') + '\n' + BLOQUE)
    print('Añadido channelmod a', f)

s = open(COMPOSE).read()
if 'RUIDO_OPTS' in s:
    print('El compose ya tiene RUIDO_OPTS, no se toca.')
else:
    shutil.copy(COMPOSE, COMPOSE + '.antes_ruido')
    out, n = [], 0
    for l in s.split('\n'):
        if 'USE_ADDITIONAL_OPTIONS:' in l:
            l = l.rstrip() + ' ${RUIDO_OPTS:-}'; n += 1
        out.append(l)
    open(COMPOSE, 'w').write('\n'.join(out))
    print(f'Añadido ${{RUIDO_OPTS:-}} en {n} servicios del compose (deben ser 2).')
