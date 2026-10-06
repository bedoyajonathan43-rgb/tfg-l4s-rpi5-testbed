# Figuras de resultados

Figuras del capítulo de resultados de la memoria, en PDF.

## Red fija

| Figura | Script | Datos |
|---|---|---|
| `baseline_comparativa` | `scripts/parsing/graficar_red_fija.py` | `metricas/red_fija/tabla_un_flujo.csv` |
| `comparativa_throughput`, `comparativa_rtt` | `graficar_red_fija.py` | `tabla_un_flujo.csv` |
| `paralelo_throughput`, `paralelo_rtt` | `graficar_red_fija.py` | `tabla_dos_flujos.csv` |
| `ruido_reparto_throughput` | `graficar_red_fija.py` | `tabla_ruido_reparto.csv` |
| `ruido_rtt_colas_e4` | `graficar_red_fija.py` | `tabla_ruido_E4.csv` |
| `sarpkaya_reparto_throughput` | `graficar_red_fija.py` | `tabla_sarpkaya.csv` |
| `serie_temporal_rtt_1mbit`, `ruido_caso_1mbit_colapso` | `scripts/parsing/graficar_series_temporales.py` | `resultados/red_fija_iperf.zip` |
| `sarpkaya_diagnostico_rtt_pacing` | `scripts/parsing/graficar_pacing_diagnostico.py` | Capturas de `ss` que no están en el repositorio. El PDF es el original |

## 5G

| Figura | Script | Datos |
|---|---|---|
| `5g_calibracion_umbral`, `5g_40mhz_resumen`, `5g_10mhz_ruido`, `5g_retardo_tramos` | `scripts/5g/analisis/figuras_5g.py` | Valores copiados de `metricas/5g/<campaña>/` |
| `5g_serie_40mhz`, `5g_serie_10mhz` | `scripts/5g/analisis/figura_series.py` | `metricas/5g/series/` |
