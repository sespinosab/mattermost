# Arquitectura de la plataforma — Mattermost en AWS

Diagramas construidos a partir de Terraform, de lo que corre realmente en la EC2 primaria (verificado por SSM el 6 de noviembre de 2026) y de los workflows de GitHub Actions. Los diagramas usan [Mermaid](https://mermaid.js.org/), que GitHub renderiza directamente.

## 1. Vista general de infraestructura (AWS `us-east-1`)

```mermaid
flowchart TB
    user([Usuarios / equipo SRE])

    subgraph aws["AWS · us-east-1"]
        eip["IP elástica 3.217.54.83"]

        subgraph vpc["VPC 10.42.0.0/16"]
            subgraph pub["Subredes públicas"]
                subgraph primary["EC2 primaria · t3.small (activa)"]
                    app["mattermost-app<br/>:8065 HTTP · :8067 métricas<br/>restart: unless-stopped"]
                    obs["Pila de observabilidad<br/>Prometheus · Grafana · blackbox<br/>node-exporter · cAdvisor · postgres-exporter<br/>Loki · Promtail · Tempo · OTel Collector"]
                end
                standby["EC2 standby · t3.small<br/>(diseñada para failover)"]
            end
            subgraph priv["Subredes privadas (10.42.11.0/24 · 10.42.12.0/24)"]
                rds[("RDS PostgreSQL 16<br/>db.t3.micro · Single-AZ · cifrada")]
            end
        end

        ssm["AWS Systems Manager<br/>(Run Command, sin SSH)"]
        lambda["Lambda failover<br/>EventBridge cada 1 min"]
        cw["CloudWatch<br/>alarmas + logs"]
        sns["SNS → correo"]
        s3[("S3 (bucket de archivos<br/>creado por Terraform)")]
        budgets["AWS Budgets<br/>USD 40/mes"]
    end

    user -->|HTTP 8065| eip --> app
    user -->|3000 Grafana · 9090 Prometheus| obs
    app -->|PostgreSQL 5432 · SSL| rds
    obs -->|postgres-exporter| rds
    lambda -->|chequeo de salud| ssm
    ssm -.-> primary
    ssm -.-> standby
    lambda -->|reasocia IP si falla| eip
    lambda --> sns
    cw --> sns
    budgets --> sns
```

**Notas**
- El tráfico de usuarios entra por la IP elástica al puerto 8065 de la EC2 primaria. No hay balanceador ni NAT Gateway (decisión de costo).
- Mattermost, Prometheus, Grafana y los exporters comparten una red Docker (`mattermost_mattermost_network`) dentro de la primaria, por lo que se resuelven por nombre (`mattermost-app`, `mattermost-prometheus`…).
- El acceso administrativo a las instancias es solo por SSM; no se abre SSH.
- La standby está diseñada para recibir la IP elástica cuando el Lambda detecta la primaria caída. Su estado operativo se describe en el [Pre-Mortem](PRE-MORTEM.md) (hecho H1).
- Terraform crea un bucket S3 para archivos, pero el `docker-compose.yml` que despliega el CI/CD configura `MM_FILESETTINGS_DRIVERNAME=local` (volumen Docker en la instancia).

## 2. Flujo de CI/CD (GitHub Actions → AWS)

```mermaid
flowchart LR
    dev([Desarrollador]) -->|PR / push a master| gh["GitHub<br/>sespinosab/mattermost"]

    subgraph pipe["Workflow: Continuous Integration & Artifact Delivery"]
        direction LR
        l["1. Lint<br/>Hadolint + compose config<br/>≈ 23 s"] --> b["2. Build imagen<br/>multi-etapa (Node + Go)<br/>≈ 323 s"]
        b --> s["3. Escaneo Trivy<br/>CRITICAL/HIGH<br/>≈ 35 s"]
        s --> p["4. Publicar en GHCR<br/>tag sha-commit<br/>≈ 68 s"]
        p --> d["5. Deploy a EC2<br/>(solo push a master)<br/>≈ 17 s"]
    end

    gh --> l
    p -->|imagen| ghcr[("GHCR<br/>ghcr.io/sespinosab/mattermost")]
    d -->|"OIDC → rol MattermostGitHubDeploy<br/>(sin llaves almacenadas)"| ssm["SSM Run Command"]
    ssm -->|scripts/deploy.sh| ec2["EC2 primaria<br/>docker-compose pull + up -d"]
    ghcr -.->|pull| ec2
    ec2 --> app["mattermost-app actualizado"]

    gh -->|manual / PR desde<br/>feat/add-monitoring-stack| mon["Workflow: Deploy Monitoring Stack<br/>git pull + compose up -d (≈ 1 min)"]
    mon --> ssm

    gh -->|cambios en terraform/**| tf["Workflow: Terraform CI<br/>fmt · Checkov · validate"]
```

**Notas**
- Duración total medida del pipeline principal: **≈ 479 s (8 min)** (ejecución del 6 de noviembre de 2026, sin errores).
- La autenticación hacia AWS usa OIDC (identidad federada); no hay claves de larga duración en GitHub.
- El despliegue a EC2 no abre puertos adicionales: usa SSM Run Command.
- Terraform tiene su propio workflow de validación; el `plan` con OIDC solo corre en una rama de infraestructura.

## 3. Flujo de observabilidad

```mermaid
flowchart LR
    subgraph fuentes["Fuentes de telemetría"]
        mm["mattermost-app<br/>métricas :8067 · logs JSON · OTLP"]
        host["Host EC2<br/>node-exporter"]
        cont["Contenedores<br/>cAdvisor"]
        db[("RDS")]
        pgx["postgres-exporter"]
        bb["blackbox-exporter<br/>sondas HTTP sintéticas"]
    end

    mm -->|sondas /api/v4/system/ping| bb
    db --> pgx

    host --> prom
    cont --> prom
    pgx --> prom
    bb --> prom
    otel["OTel Collector"] --> prom

    mm -->|trazas OTLP| otel
    otel --> tempo["Tempo (trazas)"]
    mm -->|logs de Docker| promtail["Promtail"] --> loki["Loki (logs)"]

    prom["Prometheus<br/>scrape 10 s · reglas SLI/SLO"] --> graf
    loki --> graf
    tempo --> graf
    graf["Grafana<br/>dashboard Golden Signals + SLOs"]
    prom --> alerts["Alertas<br/>ServiceDown · BurnRate · Latencia · DB"]
```

**Las cuatro señales doradas en el dashboard:** tráfico (req/s), latencia (ms), errores (tasa de fallos y consumo de Error Budget) y saturación (CPU/memoria del host y de los contenedores), más el estado de la dependencia PostgreSQL.

## 4. Inventario de componentes

| Capa | Componente | Detalle |
|---|---|---|
| Aplicación | Mattermost | Contenedor `mattermost-app`, imagen en GHCR, reinicio automático |
| Datos | RDS PostgreSQL | `mattermost-postgres`, versión 16, Single-AZ, 20 GB, cifrada, backups de 1 día |
| Cómputo | EC2 `t3.small` ×2 | Primaria (activa) y standby (diseñada para failover) |
| Red | VPC | `10.42.0.0/16`, 2 subredes públicas y 2 privadas, IP elástica |
| IaC | Terraform | Módulos `network`, `security`, `compute`, `database`, `storage`, `observability`, `failover` |
| CI/CD | GitHub Actions | Lint → build → escaneo → publicación → despliegue por OIDC + SSM |
| Observabilidad | Prometheus, Grafana, Loki, Tempo, OTel | Métricas, logs estructurados y trazas |
| Alertamiento | Prometheus + CloudWatch + SNS | Burn rate multi-ventana, servicio caído, latencia, BD, saturación |
| Resiliencia | Lambda de failover | Chequeo de salud por SSM cada minuto |
| Costos | AWS Budgets | Umbral de USD 40/mes con avisos al 50 %, 75 % y 90 % |
