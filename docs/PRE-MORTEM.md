# Informe Pre-Mortem

## Referencia de SLOs y Error Budget

  -----------------------------------------------------------------------
  **Concepto**                        **Valor**
  ----------------------------------- -----------------------------------
  SLO de disponibilidad               ≥ 99,9 % en 30 días móviles

  Presupuesto de error                0,1 % de 43 200 min = 43,2 min/mes
                                      = 2 592 s

  SLO de latencia                     P95 ≤ 250 ms

  Burn rate                           tasa de error / 0,001. Una caída
                                      total equivale a 1 000×

  Umbrales de alerta                  Crítico \> 14,4× (agota el
                                      presupuesto en ≈ 2 días) ·
                                      Advertencia \> 6×

  Tiempo para agotar el presupuesto   43,2 min (30 días / 1 000)
  con caída total                     
  -----------------------------------------------------------------------

**Política de Error Budget** (saldo → acción): 100--50 % verde,
despliegues libres · 50--20 % amarillo, despliegues con aprobación ·
20--1 % naranja, congelamiento de funcionalidades no esenciales · ≤ 0 %
rojo, feature freeze total hasta recuperar confiabilidad.

## Escenario crítico 1 --- Indisponibilidad crítica de la aplicación Mattermost

Se simulará una falla crítica mediante la terminación forzada del
contenedor principal de Mattermost utilizando
`docker kill mattermost-app`.

Como el `docker-compose` tiene configurada la política
`restart: unless-stopped`, se espera que Docker detecte la terminación
inesperada del proceso y reinicie automáticamente el contenedor sin
intervención manual.

El objetivo del experimento es validar:

-   La capacidad de auto-recuperación del servicio.
-   El tiempo real de indisponibilidad.
-   La efectividad del monitoreo y las alertas.
-   La correcta ejecución del Runbook de respuesta ante incidentes.
-   El impacto de una caída breve sobre los SLIs, SLOs y Error Budget.

### Técnica de los 5 Porqués

**Problema:** Los usuarios no pueden acceder temporalmente a la
aplicación Mattermost.

  -----------------------------------------------------------------------
  **Pregunta de Indagación**          **Hallazgo Técnico / Causa
                                      Identificada**
  ----------------------------------- -----------------------------------
  **¿Por qué los usuarios no pueden   Porque el contenedor de la
  acceder a Mattermost?**             aplicación dejó de estar disponible
                                      y dejó de responder a las
                                      solicitudes HTTP.

  **¿Por qué el contenedor dejó de    Porque el proceso principal de
  estar disponible?**                 Mattermost fue terminado
                                      inesperadamente.

  **¿Por qué el proceso principal     Hipotéticamente, por un fallo del
  pudo ser terminado                  proceso, agotamiento de recursos,
  inesperadamente?**                  error del sistema operativo, una
                                      operación administrativa incorrecta
                                      o una terminación externa del
                                      proceso.

  **¿Por qué una terminación del      Porque existe un período entre la
  proceso genera indisponibilidad     caída del proceso y la
  para los usuarios?**                detección/reinicio automático del
                                      contenedor, durante el cual la
                                      aplicación no puede atender
                                      solicitudes.

  **¿Por qué esta indisponibilidad    Porque la recuperación automática
  puede afectar el servicio antes de  depende de que Docker detecte el
  su recuperación?**                  fallo, cree nuevamente el proceso
                                      del contenedor y que Mattermost
                                      complete correctamente su proceso
                                      de inicialización y vuelva a estar
                                      saludable.
  -----------------------------------------------------------------------

La causa raíz puede modelarse como una **terminación inesperada del
proceso principal de la aplicación**, potencialmente ocasionada por:

-   Fallo interno de la aplicación.
-   Agotamiento de memoria o CPU.
-   Terminación accidental por una operación administrativa.
-   Fallo del host.
-   Problemas durante un despliegue.
-   Interacción incorrecta con procesos de automatización.

**En el GameDay**, esta condición será simulada deliberadamente mediante
`docker kill`.

### Impacto sobre SLIs/SLOs y Error Budget

#### SLI afectado: Disponibilidad

Porcentaje de solicitudes exitosas atendidas correctamente por
Mattermost durante el período de medición.

Por ejemplo:

\[ Disponibilidad =
`\frac{Solicitudes\ exitosas}{Solicitudes\ totales}`{=tex}
`\times 100`{=tex} \]

Durante la caída del contenedor:

-   Las solicitudes dirigidas a Mattermost pueden fallar.
-   Los health checks pueden reportar indisponibilidad.
-   Las métricas de disponibilidad pueden registrar errores HTTP o
    ausencia de respuesta.

El SLI de disponibilidad disminuirá durante el período comprendido
entre:

1.  La terminación efectiva del contenedor.
2.  El reinicio automático.
3.  La finalización de la inicialización de Mattermost.
4.  La recuperación completa del endpoint de la aplicación.

#### SLO

Por ejemplo, si el SLO definido para disponibilidad es del **99.9 %
mensual**, el Error Budget sería:

\[ 100% - 99.9% = 0.1% \]

En un período de 30 días:

\[ 30 `\times 24`{=tex} `\times 60`{=tex} = 43,200 minutos \]

Por tanto:

\[ 43,200 `\times 0.001`{=tex} = 43.2 minutos \]

El sistema tendría aproximadamente **43.2 minutos mensuales de Error
Budget**.

#### Ritmo de quema del Error Budget

El **Burn Rate** indica qué tan rápido se consume el Error Budget
respecto al ritmo permitido para cumplir el SLO.

Durante una indisponibilidad completa:

\[ Error Rate = 100% \]

Si el SLO permite un error de 0.1 % mientras la aplicación esté
completamente caída:

\[ Burn Rate = `\frac{100\%}{0.1\%}`{=tex} = 1000 \]

Es decir, durante una indisponibilidad total, el Error Budget se consume
aproximadamente **1,000 veces más rápido que el ritmo sostenible** para
cumplir un SLO de 99.9 %.

### Plan de contingencia y mitigación

La primera línea de recuperación es automática:

1.  El contenedor de Mattermost es terminado.
2.  Docker detecta que el proceso terminó.
3.  La política `restart: unless-stopped` activa el reinicio.
4.  Docker inicia nuevamente el contenedor.
5.  Mattermost completa su proceso de inicialización.
6.  Los health checks vuelven a reportar disponibilidad.
7.  El tráfico hacia la aplicación vuelve a procesarse normalmente.

En caso de que la recuperación automática falle, el plan de contingencia
es el siguiente:

**Diagnóstico:**

1.  Comprobar si el contenedor `mattermost-app` está detenido, en bucle
    de reinicio o si fue terminado por OOM:

    ``` bash
    docker inspect mattermost-app --format 'Estado: {{.State.Status}} | OOMKilled: {{.State.OOMKilled}} | ExitCode: {{.State.ExitCode}}'
    ```

2.  Inspeccionar los últimos logs de la aplicación buscando errores
    fatales o pánicos:

    ``` bash
    docker logs --tail 100 mattermost-app | grep -iE "error|fatal|panic|database|connection refused"
    ```

3.  Verificar el estado de reinicio:

    ``` bash
    docker inspect mattermost-app
    ```

4.  Recuperación manual controlada:

    ``` bash
    docker compose up -d mattermost
    ```

    Luego, validar con `docker ps`.

5.  También debe comprobarse que:

    -   El endpoint HTTP responde correctamente.
    -   Mattermost es accesible para los usuarios.
    -   Las métricas vuelven a valores normales.
    -   Las alertas se resuelven.
    -   No existen errores persistentes en los logs.

**Mitigación rápida:**

Si el contenedor está detenido o colgado:

``` bash
docker restart mattermost-app
```

##  Escenario crítico 2 --- Degradación de Latencia en Producción

Se detectó una degradación crítica en el tiempo de respuesta de
Mattermost generada por un cuello de botella de red (inyección
artificial de 400 ms en la interfaz `eth0` del contenedor
`mattermost-app`). El servicio se mantuvo accesible (HTTP 200), pero
violó de manera continua el SLO de latencia (P95 ≤ 250 ms). El equipo
SRE fue alertado por Prometheus, diagnosticó la capa de red con
herramientas de kernel (`tc`/`nsenter`) y ejecutó el Runbook de
remediación manual, restableciendo el rendimiento nominal en \< 20 ms.

###  Técnica de los 5 Porqués (Análisis Causal)

  -----------------------------------------------------------------------
  **Pregunta de Indagación**          **Hallazgo Técnico / Causa
                                      Identificada**
  ----------------------------------- -----------------------------------
  **¿Por qué se degradó el tiempo de  Los paquetes de respuesta HTTP
  respuesta en Mattermost (P95 \> 400 salientes (egress) tardaban 400 ms
  ms)?**                              adicionales en salir de la interfaz
                                      virtual `eth0` del contenedor.

  **¿Por qué la interfaz `eth0`       Existía una disciplina de
  retenía los paquetes de red?**      encolamiento activa
                                      (`qdisc netem delay 400ms`)
                                      manipulando el tráfico en el
                                      subsistema de red del kernel.

  **¿Por qué estaba configurada esa   Fue inyectada de manera programada
  regla de `netem` en el              vía AWS SSM durante la ejecución
  contenedor?**                       del ejercicio de GameDay para
                                      validar la observabilidad.

  **¿Por qué el servicio no se        El proceso de Mattermost seguía
  auto-recuperó de forma autónoma?**  vivo y respondiendo HTTP 200, por
                                      lo que la política de reinicio
                                      `restart: unless-stopped` de Docker
                                      no actuó.

  **¿Por qué se dependió de           Las fallas puras de red requieren
  intervención manual y se resolvió   intervención a nivel de namespace
  en minutos?**                       (`nsenter`); la alerta de latencia
                                      en Prometheus y el Runbook SRE
                                      permitieron purgar la regla en
                                      caliente sin reiniciar la
                                      aplicación.
  -----------------------------------------------------------------------

### Análisis de las Dimensiones del Incidente

#### Capacidad de Auto-recuperación del Servicio

-   **Evaluación:** **No aplica auto-recuperación automática (Diseño
    Intencional SRE).**
-   **Causa:** La degradación ocurrió a nivel de transporte/red en el
    namespace del contenedor, sin matar el proceso ni provocar fallas en
    los health checks binarios (ping). La política de Docker
    `restart: unless-stopped` solo responde ante caídas de procesos, por
    lo que una falla de este tipo requirió intervención activa del
    operador humano (Runbook SRE).

#### Tiempo Real de Indisponibilidad

-   **Resultado:** **Indisponibilidad nula (0 s).**
-   El código HTTP de respuesta se mantuvo en 200 OK en el endpoint
    `/api/v4/system/ping`. Sin embargo, la experiencia de usuario sufrió
    degradación severa (tiempo de carga 20× superior al estándar de 20
    ms).

#### Efectividad del Monitoreo y las Alertas

-   **Dashboard Grafana:**
    -   El panel **"Latencia P95 / Promedio"** reflejó de inmediato el
        salto de 1.8 ms a ≈ 402 ms, cruzando visiblemente el umbral rojo
        de 250 ms.
    -   El panel **"Estado del Servicio"** se mantuvo en **UP**,
        evitando falsas alarmas de caída de infraestructura.
-   **Prometheus Alertmanager:**
    -   La regla `MattermostLatencySLODegraded` se activó con alta
        precisión:
        -   +40 s en estado PENDING.
        -   +70 s en estado FIRING.
    -   La ventana corta de 1 minuto
        (`job:mattermost_latency_avg:seconds1m`) demostró ser eficaz
        para una rápida detección operativa frente a la ventana estándar
        de 5m.

#### Correcta Ejecución del Runbook de Respuesta ante Incidentes

-   **Diagnóstico:** El ingeniero identificó la degradación con la sonda
    Blackbox y comprobó el namespace del contenedor en Amazon Linux:

    ``` bash
    PID=$(docker inspect -f '{{.State.Pid}}' mattermost-app)

    sudo nsenter -t $PID -n tc qdisc show dev eth0
    ```

-   **Remediación:** Se ejecutó con éxito el procedimiento documentado
    en la sección 2 del Runbook:

    ``` bash
    # Vía comando directo en host o script remoto SSM:

    sudo nsenter -t $PID -n tc qdisc del dev eth0 root
    ```

-   **Resultado:** La latencia descendió instantáneamente a valores
    nominales (\< 15 ms), resolviendo la alerta sin reiniciar el
    contenedor ni generar tiempo fuera de servicio.

#### Impacto sobre SLIs, SLOs y Error Budget (Análisis Comparativo y Señales Doradas)

Con base en los fundamentos de observabilidad y las **4 Señales Doradas
de SRE** (Latencia, Tráfico, Errores y Saturación):

1.  **Separación de Señales Doradas (Latencia vs. Errores):**

    -   **Señal 1 --- Latencia:** Mide el tiempo de atención separando
        peticiones exitosas de fallidas. Durante el incidente, la
        latencia promedio saltó de 1.8 ms a más de 400 ms, violando
        sostenidamente el **SLO de Rendimiento (P95 ≤ 250 ms)** durante
        toda la ventana de degradación (\~3.5 minutos).
    -   **Señal 3 --- Errores:** Mide exclusivamente peticiones fallidas
        explícitas (5xx) o contenido inválido. Debido a que el endpoint
        `/api/v4/system/ping` continuó respondiendo HTTP 200 OK, la tasa
        de errores de la plataforma no se incrementó
        (`error_rate = 0.0`).

2.  **Impacto en el Error Budget de Disponibilidad:**

    -   El indicador de disponibilidad mensual (**SLI 30d**) se calculó
        en base a `probe_success`, manteniéndose en **100 %**.
    -   Por tanto, el **Error Budget de Disponibilidad no sufrió
        descuento inmediato**. Las peticiones se completaron con
        lentitud, pero sin rechazos de conexión ni códigos de error.

3.  **Riesgo Operativo y Correlación con Métricas DORA:**

    -   Tal como se demuestra en el caso de estudio de la anatomía del
        incidente (Señal 1 disparando en Prometheus con latencia anómala
        antes de una falla en cascada), una latencia sostenida
        representa una amenaza crítica:
        -   **Saturación latente (Señal 4):** La acumulación de sockets
            y threads esperando respuestas lentas agota los pools de
            conexión y buffers del contenedor.
        -   **Transición a caída:** Si el SRE no hubiese intervenido con
            el Runbook, los clientes y sondas habrían alcanzado el
            límite de *timeout* (\> 5 s), transformando la degradación
            de latencia en un corte total de disponibilidad y quemando
            el Error Budget a tasa acelerada.
    -   La rápida detección de Prometheus junto a la remediación manual
        permitieron mantener el **Time to Restore (MTTR)** en el nivel
        élite (\< 6 minutos), preservando la estabilidad del sistema y
        evitando el consumo del presupuesto de error mensual.
