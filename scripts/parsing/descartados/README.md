# Primera versión del cálculo de métricas

`extraer_metricas*.py` y `graficar_comparativa.py` son los scripts con los que se calcularon al principio las tablas de red fija, y los tres CSV son lo que generaban. Se sustituyeron por `calcular_metricas.py` y `graficar_red_fija.py` al revisar los datos en bruto, por dos motivos:

- En la campaña de un flujo, el RTT medio se saltaba los intervalos sin datos (0 bytes) y contaba el último intervalo, que es parcial. El cambio se nota en E1 a 1, 2 y 5 Mbit/s y en E4 a 1 Mbit/s.
- En las campañas de dos flujos y de convivencia se contaba también ese último intervalo parcial. La diferencia es inferior al 1 %.

Se conservan como registro. Los valores de la memoria son los de `metricas/red_fija/`.
