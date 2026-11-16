import Foundation

/// 工作流里的 Libbox 由 sing-box 1.11.x 编译。这个版本没有 AnyTLS（1.12 才有），
/// 所以 AnyTLS 节点可以导入、编辑、保存在列表里，但不会写进出站配置，避免整份配置被拒。
enum LibboxCapabilities {
    static let anyTLS = false
    static let versionText = "sing-box 1.11.x"
}

/// 自动优选（urltest）组的参数
struct SingBoxAutoPolicy {
    var intervalMinutes: Int = 5
    var toleranceMilliseconds: Int = 50

    var intervalText: String { "\(max(1, intervalMinutes))m" }
    var tolerance: Int { max(0, toleranceMilliseconds) }
}

enum SingBoxConfig {
    static func tls(_ n: ProxyNode) -> [String: Any]? {
        let proto = ProxyProtocol.canonical(n.proto)
        let sec = n.p("security") ?? (ProxyProtocol.defaultTLS(proto) ? "tls" : "none")
        guard sec == "tls" || sec == "reality" else { return nil }
        var t: [String: Any] = ["enabled": true]
        t["server_name"] = n.p("sni") ?? n.p("peer") ?? n.p("host") ?? n.server
        if n.p("allowInsecure") == "1" || n.p("insecure") == "1" { t["insecure"] = true }
        if let a = n.p("alpn") {
            t["alpn"] = a.split(separator: ",").map { String($0) }
        }
        if sec == "reality" {
            let reality: [String: Any] = ["enabled": true, "public_key": n.p("pbk") ?? "", "short_id": n.p("sid") ?? ""]
            t["reality"] = reality
            let utls: [String: Any] = ["enabled": true, "fingerprint": n.p("fp") ?? "chrome"]
            t["utls"] = utls
        } else if let fp = n.p("fp") {
            let utls: [String: Any] = ["enabled": true, "fingerprint": fp]
            t["utls"] = utls
        }
        return t
    }

    private static func transport(_ n: ProxyNode) -> [String: Any]? {
        let type = n.p("type") ?? n.p("net") ?? "tcp"
        switch type {
        case "ws":
            var t: [String: Any] = ["type": "ws", "path": n.p("path") ?? "/"]
            if let h = n.p("host") { t["headers"] = ["Host": h] }
            return t
        case "grpc":
            return ["type": "grpc", "service_name": n.p("serviceName") ?? n.p("path") ?? ""]
        case "httpupgrade":
            var t: [String: Any] = ["type": "httpupgrade", "path": n.p("path") ?? "/"]
            if let h = n.p("host") { t["host"] = h }
            return t
        default:
            return nil
        }
    }

    private static func intList(_ text: String?) -> [Int] {
        guard let text else { return [] }
        return text.split(separator: ",").compactMap { Int(String($0).trimmingCharacters(in: .whitespaces)) }
    }

    private static func stringList(_ text: String?) -> [String] {
        guard let text else { return [] }
        return text.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 生成一个出站。`detour` 是前置节点（链式代理）的出站标签。
    static func outbound(_ n: ProxyNode, tag: String, detour: String? = nil) -> [String: Any] {
        if let template = n.jsonTemplate, !template.isEmpty,
           let data = template.data(using: .utf8),
           var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           obj["type"] != nil {
            obj["tag"] = tag
            if let detour, !detour.isEmpty {
                obj["detour"] = detour
            } else {
                obj.removeValue(forKey: "detour")
            }
            return obj
        }

        let proto = ProxyProtocol.canonical(n.proto)
        var o: [String: Any] = ["tag": tag, "server": n.server, "server_port": n.port]
        if let detour, !detour.isEmpty { o["detour"] = detour }
        switch proto {
        case "vless":
            o["type"] = "vless"
            o["uuid"] = n.secret
            if let f = n.p("flow") { o["flow"] = f }
            o["packet_encoding"] = "xudp"
        case "vmess":
            o["type"] = "vmess"
            o["uuid"] = n.secret
            o["security"] = n.p("scy") ?? "auto"
            o["alter_id"] = Int(n.p("aid") ?? "0") ?? 0
        case "trojan":
            o["type"] = "trojan"
            o["password"] = n.secret
        case "ss":
            o["type"] = "shadowsocks"
            o["method"] = n.p("method") ?? "aes-128-gcm"
            o["password"] = n.secret
            if let pl = n.p("plugin") {
                o["plugin"] = pl
                o["plugin_opts"] = n.params["plugin_opts"] ?? ""
            }
        case "hysteria2":
            o["type"] = "hysteria2"
            o["password"] = n.secret
            if let ob = n.p("obfs") {
                o["obfs"] = ["type": ob, "password": n.p("obfs-password") ?? ""]
            }
            if let up = Int(n.p("up") ?? "") { o["up_mbps"] = up }
            if let down = Int(n.p("down") ?? "") { o["down_mbps"] = down }
            let ports = stringList(n.p("ports"))
            if !ports.isEmpty { o["server_ports"] = ports }
        case "tuic":
            o["type"] = "tuic"
            o["uuid"] = n.secret
            if let pw = n.p("password") { o["password"] = pw }
            if let cc = n.p("congestion_control") { o["congestion_control"] = cc }
            if let mode = n.p("udp_relay_mode") { o["udp_relay_mode"] = mode }
            if n.p("udp_over_stream") == "1" { o["udp_over_stream"] = true }
        case "wireguard":
            // sing-box 1.11 仍支持旧式 wireguard 出站（1.13 起改用 endpoints）。
            // 用旧式出站是为了让它和别的节点一样参与 selector / urltest / detour。
            o["type"] = "wireguard"
            o["private_key"] = n.secret
            let local = stringList(n.p("local_address") ?? n.p("address"))
            o["local_address"] = local.isEmpty ? ["10.0.0.2/32"] : local
            if let pub = n.p("peer_public_key") ?? n.p("publickey") {
                o["peer_public_key"] = pub
            }
            if let psk = n.p("pre_shared_key") ?? n.p("presharedkey") {
                o["pre_shared_key"] = psk
            }
            let reserved = intList(n.p("reserved"))
            if !reserved.isEmpty { o["reserved"] = reserved }
            if let mtu = Int(n.p("mtu") ?? "") { o["mtu"] = mtu }
        case "shadowtls":
            o["type"] = "shadowtls"
            o["version"] = Int(n.p("version") ?? "") ?? 3
            o["password"] = n.secret
        case "ssh":
            o["type"] = "ssh"
            o["user"] = n.p("user") ?? "root"
            if !n.secret.isEmpty { o["password"] = n.secret }
            if let key = n.p("private_key") { o["private_key"] = [key] }
            let hostKeys = stringList(n.p("host_key"))
            if !hostKeys.isEmpty { o["host_key"] = hostKeys }
        case "anytls":
            o["type"] = "anytls"
            o["password"] = n.secret
        default:
            o["type"] = "direct"
        }
        if ["vless", "vmess", "trojan"].contains(proto), let tr = transport(n) { o["transport"] = tr }
        if proto != "ss" && proto != "wireguard" && proto != "ssh" {
            if proto == "tuic" {
                // TUIC 必须走 TLS，ALPN 默认 h3
                var t: [String: Any] = tls(n) ?? ["enabled": true] as [String: Any]
                if t["server_name"] == nil { t["server_name"] = n.server }
                if t["alpn"] == nil { t["alpn"] = ["h3"] }
                o["tls"] = t
            } else if let t = tls(n) {
                o["tls"] = t
            }
        }
        return o
    }

    static let cnSuffixes = ["cn", "baidu.com", "qq.com", "weixin.qq.com", "taobao.com", "tmall.com", "alipay.com",
                             "alibaba.com", "aliyun.com", "jd.com", "163.com", "126.net", "bilibili.com",
                             "weibo.com", "zhihu.com", "douyin.com", "bytedance.com", "xiaohongshu.com",
                             "meituan.com", "mi.com", "xiaomi.com", "huawei.com", "sina.com.cn"]

    static let nodeProbeURL = "https://cp.cloudflare.com/generate_204"
    static let controlPort = 9090
    static let controlURL = URL(string: "http://127.0.0.1:9090")!

    static func nodeTag(_ n: ProxyNode) -> String {
        "node-" + n.id.uuidString.lowercased()
    }

    /// 能否写进出站配置。字段不全的节点直接跳过，避免整份配置被 sing-box 拒绝。
    static func isSupported(_ n: ProxyNode) -> Bool {
        guard !n.server.isEmpty, (1...65535).contains(n.port) else { return false }
        if n.hasJSONTemplate { return true }
        let proto = ProxyProtocol.canonical(n.proto)
        switch proto {
        case "vless", "vmess", "trojan", "ss", "hysteria2", "shadowtls":
            return !n.secret.isEmpty
        case "tuic":
            return !n.secret.isEmpty && (n.p("password") != nil || n.p("token") != nil)
        case "wireguard":
            return !n.secret.isEmpty && (n.p("peer_public_key") ?? n.p("publickey")) != nil
        case "ssh":
            return (n.p("user") != nil || !n.secret.isEmpty) && (!n.secret.isEmpty || n.p("private_key") != nil)
        case "anytls":
            return LibboxCapabilities.anyTLS && !n.secret.isEmpty
        default:
            return false
        }
    }

    /// 节点不能连接时的原因（用于界面提示）。
    static func unsupportedReason(_ n: ProxyNode) -> String? {
        if isSupported(n) { return nil }
        let proto = ProxyProtocol.canonical(n.proto)
        if proto == "anytls" && !LibboxCapabilities.anyTLS {
            return "AnyTLS 需要 \(LibboxCapabilities.versionText) 之后的 sing-box，当前安装包暂不能连接"
        }
        if n.server.isEmpty { return "缺少服务器地址" }
        if !(1...65535).contains(n.port) { return "端口无效" }
        switch proto {
        case "tuic": return "TUIC 需要 UUID 与密码"
        case "wireguard": return "WireGuard 需要私钥与对端公钥"
        case "ssh": return "SSH 需要用户名，以及密码或私钥"
        default: return "节点信息不完整"
        }
    }

    private static func literalIPv4(_ host: String) -> String? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        for p in parts {
            guard let n = Int(p), (0...255).contains(n) else { return nil }
        }
        return host
    }

    static func groupTag(_ category: ProxyTrafficCategory) -> String {
        "group-" + category.rawValue
    }

    private static func groupDefault(policy: ProxyGroupPolicy, selectedTag: String) -> String {
        switch policy {
        case .direct: return "direct"
        case .auto: return "auto"
        case .proxy, .follow: return selectedTag
        }
    }

    /// 分类策略 → 最终出站（不绕选择器）
    private static func outboundForPolicy(_ policy: ProxyGroupPolicy, hasNodes: Bool) -> String {
        switch policy {
        case .direct: return "direct"
        case .auto: return hasNodes ? "auto" : "proxy"
        case .proxy, .follow: return "proxy"
        }
    }

    /// 链式代理：本节点的前置节点标签。遇到指向不存在的节点或环时返回 nil。
    private static func detourTag(for node: ProxyNode, byID: [UUID: ProxyNode]) -> String? {
        guard let detourID = node.detourID, let first = byID[detourID] else { return nil }
        var visited: Set<UUID> = [node.id]
        var current: ProxyNode? = first
        var depth = 0
        while let hop = current {
            if !visited.insert(hop.id).inserted { return nil }
            depth += 1
            if depth > 8 { return nil }
            current = hop.detourID.flatMap { byID[$0] }
        }
        return nodeTag(first)
    }

    /// 显示用的链式路径（前置 → 落地），遇到环返回 nil。
    static func detourChain(nodes: [ProxyNode], node: ProxyNode) -> [ProxyNode] {
        var byID: [UUID: ProxyNode] = [:]
        for n in nodes { byID[n.id] = n }
        var chain: [ProxyNode] = []
        var visited: Set<UUID> = [node.id]
        var current = node.detourID.flatMap { byID[$0] }
        while let hop = current, visited.insert(hop.id).inserted, chain.count < 8 {
            chain.append(hop)
            current = hop.detourID.flatMap { byID[$0] }
        }
        return chain
    }

    static func build(nodes: [ProxyNode], selectedID: UUID?, mode: ProxySelectionMode,
                      bypassCN: Bool, rules: [ProxyRoutingRule],
                      categoryPolicies: [ProxyTrafficCategory: ProxyGroupPolicy] = [:],
                      auto: SingBoxAutoPolicy = SingBoxAutoPolicy()) -> String {
        let usable = nodes.filter(isSupported)
        let tags = usable.map { nodeTag($0) }
        let selectedTag = usable.first(where: { $0.id == selectedID }).map { nodeTag($0) } ?? tags.first ?? "direct"
        let proxyDefault = mode == .automatic ? "auto" : selectedTag
        var byID: [UUID: ProxyNode] = [:]
        for n in usable { byID[n.id] = n }

        let direct: [String: Any] = ["type": "direct", "tag": "direct"]
        var outbounds: [[String: Any]] = usable.map {
            outbound($0, tag: nodeTag($0), detour: detourTag(for: $0, byID: byID))
        }
        outbounds.append(direct)
        if tags.isEmpty {
            outbounds.append(["type": "selector", "tag": "proxy", "outbounds": ["direct"]])
            for c in ProxyTrafficCategory.allCases {
                outbounds.append(["type": "selector", "tag": groupTag(c), "outbounds": ["direct", "proxy"]])
            }
        } else {
            let autoGroup: [String: Any] = ["type": "urltest", "tag": "auto", "outbounds": tags,
                                            "url": nodeProbeURL, "interval": auto.intervalText,
                                            "tolerance": auto.tolerance, "idle_timeout": "30m"]
            let members = mode == .automatic ? ["auto"] + tags : [selectedTag] + tags.filter { $0 != selectedTag }
            let selector: [String: Any] = ["type": "selector", "tag": "proxy", "outbounds": members,
                                           "default": proxyDefault]
            outbounds.append(autoGroup)
            outbounds.append(selector)
            let groupMembers = ["proxy", "auto", "direct"] + tags
            for c in ProxyTrafficCategory.allCases {
                let policy = categoryPolicies[c] ?? .follow
                let def = groupDefault(policy: policy, selectedTag: proxyDefault)
                outbounds.append(["type": "selector", "tag": groupTag(c),
                                  "outbounds": groupMembers,
                                  "default": def])
            }
        }

        var nodeIPs: [String] = []
        for n in usable {
            if let ip = literalIPv4(n.server) {
                nodeIPs.append("\(ip)/32")
            }
        }

        // sniff 必须包含 dns。只嗅 tls/http/quic 时，发往 172.19.0.2:53 的查询
        // 不会被标成 protocol=dns，接着被 ip_is_private 直接送出，系统 DNS 就会空等 30 秒。
        var routeRules: [[String: Any]] = [
            ["action": "sniff", "timeout": "500ms", "sniffer": ["tls", "http", "quic", "dns"]],
            ["ip_cidr": ["223.5.5.5/32", "8.8.8.8/32"], "outbound": "direct"],
            ["protocol": "dns", "action": "hijack-dns"],
            ["ip_cidr": ["172.19.0.2/32", "127.0.0.1/32"], "port": 53, "action": "hijack-dns"],
            ["port": 53, "action": "hijack-dns"],
            ["ip_is_private": true, "outbound": "direct"]
        ]

        if !nodeIPs.isEmpty {
            routeRules.append(["ip_cidr": nodeIPs, "outbound": "direct"])
        }

        var dnsRules: [[String: Any]] = []
        for r in rules {
            let v = r.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty { continue }
            let out = r.target == .direct ? "direct" : "proxy"
            var rule: [String: Any] = ["outbound": out]
            switch r.kind {
            case .domainSuffix:
                rule["domain_suffix"] = [v]
                dnsRules.append(["domain_suffix": [v], "server": r.target == .direct ? "dns-local" : "dns-remote"])
            case .ipCIDR:
                rule["ip_cidr"] = [v]
            }
            routeRules.append(rule)
        }

        if bypassCN {
            routeRules.append(["domain_suffix": cnSuffixes, "outbound": "direct"])
            dnsRules.append(["domain_suffix": cnSuffixes, "server": "dns-local"])
        }

        // 分类：按策略直接指向 proxy / auto / direct（改完立刻进配置，不依赖选择器状态）
        for c in ProxyTrafficCategory.allCases {
            let policy = categoryPolicies[c] ?? .follow
            let out = outboundForPolicy(policy, hasNodes: !tags.isEmpty)
            if !c.suffixes.isEmpty {
                routeRules.append(["domain_suffix": c.suffixes, "outbound": out])
                dnsRules.append(["domain_suffix": c.suffixes,
                                 "server": policy == .direct ? "dns-local" : "dns-remote"])
            }
        }

        // Some mobile networks time out UDP/53 while allowing direct TCP/443.
        // Use the literal Cloudflare IP to avoid a DNS bootstrap loop; keep this
        // resolver on the direct outbound for local/domestic DNS rules.
        // Do not exclude 1.1.1.1 globally: direct sockets are bound to the physical
        // interface by TunnelPlatform, so ordinary app traffic keeps its policy.
        let dnsServers: [[String: Any]] = [
            ["tag": "dns-local",  "address": "https://1.1.1.1/dns-query", "detour": "direct"],
            ["tag": "dns-backup", "address": "udp://8.8.8.8",   "detour": "direct"],
            ["tag": "dns-remote", "address": "tls://8.8.8.8",   "detour": "proxy"]
        ]
        let dns: [String: Any] = [
            "servers": dnsServers,
            "rules": dnsRules,
            "final": "dns-local",
            "strategy": "prefer_ipv4",
            "independent_cache": true
        ]

        var tunExcludes: [String] = nodeIPs
        tunExcludes.append(contentsOf: ["223.5.5.5/32", "8.8.8.8/32"])
        var tun: [String: Any] = [
            "type": "tun", "tag": "tun-in",
            "address": ["172.19.0.1/30"],
            "mtu": 1500,
            "auto_route": true,
            "strict_route": false,
            "stack": "system"
        ]
        if !tunExcludes.isEmpty {
            tun["inet4_route_exclude_address"] = tunExcludes
        }

        let route: [String: Any] = [
            "rules": routeRules,
            "final": "proxy",
            "auto_detect_interface": true
        ]
        let log: [String: Any] = ["level": "info", "timestamp": true]
        let clash: [String: Any] = ["external_controller": "127.0.0.1:\(controlPort)"]
        let experimental: [String: Any] = ["clash_api": clash]
        let cfg: [String: Any] = [
            "log": log, "dns": dns, "inbounds": [tun], "outbounds": outbounds,
            "route": route, "experimental": experimental
        ]
        let data = (try? JSONSerialization.data(withJSONObject: cfg, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
