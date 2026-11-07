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
#   F) latency       → Inyecta latencia de red persistente con tc/netem dentro del
#                      contenedor. El servicio NO se cae, se degrada (P95 > 250ms).
#                      RECUPERACIÓN: intervención manual del SRE (`latency-fix`).
#   G) latency-fix   → Remediación manual (Runbook SRE): elimina la regla netem
#                      activa en el contenedor para restablecer la latencia nominal.
#
# Uso:
#   ./gameday_inject_aws.sh service-down <INSTANCE_ID> [REGION] [CRASHES]
#   ./gameday_inject_aws.sh latency      <INSTANCE_ID> [REGION] [DELAY_MS]
#   ./gameday_inject_aws.sh latency-fix  <INSTANCE_ID> [REGION]
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
  echo "  $0 latency      <INSTANCE_ID> [REGION] [DELAY_MS]"
  echo "  $0 latency-fix  <INSTANCE_ID> [REGION]"
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
  # ESCENARIO F — DEGRADACIÓN DE LATENCIA (persistente hasta remediación manual)
  # ============================================================================
  latency)
    DELAY_MS="${4:-400}"

    echo -e "${RED}[ATAQUE] Inyectando ${DELAY_MS}ms de latencia PERSISTENTE en el contenedor ${CONTAINER_NAME}...${NC}"
    echo -e "${YELLOW}El servicio NO se cae: se degrada (probe_success sigue en 1) hasta que el SRE intervenga.${NC}"

    # netem se aplica DENTRO del namespace de red del contenedor `mattermost`
    # (nsenter desde el host). La falla queda activa indefinidamente para que
    # el equipo SRE diagnostique la alerta y ejecute el runbook de remediación.
    read -r -d '' INJECT_CMD <<EOF || true
PID=\$(docker inspect -f '{{.State.Pid}}' ${CONTAINER_NAME})
[ -n "\$PID" ] && [ "\$PID" != "0" ] || { echo "ERROR: contenedor ${CONTAINER_NAME} no esta corriendo"; exit 1; }
command -v tc >/dev/null || dnf install -y iproute-tc >/dev/null 2>&1 || true
command -v tc >/dev/null || { echo "ERROR: falta tc (dnf install -y iproute-tc)"; exit 1; }
nsenter -t \$PID -n tc qdisc del dev eth0 root 2>/dev/null || true
nsenter -t \$PID -n tc qdisc add dev eth0 root netem delay ${DELAY_MS}ms
logger "GameDay: latencia persistente de ${DELAY_MS}ms inyectada en ${CONTAINER_NAME} (PID \$PID)"
echo "Latencia PERSISTENTE (${DELAY_MS}ms) activa en eth0 de ${CONTAINER_NAME} (PID \$PID)."
nsenter -t \$PID -n tc qdisc show dev eth0
EOF

    ESCAPED=$(printf '%s' "$INJECT_CMD" | python3 -c 'import json,sys; print(json.dumps([sys.stdin.read()]))')
    run_on_ec2 "inject persistent netem latency ${DELAY_MS}ms" "$ESCAPED"

    echo ""
    echo -e "${YELLOW}FLUJO DEL ESCENARIO (intervención manual SRE):${NC}"
    echo "  1. Detectar:   Grafana supera el umbral de 250ms y Prometheus dispara MattermostLatencySLODegraded."
    echo "  2. Investigar: Revisar en Loki/Tempo el aumento de duración en /api/v4/system/ping."
    echo "  3. Remediar:   Ejecutar el runbook de solución para eliminar el cuello de botella de red:"
    echo -e "     ${GREEN}$0 latency-fix ${INSTANCE_ID} ${REGION}${NC}"
    ;;

  # ============================================================================
  # ESCENARIO G — REMEDIACIÓN MANUAL DE LATENCIA (Runbook SRE)
  # ============================================================================
  latency-fix)
    echo -e "${GREEN}[REMEDIACIÓN SRE] Eliminando degradación de red (tc/netem) en ${CONTAINER_NAME}...${NC}"

    read -r -d '' FIX_CMD <<EOF || true
PID=\$(docker inspect -f '{{.State.Pid}}' ${CONTAINER_NAME})
[ -n "\$PID" ] && [ "\$PID" != "0" ] || { echo "ERROR: contenedor ${CONTAINER_NAME} no esta corriendo"; exit 1; }
nsenter -t \$PID -n tc qdisc del dev eth0 root 2>/dev/null || true
logger "GameDay: remediacion SRE aplicada; latencia netem eliminada en ${CONTAINER_NAME}"
echo "Regla netem eliminada exitosamente. Estado actual de eth0:"
nsenter -t \$PID -n tc qdisc show dev eth0
EOF

    ESCAPED=$(printf '%s' "$FIX_CMD" | python3 -c 'import json,sys; print(json.dumps([sys.stdin.read()]))')
    run_on_ec2 "SRE remediation: remove netem latency" "$ESCAPED"

    echo ""
    echo -e "${GREEN}✅ Remediación completada: la latencia regresará a valores nominales (<20ms) y la alerta se resolverá.${NC}"
    ;;

  *)
    echo -e "${RED}Escenario desconocido: ${SCENARIO}${NC}"
    usage
    ;;
esac

echo ""
echo -e "${GREEN}======================================================================"
echo "  Consolas de observabilidad:"
echo "    Mattermost: http://3.217.54.83:8065/signup_user_complete"
echo "    Grafana:    http://3.217.54.83:3000/"
echo "    Prometheus: http://3.217.54.83:9090/alerts?search="
echo -e "======================================================================${NC}"
