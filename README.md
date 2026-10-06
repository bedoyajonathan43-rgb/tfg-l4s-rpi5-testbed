# Evaluación de L4S sobre redes fijas y 5G

Código, configuración y resultados del Trabajo de Fin de Grado «Evaluación de L4S sobre Redes Fijas y 5G», de Jonathan Bedoya Marín (ETSI de Telecomunicación, Universidad de Málaga).

El trabajo mide qué gana L4S (Low Latency, Low Loss and Scalable Throughput: TCP Prague, AccECN y el AQM DualPI2) frente a las colas clásicas, en dos entornos:

- **Red fija.** Tres Raspberry Pi 5 conectadas por Ethernet. Se comparan cuatro configuraciones del router con el mismo tráfico.
- **5G.** Una red de OpenAirInterface con el simulador de radio. La cola está en la estación base (gNB), así que el marcado L4S se ha añadido en su capa RLC.

## Qué hay en cada carpeta

```
scripts/
  automatizacion/   campañas de medida de red fija (un flujo, dos flujos, convivencia)
  sarpkaya/         reproducción del estudio de Sarpkaya et al.
  diagnostico/      captura del estado del socket de Prague (ECN fallback)
  parsing/          cálculo de las tablas y figuras de red fija
  5g/               entorno 5G: configuración, parches de OAI, campañas y análisis
metricas/
  red_fija/         tablas de red fija de la memoria, en CSV
  5g/               resumen de cada campaña de 5G
figuras/            figuras de resultados de la memoria, en PDF
resultados/         salidas de iperf2 de las campañas de red fija que usa la memoria
```

Cada carpeta con contenido propio tiene su README: `scripts/5g/`, `metricas/red_fija/`, `metricas/5g/`, `figuras/` y `resultados/`.

## Red fija

```
rp51 (cliente iperf2)  <-->  rp50 (router con el AQM)  <-->  rp52 (servidor iperf2)
192.168.20.2                 eth1: .20.1 / eth0: .10.1         192.168.10.2
```

El router rp50 limita el ancho de banda con HTB en `eth0`, hacia rp52, y pone debajo la cola de cada escenario:

| Escenario | Cola en el router | Control de congestión | ECN |
|---|---|---|---|
| E1 | pfifo (1000 paquetes) | Cubic | No |
| E2 | fq_codel | Cubic | No (`noecn`) |
| E3 | fq_codel | Cubic | ECN clásico (`tcp_ecn=1`) |
| E4 | dualpi2 | TCP Prague | AccECN (`tcp_ecn=3`) |

Los tres nodos usan Debian 12 (Bookworm) para ARM64 con un núcleo 6.6 que incluye `dualpi2`, TCP Prague y AccECN, e iperf2 compilado desde su código fuente.

Los scripts de medida **se ejecutan en rp50**. Configuran `tc` en el propio router y lanzan por SSH el servidor en rp52 y el cliente en rp51. Cada prueba dura 60 s.

| Script | Campaña |
|---|---|
| `automatizacion/MedidasAutomatizadas.sh` | Un flujo, de 1 a 500 Mbit/s y sin límite |
| `automatizacion/MedidasAutomatizadasParalelo.sh` | Dos flujos iguales en paralelo (`-P 2`) |
| `automatizacion/MedidasV8.sh` | Convivencia: el flujo de cada escenario más un flujo de ruido Cubic |
| `sarpkaya/Reproducciones_v2_con_sanidad.sh` | Prague y Cubic a 100 Mbit/s con 10 ms de RTT, cinco tamaños de buffer y diez repeticiones |
| `diagnostico/DiagnosticoConRTT_ConfirmacionSesgo.sh` | Estado del socket de Prague cada 0,5 s (se ejecuta en rp51) |

La carpeta de resultados y la ventana TCP se fijan en la cabecera de cada script y se cambiaron de una serie a otra. Las series de la memoria se lanzaron con `-w 2000K`.

Para rehacer las tablas y las figuras de red fija no hace falta la maqueta. Basta con Python 3 y matplotlib:

```bash
python3 scripts/parsing/calcular_metricas.py          # tablas en metricas/red_fija/
python3 scripts/parsing/graficar_red_fija.py          # ocho figuras en figuras/
python3 scripts/parsing/graficar_series_temporales.py # dos figuras en figuras/
```

El primero y el tercero leen `resultados/red_fija_iperf.zip` sin descomprimirlo; el segundo lee las tablas que genera el primero.

## 5G

Todo lo de 5G está explicado en [`scripts/5g/README.md`](scripts/5g/README.md): versiones, las dos modificaciones de OpenAirInterface, cómo lanzar una campaña y cómo se analizan los resultados. Qué campaña se usa en cada parte de la memoria está en [`metricas/5g/README.md`](metricas/5g/README.md).

```bash
python3 scripts/5g/analisis/figuras_5g.py     # cuatro figuras de resultados
python3 scripts/5g/analisis/figura_series.py  # dos figuras de evolución temporal
```

## Datos que no están aquí

| Datos | Tamaño | Por qué no están |
|---|---|---|
| Capturas de paquetes y registros completos de red fija | Unos 74 GB | No caben en un repositorio. De cada prueba se han subido las salidas del cliente y del servidor de iperf2, que es de donde salen las tablas |
| Datos en bruto de las campañas de 5G (una carpeta por prueba) | Unos 940 MB | Solo se han subido los resúmenes de cada campaña |
| Capturas del estado del socket de la figura del ECN fallback | Pequeño | No se conservaron junto al resto. La figura está en `figuras/`, pero no se puede regenerar desde el repositorio |

## Autor

Jonathan Bedoya Marín. Trabajo de Fin de Grado, Grado en Ingeniería de Telecomunicación, Universidad de Málaga, 2026.
