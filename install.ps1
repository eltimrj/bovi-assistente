# Instala (ou atualiza) a skill assistente-wpp para o Claude Code, no Windows.
#
#   install.ps1            instala/atualiza a skill, cria ~/.assistente-wpp e registra o vigia
#   install.ps1 -Check     só confere se a cópia instalada é igual à do repositório (rc 0 = igual)
#   install.ps1 -SemVigia  instala sem registrar a tarefa agendada do vigia
#   install.ps1 -SemAvisoSessao  instala sem os hooks do aviso de sessão (e remove os que houver)
#   install.ps1 -Remover   remove a tarefa do vigia, os hooks e a skill instalada (a pasta ~/.assistente-wpp fica)
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
    [string]$ClaudeSettings = (Join-Path $HOME '.claude\settings.json')
)
$ErrorActionPreference = 'Stop'
$Skill = 'assistente-wpp'
$Src = Join-Path $PSScriptRoot "skills\$Skill"
$Target = Join-Path $SkillsRoot $Skill
$TaskName = 'AssistenteWppVigia'
$Excluded = '(^|[\\/])(\.env|\.env\.local|\.install-manifest\.json)$'

# Hooks do aviso de sessão no ~/.claude/settings.json do usuário. Remove só os nossos (identificados pelo caminho
# do script) e, com $Add, registra de novo apontando para a cópia instalada. Os demais hooks ficam como estão.
function Update-ClaudeHooks([bool]$Add) {
    $sp = $ClaudeSettings
    $marker = 'assistente-wpp\scripts\aviso-sessao'
    $s = [pscustomobject]@{}
    if (Test-Path -LiteralPath $sp) {
        $rawJson = Get-Content -LiteralPath $sp -Raw -Encoding UTF8
        if ($rawJson.Trim()) { $s = $rawJson | ConvertFrom-Json }
        $bk = Join-Path $PrivateDir ('backups\settings.json.' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Force -Path (Split-Path $bk -Parent) | Out-Null
        Copy-Item -LiteralPath $sp -Destination $bk
    }
    if (-not ($s.PSObject.Properties.Name -contains 'hooks')) { $s | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
    $isOurs = { param($h) ((@($h.args) -join ' ') + ' ' + [string]$h.command) -like "*$marker*" }
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
            $h = [ordered]@{ type = 'command'; command = 'powershell.exe'; args = $a; timeout = $(if ($ev -eq 'UserPromptSubmit') { 10 } else { 90 }) }
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
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop; Write-Output "tarefa $TaskName removida" } catch { Write-Output "tarefa $TaskName não existia" }
    try { Update-ClaudeHooks $false; Write-Output 'hooks do aviso de sessão removidos' } catch { Write-Output "aviso  não consegui remover os hooks: $($_.Exception.Message)" }
    $d = Join-Path $Target 'scripts\assistente-despachante.ps1'
    if (Test-Path -LiteralPath $d) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $d -Mode stop }
    if (Test-Path -LiteralPath $Target) { Remove-Item -Recurse -Force -LiteralPath $Target; Write-Output "skill removida: $Target" }
    Write-Output "configuração preservada em $PrivateDir (apague à mão se quiser)"
    exit 0
}

$map = Get-SourceMap
if ($Check) {
    $p = @(Compare-Install $Target $map)
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

# Pasta privada: configuração e exemplo da equipe, sem sobrescrever o que já existe.
New-Item -ItemType Directory -Force -Path $PrivateDir, (Join-Path $PrivateDir 'contatos') | Out-Null
$envDst = Join-Path $PrivateDir 'assistente.env'
if (-not (Test-Path -LiteralPath $envDst)) { Copy-Item -LiteralPath (Join-Path $Src '.env.example') -Destination $envDst; Write-Output "criado $envDst" }

# Vigia: tarefa agendada do usuário, a cada 3 min, sem janela. Ele sobe o despachante quando a configuração estiver pronta.
if (-not $SemVigia) {
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
Write-Output 'Importante: o assistente roda neste Windows e fica ativo sempre que você estiver logado nesta máquina'
Write-Output '(o vigia o religa no logon e a cada 3 min, sem sessão do Claude aberta).'
Write-Output 'Se não quiser que rode aqui, desative ("desliga meu assistente", ou install.ps1 -Remover) e instale no'
Write-Output 'computador de trabalho. Ligue em um computador só por conta de WhatsApp, ou ele responde em dobro.'
Write-Output ''
Write-Output 'Pronto. Abra o Claude Code e diga: "configura meu assistente de WhatsApp".'
