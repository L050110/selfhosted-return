# 已验证的版本组合

这份表只写**真的跑起来过**的版本。「未验证」就是没试过，不代表不行。

实测日期：2026-11-12。两端都是 Windows。

## 两端对照

| 组件 | 我们这端（国内，发起方） | 对端（海外，落地方） | 备注 |
| --- | --- | --- | --- |
| 操作系统 | Windows 11 家庭版 10.0.26200 | Windows 11 | 家用版没有组策略，MTU 只能走注册表/环境变量 |
| 隧道 | hysteria **v2.13.0** | hysteria **v2.13.0** | 两端小版本必须一致，大版本必须一致 |
| 组网 | Tailscale **1.104.5** | Tailscale **1.104.5** | 用 `direct`，不落 DERP |
| 代理前端 | Clash Verge **2.5.10** | — | 内核是 verge-mihomo **v1.19.33** |
| 协议 | hysteria2（QUIC + Brutal） | 同 | 服务端 `listen: :9443`，**UDP** |

## 为什么把版本号写死在这里

三条都是踩过的：

1. **hysteria 2.x 的 `cert` 命令不吃参数。** `hysteria cert hysteria.local` 会直接
   `FATAL cert command does not accept arguments`。它用**机器名**当 CN/SAN。
   跨版本时这个行为如果变了，坑 6 的修法就失效。
2. **Clash Verge 的合并配置语法在 2.4 → 2.5 之间变过。** 2.5.10 里
   `append-fake-ip-filter` 不会被展开，而是原样当成一个未知键丢掉——看起来写成功了，
   实际没生效，且不报错。要改 `dns.fake-ip-filter` 只能写 `Script.js`。
3. **mihomo 的 `external-controller` 可能落在命名管道上，不是 TCP 端口。**
   v1.19.33 在 Clash Verge 下配置里写着 `external-controller: 127.0.0.1:9097`，
   但实际监听的是 `\\.\pipe\verge-mihomo-<profile>-<hash>`。
   去 `127.0.0.1:9097` 找 API 会以「无法连接」告终，让人以为是内核没起。

## 已知不兼容 / 别混着用

| 组合 | 结果 |
| --- | --- |
| hysteria2 客户端 + `socks5` 段里填 `username`/`password` | 连接被拒。hysteria2 内置 SOCKS5 **不做认证**，填了认证字段等于声明要认证 |
| 服务端 `ignoreClientBandwidth: true` + 想要固定速率 | Brutal 退化成普通 BBR，抗丢包能力归零（坑 3） |
| `tls.sni` 填 IP | `CRYPTO_ERROR 0x150 (remote): tls: internal error`（坑 6） |
| 旧 `gost` 的 TCP 转发 + 高丢包链路 | 实测 0.14 Mbps。TCP 在 320 ms RTT + 8% 丢包下会塌，这不是配置问题 |

## 怎么复现这张表

```powershell
hysteria version                  # v2.13.0
tailscale version                 # 1.104.5
(Get-Item "C:\Program Files\Clash Verge\clash-verge.exe").VersionInfo.ProductVersion
# mihomo 内核版本（走命名管道）：
.\scripts\clashpipe.ps1 -Path '/version'
```

`scripts/clashpipe.ps1` 是配套的小工具：Clash Verge 的 API 在命名管道上时，
用它可以像访问 HTTP 一样读 `/version`、`/connections`、`/proxies`。
