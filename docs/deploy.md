# 部署流程

**核心原则：新旧并存，切换只改一个注册表值，回滚也是。**

这样任何一步出问题都能在几秒内退回原状，不会出现「换完打不开任何网站」。

---

## 阶段 0：前置检查

**在动手之前确认这四件事，任何一条不满足就先解决。**

```powershell
# ① 两端能互相 ping 通（Tailscale 已连通）
tailscale status                        # 两端都应是 online
tailscale ping <对端 Tailscale IP>       # 应显示 via <IP>:<port> 而不是 via DERP

# ② 对端的上行带宽（决定你的速度上限）
#    在对端机器上跑，用公开测速站测「上传」
#    这个数字就是你能拿到的下载速度天花板

# ③ 路径 MTU 能过 1308 字节的 IP 包
ping -f -l 1280 <对端 Tailscale IP>      # 通 → 1308 的 IP 包能过
#    （ping -l 1280 的 IP 包 = 1280 + 20 + 8 = 1308）

# ④ 防火墙允许 UDP 8443（hysteria2 默认端口）
```

**如果 ③ 不通，先做 [pitfalls.md](pitfalls.md) 的坑 1，否则后面全部白费。**

---

## 阶段 1：服务端（境内那一端）

### 1.1 生成证书和配置

```powershell
.\scripts\setup-server.ps1 -Port 8443
```

**它会生成：**

```
server.crt          自签证书（ECDSA P-256，比 RSA 小一半）
server.key          私钥
server.yaml         服务端配置
password.txt        自动生成的认证密码
```

**为什么用 ECDSA 而不是 RSA：**

```
QUIC 握手回包会带证书链。ECDSA P-256 的证书约 550 字节，
RSA-2048 约 1086 字节。握手包越小，越不容易撞上 MTU 限制。
```

### 1.2 关键配置项

```yaml
bandwidth:
  up: 95 mbps        # 填对端实测上行 × 0.95
  down: 100 mbps
# 千万不要加 ignoreClientBandwidth: true（见 pitfalls 坑 3）

speedTest: true      # 保留它，以后排查瓶颈时能一次排除源站

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 60s
  keepAlivePeriod: 10s
```

### 1.3 用看门狗启动（不要直接跑 exe）

```powershell
.\scripts\install-watchdog.ps1 -Role server
```

**它会做三件事：**

```
① 写一个循环脚本（崩了 5 秒重启，注意 Set-Location）
② 注册计划任务（普通权限、每 5 分钟触发、已在运行则忽略）
③ 立即启动并验证
```

**为什么不直接双击 exe：**

```
· 崩了不会自己回来
· 用「计划任务 + 最高权限 + 交互式登录」会静默失败（实测 LastTaskResult=1）
· 从 SSH 启动的进程，SSH 一断就被杀
```

### 1.4 验证服务端

```powershell
# 端口在听
Get-NetUDPEndpoint -LocalPort 8443

# 服务端日志应该有 "server up and running"
Get-Content .\s.err -Tail 5
```

---

## 阶段 2：客户端（境外那一端）

### 2.1 生成配置

```powershell
.\scripts\setup-client.ps1 `
  -ServerAddr <服务端的 Tailscale IPv4> `
  -Port 8443 `
  -Password <从 password.txt 读到的密码>
```

**注意 `-ServerAddr` 一定要填 IPv4 字面地址（`100.x.x.x`），不要填 MagicDNS 名字。**

```
原因：MagicDNS 名可能解析到 IPv6，而 IPv6 的 QUIC 首包需要 1328 字节，
      比 IPv4 多 20 字节。如果 MTU 只设到 1320，走 IPv6 会再撞一次坑。
```

### 2.2 客户端的关键配置

```yaml
bandwidth:
  up: 18 mbps        # 对端的上行（也就是你这边的上行）
  down: 95 Mbps      # 你这边能收到的速率，填服务端上行的 90-95%

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 41943040
  maxConnReceiveWindow: 41943040
```

### 2.3 起客户端并验证

```powershell
.\scripts\install-watchdog.ps1 -Role client
```

**验证（此时系统代理还没动，用户零感知）：**

```powershell
# 两条 curl，看分流对不对
curl -s -x http://127.0.0.1:7890 https://myip.ipip.net
#   期望：显示境内那一端的出口 IP

curl -s -x http://127.0.0.1:7890 https://api.ipify.org
#   期望：显示境外这一端自己的公网 IP（说明走了 DIRECT）

# 然后把你实际要访问的站点逐个跑一遍
curl -s -o NUL -w "%{http_code} %{time_total}" -x http://127.0.0.1:7890 <目标站>
```

**这一步全部通过，才进入阶段 3。**

---

## 阶段 3：切换（新旧并存期）

**前提：旧的方案还在跑，一个字节都没动。**

### 3.1 备份（做一次，放好）

```powershell
# 旧 PAC
Copy-Item "$env:USERPROFILE\proxy-cn.pac" "$env:USERPROFILE\proxy-cn.pac.bak"

# 注册表（整个 Internet Settings 键）
reg export "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" `
    "$env:USERPROFILE\inet-backup.reg" /y

# 旧计划任务
schtasks /query /tn "<旧任务名>" /xml > "$env:USERPROFILE\old-task.xml"
```

### 3.2 用「过渡 PAC」，不要一步换到极简版

**过渡 PAC 保留旧的域名列表，只是把返回值改成多级回退：**

```javascript
// 命中国内域名时
return "PROXY 127.0.0.1:7890; PROXY 127.0.0.1:10809; DIRECT";
//        ↑ 新内核         ↑ 旧客户端（回退）    ↑ 最后兜底

// 其他流量
return "PROXY 127.0.0.1:7890; DIRECT";
//        ↑ 新内核         ↑ 兜底（注意：不回退到旧的，避免把境外站送进隧道）
```

**为什么用多级回退：**

```
浏览器在「代理端口连不上」时会自动尝试下一个。
本机端口没人监听会立即被拒绝，回退几乎无延迟。

它管不了的情况：进程活着但隧道断了。
这时浏览器认为代理正常，不会回退——只能靠观察和手动回滚。
```

### 3.3 切换（用新文件名 + 改注册表，绝不原地改内容）

```powershell
# 生成新 PAC（文件名不同）
Copy-Item .\examples\proxy-mihomo.pac "$env:USERPROFILE\proxy-mihomo.pac"

# 改注册表指向新文件
Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" `
    -Name AutoConfigURL `
    -Value "file:///$($env:USERPROFILE -replace '\\','/')/proxy-mihomo.pac" `
    -Force
```

**为什么不能原地改 PAC 文件内容：**

```
PAC 有缓存。原地改内容，浏览器可能不重读，要等重启或几小时后。
后果：你以为切过去了，其实浏览器还在用旧脚本，
      观察到的现象和你的操作对不上，排查方向直接错掉。

这是整套流程里最容易翻车的一步。
```

### 3.4 确认切换生效

**在切换后一分钟内，看内核日志有没有出现浏览器的请求：**

```powershell
Get-Content .\core.log -Tail 20 | Select-String '\[TCP\]'
```

**期待的日志形态：**

```
[TCP] 127.0.0.1:53124 --> www.example.com:443 match GeoSite(cn) using A
                                    ↑目标域名        ↑命中的规则    ↑走的代理
```

| 要判断的事 | 找什么 | 怎么读 |
|---|---|---|
| 切换是否生效 | 一分钟内有没有出现浏览器的请求 | 没有就说明浏览器还在用旧 PAC |
| 走错方向 | `match Match using DIRECT` | 所有规则都没命中、兜底直连的域名。列出来人工看有没有国内站 |
| IP 规则在起作用 | `match GeoIP(CN) using A` | 靠 IP 段救回来的站，数量不为零说明 DNS 链路正常 |
| 隧道故障 | 同一行里有 `dial A` 和 `error` | 偶发可忽略，成片出现就是隧道断了 |
| 客户端自己解析了域名 | 目标是裸 IP 而不是域名 | 某个程序先本地解析再连代理，规则只能按 IP 判断 |

---

## 阶段 4：观察期（1-2 天）

**不要急着停旧客户端。这一阶段的目标是发现漏网的域名。**

```powershell
# 每天看一次：哪些域名走了兜底直连
Get-Content .\core.log |
  Select-String 'match Match using DIRECT' |
  ForEach-Object { if ($_ -match '--> ([^:]+):') { $Matches[1] } } |
  Group-Object | Sort-Object Count -Descending | Select-Object -First 30
```

**如果里面有国内站点，就在 `config.yaml` 的 rules 最前面加一条：**

```yaml
rules:
  - DOMAIN-SUFFIX,<漏掉的域名>,A     # 显式规则优先于一切清单
  - GEOSITE,geolocation-!cn,DIRECT
  - GEOSITE,cn,A
  - GEOIP,CN,A
  - MATCH,DIRECT
```

**改完重启内核（看门狗会在 5 秒内拉起）。**

### 观察期要看的第二件事：绕过代理的程序

**内核日志看不到这类程序（它们根本没连代理）。要从系统层面看：**

```powershell
Get-NetTCPConnection -State Established |
  Where-Object { $_.RemoteAddress -notmatch '^(127\.|100\.|::1)' } |
  Group-Object OwningProcess |
  ForEach-Object { "{0,5}  {1}" -f $_.Count, (Get-Process -Id $_.Name).ProcessName }
```

**注意：这不是新方案引入的问题。不读系统代理的程序，在旧方案里也一样绕过。**

---

## 阶段 5：收尾

**观察期确认无误后：**

```powershell
# ① 简化 PAC（旧的域名列表可以删了，内核对规则集的覆盖更全）
#    改成一行：
#    function FindProxyForURL(url, host) {
#      return "PROXY 127.0.0.1:7890; DIRECT";
#    }

# ② 停掉旧客户端（禁用计划任务，不要删文件）
schtasks /change /tn "<旧任务名>" /disable

# ③ 保留旧文件一周再清理
```

---

## 回滚（一条命令，几秒钟）

**任何阶段出问题，立刻回滚：**

```powershell
Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" `
    -Name AutoConfigURL `
    -Value "file:///C:/Users/<用户名>/proxy-cn.pac" -Force
```

**回滚后需要重启浏览器吗：**

```
据公开资料，Chromium 会监视这个注册表项，改地址会重新加载 PAC，
一般不需要重启浏览器。

验证方法：回滚后看新内核的日志，新请求应在一分钟内停止出现。
如果还在进来，才需要请用户重启浏览器。
```

---

## 长期维护三件事

### ① 规则的自动更新

```yaml
geo-auto-update: true
geo-update-interval: 168    # 小时，即 7 天
```

### ② 服务端日志级别

```yaml
log-level: info     # 日常用 info
# debug 只在你需要看每个域名的完整判断过程时临时开
```

### ③ 对端机器的稳定性（最关键）

```powershell
# 关闭 AC 供电下的自动待机/休眠
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0

# Windows 更新的活动时间要避开对方的使用时段
# 在 HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings 里改
# ActiveHoursStart / ActiveHoursEnd（0-23，跨天用小的在前）
```

**本项目的实际教训：对端机器因为 Windows 自动更新重启、随后进入睡眠，
导致通道断了 2.5 小时，正好撞在使用时段。**

**如果这个「对端」是笔记本，它随时可能被合盖、被带走。真正的解法是换成一个不会动的设备。**

---

## 检查清单（打印出来照着勾）

```
阶段 0
  □ tailscale status 两端 online
  □ tailscale ping 显示 via <IP>:<port>（不是 via DERP）
  □ 对端上行实测（记下数字，这是天花板）
  □ ping -f -l 1280 对端 通

阶段 1（服务端）
  □ 证书生成（ECDSA P-256）
  □ bandwidth.up 填对端上行 × 0.95
  □ 没有 ignoreClientBandwidth
  □ 看门狗装好，杀进程能自动恢复
  □ UDP 8443 在听

阶段 2（客户端）
  □ ServerAddr 填的是 IPv4 字面地址
  □ bandwidth.down 填服务端上行 × 0.90-0.95
  □ myip.ipip.net 显示境内出口
  □ api.ipify.org 显示本地出口
  □ 目标站点全部可访问

阶段 3（切换）
  □ 旧 PAC / 注册表 / 计划任务都已备份
  □ 用过渡 PAC（多级回退），不是极简版
  □ 改的是注册表，不是原地改 PAC 内容
  □ 切换后一分钟内日志出现浏览器请求

阶段 4（观察）
  □ 每天看一次 match Match using DIRECT 的域名
  □ 漏网的国内站已补显式规则
  □ 没有成片的 dial A + error

阶段 5（收尾）
  □ PAC 简化成一行
  □ 旧客户端计划任务禁用（不删文件）
```
