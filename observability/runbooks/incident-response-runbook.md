# Runbook Operativo de Respuesta a Incidentes SRE — Mattermost (AWS)

**Servicio:** Plataforma Mattermost en Producción (AWS EC2 / Amazon Linux)
**Objetivo de Confiabilidad (SLO):** Disponibilidad $\ge 99.9\%$ | Latencia $P_{95} \le 250\text{ ms}$

### Enlaces de Observabilidad y Producción
- **Mattermost App:** [http://3.217.54.83:8065/signup_user_complete](http://3.217.54.83:8065/signup_user_complete)
- **Grafana Dashboard:** [http://3.217.54.83:3000/](http://3.217.54.83:3000/)
- **Prometheus Alertas:** [http://3.217.54.83:9090/alerts?search=](http://3.217.54.83:9090/alerts?search=)

---

## 1. Triage Inicial Rápido (Primeros 2 Minutos)

1. **Confirmar Impacto en Dashboards:**
   - **Grafana ([http://3.217.54.83:3000/](http://3.217.54.83:3000/)):** Revisar paneles *"Estado del Servicio"*, *"Saldo Restante de Error Budget"* y *"Latencia P95 / Promedio"*.
   - **Prometheus ([http://3.217.54.83:9090/alerts?search=](http://3.217.54.83:9090/alerts?search=)):** Validar si existen alertas en `PENDING` o `FIRING`.

2. **Verificar Salud Externa del Servicio:**
   ```bash
   curl -i -s -m 5 http://3.217.54.83:8065/signup_user_complete || echo "ALERTA: MATTERMOST NO RESPONDE"
   ```

3. **Verificar Contenedores en la Instancia EC2 (Amazon Linux):**
   ```bash
   sudo docker ps --filter "name=mattermost" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
   ```

4. **Consultas Rápidas en Loki (Grafana > Explore):**
   - **Logs con traza a Tempo:** `{container_name="mattermost-app"} |= "trace_id="`
   - **Errores generales:** `{container_name="mattermost-app"} |~ "(?i)error|fatal|panic|failed"`
   - **Login fallido (401):** `{container_name="mattermost-app"} |= "/api/v4/users/login" |= "401"`
   - **Eventos 404:** `{container_name="mattermost-app"} |= "not found handler triggered"`

---

## 2. Procedimientos de Incidentes y Pruebas GameDay (AWS SSM)

### Escenario 1: `MattermostServiceDown` (Caída del Servicio y Auto-Recuperación)
**Síntoma:** El servicio no responde HTTP (`probe_success == 0`), el SLI y el Error Budget caen, y la alerta `MattermostServiceDown` pasa a `FIRING` (~75s).

#### 1. Inyección de la Falla (Desde terminal con AWS CLI vía SSM):
```bash
./observability/scripts/gameday_inject_aws.sh service-down <INSTANCE_ID> us-east-1 10
```
*Ejecuta en la EC2 un bucle con 10 `kill -9` al PID principal de `mattermost-app` (provocando crash-loop con backoff exponencial en Docker).*

#### 2. Diagnóstico en Amazon Linux (EC2):
```bash
sudo docker inspect mattermost-app --format 'Estado: {{.State.Status}} | Restarting: {{.State.Restarting}} | ExitCode: {{.State.ExitCode}}'
sudo docker logs --tail 50 mattermost-app
```

#### 3. Recuperación / Remediación:
- **Recuperación Automática (Self-Healing):** No requiere intervención manual. Al finalizar el crash-loop, la política `--restart unless-stopped` de Docker levanta y estabiliza el contenedor automáticamente.
- **Contingencia Manual en Amazon Linux (solo si el contenedor quedara detenido):**
  ```bash
  cd /opt/mattermost && sudo docker-compose up -d
  ```

---

### Escenario 2: `MattermostLatencySLODegraded` (Degradación de Latencia y Remediación SRE)
**Síntoma:** El servicio sigue arriba (`probe_success == 1`), pero la latencia sube a $> 400\text{ ms}$ violando el SLO ($\le 250\text{ ms}$). La alerta `MattermostLatencySLODegraded` entra en `FIRING`. **La falla es persistente hasta que el SRE intervenga.**

#### 1. Inyección de la Falla (Desde terminal con AWS CLI vía SSM):
```bash
./observability/scripts/gameday_inject_aws.sh latency <INSTANCE_ID> us-east-1 400
```
*Inyecta una regla persistente `tc netem delay 400ms` en la interfaz `eth0` del namespace de red de `mattermost-app`.*

#### 2. Diagnóstico de Latencia:
- **Desde tu máquina local (consultando la métrica en Prometheus):**
  ```bash
  curl -s "http://3.217.54.83:9090/api/v1/query?query=probe_duration_seconds%7Bjob%3D%22blackbox_http_mattermost%22%7D"
  ```
  *(Devuelve el valor actual, ej. `"0.0018"` en estado normal o `"0.402"` durante la prueba de latencia).*

- **O directamente dentro de la instancia EC2 (Amazon Linux):**
  ```bash
  # 1. Medir tiempo de respuesta con la sonda Blackbox local
  curl -s "http://localhost:9115/probe?target=http://mattermost-app:8065/api/v4/system/ping&module=http_mattermost_ping" | grep probe_duration_seconds

  # 2. Inspeccionar la regla de red activa en el contenedor
  sudo nsenter -t $(sudo docker inspect -f '{{.State.Pid}}' mattermost-app) -n tc qdisc show dev eth0
  ```

#### 3. Remediación Manual SRE (Paso a Paso para Solucionar el Incidente):
- **Opción A — Dentro de la instancia EC2 (Amazon Linux):**
  ```bash
  sudo nsenter -t $(sudo docker inspect -f '{{.State.Pid}}' mattermost-app) -n tc qdisc del dev eth0 root
  ```
- **Opción B — Remota vía Script SSM:**
  ```bash
  ./observability/scripts/gameday_inject_aws.sh latency-fix <INSTANCE_ID> us-east-1
  ```
- **Confirmar que la regla fue eliminada:**
  ```bash
  sudo nsenter -t $(sudo docker inspect -f '{{.State.Pid}}' mattermost-app) -n tc qdisc show dev eth0
  ```
  *(Debe mostrar `qdisc noqueue 0: root` y la latencia en Grafana caerá de inmediato a $< 20\text{ ms}$).*

---

## 3. Verificación y Restablecimiento Post-Incidente (Amazon Linux)

1. **Validar Respuesta HTTP 200:**
   ```bash
   curl -i -s http://3.217.54.83:8065/signup_user_complete | head -n 5
   ```
2. **Confirmar Alertas Resueltas:**
   - Verificar en [http://3.217.54.83:9090/alerts?search=](http://3.217.54.83:9090/alerts?search=) que todas las alertas estén en **INACTIVE (Verde)**.
