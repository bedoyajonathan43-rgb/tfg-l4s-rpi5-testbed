#!/usr/bin/env python3
"""
apply_scale_correction.py  (v2 -- con margen de incertidumbre)

Aplica un factor de correccion temporal a los resultados de RTT medidos
en el entorno de simulacion 5G (rfsimulator), para estimar cual seria el
RTT "equivalente" si la simulacion corriera a la velocidad real de una
red 5G (donde cada frame dura 10ms de forma estricta).

    RTT_corregido = RTT_observado / factor_de_escala

NOVEDAD v2: el factor de escala fluctua con el tiempo (confirmado con
calc_scale_factor.py: coeficiente de variacion ~25% entre ventanas de
60s). Por eso este script acepta ahora un factor CENTRAL y un margen
(o un rango min/max explicito), y muestra el RTT corregido junto con
su intervalo de incertidumbre, no solo un valor puntual que sugeriria
una precision que en realidad no tenemos.

IMPORTANTE - limitaciones de esta correccion (documentar en el TFG):
  - El factor de escala VARIA con el tiempo segun la carga del sistema en
    cada momento; lo ideal es medirlo en una ventana temporal lo mas
    cercana posible a las pruebas que se quieren corregir.
  - Es una aproximacion de orden de magnitud, no una medicion directa.
    Asume que el jitter es "uniforme" en el tiempo, lo cual no es
    estrictamente cierto (hay picos y valles ya documentados).
  - No corrige efectos de segundo orden (p.ej. como el jitter interactua
    con los timers de retransmision TCP, RTO, etc.) -- solo aplica un
    escalado lineal simple sobre el RTT medido.

Uso:
    python3 apply_scale_correction.py <factor_central> [margen]
    python3 apply_scale_correction.py <factor_min> <factor_max> --rango

Ejemplos:
    python3 apply_scale_correction.py 109
    python3 apply_scale_correction.py 109 10.1
    python3 apply_scale_correction.py 90 150 --rango
"""

import sys

# Resultados ya obtenidos (RTT medio y mediana, en ms), tomados de los
# resumen.txt de cada escenario. Editar aqui si se repiten las pruebas o
# se anaden nuevos escenarios.
RESULTADOS = {
    "Uplink Prague":   {"rtt_medio": 1729, "rtt_mediana": 1721},
    "Uplink Cubic":    {"rtt_medio": 6840, "rtt_mediana": 7580},
    "Downlink Prague": {"rtt_medio": 2147, "rtt_mediana": 2165},
    "Downlink Cubic":  {"rtt_medio": 3303, "rtt_mediana": 3242},
}


def parse_args():
    args = sys.argv[1:]

    if not args:
        print(f"Uso: python3 {sys.argv[0]} <factor_central> [margen]")
        print(f"     python3 {sys.argv[0]} <factor_min> <factor_max> --rango")
        print("El factor de escala se obtiene con calc_scale_factor.py")
        sys.exit(1)

    if "--rango" in args:
        args.remove("--rango")
        if len(args) != 2:
            print("ERROR: con --rango hay que dar exactamente <factor_min> <factor_max>")
            sys.exit(1)
        try:
            f_min = float(args[0])
            f_max = float(args[1])
        except ValueError:
            print("ERROR: factor_min y factor_max deben ser numeros")
            sys.exit(1)
        if f_min <= 0 or f_max <= 0 or f_min >= f_max:
            print("ERROR: se requiere 0 < factor_min < factor_max")
            sys.exit(1)
        f_central = (f_min + f_max) / 2
        return f_central, f_min, f_max

    try:
        f_central = float(args[0])
    except ValueError:
        print("ERROR: el factor de escala debe ser un numero (ej. 109)")
        sys.exit(1)
    if f_central <= 0:
        print("ERROR: el factor de escala debe ser mayor que 0")
        sys.exit(1)

    if len(args) >= 2:
        try:
            margen = float(args[1])
        except ValueError:
            print("ERROR: el margen debe ser un numero (ej. 10.1)")
            sys.exit(1)
    else:
        # Sin margen explicito: usar por defecto un +-25% (el CV observado
        # empiricamente entre ventanas de tiempo con calc_scale_factor.py),
        # que es mas realista que asumir precision exacta.
        margen = f_central * 0.25
        print(f"(No se indico margen; se usa por defecto +-25% = ±{margen:.1f}x,")
        print(" el coeficiente de variacion observado entre ventanas de tiempo)")
        print()

    f_min = max(f_central - margen, 0.1)
    f_max = f_central + margen
    return f_central, f_min, f_max


def main():
    f_central, f_min, f_max = parse_args()

    print("=" * 92)
    print(f" CORRECCION APLICADA -- factor de escala: {f_central:.1f}x  (rango plausible: [{f_min:.1f}x , {f_max:.1f}x])")
    print(" (la simulacion va, de media, esta cantidad de veces mas lenta que una red 5G real,")
    print("  con esta fluctuacion segun el momento de la prueba)")
    print("=" * 92)
    print()

    header = (f"{'Escenario':<20} {'RTT observado':>14}   "
              f"{'Corregido (central)':>20}   {'Rango plausible':>28}")
    print(header)
    print("-" * len(header))

    for nombre, datos in RESULTADOS.items():
        rtt = datos["rtt_medio"]
        corr_central = rtt / f_central
        corr_min = rtt / f_max   # factor mas alto -> RTT corregido mas bajo
        corr_max = rtt / f_min   # factor mas bajo  -> RTT corregido mas alto
        rango_str = f"[{corr_min:.1f} , {corr_max:.1f}] ms"
        print(f"{nombre:<20} {rtt:>11.0f} ms   {corr_central:>17.1f} ms   {rango_str:>28}")

    print()
    print("Interpretacion: 'Corregido (central)' usa el factor de escala central.")
    print("'Rango plausible' muestra el intervalo de RTT equivalente considerando")
    print("la fluctuacion real del factor de escala segun el momento de la prueba")
    print("(no un unico numero preciso, que daria una falsa sensacion de exactitud).")
    print()
    print("Son valores ESTIMADOS, no medidos directamente -- ver limitaciones en")
    print("el encabezado de este script antes de citarlos como definitivos.")


if __name__ == "__main__":
    main()
