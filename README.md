# TFG L4S — Testbed Raspberry Pi 5

Evaluación experimental de L4S (Low Latency, Low Loss, Scalable Throughput)
sobre un testbed físico de tres Raspberry Pi 5 interconectadas por Ethernet
punto a punto, comparando cuatro escenarios de AQM (pfifo, fq_codel sin ECN,
fq_codel con ECN clásico, y dualpi2 + TCP Prague con AccECN).

Este repositorio recoge los scripts de automatización de medidas, extracción
de métricas y generación de gráficas empleados en el Trabajo de Fin de Grado
*"Evaluación de L4S sobre Redes Fijas"* (Jonathan Bedoya Marín).

## Topología del testbed

```
rp51 (cliente iperf)  <-->  rp50 (router / AQM)  <-->  rp52 (servidor iperf)
192.168.20.2                eth1: .20.1 / eth0: .10.1        192.168.10.2
```

- **rp50**: aplica en `eth0` (salida hacia rp52) la limitación de ancho de
  banda (HTB) y la disciplina AQM bajo evaluación en cada escenario.
- **rp51**: genera el tráfico TCP de prueba mediante `iperf2` compilado con
  soporte L4S.
- **rp52**: recibe el tráfico y actúa como referencia de throughput
  efectivamente entregado.

Los tres nodos ejecutan Debian GNU/Linux 12 (Bookworm) ARM64, kernel
6.6.51-v8-16k+, con soporte nativo para `dualpi2` y TCP Prague/AccECN.

## Estructura del repositorio

```
.
├── scripts/
│   ├── automatizacion/       # Se ejecutan EN rp51 (cliente).
│   │                         # Orquestan el barrido de AQM x ancho de banda,
│   │                         # lanzando tc/HTB en rp50 vía SSH e iperf2
│   │                         # en cliente y servidor.
│   │   ├── MedidasAutomatizadas.sh          # Campaña de flujo único
│   │   ├── MedidasAutomatizadasParalelo.sh  # Campaña de flujos paralelos (-P 2)
│   │   └── MedidasV8.sh                     # Campaña de coexistencia con ruido Cubic
│   │
│   ├── sarpkaya/              # Se ejecuta EN rp51.
│   │   └── Reproducciones_v2_con_sanidad.sh
│   │       Reproducción de la metodología de Sarpkaya et al. (2024):
│   │       BW fijo a 100 Mbit/s, barrido de tamaño de buffer (0.5-8x BDP),
│   │       RTT base de 10 ms emulado con netem, Prague sobre los 4 AQM.
│   │
│   ├── diagnostico/            # Se ejecuta EN rp51.
│   │   └── DiagnosticoConRTT_ConfirmacionSesgo.sh
│   │       Captura de estado de socket (ss -tiom) para confirmar el
│   │       mecanismo de fallback ECN de TCP Prague bajo fq_codel con
│   │       RTT base emulado.
│   │
│   └── parsing/                # Se ejecutan en la máquina de procesado
│       │                       # (Ubuntu), NO en las Raspberry Pi.
│       ├── extraer_metricas.py            # Campaña de flujo individual
│       ├── extraer_metricas_paralelo.py   # Campaña de flujos paralelos
│       ├── extraer_metricas_ruido.py      # Campaña de coexistencia
│       └── graficar_comparativa.py        # Gráficas throughput/RTT vs BW
│
├── metricas/                   # CSV ya generados por los scripts de parsing
│   ├── metricas_individual.csv
│   ├── metricas_paralelo.csv
│   └── metricas_ruido.csv
│
├── resultados/                 # (Vacío por ahora) Aquí se copian los .txt
│                                # brutos de iperf2 descargados de las RPi
│                                # antes de ejecutar los scripts de parsing.
│                                # Se añadirán en una fase posterior del TFG.
│
└── figuras/                    # (Generada automáticamente) Salida de
                                 # graficar_comparativa.py
```

## Flujo de trabajo

1. **Medida** (en rp51, vía SSH desde la Ubuntu de control):
   ```bash
   scp scripts/automatizacion/MedidasAutomatizadas.sh rpiuser@192.168.20.2:~/
   ssh rpiuser@192.168.20.2 './MedidasAutomatizadas.sh'
   ```
   El script SSH-ea a su vez a rp50 para aplicar tc/HTB/AQM antes de cada
   prueba, y lanza `iperf2 -e -w 2000K` contra rp52.

2. **Descarga de resultados** desde rp51/rp52 a la máquina de procesado,
   dentro de `resultados/<nombre_carpeta_campaña>/`.

3. **Extracción de métricas** (en la máquina de procesado, raíz del repo):
   ```bash
   python3 scripts/parsing/extraer_metricas.py
   python3 scripts/parsing/extraer_metricas_paralelo.py
   python3 scripts/parsing/extraer_metricas_ruido.py
   ```
   Genera los CSV en `metricas/`.

4. **Generación de gráficas**:
   ```bash
   python3 scripts/parsing/graficar_comparativa.py
   ```
   Genera las figuras en `figuras/`.

## Escenarios AQM evaluados

| ID | AQM | Congestión | ECN |
|----|-----|-----------|-----|
| E1 | pfifo (sin gestión activa) | Cubic | Desactivado |
| E2 | fq_codel | Cubic | Desactivado (`noecn`) |
| E3 | fq_codel | Cubic | ECN clásico (`tcp_ecn=1`) |
| E4 | dualpi2 | TCP Prague | AccECN (`tcp_ecn=3`) |

## Requisitos

- **Raspberry Pi (rp50/rp51/rp52)**: kernel con soporte `dualpi2` y TCP
  Prague (rama [L4STeam/linux](https://github.com/L4STeam/linux)), `iperf2`
  compilado con soporte L4S, `iproute2` con el plugin `q_dualpi2.so`.
- **Máquina de procesado**: Python 3.9+, `matplotlib`.

## Autor

Jonathan Bedoya Marín — Trabajo de Fin de Grado en Ingeniería de
Telecomunicación.
