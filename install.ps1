# Instala (ou atualiza) a skill assistente-wpp para o Claude Code, no Windows ou no macOS.
#   Windows: powershell -ExecutionPolicy Bypass -File .\install.ps1
#   macOS:   pwsh ./install.ps1        (PowerShell 7: brew install powershell)
#
#   install.ps1            instala/atualiza a skill, cria ~/.assistente-wpp e registra o vigia
#   install.ps1 -Check     só confere se a cópia instalada é igual à do repositório (rc 0 = igual)
#   install.ps1 -SemVigia  instala sem registrar o vigia (tarefa agendada no Windows, LaunchAgent no Mac)
#   install.ps1 -SemAvisoSessao  instala sem os hooks do aviso de sessão (e remove os que houver)
#   install.ps1 -Remover   remove o vigia, os hooks e a skill instalada (a pasta ~/.assistente-wpp fica)
#
# Mac: o vigia é o LaunchAgent local.assistente-wpp.vigia em ~/Library/LaunchAgents (no login e a cada 3 min).
# -LaunchAgentsDir fora da pasta padrão só grava/apaga o arquivo, sem chamar o launchctl (usado nos testes).
#
# O repositório é a fonte; a pasta instalada é um espelho copiado, com o hash de cada arquivo em
# .install-manifest.json. A configuração, a equipe, a persona e o estado ficam em ~/.assistente-wpp e
# nunca são tocados aqui.
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$SemVigia,
    [switch]$SemAvisoSessao,
    [switch]$Remover,
    [string]$SkillsRoot = (Join-Path $HOME '.claude\skills'),
    [string]$PrivateDir = (Join-Path $HOME '.assistente-wpp'),
    [string]$ClaudeSettings = (Join-Path $HOME '.claude\settings.json'),
    [string]$LaunchAgentsDir = (Join-Path $HOME 'Library/LaunchAgents')
)
$ErrorActionPreference = 'Stop'
$Skill = 'assistente-wpp'
$Src = Join-Path $PSScriptRoot "skills\$Skill"
. (Join-Path $Src 'scripts\plataforma.ps1')
$Target = Join-Path $SkillsRoot $Skill
$TaskName = 'AssistenteWppVigia'
# Atalho /voz: uma skill de um arquivo só, instalada ao lado. Só é tocada se for a nossa (tem a marca), para nunca
# sobrescrever nem apagar uma skill "voz" do próprio dev.
$VozSrc = Join-Path $PSScriptRoot 'skills\voz\SKILL.md'
$VozDir = Join-Path $SkillsRoot 'voz'
$VozDst = Join-Path $VozDir 'SKILL.md'
$VozMarca = 'Atalho instalado junto com a skill assistente-wpp'
function Test-VozNossa { -not (Test-Path -LiteralPath $VozDst) -or ((Get-Content -LiteralPath $VozDst -Raw -Encoding UTF8) -match [regex]::Escape($VozMarca)) }
$Plist = Join-Path $LaunchAgentsDir "$VigiaRotulo.plist"
$UsaLaunchctl = ($LaunchAgentsDir -eq (Join-Path $HOME 'Library/LaunchAgents'))

# Mac: tira o LaunchAgent do vigia do launchd (se carregado) e apaga o arquivo. Devolve $true se havia algo.
function Remove-VigiaMac {
    $havia = $false
    if ($UsaLaunchctl) {
        $uid = (& /usr/bin/id -u).Trim()
        if (Test-VigiaMac) { & /bin/launchctl bootout "gui/$uid/$VigiaRotulo" 2>$null; $havia = $true }
    }
    if (Test-Path -LiteralPath $Plist) { Remove-Item -LiteralPath $Plist -Force; $havia = $true }
    $havia
}

# Mac: LaunchAgent do vigia. RunAtLoad = no login; StartInterval 180 = a cada 3 min. AbandonProcessGroup deixa o
# despachante (que o vigia sobe) vivo quando o vigia termina; sem ele, o launchd derruba o grupo de processos.
# O PATH do terminal vai junto, porque o launchd começa com um PATH mínimo (sem o claude, o gh e o brew).
function Install-VigiaMac([string]$Vigia) {
    $esc = { param($s) [Security.SecurityElement]::Escape([string]$s) }
    $dirs = @(([string]$env:PATH -split ':') + @('/opt/homebrew/bin', '/usr/local/bin', (Join-Path $HOME '.local/bin'), '/usr/bin', '/bin', '/usr/sbin', '/sbin') | Where-Object { $_ } | Select-Object -Unique)
    $logDir = Join-Path (Join-Path $PrivateDir 'state') 'launchd'
    New-Item -ItemType Directory -Force -Path $logDir, $LaunchAgentsDir | Out-Null
    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$VigiaRotulo</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(& $esc (Get-PsExe))</string>
        <string>-NoProfile</string>
        <string>-File</string>
        <string>$(& $esc $Vigia)</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>180</integer>
    <key>AbandonProcessGroup</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>$(& $esc ($dirs -join ':'))</string>
    </dict>
    <key>StandardOutPath</key><string>$(& $esc (Join-Path $logDir 'vigia.out.log'))</string>
    <key>StandardErrorPath</key><string>$(& $esc (Join-Path $logDir 'vigia.err.log'))</string>
</dict>
</plist>
"@
    $null = Remove-VigiaMac
    [IO.File]::WriteAllText($Plist, $xml, (New-Object Text.UTF8Encoding $false))
    if ($UsaLaunchctl) {
        $uid = (& /usr/bin/id -u).Trim()
        $o = (& /bin/launchctl bootstrap "gui/$uid" $Plist 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "launchctl bootstrap falhou: $o" }
    }
}
$Excluded = '(^|[\\/])(\.env|\.env\.local|\.install-manifest\.json)$'

# Hooks do aviso de sessão no ~/.claude/settings.json do usuário. Remove só os nossos (identificados pelo caminho
# do script) e, com $Add, registra de novo apontando para a cópia instalada. Os demais hooks ficam como estão.
function Update-ClaudeHooks([bool]$Add) {
    $sp = $ClaudeSettings
    $marker = 'assistente-wpp[\\/]+scripts[\\/]+aviso-sessao'   # regex: \ no Windows, / no Mac
    $s = [pscustomobject]@{}
    if (Test-Path -LiteralPath $sp) {
        $rawJson = Get-Content -LiteralPath $sp -Raw -Encoding UTF8
        if ($rawJson.Trim()) { $s = $rawJson | ConvertFrom-Json }
        $bk = Join-Path $PrivateDir ('backups\settings.json.' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Force -Path (Split-Path $bk -Parent) | Out-Null
        Copy-Item -LiteralPath $sp -Destination $bk
    }
    if (-not ($s.PSObject.Properties.Name -contains 'hooks')) { $s | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
    $isOurs = { param($h) ((@($h.args) -join ' ') + ' ' + [string]$h.command) -match $marker }
    foreach ($ev in 'UserPromptSubmit', 'Stop', 'Notification', 'PreToolUse') {
        $kept = @()
        if ($s.hooks.PSObject.Properties.Name -contains $ev) {
            foreach ($g in @($s.hooks.$ev)) {
                $hs = @($g.hooks | Where-Object { -not (& $isOurs $_) })
                if ($hs.Count -gt 0) { $g.hooks = $hs; $kept += $g }
            }
        }
        if ($Add) {
            $scriptName = if ($ev -eq 'UserPromptSubmit') { 'aviso-sessao-inicio.ps1' } else { 'aviso-sessao.ps1' }
            $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Target "scripts\$scriptName"))
            if ($ev -eq 'Notification' -or $ev -eq 'PreToolUse') { $a += @('-Mode', 'wait') }
            $h = [ordered]@{ type = 'command'; command = (Get-PsExe); args = $a; timeout = $(if ($ev -eq 'UserPromptSubmit') { 10 } else { 90 }) }
            if ($ev -ne 'UserPromptSubmit') { $h['async'] = $true }
            $g = [ordered]@{ hooks = @([pscustomobject]$h) }
            if ($ev -eq 'Notification') { $g = [ordered]@{ matcher = 'permission_prompt|elicitation_dialog'; hooks = $g.hooks } }
            if ($ev -eq 'PreToolUse') { $g = [ordered]@{ matcher = 'AskUserQuestion'; hooks = $g.hooks } }
            $kept += [pscustomobject]$g
        }
        if ($kept.Count -gt 0) { $s.hooks | Add-Member -Force -NotePropertyName $ev -NotePropertyValue @($kept) }
        elseif ($s.hooks.PSObject.Properties.Name -contains $ev) { $s.hooks.PSObject.Properties.Remove($ev) }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $sp -Parent) | Out-Null
    [IO.File]::WriteAllText($sp, ($s | ConvertTo-Json -Depth 32), (New-Object Text.UTF8Encoding $false))
}

function Get-Sha([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower() }
function Get-SourceMap {
    $map = [ordered]@{}
    $dir = (Get-Item -LiteralPath $Src).FullName
    Get-ChildItem -LiteralPath $dir -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        $rel = $_.FullName.Substring($dir.Length + 1)
        if ($rel -notmatch $Excluded -and $rel -notmatch '\.tests\.ps1$') { $map[$rel] = $_.FullName }
    }
    $map
}
function Compare-Install([string]$Dir, $Map) {
    $problems = @()
    if (-not (Test-Path -LiteralPath $Dir)) { return @('não instalada') }
    foreach ($rel in $Map.Keys) {
        $dst = Join-Path $Dir $rel
        if (-not (Test-Path -LiteralPath $dst)) { $problems += "falta $rel"; continue }
        if ((Get-Sha $dst) -ne (Get-Sha $Map[$rel])) { $problems += "difere: $rel" }
    }
    $base = (Get-Item -LiteralPath $Dir).FullName
    Get-ChildItem -LiteralPath $base -Recurse -File -Force | ForEach-Object {
        $rel = $_.FullName.Substring($base.Length + 1)
        if ($rel -ne '.install-manifest.json' -and -not $Map.Contains($rel)) { $problems += "sobra $rel" }
    }
    $problems
}

if ($Remover) {
    if ($EhMac) {
        try { if (Remove-VigiaMac) { Write-Output "vigia $VigiaRotulo removido" } else { Write-Output "vigia $VigiaRotulo não existia" } } catch { Write-Output "aviso  não consegui remover o vigia: $($_.Exception.Message)" }
    }
    else { try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop; Write-Output "tarefa $TaskName removida" } catch { Write-Output "tarefa $TaskName não existia" } }
    try { Update-ClaudeHooks $false; Write-Output 'hooks do aviso de sessão removidos' } catch { Write-Output "aviso  não consegui remover os hooks: $($_.Exception.Message)" }
    $d = Join-Path $Target 'scripts\assistente-despachante.ps1'
    if (Test-Path -LiteralPath $d) { & (Get-PsExe) -NoProfile -ExecutionPolicy Bypass -File $d -Mode stop }
    if (Test-Path -LiteralPath $Target) { Remove-Item -Recurse -Force -LiteralPath $Target; Write-Output "skill removida: $Target" }
    if ((Test-Path -LiteralPath $VozDst) -and (Test-VozNossa)) { Remove-Item -Recurse -Force -LiteralPath $VozDir; Write-Output "atalho removido: $VozDir" }
    Write-Output "configuração preservada em $PrivateDir (apague à mão se quiser)"
    exit 0
}

$map = Get-SourceMap
if ($Check) {
    $p = @(Compare-Install $Target $map)
    if (-not (Test-Path -LiteralPath $VozDst)) { $p += 'falta o atalho /voz' }
    elseif ((Get-Sha $VozDst) -ne (Get-Sha $VozSrc)) { $p += 'difere: atalho /voz' }
    if ($p.Count -eq 0) { Write-Output "ok     $Target"; exit 0 }
    Write-Output "falha  $Target"; $p | ForEach-Object { Write-Output "         $_" }; exit 1
}

# Monta ao lado, confere e só então troca, para nunca deixar a skill pela metade.
New-Item -ItemType Directory -Force -Path $SkillsRoot | Out-Null
if ((Test-Path -LiteralPath $Target) -and @(Compare-Install $Target $map).Count -eq 0) { Write-Output "igual  $Target" }
else {
    $staging = "$Target.installing"
    if (Test-Path -LiteralPath $staging) { Remove-Item -Recurse -Force -LiteralPath $staging }
    $files = [ordered]@{}
    foreach ($rel in $map.Keys) {
        $dst = Join-Path $staging $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
        Copy-Item -LiteralPath $map[$rel] -Destination $dst
        $files[$rel.Replace('\', '/')] = Get-Sha $dst
    }
    $commit = ''
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.git')) { try { $commit = (& git -C $PSScriptRoot rev-parse HEAD 2>$null | Out-String).Trim() } catch { } }
    $manifest = [ordered]@{ skill = $Skill; installed_at = (Get-Date).ToString('o'); commit = "$commit"; files = $files }
    [IO.File]::WriteAllText((Join-Path $staging '.install-manifest.json'), ($manifest | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
    $bad = @(Compare-Install $staging $map)
    if ($bad.Count -gt 0) { throw "cópia não confere: $($bad -join '; ')" }
    if (Test-Path -LiteralPath $Target) {
        $bk = Join-Path $PrivateDir ('backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Force -Path $bk | Out-Null
        Move-Item -LiteralPath $Target -Destination (Join-Path $bk $Skill)
        Write-Output "backup da versão anterior em $bk"
    }
    Move-Item -LiteralPath $staging -Destination $Target
    Write-Output "instal $Target ($($files.Count) arquivos)"
}

# Atalho /voz.
if (-not (Test-VozNossa)) { Write-Output "aviso  já existe uma skill 'voz' que não é a nossa em ${VozDir}: o atalho /voz não foi instalado" }
elseif ((Test-Path -LiteralPath $VozDst) -and (Get-Sha $VozDst) -eq (Get-Sha $VozSrc)) { Write-Output "igual  $VozDir" }
else { New-Item -ItemType Directory -Force -Path $VozDir | Out-Null; Copy-Item -LiteralPath $VozSrc -Destination $VozDst -Force; Write-Output "instal $VozDir (atalho /voz)" }

# Pasta privada: configuração e exemplo da equipe, sem sobrescrever o que já existe.
New-Item -ItemType Directory -Force -Path $PrivateDir, (Join-Path $PrivateDir 'contatos') | Out-Null
$envDst = Join-Path $PrivateDir 'assistente.env'
if (-not (Test-Path -LiteralPath $envDst)) { Copy-Item -LiteralPath (Join-Path $Src '.env.example') -Destination $envDst; Write-Output "criado $envDst" }

# Vigia: tarefa agendada do usuário (Windows) ou LaunchAgent (Mac), a cada 3 min, sem janela. Ele sobe o
# despachante quando a configuração estiver pronta.
if (-not $SemVigia -and $EhMac) {
    try {
        Install-VigiaMac (Join-Path $Target 'scripts\assistente-vigia.ps1')
        Write-Output "vigia  LaunchAgent $VigiaRotulo registrado (a cada 3 min e no login)"
    }
    catch { Write-Output "aviso  não consegui registrar o LaunchAgent do vigia: $($_.Exception.Message)" }
}
elseif (-not $SemVigia) {
    $vigia = Join-Path $Target 'scripts\assistente-vigia.ps1'
    try {
        $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$vigia`""
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 3)
        $logon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($trigger, $logon) -Settings $settings -Principal $principal -Description 'Vigia do assistente-wpp: mantém o despachante de pé e avisa se o detector parar.' -Force | Out-Null
        Write-Output "vigia  tarefa $TaskName registrada (a cada 3 min e no logon)"
    }
    catch { Write-Output "aviso  não consegui registrar a tarefa do vigia: $($_.Exception.Message)" }
}

# Aviso de sessão: hooks no ~/.claude/settings.json (backup em ~/.assistente-wpp/backups).
try {
    Update-ClaudeHooks (-not $SemAvisoSessao)
    if ($SemAvisoSessao) { Write-Output 'hooks   aviso de sessão desligado' } else { Write-Output 'hooks   aviso de sessão registrado em ~/.claude/settings.json' }
}
catch { Write-Output "aviso  não consegui atualizar ~/.claude/settings.json: $($_.Exception.Message)" }

Write-Output ''
$aqui = if ($EhMac) { 'neste Mac' } else { 'neste Windows' }
Write-Output "Importante: o assistente roda $aqui e fica ativo sempre que você estiver logado nesta máquina"
Write-Output '(o vigia o religa no login e a cada 3 min, sem sessão do Claude aberta).'
Write-Output 'Se não quiser que rode aqui, desative ("desliga meu assistente", ou install.ps1 -Remover) e instale no'
Write-Output 'computador de trabalho. Ligue em um computador só por conta de WhatsApp, ou ele responde em dobro.'
Write-Output ''
Write-Output 'Pronto. Abra o Claude Code e diga: "configure meu assistente de WhatsApp".'
