# 六个必踩的坑

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

**但 RFC 6066 明确规定：TLS 的 SNI 扩展只能是 DNS 主机名，不能是 IP 字面量。**

```
收到 IP 形式的 SNI，Go 的 crypto/tls 直接失败
错误码 0x150 = TLS alert internal_error
客户端拿到的就是这个不透明的 CRYPTO_ERROR
```

**而 `insecure: true` 只关掉「证书链验证」，不会让非法的 SNI 变合法。**

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

**`sni` 永远用域名形式。`insecure: true` 时它不被验证，所以填什么都行，只要不是 IP。**

```yaml
tls:
  sni: hysteria.local      # 用证书的 CN，或者任何域名
  insecure: true
  pinSHA256: aa:bb:cc:...  # 有 pin 更稳
```

**用 `hysteria cert` 生成证书时，CN 由 `--host` 的第一个值决定：**

```powershell
hysteria cert --host hysteria.local
#               ↑ 这个值就是 CN，客户端 sni 要跟它一致
```

**注意：`--host` 传多个值（`hysteria.local,10.0.0.1`）只会让 CN 取第一个，
不会生成 SAN 扩展。所以不要指望靠 SAN 覆盖 IP 访问。**

## 为什么这个坑值得记

```
· 错误信息完全指向错误方向（看起来像证书/密码问题）
· insecure: true 给人一种「什么都关了」的错觉，其实 SNI 格式仍然被检查
· 服务端可能一个字都不记
· 排查时会先去查密码、证书、端口，全查完才想到 SNI
```

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
