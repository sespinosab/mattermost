<#
.SYNOPSIS
  Apoyo para el GameDay (AWS) — versión PowerShell (Windows). Solo lectura.

.DESCRIPTION
  Equivalente de observability/scripts/gameday_watch.sh. NO inyecta fallas
  (eso lo hace gameday_inject_aws.ps1). Subcomandos:

    preflight                      Verifica credenciales, SSM, Prometheus, alertas y servicio.
    wait-nominal [MaxSegundos]     Espera SLI 5m = 1 y cero alertas (por defecto 600).
    watch [Segundos] [Etiqueta]    Registra cada 5 s en evidencias\<Etiqueta>-<fecha>.log.
    loki <InicioUTC> <FinUTC>      Logs de Mattermost desde Loki (vía SSM), fechas ISO UTC.

.EXAMPLE
  .\gameday_watch.ps1 preflight

.EXAMPLE
  .\gameday_watch.ps1 watch 330 escenario-F

.EXAMPLE
  .\gameday_watch.ps1 loki 2026-11-06T20:24:40Z 2026-11-06T20:27:10Z
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('preflight', 'wait-nominal', 'watch', 'loki')]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Arg1,

    [Parameter(Position = 2)]
    [string]$Arg2
)

$ErrorActionPreference = 'Stop'

$PromUrl    = if ($env:PROM_URL)    { $env:PROM_URL }    else { 'http://3.217.54.83:9090' }
$AppUrl     = if ($env:APP_URL)     { $env:APP_URL }     else { 'http://3.217.54.83:8065' }
$InstanceId = if ($env:INSTANCE_ID) { $env:INSTANCE_ID } else { 'i-0931fe9de23859d52' }
$Region     = if ($env:AWS_REGION)  { $env:AWS_REGION }  else { 'us-east-1' }
$EvidDir    = if ($env:EVID_DIR)    { $env:EVID_DIR }    else { 'evidencias' }

function Write-Ok   { param($m) Write-Host "[OK]   $m"    -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "[AVISO] $m"   -ForegroundColor Yellow }
function Write-Fail { param($m) Write-Host "[FALLO] $m"   -ForegroundColor Red }

# Consulta instantánea a Prometheus; devuelve el valor del primer resultado o 'n/d'.
function Get-PromValue {
    param([string]$Query)
    try {
        $enc = [System.Uri]::EscapeDataString($Query)
        $r = Invoke-RestMethod -Uri "$PromUrl/api/v1/query?query=$enc" -TimeoutSec 6
        if ($r.data.result.Count -gt 0) {
            return [math]::Round([double]$r.data.result[0].value[1], 4)
        }
        return 'n/d'
    }
    catch { return 'n/d' }
}

# Alertas Mattermost activas como "Nombre:estado,...".
function Get-Alerts {
    try {
        $enc = [System.Uri]::EscapeDataString('ALERTS{alertname=~"Mattermost.*"}')
        $r = Invoke-RestMethod -Uri "$PromUrl/api/v1/query?query=$enc" -TimeoutSec 6
        $parts = foreach ($x in $r.data.result) {
            ($x.metric.alertname -replace 'Mattermost', '') + ':' + $x.metric.alertstate
        }
        return ($parts -join ',')
    }
    catch { return '?' }
}

# Sonda HTTP al servicio: devuelve "CODIGO tiempo_s".
function Get-AppProbe {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = Invoke-WebRequest -Uri "$AppUrl/api/v4/system/ping" -TimeoutSec 8 -UseBasicParsing
        $sw.Stop()
        return @([int]$resp.StatusCode, [math]::Round($sw.Elapsed.TotalSeconds, 3))
    }
    catch {
        $sw.Stop()
        $code = 0
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        return @($code, [math]::Round($sw.Elapsed.TotalSeconds, 3))
    }
}

function Invoke-Preflight {
    $bad = 0
    Write-Host "== Revision previa del GameDay ($((Get-Date).ToUniversalTime().ToString('HH:mm:ss')) UTC) =="

    try {
        $id = aws sts get-caller-identity --region $Region --query '[Account,Arn]' --output text 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Ok "AWS CLI autenticado: $id" } else { Write-Fail "AWS CLI sin credenciales validas: $id"; $bad = 1 }
    }
    catch { Write-Fail "AWS CLI sin credenciales validas"; $bad = 1 }

    $ping = (aws ssm describe-instance-information --region $Region --filters "Key=InstanceIds,Values=$InstanceId" --query 'InstanceInformationList[0].PingStatus' --output text 2>$null)
    if ($ping -eq 'Online') { Write-Ok "Instancia $InstanceId Online en SSM" } else { Write-Fail "Instancia $InstanceId no esta Online en SSM ($ping)"; $bad = 1 }

    try {
        $t = Invoke-RestMethod -Uri "$PromUrl/api/v1/targets" -TimeoutSec 6
        $up = ($t.data.activeTargets | Where-Object { $_.health -eq 'up' }).Count
        $tot = $t.data.activeTargets.Count
        if ($up -eq $tot -and $tot -gt 0) { Write-Ok "Prometheus: targets UP $up/$tot" } else { Write-Fail "Prometheus: targets UP $up/$tot"; $bad = 1 }
    }
    catch { Write-Fail "Prometheus no responde en $PromUrl"; $bad = 1 }

    $ps = Get-PromValue 'probe_success{job="blackbox_http_mattermost"}'
    if ($ps -eq 1) { Write-Ok "probe_success = 1" } else { Write-Fail "probe_success = $ps"; $bad = 1 }

    $probe = Get-AppProbe
    if ($probe[0] -eq 200) { Write-Ok "Servicio publico responde HTTP 200 ($($probe[1])s)" } else { Write-Fail "Servicio publico responde HTTP $($probe[0])"; $bad = 1 }

    $al = Get-Alerts
    if ([string]::IsNullOrEmpty($al)) { Write-Ok "Sin alertas activas" } else { Write-Warn "Alertas activas: $al (espera con: wait-nominal)"; $bad = 1 }

    $sli = Get-PromValue 'job:mattermost_availability:sli5m'
    if ($sli -eq 1) { Write-Ok "SLI de disponibilidad 5m = 1,0" } else { Write-Warn "SLI de disponibilidad 5m = $sli (aun recuperando)"; $bad = 1 }

    Write-Host ""
    if ($bad -eq 0) { Write-Ok "TODO LISTO para inyectar." } else { Write-Warn "Hay puntos pendientes; revisa antes de inyectar." }
}

function Invoke-WaitNominal {
    param([int]$Max = 600)
    $start = Get-Date
    Write-Host "Esperando estado nominal (SLI 5m = 1 y sin alertas), maximo ${Max}s..."
    while (((Get-Date) - $start).TotalSeconds -lt $Max) {
        $sli = Get-PromValue 'job:mattermost_availability:sli5m'
        $al = Get-Alerts
        $alShow = if ([string]::IsNullOrEmpty($al)) { 'ninguna' } else { $al }
        Write-Host "$((Get-Date).ToUniversalTime().ToString('HH:mm:ss')) | SLI5m=$sli | alertas: $alShow"
        if ($sli -eq 1 -and [string]::IsNullOrEmpty($al)) { Write-Ok "Estado nominal recuperado."; return }
        Start-Sleep -Seconds 15
    }
    Write-Fail "No volvio al estado nominal en ${Max}s."
}

function Invoke-Watch {
    param([int]$Dur = 300, [string]$Label = 'gameday')
    $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    if (-not (Test-Path $EvidDir)) { New-Item -ItemType Directory -Path $EvidDir | Out-Null }
    $file = Join-Path $EvidDir "$Label-$ts.log"
    $header = @(
        "# GameDay - registro de linea de tiempo ($Label)",
        "# Inicio: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) * Duracion: ${Dur}s * Prometheus: $PromUrl * App: $AppUrl",
        "# hora_UTC | probe_success | latencia_1m(s) | HTTP app | t_app(s) | SLI_5m | error_budget_% | alertas"
    )
    $header | Tee-Object -FilePath $file
    $start = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt $Dur) {
        $probe = Get-AppProbe
        $line = "$((Get-Date).ToUniversalTime().ToString('HH:mm:ss')) | " +
                "$(Get-PromValue 'probe_success{job="blackbox_http_mattermost"}') | " +
                "$(Get-PromValue 'job:mattermost_latency_avg:seconds1m') | " +
                "$($probe[0]) | $($probe[1]) | " +
                "$(Get-PromValue 'job:mattermost_availability:sli5m') | " +
                "$(Get-PromValue 'job:mattermost_error_budget_remaining:percent') | " +
                "$(Get-Alerts)"
        $line | Tee-Object -FilePath $file -Append
        Start-Sleep -Seconds 5
    }
    Write-Host "Registro guardado en: $file"
}

function Invoke-Loki {
    param([string]$Ini, [string]$Fin)
    if ([string]::IsNullOrEmpty($Ini) -or [string]::IsNullOrEmpty($Fin)) {
        Write-Host "Uso: gameday_watch.ps1 loki <InicioUTC> <FinUTC>  (ISO, p. ej. 2026-11-06T20:24:40Z)"
        return
    }
    function To-Ns([string]$s) {
        $dt = [datetime]::ParseExact($s, 'yyyy-MM-ddTHH:mm:ssZ', $null, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        $epoch = [datetime]'1970-01-01T00:00:00Z'
        return [int64](($dt.ToUniversalTime() - $epoch).TotalSeconds) * 1000000000
    }
    $startNs = To-Ns $Ini
    $endNs = To-Ns $Fin
    $rx = '%28Server%20is%20listening%7CStarting%20Server%7CStopping%20Server%7Cshutdown%7CReceived%20signal%7Cpanic%7Cfailed%20to%20connect%7CError%29'
    $url = "http://loki:3100/loki/api/v1/query_range?limit=300&direction=forward&start=$startNs&end=$endNs&query=%7Bjob%3D%22mattermost%22%7D%20%7C~%20%22$rx%22"

    # Script Python que corre EN la EC2 para formatear la respuesta de Loki.
    $py = @'
import sys,json,datetime
d=json.load(sys.stdin)
rows=sorted((int(t),l) for s in d["data"]["result"] for t,l in s["values"])
print("lineas:",len(rows))
for t,l in rows[:40]:
    try:
        j=json.loads(l); m=j.get("msg") or l; lv=j.get("level","")
    except Exception:
        m=l; lv=""
    print(datetime.datetime.utcfromtimestamp(t/1e9).strftime("%H:%M:%S"),lv,str(m)[:160])
'@
    $remote = "docker exec mattermost-prometheus wget -qO- '$url' | python3 -c `"$($py -replace '"','\"')`""

    $payload = @{ commands = @($remote) } | ConvertTo-Json -Depth 5 -Compress
    $tmp = New-TemporaryFile
    [System.IO.File]::WriteAllText($tmp.FullName, $payload, [System.Text.UTF8Encoding]::new($false))
    try {
        $cmdId = (aws ssm send-command --region $Region --instance-ids $InstanceId --document-name 'AWS-RunShellScript' `
                --comment 'GameDay: consulta de logs Loki (lectura)' --parameters "file://$($tmp.FullName)" `
                --query 'Command.CommandId' --output text).Trim()
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 3
            $st = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $InstanceId --query Status --output text 2>$null
            if ($st -in @('Success', 'Failed', 'TimedOut', 'Cancelled')) { break }
        }
        Write-Host "== Logs de Mattermost en Loki ($Ini -> $Fin) [SSM: $st] =="
        aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $InstanceId `
            --query '[StandardOutputContent,StandardErrorContent]' --output text
    }
    finally {
        Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
    }
}

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Error "No se encontró 'aws'. Instala AWS CLI v2 y verifica con: aws --version"
    exit 1
}

switch ($Command) {
    'preflight'    { Invoke-Preflight }
    'wait-nominal' { Invoke-WaitNominal -Max ([int]($Arg1 | ForEach-Object { if ($_) { $_ } else { 600 } })) }
    'watch'        { Invoke-Watch -Dur ([int]($Arg1 | ForEach-Object { if ($_) { $_ } else { 300 } })) -Label ($(if ($Arg2) { $Arg2 } else { 'gameday' })) }
    'loki'         { Invoke-Loki -Ini $Arg1 -Fin $Arg2 }
}
