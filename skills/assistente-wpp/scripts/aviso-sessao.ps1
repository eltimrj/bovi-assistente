# aviso-sessao.ps1: avisa o dono no WhatsApp quando uma sessão do Claude Code para e espera por ele.
#
# Hooks (o install.ps1 registra em ~/.claude/settings.json):
#   Stop                                   -Mode stop   turno de >= ASSISTENTE_AVISO_MIN_SEG (padrão 60 s) terminou
#   Notification (permission_prompt|elicitation_dialog) e PreToolUse (AskUserQuestion)
#                                          -Mode wait   a sessão está esperando autorização ou resposta há 60 s
#   (interno)                              -Mode bgwait o turno acabou com trabalho em background: avisa quando a
#                                                       sessão ficar parada, se ela não acordar sozinha
# O par é aviso-sessao-inicio.ps1 (UserPromptSubmit), que grava o início do turno.
#
# O aviso é curto e sem conteúdo da sessão: o título, quanto tempo levou e um jeito de voltar a ela, conforme
# onde a sessão roda (VS Code, CLI/terminal, T3 Code) e, se houver, o link do Remote Control para o celular.
# Sai pela camada de envio do assistente (assistente.ps1 send), com o volante do despachante.
# Não avisa nas execuções do próprio despachante (ASSISTENTE_DESPACHADO=1).
# Log: ~/.assistente-wpp/state/avisos/aviso-sessao.log
param([ValidateSet('stop', 'wait', 'bgwait')][string]$Mode = 'stop', [int]$WaitSeconds = 60, [int]$IdleSeconds = 600, [int]$MaxSeconds = 43200, [string]$HoldFile, [switch]$DryRun)

$Utf8 = New-Object Text.UTF8Encoding $false
$HomeDir = if ($env:ASSISTENTE_HOME) { $env:ASSISTENTE_HOME } else { Join-Path $env:USERPROFILE '.assistente-wpp' }
$cfg = @{}
$cfgFile = if ($env:ASSISTENTE_CONFIG_FILE) { $env:ASSISTENTE_CONFIG_FILE } else { Join-Path $HomeDir 'assistente.env' }
if (Test-Path -LiteralPath $cfgFile) {
    foreach ($line in Get-Content -LiteralPath $cfgFile -Encoding UTF8) {
        $t = $line.Trim(); $i = $t.IndexOf('=')
        if ($t -and -not $t.StartsWith('#') -and $i -gt 0) { $cfg[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim() }
    }
}
function Get-Cfg([string]$Key, [string]$Default = '') { $v = [Environment]::GetEnvironmentVariable($Key); if ($v) { return $v }; if ($cfg[$Key]) { return $cfg[$Key] }; $Default }

$hold = $null
if ($Mode -eq 'bgwait') {
    try { $hold = [IO.File]::ReadAllText($HoldFile) | ConvertFrom-Json -ErrorAction Stop } catch { exit 0 }
    $data = $hold.data
    if ($hold.entrypoint) { $env:CLAUDE_CODE_ENTRYPOINT = [string]$hold.entrypoint }
}
else {
    $raw = [Console]::In.ReadToEnd()
    try { $data = $raw | ConvertFrom-Json -ErrorAction Stop } catch { exit 0 }
}
$sid = [string]$data.session_id
if (-not $sid) { exit 0 }
if ($env:ASSISTENTE_DESPACHADO) { exit 0 }                       # execução do despachante: não é sessão do dono
if ((Get-Cfg 'ASSISTENTE_AVISO_SESSAO' '1') -eq '0') { exit 0 }  # desligado pelo dono
$MinSeconds = [int](Get-Cfg 'ASSISTENTE_AVISO_MIN_SEG' '60')

$stateRoot = Get-Cfg 'ASSISTENTE_STATE_DIR' (Join-Path $HomeDir 'state')
$stateDir = Join-Path $stateRoot 'avisos'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$log = Join-Path $stateDir 'aviso-sessao.log'
$failFile = Join-Path $stateDir 'ultima-falha.txt'
function Log([string]$m) {
    try {
        if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 1MB) { Move-Item -LiteralPath $log -Destination "$log.old" -Force }
        Add-Content -LiteralPath $log -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " [$sid] $m") -Encoding UTF8
    } catch {}
}
function Fail([string]$why) {
    Log "FALHA: $why"
    if (-not $DryRun) { try { [IO.File]::WriteAllText($failFile, ((Get-Date -Format 'dd/MM HH:mm') + ' ' + $why), $Utf8) } catch {} }
    exit 0
}

$startFile = Join-Path $stateDir ("turno-" + $sid + ".txt")
function Read-Start { try { "$([IO.File]::ReadAllText($startFile))".Trim() } catch { '' } }
function Test-SameTurn { (Read-Start) -eq $startRaw }
$tp = [string]$data.transcript_path
$holdPath = Join-Path $stateDir ("bg-" + $sid + ".json")
function Read-HoldNonce { try { [string]([IO.File]::ReadAllText($holdPath) | ConvertFrom-Json).nonce } catch { '' } }

if ($Mode -eq 'bgwait') {
    $startRaw = [string]$hold.start
    $bgKinds = [string]$hold.kinds
    $sideDir = if ($tp) { Join-Path (Split-Path -Parent $tp) $sid } else { $null }
    $deadline = [DateTime]::UtcNow.AddSeconds($MaxSeconds)
    while ($true) {
        Start-Sleep -Seconds 30
        if ((Read-HoldNonce) -ne [string]$hold.nonce) { exit 0 }   # outro Stop assumiu
        if (-not (Test-SameTurn)) { Log 'bg: prompt novo, aviso adiado descartado'; Remove-Item -LiteralPath $holdPath -Force -ErrorAction SilentlyContinue; exit 0 }
        if ([DateTime]::UtcNow -gt $deadline) { Log 'bg: tempo máximo, aviso adiado descartado'; Remove-Item -LiteralPath $holdPath -Force -ErrorAction SilentlyContinue; exit 0 }
        $last = if ($tp -and (Test-Path -LiteralPath $tp)) { (Get-Item -LiteralPath $tp).LastWriteTimeUtc } else { [DateTime]::MinValue }
        if ($sideDir -and (Test-Path -LiteralPath $sideDir)) {
            $side = Get-ChildItem -LiteralPath $sideDir -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            if ($side -and $side.LastWriteTimeUtc -gt $last) { $last = $side.LastWriteTimeUtc }
        }
        if (([DateTime]::UtcNow - $last).TotalSeconds -ge $IdleSeconds) { break }
    }
    Remove-Item -LiteralPath $holdPath -Force -ErrorAction SilentlyContinue
    $start = 0L
    if (-not [long]::TryParse($startRaw, [ref]$start) -or $start -le 0) { exit 0 }
    if (Test-SameTurn) { Remove-Item -LiteralPath $startFile -Force -ErrorAction SilentlyContinue }
    $elapsed = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $start
    $idleMin = [Math]::Floor($IdleSeconds / 60)
}
elseif ($Mode -eq 'wait') {
    if (-not $tp -or -not (Test-Path -LiteralPath $tp)) { exit 0 }
    $waitFile = Join-Path $stateDir ("espera-" + $sid + ".txt")
    if ((Test-Path -LiteralPath $waitFile) -and (Get-Item -LiteralPath $waitFile).LastWriteTimeUtc -gt [DateTime]::UtcNow.AddMinutes(-2)) { exit 0 }
    $before = (Get-Item -LiteralPath $tp).LastWriteTimeUtc
    if (-not $DryRun) { Start-Sleep -Seconds $WaitSeconds }
    if ((Get-Item -LiteralPath $tp).LastWriteTimeUtc -ne $before) { exit 0 }   # o dono respondeu: a sessão andou
    try { [IO.File]::WriteAllText($waitFile, '') } catch {}
    $waitWhat = if (([string]$data.notification_type) -eq 'permission_prompt') { 'sua autorização' } else { 'uma resposta sua' }
    $elapsed = $WaitSeconds
    $startRaw = Read-Start
}
else {
    $bg = @($data.background_tasks | Where-Object { $_ })
    if (-not (Test-Path -LiteralPath $startFile)) { Remove-Item -LiteralPath $holdPath -Force -ErrorAction SilentlyContinue; exit 0 }
    $startRaw = Read-Start
    if ($bg.Count -gt 0) {
        # Turno encerrado com trabalho em background: em geral a sessão acorda sozinha e o Stop seguinte avisa.
        # Um vigia desligado da árvore do hook cobre o caso de ela não acordar.
        $kinds = ($bg | ForEach-Object { $_.type }) -join ', '
        Log ("background aberto ({0}: {1}), aviso adiado" -f $bg.Count, $kinds)
        if ($DryRun) { exit 0 }
        $holdObj = [ordered]@{ nonce = [guid]::NewGuid().ToString('N'); start = $startRaw; kinds = $kinds; entrypoint = [string]$env:CLAUDE_CODE_ENTRYPOINT; data = $data }
        try { [IO.File]::WriteAllText($holdPath, ($holdObj | ConvertTo-Json -Depth 8 -Compress), $Utf8) } catch { Fail "não gravou o aviso adiado: $_" }
        $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode bgwait -HoldFile "{1}" -IdleSeconds {2} -MaxSeconds {3}' -f $PSCommandPath, $holdPath, $IdleSeconds, $MaxSeconds
        try {
            $si = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
            $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd; ProcessStartupInformation = $si }
            if ($r.ReturnValue -ne 0) { Fail "vigia do background não subiu ($($r.ReturnValue))" }
        } catch { Fail "vigia do background não subiu: $_" }
        exit 0
    }
    Remove-Item -LiteralPath $holdPath -Force -ErrorAction SilentlyContinue
    $start = 0L
    if (-not [long]::TryParse($startRaw, [ref]$start) -or $start -le 0) { Log "início inválido: '$startRaw'"; exit 0 }
    if (Test-SameTurn) { Remove-Item -LiteralPath $startFile -Force -ErrorAction SilentlyContinue }
    $elapsed = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $start
    if ($elapsed -lt $MinSeconds) { exit 0 }
    if ($elapsed -gt $MaxSeconds) { Log "duração fora da faixa: ${elapsed}s"; exit 0 }
}

# Título: o renomeado pelo dono vence o gerado automaticamente.
$title = $null; $bridge = $null
if ($tp -and (Test-Path -LiteralPath $tp)) {
    $custom = $null; $ai = $null
    foreach ($l in [IO.File]::ReadLines($tp)) {
        if ($l.StartsWith('{"type":"bridge-session"')) { try { $o = $l | ConvertFrom-Json; if ($o.bridgeSessionId) { $bridge = [string]$o.bridgeSessionId } } catch {} }
        elseif ($l.StartsWith('{"type":"custom-title"')) { try { $o = $l | ConvertFrom-Json; if ($o.customTitle) { $custom = [string]$o.customTitle } } catch {} }
        elseif ($l.StartsWith('{"type":"ai-title"')) { try { $o = $l | ConvertFrom-Json; if ($o.aiTitle) { $ai = [string]$o.aiTitle } } catch {} }
    }
    $title = if ($custom) { $custom } elseif ($ai) { $ai } else { $null }
}
if ($title) {
    $title = ($title -replace '[\*_~`]', '' -replace '\s+', ' ').Trim()   # sem formatação do WhatsApp
    if ($title.Length -gt 80) { $title = $title.Substring(0, 79).TrimEnd() + '…' }
}
$folder = Split-Path -Leaf ([string]$data.cwd)
if (-not $title) { $title = $folder + ' ' + $sid.Substring(0, [Math]::Min(8, $sid.Length)) }

$h = [Math]::Floor($elapsed / 3600); $m = [Math]::Floor(($elapsed % 3600) / 60); $s = $elapsed % 60
$dur = if ($h -gt 0) { "${h}h ${m}min" } else { "${m}min ${s}s" }
$text = if ($Mode -eq 'wait') { "A sessão *$title* está esperando $waitWhat." } else { "A sessão *$title* parou e espera você ($dur)." }
if ($Mode -eq 'bgwait') { $text += " Ficou trabalho em background aberto ($bgKinds), sem atividade há ${idleMin}min." }

# Como voltar à sessão, conforme onde ela roda. ASSISTENTE_AVISO_EDITOR força um (vscode | cli | t3); auto = detecta.
$ep = [string]$env:CLAUDE_CODE_ENTRYPOINT
$editor = Get-Cfg 'ASSISTENTE_AVISO_EDITOR' 'auto'
if ($editor -eq 'auto') {
    $editor = if ($ep -eq 'claude-vscode') { 'vscode' } elseif ($ep -like 'sdk*') { 't3' } else { 'cli' }
}
$linkTpl = Get-Cfg 'ASSISTENTE_AVISO_LINK'
if ($linkTpl) {
    # Modelo próprio do dono: {session} e {cwd} são substituídos (ex.: um deep link do app que ele usa).
    $text += "`nAbrir: " + ($linkTpl.Replace('{session}', [Uri]::EscapeDataString($sid)).Replace('{cwd}', [Uri]::EscapeDataString([string]$data.cwd)))
}
elseif ($editor -eq 'vscode' -and $sid -match '^[0-9a-fA-F-]{36}$') {
    # O WhatsApp não deixa vscode:// clicável; o redirect https do vscode.dev repassa para o VS Code local.
    $target = [Uri]::EscapeDataString("vscode://anthropic.claude-code/open?session=$sid")
    $text += "`nPC (VS Code): https://vscode.dev/redirect?url=$target"
}
elseif ($editor -eq 't3') {
    $text += "`nPC (T3 Code): abra a conversa *$title* no T3 Code (pasta $folder)."
}
else {
    # CLI: não há link clicável para um terminal; vai o comando para retomar.
    $text += "`nPC (terminal), na pasta ${folder}: ``claude --resume $sid``"
}
# Remote Control: o ID cse_ vira session_ no link do claude.ai.
if ($bridge -match '^(cse|session)_[A-Za-z0-9]+$') {
    $text += "`nCelular (Remote Control): https://claude.ai/code/session_" + ($bridge -replace '^(cse|session)_', '')
}

if ($DryRun) { Log "DRY-RUN: $text"; Write-Output $text; exit 0 }

$scripts = $PSScriptRoot
$notify = Get-Cfg 'ASSISTENTE_AVISO_JID' (Get-Cfg 'ASSISTENTE_CONTA_JID')
if (-not $notify) { Fail 'assistente não configurado (sem ASSISTENTE_CONTA_JID)' }
try {
    $st = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts 'assistente-despachante.ps1') -Mode status | Out-String | ConvertFrom-Json
    $token = [long]$st.token
} catch { Fail "status do despachante falhou: $_" }
if ($token -le 0) { Fail 'despachante sem volante (parado?)' }
if ($Mode -ne 'wait' -and (Test-Path -LiteralPath $startFile) -and -not (Test-SameTurn)) { Log "${elapsed}s: prompt novo antes do envio, aviso descartado"; exit 0 }

Log "${elapsed}s: enviando"
try { $out = & (Join-Path $scripts 'assistente.ps1') send -Chat $notify -Text $text -Operator claude -Token $token | Out-String } catch { Fail "assistente.ps1 send: $_" }
$flat = ($out -replace '\s+', ' ').Trim()
Log "${elapsed}s -> $flat"
$r = $null; try { $r = $out | ConvertFrom-Json } catch {}
if (-not ($r -and $r.sent)) { Fail ("envio recusado: " + $(if ($r.reason) { $r.reason } else { $flat })) }
exit 0
