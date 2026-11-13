<#
.SYNOPSIS
    一键自检：把 docs/pitfalls.md 里每一个坑都断言一遍。
.DESCRIPTION
    只读，不改任何配置。每项输出 PASS / FAIL / SKIP 和一条修复命令。
    任何一个 FAIL 都会让退出码为 1。

    -ClientConfig / -ServerConfig 指向 hysteria 的 yaml。
    -PeerIp 是对端的 Tailscale IP（用来做 MTU 路径测试和隧道进程检查）。
    -TunnelProcess 是跑隧道的进程名（hysteria.exe / tailscaled.exe）。

.EXAMPLE
    .\verify.ps1 -ClientConfig ..\hysteria-us\client.yaml -PeerIp 100.x.x.x
#>
[CmdletBinding()]
param(
    [string]$ClientConfig,
    [string]$ServerConfig,
    [string]$PeerIp,
    [string[]]$TunnelProcess = @('hysteria.exe', 'tailscaled.exe'),
    [string]$TaskName,
    [int]$QuicMtu = 1280,
    [int]$SocksPort,
    [string]$PeerExitIp
)

$ErrorActionPreference = 'Continue'
$script:fail = 0
$script:pass = 0
$script:skip = 0

function Report {
    param([string]$Id, [string]$Verdict, [string]$Detail, [string]$Fix)
    switch ($Verdict) {
        'PASS' { $script:pass++; $c = 'Green' }
        'FAIL' { $script:fail++; $c = 'Red' }
        'SKIP' { $script:skip++; $c = 'DarkGray' }
        default { $c = 'Yellow' }
    }
    Write-Host ("[{0,-4}] {1,-3} {2}" -f $Verdict, $Id, $Detail) -ForegroundColor $c
    if ($Fix -and $Verdict -ne 'PASS') {
        Write-Host ("       fix: {0}" -f $Fix) -ForegroundColor Yellow
    }
}

function Get-YamlScalar {
    param([string]$Path, [string]$Key)
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    $line = Select-String -Path $Path -Pattern ("^\s*" + [regex]::Escape($Key) + "\s*:\s*(.+?)\s*$") -ErrorAction SilentlyContinue |
            Select-Object -First 1
    if (-not $line) { return $null }
    return ($line.Matches[0].Groups[1].Value -replace '\s+#.*$', '').Trim('"', "'")
}

Write-Host "`n=== 隧道自检 ===`n" -ForegroundColor Cyan

# ---------------------------------------------------------------- 坑 1：MTU
# QUIC 的 InitialPacketSize 是 1280。进隧道的内层 IP 包 = 1280 + 20(IPv4) + 8(UDP) = 1308。
# 虚拟网卡 MTU 低于 1308 就会静默丢握手包。
$required = $QuicMtu + 28
$ifaces = Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object { $_.InterfaceAlias -match 'Tailscale' }
if ($ifaces) {
    $mtu = ($ifaces | Select-Object -First 1).NlMtu
    $alias = ($ifaces | Select-Object -First 1).InterfaceAlias
    if ($mtu -ge $required) {
        Report 'P1' 'PASS' "MTU=$mtu on '$alias'（需要 >= $required）" $null
    } else {
        Report 'P1' 'FAIL' "MTU=$mtu on '$alias'，低于 $required —— QUIC 握手包会被静默丢弃" `
            "见坑 4：写 C:\ProgramData\Tailscale\tailscaled-env.txt 里的 TS_DEBUG_MTU=$required，再重启 Tailscale 服务"
    }
} else {
    Report 'P1' 'SKIP' '没找到 Tailscale 虚拟网卡（服务没装或没起）' $null
}

# ------------------------------------------------- 坑 2/3：服务端带宽与固定速率开关
if ($ServerConfig) {
    if (Test-Path $ServerConfig) {
        $ign = Get-YamlScalar -Path $ServerConfig -Key 'ignoreClientBandwidth'
        if ($ign -eq 'true') {
            Report 'P3' 'FAIL' "ignoreClientBandwidth: true —— Brutal 退化成普通 BBR，抗丢包能力消失" `
                "改成 false 或整行删掉，然后重启服务端"
        } else {
            $shown = if ($ign) { $ign } else { '未设置（默认 false）' }
            Report 'P3' 'PASS' "ignoreClientBandwidth=$shown" $null
        }
        # bandwidth.up 是「客户端上行」的硬上限，也就是下载方向的天花板
        $bwUp = Get-YamlScalar -Path $ServerConfig -Key 'up'
        $bwDown = Get-YamlScalar -Path $ServerConfig -Key 'down'
        if ($bwUp -or $bwDown) {
            Report 'P2' 'PASS' "服务端 bandwidth: up=$bwUp down=$bwDown（这是硬上限，不是建议值）" $null
        } else {
            Report 'P2' 'SKIP' '服务端没写 bandwidth，Brutal 不启用' '想要固定速率就写 bandwidth: { up: 50 mbps, down: 20 mbps }'
        }
    } else {
        Report 'P2' 'SKIP' "服务端配置不存在: $ServerConfig" $null
        Report 'P3' 'SKIP' "服务端配置不存在: $ServerConfig" $null
    }
} else {
    Report 'P2' 'SKIP' '没传 -ServerConfig' $null
    Report 'P3' 'SKIP' '没传 -ServerConfig' $null
}

# ---------------------------------------------------------- 坑 4：MTU 持久化
$envFile = 'C:\ProgramData\Tailscale\tailscaled-env.txt'
$tsDebug = $null
$accessDenied = $false
try {
    $tsDebug = Get-Content $envFile -Raw -ErrorAction Stop
} catch [System.UnauthorizedAccessException] {
    $accessDenied = $true
} catch {
    $tsDebug = $null
}
if ($accessDenied) {
    Report 'P4' 'SKIP' "$envFile 存在但当前不是管理员，读不了内容" '以管理员身份重跑本脚本'
} elseif ($null -ne $tsDebug) {
    if ($tsDebug -match 'TS_DEBUG_MTU\s*=\s*(\d+)') {
        $fileMtu = [int]$Matches[1]
        $liveMtu = if ($ifaces) { ($ifaces | Select-Object -First 1).NlMtu } else { $null }
        if ($liveMtu -and $fileMtu -ne $liveMtu) {
            Report 'P4' 'FAIL' "tailscaled-env.txt 写的是 $fileMtu，但网卡实际是 $liveMtu —— 文件没生效（服务没重启？）" `
                "Restart-Service Tailscale"
        } else {
            Report 'P4' 'PASS' "TS_DEBUG_MTU=$fileMtu 已持久化，且与运行值一致" $null
        }
    } else {
        Report 'P4' 'FAIL' "$envFile 存在但没有 TS_DEBUG_MTU" '写入一行 TS_DEBUG_MTU=1320 后 Restart-Service Tailscale'
    }
} else {
    Report 'P4' 'SKIP' "$envFile 不存在（如果没用 Tailscale 可以忽略）" $null
}

# ------------------------------------------- 坑 5：代理内核有没有劫持隧道进程
# 隧道进程如果被本地代理接管，连接会绕到机场节点，表现为「隧道通但极慢」。
$pipe = ([System.IO.Directory]::GetFiles('\\.\pipe\') |
    Where-Object { $_ -match 'verge-mihomo|clash' } |
    ForEach-Object { ($_ -split '\\' | Where-Object { $_ -ne '' } | Select-Object -Last 1) } |
    Where-Object { $_ -match '^(verge-mihomo|clash)' } |
    Select-Object -First 1)
if ($pipe) {
    $found = $false
    foreach ($p in $TunnelProcess) {
        $name = $p -replace '\.exe$', ''
        $hit = Get-CimInstance Win32_Process -Filter "Name='$p'" -ErrorAction SilentlyContinue
        if ($hit) { $found = $true; break }
    }
    if (-not $found) {
        Report 'P5' 'SKIP' "隧道进程（$($TunnelProcess -join '/')）没在跑，无从检查" $null
    } else {
        # 通过命名管道读 mihomo 的连接表
        try {
            $cli = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipe, [System.IO.Pipes.PipeDirection]::InOut)
            $cli.Connect(4000)
            $req = "GET /connections HTTP/1.1`r`nHost: localhost`r`nConnection: close`r`n`r`n"
            $b = [System.Text.Encoding]::ASCII.GetBytes($req)
            $cli.Write($b, 0, $b.Length); $cli.Flush()
            $ms = New-Object System.IO.MemoryStream
            $buf = New-Object byte[] 65536
            while (($n = $cli.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
            $cli.Dispose()
            $raw = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
            $bad = @()
            foreach ($p in $TunnelProcess) {
                $name = $p -replace '\.exe$', ''
                $m = [regex]::Matches($raw, '"process":"' + [regex]::Escape($name) + '"[^}]*\}.*?"chains":\[([^\]]*)\]')
                foreach ($x in $m) {
                    $chain = $x.Groups[1].Value -replace '"', '' -replace ',', ' > '
                    if ($chain -notmatch '^\s*(DIRECT)?\s*$') { $bad += "$name -> $chain" }
                }
            }
            if ($bad.Count -gt 0) {
                Report 'P5' 'FAIL' ("隧道进程被代理接管: " + ($bad -join '; ')) `
                    '在规则最前面加 PROCESS-NAME 直连，或让隧道进程绕过 TUN'
            } else {
                Report 'P5' 'PASS' "隧道进程没有走任何代理节点" $null
            }
        } catch {
            Report 'P5' 'SKIP' "读不到 mihomo 连接表: $($_.Exception.Message)" $null
        }
    }
} else {
    Report 'P5' 'SKIP' '没找到 mihomo/Clash 的命名管道' $null
}

# ---------------------------------------------------------------- 坑 6：SNI
if ($ClientConfig) {
    $sni = Get-YamlScalar -Path $ClientConfig -Key 'sni'
    $insecure = Get-YamlScalar -Path $ClientConfig -Key 'insecure'
    if (-not $sni) {
        Report 'P6' 'PASS' '客户端没写 sni（用 server 字段，且 insecure 时应无影响）' $null
    } elseif ($sni -match '^\d{1,3}(\.\d{1,3}){3}$' -or $sni -match ':') {
        Report 'P6' 'FAIL' "sni=$sni 是 IP 地址，握手指向的证书名对不上，会报 CRYPTO_ERROR 0x150" `
            'sni 必须填服务端证书的 CN/SAN（`hysteria cert` 生成时用的是机器名）'
    } else {
        Report 'P6' 'PASS' "sni=$sni（不是 IP）；insecure=$insecure" $null
    }
} else {
    Report 'P6' 'SKIP' '没传 -ClientConfig' $null
}

# ------------------------------------- 坑 7：防火墙 Block 规则压过 Allow 规则
$fw = Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.Action -eq 'Block' -and $_.Enabled -eq 'True' }
$fwHits = @()
foreach ($r in $fw) {
    $app = ($r | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue).Program
    if ($app -and ($TunnelProcess | Where-Object { $app -match [regex]::Escape(($_ -replace '\.exe$', '')) })) {
        $fwHits += "$($r.DisplayName) [$app]"
    }
}
if ($fwHits.Count -gt 0) {
    Report 'P7' 'FAIL' ("存在指向隧道程序的 Block 规则（Block 优先于 Allow）: " + ($fwHits -join '; ')) `
        'Remove-NetFirewallRule -DisplayName "<上面列出的名字>"'
} else {
    Report 'P7' 'PASS' '没有指向隧道程序的 Block 防火墙规则' $null
}

# ------------------------------------------- 坑 8：隧道进程要靠计划任务活着
if ($TaskName) {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) {
        Report 'P8' 'FAIL' "计划任务 $TaskName 不存在 —— SSH/终端里起的进程会随会话结束一起死" `
            ".\install-watchdog.ps1 -TaskName $TaskName"
    } elseif ($t.State -ne 'Running') {
        Report 'P8' 'FAIL' "计划任务 $TaskName 状态是 $($t.State)" "Start-ScheduledTask -TaskName $TaskName"
    } else {
        Report 'P8' 'PASS' "计划任务 $TaskName 正在运行" $null
    }
} else {
    Report 'P8' 'SKIP' '没传 -TaskName' $null
}

# ------------------------------------------------- 坑 9：对端可达 + 端口在听
# hysteria 跑在 UDP/QUIC 上，TCP 连 9443 连不上是「正常」的 —— 用 TCP 探活会给出假 FAIL。
# 真正该断言的是：本地 SOCKS 端口能不能真的出网，且出口是对端的 IP。
if (-not $SocksPort -and $ClientConfig) {
    # hysteria 的写法是 socks5.listen: 127.0.0.1:1081，不是单独的 port 键
    $socksPortRaw = Get-YamlScalar -Path $ClientConfig -Key 'port'
    if (-not $socksPortRaw) {
        $listen = Get-YamlScalar -Path $ClientConfig -Key 'listen'
        if ($listen -match ':(\d+)\s*$') { $socksPortRaw = $Matches[1] }
    }
    if ($socksPortRaw) { $SocksPort = [int]$socksPortRaw }
}
if ($SocksPort) {
    # 注意：-$echo 是「字符串数组」时 -match 只做过滤，不会设置 $Matches，
    # 那样 $Matches 会残留上一次匹配（这里曾经因此把端口 1081 当成出口 IP）。
    # 必须先拼成单个字符串，再匹配。
    $echo = $null
    try {
        $echo = (& curl.exe -s --max-time 25 --socks5-hostname "127.0.0.1:$SocksPort" https://ipinfo.io/json 2>$null) -join "`n"
    } catch { $echo = $null }
    $exitIp = $null
    if ($echo) {
        $m = [regex]::Match($echo, '"ip"\s*:\s*"([^"]+)"')
        if ($m.Success) { $exitIp = $m.Groups[1].Value }
    }
    if (-not $exitIp) {
        Report 'P9' 'FAIL' "经 SOCKS 127.0.0.1:$SocksPort 出不了网" '在对端确认 hysteria 服务在跑、防火墙允许 UDP 9443，并看客户端日志'
    } elseif ($PeerExitIp -and $exitIp -ne $PeerExitIp) {
        Report 'P9' 'FAIL' "出口 IP 是 $exitIp，期望 $PeerExitIp —— 流量没从对端出去" '检查客户端 server 字段和本地代理是否劫持了隧道进程'
    } else {
        $expect = if ($PeerExitIp) { "（== 期望的对端 $(($PeerExitIp))）" } else { '' }
        Report 'P9' 'PASS' "经 SOCKS 127.0.0.1:$SocksPort 出网，出口 IP $exitIp$expect" $null
    }
} else {
    Report 'P9' 'SKIP' '没找到 socks5 监听端口（客户端没配 socks5，或没传 -SocksPort）' $null
}

# ---------------------------------------------------------------- 汇总
Write-Host ""
Write-Host ("PASS {0}   FAIL {1}   SKIP {2}" -f $script:pass, $script:fail, $script:skip) -ForegroundColor Cyan
if ($script:fail -gt 0) {
    Write-Host "有 FAIL —— 先修上面红的那几项，再看其它。" -ForegroundColor Red
    exit 1
}
Write-Host "全绿。`n" -ForegroundColor Green
exit 0
