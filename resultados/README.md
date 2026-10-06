# Datos en bruto de red fija

`red_fija_iperf.zip` (2 MB) contiene las salidas de texto de iperf2, del cliente y del servidor, de las campañas de red fija que usa la memoria. Los scripts de `scripts/parsing/` lo leen sin descomprimirlo. Si se descomprime aquí, leen las carpetas.

| Carpeta dentro del zip | Campaña | Fecha |
|---|---|---|
| `resultadosFinales_1_flujoC/` | Un flujo, de 1 a 500 Mbit/s y sin límite | 24/07/2026 |
| `resultadosFinales_paraleloC/` | Dos flujos en paralelo | 24/07/2026 |
| `resultadosFinales_paraleloCA/baseline/` | Dos flujos en paralelo, repetición sin límite | 26/07/2026 |
| `resultados_flujo_ruidoCD/` | Convivencia con un flujo de ruido Cubic | 24 y 25/07/2026 |
| `resultados_fairness_sarpkayaB/` | Reproducción de Sarpkaya et al., segunda serie (diez repeticiones) | 28/07/2026 |

Cada prueba tiene un fichero `<escenario>_cliente.txt` y otro `<escenario>_servidor.txt`. En la campaña de convivencia hay además `<escenario>_ruido_cliente.txt` y `<escenario>_ruido_servidor.txt`, y en la de Sarpkaya los nombres llevan el buffer, la repetición y `principal` (Prague) o `ruido` (Cubic). `log_sanidad_tc.csv` es la comprobación del volumen de datos de cada repetición de Sarpkaya.

No están las capturas de paquetes, los registros de `ss` ni las estadísticas de `tc` de cada prueba (unos 74 GB en total), ni las series y repeticiones que la memoria no usa en sus tablas.
