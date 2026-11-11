// 过渡期 PAC 示例
//
// 用途：从「旧方案」切换到「新内核」时使用。
//      保留旧的域名列表，只把返回值改成多级回退。
//
// 为什么不直接换成一行 PROXY：
//      新内核万一没起来，一行版会让浏览器全部直连——什么都打不开。
//      多级回退能在「端口连不上」时自动退回旧客户端，用户零感知。
//
// 为什么不原地改旧 PAC 文件：
//      PAC 有缓存，浏览器可能不重读。要换文件名 + 改注册表指向。
//
// ⚠️ 使用前请把下面的 <FILL_ME> 换掉，并把你自己旧的域名列表贴进来。

function FindProxyForURL(url, host) {

    // ── 本地地址直接连 ──────────────────────────────
    if (isPlainHostName(host) ||
        shExpMatch(host, "127.*") ||
        shExpMatch(host, "localhost") ||
        shExpMatch(host, "*.local")) {
        return "DIRECT";
    }

    // ── 新内核 / 旧客户端 / 直连 三级的定义 ─────────
    // 端口要和你的实际配置一致
    var NEW_CORE = "PROXY 127.0.0.1:7890";     // 新内核（mihomo/sing-box）
    var OLD_CORE = "PROXY 127.0.0.1:10809";    // 旧客户端（切换期保留）
    var FALLBACK = "DIRECT";

    // 国内域名：三级回退（新 → 旧 → 直连）
    var CN_TIER   = NEW_CORE + "; " + OLD_CORE + "; " + FALLBACK;

    // 其他域名：两级回退（新 → 直连）
    // 注意：故意不回退到 OLD_CORE，避免把境外站点也送进隧道
    var OTHER_TIER = NEW_CORE + "; " + FALLBACK;


    // ── ① 国内域名后缀 ──────────────────────────────
    var cnSuffix = [
        ".cn", ".gov.cn", ".com.cn", ".net.cn", ".org.cn", ".edu.cn"
    ];
    for (var i = 0; i < cnSuffix.length; i++) {
        if (dnsDomainIs(host, cnSuffix[i])) return CN_TIER;
    }

    // ── ② 国内常见站点 ──────────────────────────────
    // 把你旧的 PAC 里这一整段原样复制过来即可
    var cnDomains = [
        // <FILL_ME: 从旧 PAC 复制你的域名列表>
        // 示例格式：
        // "example.com", "example2.com",
        // 注意：末尾不要留逗号
    ];
    for (var j = 0; j < cnDomains.length; j++) {
        if (dnsDomainIs(host, cnDomains[j]) || host === cnDomains[j]) {
            return CN_TIER;
        }
    }

    // ── ③ 其余全部走两级回退 ────────────────────────
    return OTHER_TIER;
}


// ═══════════════════════════════════════════════════
// 观察期结束后的极简版（旧客户端已停用时换成这个）
// ═══════════════════════════════════════════════════
//
// function FindProxyForURL(url, host) {
//     return "PROXY 127.0.0.1:7890; DIRECT";
// }
//
// 说明：
//   此时不再需要域名判断，因为新内核的规则集（GEOSITE/GEOIP）
//   覆盖面远大于手写列表，PAC 只负责「把流量交给内核」这一个动作。
//   末尾的 DIRECT 是兜底：内核没起来时浏览器自动退回直连，
//   不会出现「全部断网」。
