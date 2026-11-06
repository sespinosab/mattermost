#!/usr/bin/env bash
# ==============================================================================
# gameday_watch.sh — Apoyo para el GameDay: revisión previa, espera de estado
# nominal, registro de la línea de tiempo (evidencia) y consulta de logs de Loki.
#
# Subcomandos (solo lectura; NO inyectan fallas, eso lo hace gameday_inject_aws.sh):
#   preflight                       Verifica credenciales, SSM, Prometheus, alertas y servicio
#   wait-nominal [MAX_SEGUNDOS]     Espera SLI 5m = 1 y cero alertas (por defecto 600 s)
#   watch [SEGUNDOS] [ETIQUETA]     Registra cada 5 s probe/latencia/HTTP/SLI/alertas en
#                                   evidencias/<ETIQUETA>-<fecha>.log (por defecto 300 s)
#   loki INICIO_UTC FIN_UTC         Logs de Mattermost desde Loki (vía SSM), fechas ISO UTC,
#                                   p. ej. 2026-11-06T20:24:40Z 2026-11-06T20:27:10Z
#
# Variables opcionales: PROM_URL, APP_URL, INSTANCE_ID, AWS_REGION, EVID_DIR
# ==============================================================================
set -uo pipefail

PROM_URL="${PROM_URL:-http://3.217.54.83:9090}"
APP_URL="${APP_URL:-http://3.217.54.83:8065}"
INSTANCE_ID="${INSTANCE_ID:-i-0931fe9de23859d52}"
REGION="${AWS_REGION:-us-east-1}"
EVID_DIR="${EVID_DIR:-evidencias}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $*"; }
fail() { echo -e "${RED}[FALLO]${NC} $*"; }

# Devuelve el valor del primer resultado de una consulta instantánea, o "n/d"
pval() {
  curl -s --max-time 6 -G "${PROM_URL}/api/v1/query" --data-urlencode "query=$1" 2>/dev/null |
    python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)['data']['result']
    print(round(float(r[0]['value'][1]), 4) if r else 'n/d')
except Exception:
    print('n/d')"
}

# Lista de alertas Mattermost activas como "Nombre:estado,..." (vacío si no hay)
alerts() {
  curl -s --max-time 6 -G "${PROM_URL}/api/v1/query" --data-urlencode 'query=ALERTS{alertname=~"Mattermost.*"}' 2>/dev/null |
    python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)['data']['result']
    print(','.join(x['metric']['alertname'].replace('Mattermost', '') + ':' + x['metric']['alertstate'] for x in r))
except Exception:
    print('?')"
}

app_probe() {  # "CODIGO tiempo_s"
  curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 8 "${APP_URL}/api/v4/system/ping" 2>/dev/null || echo "000 8.0"
}

cmd_preflight() {
  local bad=0
  echo "== Revisión previa del GameDay ($(date -u +%H:%M:%S) UTC) =="

  if ident=$(aws sts get-caller-identity --region "$REGION" --query '[Account,Arn]' --output text 2>&1); then
    ok "AWS CLI autenticado: $ident"
  else
    fail "AWS CLI sin credenciales válidas: $ident"; bad=1
  fi

  ping_ssm=$(aws ssm describe-instance-information --region "$REGION" \
    --filters "Key=InstanceIds,Values=${INSTANCE_ID}" --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)
  if [ "$ping_ssm" = "Online" ]; then ok "Instancia ${INSTANCE_ID} Online en SSM"; else fail "Instancia ${INSTANCE_ID} no está Online en SSM (${ping_ssm:-sin respuesta})"; bad=1; fi

  targets=$(curl -s --max-time 6 "${PROM_URL}/api/v1/targets" 2>/dev/null | python3 -c "
import sys, json
try:
    t = json.load(sys.stdin)['data']['activeTargets']
    up = sum(1 for x in t if x['health'] == 'up')
    print(f'{up}/{len(t)}')
except Exception:
    print('n/d')")
  up_n=${targets%%/*}; tot_n=${targets##*/}
  if [ "$targets" != "n/d" ] && [ "$up_n" = "$tot_n" ]; then ok "Prometheus: targets UP ${targets}"; else fail "Prometheus: targets UP ${targets}"; bad=1; fi

  ps=$(pval 'probe_success{job="blackbox_http_mattermost"}')
  [ "$ps" = "1.0" ] || [ "$ps" = "1" ] && ok "probe_success = 1" || { fail "probe_success = ${ps}"; bad=1; }

  set -- $(app_probe)
  [ "$1" = "200" ] && ok "Servicio público responde HTTP 200 (${2}s)" || { fail "Servicio público responde HTTP ${1}"; bad=1; }

  al=$(alerts)
  [ -z "$al" ] && ok "Sin alertas activas" || { warn "Alertas activas: ${al} (espera con: $0 wait-nominal)"; bad=1; }

  sli=$(pval 'job:mattermost_availability:sli5m')
  [ "$sli" = "1.0" ] || [ "$sli" = "1" ] && ok "SLI de disponibilidad 5m = 1,0" || { warn "SLI de disponibilidad 5m = ${sli} (aún recuperando)"; bad=1; }

  echo
  if [ "$bad" = 0 ]; then ok "TODO LISTO para inyectar."; else warn "Hay puntos pendientes; revisa antes de inyectar."; fi
  return "$bad"
}

cmd_wait_nominal() {
  local max="${1:-600}" start=$SECONDS
  echo "Esperando estado nominal (SLI 5m = 1 y sin alertas), máximo ${max}s..."
  while [ $((SECONDS - start)) -lt "$max" ]; do
    sli=$(pval 'job:mattermost_availability:sli5m'); al=$(alerts)
    echo "$(date -u +%H:%M:%S) | SLI5m=${sli} | alertas: ${al:-ninguna}"
    if { [ "$sli" = "1.0" ] || [ "$sli" = "1" ]; } && [ -z "$al" ]; then ok "Estado nominal recuperado."; return 0; fi
    sleep 15
  done
  fail "No volvió al estado nominal en ${max}s."; return 1
}

cmd_watch() {
  local dur="${1:-300}" label="${2:-gameday}" ts file
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "$EVID_DIR"
  file="${EVID_DIR}/${label}-${ts}.log"
  {
    echo "# GameDay — registro de línea de tiempo (${label})"
    echo "# Inicio: $(date -u +%Y-%m-%dT%H:%M:%SZ) · Duración: ${dur}s · Prometheus: ${PROM_URL} · App: ${APP_URL}"
    echo "# hora_UTC | probe_success | latencia_1m(s) | HTTP app | t_app(s) | SLI_5m | error_budget_% | alertas"
  } | tee "$file"
  local start=$SECONDS
  while [ $((SECONDS - start)) -lt "$dur" ]; do
    set -- $(app_probe)
    line="$(date -u +%H:%M:%S) | $(pval 'probe_success{job="blackbox_http_mattermost"}') | $(pval 'job:mattermost_latency_avg:seconds1m') | $1 | $2 | $(pval 'job:mattermost_availability:sli5m') | $(pval 'job:mattermost_error_budget_remaining:percent') | $(alerts)"
    echo "$line" | tee -a "$file"
    sleep 5
  done
  echo "Registro guardado en: ${file}"
}

cmd_loki() {
  local ini="${1:-}" fin="${2:-}"
  [ -z "$ini" ] || [ -z "$fin" ] && { echo "Uso: $0 loki INICIO_UTC FIN_UTC (ISO, p. ej. 2026-11-06T20:24:40Z)"; return 1; }
  local params; params="$(mktemp)"
  INI="$ini" FIN="$fin" python3 - "$params" <<'PY'
import json, os, sys, datetime
def ns(s):
    return int(datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()) * 10**9
rx = "%28Server%20is%20listening%7CStarting%20Server%7CStopping%20Server%7Cshutdown%7CReceived%20signal%7Cpanic%7Cfailed%20to%20connect%7CError%29"
url = ("http://loki:3100/loki/api/v1/query_range?limit=300&direction=forward&start=%d&end=%d"
       "&query=%%7Bjob%%3D%%22mattermost%%22%%7D%%20%%7C~%%20%%22%s%%22") % (ns(os.environ["INI"]), ns(os.environ["FIN"]), rx)
py = ("import sys,json,datetime\n"
      "d=json.load(sys.stdin)\n"
      "rows=sorted((int(t),l) for s in d['data']['result'] for t,l in s['values'])\n"
      "print('lineas:',len(rows))\n"
      "for t,l in rows[:40]:\n"
      "  try:\n"
      "    j=json.loads(l); m=j.get('msg') or l; lv=j.get('level','')\n"
      "  except Exception:\n"
      "    m=l; lv=''\n"
      "  print(datetime.datetime.utcfromtimestamp(t/1e9).strftime('%H:%M:%S'),lv,str(m)[:160])\n")
cmd = "docker exec mattermost-prometheus wget -qO- '%s' | python3 -c \"%s\"" % (url, py.replace('"', '\\"'))
json.dump({"commands": [cmd]}, open(sys.argv[1], "w"))
PY
  local cid
  cid=$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE_ID" --document-name AWS-RunShellScript \
        --comment "GameDay: consulta de logs Loki (lectura)" --parameters "file://${params}" --query Command.CommandId --output text)
  rm -f "$params"
  for _ in $(seq 1 20); do
    sleep 3
    st=$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$INSTANCE_ID" --query Status --output text 2>/dev/null)
    case "$st" in Success|Failed|TimedOut|Cancelled) break;; esac
  done
  echo "== Logs de Mattermost en Loki (${ini} → ${fin}) [SSM: ${st}] =="
  aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$INSTANCE_ID" \
    --query '[StandardOutputContent,StandardErrorContent]' --output text
}

case "${1:-}" in
  preflight)    cmd_preflight ;;
  wait-nominal) shift; cmd_wait_nominal "${1:-600}" ;;
  watch)        shift; cmd_watch "${1:-300}" "${2:-gameday}" ;;
  loki)         shift; cmd_loki "${1:-}" "${2:-}" ;;
  *) sed -n '2,16p' "$0"; exit 1 ;;
esac
