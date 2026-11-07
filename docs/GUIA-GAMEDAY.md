# Guía para ejecutar el GameDay y tomar las evidencias

Guía paso a paso para correr los dos escenarios de falla en AWS y capturar las evidencias del Entregable #4. No requiere conocer el proyecto: sigue los pasos en orden.

**Tiempo total:** ≈ 25 minutos (Escenario F ≈ 8 min · espera ≈ 5 min · Escenario A ≈ 8 min · logs y cierre ≈ 5 min).

> **Importante:** los escenarios se ejecutan contra el entorno de AWS real del proyecto. Son reversibles y se recuperan solos, pero **solo una persona a la vez debe inyectar fallas**. Avisa en el grupo antes de empezar y no corras dos escenarios al mismo tiempo.

---

## 1. Qué hace cada escenario

| Escenario | Ataque | Qué se espera ver | Recuperación |
|---|---|---|---|
| **F — Latencia** | Se agrega 400 ms de retraso de red dentro del contenedor `mattermost-app` durante 180 s | La latencia sube de ≈ 2 ms a ≈ 800 ms; **el servicio no se cae** (`probe_success` sigue en 1); la alerta `MattermostLatencySLODegraded` pasa a `firing` en ≈ 70 s | El retraso se elimina solo a los 180 s |
| **A — Caída del servicio** | Crash-loop: 10 veces `kill -9` al proceso de `mattermost-app` | El servicio cae (≈ 1 min 40 s); `MattermostServiceDown` pasa a `firing` en ≈ 70 s; el Error Budget baja | Docker reinicia el contenedor solo; nadie ejecuta comandos de recuperación |

Haz **primero F y después A**: F no deja residuos, mientras que A mantiene alertas activas unos 5 minutos.

---

## 2. Requisitos

| Requisito | Cómo comprobarlo |
|---|---|
| **Sistema:** macOS o Linux (scripts `.sh`) o **Windows con PowerShell** (scripts `.ps1`, ver nota abajo). | — |
| **AWS CLI v2** | `aws --version` |
| **Python 3, curl y bash** | `python3 --version` · `curl --version` |
| **Git** y acceso de lectura al repositorio `sespinosab/mattermost` | `git --version` |
| **Credenciales de AWS** de un usuario IAM de la cuenta `506305355048` con permisos de SSM (ver abajo) | `aws sts get-caller-identity` |

**Permisos de AWS necesarios** (pídeselos a quien administra la cuenta; no compartas ni pegues claves en el chat):
- `ssm:SendCommand` sobre el documento `AWS-RunShellScript` y la instancia `i-0931fe9de23859d52`
- `ssm:GetCommandInvocation`, `ssm:ListCommands` y `ssm:DescribeInstanceInformation`
- `sts:GetCallerIdentity`

**Configurar las credenciales** (una sola vez). El archivo `~/.aws/credentials` debe tener el encabezado `[default]` en la primera línea:

```ini
[default]
aws_access_key_id = <TU_CLAVE>
aws_secret_access_key = <TU_SECRETO>
```

y `~/.aws/config`:

```ini
[default]
region = us-east-1
output = json
```

También puedes ejecutar `aws configure` y responder las preguntas (región `us-east-1`, formato `json`).


> **En Windows (PowerShell):** usa las versiones `.ps1` en la misma carpeta. Sustituye en todos los comandos `./observability/scripts/gameday_watch.sh` por `.\observability\scripts\gameday_watch.ps1` y `gameday_inject_aws.sh ... latency i-... us-east-1 400 180` por `gameday_inject_aws.ps1 -Scenario latency -DelayMs 400 -DurationS 180` (y `-Scenario service-down -Crashes 10` para el otro). Requisitos: AWS CLI v2 y PowerShell 5.1+ (ya incluido en Windows 10/11). Si al ejecutar aparece un error de directiva de ejecución, abre PowerShell y corre una vez: `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`.

---

## 3. Preparación

```bash
# 1. Clonar el repositorio (si aún no lo tienes)
git clone https://github.com/sespinosab/mattermost.git
cd mattermost

# 2. Cambiar a la rama que contiene los scripts de apoyo
#    (si el PR #9 ya fue mergeado, basta con estar en master y hacer git pull)
git fetch origin
git checkout docs/entregable-4

# 3. Verificar que los scripts existen y son ejecutables
ls -l observability/scripts/gameday_inject_aws.sh observability/scripts/gameday_watch.sh
chmod +x observability/scripts/gameday_inject_aws.sh observability/scripts/gameday_watch.sh
```

**Pestañas del navegador que debes dejar abiertas** (sirven para las capturas):

| Qué | URL |
|---|---|
| Grafana, dashboard de señales doradas | <http://3.217.54.83:3000/d/mattermost-sre-overview?orgId=1&from=now-15m&to=now&refresh=5s> |
| Alertas de Prometheus | <http://3.217.54.83:9090/alerts> |
| Grafana → Explore → fuente **Loki** | consulta: `{job="mattermost"} \|~ "Starting Server\|Server is listening\|Error"` |

La contraseña de Grafana (usuario `admin`) te la da quien administra el proyecto.

---

## 4. Ejecución

Usa **dos terminales** para cada escenario: una registra la línea de tiempo y la otra inyecta la falla. Ambas desde la carpeta del repositorio.

### Paso 0 — Revisión previa (siempre antes de inyectar)

```bash
./observability/scripts/gameday_watch.sh preflight
```

Debes ver todas las líneas en `[OK]` y al final **"TODO LISTO para inyectar"**. Si alguna falla, no continúes y revisa la sección 7. Si solo aparecen alertas activas o el SLI por debajo de 1,0:

```bash
./observability/scripts/gameday_watch.sh wait-nominal
```

### Escenario F — Degradación de latencia

**Terminal 1** (registro de la línea de tiempo, 5,5 min):

```bash
./observability/scripts/gameday_watch.sh watch 330 escenario-F
```

**Terminal 2** (inyección):

```bash
./observability/scripts/gameday_inject_aws.sh latency i-0931fe9de23859d52 us-east-1 400 180
```

Debe terminar mostrando `Latencia 400ms aplicada en eth0 de mattermost-app` y una línea `qdisc netem … delay 400ms`.

**Capturas de pantalla** (en Mac: `Cmd + Shift + 4`; en Windows: `Win + Shift + S`):

| Momento | Cuándo | Qué debe verse |
|---|---|---|
| **Antes** | Antes de inyectar | Grafana en verde, latencia ≈ 2 ms, sin alertas en Prometheus |
| **Durante** | ≈ 80 s después de inyectar | Latencia por encima de 250 ms, `probe_success` en 1, `MattermostLatencySLODegraded` en `firing` |
| **Después** | ≈ 4 min después de inyectar | Latencia de vuelta a lo normal y la alerta resuelta |

### Espera entre escenarios

```bash
./observability/scripts/gameday_watch.sh wait-nominal
```

Espera a ver **"Estado nominal recuperado"** antes de seguir.

### Escenario A — Caída del servicio

**Terminal 1** (registro, 5,5 min):

```bash
./observability/scripts/gameday_watch.sh watch 330 escenario-A
```

**Terminal 2** (inyección; anota la hora UTC que imprime el registro):

```bash
./observability/scripts/gameday_inject_aws.sh service-down i-0931fe9de23859d52 us-east-1 10
```

Debe terminar con `Crash-loop lanzado en background … 10 crashes`.

**Capturas de pantalla:**

| Momento | Cuándo | Qué debe verse |
|---|---|---|
| **Antes** | Antes de inyectar | Servicio en UP, SLI y Error Budget al 100 % |
| **Durante** | ≈ 80 s después | "Estado del Servicio" en DOWN, `MattermostServiceDown` en `firing`, Error Budget cayendo |
| **Después** | ≈ 2 min después | Servicio otra vez en UP **sin que nadie lo haya tocado** |
| **Recuperación del presupuesto** | ≈ 5–7 min después | SLI y Error Budget volviendo al 100 % |

### Logs de Loki (justo después del Escenario A)

```bash
./observability/scripts/gameday_watch.sh loki 2026-11-06T<HORA_INICIO>Z 2026-11-06T<HORA_FIN>Z
```

Usa la hora UTC de inicio de la inyección y unos 3 minutos después. Debe aparecer `Starting Server...` y `Server is listening on [::]:8065` en el momento en que Docker recupera el contenedor. Haz también una captura de la misma consulta en **Grafana → Explore → Loki**, con el rango de tiempo del escenario.

---

## 5. Evidencias adicionales (sin ejecutar nada en AWS)

| Evidencia | Dónde |
|---|---|
| Pipeline con las 5 etapas en verde | <https://github.com/sespinosab/mattermost/actions/runs/42292070793> (captura del *run*) |
| Log del despliegue a EC2 | Dentro de ese *run*, abre el job **"5. Deploy to AWS EC2"** y captura su log |
| Diagramas de arquitectura | `docs/ARQUITECTURA.md` en GitHub (se renderizan solos) |
| Runbook | `observability/runbooks/incident-response-runbook.md` (captura de la matriz de severidad y de la sección 5.2) |

---

## 6. Qué entregar al terminar

1. Las **capturas** de cada momento (antes / durante / después) de ambos escenarios, nombradas por ejemplo `F-antes.png`, `F-durante.png`, `A-despues.png`…
2. Los dos archivos de línea de tiempo de la carpeta `evidencias/` (`escenario-F-….log` y `escenario-A-….log`).
3. La captura de la salida de `gameday_watch.sh loki`.
4. Un mensaje al grupo indicando la hora UTC de cada inyección y si algo se comportó distinto de lo esperado.

Los archivos de `evidencias/` no contienen secretos. No subas capturas que muestren claves de AWS o la contraseña de Grafana.

---

## 7. Si algo sale mal

| Síntoma | Qué hacer |
|---|---|
| `Unable to parse config file` o `NoCredentials` | El archivo `~/.aws/credentials` no tiene `[default]` o las claves son incorrectas (sección 2) |
| `AccessDeniedException` en `ssm:SendCommand` | Falta el permiso de SSM; pídelo (sección 2) |
| `preflight` marca la instancia fuera de SSM | Revisa la región (`us-east-1`) y que la instancia siga encendida; avisa al grupo |
| `preflight` marca targets de Prometheus caídos | Avisa al grupo antes de inyectar: el monitoreo no está sano |
| Pasaron 3 minutos del Escenario A y la app no responde | Reinicia el contenedor por SSM (ver abajo) y avisa al grupo |
| La latencia sigue alta después de 4 minutos | Elimina el retraso por SSM (ver abajo) |

**Reiniciar el contenedor** (solo si el Escenario A no se recuperó solo):

```bash
aws ssm send-command --region us-east-1 --instance-ids i-0931fe9de23859d52 \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["docker start mattermost-app"]'
```

**Eliminar el retraso de red** (solo si el Escenario F no se revirtió solo; reiniciar el contenedor también lo elimina):

```bash
aws ssm send-command --region us-east-1 --instance-ids i-0931fe9de23859d52 \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["nsenter -t $(docker inspect -f {{.State.Pid}} mattermost-app) -n tc qdisc del dev eth0 root"]'
```

> Si el retraso ya se había eliminado, este comando termina en `Failed` con el mensaje `Cannot delete qdisc with handle of zero`: es normal e inofensivo, significa que no había nada que quitar.

**Comprobar que todo quedó bien:** `./observability/scripts/gameday_watch.sh preflight` debe terminar en "TODO LISTO".

---

## 8. Reglas de seguridad

- No pegues claves de AWS ni contraseñas en el chat, en capturas ni en commits.
- No ejecutes escenarios con otra persona inyectando al mismo tiempo.
- No cambies los scripts durante la ejecución; si encuentras un error, repórtalo al grupo.
- Estos comandos son solo para el entorno del proyecto (`i-0931fe9de23859d52`, `us-east-1`).
