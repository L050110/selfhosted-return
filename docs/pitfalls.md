# 十二个必踩的坑

**每一个都会让你以为「这套东西根本不能用」。按顺序看，因为后一个可能被前一个掩盖。**

---

# 坑 1：MTU —— 差 28 字节，而且是静默失败

## 症状

```
客户端报：timeout: no recent network activity
          或 handshake did not complete in time
服务端日志：完全没有连接记录
抓包（tcpdump / pktmon）：抓不到任何相关包
从本机回环地址连同一个服务端：完全正常
```

**这组症状最容易让人往「防火墙」「端口没开」「认证失败」方向查，全是错的方向。**

## 根因

```
quic-go 的 InitialPacketSize 默认 1280 字节（UDP 载荷）
+ IPv4 头 20 + UDP 头 8 = 1308 字节的 IP 包
而虚拟网卡 MTU 1280 只允许 1252 字节的 UDP 载荷（1280 - 28）

差 28 字节
```

**为什么是静默的：**

```
quic-go 把 EMSGSIZE（消息过长）当作可忽略错误
设计上是「留给 Path MTU Discovery 来处理」
但握手阶段 PMTUD 还没启动
所以每个 Initial 包都发不出去，却按 PTO 定时器原样重传
结果：客户端只看到超时，服务端什么都没收到
```

**Windows 上还有个额外因素：quic-go 会给 socket 设 `IP_DONTFRAGMENT`，
所以内核直接返回 `WSAEMSGSIZE(10040)`，包根本不出网卡。**

## 验证

```powershell
# 1. 查虚拟网卡的实际 MTU
Get-NetIPInterface -InterfaceAlias Tailscale | Select-Object AddressFamily, NlMtu

# 2. 测路径能不能承载满载包
#    注意：ping -l N 的 IP 包大小 = N + 20(IP) + 8(ICMP) = N + 28
#    所以 MTU 1320 对应 -l 1292
ping -f -l 1292 <对端地址>     # 通 → MTU 1320 的满载包能过
ping -f -l 1252 <对端地址>     # 通 → MTU 1280 的满载包能过

# 3. 关键对照：Run 一次内置测速（不经任何源站）
hysteria.exe speedtest -c client.yaml
#    如果内置测速单流远高于日常速度，说明瓶颈在「到源站」那段，不在隧道
```

## 修法（按推荐顺序）

```
① 把虚拟网卡 MTU 提到 1320 以上（IPv4）或 1330 以上（兼顾 IPv6）
② 升级到 quic-go v0.64+（本机发送报错那种会被自动修掉）
③ 在应用里显式把 InitialPacketSize 设为 1200
```

**注意 ① 的具体做法：**

```powershell
# Windows + Tailscale：必须用环境变量，不能用 netsh（见坑 4）
# 写入 C:\ProgramData\Tailscale\tailscaled-env.txt：
TS_DEBUG_MTU=1320

# 然后重启服务
Restart-Service Tailscale
```

**IPv4 需要 1308，IPv6 需要 1328（头是 40 字节不是 20）。**
**如果两端都用 IPv4 字面地址连接，1320 够；如果可能走 IPv6，用 1330。**

## 为什么这个坑值得单独立一章

```
· 失败是静默的，症状指向错误方向
· 差额只有 28 字节，靠算术能推但不容易想到
· 相关 issue 在多个项目里开了几年没定论
· 上游只修了「本机发送报错」这一种
  路径中间某跳是 1280、服务端回包方向，都还没修
```

**可查证的公开记录（建议部署前先读一遍，能省很多时间）：**

| 位置 | 内容 |
|---|---|
| `tailscale/tailscale#2633` | QUIC/HTTP3 在 tailnet 内不工作，2021 年开到现在 |
| `quic-go/quic-go#5911` | 已合并的修复：未显式设置初始包大小时，遇 EMSGSIZE 退回 1200 |
| `quic-go/quic-go#6102` | 上面那个修复覆盖不到的情况：路径中间某跳 MTU 1280 |
| `caddy` 社区 / `bluenviron/mediamtx#6363` | 同类问题在其他项目的独立报告 |

**读 #5911 和 #6102 的区别很重要：**

```
#5911 修的是「本机发送时报错」→ 会自动退回 1200
#6102 说明「路径中间某一跳只有 1280」→ 本机不报错，仍然超时

所以升级到 quic-go v0.64+ 只解决一侧。
如果你部署后仍然超时，很可能就是 #6102 那种情况，
本仓库的探测方法（对端回显测试）能定位它。
```

---

# 坑 2：`bandwidth.down` 是硬上限，不是建议值

## 症状

```
链路明明能跑 200 Mbps，客户端设了 down: 40，实测就是 35-40 Mbps
改大一点就涨一点，但永远贴着设定值
```

## 根因

**hysteria2 的 Brutal 拥塞控制是「固定速率发送」，不是「探测可用带宽」。**

```
设 down: 40  →  整条连接（所有流合计）最多 40 Mbps
设 down: 80  →  最多 80
设 down: 120 →  最多 120（如果链路真有这么多）
设 down: 200 →  仍然 120（链路只有这么多）
```

## 验证

```powershell
# 找一个真实源站，测不同 down 值下的表现
# 本项目实测（同一条链路）：
#   down=40  → 单流 21.3 / 4 流 35.9
#   down=80  → 单流 22.5 / 4 流 71.2
#   down=120 → 单流 22.9 / 4 流 86.7   ← 饱和
#   down=200 → 单流 22.9 / 4 流 86.2   ← 不再增长
```

**120 和 200 结果一样，说明 86.7 就是链路真实上限。**

## 修法

```
把这个值设成「实测链路能力的 90-95%」

设太高：持续按超额速率发送 → 持续丢包 → 重传 → 实际更慢
设太低：跑不满链路 → 白浪费

正确做法：先用 hysteria speedtest 测出真实能力，再乘 0.95
```

**双向都要设：**
```yaml
bandwidth:
  up: "18 Mbps"      # 对端的上行
  down: "95 Mbps"    # 本端的下行能力（也就是对端的上行）
```

---

# 坑 3：`ignoreClientBandwidth: true` 会让固定速率拥塞控制失效

## 症状

```
服务端配了 bandwidth，客户端也配了，但速度始终上不去
看起来像是设了没用
```

## 根因

**服务端配置里如果有这一行：**

```yaml
bandwidth:
  up: 200 mbps
  down: 200 mbps
ignoreClientBandwidth: true     # ← 这一行
```

**它会让服务端忽略客户端的带宽声明，行为上回落到 BBR（自适应探测），
而不是 Brutal（固定速率）。**

**BBR 在高丢包的跨境链路上表现远差于固定速率发送。**

## 修法

```yaml
# 服务端：删掉 ignoreClientBandwidth，或显式设 false
bandwidth:
  up: 95 mbps
  down: 100 mbps
```

**验证方法：改完之后重测 4 流吞吐，应该有明显提升。**

---

# 坑 4：Windows 上 `netsh` 改的 MTU 会被服务重启覆盖

## 症状

```
用 netsh 或 Set-NetIPInterface 把 MTU 改成 1350
查一次确实是 1350
重启服务后再查：又变回 1280
```

## 根因

**虚拟网卡（wintun）的 MTU 由创建它的服务决定，服务启动时会重新配置接口。**

**所以外部改的 MTU 只能维持到下一次服务重启。**

## 修法

**必须让服务自己在创建网卡时就用目标值：**

```powershell
# Tailscale 在 Windows 上读这个文件里的环境变量
# 路径：C:\ProgramData\Tailscale\tailscaled-env.txt
# 内容（一行）：
TS_DEBUG_MTU=1320

# 然后重启服务
Restart-Service Tailscale
```

**注意：写这个文件需要管理员权限，且要清掉任何机器级同名环境变量（两个来源会打架）。**

```powershell
# 清掉机器级的环境变量（如果有）
[System.Environment]::SetEnvironmentVariable('TS_DEBUG_MTU', $null, 'Machine')
```

---

# 坑 5：本地代理内核劫持了隧道进程，流量绕远路

## 症状

```
隧道能连上，但速度只有预期的一半或更少
多流也上不去
换源站也没用
```

## 根因

**如果本机装着 Clash / mihomo / sing-box 这类代理内核，而且开了 TUN 模式，
那么隧道进程（hysteria / mihomo）自己发出的流量也会被 TUN 接管。**

**后果：**

```
hysteria 服务端要访问一个目标站点
→ 它的流量被 TUN 抓走
→ 按规则可能落到 MATCH → 走机场节点 → 绕到国外再回国内
→ 速度废掉
```

**本项目实测：加规则前 8 流只有 40-72 Mbps 且不稳定，加规则后稳定 85。**

## 验证

```powershell
# 看代理内核的连接表，隧道进程的连接走的是哪个节点
# Clash / mihomo 的 API：
curl "http://127.0.0.1:9090/connections" | ConvertFrom-Json |
  Where-Object { $_.metadata.processPath -match 'hysteria|mihomo' }
```

**如果看到它走了某个代理组而不是 DIRECT，就是这个坑。**

## 修法

**在代理内核的规则里，把隧道进程显式指向 DIRECT，而且要放在最前面：**

```yaml
rules:
  - PROCESS-NAME,hysteria.exe,DIRECT
  - PROCESS-NAME,mihomo.exe,DIRECT
  - PROCESS-NAME,tailscaled.exe,DIRECT
  - PROCESS-NAME,tailscale.exe,DIRECT
  # ... 其余规则
```

**注意：DIRECT 仍然会「经过 TUN」，但至少不走机场绕行。
如果连 TUN 的转发开销都想避开，需要在 TUN 的排除列表里加这些进程。**

---

# 坑 6：`tls.sni` 填了 IP 地址，握手报一个看不懂的错

## 症状

```
客户端启动即退出：
FATAL failed to initialize client
{"error": "connect error: CRYPTO_ERROR 0x150 (remote): tls: internal error"}
```

**服务端日志里可能什么都没有。**

**这个错误看起来像「证书不对」或「密码错了」，实际两个都不是。**

## 根因

**配置里写了：**

```yaml
tls:
  sni: 10.0.0.1        # ← 一个 IP 地址
  insecure: true
```

**Go 的 `crypto/tls` 在生成 ClientHello 时，遇到 IP 字面量会直接不发 SNI。**

不是「发了一个非法的 SNI 被拒」，而是**什么都没发**。源码里 `hostnameInSNI()` 的行为很明确：

```go
if net.ParseIP(host) != nil {
    return ""          // IP 字面量 → 返回空串 → 不写 SNI 扩展
}
```

于是真实链路是：

```
sni: 10.0.0.1  →  ClientHello 里没有 SNI 扩展
               →  服务端拿不到主机名，sniGuard / 证书选择失败
               →  回 TLS alert internal_error (80)
               →  客户端看到 CRYPTO_ERROR 0x150
```

**RFC 6066 §3 确实写了 HostName 不允许 IP 字面量，但那条例在这里不是触发点。**
这个区别会影响排查方向：该找「**SNI 缺失**」，不是找「SNI 写错了」。

**`insecure: true` 只关掉「证书链验证」，不会把缺失的 SNI 补回来。**

## 验证

```powershell
# 1. 看证书的 CN 是什么
$c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 .\server.crt
$c.Subject        # 例如 CN=hysteria.local

# 2. 看客户端配置里的 sni
Select-String -Path .\client.yaml -Pattern 'sni:'

# 3. 如果 sni 是 IP，就是这个问题
```

## 修法

**`sni` 必须用域名形式，而且必须命中服务端证书里的名字。**

> **本节改过两次，以这次为准。** 旧版本写过「`insecure: true` 时填什么都行，只要不是 IP」——
> **那是错的**，会让人以为 `insecure` 等于「全关了」。

### 证书这一侧：`cert` 接受 flag，只拒绝位置参数

```powershell
hysteria cert hysteria.local          # ❌ FATAL cert command does not accept arguments
hysteria cert --host hysteria.local   # ✅ 正常：CN 与 DNS SAN 都是 hysteria.local
hysteria cert                         # ✅ 默认 --host = os.Hostname()
```

v2.13.0 源码（`app/v2.13.0/app/cmd/cert.go`）的 `initCertFlags()` 定义了
`--host / --cert / --key / --valid-for / --overwrite` 五个 flag；
`runCertCmd` 只在 `len(args) != 0` 时 Fatal。

**所以不要「先无参生成、再猜 CN」。** 直接 `--host` 指定，
再把这个**同一个值**写进客户端 `sni`：

```powershell
# 服务端
hysteria cert --host hysteria.local --overwrite
```

```yaml
# 客户端
tls:
  sni: hysteria.local      # ← 与服务端 --host 完全一致
  insecure: true
  pinSHA256: aa:bb:cc:...  # 有 pin 更稳
```

### 为什么 sni 必须命中证书名：服务端的 sniGuard，不是客户端

这一层以前没写清楚，是理解「为什么 `insecure: true` 也没用」的关键：

```yaml
# 服务端 server.yaml
tls:
  cert: server.crt
  key: server.key
  sniGuard: strict | disable | dns-san    # 默认 dns-san
```

官方定义：**`sniGuard` 校验客户端发来的 SNI，与证书内容不匹配就由服务端终止 TLS 握手。**

| 取值 | 行为 |
| --- | --- |
| `dns-san`（**默认**） | 证书里存在**域名型 SAN** 时启用校验；没有 DNS SAN 就不校验 |
| `strict` | 无条件校验 |
| `disable` | 完全关闭 |

**失败链路（服务端主动拒，不是客户端验证失败）：**

```
客户端 sni 与证书名不匹配
  → 服务端 sniGuard 判定失败
  → 服务端终止握手，回 TLS alert internal_error(80)
  → 客户端只看到 CRYPTO_ERROR 0x150 (remote): tls: internal error
```

**`insecure: true` 关掉的是客户端验证证书链，关不掉服务端这道门。**

所以「填个随便的域名」照样挂。真想随便填，只有两条路：
把服务端改成 `sniGuard: disable`（不推荐，等于关掉防护），
或者换一张**没有 DNS 型 SAN** 的证书（此时 `dns-san` 模式不启用校验）。

> 顺带一句：`hysteria cert` 生成的证书**一定带 DNS SAN**（就是 CN 那个名字），
> 所以用它的默认产物，`sniGuard` 必然处于启用状态。
## 为什么这个坑值得记

```
· 错误信息完全指向错误方向（看起来像证书/密码问题）
· insecure: true 给人一种「什么都关了」的错觉，其实服务端 sniGuard 仍在校验 SNI 匹配
· 服务端可能一个字都不记
· 排查时会先去查密码、证书、端口，全查完才想到 SNI
```

# 坑 7：防火墙里一条指名的 `Block` 规则会压过 `Allow`，而且不报错

## 症状

端口在听、进程在跑、服务端日志一条都没有，客户端就是 `timeout: no recent network activity`。

换个端口还是 timeout。关掉防火墙就好了 —— 但你看不出为什么。

## 根因

Windows 防火墙的判定不是「有 Allow 就放行」。**任何一条显式 `Block` 规则命中，就直接丢包**，
后面的 `Allow` 根本不会被评估。Windows 上装过多个代理工具之后，很容易留下这种孤儿规则：

```
Name    : hysteria.exe
Action  : Block
Enabled : True
Program : C:\...\hysteria.exe
Protocol: Any        ← 端口写的是 Any，UDP/TCP 全封
```

而同时你可能还有一条看起来很正常的 `Allow`：

```
Name    : hysteria2 server 9443
Action  : Allow
Protocol: UDP
```

两条同时存在，结果是全封。

## 验证

```powershell
Get-NetFirewallRule | Where-Object { $_.Action -eq 'Block' -and $_.Enabled -eq 'True' } |
  ForEach-Object {
    $app = ($_ | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue).Program
    [pscustomobject]@{ Name = $_.DisplayName; Program = $app; Proto = $_.Protocol }
  } | Where-Object { $_.Program -match 'hysteria|tailscale|clash|mihomo' }
```

## 修法

```powershell
Remove-NetFirewallRule -DisplayName "hysteria.exe"
```

然后只需要一条正常的放行规则：

```powershell
New-NetFirewallRule -DisplayName "hysteria2 server 9443" -Direction Inbound `
  -Protocol UDP -LocalPort 9443 -Action Allow
```

`scripts/verify.ps1` 的 P7 就是断言这一条。

---

# 坑 8：SSH 里起的进程会跟着会话一起死

## 症状

远程 `Start-Process hysteria` 起来，`Get-Process` 能看到，服务日志也正常。
断开 SSH 三十秒后再看：进程没了。没有任何退出日志。

换 `conhost --headless` 启动、`-WindowStyle Hidden`、`nohup` 式的写法，一样会死。

## 根因

Windows 上的 SSH 会话结束时会关掉整个 job object，子进程被连带清理。
这不是「进程崩溃」，所以不会有任何日志 —— 你只会看到它凭空消失。

## 修法

让进程的父级不是你的 SSH 会话。最稳的是**计划任务**：

```powershell
$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
             -Argument "-NoProfile -WindowStyle Hidden -File C:\path\run-server.ps1"
$trigger = @(
  (New-ScheduledTaskTrigger -AtLogOn),
  (New-ScheduledTaskTrigger -Once -At (Get-Date) `
     -RepetitionInterval (New-TimeSpan -Minutes 5) `
     -RepetitionDuration (New-TimeSpan -Days 3650))
)
Register-ScheduledTask -TaskName "hysteria-server-watchdog" -Action $action `
  -Trigger $trigger -RunLevel Limited -LogonType Interactive -Force
```

两层保险：`AtLogOn` 保证开机自启，每 5 分钟的触发器兼作看门狗（脚本自己会判断进程在不在）。

`run-server.ps1` 写成一个 while 循环就行：

```powershell
while ($true) {
  $p = Start-Process hysteria -ArgumentList 'server','-c','server.yaml' -PassThru -NoNewWindow
  $p.WaitForExit()
  "$(Get-Date -f s) exited code=$($p.ExitCode)" | Add-Content watchdog-server.log
  Start-Sleep -Seconds 5
}
```

**注意**：`schtasks /delete` 只删任务，**不会杀掉已经在跑的进程**。要清理就得单独 kill，
否则你会以为「任务删了它还在跑，是不是被什么东西托着」。

---

# 坑 9：用 TCP 去探 QUIC 的端口，会得到假阴性

## 症状

`Test-NetConnection -Port 9443` 返回 False，于是判断「服务端没起 / 防火墙封了」，
去改防火墙、改端口、换机器，全白费。

## 根因

hysteria2 的 `listen: :9443` 是 **UDP/QUIC**。那个端口上根本没有 TCP listener，
所以 TCP 连不上是**正确行为**，不是故障。

同理，`netstat -ano | findstr 9443` 只看 TCP 的话也会是空的 —— 要用 `-p UDP`。

## 验证

别探端口，**直接测「能不能从这条隧道出去，出口是不是对端的 IP」**：

```powershell
curl.exe -s --socks5-hostname 127.0.0.1:1081 https://ipinfo.io/json
# {"ip": "<对端出口IP>", ...}   ← 等于对端的公网 IP 才算通
```

这是端到端断言：DNS、QUIC 握手、Brutal、NAT、防火墙，任何一环坏了它都会失败。
比探端口强得多。

`scripts/verify.ps1` 的 P9 就是干这个，并且会把出口 IP 和 `-PeerExitIp` 比对。

---
---

# 附：一张排查顺序图

```
隧道连不上？
├─ 客户端报 "timeout: no recent network activity" / handshake timeout，服务端无日志
│   └─ → 坑 1（MTU），先查这个，占 90%
├─ 客户端报 "CRYPTO_ERROR ... tls: internal error"
│   └─ → 坑 6（sni 填了 IP）
├─ 服务端有连接记录，但立刻断开
│   └─ → 认证/证书问题，不是本项目的坑
└─ 能连上，但速度慢
    ├─ 单流慢、多流也慢
    │   ├─ 先跑 hysteria speedtest（不经源站）
    │   ├─ 内置测速也慢 → 坑 2（down 设小了）或坑 3（BBR 回落）
    │   └─ 内置测速快、实际慢 → 源站限速（正常）或坑 5（被劫持）
    └─ 多流能上去但单流上不去
        └─ → 源站按连接限速，正常现象，无法突破
```

---

# 坑 10：WebRTC 泄漏，在 TUN 模式下浏览器参数救不回来

## 症状

出口 IP 已经绑到对端住宅 IP，DNS 也跟着走了，但 WebRTC 检测里仍显示**第三个国家**的 IP。

## 根因（两层）

**第一层：本地代理内核开着 TUN 模式。**

TUN 在**操作系统路由层**就把 UDP 接走了。浏览器参数管的是「浏览器自己的代理逻辑」，
管不到 OS 路由。所以 `--force-webrtc-ip-handling-policy=disable_non_proxied_udp`
**确实生效了**（进程命令行里能看到），但拦不住已经被 TUN 抓走的包。

**第二层：Chromium 的 WebRTC 不支持通过 SOCKS5 转发 UDP。**

它只代理 TCP。所以即使指定了 `--proxy-server="socks5://..."`，
STUN 的 UDP 依然落到系统路由上，最终命中规则表兜底。

## 验证

```powershell
# 确认参数真的带上了（看不到就是参数没进进程，Edge 必须先完全退出）
Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" |
  Where-Object { $_.CommandLine -notlike '*--type=*' } |
  Select-Object ProcessId, CommandLine
```

## 判定：可以不修

三条修法代价都大于收益：

| 方法 | 代价 |
| --- | --- |
| 改浏览器组策略（注册表 `WebRtcIPHandlingPolicy`） | 碰注册表，不保证比命令行参数更管用 |
| 关掉 TUN | 影响全局，所有程序的流量路径都变 |
| 按 `DST-PORT` 把 STUN 端口送进隧道 | 很脆，STUN 端口会变（Google 用 19302/19305，TURN 用 443/3478） |

**而且多数站点不拿 WebRTC 当风控信号**——若真拿它判定，会误伤大量正常用户。

**真正有用的替代**：把浏览器**整个**绑到一条固定出口的端口（见坑 11 / [outbound.md](outbound.md)），
这样至少 IP 和 DNS 是一致的。

---

# 坑 11：`listeners[].proxy` 只认真实节点名，写策略组名会静默不监听

## 症状

端口矩阵配好了，`mixed` 端口也写了，但那个端口**连不上**。没有报错、没有日志。

## 根因

```yaml
listeners:
  - name: line-7890
    type: mixed
    port: 7890
    proxy: 美国              # ← 这是一个「策略组」名，不是真实节点
```

`listeners[].proxy` **只接受真实节点名**（proxies 里那个 `name`）。
填策略组名不会报错，只会**静默不监听**。

## 验证

```powershell
# 端口在不在听
Get-NetTCPConnection -State Listen -LocalPort 7890

# 出口对不对（能连上才有输出）
curl.exe -s -m 15 -x socks5h://127.0.0.1:7890 https://ipinfo.io/ip
```

## 修法

```yaml
listeners:
  - name: line-7890
    type: mixed
    port: 7890
    proxy: 对端节点名        # ← 必须是 proxies 里那个真实 name
```

---

# 坑 12：改运行时配置文件没用，会被重新生成；而且两个看门狗会抢同一个端口

## 症状 A：改了配置，重载后没生效

**根因**：本地代理前端（Clash Verge 之类）目录下的 `config.yaml` / `clash-verge.yaml`
是**运行时生成文件**。你在里面手工加规则、加代理，重载或重启时会被**重新生成覆盖掉**。

**判断方法**：改完看一眼文件大小和修改时间，如果和你写的不一样，就是被覆盖了。

**修法**：改**持久层**，不是改生成物。

| 层 | 位置 | 说明 |
| --- | --- | --- |
| 订阅 | `profiles/<订阅id>.yaml` | 会被订阅更新覆盖，别手改 |
| **merge / script** | `profiles/<mergeid>.yaml`、`profiles/<scriptid>.js` | **持久层，改这里** |
| 运行时 | `config.yaml`、`clash-verge.yaml` | 生成物，改了白改 |

**注意**：`profiles/` 下有一个 `Merge.yaml` 和一个 `Script.js`，那可能只是**模板**，
不一定是当前生效的那份。真实文件名在 `profiles.yaml` 里：

```yaml
items:
  - uid: <订阅>
    merge:   mopzGq9Z9xoY      # ← 这个才是生效的 merge
    script:  sx0INUYwx2yO      # ← 这个才是生效的 script
```

## 症状 B：隧道反复启动失败，报端口被占用

```
FATAL failed to run SOCKS5 server
{"error": "listen tcp4 127.0.0.1:1081: bind: Only one usage of each socket address ..."}
```

**根因**：有两个 watchdog 在跑，一个负责拉起隧道，另一个**负责拉起旧方案**。
隧道一停，旧方案那个 watchdog 立刻抢占同一个本地端口，于是隧道再也绑不上，
5 秒后重试、再被抢、无限循环。

**表现**：看起来像「隧道随机重连」，实际是端口争夺。

**排查**：

```powershell
# 谁占着这个端口
Get-NetTCPConnection -State Listen -LocalPort 1081 | Select-Object OwningProcess
Get-CimInstance Win32_Process -Filter "ProcessId=<上一步的 PID>" | Select-Object CommandLine

# 有哪些计划任务在跑
Get-ScheduledTask | Where-Object { $_.TaskName -match 'hysteria|guard|watchdog' } |
  Select-Object TaskName, State
```

**修法**：**停掉旧方案那个 watchdog**（通常是计划任务），别只杀进程——
杀进程它还会被拉起来。

```powershell
Disable-ScheduledTask -TaskName <旧方案的任务名>
# 恢复用：Enable-ScheduledTask -TaskName <同名>
```
