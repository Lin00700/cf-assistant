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
                let opts = sanitizePluginOpts(n.params["plugin_opts"] ?? "")
                if !opts.isEmpty { o["plugin_opts"] = opts }
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

    /// Hostname or IPv4. Rejects undecoded share blobs such as OjA3….
    static func isDialableHost(_ host: String) -> Bool {
        if host.isEmpty || host.count > 253 || host.contains(" ") { return false }
        if literalIPv4(host) != nil { return true }
        if host.contains(":") { return true }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return host.unicodeScalars.allSatisfy { allowed.contains($0) } && host.contains(".")
    }

    /// simple-obfs rejects `obfs-host=name:123456`. Keep a bare hostname and only obfs / obfs-host / obfs-uri.
    static func sanitizePluginOpts(_ raw: String) -> String {
        var obfs = ""
        var host = ""
        var uri = ""
        for part in raw.split(separator: ";") {
            let bits = part.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            guard bits.count == 2 else { continue }
            switch bits[0] {
            case "obfs":
                obfs = bits[1]
            case "obfs-host":
                var value = bits[1]
                if let colon = value.lastIndex(of: ":") {
                    let tail = value[value.index(after: colon)...]
                    if !tail.isEmpty, tail.allSatisfy(\.isNumber) {
                        value = String(value[..<colon])
                    }
                }
                host = value
            case "obfs-uri":
                uri = bits[1]
            default:
                break
            }
        }
        var out: [String] = []
        if !obfs.isEmpty { out.append("obfs=\(obfs)") }
        if !host.isEmpty { out.append("obfs-host=\(host)") }
        if !uri.isEmpty { out.append("obfs-uri=\(uri)") }
        return out.joined(separator: ";")
    }


    /// One proxy outbound (the chosen node, tag "proxy") plus direct. No urltest, no category selectors.
    static func build(nodes: [ProxyNode], selectedID: UUID?, mode: ProxySelectionMode,
                      bypassCN: Bool, rules: [ProxyRoutingRule],
                      categoryPolicies: [ProxyTrafficCategory: ProxyGroupPolicy] = [:],
                      resolvedExcludes: [String] = []) -> String {
        _ = mode
        _ = categoryPolicies
        guard let node = nodes.first(where: { $0.id == selectedID }) ?? nodes.first(where: isSupported) else {
            return "{}"
        }
        let proxy = outbound(node, tag: "proxy")
        let direct: [String: Any] = ["type": "direct", "tag": "direct"]

        var excludes = ["223.5.5.5/32", "8.8.8.8/32"]
        if let ip = literalIPv4(node.server) {
            excludes.insert("\(ip)/32", at: 0)
        }
        for cidr in resolvedExcludes where !excludes.contains(cidr) {
            excludes.append(cidr)
        }

        var routeRules: [[String: Any]] = [
            ["action": "sniff", "timeout": "500ms", "sniffer": ["tls", "http", "quic"]],
            ["protocol": "dns", "action": "hijack-dns"],
            ["ip_is_private": true, "outbound": "direct"]
        ]
        var dnsRules: [[String: Any]] = []
        if let ip = literalIPv4(node.server) {
            routeRules.append(["ip_cidr": ["\(ip)/32"], "outbound": "direct"])
        } else if node.server.contains(".") {
            routeRules.append(["domain_suffix": [node.server], "outbound": "direct"])
            dnsRules.append(["domain_suffix": [node.server], "server": "dns-local"])
        }
        if bypassCN {
            routeRules.append(["domain_suffix": cnSuffixes, "outbound": "direct"])
            dnsRules.append(["domain_suffix": cnSuffixes, "server": "dns-local"])
        }
        for rule in rules {
            let value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { continue }
            let outboundName = rule.target == .direct ? "direct" : "proxy"
            var item: [String: Any] = ["outbound": outboundName]
            switch rule.kind {
            case .domainSuffix:
                item["domain_suffix"] = [value]
                dnsRules.append(["domain_suffix": [value], "server": rule.target == .direct ? "dns-local" : "dns-remote"])
            case .ipCIDR:
                item["ip_cidr"] = [value]
            }
            routeRules.append(item)
        }

        let dns: [String: Any] = [
            "servers": [
                ["tag": "dns-local", "address": "udp://223.5.5.5", "detour": "direct"],
                ["tag": "dns-remote", "address": "tls://8.8.8.8", "detour": "proxy"]
            ],
            "rules": dnsRules,
            "final": "dns-remote",
            "strategy": "prefer_ipv4"
        ]
        let tun: [String: Any] = [
            "type": "tun", "tag": "tun-in",
            "address": ["172.19.0.1/30"],
            "mtu": 1500,
            "auto_route": true,
            "strict_route": false,
            "stack": "system",
            "inet4_route_exclude_address": excludes
        ]
        let route: [String: Any] = [
            "rules": routeRules,
            "final": "proxy",
            "auto_detect_interface": false
        ]
        let cfg: [String: Any] = [
            "log": ["level": "debug", "timestamp": true],
            "dns": dns,
            "inbounds": [tun],
            "outbounds": [proxy, direct],
            "route": route,
            "experimental": ["clash_api": ["external_controller": "127.0.0.1:\(controlPort)"]]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: cfg, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
