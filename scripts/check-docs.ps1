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

    只读，不改任何文件。

.EXAMPLE
    .\scripts\check-docs.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$checks = New-Object System.Collections.ArrayList

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

$readme  = Read-Doc 'README.md'
$pitfalls = Read-Doc 'docs/pitfalls.md'
$dual    = Read-Doc 'docs/dual-direction.md'
$deploy  = Read-Doc 'docs/deploy.md'
$outbound = Read-Doc 'docs/outbound.md'

if (-not $readme -or -not $pitfalls) {
    Write-Host "[FAIL] 找不到 README.md 或 docs/pitfalls.md —— 请在仓库根目录运行" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- 1. cert 的事实
# 曾把「不接受位置参数」误写成「不接受任何参数」，导致 5 篇文档 + 脚本一起错。
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
    'quic-go chrome_parrot.go: chromeInitialPacketSize = 1250'

# ---------------------------------------------------------------- 4. bandwidth 方向
$clientUpOk = ($deploy -match '你（客户端）这边的上行') -or ($outbound -match '客户端的\*\*上行\*\*')
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
    if ($Text -match '^十(.)$')   { return 10 + $d[$Matches[1]] }      # 十一..十九
    if ($Text -match '^(.)十$')   { return $d[$Matches[1]] * 10 }      # 二十..九十
    if ($Text -match '^(.)十(.)$'){ return $d[$Matches[1]] * 10 + $d[$Matches[2]] }
    if ($d.ContainsKey($Text)) { return $d[$Text] }
    return $null
}

$declared = $null
if ($readme -match '##\s*([一二三四五六七八九十]+)个必踩的坑') {
    $declared = ConvertFrom-CnNumber $Matches[1]
}
if ($null -eq $declared -and $readme -match '##\s*(\d+)个必踩的坑') { $declared = [int]$Matches[1] }

$actual = ([regex]::Matches($pitfalls, '(?m)^# 坑 \d+')).Count

Add-Check "README 标题的坑数($declared) 等于 pitfalls 实际条数($actual)" `
    ($null -ne $declared -and $declared -eq $actual) `
    '标题写十二个就必须真有 12 个 # 坑 N 标题'

Add-Check 'README 说明只列了前 9 条并指向 pitfalls' `
    ($readme -match '只列\*\*前 9 条\*\*' -or $readme -match '坑 10[–-]12') `
    '列表只有 9 条时，必须明写另外 3 条在哪'

# ---------------------------------------------------------------- 6. 脚本编码（踩过：BOM 丢失导致中文注释解析失败）
$psFiles = Get-ChildItem -Path (Join-Path $root 'scripts') -Filter *.ps1 -File
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

# ---------------------------------------------------------------- 7. 没有合并冲突残留
$mdFiles = Get-ChildItem -Path $root -Recurse -Include *.md -File | Where-Object { $_.FullName -notmatch '\\node_modules\\' }
$conflicted = @($mdFiles | Where-Object { (Get-Content $_.FullName -Raw -Encoding UTF8) -match '(?m)^(<<<<<<<|>>>>>>>) ' })
Add-Check '没有未解决的合并冲突标记' `
    ($conflicted.Count -eq 0) `
    ("冲突文件: " + (($conflicted | ForEach-Object { $_.Name }) -join ', '))

# ---------------------------------------------------------------- 输出
Write-Host ""
Write-Host "=== 文档一致性门禁 ===" -ForegroundColor Cyan
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
if ($fail -gt 0) {
    Write-Host ("{0} 项未通过。" -f $fail) -ForegroundColor Red
    exit 1
}
Write-Host ("全部通过（{0} 项）。" -f $checks.Count) -ForegroundColor Green
exit 0
