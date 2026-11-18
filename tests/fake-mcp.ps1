<#
Gateway MCP falso, só para os testes (assistente.tests.ps1). Escuta em 127.0.0.1:<Port>, sem admin.
A cada pedido relê <Dir>\responses.json, que mapeia o nome da ferramenta para a resposta:
  { "list_chats": { "text": "<json>" }, "get_chat_messages": { "error": "falhou" } }
Ferramenta sem entrada responde erro. Cada pedido é anotado em <Dir>\requests.jsonl.
Nunca fala com o WhatsApp de verdade.
#>
param([Parameter(Mandatory = $true)][int]$Port, [Parameter(Mandatory = $true)][string]$Dir)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding $false
$listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, $Port)
$listener.Start()
[IO.File]::WriteAllText((Join-Path $Dir 'ready'), "$PID", $utf8)

function Read-Request($Stream) {
    # Cabeçalho byte a byte até \r\n\r\n; corpo pelos bytes exatos do Content-Length (UTF-8 com acento).
    $head = New-Object Collections.Generic.List[byte]
    while ($true) {
        $b = $Stream.ReadByte()
        if ($b -lt 0) { return $null }
        $head.Add([byte]$b)
        $n = $head.Count
        if ($n -ge 4 -and $head[$n - 4] -eq 13 -and $head[$n - 3] -eq 10 -and $head[$n - 2] -eq 13 -and $head[$n - 1] -eq 10) { break }
    }
    $len = 0
    if ($utf8.GetString($head.ToArray()) -match '(?im)^Content-Length:\s*(\d+)') { $len = [int]$Matches[1] }
    $body = New-Object byte[] $len
    $read = 0
    while ($read -lt $len) { $k = $Stream.Read($body, $read, $len - $read); if ($k -le 0) { break }; $read += $k }
    $utf8.GetString($body, 0, $read)
}

while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        $raw = Read-Request $stream
        if ($null -eq $raw) { continue }
        $req = $raw | ConvertFrom-Json
        $tool = $req.params.name
        [IO.File]::AppendAllText((Join-Path $Dir 'requests.jsonl'), (([ordered]@{ tool = $tool; arguments = $req.params.arguments } | ConvertTo-Json -Compress -Depth 6) + "`n"), $utf8)
        $map = Get-Content -Raw -LiteralPath (Join-Path $Dir 'responses.json') -Encoding UTF8 | ConvertFrom-Json
        $spec = $map.$tool
        if ($spec -and $spec.text) { $result = @{ content = @(@{ type = 'text'; text = [string]$spec.text }); isError = $false } }
        else {
            $msg = if ($spec -and $spec.error) { [string]$spec.error } else { "ferramenta $tool sem resposta no teste" }
            $result = @{ content = @(@{ type = 'text'; text = $msg }); isError = $true }
        }
        $out = $utf8.GetBytes((@{ jsonrpc = '2.0'; id = $req.id; result = $result } | ConvertTo-Json -Compress -Depth 8))
        $hdr = $utf8.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($out.Length)`r`nConnection: close`r`n`r`n")
        $stream.Write($hdr, 0, $hdr.Length)
        $stream.Write($out, 0, $out.Length)
        $stream.Flush()
    }
    catch { }
    finally { $client.Close() }
}
