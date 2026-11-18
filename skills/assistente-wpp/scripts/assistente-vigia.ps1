<#
Vigia do assistente-wpp: roda FORA do Claude (tarefa agendada AssistenteWppVigia, a cada 3 min).

  1. Se o despachante não estiver de pé (e a configuração estiver pronta), sobe.
  2. Lê o batimento que `assistente.ps1 watch` grava a cada ciclo. Se o detector parou ou não lê o
     WhatsApp, avisa o dono: pela conversa de avisos no WhatsApp (se o app responder) e por uma
     notificação do Windows. Uma vez por episódio, de novo a cada -AlertEveryMinutes, e quando voltar.
Não envia nada ao time e não toca no volante (lease). Respeita a pausa (`assistente.ps1 pause on`).

  assistente-vigia.ps1 [-MaxAgeSeconds 240] [-AlertEveryMinutes 30] [-DryRun]
#>
param(
    [int]$MaxAgeSeconds = 240,
    [int]$AlertEveryMinutes = 30,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$Utf8 = New-Object Text.UTF8Encoding $false

function Read-EnvFile([string]$Path) {
    $cfg = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $cfg }
    foreach ($l in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $t = $l.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $cfg[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
    }
    $cfg
}
$HomeDir = if ($env:ASSISTENTE_HOME) { $env:ASSISTENTE_HOME } else { Join-Path $env:USERPROFILE '.assistente-wpp' }
$FileCfg = Read-EnvFile $(if ($env:ASSISTENTE_CONFIG_FILE) { $env:ASSISTENTE_CONFIG_FILE } else { Join-Path $HomeDir 'assistente.env' })
function Get-Cfg([string]$Key, [string]$Default = '') {
    $v = [Environment]::GetEnvironmentVariable($Key)
    if ($v) { return $v }
    if ($FileCfg.ContainsKey($Key) -and $FileCfg[$Key]) { return $FileCfg[$Key] }
    $Default
}

$StateDir = Get-Cfg 'ASSISTENTE_STATE_DIR' (Join-Path $HomeDir 'state')
if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
$LogPath = Join-Path $StateDir 'vigia.log'
$PausePath = Join-Path $StateDir 'assistente.pause'
$SentLog = Join-Path $StateDir 'sent-messages.jsonl'
$HbPath = Join-Path $StateDir 'watch-heartbeat.json'
$StPath = Join-Path $StateDir 'vigia-estado.json'
$Name = Get-Cfg 'ASSISTENTE_NOME'
$Account = Get-Cfg 'ASSISTENTE_CONTA_JID'
$Notify = Get-Cfg 'ASSISTENTE_AVISO_JID' $Account
$McpUrl = Get-Cfg 'ASSISTENTE_MCP_URL' 'http://127.0.0.1:47821/mcp'
$McpToken = Get-Cfg 'ASSISTENTE_MCP_TOKEN'

function Write-Log([string]$Msg) {
    $l = '{0} {1}' -f ([DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ssK')), $Msg
    if (-not $DryRun) {
        try {
            if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 1MB) { Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force }
            [IO.File]::AppendAllText($LogPath, $l + "`n", $Utf8)
        } catch { }
    }
    Write-Host $l
}
function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    foreach ($try in 1..2) { try { return (Get-Content -Raw -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Json) } catch { Start-Sleep -Milliseconds 700 } }
    $null
}
function Get-PhoneKey([string]$J) {
    if (-not $J) { return '' }
    $d = (($J -replace ':\d+@', '@') -replace '@.*$', '') -replace '\D', ''
    if ($d -match '^55(\d{2})9?(\d{8})$') { return '55' + $Matches[1] + $Matches[2] }
    $d
}
function Invoke-Gateway([string]$Tool, [hashtable]$Arguments) {
    $body = @{ jsonrpc = '2.0'; id = [Environment]::TickCount; method = 'tools/call'; params = @{ name = $Tool; arguments = $Arguments } } | ConvertTo-Json -Depth 6 -Compress
    $headers = @{ Accept = 'application/json, text/event-stream' }
    if ($McpToken) { $headers['Authorization'] = "Bearer $McpToken" }
    $r = Invoke-WebRequest -Uri $McpUrl -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ($Utf8.GetBytes($body)) -UseBasicParsing -TimeoutSec 15
    $raw = $Utf8.GetString($r.RawContentStream.ToArray())
    if ($raw -match '(?m)^data: (.+)$') { $raw = $Matches[1] }
    $j = $raw | ConvertFrom-Json
    if ($j.error) { throw "MCP ${Tool}: $($j.error.message)" }
    if ($j.result.isError) { throw "MCP ${Tool}: $($j.result.content[0].text)" }
    $j.result.content[0].text | ConvertFrom-Json
}

# Notificação do Windows: chega mesmo com o app do WhatsApp fechado.
function Show-Toast([string]$Text) {
    if ($DryRun -or $env:ASSISTENTE_SEM_TOAST) { return }
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $esc = [Security.SecurityElement]::Escape($Text)
        $xml.LoadXml("<toast><visual><binding template=`"ToastGeneric`"><text>Assistente de WhatsApp</text><text>$esc</text></binding></visual></toast>")
        $app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show((New-Object Windows.UI.Notifications.ToastNotification $xml))
    } catch { Write-Log "notificação do Windows falhou: $($_.Exception.Message)" }
}

# Aviso ao dono: WhatsApp (conversa de avisos, só se a conta conectada for a esperada) + notificação do Windows.
function Send-Alert([string]$Text) {
    $okAny = $false
    Show-Toast $Text
    if (-not $DryRun -and -not $env:ASSISTENTE_SEM_TOAST) { $okAny = $true }
    if (-not $Notify -or -not $Name) { Write-Log 'sem ASSISTENTE_AVISO_JID/ASSISTENTE_NOME: aviso só pelo Windows'; return $okAny }
    $msg = "*$($Name.Trim()):* $Text"
    if ($DryRun) { Write-Log "DRY-RUN aviso: $msg"; return $true }
    try {
        $linked = (Invoke-Gateway 'whatsapp_status' @{}).wacli.linked_jid
        if ((Get-PhoneKey $linked) -ne (Get-PhoneKey $Account)) { Write-Log 'conta conectada no app não é a esperada: aviso só pelo Windows'; return $okAny }
        $res = Invoke-Gateway 'send_text_message' @{ to = $Notify; text = $msg }
        if ($res.sent) {
            # registra como mensagem do assistente para o detector não tratá-la como pedido do dono
            if ($res.message_id) { try { [IO.File]::AppendAllText($SentLog, ((@{ ts = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssK'); chat = $Notify; id = $res.message_id } | ConvertTo-Json -Compress) + "`n"), $Utf8) } catch { } }
            Write-Log 'aviso enviado pelo WhatsApp'
            return $true
        }
    }
    catch { Write-Log "aviso pelo WhatsApp falhou: $($_.Exception.Message)" }
    $okAny
}

$now = [DateTimeOffset]::Now
if (Test-Path -LiteralPath $PausePath) { Write-Log 'pausado: sem verificação'; exit 0 }
if (-not $Name -or -not $Account) { Write-Log 'assistente ainda não configurado (ASSISTENTE_NOME/ASSISTENTE_CONTA_JID): nada a vigiar'; exit 0 }

# Sobe o despachante se não estiver de pé.
$Dispatcher = Join-Path $PSScriptRoot 'assistente-despachante.ps1'
if ((Get-Cfg 'ASSISTENTE_DESPACHANTE' '1') -ne '0' -and -not $DryRun -and (Test-Path -LiteralPath $Dispatcher)) {
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Dispatcher -Mode status 2>$null
    if ($LASTEXITCODE -ne 0) {
        $env:ASSISTENTE_VIGIA_RUN = '1'   # o start do despachante não chama a tarefa de volta: sobe direto daqui
        $o = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Dispatcher -Mode start 2>&1 | Out-String).Trim()
        Write-Log "despachante não estava de pé; subindo: $o"
    }
}

$hb = Read-Json $HbPath
$state = Read-Json $StPath
if (-not $state) { $state = [pscustomobject]@{ stale_since = $null; last_alert = $null; alerts = 0; stale_runs = 0; last_run = $null } }
foreach ($k in 'stale_runs', 'last_run') { if (-not ($state.PSObject.Properties.Name -contains $k)) { $state | Add-Member -NotePropertyName $k -NotePropertyValue $null } }

# Depois de suspensão/boot (intervalo grande desde a última rodada) o batimento velho não prova queda: zera a contagem.
if ($state.last_run -and (($now - [DateTimeOffset]::Parse($state.last_run)).TotalMinutes -gt 10)) { $state.stale_runs = 0 }
$state.last_run = $now.ToString('yyyy-MM-ddTHH:mm:ssK')

$age = $null; $healthy = $false; $reason = 'sem batimento'
if ($hb -and $hb.ts) {
    $age = [int]($now - [DateTimeOffset]::Parse($hb.ts)).TotalSeconds
    if ($age -lt -120) { $reason = 'o relógio do batimento está no futuro (verifique a hora do computador)' }
    elseif ($age -le $MaxAgeSeconds) {
        if ($hb.gateway_ok) { $healthy = $true }
        else {
            $e = [string]$hb.last_error
            if ($e.Length -gt 100) { $e = $e.Substring(0, 100) }
            $reason = if ($e) { "o detector está vivo, mas não consegue ler o WhatsApp ($e)" } else { 'o detector está vivo, mas não consegue ler o WhatsApp' }
        }
    }
    else { $reason = "o detector parou há $([int]($age / 60)) min" }
}

if ($healthy) {
    if ($state.stale_since -and $state.alerts -gt 0) {
        $mins = [int]($now - [DateTimeOffset]::Parse($state.stale_since)).TotalMinutes
        Write-Log "recuperado após $mins min"
        $null = Send-Alert ("Voltou: estou escutando de novo (fiquei fora do ar por cerca de $mins min).")
    }
    if (-not $DryRun) { [IO.File]::WriteAllText($StPath, (([pscustomobject]@{ stale_since = $null; last_alert = $null; alerts = 0; stale_runs = 0; last_run = $state.last_run }) | ConvertTo-Json), $Utf8) }
    exit 0
}

# Parada confirmada em 2 rodadas seguidas (evita alarme falso). Aviso no 1º episódio; depois a cada -AlertEveryMinutes
# nos 3 primeiros avisos e a cada 4 h daí em diante.
$state.stale_runs = [int]$state.stale_runs + 1
if (-not $state.stale_since) { if ($hb -and $hb.ts -and $age -gt 0) { $state.stale_since = [string]$hb.ts } else { $state.stale_since = $now.ToString('yyyy-MM-ddTHH:mm:ssK') } }
$since = [DateTimeOffset]::Parse($state.stale_since).ToLocalTime()
$every = if ([int]$state.alerts -ge 3) { 240 } else { $AlertEveryMinutes }
$due = ([int]$state.stale_runs -ge 2) -and ((-not $state.last_alert) -or (($now - [DateTimeOffset]::Parse($state.last_alert)).TotalMinutes -ge $every))
Write-Log "FORA DO AR: $reason (desde $($since.ToString('HH:mm')); rodadas=$($state.stale_runs))"
if ($due) {
    $ok = Send-Alert ("ALERTA: estou fora do ar ($reason, desde $($since.ToString('HH:mm'))). O time fica sem resposta até eu voltar. Confira se o app WhatsApp MCP está aberto e conectado. Aviso de novo se continuar assim, e quando voltar.")
    if ($ok) { $state.last_alert = $now.ToString('yyyy-MM-ddTHH:mm:ssK'); $state.alerts = [int]$state.alerts + 1 }
}
if (-not $DryRun) { [IO.File]::WriteAllText($StPath, ($state | ConvertTo-Json), $Utf8) }
exit 2
