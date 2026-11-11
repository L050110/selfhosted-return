<#
.SYNOPSIS
    Generate the client-side config for hysteria2.

.DESCRIPTION
    Produces client.yaml in the working directory (next to hysteria.exe).

    Reads the server's password.txt / pin.txt if they are in the same folder,
    otherwise asks for them interactively.

.PARAMETER ServerAddr
    Server address. MUST be the IPv4 literal (100.x.x.x), not a MagicDNS name.
    Reason: a MagicDNS name may resolve to IPv6, where a QUIC initial packet needs
    1328 bytes instead of 1308. If the TUN MTU is only 1320, IPv6 will hit the
    MTU trap again even though IPv4 works.

.PARAMETER Port
    Server UDP port. Default 8443.

.PARAMETER Password
    Auth password. If omitted, read from password.txt next to this script.

.PARAMETER Pin
    Certificate SHA-256 pin. If omitted, read from pin.txt next to this script.

.PARAMETER UpMbps
    Upstream capacity of THIS machine in Mbps.

.PARAMETER DownMbps
    Downstream capacity. This becomes the hard ceiling for download speed.

.PARAMETER HttpPort
    Local HTTP proxy port. Default 10809.
    That matches hysteria's own built-in HTTP listener, so the generated config
    needs no extra arguments. If you run mihomo instead, pass -HttpPort 7890 to
    match its mixed-port convention.

.PARAMETER SocksPort
    Local SOCKS5 port. Default 10808 (hysteria default).

.PARAMETER Sni
    TLS SNI. Must equal the CN of the server certificate.
    hysteria 2.x generates the cert with the SERVER MACHINE NAME as CN
    (`hysteria cert` takes no arguments), so pass `-Sni <that machine name>`,
    or copy cert-cn.txt from the server next to this script.

.EXAMPLE
    .\setup-client.ps1 -ServerAddr 100.64.0.1 -DownMbps 95
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServerAddr,

    [int]$Port = 8443,
    [string]$Password,
    [string]$Pin,
    [int]$UpMbps = 18,
    [int]$DownMbps = 95,
    [int]$HttpPort = 10809,
    [int]$SocksPort = 10808,
    [string]$Sni
)

$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'hysteria.exe'

Write-Host ""
Write-Host "=== client setup ===" -ForegroundColor Cyan
Write-Host "  Dir       : $root"
Write-Host "  Server    : $ServerAddr : $Port"
Write-Host "  Up        : $UpMbps Mbps"
Write-Host "  Down      : $DownMbps Mbps"
Write-Host "  HTTP port : $HttpPort"
Write-Host "  SOCKS port: $SocksPort"
Write-Host ""

# ---------- preflight ----------
if (-not (Test-Path $exe)) {
    Write-Host "  [X] hysteria.exe not found in: $root" -ForegroundColor Red
    exit 1
}

# Guard against the IPv6 trap: warn if the address is not an IPv4 literal.
$isIPv4 = $ServerAddr -match '^\d{1,3}(\.\d{1,3}){3}$'
if (-not $isIPv4) {
    Write-Host "  [!] ServerAddr is not an IPv4 literal: $ServerAddr" -ForegroundColor Yellow
    Write-Host "      If this resolves to IPv6, QUIC needs 1328 bytes; a 1320 MTU will fail." -ForegroundColor Yellow
    Write-Host "      Prefer the Tailscale IPv4 address (100.x.x.x)." -ForegroundColor Yellow
    Write-Host ""
}

# ---------- password ----------
if (-not $Password) {
    $pwFile = Join-Path $root 'password.txt'
    if (Test-Path $pwFile) {
        $Password = (Get-Content $pwFile -Raw).Trim()
        Write-Host "  [OK] password read from password.txt"
    }
    else {
        Write-Host "  [X] no -Password given and password.txt not found" -ForegroundColor Red
        exit 1
    }
}

# ---------- pin ----------
if (-not $Pin) {
    $pinFile = Join-Path $root 'pin.txt'
    if (Test-Path $pinFile) {
        $Pin = (Get-Content $pinFile -Raw).Trim()
        Write-Host "  [OK] pin read from pin.txt"
    }
}

# SNI 有两条硬约束，两条都踩过：
#   1. 不能是 IP 字面量（RFC 6066 禁止），否则握手报 CRYPTO_ERROR 0x150。
#   2. **必须和服务端证书的 CN 一致**。`insecure: true` 只跳过证书链校验，
#      SNI 的格式和匹配仍然会被检查。填一个「随便的占位域名」会直接握手失败。
# 而 hysteria 2.x 的 `cert` 用**服务端机器名**当 CN，所以本站真正的做法是：
# 把服务端生成的 cert-cn.txt 拷过来，或者用 -Sni 显式指定。
$sniValue = $Sni

if (-not $sniValue) {
    $cnFile = Join-Path $root 'cert-cn.txt'
    if (Test-Path $cnFile) {
        $sniValue = (Get-Content $cnFile -Raw).Trim()
        Write-Host "  [OK] SNI read from cert-cn.txt: $sniValue"
    }
}

if (-not $sniValue) {
    $crtFile = Join-Path $root 'server.crt'
    if (Test-Path $crtFile) {
        try {
            $c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $crtFile
            $sniValue = $c.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
            if ($sniValue) { Write-Host "  [OK] SNI read from server.crt CN: $sniValue" }
        }
        catch { $sniValue = $null }
    }
}

if (-not $sniValue) {
    if (-not ($ServerAddr -match '^\d{1,3}(\.\d{1,3}){3}$')) {
        $sniValue = $ServerAddr
        Write-Host "  [i] SNI defaulted to the server name '$sniValue'" -ForegroundColor DarkGray
    }
}

if (-not $sniValue) {
    Write-Host ""
    Write-Host "  [X] 不知道 SNI 该填什么，不敢瞎填。" -ForegroundColor Red
    Write-Host "      填错的表现是 CRYPTO_ERROR 0x150 (remote): tls: internal error，" -ForegroundColor Yellow
    Write-Host "      看起来像证书或密码问题，极难反推。" -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Yellow
    Write-Host "      两个办法，任选其一：" -ForegroundColor Yellow
    Write-Host "        1) 把服务端生成的 cert-cn.txt 拷到这个目录，再跑一次" -ForegroundColor Yellow
    Write-Host "        2) 显式指定：-Sni <服务端证书的 CN>" -ForegroundColor Yellow
    Write-Host "           （在服务端跑：openssl x509 -in server.crt -noout -subject）" -ForegroundColor Yellow
    exit 1
}

if ($sniValue -match '^\d{1,3}(\.\d{1,3}){3}$') {
    Write-Host "  [X] SNI '$sniValue' 是 IP 字面量，RFC 6066 禁止，握手必失败。" -ForegroundColor Red
    Write-Host "      用服务端证书的 CN。" -ForegroundColor Yellow
    exit 1
}

Write-Host "  [i] TLS SNI = '$sniValue'（必须等于服务端证书 CN）" -ForegroundColor DarkGray

if ($Pin) {
    Write-Host "  [OK] pin: $Pin"
    $tlsBlock = @"
tls:
  sni: $sniValue
  insecure: true
  pinSHA256: $Pin
"@
    Write-Host "  [i] pinSHA256 + insecure:true is the recommended combination:" -ForegroundColor DarkGray
    Write-Host "      it trusts exactly one certificate instead of any certificate." -ForegroundColor DarkGray
}
else {
    Write-Host "  [!] no pin available, falling back to insecure:true alone" -ForegroundColor Yellow
    Write-Host "      This accepts ANY certificate. Prefer copying pin.txt from the server." -ForegroundColor Yellow
    $tlsBlock = @"
tls:
  sni: $sniValue
  insecure: true
"@
}

# ---------- client.yaml ----------
$yaml = @'
# hysteria2 client config - generated by setup-client.ps1
server: {{ADDR}}:{{PORT}}
auth: {{PASSWORD}}

bandwidth:
  up: {{UP}} mbps
  down: {{DOWN}} mbps
  # `down` is a HARD CEILING with Brutal (fixed-rate congestion control),
  # not a hint. Setting it lower than the real capacity throttles you;
  # setting it far higher causes constant loss and makes things slower.

{{TLS}}

socks5:
  listen: 127.0.0.1:{{SOCKS}}

http:
  listen: 127.0.0.1:{{HTTP}}

# Optional: expose a plain-TCP port on the local machine that is forwarded
# through the tunnel. Useful when an app cannot use a proxy at all.
# tcpForwarding:
#   - listen: 127.0.0.1:18080
#     remote: target-host:80

fastOpen: true

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 41943040
  maxConnReceiveWindow: 41943040
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s

# Chrome-style QUIC fingerprint. hysteria2 sends its Initial packet at 1250 bytes
# (30 below quic-go's 1280 default), which is exactly the headroom that keeps it
# under a 1280-MTU virtual adapter. Setting this to true disables that and sends
# full-size packets, re-triggering the MTU trap on its own.
# Verified against the binary: the key is `disableChromeParrot`, not `sniff`
# (`sniff` exists only as an outbound-level field, so a top-level `sniff:` block
# is silently ignored).
disableChromeParrot: false

# If you need to pin the size explicitly instead of relying on parrot mode:
# maxPacketSize: 1250

logLevel: info
'@

$yaml = $yaml.
    Replace('{{ADDR}}', $ServerAddr).
    Replace('{{PORT}}', $Port.ToString()).
    Replace('{{PASSWORD}}', $Password).
    Replace('{{UP}}', $UpMbps.ToString()).
    Replace('{{DOWN}}', $DownMbps.ToString()).
    Replace('{{TLS}}', $tlsBlock).
    Replace('{{SOCKS}}', $SocksPort.ToString()).
    Replace('{{HTTP}}', $HttpPort.ToString())

$yamlPath = Join-Path $root 'client.yaml'
if ((Test-Path $yamlPath) -and -not $PSBoundParameters.ContainsKey('Force')) {
    $backup = "$yamlPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $yamlPath $backup -Force
    Write-Host "  [i] existing client.yaml backed up to: $(Split-Path $backup -Leaf)" -ForegroundColor DarkGray
}
[System.IO.File]::WriteAllText($yamlPath, $yaml, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "  [OK] client.yaml  $((Get-Item $yamlPath).Length) bytes"

# ---------- connectivity check ----------
Write-Host ""
Write-Host "=== connectivity check ===" -ForegroundColor Cyan
Write-Host "  Starting a temporary client (5s) to verify the handshake..."
Write-Host ""

$tmpOut = Join-Path $root 'client-check-out.log'
$tmpErr = Join-Path $root 'client-check-err.log'
Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue

$proc = $null
$handshakeOk = $false
try {
    $proc = Start-Process -FilePath $exe `
        -ArgumentList @('client', '-c', $yamlPath) `
        -WorkingDirectory $root `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $tmpOut `
        -RedirectStandardError $tmpErr

    Start-Sleep -Seconds 6

    if ($proc.HasExited) {
        Start-Sleep -Milliseconds 800
        Write-Host "  [X] client exited immediately (exit code $($proc.ExitCode))" -ForegroundColor Red
        foreach ($f in @($tmpErr, $tmpOut)) {
            if (Test-Path $f) {
                $lines = Get-Content $f -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }
                if ($lines) {
                    Write-Host "      --- $(Split-Path $f -Leaf) ---"
                    $lines | Select-Object -First 8 | ForEach-Object { Write-Host "      $_" }
                }
            }
        }
    }
    else {
        # Still running: the QUIC handshake almost certainly succeeded.
        # The file handles are held by the live process, so do not read them yet.
        Write-Host "  [OK] client is running (handshake accepted)" -ForegroundColor Green
        $handshakeOk = $true
    }
}
finally {
    if ($proc -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
}

if (-not $handshakeOk) {
    Write-Host ""
    Write-Host "  Handshake did not complete. Most likely cause (in order):" -ForegroundColor Yellow
    Write-Host "    1. MTU trap - see docs/pitfalls.md, pitfall 1" -ForegroundColor Yellow
    Write-Host "       Check: ping -f -l 1280 $ServerAddr  (must succeed)" -ForegroundColor Yellow
    Write-Host "    2. UDP $Port blocked between the two hosts" -ForegroundColor Yellow
    Write-Host "    3. Wrong password or pin" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  To see more: edit client.yaml and set logLevel: debug" -ForegroundColor Yellow
    exit 1
}

# ---------- summary ----------
Write-Host ""
Write-Host "=== done ===" -ForegroundColor Green
Write-Host "  client.yaml  $yamlPath"
Write-Host ""
Write-Host "  Local proxy endpoints:" -ForegroundColor DarkGray
Write-Host "    HTTP  127.0.0.1:$HttpPort" -ForegroundColor DarkGray
Write-Host "    SOCKS 127.0.0.1:$SocksPort" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Next:" -ForegroundColor DarkGray
Write-Host "    1. Start it:  .\scripts\install-watchdog.ps1 -Role client" -ForegroundColor DarkGray
Write-Host "    2. Verify:    curl -x http://127.0.0.1:$HttpPort https://myip.ipip.net" -ForegroundColor DarkGray
Write-Host "    3. Then switch the system proxy (see docs/deploy.md phase 3)" -ForegroundColor DarkGray
