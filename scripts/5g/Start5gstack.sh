#!/bin/bash
set -e

COMPOSE_DIR=~/oai-cn5g-fed/docker-compose
CORE_COMPOSE="docker-compose-basic-nrf.yaml"
RAN_COMPOSE="docker-compose-oai-rfsim-basic.yaml"
HOST_NET_IF="demo-oai"
UE_SUBNET="12.1.1.0/24"

cd "$COMPOSE_DIR"

echo "== 1. Levantando el core 5G =="
docker compose -f "$CORE_COMPOSE" up -d

echo "== 2. Esperando a que todo el core esté healthy (máx 90s) =="
CORE_SERVICES="oai-nrf oai-amf oai-smf oai-upf oai-udm oai-udr oai-ausf"
ALL_HEALTHY=false
for i in $(seq 1 18); do
    ALL_HEALTHY=true
    for svc in $CORE_SERVICES; do
        STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null || echo "missing")
        if [ "$STATUS" != "healthy" ]; then
            ALL_HEALTHY=false
        fi
    done
    if [ "$ALL_HEALTHY" = true ]; then
        echo "   Core healthy tras $((i*5))s"
        break
    fi
    sleep 5
done

if [ "$ALL_HEALTHY" != true ]; then
    echo "   AVISO: no todo el core reportó healthy a tiempo. Revisa manualmente:"
    docker ps -a --filter "name=oai" --format "table {{.Names}}\t{{.Status}}"
    exit 1
fi

echo "== 3. Verificando que el AMF esté registrado en el NRF =="
sleep 5
AMF_REG=$(docker logs oai-amf --tail 30 2>&1 | grep -c "successfully registered\|HTTP code (204)\|HTTP code (200)" || true)
if [ "$AMF_REG" -eq 0 ]; then
    echo "   AMF no confirmó registro reciente, reiniciándolo por seguridad..."
    docker compose -f "$CORE_COMPOSE" restart oai-amf
    sleep 15
fi

echo "== 4. Levantando gNB + UE =="
docker compose -f "$RAN_COMPOSE" up -d

echo "== 5. Esperando a que oaitun_ue1 exista (máx 60s) =="
UE_UP=false
for i in $(seq 1 12); do
    if docker exec oai-nr-ue-basic ip addr show oaitun_ue1 &>/dev/null; then
        UE_UP=true
        echo "   Interfaz oaitun_ue1 detectada tras $((i*5))s"
        break
    fi
    sleep 5
done

if [ "$UE_UP" != true ]; then
    echo "   ERROR: oaitun_ue1 no apareció tras 60s."
    echo "   Diagnóstico rápido - comprobando SCTP/NGAP del gNB:"
    docker logs oai-gnb-basic 2>&1 | grep -i "sctp\|ngap" | tail -10
    echo ""
    echo "   Si ves 'Connect failed: Connection refused', la IP del AMF en"
    echo "   ran-conf/gnb.conf no coincide con la IP real del AMF. Verifica con:"
    echo "   docker exec oai-amf hostname -I"
    exit 1
fi

echo "== 6. Detectando IP real del UPF y añadiendo ruta en el host =="
UPF_IP=$(docker exec oai-upf hostname -I | awk '{print $1}')
echo "   UPF IP detectada: $UPF_IP"

sudo ip route del "$UE_SUBNET" dev "$HOST_NET_IF" 2>/dev/null || true
sudo ip route add "$UE_SUBNET" via "$UPF_IP" dev "$HOST_NET_IF"

echo "== 7. Verificando conectividad end-to-end =="
sudo docker exec oai-nr-ue-basic ping -I oaitun_ue1 -c 4 192.168.70.129

echo ""
echo "== Listo. Stack 5G operativo. =="
echo "   UE IP: 12.1.1.130 (oaitun_ue1 dentro del contenedor oai-nr-ue-basic)"
echo "   UPF IP (N6/host side): $UPF_IP"
