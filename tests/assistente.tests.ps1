# Testes do assistente-wpp, sem WhatsApp de verdade: tudo roda num diretório temporário e contra um gateway MCP
# falso (fake-mcp.ps1). Saída: uma linha por teste; código 1 se algum falhar.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\assistente.tests.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$scripts = Join-Path $repo 'skills\assistente-wpp\scripts'
$AssistScript = Join-Path $scripts 'assistente.ps1'
$vigia = Join-Path $scripts 'assistente-vigia.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('assistente-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$utf8 = New-Object Text.UTF8Encoding $false

# Isolamento: nada lê a configuração real, nada alcança o app real (porta 9 fechada), nada sobe o despachante.
$keys = 'ASSISTENTE_HOME', 'ASSISTENTE_CONFIG_FILE', 'ASSISTENTE_STATE_DIR', 'ASSISTENTE_MCP_URL', 'ASSISTENTE_NOME', 'ASSISTENTE_DONO', 'ASSISTENTE_CONTA_JID', 'ASSISTENTE_AVISO_JID', 'ASSISTENTE_AUTONOMIA', 'ASSISTENTE_DESPACHANTE', 'ASSISTENTE_SEM_TOAST', 'ASSISTENTE_EQUIPE', 'ASSISTENTE_PERSONA', 'ASSISTENTE_AVISO_SESSAO', 'ASSISTENTE_AVISO_LINK', 'ASSISTENTE_DESPACHADO', 'CLAUDE_CONFIG_DIR', 'CLAUDE_CODE_ENTRYPOINT'
$saved = @{}; foreach ($k in $keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $null) }
$env:ASSISTENTE_HOME = $tmp
$env:ASSISTENTE_CONFIG_FILE = Join-Path $tmp 'assistente.env'
$env:ASSISTENTE_MCP_URL = 'http://127.0.0.1:9/mcp'
$env:ASSISTENTE_DESPACHANTE = '0'
$env:ASSISTENTE_SEM_TOAST = '1'
$fails = 0

function Check([string]$Name, [bool]$Ok, [string]$Got = '') {
    if ($Ok) { Write-Output "ok    $Name" } else { Write-Output "FALHA $Name  -> $Got"; $script:fails++ }
}
function Run([string[]]$ArgList) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $AssistScript @ArgList
    [pscustomobject]@{ Out = ($out -join "`n"); Rc = $LASTEXITCODE }
}
function J($r) { try { $r.Out | ConvertFrom-Json } catch { $null } }
function Reason($r) { $j = J $r; if ($j) { $j.reason } else { $r.Out } }
function IsoAgo([int]$Minutes) { [DateTimeOffset]::UtcNow.AddMinutes(-$Minutes).ToString('yyyy-MM-ddTHH:mm:ssK') }

try {
    # --- higiene do repositório público ---
    $bad = @(Get-ChildItem -LiteralPath $repo -Recurse -File | Where-Object { $_.Extension -eq '.ps1' } | Where-Object {
            $b = [IO.File]::ReadAllBytes($_.FullName); -not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) })
    Check 'repo: todo .ps1 tem BOM UTF-8 (Windows PowerShell 5.1 lê acentos certo)' ($bad.Count -eq 0) (($bad | ForEach-Object { $_.Name }) -join ', ')
    $leak = @(Get-ChildItem -LiteralPath $repo -Recurse -File | Where-Object { $_.FullName -notmatch '\\\.git\\' } |
        Select-String -Pattern '\d{12,13}@s\.whatsapp\.net' | Where-Object { $_.Line -notmatch '\b5500\d{8,9}@|\b120363000000' })
    Check 'repo: nenhum número de telefone real' ($leak.Count -eq 0) (($leak | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) -join ', ')

    # --- nome do assistente: reservados recusados, nomes comuns aceitos ---
    # Os nomes reservados não aparecem no repositório: o código guarda só o hash. Quem os conhece passa a lista em
    # ASSISTENTE_TESTE_RESERVADOS (separada por vírgula) para testar a recusa e garantir que nenhum vazou no repo.
    $reserved = @(([string]$env:ASSISTENTE_TESTE_RESERVADOS -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($reserved.Count -eq 0) { Write-Output 'pulo  nomes reservados (ASSISTENTE_TESTE_RESERVADOS vazio)' }
    $resFails = 0
    foreach ($w in $reserved) {
        $variants = @($w, $w.ToUpperInvariant(), ('A ' + $w), ($w + 'inha'), ($w.Substring(0, 1) + '.' + $w.Substring(1)))
        foreach ($n in $variants) {
            $r = Run @('setup', '-Name', $n, '-Owner', 'Teste')
            $okR = (($r.Rc -eq 2) -and ((Reason $r) -match 'nome_reservado|nome_so_com'))
            if (-not $okR) { $resFails++; Write-Output "      variante nº $([array]::IndexOf($variants, $n)) passou: $(Reason $r)" }
        }
        $hits = @(Get-ChildItem -LiteralPath $repo -Recurse -File | Where-Object { $_.FullName -notmatch '\\\.git\\' } | Select-String -SimpleMatch $w)
        Check "repo: nome reservado nº $([array]::IndexOf($reserved, $w) + 1) não aparece em nenhum arquivo" ($hits.Count -eq 0) (($hits | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) -join ', ')
    }
    if ($reserved.Count -gt 0) { Check 'nome: variantes dos nomes reservados são recusadas' ($resFails -eq 0) }
    foreach ($n in @('X', 'Nome Comprido Demais Para Caber', 'Bia!')) {
        Check "nome: '$n' é recusado por formato" ((Run @('setup', '-Name', $n)).Rc -eq 2)
    }
    Check 'nome: nada foi gravado depois das recusas' (-not (Test-Path -LiteralPath $env:ASSISTENTE_CONFIG_FILE))
    $r = Run @('setup', '-Name', 'Jarvis', '-Owner', 'Dev Teste', '-Mode', 'responder')
    Check 'setup: nome válido é gravado no .env' (($r.Rc -eq 0) -and ((Get-Content -Raw -Encoding UTF8 $env:ASSISTENTE_CONFIG_FILE) -match '(?m)^ASSISTENTE_NOME=Jarvis\r?$')) $r.Out
    Check 'setup: o .env nasce do exemplo, com os comentários' ((Get-Content -Raw -Encoding UTF8 $env:ASSISTENTE_CONFIG_FILE) -match 'ASSISTENTE_MCP_URL=')
    foreach ($n in @('Bia', 'Ana Clara', 'Zé')) { Check "nome: '$n' é aceito" ((Run @('setup', '-Name', $n)).Rc -eq 0) }
    $null = Run @('setup', '-Name', 'Jarvis')

    # --- prefixo com o nome configurado ---
    foreach ($c in @(@('Oi!', '*Jarvis:* Oi!'), @('*Jarvis:* Oi!', '*Jarvis:* Oi!'), @('**Jarvis:** Oi!', '*Jarvis:* Oi!'), @('jarvis: Oi!', '*Jarvis:* Oi!'), @('*Jarvis:* *Jarvis:* Oi!', '*Jarvis:* Oi!'))) {
        $r = Run @('prefix', '-Text', $c[0])
        Check "prefixo: '$($c[0])'" ($r.Out -eq $c[1]) $r.Out
    }
    Check 'prefixo: mensagem vazia é recusada' ((Run @('prefix', '-Text', '*Jarvis:*  ')).Rc -ne 0)

    # --- check e persona ---
    $ck = Run @('check')
    Check 'check: sem conta, persona e equipe não está pronto (rc 2)' (($ck.Rc -eq 2) -and ((J $ck).problems.Count -ge 3)) $ck.Out
    $pl = J (Run @('persona', 'list'))
    $names = @($pl.presets | ForEach-Object { $_.preset })
    Check 'persona: os quatro presets aparecem, com resumo' ((@('cordial', 'leve', 'objetiva', 'tecnica') | Where-Object { $names -contains $_ }).Count -eq 4 -and -not (@($pl.presets | Where-Object { -not $_.resumo }).Count)) ($names -join ',')
    Check 'persona: preset inexistente é recusado' ((Run @('persona', 'use', '-Name', 'inexistente')).Rc -eq 2)
    $pu = Run @('persona', 'use', '-Name', 'cordial')
    $pp = Join-Path $tmp 'persona.md'
    Check 'persona: use copia o preset e abre "Ajustes do dono"' (($pu.Rc -eq 0) -and ((Get-Content -Raw -Encoding UTF8 $pp) -match 'Cordial') -and ((Get-Content -Raw -Encoding UTF8 $pp) -match 'Ajustes do dono')) $pu.Out
    Add-Content -LiteralPath $pp -Value '- 2026-11-18: sem emoji.' -Encoding UTF8
    $pu2 = Run @('persona', 'use', '-Name', 'tecnica')
    Check 'persona: não sobrescreve os ajustes do dono sem -Force' (($pu2.Rc -eq 2) -and ((Get-Content -Raw -Encoding UTF8 $pp) -match 'sem emoji')) $pu2.Out
    $pu3 = Run @('persona', 'use', '-Name', 'tecnica', '-Force')
    Check 'persona: com -Force troca e guarda backup da anterior' (($pu3.Rc -eq 0) -and ((Get-Content -Raw -Encoding UTF8 $pp) -match 'Técnica') -and @(Get-ChildItem -LiteralPath $tmp -Filter 'persona.md.bak-*').Count -eq 1) $pu3.Out

    # --- equipe ---
    $acct = '5500900000100@s.whatsapp.net'
    $memberJid = '5500912340001@s.whatsapp.net'; $memberOld = '550012340001@s.whatsapp.net'
    $strangerJid = '5500912349999@s.whatsapp.net'; $groupJid = '120363000000000001@g.us'
    $team = [ordered]@{
        members = @([ordered]@{ name = 'Dev Teste'; jids = @($memberJid); lids = @('111222333@lid'); role = 'dev'; github = 'devteste' })
        groups  = @([ordered]@{ name = 'Grupo Teste'; jid = $groupJid; respond = $false })
        extra   = @()
    }
    [IO.File]::WriteAllText((Join-Path $tmp 'equipe.json'), ($team | ConvertTo-Json -Depth 6), $utf8)
    $null = Run @('setup', '-Jid', $acct)
    $ck2 = Run @('check')
    Check 'check: com nome, dono, conta, persona e equipe fica pronto (rc 0)' ($ck2.Rc -eq 0) $ck2.Out
    Check 'equipe: número sem o nono dígito é a mesma pessoa' (((J (Run @('team', '-Chat', $memberOld))).name) -eq 'Dev Teste')
    Check 'equipe: @lid conhecido é a mesma pessoa' ((Run @('team', '-Chat', '111222333@lid')).Rc -eq 0)
    Check 'equipe: estranho é fora do time (rc 2)' ((Run @('team', '-Chat', $strangerJid)).Rc -eq 2)
    Check 'equipe: a conversa de avisos é o dono' (((J (Run @('team', '-Chat', $acct))).kind) -eq 'dono')
    $tl = (Run @('team')).Out
    Check 'equipe: listagem não mostra o telefone inteiro' (($tl -like '*0001*') -and ($tl -notlike '*5500912340001*')) $tl

    # --- travas do send (DryRun; a rede é a porta fechada) ---
    $tk = [string](J (Run @('lease', 'acquire', '-Operator', 'claude', '-TtlSeconds', '600'))).fencing_token
    Check 'lease: codex é recusado enquanto o claude tem o volante' ((Run @('lease', 'acquire', '-Operator', 'codex')).Rc -eq 2)
    function Send([string]$chat, [string[]]$More = @()) { Run (@('send', '-Chat', $chat, '-Text', 'oi', '-Operator', 'claude', '-Token', $tk, '-DryRun') + $More) }
    Check 'send: token errado é recusado' ((Reason (Run @('send', '-Chat', $memberJid, '-Text', 'oi', '-Operator', 'claude', '-Token', '999', '-DryRun'))) -eq 'lease_invalido')
    Check 'send: fora do time é recusado' ((Reason (Send $strangerJid)) -eq 'fora_do_time_sem_pedido')
    Check 'send: grupo sem autorização é recusado' ((Reason (Send $groupJid)) -eq 'grupo_sem_autorizacao')
    $null = Run @('hold', 'on', '-Chat', $memberOld)
    Check 'send: conversa em espera manual é recusada (mesmo número sem o nono dígito)' ((Reason (Send $memberJid)) -eq 'dono_assumiu')
    $null = Run @('hold', 'off', '-Chat', 'all')
    function Set-HoldFile([string]$Why, [int]$AgoMin) { [IO.File]::WriteAllText((Join-Path $tmp 'state\holds.json'), ('{"chats":{"550012340001":{"chat":"' + $memberJid + '","since":"' + (IsoAgo $AgoMin) + '","why":"' + $Why + '","last_owner":"' + (IsoAgo $AgoMin) + '"}}}'), $utf8) }
    Set-HoldFile 'o dono escreveu na conversa' 5
    Check 'espera: automática com o dono ativo (5 min) segue recusando' ((Reason (Send $memberJid)) -eq 'dono_assumiu')
    Set-HoldFile 'o dono escreveu na conversa' 20
    Check 'espera: automática vencida (20 min) não trava mais' ((Reason (Send $memberJid)) -ne 'dono_assumiu')
    Set-HoldFile 'manual' 300
    Check 'espera: manual não vence com o tempo' ((Reason (Send $memberJid)) -eq 'dono_assumiu')
    Check 'espera: pedido direto do dono passa (-OwnerRequested)' ((Reason (Send $memberJid @('-OwnerRequested'))) -notmatch 'dono_assumiu')
    $null = Run @('hold', 'off', '-Chat', 'all')
    $s = Send $memberJid
    Check 'send: membro do time passa as travas e só para na rede' (($s.Rc -ne 0) -and ((Reason $s) -notmatch 'fora_do_time|grupo_sem|dono_assumiu|lease|triagem')) $s.Out
    $s = Send $acct
    Check 'send: aviso ao dono passa as travas de time' (($s.Rc -ne 0) -and ((Reason $s) -notmatch 'fora_do_time|grupo_sem|dono_assumiu|lease|triagem')) $s.Out
    $env:ASSISTENTE_AUTONOMIA = 'triagem'
    Check 'triagem: responder ao time é recusado' ((Reason (Send $memberJid)) -eq 'modo_triagem')
    Check 'triagem: com o ok do dono passa' ((Reason (Send $memberJid @('-OwnerRequested'))) -ne 'modo_triagem')
    Check 'triagem: aviso ao dono continua passando' ((Reason (Send $acct)) -ne 'modo_triagem')
    $env:ASSISTENTE_AUTONOMIA = $null
    $null = Run @('allow', 'add', '-Chat', $strangerJid, '-Name', 'Convidado', '-Due', '2099-01-01T00:00:00-03:00')
    Check 'allow: pedido do dono libera o contato' (((J (Run @('team', '-Chat', $strangerJid))).kind) -eq 'extra')
    $null = Run @('allow', 'remove', '-Chat', $strangerJid)
    Check 'allow: removido, volta a ser fora do time' ((Run @('team', '-Chat', $strangerJid)).Rc -eq 2)
    $null = Run @('allow', 'add', '-Chat', '5500912348888@s.whatsapp.net', '-Due', '2020-01-01T00:00:00-03:00')
    Check 'allow: liberação vencida não vale' ((Run @('team', '-Chat', '5500912348888@s.whatsapp.net')).Rc -eq 2)
    $ho = (Run @('help')).Out
    Check 'help: com o app fechado, mostra a conexão inativa e não quebra' (($ho -match 'Manual de Jarvis') -and ($ho -match '\[inativo\] App WhatsApp MCP')) $ho
    $null = Run @('pause', 'on')
    Check 'pausa: send recusado' ((Reason (Send $memberJid)) -eq 'pausado')
    $null = Run @('pause', 'off')

    # --- aviso de sessão: texto por editor (DryRun, sem envio) ---
    $aviso = Join-Path $scripts 'aviso-sessao.ps1'
    $sid = '0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0'
    $tpath = Join-Path $tmp 'transcript.jsonl'
    [IO.File]::WriteAllText($tpath, ('{"type":"ai-title","aiTitle":"Revisar *filtro* do lote"}' + "`n" + '{"type":"bridge-session","bridgeSessionId":"cse_ABC123"}' + "`n"), $utf8)
    $hookIn = (@{ session_id = $sid; transcript_path = $tpath; cwd = 'C:\dev\projeto-x' } | ConvertTo-Json -Compress)
    function Run-Aviso([string]$Ep, [string[]]$More = @()) {
        $avDir = Join-Path $tmp 'state\avisos'; New-Item -ItemType Directory -Force -Path $avDir | Out-Null
        [IO.File]::WriteAllText((Join-Path $avDir "turno-$sid.txt"), [string]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 125))
        $env:CLAUDE_CODE_ENTRYPOINT = $Ep
        $o = $hookIn | & powershell -NoProfile -ExecutionPolicy Bypass -File $aviso -DryRun @More
        $env:CLAUDE_CODE_ENTRYPOINT = $null
        $o -join "`n"
    }
    $a = Run-Aviso 'claude-vscode'
    Check 'aviso: título sem formatação do WhatsApp e duração' ($a -match 'A sessão \*Revisar filtro do lote\* parou e espera você \(2min \d+s\)') $a
    Check 'aviso: VS Code leva o link pelo vscode.dev' ($a -match ('PC \(VS Code\): https://vscode\.dev/redirect\?url=vscode%3A%2F%2Fanthropic\.claude-code%2Fopen%3Fsession%3D' + $sid)) $a
    Check 'aviso: Remote Control leva o link do celular' ($a -match 'Celular \(Remote Control\): https://claude\.ai/code/session_ABC123') $a
    $a = Run-Aviso 'cli'
    Check 'aviso: CLI leva a pasta e o comando de retomar' (($a -match ('projeto-x: `claude --resume ' + $sid + '`')) -and ($a -notmatch 'vscode')) $a
    $a = Run-Aviso 'sdk-ts'
    Check 'aviso: T3 Code (Agent SDK) avisa e diz onde abrir' ($a -match 'PC \(T3 Code\): abra a conversa') $a
    $env:ASSISTENTE_AVISO_LINK = 'meuapp://abrir?s={session}'
    $a = Run-Aviso 'sdk-ts'
    Check 'aviso: link próprio do dono vence o padrão' (($a -match ('Abrir: meuapp://abrir\?s=' + $sid)) -and ($a -notmatch 'T3 Code')) $a
    $env:ASSISTENTE_AVISO_LINK = $null
    $env:ASSISTENTE_DESPACHADO = '1'
    $a = Run-Aviso 'sdk-cli'
    $env:ASSISTENTE_DESPACHADO = $null
    Check 'aviso: execução do despachante não avisa' (-not $a) $a
    $avDir = Join-Path $tmp 'state\avisos'
    [IO.File]::WriteAllText((Join-Path $avDir "turno-$sid.txt"), [string]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 20))
    $a = ($hookIn | & powershell -NoProfile -ExecutionPolicy Bypass -File $aviso -DryRun) -join "`n"
    Check 'aviso: turno curto (20 s) não avisa' (-not $a) $a
    $a = ((@{ session_id = $sid; transcript_path = $tpath; cwd = 'C:\dev\projeto-x'; notification_type = 'permission_prompt' } | ConvertTo-Json -Compress) | & powershell -NoProfile -ExecutionPolicy Bypass -File $aviso -Mode wait -DryRun) -join "`n"
    Check 'aviso: espera de autorização' ($a -match 'está esperando sua autorização') $a

    # --- instalador: hooks no settings.json sem tocar nos do usuário ---
    $inst = Join-Path $tmp 'inst'; New-Item -ItemType Directory -Force -Path $inst | Out-Null
    $sj = Join-Path $inst 'settings.json'
    [IO.File]::WriteAllText($sj, '{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"meu-hook.exe"}]}]}}', $utf8)
    $ia = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $repo 'install.ps1'), '-SemVigia', '-SkillsRoot', (Join-Path $inst 'skills'), '-PrivateDir', (Join-Path $inst 'priv'), '-ClaudeSettings', $sj)
    $null = & powershell @ia
    $null = & powershell @ia
    $st = Get-Content -Raw $sj | ConvertFrom-Json
    function Count-Ours($ev) { @(@($st.hooks.$ev) | ForEach-Object { $_.hooks } | Where-Object { (@($_.args) -join ' ') -like '*assistente-wpp\scripts\aviso-sessao*' }).Count }
    Check 'instalador: registra um hook de cada (idempotente em duas rodadas)' ((Count-Ours 'Stop') -eq 1 -and (Count-Ours 'UserPromptSubmit') -eq 1 -and (Count-Ours 'Notification') -eq 1 -and (Count-Ours 'PreToolUse') -eq 1) (Get-Content -Raw $sj)
    Check 'instalador: mantém o hook e as chaves do usuário' ((@($st.hooks.Stop | ForEach-Object { $_.hooks } | Where-Object { $_.command -eq 'meu-hook.exe' }).Count -eq 1) -and ($st.model -eq 'x'))
    Check 'instalador: copia a skill com manifesto' ((Test-Path (Join-Path $inst 'skills\assistente-wpp\SKILL.md')) -and (Test-Path (Join-Path $inst 'skills\assistente-wpp\.install-manifest.json')))
    $null = & powershell ($ia + '-SemAvisoSessao')
    $st = Get-Content -Raw $sj | ConvertFrom-Json
    Check 'instalador: -SemAvisoSessao tira só os nossos' (((Count-Ours 'Stop') + (Count-Ours 'UserPromptSubmit') + (Count-Ours 'Notification') + (Count-Ours 'PreToolUse')) -eq 0 -and (@($st.hooks.Stop | ForEach-Object { $_.hooks } | Where-Object { $_.command -eq 'meu-hook.exe' }).Count -eq 1)) (Get-Content -Raw $sj)

    # --- gateway falso: detector e vigia de ponta a ponta ---
    $fake = Join-Path $tmp 'fake'; New-Item -ItemType Directory -Force -Path $fake | Out-Null
    function Set-Responses([hashtable]$Map) { [IO.File]::WriteAllText((Join-Path $fake 'responses.json'), ($Map | ConvertTo-Json -Depth 6), $utf8) }
    function Get-Requests { $p = Join-Path $fake 'requests.jsonl'; if (Test-Path -LiteralPath $p) { @(Get-Content -LiteralPath $p -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() } }
    function Wait-Until([scriptblock]$Cond, [int]$Seconds = 20) { $end = (Get-Date).AddSeconds($Seconds); while ((Get-Date) -lt $end) { if (& $Cond) { return $true }; Start-Sleep -Milliseconds 300 }; $false }
    $probe = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, 0); $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
    Set-Responses @{}
    $fakeProc = Start-Process powershell -NoNewWindow -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $PSScriptRoot 'fake-mcp.ps1')`"", '-Port', $port, '-Dir', "`"$fake`"")
    try {
        Check 'gateway falso: subiu' (Wait-Until { Test-Path -LiteralPath (Join-Path $fake 'ready') } 15)
        $env:ASSISTENTE_MCP_URL = "http://127.0.0.1:$port/mcp"
        $status = @{ text = ('{"wacli":{"linked_jid":"' + $acct + '"}}') }
        $chats = '{"chats":[{"jid":"' + $memberJid + '","last_message_ts":"' + (IsoAgo 0) + '"},{"jid":"' + $strangerJid + '","last_message_ts":"' + (IsoAgo 0) + '"},{"jid":"' + $groupJid + '","last_message_ts":"' + (IsoAgo 0) + '"},{"jid":"' + $acct + '","last_message_ts":"' + (IsoAgo 0) + '"}]}'
        function Set-Cursor { $c = @{}; foreach ($j in $memberJid, $strangerJid, $groupJid, $acct) { $c[$j] = (IsoAgo 60) }; [IO.File]::WriteAllText((Join-Path $tmp 'state\wpp-cursor.json'), (@{ updated_at = (IsoAgo 60); chats = $c } | ConvertTo-Json), $utf8) }
        function Msg([bool]$FromMe, [string]$Id, [string]$Text = 'oi') { '{"messages":[{"id":"' + $Id + '","timestamp":"' + (IsoAgo 1) + '","from_me":' + $(if ($FromMe) { 'true' } else { 'false' }) + ',"text":"' + $Text + '"}]}' }

        Set-Cursor
        Set-Responses @{ whatsapp_status = $status; list_chats = @{ text = $chats }; get_chat_messages = @{ text = (Msg $false 'IN-1') } }
        $before = @(Get-Requests).Count
        $w = Run @('watch', '-Once')
        $read = @(Get-Requests | Select-Object -Skip $before | Where-Object { $_.tool -eq 'get_chat_messages' } | ForEach-Object { $_.arguments.chat_jid })
        Check 'detector: mensagem do time vira EVENT inbound equipe' ($w.Out -match ('EVENT inbound equipe chat=' + [regex]::Escape($memberJid) + ' quem="Dev Teste"')) $w.Out
        Check 'detector: grupo vira EVENT grupo, sem autorização para responder' ($w.Out -match ('EVENT grupo chat=' + [regex]::Escape($groupJid) + ' nome="Grupo Teste" responder=nao')) $w.Out
        Check 'detector: conversa de fora do time nem é lida' (($read -notcontains $strangerJid) -and ($read -contains $memberJid)) ($read -join ',')

        Set-Cursor
        Set-Responses @{ whatsapp_status = $status; list_chats = @{ text = $chats }; get_chat_messages = @{ text = (Msg $true 'DONO-1' 'manda pro Dev que ok') } }
        $w = Run @('watch', '-Once')
        Check 'detector: o dono escreveu do celular -> EVENT assumido e espera' (($w.Out -match ('EVENT assumido chat=' + [regex]::Escape($memberJid))) -and ((Get-Content -Raw (Join-Path $tmp 'state\holds.json')) -like '*550012340001*')) $w.Out
        Check 'detector: o dono escreveu na conversa consigo mesmo -> EVENT dono' ($w.Out -match ('EVENT dono chat=' + [regex]::Escape($acct))) $w.Out

        Set-Cursor
        Set-Responses @{ whatsapp_status = $status; list_chats = @{ text = $chats }; get_chat_messages = @{ text = (Msg $false 'IN-2') } }
        $w = Run @('watch', '-Once')
        Check 'detector: conversa em espera vira EVENT espera, não inbound' (($w.Out -match ('EVENT espera equipe chat=' + [regex]::Escape($memberJid) + '.* dono_ultima=\S+')) -and ($w.Out -notmatch 'EVENT inbound equipe')) $w.Out
        $null = Run @('hold', 'off', '-Chat', 'all')

        Set-Cursor
        Set-Responses @{ whatsapp_status = $status; list_chats = @{ text = $chats }; get_chat_messages = @{ text = (Msg $true 'SEM-REGISTRO' '*Jarvis:* aviso') } }
        $w = Run @('watch', '-Once')
        Check 'detector: mensagem com o prefixo do assistente não é tomada como do dono' (($w.Out -notmatch 'EVENT dono') -and ($w.Out -notmatch 'EVENT assumido')) $w.Out

        Set-Responses @{ whatsapp_status = @{ text = '{"wacli":{"linked_jid":"5500000000000@s.whatsapp.net"}}' }; list_chats = @{ text = $chats } }
        $w = Run @('watch', '-Once')
        Check 'detector: outra conta no app -> ERRO e nada é lido' (($w.Out -match 'ERRO a conta conectada') -and ($w.Out -notmatch 'EVENT')) $w.Out
        $s = Run @('send', '-Chat', $memberJid, '-Text', 'oi', '-Operator', 'claude', '-Token', $tk, '-DryRun')
        Check 'send: confere a conta conectada no envio' ((Reason $s) -eq 'conta_nao_e_a_configurada') $s.Out

        Set-Responses @{ whatsapp_status = $status; get_chat_messages = @{ text = '{"messages":[]}' }; send_text_message = @{ text = '{"sent":true,"message_id":"FAKE-1"}' } }
        $s = Run @('send', '-Chat', $memberJid, '-Text', 'Oi, Dev!', '-Operator', 'claude', '-Token', $tk)
        Check 'send: primeiro contato sem histórico exige confirmação do dono' ((Reason $s) -eq 'primeiro_contato_sem_confirmacao') $s.Out
        $s = Run @('send', '-Chat', $memberJid, '-Text', 'Oi, Dev!', '-Operator', 'claude', '-Token', $tk, '-NewContactConfirmed')
        $sent = @(Get-Requests | Where-Object { $_.tool -eq 'send_text_message' })[-1]
        Check 'send: envia com o prefixo do nome escolhido e registra' ((((J $s).sent) -eq $true) -and ($sent.arguments.text -eq '*Jarvis:* Oi, Dev!') -and ((Run @('is-ours', '-MessageId', 'FAKE-1')).Rc -eq 0)) $s.Out
        Check 'intro: quem já recebeu mensagem não é reapresentado' (((J (Run @('intro-needed', '-Chat', $memberJid))).intro_needed) -eq $false)

        # Manual (help): estado real de cada funcionalidade
        $env:CLAUDE_CONFIG_DIR = $inst
        $null = & powershell @ia   # hooks de volta no settings.json de teste
        $hp = (Run @('help')).Out
        Check 'help: título com o nome do assistente' ($hp -match 'Manual de Jarvis') $hp
        Check 'help: app conectado aparece ativo' ($hp -match '\[ativo\]\s+App WhatsApp MCP: conta \*\*\*\*0100 conectada') $hp
        Check 'help: despachante parado aparece inativo' ($hp -match '\[inativo\] Despachante') $hp
        Check 'help: personalidade e ajustes' ($hp -match '\[ativo\]\s+Personalidade: Técnica') $hp
        Check 'help: aviso de sessão ativo com os hooks registrados' ($hp -match '\[ativo\]\s+Avisar quando uma sessão para') $hp
        Check 'help: cada item diz como mudar' (([regex]::Matches($hp, 'como mudar:')).Count -ge 15) $hp
        $env:ASSISTENTE_AVISO_SESSAO = '0'
        Check 'help: aviso desligado no .env aparece inativo' ((Run @('help')).Out -match '\[inativo\] Avisar quando.*desligado no \.env')
        $env:ASSISTENTE_AVISO_SESSAO = $null
        $null = Run @('pause', 'on')
        $hj = J (Run @('help', '-Json'))
        Check 'help -Json: pausado aparece em Ligado = inativo' ((@($hj.itens | Where-Object { $_.funcionalidade -eq 'Ligado' })[0].estado) -eq 'inativo') ($hj | ConvertTo-Json -Compress -Depth 5)
        $null = Run @('pause', 'off')

        # Vigia
        function Set-Hb([int]$AgeMin) { [IO.File]::WriteAllText((Join-Path $tmp 'state\watch-heartbeat.json'), ('{"ts":"' + (IsoAgo $AgeMin) + '","pid":1,"gateway_ok":true}'), $utf8) }
        function Set-VigiaState([string]$Since, [int]$Alerts, [int]$Runs) { $ss = if ($Since) { '"' + $Since + '"' } else { 'null' }; [IO.File]::WriteAllText((Join-Path $tmp 'state\vigia-estado.json'), ('{"stale_since":' + $ss + ',"last_alert":null,"alerts":' + $Alerts + ',"stale_runs":' + $Runs + ',"last_run":"' + (IsoAgo 3) + '"}'), $utf8) }
        function Run-Vigia { $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $vigia; $LASTEXITCODE }
        function Sends { @(Get-Requests | Where-Object { $_.tool -eq 'send_text_message' }) }
        $n0 = @(Sends).Count
        Set-Hb 10; Set-VigiaState '' 0 1
        $rc = Run-Vigia
        $new = @(Sends | Select-Object -Skip $n0)
        Check 'vigia: detector parado (2ª rodada) avisa o dono com o nome do assistente, rc 2' (($rc -eq 2) -and $new.Count -eq 1 -and $new[0].arguments.to -eq $acct -and $new[0].arguments.text -like '`*Jarvis:`* ALERTA*') ($new | ConvertTo-Json -Compress -Depth 5)
        $null = Run-Vigia
        Check 'vigia: não repete o alerta antes do intervalo' (@(Sends).Count -eq $n0 + 1)
        Set-Hb 0; Set-VigiaState (IsoAgo 20) 1 3
        $rc = Run-Vigia
        Check 'vigia: recuperação avisa que voltou, rc 0' (($rc -eq 0) -and (@(Sends)[-1].arguments.text -like '*Voltou*'))
        [IO.File]::WriteAllText((Join-Path $tmp 'state\assistente.pause'), 'teste', $utf8)
        Set-Hb 10; Set-VigiaState '' 0 5
        $before = @(Get-Requests).Count
        Check 'vigia: pausado não chama o app' (((Run-Vigia) -eq 0) -and (@(Get-Requests).Count -eq $before))
        Remove-Item -LiteralPath (Join-Path $tmp 'state\assistente.pause') -Force
        $env:ASSISTENTE_CONFIG_FILE = Join-Path $tmp 'vazio.env'
        $before = @(Get-Requests).Count
        Check 'vigia: sem configuração, fica quieto (rc 0)' (((Run-Vigia) -eq 0) -and (@(Get-Requests).Count -eq $before))
        $env:ASSISTENTE_CONFIG_FILE = Join-Path $tmp 'assistente.env'
    }
    finally { if ($fakeProc) { Stop-Process -Id $fakeProc.Id -Force -ErrorAction SilentlyContinue } }
}
finally {
    foreach ($k in $keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    Start-Sleep -Milliseconds 300
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fails -gt 0) { Write-Output "$fails teste(s) falharam"; exit 1 }
Write-Output 'todos os testes passaram'
