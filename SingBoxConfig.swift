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
                outbounds.append(["type": "selector", "tag": groupTag(c),
                                  "outbounds": groupMembers,
                                  "default": groupDefault(policy: policy, selectedTag: proxyDefault)])
            }
        }

        var nodeIPs: [String] = []
        for n in usable {
            if let ip = literalIPv4(n.server) {
                nodeIPs.append("\(ip)/32")
            }
        }

        var routeRules: [[String: Any]] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
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

        for c in ProxyTrafficCategory.allCases {
            routeRules.append(["domain_suffix": c.suffixes, "outbound": groupTag(c)])
            let policy = categoryPolicies[c] ?? .follow
            dnsRules.append(["domain_suffix": c.suffixes,
                             "server": policy == .direct ? "dns-local" : "dns-remote"])
        }

        let dnsServers: [[String: Any]] = [
            ["tag": "dns-local",  "address": "udp://223.5.5.5", "detour": "direct"],
            ["tag": "dns-backup", "address": "udp://8.8.8.8",   "detour": "direct"],
            ["tag": "dns-remote", "address": "tls://8.8.8.8",   "detour": "proxy"]
        ]
        let dns: [String: Any] = [
            "servers": dnsServers,
            "rules": dnsRules,
            "final": "dns-remote",
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
            "auto_detect_interface": false
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
