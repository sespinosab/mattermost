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
#   A) service-down  → Mata el contenedor Mattermost (docker kill).
#                      RECUPERACIÓN: automática por la restart policy de Docker.
#                      No se reinicia nada a mano.
#   F) latency       → Inyecta latencia de red con tc/netem en el host EC2.
#                      El servicio NO se cae, se degrada (P95 > 250ms).
#                      RECUPERACIÓN: auto-expiración programada (tc qdisc del).
#
# Uso:
#   ./gameday_inject_aws.sh service-down <INSTANCE_ID> [REGION]
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

  local cmd_id
  cmd_id=$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --comment "GameDay: ${description}" \
    --parameters "commands=${commands_json}" \
    --query "Command.CommandId" --output text)

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
    echo -e "${RED}[ATAQUE] Matando el contenedor '${CONTAINER_NAME}' en la EC2...${NC}"
    run_on_ec2 "kill mattermost container" \
      "[\"docker kill ${CONTAINER_NAME} || true\",\"echo '--- estado tras el kill ---'\",\"docker ps -a --filter name=${CONTAINER_NAME} --format '{{.Names}}: {{.Status}}'\"]"

    echo ""
    echo -e "${YELLOW}OBSERVAR EN VIVO (no se interviene manualmente):${NC}"
    echo "  → Grafana:    panel 'Estado del Servicio' pasa a DOWN; SLI y Error Budget caen"
    echo "  → Prometheus: MattermostServiceDown → PENDING → FIRING (~1 min)"
    echo "  → RECUPERACIÓN: 'restart: unless-stopped' revive el contenedor solo (~30s)"
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

    echo -e "${RED}[ATAQUE] Inyectando ${DELAY_MS}ms de latencia en el host EC2 por ${DURATION_S}s...${NC}"
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
