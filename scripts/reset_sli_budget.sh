#!/usr/bin/env bash
set -e

echo "🔄 Restableciendo SLI acumulado y Error Budget al 100%..."

# Detectar automáticamente docker compose (v2) o docker-compose (v1 en Amazon Linux)
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  echo "❌ Error: No se encontró 'docker compose' ni 'docker-compose'."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../observability"

# Cargar variables de entorno de la raíz si existen (evita warnings en Amazon Linux)
if [ -f "../.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "../.env"
  set +a
fi

# 1. Eliminar contenedor de Prometheus
docker rm -f mattermost-prometheus >/dev/null 2>&1 || true

# 2. Eliminar volumen TSDB de Prometheus (sea observability_prometheus_data o similar)
for vol in $(docker volume ls -q | grep "prometheus_data" || true); do
  docker volume rm "$vol" >/dev/null 2>&1 || true
done

# 3. Levantar Prometheus limpio
$COMPOSE_CMD -f docker-compose.monitoring.yml up -d prometheus

echo "✅ Listo: En 10 segundos el SLI y el Error Budget reflejarán 100% en Grafana."
