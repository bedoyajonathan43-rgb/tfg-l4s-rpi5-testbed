# Métodos descartados

Scripts de la primera fase de 5G. Se conservan porque la memoria explica por qué se abandonaron, pero **no se usaron para ningún resultado final**.

| Fichero | Qué hacía | Por qué se descartó |
|---|---|---|
| `CalScaleFactor.py`, `apply_scale_correction.py`, `calibrar_cpu.sh` | Medían cuánto más lento que el reloj iba el simulador y corregían los tiempos con un factor | El factor cambiaba según el modo de la prueba. Se sustituyó por la modificación que hace correr el simulador en tiempo real |
| `run_l4s_comparison.sh`, `Capturel4s.sh` | Comparación entre Prague y Cubic con un límite HTB y el AQM en la UPF | iperf2 no aplicaba el algoritmo pedido, así que los flujos «Prague» eran Cubic. Además, el tutor pidió que el límite lo pusiera la radio y no HTB |
| `check_ecn_survival.sh` | Comprobaba si las marcas ECN sobrevivían al paso por la radio | Era de la fase en la que se marcaba fuera del gNB. La llegada de las marcas a la UE se comprueba ahora con las capturas de `analisis/` |
