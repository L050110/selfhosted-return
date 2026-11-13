#requires -Version 5.1
<#
.SYNOPSIS
    文档一致性门禁：防止「改了一处、漏了另一处」。

.DESCRIPTION
    这套文档多次出现同一事实分散在 5-6 个文件里的情况。改的时候改一半，
    读者就会拿到互相矛盾的结论（本项目真实发生过两次：cert 的 flag 用法、
    以及 MTU 的三个数字）。

    本脚本只做一件事：把「必须在多处保持一致的事实」变成断言。
    全部 PASS 退出码 0，否则 1，可以直接进 CI。

    ⚠️ 边界：它验证的是**内部一致性**，不是外部事实。
    正则匹配只能证明「文档里这么写」，不能证明「这么写是对的」。
    外部事实靠 permalink 引用（见 dual-direction.md 的 MTU 表）。

    只读，不改任何文件。

.PARAMETER SelfTest
    自检模式：喂一份故意写错的文本给同一套正则，要求至少 5 条 FAIL。
    用来防止「正则被写松了，门禁变成永远绿」。

.EXAMPLE
    .\scripts\check-docs.ps1

.EXAMPLE
    .\scripts\check-docs.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$checks = New-Object System.Collections.ArrayList

# 断言数下限：删检查项会让门禁变松，这里拦住。
$MinChecks = 15

function Add-Check {
    param([string]$Name, [bool]$Ok, [string]$Hint)
    [void]$checks.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Hint = $Hint })
}

function Read-Doc {
    param([string]$Rel)
    $p = Join-Path $root $Rel
    if (-not (Test-Path $p)) { return $null }
    return (Get-Content $p -Raw -Encoding UTF8)
}

if ($SelfTest) {
    # 故意写错的样本：包含历史上真实出现过的全部错误说法
    $readme   = "## 十二个必踩的坑（都在这了）`n1. **坑一**`n"
    $pitfalls = "## 修法`n正确用法是不带任何参数：`nhysteria cert`n`n" +
                "**`sni` 永远用域名形式。`insecure: true` 时它不被验证，所以填什么都行，只要不是 IP。**`n"
    $dual     = "这里既没有 1280 也没有 1250。"
    $deploy   = "bandwidth:`n  up: 18 mbps        # 对端的上行（也就是你这边的上行）`n"
    $outbound = "没有方向对照表。"
    Write-Host "[SelfTest] 已载入错误样本，期望多处 FAIL。" -ForegroundColor DarkCyan
} else {
    $readme   = Read-Doc 'README.md'
    $pitfalls = Read-Doc 'docs/pitfalls.md'
    $dual     = Read-Doc 'docs/dual-direction.md'
    $deploy   = Read-Doc 'docs/deploy.md'
    $outbound = Read-Doc 'docs/outbound.md'

    if (-not $readme -or -not $pitfalls) {
        Write-Host "[FAIL] 找不到 README.md 或 docs/pitfalls.md —— 请在仓库根目录运行" -ForegroundColor Red
        exit 1
    }
}

# ---------------------------------------------------------------- 1. cert 的事实
Add-Check 'pitfalls 写明 cert 只拒绝位置参数' `
    ($pitfalls -match '只拒绝位置参数') `
    'hysteria cert 接受 --host/--cert/--key/--valid-for/--overwrite，只有位置参数才 Fatal'

Add-Check 'pitfalls 不再断言「cert 不接受任何参数」' `
    (-not ($pitfalls -match '正确用法是[^\n]{0,10}(不带|不吃)任何参数')) `
    '改为：接受 flag、只拒绝位置参数'

# ---------------------------------------------------------------- 2. sni / sniGuard 机制
Add-Check 'pitfalls 提到服务端 sniGuard' `
    ($pitfalls -match 'sniGuard') `
    '失败是服务端 sniGuard 主动终止握手，不是客户端验证书失败'

Add-Check 'pitfalls 给出 sniGuard 默认值 dns-san' `
    ($pitfalls -match 'dns-san') `
    '默认 dns-san：证书含域名型 SAN 时校验 SNI'

Add-Check 'pitfalls 不再说「insecure 之后填什么都行」' `
    (-not ($pitfalls -match '`insecure: true` 时它不被验证，所以填什么都行')) `
    'insecure 只关客户端证书链校验，关不掉服务端 sniGuard'

# ---------------------------------------------------------------- 3. MTU 的唯一数字源
Add-Check 'dual-direction 给出 quic-go 默认首包 1280' `
    ($dual -and $dual -match 'InitialPacketSize\s*=\s*1280') `
    'quic-go internal/protocol/params.go: InitialPacketSize = 1280'

Add-Check 'dual-direction 给出 Chrome-parrot 首包 1250' `
    ($dual -and $dual -match 'chromeInitialPacketSize\s*=\s*1250') `
    'quic-go 仓库根目录 chrome_parrot.go（不在 internal/protocol/）: chromeInitialPacketSize = 1250'

Add-Check 'dual-direction 标明 1250 的出处路径（避免读者找错目录）' `
    ($dual -and $dual -match '根本[目录录]|根目录|/chrome_parrot\.go') `
    '写明是仓库根目录的 chrome_parrot.go，不是 internal/protocol/ 下'

# ---------------------------------------------------------------- 4. bandwidth 方向
Add-Check '客户端 bandwidth.up 的注释不再写成「对端的上行」' `
    ($deploy -and -not ($deploy -match 'up:\s*\d+ mbps\s*#\s*对端的上行')) `
    '客户端 up = 你这边的上行，不是对端的上行'

Add-Check '存在 bandwidth 服务端/客户端方向对照表' `
    ($outbound -and $outbound -match '服务端.{0,12}up.{0,40}客户端下载') `
    '服务端 up 限制的是客户端下载方向'

# ---------------------------------------------------------------- 5. 坑数一致
function ConvertFrom-CnNumber {
    param([string]$Text)
    $d = @{ '一'=1;'二'=2;'三'=3;'四'=4;'五'=5;'六'=6;'七'=7;'八'=8;'九'=9 }
    if ($Text -eq '十') { return 10 }
    if ($Text -match '^十(.)$')    { return 10 + $d[$Matches[1]] }
    if ($Text -match '^(.)十$')    { return $d[$Matches[1]] * 10 }
    if ($Text -match '^(.)十(.)$') { return $d[$Matches[1]] * 10 + $d[$Matches[2]] }
    if ($d.ContainsKey($Text)) { return $d[$Text] }
    return $null
}

$declared = $null
if ($readme -match '##\s*([一二三四五六七八九十]+)个必踩的坑') {
    $declared = ConvertFrom-CnNumber $Matches[1]
}
if ($null -eq $declared -and $readme -match '##\s*(\d+)个必踩的坑') { $declared = [int]$Matches[1] }

$actual = if ($SelfTest) { 12 } else { ([regex]::Matches($pitfalls, '(?m)^# 坑 \d+')).Count }

Add-Check "README 标题的坑数($declared) 等于 pitfalls 实际条数($actual)" `
    ($null -ne $declared -and $declared -eq $actual) `
    '标题写十二个就必须真有 12 个 # 坑 N 标题'

Add-Check 'README 说明只列了前 9 条并指向 pitfalls' `
    ($readme -match '只列\*\*前 9 条\*\*' -or $readme -match '坑 10[–-]12') `
    '列表只有 9 条时，必须明写另外 3 条在哪'

# ---------------------------------------------------------------- 6. 脚本编码与语法（SelfTest 下跳过）
if (-not $SelfTest) {
    $psFiles = @(Get-ChildItem -Path (Join-Path $root 'scripts') -Filter *.ps1 -File)
    $noBom = @()
    foreach ($f in $psFiles) {
        $b = [System.IO.File]::ReadAllBytes($f.FullName)
        if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) {
            $noBom += $f.Name
        }
    }
    Add-Check '所有 .ps1 带 UTF-8 BOM（否则中文注释会被按 ANSI 解析）' `
        ($noBom.Count -eq 0) `
        ("缺 BOM: " + ($noBom -join ', '))

    Add-Check '所有 .ps1 能通过 PowerShell 语法解析' `
        (@($psFiles | Where-Object {
            $err = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$err)
            $err -and $err.Count -gt 0
        }).Count -eq 0) `
        '用 Parser::ParseFile 逐个检查'

    $mdFiles = @(Get-ChildItem -Path $root -Recurse -Include *.md -File |
        Where-Object { $_.FullName -notmatch '\\node_modules\\' })
    $conflicted = @($mdFiles | Where-Object { (Get-Content $_.FullName -Raw -Encoding UTF8) -match '(?m)^(<<<<<<<|>>>>>>>) ' })
    Add-Check '没有未解决的合并冲突标记' `
        ($conflicted.Count -eq 0) `
        ("冲突文件: " + (($conflicted | ForEach-Object { $_.Name }) -join ', '))
}

# ---------------------------------------------------------------- 7. probe 的列定义（脚本与文档必须一致）
if (-not $SelfTest) {
    $probe = Read-Doc 'scripts/probe.ps1'
    $mreadme = Read-Doc 'measurements/README.md'

    Add-Check 'probe.ps1 采集 egressIp 与 mbpsEff' `
        ($probe -and $probe -match 'egressIp' -and $probe -match 'mbpsEff') `
        'CSV 里要有出口 IP 和扣除 TTFB 后的有效吞吐，否则 measurements 还是故事不是数据'

    Add-Check 'measurements/README.md 记录了同一组列' `
        ($mreadme -and $mreadme -match 'mbpsEff' -and $mreadme -match 'egressIp') `
        '脚本加的列必须在 measurements/README.md 里有释义，否则下一个人看不懂 CSV'
}

# ---------------------------------------------------------------- 断言数下限
Add-Check ("检查项数($($checks.Count + 1)) 不少于下限 $MinChecks") `
    (($checks.Count + 1) -ge $MinChecks) `
    '有人删了检查项 —— 门禁会变松，请补回或下调 MinChecks 并说明原因'

# ---------------------------------------------------------------- 输出
Write-Host ""
Write-Host ("=== 文档一致性门禁{0} ===" -f $(if ($SelfTest) { '（自检模式）' } else { '' })) -ForegroundColor Cyan
$fail = 0
foreach ($c in $checks) {
    if ($c.Ok) {
        Write-Host ("[PASS] {0}" -f $c.Name) -ForegroundColor Green
    } else {
        $fail++
        Write-Host ("[FAIL] {0}" -f $c.Name) -ForegroundColor Red
        if ($c.Hint) { Write-Host ("       fix: {0}" -f $c.Hint) -ForegroundColor Yellow }
    }
}
Write-Host ""

if ($SelfTest) {
    if ($fail -lt 5) {
        Write-Host ("[FAIL] 自检只触发 {0} 条 FAIL（要求 >= 5）—— 正则被写松了，门禁会变成永远绿。" -f $fail) -ForegroundColor Red
        exit 1
    }
    Write-Host ("[PASS] 自检触发 {0} 条 FAIL，正则有效。" -f $fail) -ForegroundColor Green
    exit 0
}

if ($fail -gt 0) {
    Write-Host ("{0} 项未通过。" -f $fail) -ForegroundColor Red
    exit 1
}
Write-Host ("全部通过（{0} 项）。" -f $checks.Count) -ForegroundColor Green
exit 0
