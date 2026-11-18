<#
Despachante do assistente-wpp: o assistente funcionando sem sessão aberta.

Em repouso são dois processos leves: este laço e o detector (`assistente.ps1 watch`). Só quando o
detector emite uma linha (EVENT / ERRO / RECOVERED) ou vence um retorno prometido, ele abre o
Claude sem tela (`claude -p`), entrega o lote, espera terminar e volta ao repouso.

Ele também segura o volante (lease, operador `claude`) e o renova a cada minuto, inclusive
enquanto o Claude trabalha. O token fica em `despachante.json`, para uma sessão interativa usar o
mesmo volante quando o dono pedir algo direto.

  assistente-despachante.ps1 [-Mode run]     laço principal (o que o vigia sobe, sem janela)
  assistente-despachante.ps1 -Mode start     sobe o laço escondido, se ainda não estiver de pé
  assistente-despachante.ps1 -Mode status    JSON: rodando?, pid, token, última execução
  assistente-despachante.ps1 -Mode stop      derruba o laço e o detector dele
  assistente-despachante.ps1 -Mode enqueue -Line "MANUAL ..."   linha manual para o próximo lote
  -DryRun                                    não chama o Claude: grava no log o prompt que mandaria

Respeita a pausa (`assistente.ps1 pause on`): com ela, desliga o detector e espera.
O único envio próprio dele é o aviso ao dono quando o Claude falha várias vezes seguidas.
#>
param(
    [ValidateSet('run', 'start', 'stop', 'status', 'enqueue')][string]$Mode = 'run',
    [string]$Line,
    [int]$DebounceSeconds = 8,
    [int]$DueCheckSeconds = 60,
    [int]$LeaseRenewSeconds = 60,
    [int]$RunTimeoutMinutes = 15,
    [int]$SessionRotateHours = 6,
    [int]$RedispatchDueMinutes = 30,
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
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$S = Join-Path $PSScriptRoot 'assistente.ps1'
$Self = $PSCommandPath
$StatePath = Join-Path $StateDir 'despachante.json'
$LogPath = Join-Path $StateDir 'despachante.log'
$PausePath = Join-Path $StateDir 'assistente.pause'
$InboxPath = Join-Path $StateDir 'despachante-fila.txt'
$TaskName = 'AssistenteWppVigia'
$WorkDir = Get-Cfg 'ASSISTENTE_PASTA_TRABALHO' $env:USERPROFILE
$PermMode = Get-Cfg 'ASSISTENTE_CLAUDE_PERMISSAO' 'auto'   # auto | lista
$Notify = Get-Cfg 'ASSISTENTE_AVISO_JID' (Get-Cfg 'ASSISTENTE_CONTA_JID')
$AssistantName = Get-Cfg 'ASSISTENTE_NOME' 'assistente'
$OwnerName = Get-Cfg 'ASSISTENTE_DONO' 'o dono'
$Autonomy = Get-Cfg 'ASSISTENTE_AUTONOMIA' 'responder'

function Find-Claude {
    $c = Get-Cfg 'ASSISTENTE_CLAUDE_EXE'
    if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    $d = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path -LiteralPath $d) { return $d }
    $g = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($g) { return $g.Source }
    ''
}
$ClaudeExe = Find-Claude

function Iso([DateTimeOffset]$d) { $d.ToString('yyyy-MM-ddTHH:mm:ssK') }
function Now-Utc { [DateTimeOffset]::UtcNow }

function Write-Log([string]$Msg) {
    $l = '{0} {1}' -f ([DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ssK')), $Msg
    try {
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 1MB) { Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force }
        [IO.File]::AppendAllText($LogPath, $l + "`n", $Utf8)
    } catch { }
    if ($Mode -ne 'run') { Write-Host $l }
}

function Read-State {
    $st = $null
    if (Test-Path -LiteralPath $StatePath) { try { $st = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
    $h = [ordered]@{ pid = $null; started = $null; token = 0; session_id = $null; session_started = $null; runs = 0; last_run = $null; last_rc = $null; last_summary = $null; fail_streak = 0; last_alert = $null; dispatched = @{} }
    if ($st) {
        foreach ($p in $st.PSObject.Properties) {
            if ($p.Name -eq 'dispatched') { if ($p.Value) { foreach ($q in $p.Value.PSObject.Properties) { $h.dispatched[$q.Name] = $q.Value } } }
            else { $h[$p.Name] = $p.Value }
        }
    }
    $h
}
function Save-State($St) {
    $tmp = "$StatePath.tmp"
    [IO.File]::WriteAllText($tmp, ($St | ConvertTo-Json -Depth 5), $Utf8)
    Move-Item -LiteralPath $tmp -Destination $StatePath -Force
}

# Processo do despachante vivo? Confere pelo PID gravado e pela linha de comando (PID reaproveitado não engana).
function Get-RunningPid {
    $st = Read-State
    if (-not $st.pid) { return $null }
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$st.pid)" -ErrorAction SilentlyContinue
    if ($p -and $p.CommandLine -match 'assistente-despachante\.ps1' -and $p.CommandLine -notmatch '-Mode\s+(start|stop|status|enqueue)') { return [int]$st.pid }
    $null
}
function Stop-Tree([int]$ProcessId) { & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null }

# Chama assistente.ps1 no mesmo processo e devolve o JSON lido (ou $null).
function Invoke-Assistente([string]$Cmd, [string]$Act, [hashtable]$P = @{}) {
    try {
        $out = & $S $Cmd $Act @P 2>$null | Out-String
        if ($out.Trim()) { return ($out | ConvertFrom-Json) }
    } catch { Write-Log "assistente.ps1 $Cmd $Act falhou: $($_.Exception.Message)" }
    $null
}

# ---------- modos curtos ----------

if ($Mode -eq 'status') {
    $st = Read-State
    $running = Get-RunningPid
    [ordered]@{
        running = [bool]$running; pid = $running; paused = (Test-Path -LiteralPath $PausePath)
        operator = 'claude'; token = $st.token; started = $st.started
        runs = $st.runs; last_run = $st.last_run; last_rc = $st.last_rc; fail_streak = $st.fail_streak
        claude = $ClaudeExe; log = $LogPath
    } | ConvertTo-Json
    if ($running) { exit 0 } else { exit 2 }
}

if ($Mode -eq 'start') {
    $running = Get-RunningPid
    if ($running) { Write-Output "já está rodando (pid $running)"; exit 0 }
    if (Test-Path -LiteralPath $PausePath) { Write-Output 'pausado (assistente.pause): não subo'; exit 2 }
    # Pela tarefa agendada do vigia, quando existir: o despachante nasce fora da árvore de processos de quem pediu.
    # Subido de dentro de uma sessão do Claude, morreria junto quando a sessão fechasse.
    $viaTask = $false
    if (-not $env:ASSISTENTE_VIGIA_RUN) { try { Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop; $viaTask = $true } catch { } }
    if (-not $viaTask) {
        $argLine = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Self`" -Mode run"
        Start-Process -FilePath "$env:SystemRoot\System32\conhost.exe" -ArgumentList $argLine -WindowStyle Hidden
    }
    foreach ($i in 1..40) { Start-Sleep -Milliseconds 500; $running = Get-RunningPid; if ($running) { break } }
    if ($running) { Write-Output "subiu (pid $running)"; exit 0 }
    Write-Output "não confirmei a subida; veja $LogPath"; exit 1
}

if ($Mode -eq 'enqueue') {
    if (-not $Line -or $Line -notmatch '^(EVENT|ERRO|RECOVERED|MANUAL)') { Write-Output 'informe -Line começando com EVENT, ERRO, RECOVERED ou MANUAL'; exit 2 }
    [IO.File]::AppendAllText($InboxPath, $Line + "`n", $Utf8)
    Write-Log "linha manual na fila: $Line"
    Write-Output 'na fila'; exit 0
}

if ($Mode -eq 'stop') {
    $running = Get-RunningPid
    if (-not $running) { Write-Output 'não estava rodando'; exit 0 }
    Stop-Tree $running
    $st = Read-State
    if ($st.token) { $null = Invoke-Assistente 'lease' 'release' @{ Operator = 'claude'; Token = [long]$st.token } }
    $st.pid = $null; Save-State $st
    Write-Log "parado pelo modo stop (pid $running)"
    Write-Output "parado (pid $running)"; exit 0
}

# ---------- laço principal ----------

# Falha fechada: sem configuração pronta (ou com o despachante desligado por configuração) não roda.
$chk = Invoke-Assistente 'check' ''
if (-not $chk -or -not $chk.ready) { Write-Log ("configuração incompleta, não rodo: " + $(if ($chk) { $chk.problems -join '; ' } else { 'check falhou' })); exit 2 }
if ((Get-Cfg 'ASSISTENTE_DESPACHANTE' '1') -eq '0') { Write-Log 'ASSISTENTE_DESPACHANTE=0: não rodo'; exit 2 }
if (-not $ClaudeExe -and -not $DryRun) { Write-Log 'não achei o claude (ASSISTENTE_CLAUDE_EXE): não rodo'; exit 2 }

$mutex = New-Object Threading.Mutex($false, 'Local\AssistenteWppDespachante')
if (-not $mutex.WaitOne(0)) { exit 0 }   # já há um despachante nesta sessão do Windows

$state = Read-State
$prevLease = $null
try { $prevLease = Get-Content -LiteralPath (Join-Path $StateDir 'operator-lease.json') -Raw | ConvertFrom-Json } catch { }
$state.pid = $PID
$state.started = Iso (Now-Utc)
Save-State $state
Write-Log "despachante de pé (pid $PID, claude=$ClaudeExe, permissao=$PermMode, dryrun=$([bool]$DryRun))"

# Um detector só: derruba qualquer `assistente.ps1 watch` que não seja deste despachante.
function Stop-ForeignWatchers([int]$OwnChild = 0) {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
        $_.CommandLine -match 'assistente\.ps1"?\s+watch' -and $_.ProcessId -ne $OwnChild
    } | ForEach-Object { Write-Log "derrubando detector que não é deste despachante (pid $($_.ProcessId))"; Stop-Tree $_.ProcessId }
}

# Reconciliação inicial: se o volante ficou sem dono por mais de 5 min, o primeiro lote manda conferir o que chegou.
$reconcileSince = $null
if ($prevLease -and $prevLease.heartbeat_at) {
    $hb = [DateTimeOffset]::Parse($prevLease.heartbeat_at)
    if (((Now-Utc) - $hb).TotalMinutes -gt 5) { $reconcileSince = Iso $hb }
}

$script:Token = [long]0
function Update-Lease {
    if ($script:Token -gt 0) {
        $r = Invoke-Assistente 'lease' 'renew' @{ Operator = 'claude'; Token = $script:Token }
        if ($r -and $r.renewed) { return $true }
    }
    $r = Invoke-Assistente 'lease' 'acquire' @{ Operator = 'claude' }
    if ($r -and $r.granted) {
        if ([long]$r.fencing_token -ne $script:Token) { Write-Log "volante adquirido (token $($r.fencing_token))" }
        $script:Token = [long]$r.fencing_token
        $state.token = $script:Token; Save-State $state
        return $true
    }
    if ($r) { Write-Log "volante com outro operador ($($r.holder)) até $($r.expires_at): não despacho" }
    $false
}

function Start-Watcher {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$S`" watch"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $p = [Diagnostics.Process]::Start($psi)
    $null = $p.StandardError.ReadToEndAsync()   # não deixa o buffer de erro travar o detector
    Write-Log "detector de pé (pid $($p.Id))"
    $p
}

function Build-Prompt($Lines, $DueFollowups, [string]$ReconcileFrom) {
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('[assistente-wpp - modo despachado]')
    [void]$sb.AppendLine("Quem te acordou foi o despachante do assistente de WhatsApp de $OwnerName ($AssistantName), numa execução sem terminal.")
    [void]$sb.AppendLine('- Carregue a skill assistente-wpp (ferramenta Skill) e siga a seção "Modo despachado", além das regras de sempre.')
    [void]$sb.AppendLine('- NÃO rode `watch`, NÃO faça `lease acquire`/`release` e NÃO use CronCreate/ScheduleWakeup: o despachante cuida do detector, do volante e dos vencimentos.')
    [void]$sb.AppendLine("- O volante já é seu: -Operator claude -Token $($script:Token). Se um ``send`` recusar por lease, pare e diga isso no resumo.")
    [void]$sb.AppendLine('- Retorno prometido: só `followup add`. O despachante te acorda no vencimento.')
    [void]$sb.AppendLine('- Termine com um resumo curto: uma linha por item, dizendo o que fez ou por que não fez. Sem conversa na íntegra.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Autorização do dono ($OwnerName), dada ao instalar e configurar o assistente (ASSISTENTE_AUTONOMIA=$Autonomy):")
    if ($Autonomy -eq 'responder') { [void]$sb.AppendLine('- O assistente responde sozinho, pelo `assistente.ps1 send`, a quem é do time, dentro das regras da skill.') }
    else { [void]$sb.AppendLine('- Modo triagem: o assistente NÃO responde ao time sozinho. Leia, resuma e leve ao dono pela conversa de avisos; o `send` recusa o resto.') }
    [void]$sb.AppendLine('- Avisos ao dono pela conversa de avisos (ASSISTENTE_AVISO_JID) são sempre permitidos.')
    [void]$sb.AppendLine('- Linha `EVENT dono`: é o dono escrevendo na conversa consigo mesmo. Leia e trate como pedido dele, dentro das regras da skill (envio que ele pedir explicitamente ali pode usar `-OwnerRequested`).')
    [void]$sb.AppendLine('- Continua proibido: iniciar conversa com quem não escreveu sem pedido do dono, falar com quem está fora do time, e qualquer ação fora de conversar (merge, card, acesso) sem ok explícito do dono.')
    [void]$sb.AppendLine('')
    if ($ReconcileFrom) {
        [void]$sb.AppendLine("Reconciliação: o volante ficou sem dono desde $ReconcileFrom (UTC). Confira as conversas do time com mensagem depois disso que ficaram sem resposta e atenda o que couber pelas regras de sempre. Avise o dono só se algo ficou sem resposta por mais de 30 min.")
        [void]$sb.AppendLine('')
    }
    if ($Lines.Count -gt 0) {
        [void]$sb.AppendLine('Linhas do detector (mais antiga primeiro):')
        foreach ($l in $Lines) { [void]$sb.AppendLine('  ' + $l) }
        [void]$sb.AppendLine('')
    }
    if (@($DueFollowups).Count -gt 0) {
        [void]$sb.AppendLine('Retornos prometidos vencidos (`followup due`): cumpra, conferindo antes se a conversa mudou; depois `followup done -Id <id>`.')
        [void]$sb.AppendLine(($DueFollowups | ConvertTo-Json -Depth 4 -Compress))
        [void]$sb.AppendLine('')
    }
    $sb.ToString()
}

function Start-ClaudeRun([string]$Prompt) {
    $resume = $null
    if ($state.session_id -and $state.session_started) {
        $age = ((Now-Utc) - [DateTimeOffset]::Parse([string]$state.session_started)).TotalHours
        if ($age -lt $SessionRotateHours) { $resume = [string]$state.session_id }
    }
    $cargs = @('-p', '--output-format', 'json', '-n', "$AssistantName (despachado)")
    if ($PermMode -eq 'lista') {
        # Sem o modo auto: libera só o necessário para conversar e conferir estado.
        $cargs += @('--allowedTools', 'Skill', 'Read', 'Glob', 'Grep', 'Bash(powershell*)', 'PowerShell', 'Bash(gh pr view*)', 'Bash(gh issue view*)', 'Bash(gh pr list*)', 'Bash(gh pr checks*)', 'mcp__whatsapp__get_chat_messages', 'mcp__whatsapp__transcribe_audio', 'mcp__whatsapp__download_media', 'mcp__whatsapp__list_contacts')
    }
    else { $cargs += @('--permission-mode', 'auto') }
    if ($resume) { $cargs += @('--resume', $resume) }
    # Argumentos extras do dono (ex.: --model, --strict-mcp-config), separados por espaço.
    $extra = Get-Cfg 'ASSISTENTE_CLAUDE_ARGS'
    if ($extra) { $cargs += @($extra -split '\s+' | Where-Object { $_ }) }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $ClaudeExe
    $psi.Arguments = ($cargs | ForEach-Object { if ($_ -match '[\s()*]') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding = $Utf8
    # Marca a execução como do despachante: os hooks de aviso de sessão a ignoram (não é sessão do dono).
    $psi.EnvironmentVariables['ASSISTENTE_DESPACHADO'] = '1'
    $p = [Diagnostics.Process]::Start($psi)
    # O prompt vai como bytes UTF-8: o StandardInput do .NET Framework usaria a página de código do console.
    $bytes = $Utf8.GetBytes($Prompt)
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $p.StandardInput.Close()
    [ordered]@{ proc = $p; out = $p.StandardOutput.ReadToEndAsync(); err = $p.StandardError.ReadToEndAsync(); started = (Now-Utc); resumed = [bool]$resume }
}

function Send-OwnerAlert([string]$Text) {
    if (-not $Notify -or $script:Token -le 0) { return }
    $r = Invoke-Assistente 'send' '' @{ Chat = $Notify; Text = $Text; Operator = 'claude'; Token = $script:Token }
    if ($r -and $r.sent) { Write-Log 'aviso enviado ao dono' } else { Write-Log 'não consegui avisar o dono' }
}

function Complete-ClaudeRun($Run, $Batch) {
    $rc = $Run.proc.ExitCode
    $out = ''; $err = ''
    try { $out = $Run.out.Result } catch { }
    try { $err = $Run.err.Result } catch { }
    $j = $null
    try { $j = $out | ConvertFrom-Json } catch { }
    $ok = ($rc -eq 0 -and $j -and -not $j.is_error)
    $secs = [int]((Now-Utc) - $Run.started).TotalSeconds
    $state.runs = [int]$state.runs + 1
    $state.last_run = Iso (Now-Utc)
    $state.last_rc = $rc
    if ($j -and $j.session_id) {
        if (-not $Run.resumed -or $state.session_id -ne $j.session_id) { $state.session_started = Iso (Now-Utc) }
        $state.session_id = $j.session_id
    }
    if ($ok) {
        $sum = [string]$j.result
        if ($sum.Length -gt 400) { $sum = $sum.Substring(0, 400) + '…' }
        $state.last_summary = $sum
        $state.fail_streak = 0
        Write-Log ("lote ok em {0}s (custo US$ {1}): {2}" -f $secs, $j.total_cost_usd, ($sum -replace '\s+', ' '))
        foreach ($k in $Batch.dueKeys) { $state.dispatched[$k] = Iso (Now-Utc) }
    }
    else {
        $state.fail_streak = [int]$state.fail_streak + 1
        $why = if ($j -and $j.result) { [string]$j.result } elseif ($err) { $err } else { $out }
        if ($why.Length -gt 300) { $why = $why.Substring(0, 300) }
        Write-Log ("lote FALHOU (rc {0}, {1}s, seguidas {2}): {3}" -f $rc, $secs, $state.fail_streak, ($why -replace '\s+', ' '))
        if ($Run.resumed) { $state.session_id = $null; $state.session_started = $null }   # próxima tentativa em sessão nova
        if ($state.fail_streak -ge 3) {
            $last = if ($state.last_alert) { [DateTimeOffset]::Parse([string]$state.last_alert) } else { $null }
            if (-not $last -or ((Now-Utc) - $last).TotalMinutes -ge 30) {
                Send-OwnerAlert ("ALERTA: o despachante não consegue rodar o Claude ($($state.fail_streak) falhas seguidas). As mensagens do time continuam chegando, mas ficam sem resposta. Log: $LogPath")
                $state.last_alert = Iso (Now-Utc)
            }
        }
    }
    Save-State $state
    $ok
}

# ---------- laço ----------
$watch = $null
$pending = $null
$queue = New-Object Collections.Generic.List[string]
$lastLineAt = [DateTimeOffset]::MinValue
$lastDueCheck = [DateTimeOffset]::MinValue
$lastLease = [DateTimeOffset]::MinValue
$run = $null
$batch = $null
$retryAt = [DateTimeOffset]::MinValue
$dueF = @(); $dueKeys = @()

Stop-ForeignWatchers
while ($true) {
    try {
        $now = Now-Utc

        if (Test-Path -LiteralPath $PausePath) {
            if ($watch -and -not $watch.HasExited) { Write-Log 'pausa ligada: detector desligado'; Stop-Tree $watch.Id }
            $watch = $null; $pending = $null
            Start-Sleep -Seconds 30
            continue
        }

        if (-not $watch -or $watch.HasExited) {
            if ($watch) { Write-Log "detector caiu (rc $($watch.ExitCode)); subindo de novo" ; Start-Sleep -Seconds 5 }
            Stop-ForeignWatchers
            $watch = Start-Watcher
            $pending = $watch.StandardOutput.ReadLineAsync()
        }
        while ($pending -and $pending.IsCompleted) {
            $l = $pending.Result
            if ($null -eq $l) { $pending = $null; break }
            if ($l -match '^(EVENT|ERRO|RECOVERED)') { $queue.Add($l); $lastLineAt = $now }
            elseif ($l.Trim()) { Write-Log "detector: $l" }
            $pending = $watch.StandardOutput.ReadLineAsync()
        }

        if (Test-Path -LiteralPath $InboxPath) {
            $tmpIn = "$InboxPath.$PID"
            try {
                Move-Item -LiteralPath $InboxPath -Destination $tmpIn -Force
                foreach ($l in [IO.File]::ReadAllLines($tmpIn, $Utf8)) { if ($l.Trim()) { $queue.Add($l.Trim()); $lastLineAt = $now } }
                Remove-Item -LiteralPath $tmpIn -Force
            } catch { Write-Log "falha ao ler a fila manual: $($_.Exception.Message)" }
        }

        if (($now - $lastLease).TotalSeconds -ge $LeaseRenewSeconds) { $null = Update-Lease; $lastLease = $now }

        if (-not $run -and ($now - $lastDueCheck).TotalSeconds -ge $DueCheckSeconds) {
            $lastDueCheck = $now
            $dueF = @(); $dueKeys = @()
            $f = Invoke-Assistente 'followup' 'due'
            foreach ($i in @($f.due)) {
                if (-not $i) { continue }
                $k = "fu:$($i.id)"
                $prev = $state.dispatched[$k]
                if (-not $prev -or ($now - [DateTimeOffset]::Parse([string]$prev)).TotalMinutes -ge $RedispatchDueMinutes) { $dueF += $i; $dueKeys += $k }
            }
        }

        if ($run) {
            if ($run.proc.HasExited) {
                $ok = Complete-ClaudeRun $run $batch
                if (-not $ok) {
                    for ($i = $batch.lines.Count - 1; $i -ge 0; $i--) { $queue.Insert(0, $batch.lines[$i]) }
                    if ($batch.reconcile) { $reconcileSince = $batch.reconcile }
                    $retryAt = $now.AddSeconds(60)
                }
                $run = $null; $batch = $null
            }
            elseif (($now - $run.started).TotalMinutes -ge $RunTimeoutMinutes) {
                Write-Log "lote passou de $RunTimeoutMinutes min: encerrando o Claude"
                Stop-Tree $run.proc.Id
            }
        }

        $settled = ($queue.Count -gt 0 -and ($now - $lastLineAt).TotalSeconds -ge $DebounceSeconds)
        $hasWork = $settled -or $dueF.Count -gt 0 -or $reconcileSince
        if (-not $run -and $hasWork -and $now -ge $retryAt -and $script:Token -gt 0) {
            $lines = @($queue.ToArray()); $queue.Clear()
            $prompt = Build-Prompt $lines $dueF $reconcileSince
            $batch = [ordered]@{ lines = $lines; dueKeys = $dueKeys; reconcile = $reconcileSince }
            $reconcileSince = $null
            $desc = "linhas=$($lines.Count) retornos=$($dueF.Count) reconciliar=$([bool]$batch.reconcile)"
            $dueF = @(); $dueKeys = @()
            if ($DryRun) {
                Write-Log "DRY-RUN lote ($desc). Prompt:`n$prompt"
                foreach ($k in $batch.dueKeys) { $state.dispatched[$k] = Iso $now }
                Save-State $state
                $batch = $null
            }
            else {
                Write-Log "abrindo o Claude ($desc)"
                $run = Start-ClaudeRun $prompt
            }
        }
    }
    catch { Write-Log "erro no laço: $($_.Exception.Message)"; Start-Sleep -Seconds 5 }
    Start-Sleep -Milliseconds 500
}
