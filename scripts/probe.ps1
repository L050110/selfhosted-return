param(
    [Parameter(Mandatory = $true)][string]$PeerIp,
    [string]$PublicIp = "223.5.5.5",
    [string]$GatewayIp,
    [int]$PeerPort = 22,
    [int]$IntervalSeconds = 5,
    [string]$LogPath,
    # ---- 吞吐/出口采样（可选；不进就直接退回纯可达性探针）----
    [int]$SocksPort,
    [string]$SpeedUrl = "https://speed.cloudflare.com/__down?bytes=5000000",
    [int]$SpeedEvery = 12,
    [int]$EgressEvery = 12,
    [switch]$NoHeader
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

if (-not $NoHeader -and -not (Test-Path $LogPath)) {
    $header = 'timestamp,gateway,public,peer,curAddr,relay,lastHandshake,tsDiag,' +
              'egressIp,mbpsEff,ttfbSec,bytes,speedDiag'
    Set-Content -Path $LogPath -Value $header -Encoding UTF8
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

# ---------------------------------------------------------------- 吞吐 / 出口采样
# 为什么不用 %{speed_download}：它 = 字节数 / time_total，分母含 DNS、建连、等首字节。
# 225ms RTT 的洲际链路上 TTFB 常到 0.7–1.1s，摊进 20s 传输会凭空少 4–5%。
# 所以这里取 time_total 和 time_starttransfer，自己算：
#     有效吞吐 = 字节数 × 8 / (time_total − time_starttransfer)
function Measure-Throughput {
    param([string]$Url, [int]$Port)
    $r = [pscustomobject]@{ Mbps = ''; Ttfb = ''; Bytes = 0; Err = '' }
    if (-not $Port) { $r.Err = 'no-port'; return $r }
    try {
        $fmt = '%{time_total} %{time_starttransfer} %{size_download}'
        $out = & curl.exe -s -m 90 -x "socks5h://127.0.0.1:$Port" -o NUL -w $fmt $Url 2>$null
        if (-not $out) { $r.Err = 'no-output'; return $r }
        $parts = ("$out").Trim() -split '\s+'
        if ($parts.Count -lt 3) { $r.Err = 'bad-format'; return $r }

        $total = 0.0; $ttfb = 0.0; $bytes = 0.0
        if (-not [double]::TryParse($parts[0], [ref]$total)) { $r.Err = 'parse-total'; return $r }
        if (-not [double]::TryParse($parts[1], [ref]$ttfb))  { $r.Err = 'parse-ttfb';  return $r }
        if (-not [double]::TryParse($parts[2], [ref]$bytes)) { $r.Err = 'parse-bytes'; return $r }

        $r.Ttfb = [math]::Round($ttfb, 3)
        $r.Bytes = [int]$bytes
        $payload = $total - $ttfb
        if ($payload -le 0 -or $bytes -le 0) { $r.Err = 'zero-payload'; return $r }
        $r.Mbps = [math]::Round($bytes * 8 / $payload / 1e6, 2)
        $r.Err = 'ok'
    } catch {
        $m = $_.Exception.Message
        $r.Err = 'err:' + $m.Substring(0, [Math]::Min(40, $m.Length))
    }
    return $r
}

# 出口 IP：确认这一轮流量确实从对端出去，而不是被本地代理劫走。
function Get-EgressIp {
    param([int]$Port)
    if (-not $Port) { return '' }
    try {
        $ip = & curl.exe -s -m 15 -x "socks5h://127.0.0.1:$Port" https://ipinfo.io/ip 2>$null
        if ($ip) { return ("$ip").Trim() }
    } catch { }
    return ''
}

$script:round = 0
while ($true) {
    $script:round++
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $gwStatus = Test-Icmp $GatewayIp
    $pubStatus = Test-Icmp $PublicIp
    $peerStatus = Test-TcpPort $PeerIp $PeerPort
    $peerInfo = Get-TsPeerInfo $PeerIp

    # 吞吐/出口按各自周期采样，避免每 5 秒拖一次 5MB
    $thr = [pscustomobject]@{ Mbps = ''; Ttfb = ''; Bytes = 0; Err = 'skip' }
    if ($SocksPort -and $SpeedEvery -gt 0 -and ($script:round % $SpeedEvery) -eq 0) {
        $thr = Measure-Throughput -Url $SpeedUrl -Port $SocksPort
    }
    $egress = ''
    if ($SocksPort -and $EgressEvery -gt 0 -and ($script:round % $EgressEvery) -eq 0) {
        $egress = Get-EgressIp $SocksPort
    }

    $row = $stamp + ',' + $gwStatus + ',' + $pubStatus + ',' + $peerStatus +
           ',"' + $peerInfo.CurAddr + '"' +
           ',"' + $peerInfo.Relay + '"' +
           ',"' + $peerInfo.LastHandshake + '"' +
           ',"' + $peerInfo.Diag + '"' +
           ',"' + $egress + '"' +
           ',' + $thr.Mbps + ',' + $thr.Ttfb + ',' + $thr.Bytes + ',"' + $thr.Err + '"'

    Add-Content -Path $LogPath -Value $row -Encoding UTF8
    Start-Sleep -Seconds $IntervalSeconds
}
