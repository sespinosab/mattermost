#!/usr/bin/env bash
# ==============================================================================
# gameday_inject_aws.sh — Inyección controlada de fallas para el GameDay (AWS)
#
# Topología objetivo (producción, definida en terraform/modules/compute/main.tf):
#   - Mattermost corre como contenedor `mattermost` en una instancia EC2
#     con la política `--restart unless-stopped`.
#   - La base de datos es RDS (gestionada); este script NO la toca.
#   - La inyección se envía a la EC2 vía AWS SSM Run Command (sin abrir SSH).
#
# Escenarios:
#   A) service-down  → Simula un crash: kill -9 al proceso principal del contenedor
#                      desde el host (NO `docker kill`, que Docker trata como parada
#                      manual y no reinicia).
#                      RECUPERACIÓN: automática por la restart policy de Docker.
#                      No se reinicia nada a mano.
#   F) latency       → Inyecta latencia de red con tc/netem dentro del contenedor.
#                      El servicio NO se cae, se degrada (P95 > 250ms).
#                      RECUPERACIÓN: auto-expiración programada (tc qdisc del).
#
# Uso:
#   ./gameday_inject_aws.sh service-down <INSTANCE_ID> [REGION] [CRASHES]
#   ./gameday_inject_aws.sh latency      <INSTANCE_ID> [REGION] [DELAY_MS] [DURATION_S]
#
# Requisitos locales:
#   - AWS CLI v2 autenticado con permisos ssm:SendCommand / ssm:GetCommandInvocation.
#   - La instancia EC2 registrada en SSM (ya tiene AmazonSSMManagedInstanceCore).
# ==============================================================================
set -euo pipefail

SCENARIO="${1:-}"
INSTANCE_ID="${2:-}"
REGION="${3:-us-east-1}"

# Nombre real del contenedor en la EC2 primaria. Verificado en vivo: el deploy de
# CI/CD (scripts/deploy.sh + docker-compose.yml) lo crea como `mattermost-app` con
# restart=unless-stopped, en la red `mattermost_mattermost_network`.
CONTAINER_NAME="mattermost-app"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

usage() {
  echo "Uso:"
  echo "  $0 service-down <INSTANCE_ID> [REGION]"
  echo "  $0 latency      <INSTANCE_ID> [REGION] [DELAY_MS] [DURATION_S]"
  exit 1
}

[ -z "$SCENARIO" ] && usage
[ -z "$INSTANCE_ID" ] && { echo -e "${RED}ERROR: falta INSTANCE_ID${NC}"; usage; }

# ------------------------------------------------------------------------------
# Envía un bloque de comandos a la EC2 por SSM y espera el resultado.
# ------------------------------------------------------------------------------
run_on_ec2() {
  local description="$1"; shift
  local commands_json="$1"

  echo -e "${YELLOW}→ Enviando a ${INSTANCE_ID} vía SSM: ${description}${NC}"

  # Los parámetros se pasan desde un archivo JSON: la sintaxis abreviada
  # `commands=[...]` del CLI NO interpreta los saltos de línea (\n) y rompía los
  # comandos de varias líneas en la EC2 (verificado en el ensayo).
  local params_file cmd_id
  params_file="$(mktemp)"
  printf '{"commands": %s}' "$commands_json" > "$params_file"
  cmd_id=$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --comment "GameDay: ${description}" \
    --parameters "file://${params_file}" \
    --query "Command.CommandId" --output text)
  rm -f "$params_file"

  echo "  CommandId: ${cmd_id}"
  aws ssm wait command-executed \
    --region "$REGION" \
    --command-id "$cmd_id" \
    --instance-id "$INSTANCE_ID" 2>/dev/null || true

  aws ssm get-command-invocation \
    --region "$REGION" \
    --command-id "$cmd_id" \
    --instance-id "$INSTANCE_ID" \
    --query "{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}" \
    --output text
}

echo ""
echo -e "${RED}======================================================================"
echo "  GAMEDAY — INYECCIÓN DE FALLA (AWS / SSM)"
echo "======================================================================"
echo -e "  Escenario:  ${YELLOW}${SCENARIO}${RED}"
echo -e "  Instancia:  ${YELLOW}${INSTANCE_ID}${RED}  Región: ${YELLOW}${REGION}${RED}"
echo -e "======================================================================${NC}"
echo ""

case "$SCENARIO" in
  # ============================================================================
  # ESCENARIO A — CAÍDA DEL SERVICIO (self-healing por restart policy)
  # ============================================================================
  service-down)
    CRASHES="${4:-10}"

    echo -e "${RED}[ATAQUE] Crash-loop de '${CONTAINER_NAME}': ${CRASHES} crashes consecutivos (kill -9 desde el host)...${NC}"
    # IMPORTANTE: NO usar `docker kill` ni `docker stop`. Ambos pasan por la API de
    # Docker, que los trata como parada MANUAL e ignora la restart policy
    # (verificado en el ensayo: el contenedor quedó en Exited (137) sin reiniciarse).
    # Un `kill -9` al PID del contenedor desde el host simula un crash real del
    # proceso: Docker lo ve como salida inesperada y aplica `unless-stopped`.
    #
    # Un solo crash se recupera en ~7s (demasiado corto para que la alerta dispare).
    # Por eso se repite: si el contenedor muere antes de 10s de vida, Docker DUPLICA
    # el tiempo de espera entre reinicios (100ms, 200ms, 400ms ... backoff exponencial),
    # lo que produce un crash-loop realista cuya caída crece a ~2 min con 10 crashes.
    # Al terminar el bucle nadie interviene: Docker levanta el contenedor y, al vivir
    # más de 10s, el backoff se reinicia. El bucle corre EN la EC2 (nohup), así que la
    # inyección es autónoma y no depende de esta sesión.
    read -r -d '' CRASH_CMD <<EOF || true
cat > /tmp/gameday_crashloop.sh <<'INNER'
#!/bin/bash
for i in \$(seq 1 ${CRASHES}); do
  PID=0
  for t in \$(seq 1 90); do
    PID=\$(docker inspect -f '{{.State.Pid}}' ${CONTAINER_NAME} 2>/dev/null || echo 0)
    [ "\$PID" != "0" ] && [ -n "\$PID" ] && break
    sleep 1
  done
  [ "\$PID" != "0" ] && kill -9 "\$PID" 2>/dev/null
  logger "GameDay: crash \$i/${CRASHES} de ${CONTAINER_NAME}"
  sleep 1
done
logger "GameDay: crash-loop terminado; Docker debe recuperar el contenedor solo"
INNER
chmod +x /tmp/gameday_crashloop.sh
nohup /tmp/gameday_crashloop.sh >/tmp/gameday_crashloop.log 2>&1 &
echo "Crash-loop lanzado en background (PID \$!), ${CRASHES} crashes."
EOF
    ESCAPED=$(printf '%s' "$CRASH_CMD" | python3 -c 'import json,sys; print(json.dumps([sys.stdin.read()]))')
    run_on_ec2 "crash-loop mattermost (${CRASHES} kill -9)" "$ESCAPED"

    echo ""
    echo -e "${YELLOW}OBSERVAR EN VIVO (no se interviene manualmente):${NC}"
    echo "  → Grafana:    panel 'Estado del Servicio' pasa a DOWN; SLI y Error Budget caen"
    echo "  → Prometheus: MattermostServiceDown → PENDING → FIRING (~1 min de caída sostenida)"
    echo "  → RECUPERACIÓN: al terminar el crash-loop, 'restart: unless-stopped' deja el"
    echo "    contenedor arriba solo; no se ejecuta ningún comando de recuperación."
    echo ""
    echo -e "${GREEN}Inyección aplicada. La plataforma se recupera sola; NO reiniciar a mano.${NC}"
    echo -e "Para verificar la auto-recuperación:"
    echo -e "  aws ssm send-command --region ${REGION} --instance-ids ${INSTANCE_ID} \\"
    echo -e "    --document-name AWS-RunShellScript \\"
    echo -e "    --parameters 'commands=[\"docker ps --filter name=${CONTAINER_NAME} --format {{.Status}}\"]'"
    ;;

  # ============================================================================
  # ESCENARIO F — DEGRADACIÓN DE LATENCIA (auto-expiración, sin reinicio)
  # ============================================================================
  latency)
    DELAY_MS="${4:-400}"
    DURATION_S="${5:-240}"

    echo -e "${RED}[ATAQUE] Inyectando ${DELAY_MS}ms de latencia en el contenedor ${CONTAINER_NAME} por ${DURATION_S}s...${NC}"
    echo -e "${YELLOW}El servicio NO se cae: se degrada (probe_success sigue en 1).${NC}"

    # netem se aplica DENTRO del namespace de red del contenedor `mattermost`
    # (nsenter desde el host, sin necesitar NET_ADMIN en el contenedor ni cambiar
    # el `docker run` de Terraform). Motivo: el blackbox sondea a Mattermost por el
    # puente de Docker (host.docker.internal), tráfico que NO pasa por la interfaz
    # física de la EC2, así que un netem en el host no afectaría la medición.
    # Efecto: retrasa las respuestas de Mattermost (egress de su eth0).
    # La reversión queda PROGRAMADA en la propia EC2 con un 'sleep' en background,
    # de modo que el defecto se auto-expira aunque el operador no intervenga.
    # Si el contenedor se reinicia, su namespace se destruye y el defecto desaparece.
    read -r -d '' INJECT_CMD <<EOF || true
PID=\$(docker inspect -f '{{.State.Pid}}' ${CONTAINER_NAME})
[ -n "\$PID" ] && [ "\$PID" != "0" ] || { echo "ERROR: contenedor ${CONTAINER_NAME} no esta corriendo"; exit 1; }
command -v tc >/dev/null || dnf install -y iproute-tc >/dev/null 2>&1 || true
command -v tc >/dev/null || { echo "ERROR: falta tc (dnf install -y iproute-tc)"; exit 1; }
nsenter -t \$PID -n tc qdisc del dev eth0 root 2>/dev/null || true
nsenter -t \$PID -n tc qdisc add dev eth0 root netem delay ${DELAY_MS}ms
echo "Latencia ${DELAY_MS}ms aplicada en eth0 de ${CONTAINER_NAME} (PID \$PID). Reversion automatica en ${DURATION_S}s."
nsenter -t \$PID -n tc qdisc show dev eth0
# Reversión auto-expirante e independiente de la sesión SSM:
nohup sh -c "sleep ${DURATION_S}; nsenter -t \$PID -n tc qdisc del dev eth0 root 2>/dev/null || true; logger 'GameDay: latencia netem revertida automaticamente'" >/dev/null 2>&1 &
echo "Reversion programada (PID \$!)."
EOF

    # Escapar comillas para el JSON de --parameters
    ESCAPED=$(printf '%s' "$INJECT_CMD" | python3 -c 'import json,sys; print(json.dumps([sys.stdin.read()]))')
    run_on_ec2 "inject netem latency ${DELAY_MS}ms for ${DURATION_S}s" "$ESCAPED"

    echo ""
    echo -e "${YELLOW}OBSERVAR EN VIVO (no se interviene manualmente):${NC}"
    echo "  → Grafana:    panel de Latencia cruza el umbral de 250ms"
    echo "  → Prometheus: MattermostLatencySLODegraded → FIRING (~1 min)"
    echo "  → probe_success SIGUE en 1 (el servicio nunca se cae)"
    echo "  → RECUPERACIÓN: la regla netem se auto-elimina a los ${DURATION_S}s;"
    echo "    Mattermost no se reinicia y la latencia vuelve a su rango nominal."
    echo ""
    echo -e "${GREEN}Inyección aplicada con reversión automática programada.${NC}"
    echo -e "Reversión manual de emergencia (solo si algo falla; reiniciar el contenedor también la elimina):"
    echo -e "  aws ssm send-command --region ${REGION} --instance-ids ${INSTANCE_ID} \\"
    echo -e "    --document-name AWS-RunShellScript \\"
    echo -e "    --parameters 'commands=[\"nsenter -t \$(docker inspect -f {{.State.Pid}} ${CONTAINER_NAME}) -n tc qdisc del dev eth0 root\"]'"
    ;;

  *)
    echo -e "${RED}Escenario desconocido: ${SCENARIO}${NC}"
    usage
    ;;
esac

echo ""
echo -e "${GREEN}======================================================================"
echo "  Consolas de observabilidad:"
echo "    Grafana:    http://<HOST_OBS>:3000"
echo "    Prometheus: http://<HOST_OBS>:9090/alerts"
echo -e "======================================================================${NC}"
