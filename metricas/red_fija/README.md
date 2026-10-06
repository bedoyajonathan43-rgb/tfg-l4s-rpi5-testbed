# Tablas de red fija

Las escribe `scripts/parsing/calcular_metricas.py` a partir de `resultados/red_fija_iperf.zip`. Son los valores de las tablas del capítulo de resultados de la memoria.

| Fichero | Campaña | Columnas principales |
|---|---|---|
| `tabla_un_flujo.csv` | Un flujo (24/07/2026) | Throughput y RTT por escenario (E1 a E4) y ancho de banda |
| `tabla_dos_flujos.csv` | Dos flujos en paralelo (24/07; la fila sin límite es del 26/07) | Throughput agregado y RTT medio de los dos flujos |
| `tabla_ruido_E4.csv` | Convivencia con ruido (24 y 25/07) | Throughput y RTT del flujo Prague y del flujo de ruido Cubic en E4 |
| `tabla_ruido_reparto.csv` | Convivencia con ruido | Throughput del flujo principal y del ruido en los cuatro escenarios, y cuota del principal |
| `tabla_sarpkaya.csv` | Reproducción de Sarpkaya et al., segunda serie (28/07) | Throughput medio de Prague y de Cubic por escenario y tamaño de buffer, cuota de Prague y valores mínimo y máximo de Prague entre las diez repeticiones |

## Cómo se calcula

- **Throughput.** Línea final de resumen del servidor de iperf2. Con dos flujos, la línea `[SUM-2]`; si falta, la suma de los totales de cada flujo.
- **RTT.** Media de los intervalos de 1 s del cliente con inicio en t ≥ 2 s y fin en t ≤ 60 s. Se cuentan todos, también los de 0 bytes, y no el último intervalo parcial. Siempre son 58 intervalos por flujo. Con dos flujos, media de las medias de cada flujo.
- **Retransmisiones (`rtry`).** Columna `Rtry` de la línea de resumen del cliente.
- **Tabla de Sarpkaya.** El throughput de cada flujo es la media de los intervalos de 1 s del cliente desde t = 2 s. Después se hace la media de las diez repeticiones. La cuota de Prague es su media dividida por la suma de las dos medias.

En `ancho_de_banda`, `baseline` es la medida sin límite de ancho de banda. Los throughputs están en Mbit/s y los RTT en ms. Salvo en la tabla de Sarpkaya, cada fila es una sola ejecución de 60 s.
