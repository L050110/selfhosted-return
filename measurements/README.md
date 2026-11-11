# 原始测量数据

这里存的是**原始记录**，不是整理过的结论。结论在 `docs/performance.md`，
这里放的是能被人重新算一遍的东西。

## 文件

| 文件 | 内容 |
| --- | --- |
| `probe-sample.csv` | 每 5 秒一条的隧道探针记录，最近 300 条（约 25 分钟）。完整记录在本机，没上传 |
| `2026-11-12-scenario.md` | 当晚全部对照实测（gost vs hysteria2 vs 各端口） |

## probe-sample.csv 的列

```
time,gateway,public,peer,curAddr,relay,lastHandshake,diag
```

| 列 | 含义 | 正常值 |
| --- | --- | --- |
| `time` | 本地时间 | — |
| `gateway` | 到本地网关的 ICMP，1=通 | `1` |
| `public` | 到公网（8.8.8.8）的 ICMP，1=通 | `1` |
| `peer` | 到对端 Tailscale IP 的 TCP 连接，1=通 | `1` |
| `curAddr` | Tailscale 当前实际用的地址 | 对端的 `公网IP:端口`（说明是 direct，没走 DERP） |
| `relay` | Tailscale 的中继名 | 空或任意；`curAddr` 有值就说明没在用中继 |
| `lastHandshake` | 最近一次握手的本地时间 | 与 `time` 相差 < 1 分钟 |
| `diag` | 综合判定 | `ok` |

## 为什么这四列要一起看

单看 `peer=1`（TCP 通）会骗人。这条链路上出现过：

- ICMP 到对端丢 14%，但同一时刻 TCP 探测 100% 通 —— **ICMP 被 QoS 限速**，不代表链路坏
- 到 `1.1.1.1` 丢 36%，到 `8.8.8.8` 只丢 0–4% —— **不能拿单个目标代表「整条国际链路」**
- `curAddr` 为空而 `peer=1`：走的是 DERP 中继，延迟会翻倍，但探针全绿

所以判定要看 `curAddr` 是不是对端的公网 IP，而不是只看通断。

## 采样脚本

```powershell
.\scripts\probe.ps1 -PeerIp <对端 Tailscale IP> -PublicIp 8.8.8.8 -IntervalSeconds 5
```

脚本用命名互斥体保证只有一个实例在写同一个 CSV —— 否则两个实例会交叉写，
行数翻倍、时间戳乱序，看起来像「隧道抖得很厉害」。
