import Foundation

enum SingBoxConfig {
    private static func tls(_ n: ProxyNode) -> [String: Any]? {
        let sec = n.p("security") ?? ((n.proto == "trojan" || n.proto == "hysteria2") ? "tls" : "none")
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
        case "xhttp":
            var t: [String: Any] = ["type": "xhttp"]
            if let mode = n.p("mode") { t["mode"] = mode }
            if let path = n.p("path") { t["path"] = path }
            if let host = n.p("host") { t["host"] = host }
            if let bytes = n.p("x_padding_bytes") { t["x_padding_bytes"] = bytes }
            if let obfsMode = n.p("x_padding_obfs_mode") {
                t["x_padding_obfs_mode"] = ["1", "true", "yes"].contains(obfsMode.lowercased())
            }
            if let key = n.p("x_padding_key") { t["x_padding_key"] = key }
            if let header = n.p("x_padding_header") { t["x_padding_header"] = header }
            if let method = n.p("x_padding_method") { t["x_padding_method"] = method }
            if let placement = n.p("x_padding_placement") { t["x_padding_placement"] = placement }
            return t
        default:
            return nil
        }
    }

    static func outbound(_ n: ProxyNode, tag: String) -> [String: Any] {
        var o: [String: Any] = ["tag": tag, "server": n.server, "server_port": n.port]
        switch n.proto {
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
        default:
            o["type"] = "direct"
        }
        if n.proto != "ss", let t = tls(n) { o["tls"] = t }
        if ["vless", "vmess", "trojan"].contains(n.proto), let tr = transport(n) { o["transport"] = tr }
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

    static func isSupported(_ n: ProxyNode) -> Bool {
        ["vless", "vmess", "trojan", "ss", "hysteria2"].contains(n.proto)
            && !n.server.isEmpty && !n.secret.isEmpty && (1...65535).contains(n.port)
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

    static func build(nodes: [ProxyNode], selectedID: UUID?, mode: ProxySelectionMode,
                      bypassCN: Bool, rules: [ProxyRoutingRule],
                      categoryPolicies: [ProxyTrafficCategory: ProxyGroupPolicy] = [:]) -> String {
        let usable = nodes.filter(isSupported)
        let tags = usable.map { nodeTag($0) }
        let selectedTag = usable.first(where: { $0.id == selectedID }).map { nodeTag($0) } ?? tags.first ?? "direct"
        let proxyDefault = mode == .automatic ? "auto" : selectedTag

        let direct: [String: Any] = ["type": "direct", "tag": "direct"]
        var outbounds: [[String: Any]] = usable.map { outbound($0, tag: nodeTag($0)) }
        outbounds.append(direct)
        if tags.isEmpty {
            outbounds.append(["type": "selector", "tag": "proxy", "outbounds": ["direct"]])
            for c in ProxyTrafficCategory.allCases {
                outbounds.append(["type": "selector", "tag": groupTag(c), "outbounds": ["direct", "proxy"]])
            }
        } else {
            let auto: [String: Any] = ["type": "urltest", "tag": "auto", "outbounds": tags,
                                       "url": nodeProbeURL, "interval": "5m"]
            let members = mode == .automatic ? ["auto"] + tags : [selectedTag] + tags.filter { $0 != selectedTag }
            let selector: [String: Any] = ["type": "selector", "tag": "proxy", "outbounds": members,
                                           "default": proxyDefault]
            outbounds.append(auto)
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
