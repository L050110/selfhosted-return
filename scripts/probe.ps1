param(
    [Parameter(Mandatory = $true)][string]$PeerIp,
    [string]$PublicIp = "223.5.5.5",
    [string]$GatewayIp,
    [int]$PeerPort = 22,
    [int]$IntervalSeconds = 5,
    [string]$LogPath
)

$ErrorActionPreference = 'Continue'

if (-not $LogPath) { $LogPath = Join-Path $PSScriptRoot "probe.csv" }

if (-not $GatewayIp) {
    try {
        $GatewayIp = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop |
                      Sort-Object RouteMetric | Select-Object -First 1).NextHop
    } catch { $GatewayIp = "0.0.0.0" }
}

$tsExe = 'C:\Program Files\Tailscale\tailscale.exe'
if (-not (Test-Path $tsExe)) { $tsExe = $null }

if (-not (Test-Path $LogPath)) {
    'time,gateway,public,peer,curAddr,relay,lastHandshake,diag' | Set-Content -Path $LogPath -Encoding UTF8
}

# 防止多实例并发写同一个 CSV（用命名互斥量，同一时间只允许一个实例）
$mutexName = "Global\ProbePS_" + ($LogPath -replace '[^a-zA-Z0-9]', '_')
$script:probeMutex = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $script:probeMutex.WaitOne(0)) {
    Write-Output "另一个实例已在运行，退出"
    exit 0
}
$ping = New-Object System.Net.NetworkInformation.Ping

function Test-Icmp([string]$hostname) {
    if (-not $hostname -or $hostname -eq "0.0.0.0") { return 0 }
    try {
        $r = $ping.Send($hostname, 1500)
        if ($r -and $r.Status -eq 'Success') { return 1 }
        return 0
    } catch { return 0 }
}

function Test-TcpPort([string]$hostname, [int]$port) {
    if (-not $hostname) { return 0 }
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($hostname, $port, $null, $null)
        $ok = $ar.AsyncWaitHandle.WaitOne(1500, $false)
        if ($ok -and $c.Connected) { return 1 }
        return 0
    } catch { return 0 }
    finally { $c.Close() }
}

function Get-TsPeerInfo([string]$targetIp) {
    $result = [ordered]@{ CurAddr = ""; Relay = ""; LastHandshake = ""; Diag = "" }
    if (-not $tsExe) { $result.Diag = "no-exe"; return $result }

    # 必须用 cmd 重定向把 tailscale 的输出直接写进文件。
    # 用 PowerShell 的 & $tsExe ... 拼接输出时，stdout/stderr 混流会让 JSON 里的
    # ":" 被破坏（实测 "Version": 变成 "Version,），ConvertFrom-Json 随即失败。
    $tmp = Join-Path $env:TEMP ("ts_" + [guid]::NewGuid().ToString("N") + ".json")
    try {
        $null = & cmd /c "`"$tsExe`" status --json > `"$tmp`" 2>nul"
        if (-not (Test-Path $tmp)) { $result.Diag = "no-file"; return $result }

        $text = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8)
        $result.Diag = "len=" + $text.Length

        $parsed = $null
        try { $parsed = $text | ConvertFrom-Json -ErrorAction Stop }
        catch {
            $msg = $_.Exception.Message
            $result.Diag = "bad-json(" + $text.Length + "):" + $msg.Substring(0, [Math]::Min(50, $msg.Length))
            return $result
        }

        $found = $null
        foreach ($prop in $parsed.Peer.PSObject.Properties) {
            $node = $prop.Value
            if ($node.TailscaleIPs -contains $targetIp) { $found = $node; break }
        }
        if (-not $found) { $result.Diag = "not-found"; return $result }

        $result.Diag = "ok"
        if ($found.CurAddr)       { $result.CurAddr = [string]$found.CurAddr }
        if ($found.Relay)         { $result.Relay = [string]$found.Relay }
        if ($found.LastHandshake) {
            try { $result.LastHandshake = ([datetime]$found.LastHandshake).ToLocalTime().ToString('HH:mm:ss') }
            catch { $result.LastHandshake = "" }
        }
    } catch {
        $msg = $_.Exception.Message
        $result.Diag = "err:" + $msg.Substring(0, [Math]::Min(50, $msg.Length))
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    return $result
}

while ($true) {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $gwStatus = Test-Icmp $GatewayIp
    $pubStatus = Test-Icmp $PublicIp
    $peerStatus = Test-TcpPort $PeerIp $PeerPort
    $peerInfo = Get-TsPeerInfo $PeerIp

    $row = $stamp + ',' + $gwStatus + ',' + $pubStatus + ',' + $peerStatus +
           ',"' + $peerInfo.CurAddr + '"' +
           ',"' + $peerInfo.Relay + '"' +
           ',"' + $peerInfo.LastHandshake + '"' +
           ',"' + $peerInfo.Diag + '"'

    Add-Content -Path $LogPath -Value $row -Encoding UTF8
    Start-Sleep -Seconds $IntervalSeconds
}
