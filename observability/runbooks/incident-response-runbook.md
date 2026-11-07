# Runbook Operativo de Respuesta a Incidentes SRE — Mattermost (AWS)

**Servicio:** Plataforma Mattermost en Producción (AWS EC2 / Amazon Linux)  
**Objetivo de Confiabilidad (SLO):** Disponibilidad $\ge 99.9\%$ | Latencia $P_{95} \le 250\text{ ms}$  

### Enlaces de Observabilidad y Servicio
- **Mattermost App:** [http://3.217.54.83:8065/signup_user_complete](http://3.217.54.83:8065/signup_user_complete)
- **Grafana Dashboard:** [http://3.217.54.83:3000/](http://3.217.54.83:3000/)
- **Prometheus Alertas:** [http://3.217.54.83:9090/alerts?search=](http://3.217.54.83:9090/alerts?search=)

---

## 1. Triage Inicial Rápido (Primeros 2 Minutos)

1. **Confirmar Impacto en Dashboards:**
   - **Grafana:** Revisar paneles *"Estado del Servicio"*, *"Saldo Restante de Error Budget"* y *"Latencia P95 / Promedio"*.
   - **Prometheus:** Validar si hay alertas en estado `PENDING` o `FIRING`.

2. **Verificar Salud del Servicio:**
   ```bash
   curl -i -s -m 5 http://3.217.54.83:8065/signup_user_complete || echo "ALERTA: MATTERMOST NO RESPONDE"
   ```

3. **Verificar Contenedor en la Instancia (Amazon Linux):**
   ```bash
   docker ps --filter "name=mattermost-app" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
   ```

---

## 2. Procedimientos de Incidentes y GameDay AWS

### Escenario 1: `MattermostServiceDown` (Caída del Servicio)
**Síntoma:** El servicio no responde HTTP (`probe_success == 0`). Alerta `MattermostServiceDown` en `FIRING`.

#### Diagnóstico:
```bash
docker inspect mattermost-app --format 'Estado: {{.State.Status}} | ExitCode: {{.State.ExitCode}}'
docker logs --tail 50 mattermost-app
```

#### Inyección GameDay (AWS SSM):
```bash
./observability/scripts/gameday_inject_aws.sh service-down <INSTANCE_ID> [REGION] 10
```
*Simula un crash-loop de 10 caídas consecutivas con `kill -9` al PID principal.*

#### Remediación y Recuperación:
- **Comportamiento esperado (Self-healing):** Al terminar el ciclo, la política `--restart unless-stopped` estabiliza y levanta el contenedor automáticamente.
- **Acción manual de contingencia (si no levanta):**
  ```bash
  cd /opt/mattermost && docker-compose up -d
  ```

---

### Escenario 2: `MattermostLatencySLODegraded` (Degradación de Latencia)
**Síntoma:** El servicio sigue activo (`probe_success == 1`), pero la latencia supera el SLO ($> 250\text{ ms}$, rondando $400\text{ ms}$).

#### Diagnóstico:
1. Verificar tiempo de respuesta con Blackbox:
   ```bash
   curl -s "http://localhost:9115/probe?target=http://mattermost-app:8065/api/v4/system/ping&module=http_mattermost_ping" | grep probe_duration_seconds
   ```
2. Inspeccionar si hay reglas de retardo de red en el contenedor:
   ```bash
   PID=$(docker inspect -f '{{.State.Pid}}' mattermost-app)
   sudo nsenter -t $PID -n tc qdisc show dev eth0
   ```

#### Inyección GameDay (AWS SSM):
```bash
./observability/scripts/gameday_inject_aws.sh latency <INSTANCE_ID> [REGION] 400
```
*Inyecta 400 ms de latencia artificial persistente en la interfaz `eth0` del contenedor.*

#### Remediación SRE (Eliminación de la degradación):
- **Vía script SRE (Remoto por SSM):**
  ```bash
  ./observability/scripts/gameday_inject_aws.sh latency-fix <INSTANCE_ID> [REGION]
  ```
- **Vía directa en la EC2 (Amazon Linux):**
  ```bash
  PID=$(docker inspect -f '{{.State.Pid}}' mattermost-app)
  sudo nsenter -t $PID -n tc qdisc del dev eth0 root
  ```
*La latencia vuelve inmediatamente a < 20 ms y la alerta se resuelve.*

---

## 3. Verificación y Restablecimiento Post-Incidente

1. **Validar Respuesta HTTP 200:**
   ```bash
   curl -i http://3.217.54.83:8065/signup_user_complete
   ```
2. **Confirmar Alertas Inactivas:**
   - Verificar en [http://3.217.54.83:9090/alerts?search=](http://3.217.54.83:9090/alerts?search=) que no existan alertas en `FIRING`.
3. **Restablecer SLI y Error Budget al 100% (para la presentación):**
   ```bash
   ./scripts/reset_sli_budget.sh
   ```
   *(Limpia métricas históricas de fallo y deja el saldo y disponibilidad en 100% en Grafana en 10s).*
