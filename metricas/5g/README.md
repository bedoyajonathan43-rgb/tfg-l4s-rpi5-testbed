# Resultados de las campañas de 5G

Resumen de cada campaña lanzada con `scripts/5g/campanas/campana_oai.sh`. Aquí solo están los resúmenes; los datos en bruto de cada prueba (registros de `ss`, de la RLC del gNB, pings y salidas de iperf2) ocupan unos 940 MB y no están en el repositorio.

| Fichero | Contenido |
|---|---|
| `pruebas.csv` | Una fila por prueba válida, con todas sus métricas |
| `casos.csv` | Por caso: número de pruebas, media, desviación típica, intervalo de confianza del 95 % (t de Student) y mediana. En las campañas sin `pruebas.csv` es la lista de casos de entrada |
| `estado.csv` | Estado de cada prueba del plan |
| `campana.log` | Registro del lanzador: cada intento y si fue válido |
| `retardo_tramos.csv` y `.log` | Solo en `capas_*`: retardo de cada ping repartido por tramos |

## Campañas

| Inicio | Campaña | Casos | Pruebas en el resumen | Intentos válidos | Intentos no válidos | Qué es | Uso en la memoria |
|---|---|---|---|---|---|---|---|
| 2026-09-25 | `fase1_tiempo_real` | 6 | 60 | 60 | 0 | El mismo caso con el simulador en tiempo real, libre y con la CPU limitada | Validación del entorno |
| 2026-09-25 | `humo` | 2 | 2 | 2 | 0 | Prueba de humo del lanzador | No se usa |
| 2026-09-26 | `fase2_linea_base` | 8 | 78 | 42 | 123 | Sin límite de tasa, con y sin dualpi2 en la UPF | AQM en la UPF (solo los casos de Cubic) |
| 2026-09-26 | `fase3_barrido` | 30 | 300 | 300 | 0 | Barrido del límite HTB con dualpi2 en la UPF | AQM en la UPF (solo los casos de Cubic) |
| 2026-09-27 | `fase3b_referencia_pfifo` | 15 | 150 | 150 | 1 | El mismo barrido con pfifo | AQM en la UPF (solo los casos de Cubic) |
| 2026-09-28 | `fase4_ruido_dl` | 16 | 159 | 159 | 5 | Primera campaña con ruido en bajada, con el AQM en la UPF | AQM en la UPF (solo los casos de Cubic) |
| 2026-09-29 | `fase_demo` | 7 | 21 | 21 | 0 | Serie corta con Prague bien activado y dualpi2 en la UPF | AQM en la UPF |
| 2026-09-29 | `fase_validacion` | 4 | 4 | 4 | 0 | Comprobación de Prague y AccECN tras corregir la selección del algoritmo | Validación del entorno |
| 2026-10-03 | `fase_40mhz` | 7 | 70 | 70 | 0 | Celda de 40 MHz sin ruido, primera versión | Solo como comparación con la final |
| 2026-10-03 | `fase_cal10` | 0 | 0 | 0 | 108 | Calibración en la celda de 10 MHz con el reparto de núcleos de 40 MHz | No válida: ningún intento cumple el tiempo real |
| 2026-10-03 | `fase_umbral` | 6 | 30 | 30 | 0 | Calibración del umbral de marcado, celda de 40 MHz, primer barrido | Calibración del umbral |
| 2026-10-03 | `fase_umbral2` | 5 | 25 | 25 | 0 | Calibración del umbral de marcado, celda de 40 MHz, segundo barrido | Calibración del umbral |
| 2026-10-04 | `fase_10mhz` | 26 | 260 | 260 | 2 | Celda de 10 MHz con ruido | **Resultado final** |
| 2026-10-04 | `fase_cal10b` | 12 | 36 | 36 | 1 | Calibración del umbral de marcado, celda de 10 MHz | **Resultado final** |
| 2026-10-05 | `capas_10mhz_r4` | 3 | 9 | 9 | 0 | Retardo por tramos con capturas, celda de 10 MHz con ruido de −4 dB | **Resultado final** |
| 2026-10-05 | `capas_10mhz_r4_pre` | 0 | 0 | 1 | 0 | Prueba previa a las capturas (deja la red arrancada) | No se usa |
| 2026-10-05 | `capas_40mhz` | 3 | 9 | 9 | 0 | Retardo por tramos con capturas, celda de 40 MHz | **Resultado final** |
| 2026-10-05 | `capas_40mhz_pre` | 0 | 0 | 1 | 0 | Prueba previa a las capturas (deja la red arrancada) | No se usa |
| 2026-10-05 | `fase_40mhz_b` | 7 | 70 | 70 | 0 | Celda de 40 MHz sin ruido | **Resultado final** |

Avisos:

- En las campañas anteriores al 29 de septiembre de 2026, los casos etiquetados como Prague eran en realidad Cubic con ECN clásico, porque iperf2 no aplicaba el algoritmo pedido. De esas campañas solo valen los casos de Cubic.
- `fase_40mhz` se repitió como `fase_40mhz_b` vaciando entre pruebas la caché de métricas de TCP. El resultado principal no cambia.
- En `fase2_linea_base` el resumen tiene 78 pruebas y el registro solo 42 intentos válidos. Las otras 36 son intentos que el criterio inicial descartaba y que se recuperaron con `reclasificar_pacing.py` al revisar el criterio para admitir un reanclaje.

## Otras carpetas

- `series/`: evolución segundo a segundo de seis pruebas (tres por celda), de la que salen las figuras de evolución temporal.
- `calibracion_ruido/`: capacidad de la celda de 10 MHz para cada nivel de ruido.
