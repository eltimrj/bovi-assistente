# aviso-sessao-inicio.ps1: hook UserPromptSubmit. Grava o instante em que o turno começou, por sessão.
# O par é aviso-sessao.ps1 (Stop), que avisa o dono no WhatsApp quando o turno passou do limite.
# Também mostra na sessão, uma vez, a última falha de envio do aviso.

$raw = [Console]::In.ReadToEnd()
try { $data = $raw | ConvertFrom-Json -ErrorAction Stop } catch { exit 0 }
if (-not $data.session_id) { exit 0 }
if ($env:ASSISTENTE_DESPACHADO) { exit 0 }

$HomeDir = if ($env:ASSISTENTE_HOME) { $env:ASSISTENTE_HOME } else { Join-Path $env:USERPROFILE '.assistente-wpp' }
$stateRoot = if ($env:ASSISTENTE_STATE_DIR) { $env:ASSISTENTE_STATE_DIR } else { Join-Path $HomeDir 'state' }
$dir = Join-Path $stateRoot 'avisos'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$file = Join-Path $dir ("turno-" + $data.session_id + ".txt")
# Prompt do dono reinicia a contagem. Acordada automática (fim de background, wakeup) continua o turno dele.
$src = [string]$data.source
if (-not $src -or $src -eq 'user' -or -not (Test-Path -LiteralPath $file)) {
    [IO.File]::WriteAllText($file, [string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
}

# Limpa inícios de turno órfãos (turno interrompido, sessão fechada).
Get-ChildItem -LiteralPath $dir -Filter 'turno-*.txt' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-1) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

$fail = Join-Path $dir 'ultima-falha.txt'
if (Test-Path -LiteralPath $fail) {
    $why = [IO.File]::ReadAllText($fail).Trim()
    Remove-Item -LiteralPath $fail -Force -ErrorAction SilentlyContinue
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
    @{ systemMessage = "O aviso de sessão no WhatsApp falhou ($why). Detalhes em $dir\aviso-sessao.log" } | ConvertTo-Json -Compress
}
exit 0
