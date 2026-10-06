# Entorno 5G: OpenAirInterface con el simulador de radio

Material para repetir las medidas de 5G de la memoria. La red es la de OpenAirInterface (OAI) en contenedores Docker: núcleo 5G, gNB y UE unidos por el simulador de radio `rfsimulator`, todo en una misma máquina.

El gNB y la UE usan las imágenes oficiales de OAI de la rama `develop`, commit `1143f7500e5e5a9cd258148f8429230cc2759554`. Las dos modificaciones de este trabajo se compilan a partir de ese mismo commit.

El despliegue parte de `oai-cn5g-fed` en el commit `2712e714a2d136972dd0cca4ad09d55c5b232b21` (12/08/2026). Sobre él se cambian cuatro ficheros: el despliegue del núcleo (direcciones IP fijas, para que el gNB encuentre siempre al AMF), el de la RAN (binario del gNB con marcado, librería del simulador en tiempo real y variables de entorno) y las configuraciones del gNB y de la UE (modelo de canal con ruido).

## Carpetas

| Carpeta | Contenido |
|---|---|
| `config/` | Despliegue del núcleo con las direcciones IP fijas (`docker-compose-basic-nrf.yaml`), `docker-compose` de la RAN para las dos celdas (`...-rfsim-basic.yaml`: 40 MHz, 106 PRB; `...-rfsim-24prb.yaml`: 10 MHz, 24 PRB) y `ran-conf/` con la configuración del gNB de cada celda y de la UE. Se copian en `~/oai-cn5g-fed/docker-compose/`. `cambios_oai-cn5g-fed.patch` resume lo que cambia respecto a los ficheros originales |
| `parches/` | Las dos modificaciones de OAI y los scripts que las compilan |
| `campanas/` | Lanzador de campañas, cálculo de estadísticas, control del ruido y ficheros de casos (`casos/`) |
| `analisis/` | Series temporales, retardo por tramos con capturas y scripts de las figuras |
| `desarrollo/` | Comprobaciones puntuales hechas mientras se desarrollaba el entorno, con su salida |
| `descartados/` | Métodos de la primera fase que la memoria descarta |
| `Start5gstack.sh` | Arranque manual de la red (núcleo, gNB y UE) con comprobación de cada paso. Las campañas no lo usan: el lanzador levanta la red por su cuenta |

## Las dos modificaciones de OAI

Los ficheros `.patch` son la referencia. Están sacados con `git diff` del código con el que se compilaron los binarios de las medidas.

```bash
git clone https://gitlab.eurecom.fr/oai/openairinterface5g.git ~/oai-src
cd ~/oai-src && git checkout 1143f7500e5e5a9cd258148f8429230cc2759554
git apply tfg_rfsim_realtime.patch tfg_l4s_rlc.patch
```

**`tfg_rfsim_realtime.patch`: simulador en tiempo real.** Cambia `radio/rfsimulator/simulator.cpp` para que el simulador entregue las muestras al ritmo del reloj. Se activa con `RFSIM_REALTIME=1`; con 0 se comporta como el original. `build_rfsim_rt.sh` compila la librería `librfsimulator.so`, que sustituye a la del contenedor.

**`tfg_l4s_rlc.patch`: marcado L4S en la RLC del gNB.** Cambia `openair2/LAYER2/nr_rlc/nr_rlc_entity_am.c` y `.h`. Al sacar un paquete de la cola RLC en bajada, si es IPv4 con ECT(1) y lleva en la cola más que el umbral, se marca con CE. También guarda un registro periódico del estado de la cola.

| Variable de entorno | Para qué |
|---|---|
| `TFG_L4S_UMBRAL_US` | Umbral de marcado en microsegundos. 0 = sin marcado |
| `TFG_L4S_CTRL` | Fichero del que se relee el umbral cada segundo, para cambiarlo sin reiniciar el gNB |
| `TFG_RLC_LOG` | Fichero CSV del registro de la RLC |
| `TFG_LOG_MS` | Periodo del registro en milisegundos (10 por defecto) |

`build_gnb_l4s.sh` compila el gNB (`nr-softmodem`) con el cambio; lo aplica con `parche_l4s_rlc.py`, que genera exactamente el mismo código que el `.patch`. `activar_gnb_l4s.py` añade al `docker-compose` el binario y las variables.

## Campañas

```bash
cd scripts/5g/campanas
./campana_oai.sh casos/fase_40mhz_b.csv 10          # fichero de casos y repeticiones
python3 resumen_campana.py ~/campanas_oai/fase_40mhz_b
```

- `campana_oai.sh` repite cada caso en orden aleatorio, levanta la red si hace falta, fija el algoritmo de congestión y ECN, lanza iperf2 y los pings, y guarda una carpeta por prueba en `~/campanas_oai/<campaña>/`. Si se corta, al relanzarlo sigue por donde iba.
- Una prueba en tiempo real se da por válida si menos del 5 % de los bloques de muestras llegan tarde y hay como mucho un reanclaje del reloj del simulador. Si no, se repite, hasta tres intentos.
- `resumen_campana.py` escribe `pruebas.csv` (una fila por prueba) y `casos.csv` (media, desviación, intervalo de confianza del 95 % con la t de Student y mediana por caso).
- El formato del fichero de casos está en la cabecera de `campana_oai.sh`. La columna `umbral` es el umbral de marcado del gNB en microsegundos.

El lanzador necesita además una imagen local `tc-l4s:img`: Ubuntu 22.04 con el `tc` de L4STeam (iproute2 5.12.0, <https://github.com/L4STeam/iproute2>), que es el que sabe leer las estadísticas de dualpi2 en la UPF. Se preparó a mano dentro de un contenedor y se guardó con `docker commit`; los pasos exactos no se conservaron.

Celda de 40 MHz: valores por defecto. Celda de 10 MHz con ruido:

```bash
export RAN_COMPOSE=docker-compose-oai-rfsim-24prb.yaml
export RUIDO_OPTS_GNB="--rfsimulator.[0].options chanmod --telnetsrv" RUIDO_OPTS_UE="$RUIDO_OPTS_GNB"
export CPUSET_GNB_RT=0-15 CPUSET_UE_RT=16-31 CPUSET_RESTO_RT=0-31
./campana_oai.sh casos/fase_10mhz.csv 10
```

Antes de cambiar de celda hay que parar la otra con `docker compose -f <compose de la otra celda> down`: el lanzador no comprueba cuál está arrancada.

Otros ficheros: `crear_celda24.py` crea la configuración de la celda de 10 MHz a partir de la de 40 MHz; `activar_ruido.py` añade el modelo de canal con ruido; `ruido.sh` consulta o cambia el ruido en caliente; `calibrar_ruido.sh` mide la capacidad de la celda para cada nivel de ruido; `reclasificar_pacing.py` aplica el criterio de validez a una campaña ya hecha.

Qué campaña es cada fichero de `casos/` y cuáles se usan en la memoria está en `metricas/5g/README.md`. `fase4_ruido.csv`, `fase_r40.csv` y `fase_r10_ruido.csv` se prepararon pero no llegaron a lanzarse.

## Análisis

- `series_temporales.py`: evolución segundo a segundo de la repetición más cercana a la mediana de cada caso.
- `capturas_tramos.sh` y `retardo_tramos.py`: lanzan una campaña corta con capturas en el servidor, la UPF y la UE, y reparten el retardo de cada ping entre núcleo, bajada y subida.
