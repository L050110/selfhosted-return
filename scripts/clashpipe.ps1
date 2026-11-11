param(
  [Parameter(Mandatory=$true)][string]$Path,
  [string]$Secret = 'set-your-secret',
  [int]$TimeoutMs = 8000,
  [int]$MaxBytes = 4000000,
  [string]$OutFile
)
# HTTP-over-named-pipe client for Clash Verge's sidecar (external-controller is a pipe, not TCP).
$ErrorActionPreference = 'Stop'

$pipeName = ([System.IO.Directory]::GetFiles('\\.\pipe\') |
  Where-Object { $_ -match 'verge-mihomo' } |
  ForEach-Object { ($_ -split '\\' | Where-Object { $_ -ne '' } | Select-Object -Last 1) } |
  Where-Object { $_ -match '^verge-mihomo' } |
  Select-Object -First 1)
if (-not $pipeName) { throw 'no verge-mihomo pipe found' }

$cli = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
$cli.Connect($TimeoutMs)
try {
  $req = "GET $Path HTTP/1.1`r`nHost: localhost`r`nAuthorization: Bearer $Secret`r`nAccept-Encoding: identity`r`nConnection: close`r`n`r`n"
  $bytes = [System.Text.Encoding]::ASCII.GetBytes($req)
  $cli.Write($bytes, 0, $bytes.Length)
  $cli.Flush()

  $ms = New-Object System.IO.MemoryStream
  $buf = New-Object byte[] 65536
  while ($true) {
    $n = $cli.Read($buf, 0, $buf.Length)
    if ($n -le 0) { break }
    $ms.Write($buf, 0, $n)
    if ($ms.Length -gt $MaxBytes) { break }
  }
} finally { $cli.Dispose() }

$raw = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
$split = $raw.IndexOf("`r`n`r`n")
if ($split -lt 0) { throw "malformed response: $($raw.Substring(0,[Math]::Min(200,$raw.Length)))" }
$head = $raw.Substring(0, $split)
$body = $raw.Substring($split + 4)

if ($head -match '(?i)Transfer-Encoding:\s*chunked') {
  $sb = New-Object System.Text.StringBuilder
  $pos = 0
  while ($pos -lt $body.Length) {
    $eol = $body.IndexOf("`r`n", $pos)
    if ($eol -lt 0) { break }
    $line = $body.Substring($pos, $eol - $pos).Trim()
    if ($line -eq '') { $pos = $eol + 2; continue }
    $lenHex = ($line -split ';')[0].Trim()
    $len = 0
    if (-not [int]::TryParse($lenHex, [System.Globalization.NumberStyles]::HexNumber, $null, [ref]$len)) { break }
    if ($len -eq 0) { break }
    $start = $eol + 2
    if ($start + $len -gt $body.Length) { $len = $body.Length - $start }
    if ($len -le 0) { break }
    $sb.Append($body.Substring($start, $len)) | Out-Null
    $pos = $start + $len + 2
  }
  $body = $sb.ToString()
}
if ($OutFile) { [System.IO.File]::WriteAllText($OutFile, $body, (New-Object System.Text.UTF8Encoding($false))) } else { $body }
