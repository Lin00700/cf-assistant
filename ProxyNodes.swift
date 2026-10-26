import Foundation

// MARK: - 节点模型

struct ProxyNode: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var proto: String            // vless / vmess / trojan / ss / hysteria2
    var server: String
    var port: Int
    var secret: String           // uuid / password
    var params: [String: String] = [:]
    var raw: String = ""         // 原始分享链接（导入时保留）

    var detail: String { "\(proto.uppercased()) · \(server):\(port)" }

    func p(_ k: String) -> String? {
        guard let v = params[k], !v.isEmpty else { return nil }
        return v
    }
}

// MARK: - 节点选择与分流规则

enum ProxySelectionMode: String, Codable, CaseIterable {
    case manual
    case automatic
}

struct ProxyRoutingRule: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case domainSuffix
        case ipCIDR
    }

    enum Target: String, Codable, CaseIterable {
        case direct
        case proxy
    }

    var id = UUID()
    var kind: Kind
    var value: String
    var target: Target
}

// MARK: - 链接解析

enum LinkParser {
    static func b64(_ s: String) -> Data? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    static func parse(_ text: String) -> ProxyNode? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = s.lowercased()
        if l.hasPrefix("vmess://") { return vmess(s) }
        if l.hasPrefix("ss://") { return shadowsocks(s) }
        if l.hasPrefix("vless://") { return generic(s, proto: "vless") }
        if l.hasPrefix("trojan://") { return generic(s, proto: "trojan") }
        if l.hasPrefix("hysteria2://") || l.hasPrefix("hy2://") { return generic(s, proto: "hysteria2") }
        return nil
    }

    /// 订阅内容：Base64 或按行的分享链接
    static func parseMany(_ text: String) -> [ProxyNode] {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.contains("://"), let d = b64(t), let dec = String(data: d, encoding: .utf8) { t = dec }
        return t.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { parse(String($0)) }
    }

    static func fetchSubscription(_ urlString: String) async throws -> [ProxyNode] {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CFClientError.message("订阅地址无效")
        }
        var req = URLRequest(url: url)
        req.setValue("v2rayN/6.42", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        let nodes = parseMany(String(decoding: data, as: UTF8.self))
        if nodes.isEmpty { throw CFClientError.message("订阅里没有解析到可用节点") }
        return nodes
    }

    private static func generic(_ s: String, proto: String) -> ProxyNode? {
        var main = s
        var frag = ""
        if let i = s.firstIndex(of: "#") {
            main = String(s[..<i])
            frag = String(s[s.index(after: i)...])
        }
        guard let c = URLComponents(string: main), let host = c.host, !host.isEmpty else { return nil }
        var p: [String: String] = [:]
        for q in c.queryItems ?? [] { p[q.name] = q.value ?? "" }
        let secret = c.user?.removingPercentEncoding ?? c.user ?? ""
        let name = frag.removingPercentEncoding ?? frag
        return ProxyNode(name: name.isEmpty ? host : name, proto: proto, server: host,
                         port: c.port ?? 443, secret: secret, params: p, raw: s)
    }

    private static func vmess(_ s: String) -> ProxyNode? {
        let body = String(s.dropFirst("vmess://".count))
        guard let data = b64(body),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func str(_ k: String) -> String {
            if let v = obj[k] as? String { return v }
            if let n = obj[k] as? NSNumber { return n.stringValue }
            return ""
        }
        let host = str("add")
        guard !host.isEmpty else { return nil }
        let net = str("net").isEmpty ? "tcp" : str("net")
        let p: [String: String] = [
            "type": net, "host": str("host"), "path": str("path"), "aid": str("aid"),
            "scy": str("scy"), "sni": str("sni"), "alpn": str("alpn"), "fp": str("fp"),
            "security": str("tls") == "tls" ? "tls" : "none"
        ]
        return ProxyNode(name: str("ps").isEmpty ? host : str("ps"), proto: "vmess", server: host,
                         port: Int(str("port")) ?? 443, secret: str("id"), params: p, raw: s)
    }

    private static func shadowsocks(_ s: String) -> ProxyNode? {
        var body = String(s.dropFirst("ss://".count))
        var name = ""
        if let i = body.firstIndex(of: "#") {
            name = String(body[body.index(after: i)...]).removingPercentEncoding ?? ""
            body = String(body[..<i])
        }
        var plugin = ""
        if let i = body.firstIndex(of: "?") {
            let query = String(body[body.index(after: i)...])
            body = String(body[..<i])
            for kv in query.split(separator: "&") {
                let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2, parts[0] == "plugin" { plugin = parts[1].removingPercentEncoding ?? parts[1] }
            }
        }
        var userinfo = ""
        var hostport = ""
        if let at = body.lastIndex(of: "@") {
            userinfo = String(body[..<at])
            hostport = String(body[body.index(after: at)...])
            if !userinfo.contains(":"), let d = b64(userinfo), let t = String(data: d, encoding: .utf8) {
                userinfo = t
            } else {
                userinfo = userinfo.removingPercentEncoding ?? userinfo
            }
        } else if let d = b64(body), let t = String(data: d, encoding: .utf8), let at = t.lastIndex(of: "@") {
            userinfo = String(t[..<at])
            hostport = String(t[t.index(after: at)...])
        } else { return nil }
        guard let colon = userinfo.firstIndex(of: ":"),
              let pc = hostport.lastIndex(of: ":"),
              let port = Int(String(hostport[hostport.index(after: pc)...])) else { return nil }
        let method = String(userinfo[..<colon])
        let pass = String(userinfo[userinfo.index(after: colon)...])
        let host = String(hostport[..<pc]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var params: [String: String] = ["method": method]
        if !plugin.isEmpty {
            let parts = plugin.split(separator: ";", maxSplits: 1).map(String.init)
            params["plugin"] = parts[0] == "simple-obfs" ? "obfs-local" : parts[0]
            params["plugin_opts"] = parts.count > 1 ? parts[1] : ""
        }
        return ProxyNode(name: name.isEmpty ? host : name, proto: "ss", server: host, port: port,
                         secret: pass, params: params, raw: s)
    }

    /// 导出分享链接（导入的节点用原链接；Worker 生成的 VLESS 节点现场拼）
    static func shareLink(_ n: ProxyNode) -> String {
        if !n.raw.isEmpty { return n.raw }
        guard n.proto == "vless" else { return "" }
        var items = [URLQueryItem(name: "encryption", value: "none")]
        for k in n.params.keys.sorted() { if let v = n.p(k) { items.append(URLQueryItem(name: k, value: v)) } }
        var c = URLComponents()
        c.scheme = "vless"
        c.user = n.secret
        c.host = n.server
        c.port = n.port
        c.queryItems = items
        c.fragment = n.name
        return c.string ?? ""
    }
}
