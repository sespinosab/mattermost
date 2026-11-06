# Lecciones aprendidas — CI/CD, IaC y SRE

Análisis de los principales desafíos técnicos del proyecto y de cómo se resolvieron. Cada lección indica su **evidencia** (commit, log o medición) para que pueda verificarse.

> **Alcance honesto de este documento:** la evidencia del historial de Git cubre con detalle la observabilidad y los SLOs (1–2 nov), el pipeline de CI/CD (2–5 nov), la pila de logs/trazas (6 nov) y el GameDay (6 nov). Las primeras semanas del curso (selección de la plataforma, diseño inicial de Terraform y primeras entregas) **no dejaron trazas detalladas en el repositorio**; los integrantes deben completar la sección 5 con su experiencia directa.

---

## 1. CI/CD (GitHub Actions)

### 1.1 El despliegue automatizado a EC2 requirió muchas iteraciones
- **Problema:** conectar el pipeline con la instancia sin abrir SSH ni guardar llaves. Entre el 3 y el 5 de noviembre el historial muestra una cadena de ajustes: *"Added script and job for ec2 deploy"*, *"Added log to look for error"*, *"Chenged environment in deploy job"*, *"Added more stuff to run command in deploy job to synchronize responses between AWS and GitHub"*, *"Corrected error in duplicated deploy"* y varios *"Correction for monitoring pipeline"*.
- **Causa:** el despliegue por SSM Run Command pasa variables sensibles a un script remoto; requiere escapado seguro, esperar el resultado del comando y que el *environment* de GitHub tenga todas las variables.
- **Solución:** autenticación con **OIDC** hacia un rol de AWS (sin claves almacenadas), `scripts/deploy.sh` ejecutado por SSM con variables entrecomilladas (`printf %q`), validación de variables obligatorias (`: "${VAR:?}"`) y espera activa del estado del comando.
- **Lección:** automatizar contra un host remoto sin SSH es viable y más seguro, pero cada paso (permisos, variables, citado de comillas, espera de resultados) debe validarse con logs explícitos; conviene exigir variables obligatorias con error claro.

### 1.2 El tiempo del pipeline lo domina el *build*
- **Evidencia (ejecución del 6 nov):** lint 23 s · build **323 s** · escaneo 35 s · publicación 68 s · despliegue 17 s · total **479 s (≈ 8 min)**.
- **Lección:** el build de la imagen representa dos tercios del tiempo. Separar los cambios de configuración u observabilidad de los de código, o reutilizar mejor la caché, acortaría el ciclo de retroalimentación.

### 1.3 Validar Compose en CI exige variables simuladas
- **Problema:** `docker compose config` falla si faltan variables.
- **Solución:** el commit *"Added mocked env to validate docker compose configuration step in job lint"* define valores ficticios solo para la validación.
- **Lección:** los *linters* de infraestructura necesitan un entorno de prueba determinista, sin secretos reales.

### 1.4 Escaneo de vulnerabilidades no bloqueante
- **Decisión:** Trivy revisa severidades CRITICAL y HIGH con `ignore-unfixed` y `exit-code: 0` (informa, no bloquea).
- **Lección y trade-off:** evita bloquear el despliegue por vulnerabilidades sin parche, pero reduce la fuerza del control; en producción se bloquearía al menos por CRITICAL con parche disponible.

---

## 2. Infraestructura como código (Terraform)

### 2.1 El `user_data` no era reproducible desde cero
- **Problema:** la instancia *standby* nunca llegó a ejecutar Mattermost.
- **Evidencia:** `cloud-init-output.log` de la standby muestra que `dnf install -y docker awscli curl` falla por el conflicto entre `curl` y `curl-minimal` en Amazon Linux 2023; con `set -euo pipefail` el script abortó.
- **Lección:** los paquetes y sus conflictos dependen de la imagen base; un script de arranque debe probarse en una instancia limpia. Sin pruebas de aprovisionamiento desde cero, la IaC solo "parece" reproducible.

### 2.2 Divergencia entre IaC y el despliegue real
- **Problema:** Terraform arranca un contenedor `mattermost` con `docker run`; el CI/CD despliega `mattermost-app` con Docker Compose. Son dos mecanismos para el mismo servicio.
- **Impacto:** nombres de contenedor, red y almacenamiento (S3 vs. volumen local) difieren, y los scripts que asumían uno fallaban en el otro. Nos obligó a verificar contra la instancia real antes de asumir.
- **Lección:** una sola fuente de verdad para el despliegue de la aplicación; ante la duda, inspeccionar el entorno real (`docker ps`, `docker inspect`).

### 2.3 *Drift* en el security group y dos cuentas de AWS
- **Hallazgo:** el SG real tiene puertos abiertos (3000, 9090, 8065) que Terraform no declara, y los workflows referencian roles de dos cuentas distintas.
- **Lección:** los cambios manuales generan deriva; se necesita `terraform plan` periódico y una convención clara de cuenta/entorno. También condicionó cómo corregimos el Lambda (actualización directa del código en lugar de `terraform apply`, para no revertir configuración manual ni tocar un estado remoto sin acceso completo).

### 2.4 Decisiones de costo con impacto en confiabilidad
- RDS Single-AZ, sin balanceador ni NAT, una sola EC2 para app y observabilidad, presupuesto de USD 40/mes.
- **Lección:** cada ahorro tiene un costo medible en presupuesto de error; el Pre-Mortem cuantifica esos trade-offs.

---

## 3. SRE y observabilidad

### 3.1 Definir SLIs medibles y un presupuesto de error útil
- Disponibilidad ≥ 99,9 % (43,2 min/mes) y latencia ≤ 250 ms, con alertas de *burn rate* a 14,4× y 6×. El historial muestra la revisión del SLO el 1–2 de noviembre (*"Actualizar SLOs y métricas de disponibilidad a 99.9%"*).
- **Lección:** una caída total quema el presupuesto a 1 000×; con 99,9 % solo caben ≈ 43 min de indisponibilidad mensual, por lo que la automatización de la recuperación importa más que la respuesta humana.

### 3.2 La ventana de la regla condiciona el tiempo de detección
- **Problema:** la alerta de latencia usaba promedio de 5 min con `for: 3m`; tardaba ≈ 5–6 min en disparar.
- **Solución:** ventana de 1 min y `for: 30s`. En el ensayo la alerta pasó a `pending` a los ≈ 40 s y a `firing` a los ≈ 70 s.
- **Lección:** el tiempo de detección es la suma de la ventana de la métrica y la duración `for`; hay que diseñarlos juntos y aceptar que una ventana corta es más sensible a picos.

### 3.3 El SLI de latencia es sintético
- Se mide con la duración de las sondas de blackbox, no con el percentil real de usuarios, y la regla `latency_p95` recurre a `promedio × 1,25` cuando no hay histograma.
- **Lección:** declarar con honestidad qué mide cada SLI; para un P95 real habría que instrumentar la aplicación (histogramas) o medir en el balanceador.

### 3.4 Las reglas de Prometheus no se recargan solas
- Tras `git pull` y `docker-compose up -d`, Prometheus no se reinicia si su definición no cambió; hay que reiniciarlo o llamar a `/-/reload`. Además, un archivo montado individualmente puede quedar desactualizado si Git lo reemplaza.
- **Lección:** la entrega de configuración de observabilidad necesita un paso explícito de recarga y una verificación (`/rules`, `/targets`).

### 3.5 Logs y trazas estructurados
- El 6 de noviembre se incorporaron OpenTelemetry, Loki, Promtail y Tempo, con logs de Mattermost en JSON. Los logs de Loki permitieron confirmar la recuperación del Escenario A (`Starting Server…` / `Server is listening` a las 20:26:33 UTC).
- **Lección:** la correlación entre una alerta de métricas y un log con marca de tiempo acorta el diagnóstico; en una degradación de red (Escenario F) los logs de la aplicación no muestran errores, por lo que la causa se infiere de las métricas.

---

## 4. Operación y GameDay

### 4.1 `docker kill` no activa la política de reinicio
- **Evidencia:** en el primer ensayo el contenedor quedó en `Exited (137)` más de 3 minutos y hubo que restaurarlo a mano.
- **Causa:** Docker trata `docker kill`/`docker stop` como una parada **manual** y ignora `restart: unless-stopped`.
- **Solución:** simular un crash real con `kill -9` al proceso principal desde el host.
- **Lección:** validar el mecanismo de auto-recuperación antes de declararlo; una suposición razonable resultó falsa y solo el ensayo lo mostró.

### 4.2 Un solo crash es demasiado corto para observarse
- Un crash simple se recupera en ≈ 7 s y la alerta `ServiceDown` (`for: 1m`) nunca llega a `firing`.
- **Solución:** repetir el crash 10 veces; Docker duplica la espera entre reinicios cuando el contenedor muere antes de 10 s (100 ms, 200 ms, 400 ms…), produciendo una caída de ≈ 1 min 40 s y alertas visibles. La recuperación final la hace Docker sin intervención.

### 4.3 Dónde se inyecta la latencia importa
- Aplicar `netem` en la interfaz de la EC2 no habría afectado las sondas, porque llegan a la aplicación por el puente de Docker. Se inyecta dentro del *namespace* de red del contenedor (`nsenter`).
- **Resultado medido:** latencia de 1,7 ms a ≈ 800 ms; `probe_success` se mantuvo en 1 y el contenedor no se reinició.

### 4.4 Herramientas que fallan en silencio
- `aws ssm send-command --parameters 'commands=[...]'` no interpreta saltos de línea y los comandos multilínea llegaban rotos; se resolvió pasando los parámetros desde un archivo JSON.
- El parámetro `TimeoutSeconds` de SSM exige mínimo 30; con 15 el chequeo del Lambda de failover **siempre fallaba**, sin errores de ejecución visibles (0 errores en CloudWatch, pero 15 avisos en 5 min en el log).
- **Lección:** que un componente "no dé error" no prueba que funcione; hay que leer sus logs y ejercitar el comportamiento esperado.

### 4.5 Credenciales y accesos
- Un archivo de credenciales de AWS sin perfil `[default]` y un token de Git de otra cuenta en el llavero provocaron fallos del CLI y `push` con error 403. Se corrigió con perfiles correctos y usando el token de `gh` por comando.
- **Lección:** estandarizar perfiles y verificar la identidad activa (`sts get-caller-identity`, `gh auth status`) antes de operar.

---

## 5. Pendiente de completar por el equipo (semanas 1–4)

Esta sección no tiene evidencia en el repositorio y debe escribirla cada integrante con su experiencia directa:

- Selección de la plataforma FOSS y decisiones iniciales de arquitectura.
- Diseño y primeras iteraciones de Terraform (módulos, estado remoto, costos).
- Primeras configuraciones de CI y problemas con la imagen de Mattermost.
- Cualquier dificultad de coordinación entre integrantes o de acceso a la cuenta de AWS.

Para cada punto: problema → causa → solución → qué haríamos distinto.
