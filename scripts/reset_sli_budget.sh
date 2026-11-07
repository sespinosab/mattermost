#!/usr/bin/env bash
set -e

echo "🔄 Restableciendo SLI acumulado y Error Budget al 100%..."

# 1. Eliminar contenedor y volumen TSDB de Prometheus
docker rm -f mattermost-prometheus 2>/dev/null || true
docker volume rm -f observability_prometheus_data 2>/dev/null || true

# 2. Levantar Prometheus limpio
cd "$(dirname "$0")/../observability"
docker compose -f docker-compose.monitoring.yml up -d prometheus

echo "✅ Listo: En 10 segundos el SLI y el Error Budget reflejarán 100% en Grafana."
