# B 方向（出国）：用一台境外的家用电脑做出口

> **方向**：使用者在**境内**，出口在**境外**。
> 服务端装境外那台（它的住宅 IP 就是出口），客户端装境内这台。
>
> 这一篇是 [README](../README.md) 那个方向（回国）的**镜像**。
> 两篇一起看，就是「双向」。总览见 [dual-direction.md](dual-direction.md)。

---

## 它和 A 方向（回国）差在哪

| | A 方向：回国 | B 方向：出国 |
| --- | --- | --- |
| 服务端 | 境内那台，`listen: :8443` | 境外那台，`listen: :9443` |
| 客户端 | 境外这台 | 境内这台 |
| 实测 RTT | ~300 ms | **225–227 ms** |
| 实测吞吐 | **99.4 Mbps** 单流 | **7.0–7.5 Mbps** |
| 上限来源 | 境内那台上行（~99 Mbps） | 境外那台上行（22 Mbps，链路交出 7.5） |
| 主力用途 | 政务/银行/票务/视频 | 住宅 IP 注册验证、分区内容、价格查询、当探针 |

**同一套软件、同一种协议，差 13 倍。** 别拿 A 的数字去承诺 B。

---

## 前提（和 A 方向一样，一条都绕不过）

```
1. 境外那一端要有人，而且愿意让你装东西
2. 那台机器要能长期开机（睡眠 = 你这边立刻断）
3. 两端都要装软件、配对、调参
4. 出问题只能自己查
```

**决定用不用这套的唯一一条**：那台机器能不能从「会关机的笔记本」变成「不会动的固定设施」。
这一个判断比任何调参都重要。

---

## 部署

### 1. 境外那台：起服务端

```powershell
# 证书：v2.13.0 的 cert 命令不吃任何参数，CN 取机器名
hysteria cert          # 成功会生成 server.crt / server.key

# 记下 CN，客户端 sni 必须等于它
# 在 server.yaml 里确认 listen 是 UDP，例如 listen: :9443
```

`server.yaml` 关键几项：

```yaml
listen: :9443

tls:
  cert: server.crt
  key:  server.key

bandwidth:
  up: 22 mbps      # ← 填这台机器的真实上行，不是套餐标称
  down: 100 mbps

# 关键：保持 false，让服务端按客户端声明发
ignoreClientBandwidth: false
```

> `ignoreClientBandwidth: true` 会让 Brutal **静默退化成普通 BBR**，
> 抗丢包能力归零，而且不报错。这是坑 3。

### 2. 境内这台：起客户端

```yaml
server: 100.x.x.x:9443      # ← 对端的 Tailscale IPv4，不是公网 IP
auth: <两端一致>

tls:
  sni: <服务端 CN，必须是主机名，不能填 IP>
  insecure: true

bandwidth:
  up:   80 mbps    # ← 本机真实上行
  down: 8 mbps     # ← 见下面「声明值怎么定」

socks5:
  listen: 127.0.0.1:1081
```

> **`sni` 填 IP 会失败**，报 `CRYPTO_ERROR 0x150 (remote): tls: internal error`。
> 机制不是「发了非法 SNI 被 RFC 6066 拒」——Go 的 `crypto/tls` 遇到 IP 字面量
> **根本不发 SNI**（`hostnameInSNI()` 对 `net.ParseIP()` 命中的返回空串），
> 服务端因此 `sniGuard` / 证书选择失败。修法一样，但排查方向不同：找「没发」，不是找「发错了」。

### 3. 声明值怎么定：测拐点，不要猜

`bandwidth.down` 是**硬上限**，Brutal 按它发送，不会自己让路。

实测（同方向、同路径、只改声明）：

| 声明 | 实测 | 占声明 |
| --- | --- | --- |
| 8 mbps | 7.38 Mbps | 92%（≈满额，见注） |
| 10 mbps | 7.52 / 7.30 Mbps | 75% |
| 12 mbps | **7.12 Mbps** | 59% |

**声明越高，实际越低**——超发的包丢在瓶颈里。

> 注：92% 不是损失。Brutal 按线上字节计（含 QUIC 头约 4%），而 `curl -w %{speed_download}`
> 把首字节等待也算进总时长（约 4.5%），两项相乘正好 ~92%，即**声明 8 时其实足额送达**。

**测法：**

```powershell
# 单流 20 MB，看拐点；换 3 个声明值各测一次
curl.exe -s -m 90 -x socks5h://127.0.0.1:1081 -o NUL `
  -w "time=%{time_total} speed=%{speed_download}`n" `
  "https://speed.cloudflare.com/__down?bytes=20000000"
```

**`%{speed_download}` 含 TTFB**。扣掉首字节再算才是真实吞吐：

```
有效吞吐 = 字节数 × 8 / (time_total − ttfb)
```

---

## 分流：按端口绑出口，比走规则表稳

**问题**：走规则表时，隧道进程本身可能被规则抓走、绕道或劫持，速度掉一半；
DNS 也仍走本地，出口 IP 和 DNS 出口不一致——这是「环境不一致」里最容易漏的一环。

**做法**：给每条线路开一个 `mixed` 端口，**绑死一个节点**，不走规则。

```yaml
# mihomo / Clash 的 merge 层（不是 profiles 里那份订阅）
listeners:
  - name: line-7890
    type: mixed
    port: 7890
    listen: 127.0.0.1
    proxy: 出口节点名        # ← 必须是真实节点名，不能写策略组名
  - name: line-7896
    type: mixed
    port: 7896
    listen: 127.0.0.1
    proxy: 出口节点名
```

用法：**给程序指定 `--proxy-server`**，它的全部流量无条件走这条线。

```powershell
# 浏览器专属实例：整个浏览器绑到 7896，含 UDP
msedge.exe --proxy-server="socks5://127.0.0.1:7896"
```

**实测效果**（同一台机、同一时刻）：

| 指标 | 走规则表 | 绑 7896 |
| --- | --- | --- |
| 中国出口 IPv4 | 本地 IP | **住宅 IP（对端）** |
| Cloudflare 出口 | 第三个国家 | **住宅 IP（对端）** |
| DNS 出口 | 本地 ISP | **对端 ISP** |
| WebRTC UDP | 第三个国家 | 仍泄漏（见坑 10） |

**一次绑定，三处统一。** 这是这套方案里性价比最高的一个改动。

> `listeners[].proxy` 只接受**真实节点名**，写策略组名不会报错，只会静默不监听——
> 极难发现。这是坑 11。

---

## 验证（三级，从便宜到贵）

**第一级：出口对不对**

```powershell
curl.exe -s -x socks5h://127.0.0.1:1081 https://ipinfo.io/json
# 看 ip / org，应该是对端的住宅运营商
```

**第二级：实际走的是哪条路（别猜，读连接表）**

```powershell
.\scripts\clashpipe.ps1 -Path '/connections' -OutFile conns.json
# 看 metadata.process / chains / rule / rulePayload 四个字段
```

**第三级：真实吞吐**

```powershell
# 单流 20 MB（见上面「声明值怎么定」）
```

---

## 这套东西不该用的时候

作者自己撞过的坑，比任何评测都直接：

- **对端关机就断。** Windows 更新自动重启 + 睡眠，断过 2.5 小时
- **链路干净时 hysteria2 反而不如 BBR。** Brutal 的优势建立在丢包上；链路干净时它只是更激进
- **九个坑会把你劝退三次。** 不接受折腾的人，去用商业方案
- **要 7×24 的别用。** 这套的可用性等于「对端那台机器的可用性」

---

## 责任边界

- 出口那台的**宽带条款**在你（或帮你的人）身上
- 让对端用自己的住宅 IP 给你访问银行/政务，**责任边界在对端身上**
- **别把住宅 IP 当免风控通行证**：同一 IP 挂多账号、高频请求，一样会被盯
