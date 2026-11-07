<#
.SYNOPSIS
  Inyección controlada de fallas para el GameDay (AWS) — versión PowerShell (Windows).

.DESCRIPTION
  Equivalente de observability/scripts/gameday_inject_aws.sh para Windows PowerShell 5.1+
  o PowerShell 7+. Envía la inyección a la EC2 por AWS SSM Run Command (sin SSH).

  Topología objetivo (verificada): Mattermost corre como contenedor `mattermost-app`
  en la EC2 primaria con `restart: unless-stopped`; la base de datos es RDS gestionado.

  Escenarios:
    service-down : crash-loop (N x kill -9 al proceso principal desde el host).
                   Recuperación automática por la restart policy de Docker.
    latency      : netem dentro del namespace de red del contenedor (nsenter).
                   El servicio no se cae; la regla se auto-elimina por un timer.

.PARAMETER Scenario
  'service-down' o 'latency'.

.PARAMETER InstanceId
  ID de la instancia EC2 (por defecto i-0931fe9de23859d52).

.PARAMETER Region
  Región de AWS (por defecto us-east-1).

.PARAMETER Crashes
  (service-down) número de crashes consecutivos (por defecto 10).

.PARAMETER DelayMs
  (latency) milisegundos de retraso (por defecto 400).

.PARAMETER DurationS
  (latency) segundos antes de la auto-reversión (por defecto 240).

.EXAMPLE
  .\gameday_inject_aws.ps1 -Scenario service-down -InstanceId i-0931fe9de23859d52 -Region us-east-1 -Crashes 10

.EXAMPLE
  .\gameday_inject_aws.ps1 -Scenario latency -DelayMs 400 -DurationS 180
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('service-down', 'latency')]
    [string]$Scenario,

    [string]$InstanceId = 'i-0931fe9de23859d52',
    [string]$Region = 'us-east-1',
    [int]$Crashes = 10,
    [int]$DelayMs = 400,
    [int]$DurationS = 240
)

$ErrorActionPreference = 'Stop'
$ContainerName = 'mattermost-app'

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Error "No se encontró 'aws'. Instala AWS CLI v2 y verifica con: aws --version"
    exit 1
}

# Envía un bloque de comandos (array de strings) a la EC2 vía SSM y espera el resultado.
function Invoke-OnEc2 {
    param(
        [string]$Description,
        [string[]]$Commands
    )

    Write-Host "-> Enviando a $InstanceId via SSM: $Description" -ForegroundColor Yellow

    # El parámetro se pasa desde un archivo JSON: la forma abreviada no interpreta
    # los saltos de línea y rompe los comandos multilínea.
    $payload = @{ commands = $Commands } | ConvertTo-Json -Depth 5 -Compress
    $tmp = New-TemporaryFile
    # Sin BOM, para que el CLI lo lea correctamente.
    [System.IO.File]::WriteAllText($tmp.FullName, $payload, [System.Text.UTF8Encoding]::new($false))

    try {
        $cmdId = (aws ssm send-command `
                --region $Region `
                --instance-ids $InstanceId `
                --document-name 'AWS-RunShellScript' `
                --comment "GameDay: $Description" `
                --parameters "file://$($tmp.FullName)" `
                --query 'Command.CommandId' --output text).Trim()
        Write-Host "  CommandId: $cmdId"

        aws ssm wait command-executed --region $Region --command-id $cmdId --instance-id $InstanceId 2>$null | Out-Null

        $result = aws ssm get-command-invocation `
            --region $Region --command-id $cmdId --instance-id $InstanceId `
            --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' --output text
        Write-Host $result
    }
    finally {
        Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Red
Write-Host "  GAMEDAY - INYECCION DE FALLA (AWS / SSM)" -ForegroundColor Red
Write-Host "======================================================================" -ForegroundColor Red
Write-Host "  Escenario:  $Scenario"
Write-Host "  Instancia:  $InstanceId   Region: $Region"
Write-Host "======================================================================" -ForegroundColor Red
Write-Host ""

switch ($Scenario) {
    'service-down' {
        Write-Host "[ATAQUE] Crash-loop de '$ContainerName': $Crashes crashes (kill -9 desde el host)..." -ForegroundColor Red

        # Guion remoto (bash, corre en la EC2 Linux). Se escribe en /tmp y se lanza en
        # background con nohup, de modo que el bucle es autónomo y no depende de la sesión.
        # NOTA: no usar docker kill/stop (Docker los trata como parada manual e ignora
        # la restart policy). kill -9 al PID simula un crash real.
        $inner = @"
cat > /tmp/gameday_crashloop.sh <<'INNER'
#!/bin/bash
for i in `$(seq 1 $Crashes); do
  PID=0
  for t in `$(seq 1 90); do
    PID=`$(docker inspect -f '{{.State.Pid}}' $ContainerName 2>/dev/null || echo 0)
    [ "`$PID" != "0" ] && [ -n "`$PID" ] && break
    sleep 1
  done
  [ "`$PID" != "0" ] && kill -9 "`$PID" 2>/dev/null
  logger "GameDay: crash `$i/$Crashes de $ContainerName"
  sleep 1
done
logger "GameDay: crash-loop terminado; Docker debe recuperar el contenedor solo"
INNER
chmod +x /tmp/gameday_crashloop.sh
nohup /tmp/gameday_crashloop.sh >/tmp/gameday_crashloop.log 2>&1 &
echo "Crash-loop lanzado en background (PID `$!), $Crashes crashes."
"@

        Invoke-OnEc2 -Description "crash-loop mattermost ($Crashes kill -9)" -Commands @($inner)

        Write-Host ""
        Write-Host "OBSERVAR EN VIVO (no se interviene manualmente):" -ForegroundColor Yellow
        Write-Host "  -> Grafana:    'Estado del Servicio' pasa a DOWN; SLI y Error Budget caen"
        Write-Host "  -> Prometheus: MattermostServiceDown -> PENDING -> FIRING (~70 s)"
        Write-Host "  -> RECUPERACION: al terminar el bucle, 'restart: unless-stopped' deja el"
        Write-Host "     contenedor arriba solo (~1 min 40 s de caida total)."
        Write-Host ""
        Write-Host "Inyeccion aplicada. La plataforma se recupera sola; NO reiniciar a mano." -ForegroundColor Green
    }

    'latency' {
        Write-Host "[ATAQUE] Inyectando $DelayMs ms de latencia en el contenedor $ContainerName por $DurationS s..." -ForegroundColor Red
        Write-Host "El servicio NO se cae: se degrada (probe_success sigue en 1)." -ForegroundColor Yellow

        # netem dentro del namespace de red del contenedor (nsenter desde el host),
        # porque el tráfico de las sondas viaja por el puente de Docker, no por la
        # interfaz física de la EC2. La reversión queda programada con nohup+sleep.
        $inner = @"
PID=`$(docker inspect -f '{{.State.Pid}}' $ContainerName)
[ -n "`$PID" ] && [ "`$PID" != "0" ] || { echo "ERROR: contenedor $ContainerName no esta corriendo"; exit 1; }
command -v tc >/dev/null || dnf install -y iproute-tc >/dev/null 2>&1 || true
command -v tc >/dev/null || { echo "ERROR: falta tc (dnf install -y iproute-tc)"; exit 1; }
nsenter -t `$PID -n tc qdisc del dev eth0 root 2>/dev/null || true
nsenter -t `$PID -n tc qdisc add dev eth0 root netem delay ${DelayMs}ms
echo "Latencia ${DelayMs}ms aplicada en eth0 de $ContainerName (PID `$PID). Reversion automatica en $DurationS s."
nsenter -t `$PID -n tc qdisc show dev eth0
nohup sh -c "sleep $DurationS; nsenter -t `$PID -n tc qdisc del dev eth0 root 2>/dev/null || true; logger 'GameDay: latencia netem revertida automaticamente'" >/dev/null 2>&1 &
echo "Reversion programada (PID `$!)."
"@

        Invoke-OnEc2 -Description "inject netem latency ${DelayMs}ms for ${DurationS}s" -Commands @($inner)

        Write-Host ""
        Write-Host "OBSERVAR EN VIVO (no se interviene manualmente):" -ForegroundColor Yellow
        Write-Host "  -> Grafana:    panel de Latencia cruza el umbral de 250ms"
        Write-Host "  -> Prometheus: MattermostLatencySLODegraded -> FIRING (~70 s)"
        Write-Host "  -> probe_success SIGUE en 1 (el servicio nunca se cae)"
        Write-Host "  -> RECUPERACION: la regla netem se auto-elimina a los $DurationS s;"
        Write-Host "     Mattermost no se reinicia y la latencia vuelve a su rango nominal."
        Write-Host ""
        Write-Host "Inyeccion aplicada con reversion automatica programada." -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Green
Write-Host "  Grafana:    http://3.217.54.83:3000"
Write-Host "  Prometheus: http://3.217.54.83:9090/alerts"
Write-Host "======================================================================" -ForegroundColor Green
