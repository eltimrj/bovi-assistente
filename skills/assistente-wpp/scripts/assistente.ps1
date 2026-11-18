<#
assistente-wpp: utilitários determinísticos do assistente de WhatsApp de cada dev.
Nenhum deles chama modelo de IA. Só `send` envia mensagem, e só com o volante (lease) válido.

  assistente.ps1 help [-Json]                                manual: o que o assistente faz, o que está ativo/inativo e como mudar
  assistente.ps1 setup [-Name "<nome do assistente>"] [-Owner "<seu nome>"] [-Jid <linked_jid>|auto] [-Mode responder|triagem] [-Fuso GMT-3] [-Genero feminino|masculino|neutro]
                                                             grava/atualiza a configuração privada; -Jid auto lê do app
  assistente.ps1 now [-Due <RFC 3339>]                      hora agora (ou a de -Due) no fuso do dono e no do time
  assistente.ps1 check                                       a configuração está pronta? (rc 0 = sim; lista o que falta)
  assistente.ps1 persona list | use -Name <preset> [-Force] | show
                                                             personalidades prontas; `use` copia o preset para a sua persona
  assistente.ps1 prefix -Text "<mensagem>"                  prefixo *<Nome>:* uma única vez
  assistente.ps1 lease acquire|renew|release|check|status -Operator claude|codex [-Token <n>] [-TtlSeconds 180]
  assistente.ps1 sent -Chat <jid> -MessageId <id>           registra mensagem enviada pelo assistente
  assistente.ps1 is-ours -MessageId <id>                    0 = enviada pelo assistente; 1 = não
  assistente.ps1 watch [-IntervalSeconds 30] [-Once]        detector de mensagens novas, sem IA
  assistente.ps1 account                                    confere se a conta conectada no app é a configurada
  assistente.ps1 messages -Chat <jid> [-Since <RFC 3339>] [-Limit 30]
  assistente.ps1 send -Chat <jid> -Text "<mensagem>" -Operator <op> -Token <n> [-DryRun] [-OwnerRequested] [-NewContactConfirmed]
                                                             camada de envio: pausa + lease + travas + conta + prefixo + registro
  assistente.ps1 team [-Chat <jid>]                         equipe (arquivo privado); com -Chat, quem é
  assistente.ps1 allow add|remove|list -Chat <jid> [-Name ".."] [-Note ".."] [-Due <RFC 3339>]
                                                             pedido explícito do dono: responder a alguém fora do time ou num grupo
  assistente.ps1 hold on|off|list [-Chat <jid>|all] [-Note ".."]   conversas que o dono assumiu (assistente em silêncio)
  assistente.ps1 pause on|off|status [-Note ".."]           desliga de propósito (despachante, vigia e send respeitam)
  assistente.ps1 intro-needed -Chat <jid>                   apresentar? (a pessoa nunca recebeu mensagem do assistente)
  assistente.ps1 heartbeat [-MaxAgeSeconds 120]             saúde do detector (rc 0 = vivo, 2 = parado)
  assistente.ps1 followup add -Chat <jid> -Due <RFC 3339> -Note ".." | list | due | done -Id <id>
  assistente.ps1 resolve -Name "<nome>"                     candidatos com nome igual ou foneticamente parecido
  assistente.ps1 name-key -Text <palavra> | name-match -Text <a> -Name <b>
  assistente.ps1 config                                     configuração efetiva, valores mascarados

Configuração: ~/.assistente-wpp/assistente.env (ver ../.env.example). Variáveis de ambiente com o
mesmo nome têm precedência. Código de saída 2 = recusado; 1 = erro.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('help', 'setup', 'check', 'persona', 'prefix', 'lease', 'sent', 'is-ours', 'watch', 'account', 'messages', 'send', 'config', 'resolve', 'name-key', 'name-match', 'heartbeat', 'followup', 'pause', 'intro-needed', 'team', 'allow', 'hold', 'now')]
    [string]$Command,
    [Parameter(Position = 1)][string]$Action,
    [string]$Text,
    [ValidateSet('', 'claude', 'codex')][string]$Operator = '',
    [long]$Token = 0, [int]$TtlSeconds = 180,
    [string]$Id, [string]$Chat, [string]$MessageId, [string]$Since, [int]$Limit = 30,
    [string]$Name, [string]$Owner, [string]$Jid, [ValidateSet('', 'responder', 'triagem')][string]$Mode = '', [string]$Fuso,
    [ValidateSet('', 'feminino', 'masculino', 'neutro')][string]$Genero = '',
    [string]$Due, [string]$Note, [int]$MaxAgeSeconds = 120,
    [int]$IntervalSeconds = 30, [switch]$Once, [switch]$DryRun, [switch]$NewContactConfirmed, [switch]$OwnerRequested, [switch]$Force, [switch]$Json
)

$ErrorActionPreference = 'Stop'
$script:Rc = 1
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$Utf8 = New-Object Text.UTF8Encoding $false
. (Join-Path $PSScriptRoot 'plataforma.ps1')

# ---------- configuração ----------

function Read-EnvFile([string]$Path) {
    $cfg = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) { return $cfg }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $cfg[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
    }
    $cfg
}

$HomeDir = if ($env:ASSISTENTE_HOME) { $env:ASSISTENTE_HOME } else { Join-Path $HOME '.assistente-wpp' }
$ConfigPath = if ($env:ASSISTENTE_CONFIG_FILE) { $env:ASSISTENTE_CONFIG_FILE } else { Join-Path $HomeDir 'assistente.env' }
$FileCfg = Read-EnvFile $ConfigPath
function Get-Cfg([string]$Key, [string]$Default = '') {
    $v = [Environment]::GetEnvironmentVariable($Key)
    if ($v) { return $v }
    if ($FileCfg.Contains($Key) -and $FileCfg[$Key]) { return $FileCfg[$Key] }
    $Default
}

$StateDir = Get-Cfg 'ASSISTENTE_STATE_DIR' (Join-Path $HomeDir 'state')
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$SkillDir = Split-Path $PSScriptRoot -Parent
$PresetDir = Join-Path (Join-Path $SkillDir 'references') 'personalidades'

$AssistantName = Get-Cfg 'ASSISTENTE_NOME'
$OwnerName = Get-Cfg 'ASSISTENTE_DONO'
$AccountJid = Get-Cfg 'ASSISTENTE_CONTA_JID'
$McpUrl = Get-Cfg 'ASSISTENTE_MCP_URL' 'http://127.0.0.1:47821/mcp'
$McpToken = Get-Cfg 'ASSISTENTE_MCP_TOKEN'
$NotifyJid = Get-Cfg 'ASSISTENTE_AVISO_JID' $AccountJid   # padrão: a conversa consigo mesmo
$Autonomy = Get-Cfg 'ASSISTENTE_AUTONOMIA' 'responder'
$TeamPath = Get-Cfg 'ASSISTENTE_EQUIPE' (Join-Path $HomeDir 'equipe.json')
$PersonaPath = Get-Cfg 'ASSISTENTE_PERSONA' (Join-Path $HomeDir 'persona.md')
$HoldMinutes = [int](Get-Cfg 'ASSISTENTE_ESPERA_MIN' '15')
$TeamFusoName = Get-Cfg 'ASSISTENTE_FUSO_TIME' 'GMT-3'   # o fuso em que o time trabalha
$OwnerFusoName = Get-Cfg 'ASSISTENTE_FUSO' $TeamFusoName  # o fuso em que o dono quer ver os horários

# Fuso: "GMT-3", "UTC+1", "GMT+5:30" (fixo) ou um id do Windows ("E. South America Standard Time", "GMT Standard Time").
function Resolve-Fuso([string]$Value) {
    $v = ([string]$Value).Trim()
    if ($v -match '^(?:GMT|UTC)\s*([+-])\s*(\d{1,2})(?::?(\d{2}))?$') {
        $h = [int]$Matches[2]; $m = if ($Matches[3]) { [int]$Matches[3] } else { 0 }
        if ($h -gt 14 -or $m -ge 60) { throw "fuso inválido: $Value" }
        $off = New-Object TimeSpan ($h, $m, 0); if ($Matches[1] -eq '-') { $off = $off.Negate() }
        $label = 'GMT' + $Matches[1] + $h + $(if ($m) { ':' + $m.ToString('00') } else { '' })
        return [TimeZoneInfo]::CreateCustomTimeZone($label, $off, $label, $label)
    }
    if ($v -match '^(?:GMT|UTC)$') { return [TimeZoneInfo]::Utc }
    try { return [TimeZoneInfo]::FindSystemTimeZoneById($v) } catch { throw "fuso inválido: $Value (use GMT-3, UTC+1 ou um id do Windows)" }
}
function Get-FusoLabel($Tz, [DateTimeOffset]$At) {
    if ($Tz.Id -match '^GMT[+-]\d') { return $Tz.Id }
    $o = $Tz.GetUtcOffset($At)
    'GMT' + $(if ($o -lt [TimeSpan]::Zero) { '-' } else { '+' }) + [Math]::Abs($o.Hours) + $(if ($o.Minutes) { ':' + [Math]::Abs($o.Minutes).ToString('00') } else { '' })
}
function Format-InFuso([DateTimeOffset]$At, $Tz) {
    $l = [TimeZoneInfo]::ConvertTime($At, $Tz)
    $pt = [Globalization.CultureInfo]::GetCultureInfo('pt-BR')
    [ordered]@{ fuso = (Get-FusoLabel $Tz $At); data_hora = $l.ToString('dd/MM/yyyy HH:mm'); dia = $pt.DateTimeFormat.GetDayName($l.DayOfWeek); iso = $l.ToString('yyyy-MM-ddTHH:mm:sszzz') }
}

function Out-Json($Obj) { $Obj | ConvertTo-Json -Depth 6 -Compress:$false }
function Now-Utc { [DateTimeOffset]::UtcNow }
function Iso([DateTimeOffset]$d) { $d.ToString('yyyy-MM-ddTHH:mm:ssK') }
function Mask([string]$J) { if (-not $J) { return '' }; $d = $J -replace '@.*$', ''; '****' + $d.Substring([Math]::Max(0, $d.Length - 4)) }

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}
function Write-JsonFile([string]$Path, $Obj) {
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, ($Obj | ConvertTo-Json -Depth 6), $Utf8)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# Exclusão mútua entre processos (despachante, sessão interativa, Codex).
function Invoke-Locked([string]$LockName, [scriptblock]$Body) {
    $lockPath = Join-Path $StateDir "$LockName.lock"
    $fs = $null
    for ($i = 0; $i -lt 100 -and $null -eq $fs; $i++) {
        try { $fs = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch { Start-Sleep -Milliseconds 100 }
    }
    if ($null -eq $fs) { throw "lock '$LockName' indisponível" }
    try { & $Body } finally { $fs.Dispose() }
}

# ---------- nome do assistente ----------

# Nomes reservados, guardados só como SHA-256 do nome normalizado. O nome escolhido é recusado se qualquer
# trecho dele bater com um reservado. Não há lista legível de propósito.
$ReservedNameHashes = @(
    'ef4a2a63283303307a57bdb359af6ec4ea3b2af8b8e10a98f507052c0e5c67eb',
    'd4ef876bcb7ec1b7cee87c1f0738f326997b92325d25dc50acef27e68a1951a3'
)
function Get-Sha256Hex([string]$S) {
    $h = [Security.Cryptography.SHA256]::Create().ComputeHash($Utf8.GetBytes($S))
    ($h | ForEach-Object { $_.ToString('x2') }) -join ''
}
function ConvertTo-PlainLower([string]$S) { (($S.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)) -replace '\p{M}', '') -replace '[^a-z0-9]', '' }

# '' = nome válido; senão, o motivo da recusa.
function Test-AssistantName([string]$N) {
    if (-not $N) { return 'nome_vazio' }
    $t = $N.Trim()
    if ($t.Length -lt 2 -or $t.Length -gt 24) { return 'nome_deve_ter_de_2_a_24_caracteres' }
    if ($t -notmatch "^[\p{L}][\p{L}0-9 '\-]*$") { return 'nome_so_com_letras_numeros_espaco_hifen' }
    $p = ConvertTo-PlainLower $t
    for ($i = 0; $i -lt $p.Length; $i++) {
        for ($len = 3; $i + $len -le $p.Length; $len++) {
            if ($ReservedNameHashes -contains (Get-Sha256Hex $p.Substring($i, $len))) { return 'nome_reservado_escolha_outro' }
        }
    }
    ''
}

# ---------- prefixo ----------

# Remove qualquer prefixo já presente (*Nome:*, **Nome:**, Nome:) e põe exatamente um.
function Format-AssistantMessage([string]$Value) {
    if (-not $AssistantName) { throw 'sem ASSISTENTE_NOME: rode o setup antes' }
    $why = Test-AssistantName $AssistantName
    if ($why) { throw "ASSISTENTE_NOME inválido ($why)" }
    if ($null -eq $Value) { throw 'mensagem vazia' }
    $n = [regex]::Escape($AssistantName.Trim())
    $body = $Value.TrimStart()
    $pattern = '^(\*{1,2}\s*' + $n + '\s*:\s*\*{1,2}|' + $n + '\s*:)\s*'
    while ($body -match $pattern) { $body = [regex]::Replace($body, $pattern, '', 'IgnoreCase') }
    if ($body.Trim() -eq '') { throw 'mensagem vazia' }
    '*' + $AssistantName.Trim() + ':* ' + $body
}
function Get-PrefixText { '*' + $AssistantName.Trim() + ':*' }

# ---------- volante: um operador por vez ----------

$LeasePath = Join-Path $StateDir 'operator-lease.json'

function Invoke-Lease([string]$Act) {
    if ($Act -ne 'status' -and -not $Operator) { throw 'informe -Operator claude|codex' }
    Invoke-Locked 'operator-lease' {
        $now = Now-Utc
        $l = Read-JsonFile $LeasePath
        if ($null -eq $l) { $l = [pscustomobject]@{ owner = $null; lease_id = $null; fencing_token = 0; acquired_at = $null; heartbeat_at = $null; expires_at = $null; version = 0 } }
        $active = $l.owner -and $l.expires_at -and ([DateTimeOffset]::Parse($l.expires_at) -gt $now)
        $mine = $active -and $l.owner -eq $Operator -and ($Token -eq 0 -or $Token -eq [long]$l.fencing_token)
        switch ($Act) {
            'status' { Out-Json ([ordered]@{ active = [bool]$active; lease = $l }); $script:Rc = 0; return }
            'check' {
                $ok = $active -and $l.owner -eq $Operator -and $Token -eq [long]$l.fencing_token
                Out-Json ([ordered]@{ valid = [bool]$ok; owner = $l.owner; fencing_token = $l.fencing_token; expires_at = $l.expires_at })
                if ($ok) { $script:Rc = 0 } else { $script:Rc = 2 }; return
            }
            'acquire' {
                if ($active -and $l.owner -ne $Operator) { Out-Json ([ordered]@{ granted = $false; holder = $l.owner; expires_at = $l.expires_at }); $script:Rc = 2; return }
                if (-not ($active -and $l.owner -eq $Operator)) {
                    $l.fencing_token = [long]$l.fencing_token + 1
                    $l.lease_id = [guid]::NewGuid().ToString()
                    $l.acquired_at = Iso $now
                }
                $l.owner = $Operator; $l.heartbeat_at = Iso $now; $l.expires_at = Iso ($now.AddSeconds($TtlSeconds)); $l.version = [long]$l.version + 1
                Write-JsonFile $LeasePath $l
                Out-Json ([ordered]@{ granted = $true; owner = $l.owner; fencing_token = $l.fencing_token; lease_id = $l.lease_id; expires_at = $l.expires_at })
                $script:Rc = 0; return
            }
            'renew' {
                if (-not $mine -or $Token -eq 0) { Out-Json ([ordered]@{ renewed = $false; owner = $l.owner; fencing_token = $l.fencing_token }); $script:Rc = 2; return }
                $l.heartbeat_at = Iso $now; $l.expires_at = Iso ($now.AddSeconds($TtlSeconds)); $l.version = [long]$l.version + 1
                Write-JsonFile $LeasePath $l
                Out-Json ([ordered]@{ renewed = $true; fencing_token = $l.fencing_token; expires_at = $l.expires_at })
                $script:Rc = 0; return
            }
            'release' {
                if (-not $mine -or $Token -eq 0) { Out-Json ([ordered]@{ released = $false; owner = $l.owner; fencing_token = $l.fencing_token }); $script:Rc = 2; return }
                $l.owner = $null; $l.expires_at = $null; $l.version = [long]$l.version + 1
                Write-JsonFile $LeasePath $l
                Out-Json ([ordered]@{ released = $true; fencing_token = $l.fencing_token })
                $script:Rc = 0; return
            }
            default { throw "ação de lease desconhecida: $Act" }
        }
    }
}

# ---------- estado da conta ----------

$SentLog = Join-Path $StateDir 'sent-messages.jsonl'
$HeartbeatPath = Join-Path $StateDir 'watch-heartbeat.json'
$CursorPath = Join-Path $StateDir 'wpp-cursor.json'
$PausePath = Join-Path $StateDir 'assistente.pause'
$HoldPath = Join-Path $StateDir 'holds.json'
$FollowupPath = Join-Path $StateDir 'followups.json'

# Chave de comparação de um JID: celular brasileiro com ou sem o nono dígito dá a mesma chave.
function Get-PhoneKey([string]$J) {
    if (-not $J) { return '' }
    $base = $J -replace ':\d+@', '@'
    if ($base -like '*@lid') { return 'lid:' + ($base -replace '@.*$', '') }
    if ($base -like '*@g.us') { return 'g:' + ($base -replace '@.*$', '') }
    $d = ($base -replace '@.*$', '') -replace '\D', ''
    if ($d -match '^55(\d{2})9?(\d{8})$') { return '55' + $Matches[1] + $Matches[2] }
    $d
}
function Get-BaseJid([string]$J) { $J -replace ':\d+@', '@' }
function Test-IsNotifyChat([string]$J) { $NotifyJid -and (Get-PhoneKey $J) -eq (Get-PhoneKey $NotifyJid) }

# ---------- equipe (arquivo privado, fora do Git: telefones nunca entram no repositório) ----------

function Read-Team {
    $t = Read-JsonFile $TeamPath
    if (-not $t) { $t = [pscustomobject]@{} }
    foreach ($k in 'members', 'groups', 'extra') {
        if (-not ($t.PSObject.Properties.Name -contains $k)) { $t | Add-Member -NotePropertyName $k -NotePropertyValue @() }
        $t.$k = @($t.$k | Where-Object { $_ })
    }
    $t
}

# Quem é este chat: equipe, extra (pedido explícito do dono), grupo do time, ou ninguém ($null).
function Find-TeamEntry($Team, [string]$J) {
    $key = Get-PhoneKey $J
    if (-not $key) { return $null }
    if ($key -like 'g:*') {
        $g = @($Team.groups | Where-Object { (Get-PhoneKey $_.jid) -eq $key }) | Select-Object -First 1
        if ($g) { return [ordered]@{ kind = 'grupo'; name = $g.name; respond = [bool]$g.respond; entry = $g } }
        return $null
    }
    foreach ($m in @($Team.members)) {
        foreach ($j in (@($m.jids) + @($m.lids))) {
            if ($j -and (Get-PhoneKey $j) -eq $key) { return [ordered]@{ kind = 'equipe'; name = $m.name; respond = $true; entry = $m } }
        }
    }
    foreach ($x in @($Team.extra)) {
        if ($x.until -and ([DateTimeOffset]::Parse($x.until) -lt [DateTimeOffset]::UtcNow)) { continue }
        if ((Get-PhoneKey $x.jid) -eq $key) { return [ordered]@{ kind = 'extra'; name = $x.name; respond = $true; entry = $x } }
    }
    $null
}

# ---------- espera: o dono escreveu na conversa ----------

# A espera automática (o dono escreveu do celular) vence sozinha ASSISTENTE_ESPERA_MIN minutos (padrão 15) depois
# da última mensagem dele na conversa. A manual (`hold on`) só acaba com `hold off`.
$AutoHoldWhy = 'o dono escreveu na conversa'
function Test-HoldExpired($e) {
    if (-not $e -or [string]$e.why -ne $AutoHoldWhy) { return $false }
    $at = if ($e.last_owner) { [string]$e.last_owner } else { [string]$e.since }
    try { return ((Now-Utc) - [DateTimeOffset]::Parse($at, [Globalization.CultureInfo]::InvariantCulture)).TotalMinutes -ge $HoldMinutes } catch { return $false }
}
function Get-HoldMap {
    $map = [ordered]@{}
    $h = Read-JsonFile $HoldPath
    if ($h -and $h.chats) { foreach ($p in $h.chats.PSObject.Properties) { if (-not (Test-HoldExpired $p.Value)) { $map[$p.Name] = $p.Value } } }
    $map
}
function Test-Hold([string]$J) { (Get-HoldMap).Contains((Get-PhoneKey $J)) }
function Get-HoldEntry([string]$J) { $m = Get-HoldMap; $k = Get-PhoneKey $J; if ($m.Contains($k)) { $m[$k] } else { $null } }
# Devolve $true quando a conversa acabou de entrar em espera (para o detector avisar uma vez só).
function Set-Hold([string]$J, [bool]$On, [string]$Why, [string]$At = '') {
    Invoke-Locked 'holds' {
        $map = Get-HoldMap
        $changed = $false; $write = $false
        if (-not $At) { $At = Iso (Now-Utc) }
        if ($J -eq 'all') { if (-not $On -and $map.Count -gt 0) { $map = [ordered]@{}; $changed = $true } }
        else {
            $k = Get-PhoneKey $J
            if ($On -and -not $map.Contains($k)) { $map[$k] = [ordered]@{ chat = (Get-BaseJid $J); since = (Iso (Now-Utc)); why = $Why; last_owner = $At }; $changed = $true }
            elseif ($On) {
                $e = $map[$k]
                $prevAt = if ($e.last_owner) { [string]$e.last_owner } else { [string]$e.since }
                if (-not $prevAt -or [DateTimeOffset]::Parse($At) -gt [DateTimeOffset]::Parse($prevAt)) {
                    $map[$k] = [ordered]@{ chat = $e.chat; since = $e.since; why = $e.why; last_owner = $At }; $write = $true
                }
            }
            elseif ($map.Contains($k)) { $map.Remove($k); $changed = $true }
        }
        if ($changed -or $write) { Write-JsonFile $HoldPath ([ordered]@{ chats = $map }) }
        $changed
    }
}

function Test-OurMessage([string]$Mid) {
    if (-not $Mid -or -not (Test-Path -LiteralPath $SentLog)) { return $false }
    [bool](Select-String -LiteralPath $SentLog -SimpleMatch "`"id`":`"$Mid`"" -Quiet)
}
function Test-ContactedByUs([string]$J) {
    if (-not (Test-Path -LiteralPath $SentLog)) { return $false }
    [bool](Select-String -LiteralPath $SentLog -SimpleMatch ('"chat":"' + (Get-BaseJid $J) + '"') -Quiet)
}
function Add-SentLine([string]$ChatJid, [string]$Mid) {
    $line = ([ordered]@{ ts = Iso (Now-Utc); chat = (Get-BaseJid $ChatJid); id = $Mid } | ConvertTo-Json -Compress)
    Invoke-Locked 'sent-log' { [IO.File]::AppendAllText($SentLog, $line + "`n", $Utf8) }
}

# ---------- gateway MCP (app WhatsApp MCP) ----------

function Invoke-Mcp([string]$Tool, [hashtable]$Arguments) {
    $body = @{ jsonrpc = '2.0'; id = [Environment]::TickCount; method = 'tools/call'; params = @{ name = $Tool; arguments = $Arguments } } | ConvertTo-Json -Depth 6 -Compress
    $headers = @{ Accept = 'application/json, text/event-stream' }
    if ($McpToken) { $headers['Authorization'] = "Bearer $McpToken" }
    $r = Invoke-WebRequest -Uri $McpUrl -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ($Utf8.GetBytes($body)) -UseBasicParsing -TimeoutSec 20
    $raw = $Utf8.GetString($r.RawContentStream.ToArray())
    if ($raw -match '(?m)^data: (.+)$') { $raw = $Matches[1] }
    $j = $raw | ConvertFrom-Json
    if ($j.error) { throw "MCP $Tool : $($j.error.message)" }
    if ($j.result.isError) { throw "MCP $Tool : $($j.result.content[0].text)" }
    $j.result.content[0].text | ConvertFrom-Json
}

# ---------- saúde e retornos prometidos ----------

function Write-Heartbeat([bool]$GatewayOk, [string]$LastError = '', [int]$FailedChats = 0, [bool]$Paused = $false) {
    if ($Once) { return }   # execução avulsa não prova que o detector contínuo está vivo
    try { Write-JsonFile $HeartbeatPath ([ordered]@{ ts = Iso (Now-Utc); pid = $PID; gateway_ok = $GatewayOk; paused = $Paused; failed_chats = $FailedChats; last_error = $LastError; interval_s = $IntervalSeconds }) } catch { }
}
function Get-Heartbeat([int]$MaxAge) {
    $h = Read-JsonFile $HeartbeatPath
    if (-not $h -or -not $h.ts) { return [ordered]@{ status = 'missing'; age_seconds = $null; max_age_seconds = $MaxAge } }
    $age = [int]((Now-Utc) - [DateTimeOffset]::Parse($h.ts)).TotalSeconds
    $st = if ($age -le $MaxAge) { if ($h.gateway_ok) { 'ok' } else { 'gateway_fora' } } else { 'stale' }
    [ordered]@{ status = $st; age_seconds = $age; max_age_seconds = $MaxAge; watch_pid = $h.pid; gateway_ok = $h.gateway_ok; paused = [bool]$h.paused; last = $h.ts; last_error = $h.last_error }
}

$script:FollowupRc = 0
function Get-FollowupItems { $d = Read-JsonFile $FollowupPath; if ($d -and $d.items) { @($d.items) } else { @() } }
function Invoke-Followup([string]$Act) {
    switch ($Act) {
        'add' {
            if (-not $Chat -or -not $Due) { throw 'informe -Chat e -Due (RFC 3339, com fuso)' }
            $dueAt = [DateTimeOffset]::Parse($Due)
            Invoke-Locked 'followups' {
                $items = @(Get-FollowupItems)
                $fid = 'fu-' + (Now-Utc).ToString('yyyyMMddHHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 4))
                $items += [pscustomobject][ordered]@{ id = $fid; chat = $Chat; due = (Iso $dueAt); note = $Note; done = $false; created = (Iso (Now-Utc)) }
                Write-JsonFile $FollowupPath ([ordered]@{ items = $items })
                Out-Json ([ordered]@{ added = $true; id = $fid; due = (Iso $dueAt) })
            }
        }
        'list' { Out-Json ([ordered]@{ items = @(Get-FollowupItems | Where-Object { -not $_.done }) }) }
        'due' { $now = Now-Utc; Out-Json ([ordered]@{ now = (Iso $now); due = @(Get-FollowupItems | Where-Object { -not $_.done -and ([DateTimeOffset]::Parse($_.due) -le $now) }) }) }
        'done' {
            if (-not $Id) { throw 'informe -Id' }
            Invoke-Locked 'followups' {
                $items = @(Get-FollowupItems); $hit = $false
                foreach ($i in $items) { if ($i.id -eq $Id) { $i.done = $true; $hit = $true } }
                if ($hit) { Write-JsonFile $FollowupPath ([ordered]@{ items = $items }) } else { $script:FollowupRc = 2 }
                Out-Json ([ordered]@{ done = $hit; id = $Id })
            }
        }
        default { throw 'followup: use add | list | due | done' }
    }
}

# ---------- detector (sem IA) ----------

# Linhas emitidas (só quando há novidade):
#   EVENT inbound equipe|extra chat=<jid> quem="<nome>" n=<k> last=<ts>   alguém do time (ou liberado) escreveu
#   EVENT grupo chat=<jid> nome="<grupo>" responder=sim|nao n=<k> last=<ts>
#   EVENT assumido chat=<jid> quem="<nome>" ...                          o dono escreveu do celular: conversa em espera
#   EVENT espera equipe|extra chat=<jid> quem="<nome>" ... dono_ultima=<ts> alguém escreveu numa conversa em espera
#   EVENT dono chat=<jid> n=<k> last=<ts>                                o dono escreveu na conversa consigo mesmo
#   ERRO <motivo> / RECOVERED / BASELINE chats=<n>
function Invoke-WatchCycle($St) {
    if (Test-Path -LiteralPath $PausePath) { Write-Heartbeat $true '' 0 $true; return }
    $ignored = @('0@s.whatsapp.net', 'status@broadcast')
    $prefix = Get-PrefixText
    $listOk = $true; $lastErr = ''; $failedChats = 0; $chats = @()
    try { $chats = @((Invoke-Mcp 'list_chats' @{ limit = 100 }).chats) }
    catch {
        $listOk = $false; $lastErr = $_.Exception.Message
        if (-not $St.failing) { Write-Output ("ERRO {0}" -f $lastErr); $St.failing = $true }
    }
    if ($listOk) {
        $team = Read-Team
        $cursor = @{}; $c = $null
        try { $c = Read-JsonFile $CursorPath }
        catch {
            # Cursor ilegível (desligamento brusco deixa o arquivo só com bytes nulos): guarda o arquivo e relê desde a
            # última gravação dele, com folga, em vez de virar BASELINE e perder mensagem.
            $cut = Iso (([DateTimeOffset](Get-Item -LiteralPath $CursorPath).LastWriteTimeUtc).AddMinutes(-2))
            Move-Item -LiteralPath $CursorPath -Destination ('{0}.corrupt-{1}' -f $CursorPath, (Get-Date -Format 'yyyyMMddHHmmss')) -Force
            foreach ($ch in $chats) { $cursor[$ch.jid] = $cut }
            $c = [pscustomobject]@{ chats = [pscustomobject]@{} }
            Write-Output ("ERRO cursor ilegível; guardado e refeito desde {0}" -f $cut)
        }
        if ($c) { foreach ($p in $c.chats.PSObject.Properties) { $cursor[$p.Name] = $p.Value } }
        $baseline = ($null -eq $c)
        foreach ($ch in $chats) {
            try {
                if ($ignored -contains $ch.jid -or -not $ch.last_message_ts) { continue }
                $prev = $cursor[$ch.jid]
                if ($baseline) { $cursor[$ch.jid] = $ch.last_message_ts; continue }
                if ($prev -and ([DateTimeOffset]::Parse($ch.last_message_ts) -le [DateTimeOffset]::Parse($prev))) { continue }
                $isNotify = Test-IsNotifyChat $ch.jid
                $who = $null
                if (-not $isNotify) {
                    # Fora do time (e sem pedido do dono) a conversa nem é lida.
                    $who = Find-TeamEntry $team $ch.jid
                    if (-not $who) {
                        $cursor[$ch.jid] = $ch.last_message_ts
                        Write-JsonFile $CursorPath ([ordered]@{ updated_at = Iso (Now-Utc); chats = $cursor })
                        continue
                    }
                }
                $since = if ($prev) { $prev } else { Iso ((Now-Utc).AddMinutes(-10)) }
                $msgs = @((Invoke-Mcp 'get_chat_messages' @{ chat_jid = $ch.jid; since = $since; order = 'oldest'; limit = 50 }).messages)
                $newer = @($msgs | Where-Object { -not $prev -or [DateTimeOffset]::Parse($_.timestamp) -gt [DateTimeOffset]::Parse($prev) })
                $inbound = @($newer | Where-Object { -not $_.from_me })
                # Mensagem com o prefixo do assistente é dele mesmo antes do send registrar o id (corrida detector x send).
                $foreign = @($newer | Where-Object { $_.from_me -and -not (Test-OurMessage $_.id) -and -not ([string]$_.text).StartsWith($prefix) })
                if ($isNotify) {
                    # Avisos noutro número do dono (ASSISTENTE_AVISO_JID diferente da conta): o que chega de lá também é dele.
                    $fromOwner = @($foreign)
                    if ((Get-PhoneKey $NotifyJid) -ne (Get-PhoneKey $AccountJid)) { $fromOwner += @($inbound) }
                    if ($fromOwner.Count -gt 0) { Write-Output ("EVENT dono chat={0} n={1} last={2}" -f $ch.jid, $fromOwner.Count, $ch.last_message_ts) }
                }
                else {
                    $nm = ([string]$who.name) -replace '"', ''
                    if ($who.kind -eq 'grupo') {
                        if ($inbound.Count -gt 0) { Write-Output ('EVENT grupo chat={0} nome="{1}" responder={2} n={3} last={4}' -f $ch.jid, $nm, $(if ($who.respond) { 'sim' } else { 'nao' }), $inbound.Count, $ch.last_message_ts) }
                    }
                    elseif ($foreign.Count -gt 0) {
                        $ownerAt = [string](@($foreign)[-1].timestamp)
                        if (Set-Hold $ch.jid $true $AutoHoldWhy $ownerAt) { Write-Output ('EVENT assumido chat={0} quem="{1}" n={2} last={3}' -f $ch.jid, $nm, $foreign.Count, $ch.last_message_ts) }
                    }
                    elseif ($inbound.Count -gt 0) {
                        $hold = Get-HoldEntry $ch.jid
                        if ($hold) {
                            $lastO = if ($hold.last_owner) { [string]$hold.last_owner } else { [string]$hold.since }
                            Write-Output ('EVENT espera {0} chat={1} quem="{2}" n={3} last={4} dono_ultima={5}' -f $who.kind, $ch.jid, $nm, $inbound.Count, $ch.last_message_ts, $lastO)
                        }
                        else { Write-Output ('EVENT inbound {0} chat={1} quem="{2}" n={3} last={4}' -f $who.kind, $ch.jid, $nm, $inbound.Count, $ch.last_message_ts) }
                    }
                }
                $cursor[$ch.jid] = $ch.last_message_ts
                Write-JsonFile $CursorPath ([ordered]@{ updated_at = Iso (Now-Utc); chats = $cursor })
                if ($St.chatErrs.ContainsKey($ch.jid)) { $St.chatErrs.Remove($ch.jid) }
            }
            catch {
                # O cursor desse chat não avança (a mensagem é relida no próximo ciclo), e o batimento não diz que está tudo bem.
                $failedChats++
                $lastErr = "falha ao ler $failedChats conversa(s): $($_.Exception.Message)"
                if (-not $St.chatErrs.ContainsKey($ch.jid)) { $St.chatErrs[$ch.jid] = $true; Write-Output ("ERRO chat={0} {1}" -f $ch.jid, $_.Exception.Message) }
            }
        }
        Write-JsonFile $CursorPath ([ordered]@{ updated_at = Iso (Now-Utc); chats = $cursor })
        if ($baseline) { Write-Output ("BASELINE chats={0}" -f $cursor.Count) }
        if ($St.failing) { Write-Output 'RECOVERED'; $St.failing = $false }
    }
    Write-Heartbeat ($listOk -and $failedChats -eq 0) $lastErr $failedChats
}

function Start-Watch {
    $why = ''
    if (-not $AssistantName -or (Test-AssistantName $AssistantName)) { $why = 'sem ASSISTENTE_NOME válido' }
    elseif (-not $AccountJid) { $why = 'sem ASSISTENTE_CONTA_JID' }
    elseif (-not (Test-Path -LiteralPath $TeamPath)) { $why = "sem o arquivo da equipe ($TeamPath)" }
    if ($why) { Write-Output "ERRO detector não sobe: $why"; Write-Heartbeat $false $why; return }
    # Conta conectada: conferida antes de ler. App fechado ou outra conta = espera, com o batimento acusando a falha.
    $st = @{ failing = $false; chatErrs = @{} }
    $acctOk = $false; $acctErr = ''
    while ($true) {
        if (-not $acctOk) {
            $e = ''
            try { $linked = (Invoke-Mcp 'whatsapp_status' @{}).wacli.linked_jid; if ((Get-PhoneKey $linked) -ne (Get-PhoneKey $AccountJid)) { $e = 'a conta conectada no app não é a configurada' } }
            catch { $e = "app WhatsApp MCP fora: $($_.Exception.Message)" }
            if ($e) {
                if ($e -ne $acctErr) { Write-Output "ERRO $e"; $acctErr = $e }
                Write-Heartbeat $false $e
                if ($Once) { break }
                Start-Sleep -Seconds $IntervalSeconds; continue
            }
            if ($acctErr) { Write-Output 'RECOVERED'; $acctErr = '' }
            $acctOk = $true
        }
        Invoke-WatchCycle $st
        if ($Once) { break }
        Start-Sleep -Seconds $IntervalSeconds
    }
}

# ---------- resolução de destinatário (nomes iguais ou foneticamente parecidos) ----------

# Chave fonética de uma palavra (português): "Felipe", "Filipe", "Phelippe" e "Felype" dão a mesma chave.
function Get-NameKey([string]$Word) {
    if (-not $Word) { return '' }
    $w = $Word.ToLowerInvariant().Replace([string][char]0x00E7, 's')
    $w = ($w.Normalize([Text.NormalizationForm]::FormD) -replace '\p{M}', '') -replace '[^a-z]', ''
    $w = $w -replace 'ph', 'f' -replace 'th', 't' -replace 'ck', 'k' -replace 'qu', 'k' -replace 'ch', 'x' -replace 'sh', 'x'
    $w = $w -replace 'w', 'v' -replace 'y', 'i' -replace 'h', '' -replace 'z', 's'
    $w = $w -replace 'c(?=[ei])', 's' -replace 'c', 'k' -replace 'g(?=[ei])', 'j'
    $w = $w -replace '(.)\1+', '$1'
    $w = $w -replace 'e', 'i' -replace 'o', 'u'
    $w
}
function Get-EditDistance([string]$A, [string]$B) {
    $prev = 0..$B.Length
    for ($i = 1; $i -le $A.Length; $i++) {
        $cur = @($i) + @(0) * $B.Length
        for ($j = 1; $j -le $B.Length; $j++) {
            $cost = 1; if ($A[$i - 1] -eq $B[$j - 1]) { $cost = 0 }
            $cur[$j] = [Math]::Min([Math]::Min($cur[$j - 1] + 1, $prev[$j] + 1), $prev[$j - 1] + $cost)
        }
        $prev = $cur
    }
    $prev[$B.Length]
}
# 'exact' | 'phonetic' | 'near' | '' (sem relação) entre duas palavras.
function Get-WordMatch([string]$A, [string]$B) {
    $ka = Get-NameKey $A; $kb = Get-NameKey $B
    if (-not $ka -or -not $kb) { return '' }
    $na = ($A.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD) -replace '\p{M}', '') -replace '[^a-z]', ''
    $nb = ($B.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD) -replace '\p{M}', '') -replace '[^a-z]', ''
    if ($na -eq $nb) { return 'exact' }
    if ($ka -eq $kb) { return 'phonetic' }
    if ([Math]::Min($ka.Length, $kb.Length) -ge 4 -and (Get-EditDistance $ka $kb) -le 1) { return 'near' }
    ''
}
function Split-NameWords([string]$Value) { @(($Value -split '[^\p{L}]+') | Where-Object { $_.Length -ge 2 }) }
# Fragmentos de busca que cobrem as grafias possíveis do começo do nome (a busca do app é por substring).
function Get-SearchFragments([string]$Word) {
    $alt = @{ f = @('f', 'ph'); i = @('i', 'e', 'y'); u = @('u', 'o'); k = @('k', 'c', 'q'); s = @('s', 'c', 'z', 'x', 'ss'); v = @('v', 'w'); j = @('j', 'g'); x = @('x', 'ch', 'sh'); t = @('t', 'th') }
    $key = Get-NameKey $Word
    if (-not $key) { return @() }
    $frags = @('')
    foreach ($ch in $key.Substring(0, [Math]::Min(3, $key.Length)).ToCharArray()) {
        $opts = @([string]$ch); if ($alt.ContainsKey([string]$ch)) { $opts = $alt[[string]$ch] }
        $frags = @(foreach ($p in $frags) { foreach ($o in $opts) { $p + $o } })
    }
    $raw = ($Word.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD) -replace '\p{M}', '') -replace '[^a-z]', ''
    @($frags + $raw.Substring(0, [Math]::Min(3, $raw.Length)) | Select-Object -Unique)
}
function Resolve-Recipient([string]$Query) {
    $qWords = @(Split-NameWords $Query)
    if ($qWords.Count -eq 0) { throw 'informe -Name' }
    $found = @{}
    $add = {
        param($jid, $nm, $source)
        if (-not $jid -or -not $nm -or $jid -like '0@*' -or $jid -like '*@g.us') { return }
        $b = Get-BaseJid $jid
        if (-not $found.ContainsKey($b)) { $found[$b] = [ordered]@{ jid = $b; name = $nm; sources = @() } }
        if ($found[$b].sources -notcontains $source) { $found[$b].sources += $source }
    }
    $chatInfo = @{}
    foreach ($c in @((Invoke-Mcp 'list_chats' @{ limit = 500 }).chats)) {
        if ($c.kind -eq 'dm') { $chatInfo[(Get-BaseJid $c.jid)] = $c.last_message_ts; & $add $c.jid $c.name 'chat' }
    }
    $frags = @($qWords | ForEach-Object { Get-SearchFragments $_ } | Select-Object -Unique | Select-Object -First 60)
    foreach ($fr in $frags) { foreach ($c in @((Invoke-Mcp 'list_contacts' @{ search = $fr; limit = 500 }).contacts)) { & $add $c.jid $c.name 'contato' } }
    $first = $qWords[0]
    $cands = @()
    foreach ($e in $found.Values) {
        $words = @(Split-NameWords $e.name)
        $best = ''; $rank = @{ exact = 3; phonetic = 2; near = 1; '' = 0 }
        foreach ($w in $words) { $m = Get-WordMatch $first $w; if ($rank[$m] -gt $rank[$best]) { $best = $m } }
        if (-not $best) { continue }
        $extra = 0
        if ($qWords.Count -gt 1) { foreach ($q in $qWords[1..($qWords.Count - 1)]) { foreach ($w in $words) { if (Get-WordMatch $q $w) { $extra++; break } } } }
        $cands += [pscustomobject][ordered]@{
            jid = $e.jid; name = $e.name; match = $best; also_matches_other_words = $extra
            has_chat_history = $chatInfo.ContainsKey($e.jid); last_message_ts = $chatInfo[$e.jid]
            contacted_before = (Test-ContactedByUs $e.jid)
        }
    }
    $strong = @($cands | Where-Object { $_.also_matches_other_words -gt 0 })
    if ($strong.Count -gt 0) { $cands = $strong }
    $cands = @($cands | Sort-Object @{ e = { @{ exact = 0; phonetic = 1; near = 2 }[$_.match] } }, name)
    $status = 'none'
    if ($cands.Count -eq 1) { $status = 'unique' } elseif ($cands.Count -gt 1) { $status = 'ambiguous' }
    [ordered]@{
        query = $Query; status = $status; count = $cands.Count; candidates = $cands
        rule = 'unique: confirme com o dono que o número é o certo antes do primeiro contato. ambiguous/none: NÃO envie; mostre os candidatos ao dono e pergunte.'
    }
}

# ---------- setup e personalidade ----------

function Set-EnvKeys([hashtable]$Pairs) {
    New-Item -ItemType Directory -Force -Path (Split-Path $ConfigPath -Parent) | Out-Null
    $lines = @()
    if (Test-Path -LiteralPath $ConfigPath) { $lines = @(Get-Content -LiteralPath $ConfigPath -Encoding UTF8) }
    else {
        $example = Join-Path $SkillDir '.env.example'
        if (Test-Path -LiteralPath $example) { $lines = @(Get-Content -LiteralPath $example -Encoding UTF8) }
    }
    foreach ($k in $Pairs.Keys) {
        $hit = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match ('^\s*' + [regex]::Escape($k) + '\s*=')) { $lines[$i] = "$k=$($Pairs[$k])"; $hit = $true; break }
        }
        if (-not $hit) { $lines += "$k=$($Pairs[$k])" }
    }
    [IO.File]::WriteAllText($ConfigPath, (($lines -join "`r`n") + "`r`n"), $Utf8)
}

# "Escopo: só com o dono. Com o time: cordial." -> 'cordial' (o tom vale só com o dono); sem a linha -> ''.
function Get-PersonaScope([string[]]$Lines) {
    foreach ($l in $Lines) { if ($l -match '^Escopo:\s*só com o dono\.\s*Com o time:\s*([\w-]+)') { return $Matches[1] } }
    ''
}

function Get-Presets {
    if (-not (Test-Path -LiteralPath $PresetDir)) { return @() }
    @(Get-ChildItem -LiteralPath $PresetDir -Filter '*.md' | Sort-Object Name | ForEach-Object {
            $headLines = @(Get-Content -LiteralPath $_.FullName -Encoding UTF8 -TotalCount 12)
            $first = ($headLines | Where-Object { $_ -match '^>\s*' } | Select-Object -First 1) -replace '^>\s*', ''
            $sc = Get-PersonaScope $headLines
            [ordered]@{ preset = $_.BaseName; resumo = $first; so_com_o_dono = [bool]$sc; com_o_time = $(if ($sc) { $sc } else { $_.BaseName }) }
        })
}

function Get-CheckProblems {
    $p = @()
    $nameWhy = Test-AssistantName $AssistantName
    if ($nameWhy) { $p += "ASSISTENTE_NOME: $nameWhy" }
    if (-not $OwnerName) { $p += 'ASSISTENTE_DONO vazio' }
    if (-not $AccountJid) { $p += 'ASSISTENTE_CONTA_JID vazio (rode setup -Jid auto com o app aberto)' }
    if (@('responder', 'triagem') -notcontains $Autonomy) { $p += "ASSISTENTE_AUTONOMIA inválida: $Autonomy" }
    $g = Get-Cfg 'ASSISTENTE_GENERO'
    if ($g -and @('feminino', 'masculino', 'neutro') -notcontains $g) { $p += "ASSISTENTE_GENERO inválido: $g (feminino, masculino, neutro ou vazio)" }
    foreach ($fz in @(@('ASSISTENTE_FUSO', $OwnerFusoName), @('ASSISTENTE_FUSO_TIME', $TeamFusoName))) {
        try { $null = Resolve-Fuso $fz[1] } catch { $p += "$($fz[0]) inválido: $($fz[1]) (ex.: GMT-3)" }
    }
    if (-not (Test-Path -LiteralPath $PersonaPath)) { $p += "sem persona ($PersonaPath): rode persona use -Name <preset>" }
    if (-not (Test-Path -LiteralPath $TeamPath)) { $p += "sem equipe ($TeamPath)" }
    else { $t = Read-Team; if (@($t.members).Count -eq 0) { $p += 'equipe sem membros' } }
    $p
}

# ---------- manual (help) ----------

# Cada funcionalidade com o estado real nesta máquina: ativo, inativo ou atenção, e como mudar.
function Get-HelpReport {
    $items = New-Object System.Collections.Generic.List[object]
    function Add-Item([string]$Area, [string]$Feature, [string]$State, [string]$Detail, [string]$How) {
        $items.Add([ordered]@{ area = $Area; funcionalidade = $Feature; estado = $State; detalhe = $Detail; como_mudar = $How })
    }
    $nameOk = $AssistantName -and -not (Test-AssistantName $AssistantName)
    Add-Item 'Identidade' 'Nome do assistente' $(if ($nameOk) { 'ativo' } else { 'inativo' }) $(if ($nameOk) { "$AssistantName, assistente virtual de $OwnerName; assina *$($AssistantName.Trim()):*" } else { 'sem nome' }) '"troca o nome do meu assistente para X"'
    $presetName = ''
    if (Test-Path -LiteralPath $PersonaPath) {
        $head = Get-Content -LiteralPath $PersonaPath -Encoding UTF8 -TotalCount 1
        $presetName = ($head -replace '^#\s*Personalidade:\s*', '').Trim()
        $adj = @((Get-Content -LiteralPath $PersonaPath -Raw -Encoding UTF8) -split 'Ajustes do dono', 2)
        $nAdj = if ($adj.Count -gt 1) { @($adj[1] -split "`n" | Where-Object { $_ -match '^\s*-\s+\S' }).Count } else { 0 }
        $scope = Get-PersonaScope @(Get-Content -LiteralPath $PersonaPath -Encoding UTF8 -TotalCount 12)
        $pDet = "$presetName; $nAdj ajuste(s) seu(s)" + $(if ($scope) { "; esse tom é só com você, com o time fala no tom $scope" } else { '' })
        Add-Item 'Identidade' 'Personalidade' 'ativo' $pDet '"deixa meu assistente mais X" (ajuste) ou "muda para a personalidade técnica" (troca)'
    }
    else { Add-Item 'Identidade' 'Personalidade' 'inativo' 'nenhuma escolhida' '"configure meu assistente de WhatsApp"' }
    $gen = Get-Cfg 'ASSISTENTE_GENERO'
    Add-Item 'Identidade' 'Gênero do assistente (opcional)' $(if ($gen -and $gen -ne 'neutro') { 'ativo' } else { 'inativo' }) $(if ($gen -and $gen -ne 'neutro') { "$gen (concordância: $(if ($gen -eq 'feminino') { 'obrigada' } else { 'obrigado' }))" } else { 'não definido: formas neutras' }) '"meu assistente é ela/ele" ou "deixa neutro" (ASSISTENTE_GENERO)'
    try {
        $now = Now-Utc
        $fo = Get-FusoLabel (Resolve-Fuso $OwnerFusoName) $now; $ft = Get-FusoLabel (Resolve-Fuso $TeamFusoName) $now
        $fDet = if ($fo -eq $ft) { "$fo, o mesmo do time" } else { "seus avisos em $fo; para o time, $ft (o fuso de trabalho), sempre com o fuso escrito ao lado" }
        Add-Item 'Identidade' 'Fuso dos horários' 'ativo' $fDet '"usa o fuso GMT+1 nos meus horários" (ASSISTENTE_FUSO)'
    }
    catch { Add-Item 'Identidade' 'Fuso dos horários' 'atenção' $_.Exception.Message 'corrigir ASSISTENTE_FUSO no .env (ex.: GMT-3)' }

    $app = 'inativo'; $appDet = 'app WhatsApp MCP não respondeu'
    try {
        $linked = (Invoke-Mcp 'whatsapp_status' @{}).wacli.linked_jid
        if ($linked -and $AccountJid -and (Get-PhoneKey $linked) -eq (Get-PhoneKey $AccountJid)) { $app = 'ativo'; $appDet = "conta $(Mask $linked) conectada" }
        elseif ($linked) { $app = 'atenção'; $appDet = "conectada a outra conta ($(Mask $linked))" }
        else { $appDet = 'app aberto, sem WhatsApp conectado' }
    } catch { }
    Add-Item 'Conexão' 'App WhatsApp MCP' $app $appDet 'abrir o app e conectar pelo QR Code; depois "setup -Jid auto"'

    $team = Read-Team
    $nm = @($team.members).Count; $ng = @($team.groups).Count; $ngr = @($team.groups | Where-Object { $_.respond }).Count
    $nx = @($team.extra | Where-Object { -not $_.until -or [DateTimeOffset]::Parse($_.until) -gt (Now-Utc) }).Count
    Add-Item 'Atendimento' 'Responder ao time' $(if ($nm -eq 0) { 'inativo' } elseif ($Autonomy -eq 'responder') { 'ativo' } else { 'inativo' }) $(if ($Autonomy -eq 'responder') { "responde sozinho a $nm pessoa(s) do time" } else { "modo triagem: lê e leva a você ($nm pessoa(s))" }) '"deixa meu assistente só em triagem" / "volta a responder sozinho"'
    Add-Item 'Atendimento' 'Grupos do time' $(if ($ng -gt 0) { 'ativo' } else { 'inativo' }) "$ng grupo(s) vigiado(s); responde em $ngr" '"vigia o grupo X" / "pode responder no grupo X"'
    Add-Item 'Atendimento' 'Contatos fora do time' $(if ($nx -gt 0) { 'ativo' } else { 'inativo' }) "$nx liberado(s) por você" '"atende o Fulano sobre X até sexta"'
    $holds = Get-HoldMap
    Add-Item 'Atendimento' 'Silêncio quando você escreve' 'ativo' "$HoldMinutes min depois da sua última mensagem; $($holds.Count) conversa(s) em espera agora" '"fica fora da conversa com X" (espera manual) / "volta a atender X"'
    $fu = @(Get-FollowupItems | Where-Object { -not $_.done }).Count
    Add-Item 'Atendimento' 'Retornos prometidos' 'ativo' "$fu pendente(s)" 'o assistente registra sozinho quando promete retorno'
    Add-Item 'Atendimento' 'Recado a pedido seu' 'ativo' 'pelo Claude Code ou escrevendo na conversa consigo mesmo no WhatsApp' '"manda pro Fulano que…"'

    $paused = Test-Path -LiteralPath $PausePath
    Add-Item 'Funcionamento' 'Ligado' $(if ($paused) { 'inativo' } else { 'ativo' }) $(if ($paused) { 'pausado por você' } else { 'não pausado' }) '"desliga meu assistente" / "religa meu assistente"'
    $dRun = $false
    try { $null = & (Get-PsExe) -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'assistente-despachante.ps1') -Mode status 2>$null; $dRun = ($LASTEXITCODE -eq 0) } catch { }
    Add-Item 'Funcionamento' 'Despachante (sem sessão aberta)' $(if ($dRun) { 'ativo' } else { 'inativo' }) $(if ($dRun) { 'abre o Claude a cada lote de mensagens' } else { 'parado: ninguém é atendido' }) 'o vigia sobe sozinho em até 3 min; ou "assistente-despachante.ps1 -Mode start"'
    $hb = Get-Heartbeat 120
    Add-Item 'Funcionamento' 'Detector de mensagens' $(if ($hb.status -eq 'ok') { 'ativo' } elseif ($hb.status -eq 'gateway_fora') { 'atenção' } else { 'inativo' }) "batimento: $($hb.status)" 'sobe junto com o despachante'
    if ($EhMac) {
        $la = $false; try { $la = Test-VigiaMac } catch { }
        Add-Item 'Funcionamento' 'Vigia (LaunchAgent do macOS)' $(if ($la) { 'ativo' } else { 'inativo' }) $(if ($la) { "LaunchAgent $VigiaRotulo carregado" } else { 'LaunchAgent não carregado' }) 'rodar o install.ps1 de novo (pwsh ./install.ps1)'
    }
    else {
        $task = $null; try { $task = Get-ScheduledTask -TaskName 'AssistenteWppVigia' -ErrorAction Stop } catch { }
        Add-Item 'Funcionamento' 'Vigia (Agendador do Windows)' $(if ($task -and $task.State -ne 'Disabled') { 'ativo' } else { 'inativo' }) $(if ($task) { "tarefa AssistenteWppVigia: $($task.State)" } else { 'tarefa não registrada' }) 'rodar o install.ps1 de novo'
    }

    $cfgDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
    $hooksOn = $false
    try { $hooksOn = (Get-Content -LiteralPath (Join-Path $cfgDir 'settings.json') -Raw -Encoding UTF8) -match 'assistente-wpp(\\\\|/)scripts(\\\\|/)aviso-sessao' } catch { }
    $avisoCfg = (Get-Cfg 'ASSISTENTE_AVISO_SESSAO' '1') -ne '0'
    $ed = Get-Cfg 'ASSISTENTE_AVISO_EDITOR' 'auto'
    Add-Item 'Aviso de sessão' 'Avisar quando uma sessão para e espera você' $(if ($hooksOn -and $avisoCfg) { 'ativo' } else { 'inativo' }) ("turno de $(Get-Cfg 'ASSISTENTE_AVISO_MIN_SEG' '60') s ou mais, autorização ou pergunta pendente; editor: $ed" + $(if (-not $hooksOn) { '; hooks não registrados' } elseif (-not $avisoCfg) { '; desligado no .env' } else { '' })) 'ASSISTENTE_AVISO_SESSAO=1|0 no .env; hooks: install.ps1 (ou -SemAvisoSessao)'
    Add-Item 'Aviso de sessão' 'Link de volta à sessão' $(if ($hooksOn -and $avisoCfg) { 'ativo' } else { 'inativo' }) 'VS Code: link; terminal: claude --resume; T3 Code: título e pasta; Remote Control: link do celular' 'ASSISTENTE_AVISO_EDITOR=auto|vscode|cli|t3 ou ASSISTENTE_AVISO_LINK com {session}'
    $comoTirar = 'para não rodar aqui: "desliga meu assistente" (fica desligado até você religar, mesmo reiniciando) ou install.ps1 -Remover; depois instale e ligue no computador de trabalho'
    if ($EhMac) {
        Add-Item 'Plataforma' 'macOS: onde roda' $(if ($paused) { 'inativo' } else { 'ativo' }) "neste Mac ($(Get-NomeMaquina)), sempre que você está logado nele: o vigia (LaunchAgent) religa sozinho no login e a cada 3 min. Ligue em um computador só por conta de WhatsApp, ou ele responde em dobro" $comoTirar
        Add-Item 'Plataforma' 'Windows' 'inativo' 'também roda no Windows (Windows PowerShell 5.1); aqui está no Mac' '—'
    }
    else {
        Add-Item 'Plataforma' 'Windows: onde roda' $(if ($paused) { 'inativo' } else { 'ativo' }) "neste PC ($(Get-NomeMaquina)), sempre que você está logado nele: o vigia religa sozinho no logon e a cada 3 min. Ligue em um computador só por conta de WhatsApp, ou ele responde em dobro" $comoTirar
        Add-Item 'Plataforma' 'Mac' 'inativo' 'também roda no macOS (pwsh, com LaunchAgent); aqui está no Windows' '—'
    }
    ,$items
}

function Format-HelpText($Items) {
    $sb = New-Object Text.StringBuilder
    $title = if ($AssistantName) { "Manual de $($AssistantName.Trim())" } else { 'Manual do assistente de WhatsApp' }
    [void]$sb.AppendLine($title)
    [void]$sb.AppendLine('')
    $mark = @{ 'ativo' = '[ativo]  '; 'inativo' = '[inativo]'; 'atenção' = '[atenção]' }
    foreach ($g in ($Items | Group-Object { $_.area })) {
        [void]$sb.AppendLine($g.Name)
        foreach ($i in $g.Group) {
            [void]$sb.AppendLine(('  {0} {1}: {2}' -f $mark[$i.estado], $i.funcionalidade, $i.detalhe))
            [void]$sb.AppendLine(('             como mudar: {0}' -f $i.como_mudar))
        }
        [void]$sb.AppendLine('')
    }
    [void]$sb.AppendLine('Sempre valem, em qualquer personalidade: objetividade, cortesia, conferir na fonte antes de afirmar, sigilo, e nenhuma ação além de conversar sem o seu ok.')
    $sb.ToString().TrimEnd()
}

# ---------- despacho ----------

try {
    switch ($Command) {
        'help' {
            $rep = Get-HelpReport
            if ($Json) { Out-Json ([ordered]@{ assistente = $AssistantName; dono = $OwnerName; itens = $rep }) } else { Write-Output (Format-HelpText $rep) }
            exit 0
        }
        'setup' {
            $pairs = @{}
            if ($Name) {
                $why = Test-AssistantName $Name
                if ($why) { Out-Json ([ordered]@{ saved = $false; reason = $why; dica = 'escolha outro nome para o assistente (2 a 24 letras)' }); exit 2 }
                $pairs['ASSISTENTE_NOME'] = $Name.Trim()
            }
            if ($Owner) { $pairs['ASSISTENTE_DONO'] = $Owner.Trim() }
            if ($Mode) { $pairs['ASSISTENTE_AUTONOMIA'] = $Mode }
            if ($Genero) { $pairs['ASSISTENTE_GENERO'] = $Genero }
            if ($Fuso) {
                try { $null = Resolve-Fuso $Fuso } catch { Out-Json ([ordered]@{ saved = $false; reason = 'fuso_invalido'; dica = 'use GMT-3, UTC+1, GMT+5:30 ou um id do Windows' }); exit 2 }
                $pairs['ASSISTENTE_FUSO'] = $Fuso.Trim()
            }
            if ($Jid) {
                if ($Jid -eq 'auto') {
                    $linked = (Invoke-Mcp 'whatsapp_status' @{}).wacli.linked_jid
                    if (-not $linked) { Out-Json ([ordered]@{ saved = $false; reason = 'app_sem_conta_conectada'; dica = 'abra o app WhatsApp MCP e conecte o seu WhatsApp' }); exit 2 }
                    $pairs['ASSISTENTE_CONTA_JID'] = (Get-BaseJid $linked)
                }
                else { $pairs['ASSISTENTE_CONTA_JID'] = (Get-BaseJid $Jid) }
            }
            if ($pairs.Count -eq 0) { throw 'informe ao menos um de -Name, -Owner, -Jid, -Mode, -Fuso, -Genero' }
            Set-EnvKeys $pairs
            $shown = [ordered]@{}; foreach ($k in $pairs.Keys) { $shown[$k] = $(if ($k -like '*JID') { Mask $pairs[$k] } else { $pairs[$k] }) }
            Out-Json ([ordered]@{ saved = $true; file = $ConfigPath; values = $shown }); exit 0
        }
        'check' {
            $p = @(Get-CheckProblems)
            Out-Json ([ordered]@{ ready = ($p.Count -eq 0); problems = $p; config_file = $ConfigPath; persona = $PersonaPath; equipe = $TeamPath })
            if ($p.Count -eq 0) { exit 0 } else { exit 2 }
        }
        'persona' {
            switch ($Action) {
                'use' {
                    if (-not $Name) { throw 'informe -Name <preset>' }
                    $src = Join-Path $PresetDir ($Name + '.md')
                    if (-not (Test-Path -LiteralPath $src)) { Out-Json ([ordered]@{ ok = $false; reason = 'preset_inexistente'; presets = (Get-Presets) }); exit 2 }
                    if ((Test-Path -LiteralPath $PersonaPath) -and -not $Force) { Out-Json ([ordered]@{ ok = $false; reason = 'persona_ja_existe'; dica = 'a persona atual tem os seus ajustes; use -Force só se o dono pediu para recomeçar do preset'; file = $PersonaPath }); exit 2 }
                    New-Item -ItemType Directory -Force -Path (Split-Path $PersonaPath -Parent) | Out-Null
                    if (Test-Path -LiteralPath $PersonaPath) { Copy-Item -LiteralPath $PersonaPath -Destination ("$PersonaPath.bak-" + (Get-Date -Format 'yyyyMMddHHmmss')) }
                    $body = Get-Content -LiteralPath $src -Raw -Encoding UTF8
                    $body += "`r`n`r`n## Ajustes do dono`r`n`r`n<!-- Evolução da personalidade, pedida pelo próprio dono. Uma linha por ajuste, com a data. -->`r`n"
                    [IO.File]::WriteAllText($PersonaPath, $body, $Utf8)
                    Out-Json ([ordered]@{ ok = $true; preset = $Name; file = $PersonaPath }); exit 0
                }
                'show' { if (Test-Path -LiteralPath $PersonaPath) { Get-Content -LiteralPath $PersonaPath -Raw -Encoding UTF8 } else { Write-Output "sem persona em $PersonaPath" }; exit 0 }
                default { Out-Json ([ordered]@{ presets = (Get-Presets); persona_atual = $(if (Test-Path -LiteralPath $PersonaPath) { $PersonaPath } else { $null }) }); exit 0 }
            }
        }
        'prefix' { Write-Output (Format-AssistantMessage $Text); exit 0 }
        'lease' { Invoke-Lease $Action; exit $script:Rc }
        'sent' {
            if (-not $Chat -or -not $MessageId) { throw 'informe -Chat e -MessageId' }
            Add-SentLine $Chat $MessageId
            Write-Output 'ok'; exit 0
        }
        'is-ours' { if (Test-OurMessage $MessageId) { Write-Output 'sim'; exit 0 } else { Write-Output 'nao'; exit 1 } }
        'watch' { Start-Watch; exit 0 }
        'account' {
            $linked = (Invoke-Mcp 'whatsapp_status' @{}).wacli.linked_jid
            $ok = [bool]$AccountJid -and (Get-PhoneKey $linked) -eq (Get-PhoneKey $AccountJid)
            Out-Json ([ordered]@{ matches = $ok; linked_suffix = (Mask $linked); expected_configured = [bool]$AccountJid })
            if ($ok) { exit 0 } else { exit 2 }
        }
        'messages' {
            if (-not $Chat) { throw 'informe -Chat' }
            $a = @{ chat_jid = $Chat; limit = $Limit; order = 'oldest' }
            if ($Since) { $a['since'] = $Since }
            Out-Json (Invoke-Mcp 'get_chat_messages' $a); exit 0
        }
        'send' {
            if (-not $Chat -or $null -eq $Text) { throw 'informe -Chat e -Text' }
            if (-not $Operator -or $Token -eq 0) { throw 'informe -Operator e -Token do lease' }
            function Refuse([string]$Reason, [string]$Hint) { Out-Json ([ordered]@{ sent = $false; reason = $Reason; chat = $Chat; dica = $Hint }); exit 2 }
            # Pausa bloqueia antes de qualquer rede: operador já ativo também para.
            if (Test-Path -LiteralPath $PausePath) { Refuse 'pausado' 'o dono desligou o assistente (pause on); só ele religa' }
            $msg = Format-AssistantMessage $Text
            # Lease conferido no momento do envio (fencing): instância antiga não envia.
            $l = Read-JsonFile $LeasePath
            $leaseOk = $l -and $l.owner -eq $Operator -and [long]$l.fencing_token -eq $Token -and $l.expires_at -and ([DateTimeOffset]::Parse($l.expires_at) -gt (Now-Utc))
            if (-not $leaseOk) { Refuse 'lease_invalido' 'o volante não é seu (ou venceu)' }
            $toOwner = Test-IsNotifyChat $Chat
            if (-not $toOwner) {
                $who = Find-TeamEntry (Read-Team) $Chat
                if (-not $who) { Refuse 'fora_do_time_sem_pedido' 'o assistente só fala com o time; outra pessoa só com pedido explícito do dono (allow add -Chat <jid>)' }
                if ($who.kind -eq 'grupo' -and -not $who.respond) { Refuse 'grupo_sem_autorizacao' 'em grupo o assistente só lê e leva ao dono; responder exige autorização prévia dele (allow add -Chat <grupo>)' }
                # Pedido direto do dono numa sessão interativa vence a triagem e a conversa assumida, só para este envio.
                if ($Autonomy -eq 'triagem' -and -not $OwnerRequested) { Refuse 'modo_triagem' 'em triagem o assistente não responde sozinho: leve ao dono e envie só com o ok dele (-OwnerRequested)' }
                if ((Test-Hold $Chat) -and -not $OwnerRequested) { Refuse 'dono_assumiu' "o dono falou nessa conversa há menos de $HoldMinutes min (ou pediu espera manual)" }
            }
            $linked = (Invoke-Mcp 'whatsapp_status' @{}).wacli.linked_jid
            if (-not $AccountJid -or (Get-PhoneKey $linked) -ne (Get-PhoneKey $AccountJid)) { Refuse 'conta_nao_e_a_configurada' 'a conta conectada no app não é a do ASSISTENTE_CONTA_JID' }
            # Primeiro contato: sem histórico e sem envio anterior exige confirmação do número pelo dono.
            $known = $toOwner -or (Test-ContactedByUs $Chat)
            if (-not $known) { try { $known = @((Invoke-Mcp 'get_chat_messages' @{ chat_jid = $Chat; limit = 1 }).messages).Count -gt 0 } catch { $known = $false } }
            if (-not $known -and -not $NewContactConfirmed) { Refuse 'primeiro_contato_sem_confirmacao' 'rode resolve -Name, mostre os candidatos ao dono e use -NewContactConfirmed só depois que ele confirmar este número' }
            if ($DryRun) { Out-Json ([ordered]@{ sent = $false; dry_run = $true; chat = $Chat; text = $msg }); exit 0 }
            # Marcação: cada @<número com DDI> no texto vai também em mentions, para o WhatsApp mostrar o nome e notificar.
            $sendArgs = @{ to = $Chat; text = $msg }
            $mentions = @([regex]::Matches($msg, '(?<![\w@])@(\d{10,15})\b') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
            if ($mentions.Count -gt 0) { $sendArgs['mentions'] = $mentions }
            $r = Invoke-Mcp 'send_text_message' $sendArgs
            if ($r.message_id) { Add-SentLine $Chat $r.message_id }
            Out-Json ([ordered]@{ sent = [bool]$r.sent; message_id = $r.message_id; note = $r.note }); exit 0
        }
        'heartbeat' { $h = Get-Heartbeat $MaxAgeSeconds; Out-Json $h; if ($h.status -eq 'ok') { exit 0 } else { exit 2 } }
        'team' {
            $team = Read-Team
            if ($Chat) {
                if (Test-IsNotifyChat $Chat) { Out-Json ([ordered]@{ chat = $Chat; kind = 'dono'; name = $OwnerName; respond = $true }); exit 0 }
                $who = Find-TeamEntry $team $Chat
                if (-not $who) { Out-Json ([ordered]@{ chat = $Chat; kind = 'fora_do_time'; respond = $false; regra = 'não responde; só com pedido explícito do dono (allow add)' }); exit 2 }
                $e = $who.entry
                Out-Json ([ordered]@{ chat = $Chat; kind = $who.kind; name = $who.name; respond = $who.respond; role = $e.role; focus = $e.focus; github = $e.github; rules = $e.rules; note = $e.note; on_hold = (Test-Hold $Chat) })
                exit 0
            }
            Out-Json ([ordered]@{
                    file    = $TeamPath; exists = (Test-Path -LiteralPath $TeamPath)
                    members = @($team.members | ForEach-Object { [ordered]@{ name = $_.name; role = $_.role; focus = $_.focus; github = $_.github; jid = (Mask (@($_.jids)[0])); rules = $_.rules } })
                    groups  = @($team.groups | ForEach-Object { [ordered]@{ name = $_.name; jid = $_.jid; respond = [bool]$_.respond } })
                    extra   = @($team.extra | ForEach-Object { [ordered]@{ name = $_.name; jid = (Mask $_.jid); until = $_.until; note = $_.note } })
                })
            exit 0
        }
        'allow' {
            if ($Action -eq 'list') { $t = Read-Team; Out-Json ([ordered]@{ groups_respond = @($t.groups | Where-Object { $_.respond } | ForEach-Object { $_.name }); extra = @($t.extra) }); exit 0 }
            if (@('add', 'remove') -notcontains $Action) { throw 'allow: use add | remove | list' }
            if (-not $Chat) { throw 'informe -Chat' }
            if (-not (Test-Path -LiteralPath $TeamPath)) { throw "arquivo da equipe não existe: $TeamPath" }
            $res = Invoke-Locked 'team' {
                $t = Read-Team
                $key = Get-PhoneKey $Chat
                if ($key -like 'g:*') {
                    $g = @($t.groups | Where-Object { (Get-PhoneKey $_.jid) -eq $key }) | Select-Object -First 1
                    if (-not $g) {
                        if ($Action -eq 'remove') { return [ordered]@{ changed = $false; reason = 'grupo não está na lista' } }
                        $g = [pscustomobject][ordered]@{ name = $(if ($Name) { $Name } else { $Chat }); jid = $Chat; respond = $false }
                        $t.groups = @($t.groups) + @($g)
                    }
                    $g | Add-Member -Force -NotePropertyName respond -NotePropertyValue ($Action -eq 'add')
                    if ($Note) { $g | Add-Member -Force -NotePropertyName note -NotePropertyValue $Note }
                }
                else {
                    $t.extra = @($t.extra | Where-Object { (Get-PhoneKey $_.jid) -ne $key })
                    if ($Action -eq 'add') {
                        $x = [ordered]@{ name = $(if ($Name) { $Name } else { $Chat }); jid = (Get-BaseJid $Chat); added = (Iso (Now-Utc)); note = $Note }
                        if ($Due) { $x['until'] = Iso ([DateTimeOffset]::Parse($Due)) }
                        $t.extra = @($t.extra) + @([pscustomobject]$x)
                    }
                }
                Write-JsonFile $TeamPath $t
                [ordered]@{ changed = $true; action = $Action; chat = $Chat }
            }
            Out-Json $res; exit 0
        }
        'hold' {
            switch ($Action) {
                'on' { if (-not $Chat -or $Chat -eq 'all') { throw 'informe -Chat <jid>' }; $c = Set-Hold $Chat $true $(if ($Note) { $Note } else { 'manual' }); Out-Json ([ordered]@{ on_hold = $true; changed = $c; chat = $Chat }); exit 0 }
                'off' { if (-not $Chat) { throw 'informe -Chat <jid> ou -Chat all' }; $c = Set-Hold $Chat $false ''; Out-Json ([ordered]@{ on_hold = $false; changed = $c; chat = $Chat }); exit 0 }
                default { Out-Json ([ordered]@{ holds = (Get-HoldMap) }); exit 0 }
            }
        }
        'followup' { Invoke-Followup $Action; exit $script:FollowupRc }
        'pause' {
            switch ($Action) {
                'on' { [IO.File]::WriteAllText($PausePath, ((Iso (Now-Utc)) + ' ' + $Note), $Utf8); Out-Json ([ordered]@{ paused = $true }); exit 0 }
                'off' { if (Test-Path -LiteralPath $PausePath) { Remove-Item -LiteralPath $PausePath -Force }; Out-Json ([ordered]@{ paused = $false }); exit 0 }
                default { $on = Test-Path -LiteralPath $PausePath; Out-Json ([ordered]@{ paused = $on }); if ($on) { exit 2 } else { exit 0 } }
            }
        }
        'intro-needed' {
            # Apresenta só a quem nunca recebeu mensagem do assistente: nem pelo registro, nem no histórico do chat,
            # nem marcado no equipe.json (knows_assistant). Sem reapresentação por tempo.
            if (-not $Chat) { throw 'informe -Chat' }
            $who = Find-TeamEntry (Read-Team) $Chat
            $why = ''
            if (Test-ContactedByUs $Chat) { $why = 'ja_falou' }
            elseif ($who -and $who.entry.knows_assistant) { $why = 'conhece_pela_equipe' }
            else {
                try {
                    $hist = @((Invoke-Mcp 'get_chat_messages' @{ chat_jid = $Chat; limit = 500; order = 'newest' }).messages)
                    $pfx = Get-PrefixText
                    if (@($hist | Where-Object { $_.from_me -and ([string]$_.text).TrimStart().StartsWith($pfx) }).Count -gt 0) { $why = 'ja_conhece_pelo_historico' }
                }
                catch { $why = 'historico_indisponivel_nao_apresentar' }
            }
            $need = -not $why
            if ($need) { $why = 'nunca_falou' }
            Out-Json ([ordered]@{ chat = $Chat; intro_needed = $need; reason = $why }); exit 0
        }
        'now' {
            # Hora certa para escrever: no fuso do dono e no do time. Com -Due, converte esse instante (ex.: o UTC das ferramentas).
            $at = if ($Due) { [DateTimeOffset]::Parse($Due, [Globalization.CultureInfo]::InvariantCulture) } else { Now-Utc }
            $o = Format-InFuso $at (Resolve-Fuso $OwnerFusoName)
            $t = Format-InFuso $at (Resolve-Fuso $TeamFusoName)
            Out-Json ([ordered]@{ instante_utc = (Iso $at.ToUniversalTime()); dono = $o; time = $t; mesmo_fuso = ($o.fuso -eq $t.fuso); regra = 'ao dono, no fuso dele; ao time, no fuso do time; se forem diferentes, escreva o fuso ao lado do horário' })
            exit 0
        }
        'name-key' { Write-Output (Get-NameKey $Text); exit 0 }
        'name-match' { $m = Get-WordMatch $Text $Name; if ($m) { Write-Output $m; exit 0 } else { Write-Output 'nenhum'; exit 1 } }
        'resolve' { $r = Resolve-Recipient $Name; Out-Json $r; if ($r.status -eq 'unique') { exit 0 } else { exit 2 } }
        'config' {
            $o = [ordered]@{ config_file = $ConfigPath; config_file_exists = (Test-Path -LiteralPath $ConfigPath) }
            foreach ($k in 'ASSISTENTE_NOME', 'ASSISTENTE_DONO', 'ASSISTENTE_CONTA_JID', 'ASSISTENTE_AVISO_JID', 'ASSISTENTE_MCP_URL', 'ASSISTENTE_AUTONOMIA', 'ASSISTENTE_GENERO', 'ASSISTENTE_FUSO', 'ASSISTENTE_FUSO_TIME', 'ASSISTENTE_ESPERA_MIN', 'ASSISTENTE_EQUIPE', 'ASSISTENTE_PERSONA', 'ASSISTENTE_PASTA_TRABALHO', 'ASSISTENTE_DESPACHANTE', 'ASSISTENTE_CLAUDE_PERMISSAO') {
                $v = Get-Cfg $k
                if ($k -like '*JID' -and $v) { $v = Mask $v }
                $o[$k] = $v
            }
            $o['ASSISTENTE_MCP_TOKEN'] = $(if ($McpToken) { '(definido)' } else { '' })
            $o['ASSISTENTE_AVISO_JID_efetivo'] = (Mask $NotifyJid)
            $o['ASSISTENTE_STATE_DIR'] = $StateDir
            Out-Json $o; exit 0
        }
    }
}
catch {
    Write-Output ("ERRO {0}" -f $_.Exception.Message)
    exit 1
}
