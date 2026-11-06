# Evidencias para el Entregable #4

Guía de las capturas y datos que deben acompañar el informe y la sustentación. Las mediciones provienen de ejecuciones reales del 6 de noviembre de 2026. **Las capturas de pantalla las debe tomar el equipo** siguiendo esta guía; aquí quedan los datos verificados, las URL y los momentos exactos para reproducir cada evidencia.

---

## 1. Evidencias del pipeline (CI/CD)

### 1.1 Las cinco etapas en verde
- **Dónde:** GitHub → repositorio → pestaña **Actions** → workflow *"Continuous Integration & Artifact Delivery"*.
- **Ejecución recomendada:** la del merge del PR #8, **todas las etapas exitosas**: <https://github.com/sespinosab/mattermost/actions/runs/42292070793>
- **Captura 1:** vista del *run* con los 5 jobs en verde (Lint → Build → Scan → Publish → Deploy).
- **Duraciones medidas (para la diapositiva):**

  | Etapa | Tiempo |
  |---|---|
  | 1. Lint & Static Code Analysis | 23 s |
  | 2. Build Container Image | 323 s |
  | 3. Vulnerability Security Scan | 35 s |
  | 4. Publish Container Artifact | 68 s |
  | 5. Deploy to AWS EC2 | 17 s |
  | **Total** | **≈ 479 s (8 min)** |

### 1.2 Evidencia de que el despliegue actualizó el servicio
- **Historial de despliegues por SSM** (verificado): el despliegue del commit `4f8a1b2` se ejecutó con éxito a las **2026-11-06 16:00 (hora local, 21:00 UTC)**. Lista completa reproducible con:
  ```bash
  aws ssm list-commands --instance-id i-0931fe9de23859d52 \
    --query 'Commands[?contains(Comment,`Deploy`)].{UTC:RequestedDateTime,Estado:Status,Comentario:Comment}' --output table
  ```
- **Imágenes publicadas en GHCR:** tags `sha-<commit>` en `ghcr.io/sespinosab/mattermost`.
- **Captura 2:** el log del job *"5. Deploy to AWS EC2"* mostrando el comando SSM y su salida `Success`.

> **Hallazgo verificado y corregido:** el contenedor en ejecución usaba la imagen `ghcr.io/sespinosab/mattermost:sha-30da133` (iniciado a las 18:42 UTC), **anterior** al commit `4f8a1b2` cuyo despliegue marcó `Success` a las 21:00 UTC; es decir, los despliegues reportaban éxito pero no actualizaban la aplicación.
> **Causa:** `scripts/deploy.sh` cargaba el `.env` existente en la EC2 con `source .env` *después* de recibir del pipeline la variable `MATTERMOST_IMAGE` nueva, y la sobrescribía con la imagen antigua guardada en ese `.env`; luego regeneraba el `.env` con el valor viejo.
> **Corrección (PR de esta rama):** el `.env` ahora solo aporta valores por defecto; las variables ya presentes en el entorno (la imagen nueva del pipeline) tienen prioridad. Se probó en local con variables de entorno y con caracteres especiales en la contraseña. **La verificación definitiva ocurre en el primer despliegue tras el merge:** debe verse `imagen=…:sha-<commit nuevo>` en `docker inspect mattermost-app`, y esa actualización recrea el contenedor (ventana breve de reinicio, no medida).

### 1.3 Cambio menor para la demo de despliegue continuo (por definir)
El enunciado pide ejecutar en vivo un cambio menor (config, variable o versión) y evidenciar la actualización sin pérdida de disponibilidad. Opciones (a elegir por el equipo):
- **Cambio en `observability/`** (p. ej. un umbral de alerta o un título de panel) desplegado con el workflow *Deploy Monitoring Stack* (≈ 1 min) más recarga de Prometheus. No recrea la aplicación.
- **Cambio de variable/versión** en la app vía PR → merge → pipeline. Más representativo, pero el pipeline tarda ≈ 8 min y `up -d` recrea el contenedor (ventana breve de reinicio).
- En cualquier caso, mostrar: el commit/PR, el *run* del pipeline y la verificación posterior (`curl … /api/v4/system/ping` → 200, o el cambio reflejado en Grafana/Prometheus).

---

## 2. Evidencias de observabilidad (antes · durante · después)

- **Grafana:** <http://3.217.54.83:3000> → dashboard **"Mattermost SRE — Golden Signals & SLOs"** (`/d/mattermost-sre-overview`).
- **Alertas de Prometheus:** <http://3.217.54.83:9090/alerts>
- **Logs de Loki:** Grafana → **Explore** → fuente **Loki** → consulta `{job="mattermost"}`.

Para cada escenario, capturar los tres momentos: **antes** (verde), **durante** (degradado/caído con la alerta en `firing`) y **después** (recuperado).

### 2.1 Escenario F — Degradación de latencia
- **Comando:** `./observability/scripts/gameday_inject_aws.sh latency i-0931fe9de23859d52 us-east-1 400 180`
- **Qué capturar:**
  - *Antes:* panel de latencia en el rango nominal (≈ 1,7 ms) y sin alertas.
  - *Durante:* panel de latencia sobre 250 ms (en el ensayo llegó a ≈ 800 ms), **`probe_success` seguía en 1** (el servicio no cae), y en `/alerts` `MattermostLatencySLODegraded` en `pending` (≈ 40 s) y luego `firing` (≈ 70 s).
  - *Después:* latencia de vuelta a su rango y alerta en `inactive` (≈ 1 min tras expirar la inyección).
- **Línea de tiempo medida (UTC, ensayo del 6 nov):** 20:32:05 inyección → 20:32:44 `pending` → 20:33:13 `firing` → 20:35:06 `netem` auto-eliminado → 20:36:08 alerta resuelta.

### 2.2 Escenario A — Caída del servicio con auto-recuperación
- **Comando:** `./observability/scripts/gameday_inject_aws.sh service-down i-0931fe9de23859d52 us-east-1 10`
- **Qué capturar:**
  - *Antes:* panel "Estado del Servicio" en UP, SLI y Error Budget al 100 %.
  - *Durante:* "Estado del Servicio" en DOWN, SLI y Error Budget cayendo, y en `/alerts` `MattermostServiceDown` en `firing`.
  - *Después:* servicio en UP sin intervención manual (recuperado por Docker).
- **Línea de tiempo medida (UTC, ensayo 2):** 20:24:42 inyección → 20:24:56 `probe_success=0` → 20:26:01 `ServiceDown` en `firing` (≈ 70 s) → 20:26:32 Docker recupera el contenedor → 20:26:53 alerta resuelta. Caída total ≈ 1 min 40 s.
- **Evidencia de logs (Loki):** durante la ventana del escenario, los registros de la aplicación muestran `Starting Server...` y `Server is listening on [::]:8065` a las **20:26:33 UTC**, el instante del reinicio automático. Correlaciona el reinicio del contenedor con la recuperación de la métrica.

### 2.3 Recuperación del Error Budget (opcional pero contundente)
Tras el Escenario A, el SLI de 5 min y el saldo de Error Budget vuelven progresivamente a 100 % en ≈ 5 min. Una captura de esa recuperación en Grafana ilustra la ventana de la métrica.

---

## 3. Arquitectura

Diagramas en [ARQUITECTURA.md](ARQUITECTURA.md) (Mermaid, se renderizan en GitHub): vista de infraestructura AWS, flujo de CI/CD y flujo de observabilidad, más un inventario de componentes. Para el informe se pueden exportar como imagen (abrir el `.md` en GitHub y capturar, o renderizar el bloque Mermaid).

---

## 4. Runbook

- **Ubicación en el repositorio:** [`observability/runbooks/incident-response-runbook.md`](../observability/runbooks/incident-response-runbook.md) (confirmado presente).
- **Contenido:** matriz de severidad P1/P2/P3, triaje de 3 minutos, procedimientos por incidente (servicio caído, BD, latencia, saturación), verificación de restablecimiento y sección de simulación (local y **GameDay en AWS**, §5.2).
- **Captura sugerida:** la matriz de severidad y la tabla del GameDay AWS.

---

## 5. Checklist de evidencias para el PDF

- [ ] Captura del pipeline con las 5 etapas en verde (run 42292070793).
- [ ] Captura del log del job de despliegue (SSM `Success`) + verificación del servicio.
- [ ] Decidir y preparar el cambio menor de la demo; resolver la discrepancia de imagen (§1.2).
- [ ] Grafana Escenario F: antes / durante / después.
- [ ] Grafana Escenario A: antes / durante / después.
- [ ] `/alerts` de Prometheus con alertas en `firing` durante cada escenario.
- [ ] Logs de Loki correlacionando el reinicio (Escenario A) y el estado durante F.
- [ ] Diagramas de arquitectura (exportados de ARQUITECTURA.md).
- [ ] Matriz del Runbook.
