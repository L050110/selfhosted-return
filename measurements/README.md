# 原始测量数据

这里存的是**原始记录**，不是整理过的结论。结论在 `docs/performance.md`，
这里放的是能被人重新算一遍的东西。

## 文件

| 文件 | 内容 |
| --- | --- |
| `probe-sample.csv` | 每 5 秒一条的隧道探针记录，最近 300 条（约 25 分钟）。完整记录在本机，没上传 |
| `2026-11-12-scenario.md` | 当晚全部对照实测（gost vs hysteria2 vs 各端口） |

## probe.csv 的列

`probe.ps1` 现在采两类东西：**可达性**（每轮）和**吞吐/出口**（按周期）。

```
timestamp,gateway,public,peer,curAddr,relay,lastHandshake,tsDiag,egressIp,mbpsEff,ttfbSec,bytes,speedDiag
```

| 列 | 频率 | 含义 | 正常值 |
| --- | --- | --- | --- |
| `timestamp` | 每轮 | 本地时间 | — |
| `gateway` | 每轮 | 到本地网关的 ICMP，1=通 | `1` |
| `public` | 每轮 | 到公网（如 8.8.8.8）的 ICMP，1=通 | `1` |
| `peer` | 每轮 | 到对端 Tailscale IP 的 TCP 连接，1=通 | `1` |
| `curAddr` | 每轮 | Tailscale 当前实际用的地址 | 对端的 `公网IP:端口`（说明是 direct，没走 DERP） |
| `relay` | 每轮 | Tailscale 的中继名 | 空或任意；`curAddr` 有值说明没在用中继 |
| `lastHandshake` | 每轮 | 最近一次握手的本地时间 | 与 `timestamp` 相差 < 1 分钟 |
| `tsDiag` | 每轮 | Tailscale 查询的判定 | `ok` |
| `egressIp` | 每 N 轮 | 经 SOCKS 出口看到的公网 IP | 对端的住宅 IP；不是本地 IP |
| `mbpsEff` | 每 N 轮 | **扣除 TTFB 后的有效吞吐**（Mbps） | 见下 |
| `ttfbSec` | 每 N 轮 | 首字节等待（秒） | 洲际链路 0.7–1.2 常见 |
| `bytes` | 每 N 轮 | 本次采样下载的字节数 | 与 `-SpeedUrl` 一致 |
| `speedDiag` | 每 N 轮 | 采样判定 | `ok` / `skip`（本轮不采）/ 其他=失败原因 |

> **旧文件是 8 列**（`time,...,diag`），`probe-sample.csv` 就是旧格式，保留原样作为历史样本。
> 新采的记录一律 13 列。

### 为什么是 `mbpsEff` 而不是 `speed_download`

`curl -w %{speed_download}` = 字节数 / `time_total`，**分母含 DNS、建连、等首字节**。
225 ms RTT 的洲际链路上 TTFB 常到 0.7–1.2 秒，摊进十几秒的传输里会凭空少 4–5%。

```
mbpsEff = bytes × 8 / (time_total − time_starttransfer) / 1e6
```

`probe.ps1` 就是这么算的，所以这列可以直接拿去画图，不用二次修正。

### 一个必须知道的副作用

**采样那轮会拖慢节奏。** `-IntervalSeconds` 是「两轮之间 sleep 多久」，不是墙钟周期：

```
实际间隔 = IntervalSeconds + 本轮采样耗时
         采样耗时：成功时 ≈ 采样字节数 × 8 ÷ 有效吞吐
                   断链时 ≈ Speed 超时(30s) + Egress 超时(15s)
```

所以别拿「时间戳间隔」当采样周期用。`egressIp` 与 `mbpsEff` 已经**错开半个周期**采样，
避免两个超时叠在同一轮；即便如此，断链时那一轮仍会吞掉几十秒——**而断链恰恰是你最需要
那几十秒可达性数据的时候**，所以要么把 `-SpeedEvery` 调大，要么单独跑一个不采吞吐的实例。

要无干扰的等间隔数据，两条路：

- 把 `-SpeedUrl` 换成小一点的（比如 `?bytes=1000000`），采样耗时降到 1 秒级
- 或者只关心吞吐、不关心频率：`-SpeedEvery 60`（5 秒间隔下约 5 分钟采一次）

### 从 CSV 直接出报告

```powershell
Import-Csv .\probe.csv | Where-Object { $_.speedDiag -eq 'ok' } |
  Select-Object timestamp, mbpsEff, ttfbSec, egressIp |
  Format-Table -AutoSize
```

成功采样的行拿去算中位数/离散度，口径见 [docs/how-to-verify.md](../docs/how-to-verify.md) 第二节。

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
