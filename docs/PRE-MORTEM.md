# Informe Pre-Mortem — Mattermost en AWS

**Curso:** Fundamentos de DevOps y SRE (2026-02) · **Equipo #2** · **Entregable #4**
**Plataforma:** Mattermost (FOSS) desplegada con Terraform + Docker Compose + GitHub Actions en AWS (`us-east-1`)
**Documentos relacionados:** [Arquitectura](ARQUITECTURA.md) · [Evidencias](EVIDENCIAS.md) · [Lecciones aprendidas](LECCIONES-APRENDIDAS.md) · [Runbook](../observability/runbooks/incident-response-runbook.md) · [Informe de SLOs (Entregable #3)](../observability/INFORME_ENTREGABLE_3.md)

---

## 1. Planteamiento del ejercicio

Un Pre-Mortem parte de una suposición: **la plataforma ya sufrió una falla catastrófica en producción** y preguntamos qué la causó, cuánto costó en términos de SLO y qué debimos tener preparado. Cada escenario se construye sobre hechos verificados en nuestra infraestructura real (sección 2), no sobre supuestos genéricos.

### 1.1 Referencia de SLOs y Error Budget (Entregable #3)

| Concepto | Valor |
|---|---|
| SLO de disponibilidad | **≥ 99,9 %** en 30 días móviles |
| Presupuesto de error | 0,1 % de 43 200 min = **43,2 min/mes = 2 592 s** |
| SLO de latencia | P95 ≤ 250 ms |
| Burn rate | `tasa de error / 0,001`. Una caída total equivale a **1 000×** |
| Umbrales de alerta | Crítico > 14,4× (agota el presupuesto en ≈ 2 días) · Advertencia > 6× |
| Tiempo para agotar el presupuesto con caída total | 43,2 min (30 días / 1 000) |

**Política de Error Budget** (saldo → acción): 100–50 % verde, despliegues libres · 50–20 % amarillo, despliegues con aprobación · 20–1 % naranja, congelamiento de funcionalidades no esenciales · ≤ 0 % rojo, *feature freeze* total hasta recuperar confiabilidad.

> **Cómo se calculan los porcentajes de este documento:** `% del presupuesto mensual = minutos de caída total / 43,2`. Los tiempos marcados como *estimado* son hipótesis de planificación del Pre-Mortem, **no mediciones**. Los marcados como *medido* provienen de los ensayos reales de GameDay (ver [EVIDENCIAS](EVIDENCIAS.md)).

---

## 2. Hechos verificados que sustentan los escenarios

Estos hallazgos salieron de revisar la infraestructura real el 6 de noviembre de 2026 y son la base de los escenarios:

| # | Hecho | Cómo se verificó |
|---|---|---|
| H1 | La instancia **standby** (`i-0cd0e9a5102f54281`) nunca llegó a ser funcional: no tiene Docker ni Mattermost. El `user_data` de Terraform falló en el primer arranque porque `dnf install … curl` choca con `curl-minimal` en Amazon Linux 2023 y el script usa `set -e`. | `cloud-init status` y `/var/log/cloud-init-output.log` de la standby |
| H2 | El Lambda de failover llamaba a SSM con `TimeoutSeconds=15` (mínimo permitido: 30), por lo que su chequeo de salud **siempre devolvía "no saludable"**. Lo corregimos a 30. | Logs de CloudWatch del Lambda (15 avisos en 5 min antes del arreglo, 0 después) |
| H3 | El failover decide con **un solo chequeo fallido** (cada 1 min), sin contador de fallos consecutivos. | Lectura de `terraform/modules/failover/lambda/failover.py` |
| H4 | Mattermost, Prometheus, Grafana, Loki y todos los exporters corren en **una sola EC2** (sin balanceador). | `docker ps` por SSM |
| H5 | La base de datos es **RDS PostgreSQL 16 Single-AZ** (`mattermost-postgres`, `db.t3.micro`, 20 GB, cifrada), con **1 día** de retención de backups y **sin protección contra borrado**. | `aws rds describe-db-instances` |
| H6 | El código de Terraform despliega un contenedor `mattermost` con `docker run`, pero el CI/CD despliega `mattermost-app` con Compose: **dos mecanismos distintos** para el mismo servicio. | Código de Terraform vs `docker ps` real |
| H7 | La política `restart: unless-stopped` recupera crashes del proceso, pero **no** paradas manuales (`docker stop`/`docker kill`). | Ensayo A (primer intento) |
| H8 | El security group real difiere del declarado en Terraform (puertos 3000, 9090 y 8065 abiertos al público). | `aws ec2 describe-security-groups` |

---

## 3. Escenario crítico 1 — Pérdida de la instancia primaria sin failover efectivo

### 3.1 Modelado

- **Disparador hipotético:** la EC2 primaria falla (fallo de hardware subyacente, fallo del chequeo de estado de la instancia, o disco/volumen corrupto) o se reemplaza durante un `terraform apply`.
- **Alcance:** toda la plataforma. En la misma instancia viven la aplicación **y** la pila de observabilidad, así que se pierde el servicio y también la visibilidad (Grafana, Prometheus, Loki).
- **Estado catastrófico:** la aplicación no responde y no hay réplica sana que tome el tráfico; la recuperación depende de una persona.
- **Evidencia de comportamiento real:** en el GameDay (Escenario A) una caída del proceso de ≈ 1 min 40 s fue detectada en ≈ 70 s y recuperada sola por Docker. Eso cubre fallos del *proceso*, **no** la pérdida de la *instancia*.

### 3.2 Análisis de causa raíz — 5 Porqués

| Por qué | Respuesta |
|---|---|
| **1. ¿Por qué el servicio estuvo caído tanto tiempo?** | Porque al fallar la primaria no existía una réplica sana que atendiera el tráfico y hubo que recuperar manualmente. |
| **2. ¿Por qué no había una réplica sana?** | Porque la standby nunca llegó a ejecutar Mattermost: su arranque falló y quedó encendida pero sin la aplicación (H1). |
| **3. ¿Por qué falló el arranque y nadie lo notó?** | Porque el `user_data` instala `curl`, que entra en conflicto con `curl-minimal` en Amazon Linux 2023; con `set -e` el script abortó. La alerta del Lambda era silenciosa: su chequeo estaba roto (H2) y devolvía "no saludable" para ambas instancias, de modo que el failover nunca se completaba pero tampoco generaba una alarma visible. |
| **4. ¿Por qué el defecto pasó desapercibido?** | Porque nunca se ejecutó un ensayo de failover de extremo a extremo y el control (Lambda) no tenía pruebas ni una alarma de "standby no saludable". Además, el despliegue real (Compose por CI/CD) diverge del que describe Terraform (H6), así que lo validado en un lado no cubría al otro. |
| **5. ¿Por qué no se detectó la divergencia entre IaC y realidad?** | Porque no hay detección de *drift* ni pruebas de aprovisionamiento desde cero (la primaria funciona por configuración manual posterior), y los controles de confiabilidad se diseñaron como declaración de intención, no como capacidad ejercitada. |

**Causa raíz:** el mecanismo de alta disponibilidad existe en el diseño pero **no está ejercitado ni monitoreado**, y la infraestructura no es reproducible desde cero.

### 3.3 Impacto en SLIs/SLOs y Error Budget

| Variante | Duración de la caída | Tasa de error | Burn rate | % del presupuesto mensual | Estado de la política |
|---|---|---|---|---|---|
| **Medido** — caída del proceso (GameDay A) | ≈ 100 s (1,7 min) | 100 % | 1 000× | **≈ 3,9 %** | Verde |
| *Estimado* — failover funcionando (arranque de la standby + app sana) | ≈ 3 min | 100 % | 1 000× | ≈ 6,9 % | Verde |
| *Estimado* — recuperación manual de la primaria | ≈ 30 min | 100 % | 1 000× | **≈ 69 %** | Amarillo → Naranja |
| *Estimado* — reconstrucción de la instancia desde cero (con el defecto H1 sin corregir) | ≈ 60 min | 100 % | 1 000× | **≈ 139 %** (presupuesto agotado) | **Rojo: *feature freeze*** |

- **SLI de disponibilidad:** cae a 0 mientras dura el incidente y tarda ≈ 5 min adicionales en recuperarse (ventana de 5 min).
- **SLO de latencia:** no aplica durante la caída total (sin respuestas); después de la recuperación hay arranque en frío.
- **Ritmo de quema:** con caída total el presupuesto mensual se agota en **43,2 min**, muy por encima del umbral crítico (14,4×).

### 3.4 Detección

| Señal | Fuente | Tiempo medido |
|---|---|---|
| `MattermostServiceDown` (`probe_success == 0`, `for: 1m`) | Prometheus + blackbox | `firing` a los ≈ 70 s |
| `MattermostHighBurnRateCritical` (> 14,4×, `for: 2m`) | Prometheus | `pending` de inmediato, `firing` pocos minutos después |
| `mattermost-primary-status-check-failed` | CloudWatch → SNS (correo) | Alarma de estado de instancia |
| Panel "Estado del Servicio" y "Saldo de Error Budget" | Grafana | Inmediato |

**Limitación:** si la instancia primaria se pierde, también se pierden Prometheus y Grafana (viven en ella). La detección quedaría a cargo de CloudWatch/SNS. Es un trade-off de costo documentado.

### 3.5 Plan de contingencia y mitigación (vinculado al Runbook)

**Respuesta inmediata (P1, MTTA < 5 min)** — ver [Runbook §3.1](../observability/runbooks/incident-response-runbook.md):

1. Confirmar impacto: `curl -i http://<EIP>:8065/api/v4/system/ping` y estado de la instancia en EC2 (`describe-instance-status`).
2. Si la instancia está viva pero la app no: revisar `docker inspect mattermost-app` y `docker logs --tail 100 mattermost-app` por SSM; la política de reinicio actúa sola ante crashes.
3. Si la instancia está degradada o perdida: **restaurar el servicio con la standby** (tras corregirla, ver controles) o recrear la primaria; reasociar la IP elástica a la instancia sana (`aws ec2 associate-address --allocation-id <eip> --instance-id <id>`).
4. Verificar recuperación: `ping` HTTP 200, `probe_success == 1`, alertas en `inactive` y SLI de 5 min estabilizándose.
5. Registrar el consumo de presupuesto y aplicar la política de Error Budget (§1.1).

### 3.6 Controles preventivos y detectivos

| Control | Tipo | Estado |
|---|---|---|
| Corregir el `user_data` (quitar `curl`, porque AL2023 ya trae `curl-minimal`; verificar si `awscli` también viene incluido) y desplegar la standby con el **mismo Compose** que la primaria | Preventivo | Pendiente (causa raíz H1) |
| Corregir `TimeoutSeconds` del Lambda a 30 | Preventivo | **Hecho** (en el código y aplicado en AWS) |
| Contador de fallos consecutivos (p. ej. 3) antes de mover la IP, para evitar *failover* por un chequeo transitorio | Preventivo | Pendiente |
| Alarma "standby no saludable" y alarma de errores del propio Lambda | Detectivo | Pendiente |
| Ejercicio periódico de failover (GameDay) y prueba de aprovisionamiento desde cero | Detectivo | Pendiente |
| Detección de *drift* entre Terraform y AWS (`terraform plan` programado) | Detectivo | Pendiente |
| Mover la observabilidad fuera de la instancia de la app, o añadir métricas de CloudWatch como respaldo | Preventivo | Pendiente (costo) |
| Balanceador con *health checks* y dos instancias activas | Preventivo | Fuera de alcance por costo |

---

## 4. Escenario crítico 2 — Pérdida o corrupción de la base de datos RDS

### 4.1 Modelado

- **Disparador hipotético:** la instancia RDS `mattermost-postgres` falla o se elimina (error humano en `terraform apply`/`destroy`, fallo del host subyacente, corrupción o llenado del almacenamiento de 20 GB).
- **Alcance:** pérdida total de la mensajería. Mattermost depende de PostgreSQL para todo el estado (usuarios, canales, mensajes); sin BD la aplicación no puede servir.
- **Estado catastrófico:** hay que restaurar desde copia de seguridad, con el riesgo de perder los mensajes posteriores al último punto restaurable.
- **Configuración real (H5):** Single-AZ, backups de 1 día, **sin protección contra borrado**. Ventana de restauración observada: `2026-11-05 21:24 UTC → 2026-11-06 21:24 UTC`.

### 4.2 Análisis de causa raíz — 5 Porqués

| Por qué | Respuesta |
|---|---|
| **1. ¿Por qué se perdió el servicio por completo?** | Porque Mattermost no puede operar sin su base de datos y esta quedó fuera de línea sin alternativa disponible. |
| **2. ¿Por qué no había alternativa?** | Porque la BD es Single-AZ, sin réplica ni *standby* (decisión de costo explícita en el diseño). |
| **3. ¿Por qué la recuperación fue lenta y con pérdida de datos?** | Porque restaurar una instancia RDS desde copia de seguridad toma decenas de minutos, y la retención de un solo día limita los puntos de restauración y deja poco margen ante un error detectado tarde. |
| **4. ¿Por qué se pudo llegar a eliminar o corromper la BD?** | Porque `deletion_protection = false` y los cambios de infraestructura se aplican sin un paso de revisión del *plan* obligatorio en producción; además hay *drift* entre lo declarado y lo real (H8). |
| **5. ¿Por qué esos controles se omitieron?** | Porque se priorizó el costo del laboratorio (presupuesto de USD 40/mes) sobre la resiliencia de datos, sin cuantificar el costo de una restauración en términos de presupuesto de error. |

**Causa raíz:** la capa de datos es un punto único de falla y carece de protecciones básicas contra pérdida (Multi-AZ, protección contra borrado y retención suficiente).

### 4.3 Impacto en SLIs/SLOs y Error Budget

| Variante | Duración | Burn rate | % del presupuesto mensual | Política |
|---|---|---|---|---|
| *Estimado* — reinicio de la instancia RDS (fallo transitorio) | ≈ 5 min | 1 000× | ≈ 11,6 % | Verde |
| *Estimado* — conmutación manual a una restauración puntual (PITR) | ≈ 45 min | 1 000× | **≈ 104 %** (presupuesto agotado) | **Rojo: *feature freeze*** |
| *Estimado* — restauración desde *snapshot* con reconfiguración de la aplicación | ≈ 90 min | 1 000× | **≈ 208 %** | **Rojo** |

- **RPO (pérdida de datos):** hasta el último punto restaurable (PITR típicamente a pocos minutos del momento del fallo); con retención de 1 día, un error detectado después de 24 h **no tendría punto de restauración**.
- **RTO (tiempo de recuperación):** decenas de minutos a más de una hora (estimado), muy superior al margen mensual de 43,2 min.
- **Una sola caída de este tipo puede agotar por completo el presupuesto del mes**, activando la política de congelamiento.

### 4.4 Detección

| Señal | Fuente | Tiempo esperado |
|---|---|---|
| `MattermostDatabaseDown` (`pg_up == 0`, `for: 30s`) | postgres-exporter → Prometheus | ≈ 30–40 s |
| `MattermostServiceDown` y burn rate crítico | blackbox → Prometheus | ≈ 70 s |
| Panel "PostgreSQL: Conexiones activas vs límite" y "Estado de PostgreSQL" | Grafana (cAdvisor + exporter) | Inmediato |
| Logs de error de conexión a la BD | Loki (`{job="mattermost"}`) | Inmediato |
| Eventos y estado de RDS | Consola/CLI de RDS | Inmediato |

### 4.5 Plan de contingencia y mitigación (vinculado al Runbook)

> El Runbook §3.2 está escrito para un PostgreSQL en contenedor local. En AWS la BD es RDS gestionada; los pasos equivalentes están en la nueva sección **§3.2-AWS** del [Runbook](../observability/runbooks/incident-response-runbook.md).

1. Confirmar el estado de la BD: `aws rds describe-db-instances --db-instance-identifier mattermost-postgres --query 'DBInstances[0].DBInstanceStatus'` y revisar los eventos recientes (`describe-events`).
2. Si es un fallo transitorio: `aws rds reboot-db-instance --db-instance-identifier mattermost-postgres`. Mattermost reconecta solo cuando la BD vuelve.
3. Si la instancia se perdió: restaurar a un punto en el tiempo (`restore-db-instance-to-point-in-time` hacia una instancia nueva con el mismo grupo de subredes y *security group*), actualizar `DB_HOST` en las variables del *environment* de GitHub y redeplegar la aplicación.
4. Verificar conectividad desde la EC2 (`pg_isready`/conexión de prueba), `pg_up == 1` y `probe_success == 1`.
5. Registrar el consumo de presupuesto y aplicar la política (congelamiento de despliegues si queda ≤ 0 %).

### 4.6 Controles preventivos y detectivos

| Control | Tipo | Estado |
|---|---|---|
| Activar **protección contra borrado** (`deletion_protection = true`) | Preventivo | Pendiente |
| Aumentar la retención de backups a ≥ 7 días y tomar *snapshot* manual antes de cambios de infraestructura | Preventivo | Pendiente |
| Evaluar **Multi-AZ** para eliminar el punto único de falla (trade-off de costo) | Preventivo | Pendiente (costo) |
| Revisión obligatoria del `terraform plan` antes de aplicar en producción | Preventivo | Parcial (plan solo en una rama) |
| Alarma de CloudWatch sobre almacenamiento libre y conexiones de RDS | Detectivo | Pendiente |
| Ensayo periódico de restauración (PITR) y medición real del RTO | Detectivo | Pendiente |
| Alerta `pg_up == 0` a 30 s con enlace al runbook | Detectivo | **Hecho** |

---

## 5. Comparación de escenarios y priorización

| Criterio | Escenario 1: pérdida de la EC2 primaria | Escenario 2: pérdida de RDS |
|---|---|---|
| Probabilidad (juicio del equipo) | Media | Baja |
| Impacto en el presupuesto de error | 7 % a 139 % según la recuperación | 12 % a 208 % |
| Pérdida de datos | No (la BD es externa) | Posible (RPO) |
| Mitigación de menor costo/mayor retorno | Corregir `user_data` y ensayar el failover | Protección contra borrado + retención de backups |
| Brecha principal | Control de HA no ejercitado | Punto único de falla en datos |

**Prioridad recomendada:** (1) protección contra borrado y retención de backups de RDS (bajo costo, alto efecto), (2) corregir y ensayar la standby, (3) detección de *drift* y alarmas del Lambda, (4) valorar Multi-AZ según presupuesto.

## 6. Trade-offs de arquitectura que sustentamos

| Decisión | Beneficio | Costo en confiabilidad |
|---|---|---|
| RDS Single-AZ | Menor costo | Punto único de falla; RTO alto |
| Sin balanceador ni NAT | Ahorro mensual | Sin failover transparente; la IP elástica se reasocia a mano o por Lambda |
| Todo en una EC2 (app + observabilidad) | Simplicidad y costo | La pérdida de la instancia elimina servicio y visibilidad |
| Failover con instancia standby apagada | Evita pagar dos instancias activas | Arranque en frío; depende de un Lambda que debe estar ejercitado |
| `restart: unless-stopped` | Recupera crashes del proceso en segundos (medido) | No cubre paradas manuales ni pérdida de la instancia |
| Sondas sintéticas para el SLI | Simples y baratas | No es un percentil real de usuarios |
| Observabilidad abierta (Grafana/Prometheus) para el laboratorio | Acceso rápido en la sustentación | Superficie de exposición mayor |

## 7. Lecciones y acciones de seguimiento

Las lecciones técnicas de las seis semanas están en [LECCIONES-APRENDIDAS.md](LECCIONES-APRENDIDAS.md). Las acciones de este Pre-Mortem, en orden de prioridad:

1. Activar `deletion_protection` y subir la retención de backups de RDS.
2. Corregir el `user_data`, alinear el despliegue de Terraform con el de Compose y ejercitar el failover de extremo a extremo.
3. Añadir contador de fallos consecutivos y alarmas al Lambda de failover.
4. Detectar *drift* de Terraform periódicamente y cerrar los puertos de observabilidad al público.
5. Actualizar el Runbook con los procedimientos para RDS (hecho en §3.2-AWS) y ensayarlos.
