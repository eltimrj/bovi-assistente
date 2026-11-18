# plataforma.ps1: o que muda entre Windows e macOS, num lugar só. Os scripts carregam com
#   . (Join-Path $PSScriptRoot 'plataforma.ps1')
# No Windows o assistente segue no Windows PowerShell 5.1 (powershell.exe), Agendador e conhost, como sempre.
# No macOS roda no PowerShell 7 (pwsh), com LaunchAgent, processos soltos pelo nohup e notificação pelo osascript.
# Compatível com o 5.1: lá $IsMacOS não existe e vale $null.

$EhMac = [bool]$IsMacOS
$EhWindows = -not $EhMac -and -not [bool]$IsLinux
$VigiaRotulo = 'local.assistente-wpp.vigia'   # LaunchAgent do vigia no Mac (no Windows, a tarefa AssistenteWppVigia)

# PowerShell 7: o ConvertFrom-Json transforma datas ISO em DateTime (perdendo o fuso) e o [DateTimeOffset]::Parse
# depois quebra conforme a cultura. O 5.1 mantém o texto. -DateKind String (7.5+) devolve o comportamento do 5.1.
if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $PSDefaultParameterValues['ConvertFrom-Json:DateKind'] = 'String' }
elseif ($PSVersionTable.PSEdition -eq 'Core') { throw 'o assistente-wpp precisa do PowerShell 7.5 ou mais novo (brew upgrade powershell)' }

# O PowerShell que roda os scripts. No Mac, o caminho estável do Homebrew (o do Cellar muda a cada atualização);
# o launchd e os hooks não têm o PATH do terminal, então vai sempre o caminho completo.
function Get-PsExe {
    if ($EhWindows) { return 'powershell.exe' }
    foreach ($c in '/opt/homebrew/bin/pwsh', '/usr/local/bin/pwsh', '/usr/local/microsoft/powershell/7/pwsh') { if (Test-Path -LiteralPath $c) { return $c } }
    $g = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($g) { return $g.Source }
    [Environment]::ProcessPath
}

function Get-NomeMaquina { if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [Environment]::MachineName } }

# Linha de comando de um processo ('' se não existe).
function Get-LinhaDeComando([int]$ProcessId) {
    if ($EhWindows) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
        if ($p) { return [string]$p.CommandLine }
        return ''
    }
    ((& /bin/ps -o command= -p $ProcessId 2>$null) | Out-String).Trim()
}

# Processos do PowerShell (powershell.exe no Windows, pwsh no Mac) com a linha de comando: ProcessId, CommandLine.
function Get-ProcessosPowerShell {
    if ($EhWindows) {
        return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ForEach-Object { [pscustomobject]@{ ProcessId = [int]$_.ProcessId; CommandLine = [string]$_.CommandLine } })
    }
    @(& /bin/ps -axo pid=,command= 2>$null | ForEach-Object {
            if ($_ -match '^\s*(\d+)\s+(.*)$') {
                $procId = [int]$Matches[1]; $cl = $Matches[2]
                if ($cl -match 'pwsh') { [pscustomobject]@{ ProcessId = $procId; CommandLine = $cl } }
            }
        })
}

# Derruba o processo e os filhos dele.
function Stop-Arvore([int]$ProcessId) {
    if ($EhWindows) { & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null; return }
    foreach ($c in @(& /usr/bin/pgrep -P $ProcessId 2>$null)) { if ("$c".Trim()) { Stop-Arvore ([int]"$c".Trim()) } }
    & /bin/kill -9 $ProcessId 2>$null
}

# Mac: sobe um script do PowerShell solto (nohup, sem terminal, saída descartada), fora da espera de quem chamou.
function Start-Solto([string]$Script, [string[]]$Argumentos = @()) {
    $q = { param($s) "'" + ([string]$s).Replace("'", "'\''") + "'" }
    $partes = @((& $q (Get-PsExe)), '-NoProfile', '-File', (& $q $Script)) + @($Argumentos | ForEach-Object { & $q $_ })
    $cmd = 'nohup ' + ($partes -join ' ') + ' >/dev/null 2>&1 &'
    & /bin/sh -c $cmd
}

# Notificação do sistema: chega mesmo com o app do WhatsApp fechado.
function Show-NotificacaoSistema([string]$Text) {
    if ($EhMac) {
        # O texto vai como argumento do AppleScript, nunca dentro do código.
        & /usr/bin/osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "Assistente de WhatsApp"' -e 'end run' $Text 2>$null | Out-Null
        return
    }
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $esc = [Security.SecurityElement]::Escape($Text)
    $xml.LoadXml("<toast><visual><binding template=`"ToastGeneric`"><text>Assistente de WhatsApp</text><text>$esc</text></binding></visual></toast>")
    $app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show((New-Object Windows.UI.Notifications.ToastNotification $xml))
}

# Mac: o LaunchAgent do vigia está carregado no launchd?
function Test-VigiaMac {
    $uid = (& /usr/bin/id -u).Trim()
    & /bin/launchctl print "gui/$uid/$VigiaRotulo" *> $null
    $LASTEXITCODE -eq 0
}
