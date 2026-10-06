#!/bin/bash
# =============================================================================
# ruido.sh - TFG L4S, fase 4: cambia o consulta el ruido AWGN en caliente
# a través del servidor telnet de OAI (puerto 9090 dentro de cada contenedor).
#   Subida (UL): lo aplica el gNB  -> contenedor oai-gnb-basic
#   Bajada (DL): lo aplica la UE   -> contenedor oai-nr-ue-basic
# Uso:
#   ./ruido.sh ver                    muestra los canales activos en gNB y UE
#   ./ruido.sh ul <dB>                fija noise_power_dB en la subida
#   ./ruido.sh dl <dB>                fija noise_power_dB en la bajada
#   ./ruido.sh ambos <dB>             fija el mismo valor en los dos sentidos
# Requiere la red lanzada con RUIDO_OPTS="--rfsimulator.[0].options chanmod --telnetsrv"
# =============================================================================
GNB=oai-gnb-basic; UE=oai-nr-ue-basic

telnet_cmd() {  # $1 contenedor, resto: comandos
  local c=$1; shift
  local cmds=""; for x in "$@"; do cmds+="$x\n"; done
  docker exec "$c" bash -c "exec 3<>/dev/tcp/127.0.0.1/9090 || exit 2; sleep 0.3; printf '\n$cmds' >&3; sleep 0.8; printf 'exit\n' >&3; timeout 2 cat <&3" 2>&1 \
    | tr -d '\r' | grep -v '^\s*$'
}

set_noise() {  # $1 contenedor  $2 dB  (se aplica a los dos modelos de la lista; solo uno está activo)
  telnet_cmd "$1" "channelmod modify 0 noise_power_dB $2" "channelmod modify 1 noise_power_dB $2" "channelmod show current"
}

case "$1" in
  ver)   echo "== gNB (subida) =="; telnet_cmd $GNB "channelmod show current"
         echo "== UE (bajada) ==";  telnet_cmd $UE  "channelmod show current" ;;
  ul)    set_noise $GNB "$2" ;;
  dl)    set_noise $UE "$2" ;;
  ambos) set_noise $GNB "$2"; set_noise $UE "$2" ;;
  *)     sed -n '2,13p' "$0"; exit 1 ;;
esac
