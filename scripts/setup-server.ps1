<#
.SYNOPSIS
    Generate server-side config and a self-signed certificate for hysteria2.

.DESCRIPTION
    Produces in the working directory:
      server.crt      self-signed certificate (ECDSA, ~590 bytes)
      server.key      private key
      server.yaml     server config with a random password
      password.txt    the generated password (for copying to the client)
      pin.txt         certificate SHA-256 pin (safer than skip-cert-verify)

    Uses hysteria's built-in `cert` subcommand, so no ASN.1 or OpenSSL needed.

.PARAMETER Port
    UDP listen port. Default 8443.

.PARAMETER Host
    Comma-separated SAN entries (DNS names or IPs) for the certificate.
    Default: the machine name. Use the Tailscale IP or MagicDNS name so the
    client can verify the pin.

.PARAMETER UpMbps
    Upstream capacity of THIS machine in Mbps. Set to ~95% of the measured value.
    This becomes the ceiling for the other side's download speed.

.PARAMETER DownMbps
    Downstream capacity of THIS machine in Mbps.

.PARAMETER Overwrite
    Overwrite existing files instead of refusing.

.EXAMPLE
    .\setup-server.ps1 -Host 100.x.x.x -UpMbps 95 -DownMbps 100
#>

[CmdletBinding()]
param(
    [int]$Port = 8443,
    [string]$CertHost = 'hysteria.local',
    [int]$UpMbps = 95,
    [int]$DownMbps = 100,
    [switch]$Overwrite
)

# 注意：这里故意用 Continue 而不是 Stop。
# PowerShell 会把原生命令（hysteria.exe）写到 stderr 的正常日志
# 当成异常抛出，用 Stop 会导致脚本在「证书其实已生成」之后中断。
$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'hysteria.exe'

Write-Host ""
Write-Host "=== server setup ===" -ForegroundColor Cyan
Write-Host "  Dir   : $root"
Write-Host "  Port  : $Port (UDP)"
Write-Host "  Host  : $CertHost"
Write-Host "  Up    : $UpMbps Mbps"
Write-Host "  Down  : $DownMbps Mbps"
Write-Host ""

# ---------- preflight ----------
if (-not (Test-Path $exe)) {
    Write-Host "  [X] hysteria.exe not found next to scripts/" -ForegroundColor Red
    Write-Host "      Download it from the hysteria releases page and put it in: $root"
    exit 1
}

$existing = @('server.crt', 'server.key', 'server.yaml') | Where-Object { Test-Path (Join-Path $root $_) }
if ($existing -and -not $Overwrite) {
    Write-Host "  [X] these already exist: $($existing -join ', ')" -ForegroundColor Red
    Write-Host "      Re-run with -Overwrite to replace them." -ForegroundColor Yellow
    exit 1
}

# ---------- 1. certificate ----------
Write-Host "=== certificate ===" -ForegroundColor Cyan
Push-Location $root
try {
    # hysteria 的 `cert` 子命令【接受 flag，只拒绝位置参数】：
    #   hysteria cert my.domain       -> FATAL "cert command does not accept arguments"
    #   hysteria cert --host my.domain -> 正常
    # v2.13.0 有 --host / --cert / --key / --valid-for / --overwrite 五个 flag。
    # 不传 --host 时默认取 os.Hostname() 当 CN + SAN。
    # 所以：先带 --host（可以指定 CN，行为可控），失败再退回无参（照顾极老版本）。
    $certOut = & $exe cert --host $CertHost --overwrite 2>&1
    $certCode = $LASTEXITCODE
    if ($certCode -ne 0) {
        Write-Host "  [i] '--host' rejected, retrying bare (build predates the flag)" -ForegroundColor DarkGray
        $certOut  = & $exe cert 2>&1
        $certCode = $LASTEXITCODE
    }
    $certOut | ForEach-Object { Write-Host "  $_" }
    if ($certCode -ne 0) {
        Write-Host "  [X] cert generation failed (exit=$certCode)" -ForegroundColor Red
        Write-Host "      If your hysteria build wants a host, pass -CertHost; if it rejects arguments," -ForegroundColor Yellow
        Write-Host "      this is a bug report worth filing upstream." -ForegroundColor Yellow
        exit 1
    }
}
finally { Pop-Location }

$certPath = Join-Path $root 'server.crt'
$keyPath  = Join-Path $root 'server.key'
if (-not (Test-Path $certPath) -or -not (Test-Path $keyPath)) {
    Write-Host "  [X] certificate files were not created" -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] server.crt  $((Get-Item $certPath).Length) bytes"
Write-Host "  [OK] server.key  $((Get-Item $keyPath).Length) bytes"

# Compute and store the pin (SHA-256 of the DER certificate).
# The client can verify against this instead of disabling verification entirely.
try {
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $certPath
    $hash = $cert.GetCertHashString([System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $pin = ($hash -replace '(..)', '$1:').TrimEnd(':').ToLower()
    Set-Content -Path (Join-Path $root 'pin.txt') -Value $pin -Encoding ASCII
    Write-Host "  [OK] pin.txt  $pin"
}
catch {
    Write-Host "  [!] could not compute pin: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "      hysteria cert prints pinSHA256 above; copy that value instead."
}

# ---------- 1b. 读出证书的 CN ----------
# 客户端的 tls.sni 必须等于这个值。填错就是 CRYPTO_ERROR 0x150，
# 而且报错信息看起来像证书/密码问题，完全指向错误方向。
$certCn = $null
try {
    $c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $certPath
    $certCn = $c.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    if ($certCn) {
        Set-Content -Path (Join-Path $root 'cert-cn.txt') -Value $certCn -Encoding ASCII
    }
}
catch { $certCn = $null }

Write-Host ""
if ($certCn) {
    Write-Host "  ============================================================" -ForegroundColor Green
    Write-Host "   客户的 tls.sni 必须填这个值：  $certCn" -ForegroundColor Green
    Write-Host "   （已写入 cert-cn.txt）" -ForegroundColor Green
    Write-Host "  ============================================================" -ForegroundColor Green
    if ($certCn -ne $CertHost) {
        Write-Host "  [i] 注意：证书 CN 是 '$certCn'，不是你传的 -CertHost='$CertHost'。" -ForegroundColor DarkGray
        Write-Host "      hysteria 2.x 的 cert 用机器名当 CN，-CertHost 只在老版本上生效。" -ForegroundColor DarkGray
        Write-Host "      想要自定义域名，请用 openssl 自己签（见 docs/pitfalls.md 坑 6）。" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  [!] 读不出证书 CN。请在客户端和这里分别执行：" -ForegroundColor Yellow
    Write-Host "      openssl x509 -in server.crt -noout -subject" -ForegroundColor Yellow
    Write-Host "      然后把客户端 tls.sni 填成 subject 里的 CN。" -ForegroundColor Yellow
}
Write-Host ""

# ---------- 2. random password ----------
$bytes = New-Object byte[] 16
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$password = -join ($bytes | ForEach-Object { '{0:x2}' -f $_ })
Set-Content -Path (Join-Path $root 'password.txt') -Value $password -Encoding ASCII
Write-Host "  [OK] password.txt  (20 hex chars)"

# ---------- 3. server.yaml ----------
# Certificate paths are ABSOLUTE on purpose: the watchdog may start the process
# from a different working directory, and relative paths would fail silently.
$certAbs = ($certPath -replace '\\', '/')
$keyAbs  = ($keyPath  -replace '\\', '/')

$yaml = @'
# hysteria2 server config - generated by setup-server.ps1
listen: 0.0.0.0:{{PORT}}

tls:
  cert: {{CERT}}
  key: {{KEY}}

auth:
  type: password
  password: {{PASSWORD}}

bandwidth:
  up: {{UP}} mbps
  down: {{DOWN}} mbps
# Do NOT add ignoreClientBandwidth: true here.
# It silently disables Brutal (fixed-rate congestion control) and falls back to BBR,
# which performs much worse on lossy long-haul paths.

speedTest: true
# Keep this on. It lets you run `hysteria speedtest` later to measure the tunnel
# in isolation from any origin server, which is the fastest way to tell whether a
# slowdown is the tunnel or the site you are fetching.

resolver:
  type: system

masquerade:
  type: string
  string:
    content: "not found"
    statusCode: 404

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 60s
  keepAlivePeriod: 10s

logLevel: info
# Use debug only while diagnosing: it logs every domain and rule decision.
'@

$yaml = $yaml.
    Replace('{{PORT}}', $Port.ToString()).
    Replace('{{CERT}}', $certAbs).
    Replace('{{KEY}}', $keyAbs).
    Replace('{{PASSWORD}}', $password).
    Replace('{{UP}}', $UpMbps.ToString()).
    Replace('{{DOWN}}', $DownMbps.ToString())

$yamlPath = Join-Path $root 'server.yaml'
[System.IO.File]::WriteAllText($yamlPath, $yaml, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "  [OK] server.yaml  $((Get-Item $yamlPath).Length) bytes"

# ---------- 4. config check ----------
# `hysteria server` runs in the foreground and never exits, so it must be started
# as a background process. Only that specific PID is stopped afterwards -- never
# a broad "stop all hysteria" query, which would kill an unrelated running instance.
Write-Host ""
Write-Host "=== config check ===" -ForegroundColor Cyan

$checkOut = Join-Path $root 'check-stdout.log'
$checkErr = Join-Path $root 'check-stderr.log'
Remove-Item $checkOut, $checkErr -Force -ErrorAction SilentlyContinue

$checkProc = $null
$checkOk = $false
try {
    $checkProc = Start-Process -FilePath $exe `
        -ArgumentList @('server', '-c', $yamlPath) `
        -WorkingDirectory $root `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $checkOut `
        -RedirectStandardError $checkErr

    # Give it long enough to fail on a bad config (fails in well under a second).
    Start-Sleep -Seconds 5

    if (-not $checkProc.HasExited) {
        # Still running => the config was accepted. Nothing to read yet: the process
        # holds the redirect file handles while alive, so reading them would throw.
        Write-Host "  [OK] config accepted (server is running)" -ForegroundColor Green
        $checkOk = $true
    }
    else {
        # It exited => something is wrong. Handles are released now, safe to read.
        Start-Sleep -Milliseconds 800
        Write-Host "  [X] server exited immediately (exit code $($checkProc.ExitCode))" -ForegroundColor Red
        foreach ($f in @($checkErr, $checkOut)) {
            if (Test-Path $f) {
                $lines = Get-Content $f -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }
                if ($lines) {
                    Write-Host "      --- $(Split-Path $f -Leaf) ---"
                    $lines | Select-Object -First 6 | ForEach-Object { Write-Host "      $_" }
                }
            }
        }
    }
}
catch {
    Write-Host "  [!] config check error: $($_.Exception.Message)" -ForegroundColor Yellow
}
finally {
    # stop ONLY the process we started
    if ($checkProc -and -not $checkProc.HasExited) {
        Stop-Process -Id $checkProc.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    Remove-Item $checkOut, $checkErr -Force -ErrorAction SilentlyContinue
}

if (-not $checkOk) {
    Write-Host ""
    Write-Host "  Config check did not pass. Fix server.yaml before starting the watchdog." -ForegroundColor Yellow
    exit 1
}

# ---------- summary ----------
Write-Host ""
Write-Host "=== done ===" -ForegroundColor Green
Write-Host "  server.crt    certificate"
Write-Host "  server.key    private key"
Write-Host "  server.yaml   config"
Write-Host "  password.txt  auth password  -> copy to the client"
if (Test-Path (Join-Path $root 'pin.txt')) {
    Write-Host "  pin.txt       cert pin      -> copy to the client"
}
Write-Host ""
Write-Host "  Next:" -ForegroundColor DarkGray
Write-Host "    1. Start it:   .\scripts\install-watchdog.ps1 -Role server" -ForegroundColor DarkGray
Write-Host "    2. On the other machine:" -ForegroundColor DarkGray
Write-Host "       .\scripts\setup-client.ps1 -ServerAddr <this machine's Tailscale IPv4>" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Caller note: -Host should be the address the client will connect to," -ForegroundColor DarkGray
Write-Host "  so the pin matches. If you pass a plain machine name, add the Tailscale IP here." -ForegroundColor DarkGray
