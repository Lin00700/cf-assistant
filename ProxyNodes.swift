import Foundation
import CoreFoundation

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

    var detail: String {
        var s = "\(proto.uppercased()) · \(server):\(port)"
        if proto == "ss", let m = p("method") { s += " · \(m)" }
        return s
    }

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

enum ProxyGroupPolicy: String, Codable, CaseIterable {
    case follow
    case proxy
    case direct
    case auto

    var title: String {
        switch self {
        case .follow: return "跟随节点选择"
        case .proxy: return "代理"
        case .direct: return "直连"
        case .auto: return "自动选择"
        }
    }
}

enum ProxyTrafficCategory: String, Codable, CaseIterable, Identifiable {
    case ai
    case streaming
    case telegram
    case google

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ai: return "AI 服务"
        case .streaming: return "流媒体"
        case .telegram: return "电报"
        case .google: return "谷歌油管"
        }
    }

    var symbol: String {
        switch self {
        case .ai: return "brain.head.profile"
        case .streaming: return "play.tv"
        case .telegram: return "paperplane"
        case .google: return "magnifyingglass"
        }
    }

    var clashName: String {
        switch self {
        case .ai: return "AI服务"
        case .streaming: return "流媒体"
        case .telegram: return "电报"
        case .google: return "谷歌油管"
        }
    }

    var suffixes: [String] {
        switch self {
        case .ai:
            return ["openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com",
                    "anthropic.com", "claude.ai", "deepseek.com", "groq.com",
                    "perplexity.ai", "poe.com", "cursor.sh", "cursor.com", "x.ai",
                    "generativelanguage.googleapis.com", "gemini.google.com",
                    "copilot.microsoft.com", "openaiapi-site.azureedge.net"]
        case .streaming:
            return ["netflix.com", "nflxvideo.net", "nflximg.net", "nflxso.net",
                    "disneyplus.com", "dssott.com", "hulu.com", "max.com", "hbo.com",
                    "hbomax.com", "primevideo.com", "aiv-cdn.net", "spotify.com",
                    "spotifycdn.com", "tidal.com", "tidalhifi.com", "twitch.tv",
                    "ttvnw.net", "tiktok.com", "tiktokv.com", "tiktokcdn.com",
                    "musical.ly", "bytedance.com", "bilibili.tv"]
        case .telegram:
            return ["telegram.org", "telegram.me", "t.me", "tdesktop.com",
                    "telegra.ph", "telegram-cdn.org", "telesco.pe"]
        case .google:
            return ["google.com", "google.com.hk", "google.co.jp", "googleapis.com",
                    "gstatic.com", "googleusercontent.com", "ggpht.com", "gvt1.com",
                    "gvt2.com", "gvt3.com", "youtube.com", "youtu.be", "ytimg.com",
                    "googlevideo.com", "youtube-nocookie.com", "withgoogle.com",
                    "android.com", "googleadservices.com"]
        }
    }
}

// MARK: - 链接解析

enum LinkParser {
    static func b64(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
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
        if let d = b64(t), let decoded = String(data: d, encoding: .utf8) { t = decoded }
        return t.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { parse(String($0)) }
    }

    static func fetchSubscription(_ urlString: String) async throws -> [ProxyNode] {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let nodes = parseMany(String(decoding: data, as: UTF8.self))
        if nodes.isEmpty { throw URLError(.cannotParseResponse) }
        return nodes
    }

    /// `vless://uuid@host:port?...` stays as-is. `vless://BASE64(uuid@host:port?...)`
    /// is decoded before the host is stored, otherwise the server becomes the blob
    /// and sing-box cannot dial it. Shadowsocks keeps its own SIP002 parser.
    private static func generic(_ s: String, proto: String) -> ProxyNode? {
        if let node = nodeFromDecodedShare(s, proto: proto) { return node }
        return genericURL(s, proto: proto)
    }

    private static func genericURL(_ s: String, proto: String) -> ProxyNode? {
        guard let url = URL(string: s) else { return nil }
        let host = url.host ?? ""
        if proto == "vless", serverLooksLikeBlob(host) { return nil }
        let port = url.port ?? 443
        let secret = credential(url.user ?? "", proto: proto)
        var params: [String: String] = [:]
        if let items = URLComponents(string: s)?.queryItems {
            for i in items { if let v = i.value { params[i.name] = v } }
        }
        params = normalizedTransportParams(params, proto: proto)
        let name = url.fragment?.removingPercentEncoding ?? host
        return ProxyNode(name: name.isEmpty ? host : name, proto: proto, server: host,
                         port: port, secret: secret, params: params, raw: s)
    }

    private static func nodeFromDecodedShare(_ s: String, proto: String) -> ProxyNode? {
        guard let range = s.range(of: "://") else { return nil }
        var body = String(s[range.upperBound...])
        var fragment = ""
        if let i = body.firstIndex(of: "#") {
            fragment = String(body[body.index(after: i)...]).removingPercentEncoding ?? ""
            body = String(body[..<i])
        }
        var query = ""
        if let i = body.firstIndex(of: "?") {
            query = String(body[body.index(after: i)...])
            body = String(body[..<i])
        }
        let encodedCandidate = body.removingPercentEncoding ?? body
        var encodedName = ""
        if !encodedCandidate.contains("@"), let data = b64(encodedCandidate),
           let text = String(data: data, encoding: .utf8), text.contains("@") {
            encodedName = encodedCandidate
            body = text
            if let i = body.firstIndex(of: "#") {
                if fragment.isEmpty {
                    fragment = String(body[body.index(after: i)...]).removingPercentEncoding ?? ""
                }
                body = String(body[..<i])
            }
            if let i = body.firstIndex(of: "?") {
                if query.isEmpty { query = String(body[body.index(after: i)...]) }
                body = String(body[..<i])
            }
        }
        guard let at = body.lastIndex(of: "@") else { return nil }
        let user = String(body[..<at]).removingPercentEncoding ?? String(body[..<at])
        var hostport = String(body[body.index(after: at)...])
        hostport = hostport.removingPercentEncoding ?? hostport
        guard let colon = hostport.lastIndex(of: ":"),
              let port = Int(hostport[hostport.index(after: colon)...].filter(\.isNumber)),
              (1...65535).contains(port) else { return nil }
        var host = String(hostport[..<colon])
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard serverLooksDialable(host) else { return nil }
        let params = normalizedTransportParams(queryParams(query), proto: proto)
        let fallbackName = proto == "vless" && !encodedName.isEmpty ? encodedName : host
        let name = fragment.isEmpty ? fallbackName : fragment
        return ProxyNode(name: name, proto: proto, server: host, port: port,
                         secret: credential(user, proto: proto), params: params, raw: s)
    }

    /// `auto:uuid` / `:uuid` on a VLESS link is still just the UUID. Passwords stay intact.
    private static func credential(_ user: String, proto: String) -> String {
        let decoded = user.removingPercentEncoding ?? user
        guard proto == "vless" || proto == "vmess" else { return decoded }
        let parts = decoded.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2 {
            let head = parts[0].lowercased()
            if head.isEmpty || head == "auto" || head == "none" || parts[1].count >= 32 {
                return parts[1]
            }
        }
        return decoded
    }

    private static func queryParams(_ query: String) -> [String: String] {
        var params: [String: String] = [:]
        guard !query.isEmpty else { return params }
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].removingPercentEncoding ?? parts[0]
            let value = parts[1].removingPercentEncoding ?? parts[1]
            if !key.isEmpty { params[key] = value }
        }
        return params
    }

    private static func normalizedTransportParams(_ params: [String: String], proto: String) -> [String: String] {
        guard proto == "vless" else { return params }
        var result = params
        func value(_ keys: [String]) -> String? {
            for key in keys {
                if let pair = params.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }), !pair.value.isEmpty {
                    return pair.value
                }
            }
            return nil
        }

        if let type = value(["type", "net"]) { result["type"] = type.lowercased() }
        if let obfs = value(["obfs"]), obfs.lowercased() == "xhttp" { result["type"] = "xhttp" }
        if let host = value(["host"]) { result["host"] = host }
        if let sni = value(["sni", "peer", "servername", "server_name"]) { result["sni"] = sni }
        if let security = value(["security"]) {
            result["security"] = security.lowercased()
        } else if let tls = value(["tls"]) {
            let enabled = ["1", "true", "tls", "yes"].contains(tls.lowercased())
            result["security"] = enabled ? "tls" : "none"
        }

        if result["type"] == "xhttp", let raw = value(["obfsParam", "obfs_param"]) {
            mapXHTTPParameters(raw, into: &result)
        }
        return result
    }

    private static func mapXHTTPParameters(_ raw: String, into params: inout [String: String]) {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return }

        func stringValue(_ value: Any) -> String? {
            if let string = value as? String { return string }
            if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
                return number.stringValue
            }
            return nil
        }

        func visit(_ value: Any) {
            guard let dictionary = value as? [String: Any] else { return }
            for (key, child) in dictionary {
                let compact = key.lowercased().filter { $0.isLetter || $0.isNumber }
                let target: String?
                switch compact {
                case "xpaddingbytes": target = "x_padding_bytes"
                case "xpaddingobfsmode": target = "x_padding_obfs_mode"
                case "xpaddingkey": target = "x_padding_key"
                case "xpaddingheader": target = "x_padding_header"
                case "xpaddingmethod": target = "x_padding_method"
                case "xpaddingplacement": target = "x_padding_placement"
                default: target = nil
                }
                if let target, let text = stringValue(child) {
                    params[target] = text
                } else if child is [String: Any] {
                    visit(child)
                }
            }
        }
        visit(object)
    }

    static func serverLooksDialable(_ host: String) -> Bool {
        if host.isEmpty || host.count > 253 || host.contains(" ") { return false }
        let labels = host.split(separator: ".")
        if labels.count == 4, labels.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) {
            return true
        }
        if host.contains(":") { return true }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return host.unicodeScalars.allSatisfy { allowed.contains($0) } && host.contains(".")
    }

    static func serverLooksLikeBlob(_ host: String) -> Bool {
        if serverLooksDialable(host) || host.count < 16 { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_+/= ")
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Re-read a saved node whose server is still the base64 share blob.
    static func normalized(_ node: ProxyNode) -> ProxyNode {
        let parsed: ProxyNode?
        if !node.raw.isEmpty {
            parsed = parse(node.raw)
        } else if serverLooksLikeBlob(node.server) {
            parsed = parse("\(node.proto)://\(node.server)")
        } else {
            parsed = nil
        }
        guard let parsed, serverLooksDialable(parsed.server) else { return node }
        var mergedParams = node.params
        for (key, value) in parsed.params where !value.isEmpty { mergedParams[key] = value }
        let preserveName = !serverLooksLikeBlob(node.name) && node.name != node.server
        let desiredName = preserveName ? node.name : parsed.name
        guard parsed.server != node.server || parsed.secret != node.secret || parsed.port != node.port
                || desiredName != node.name || mergedParams != node.params else { return node }
        var fixed = parsed
        fixed.id = node.id
        if !node.raw.isEmpty { fixed.raw = node.raw }
        fixed.name = desiredName
        fixed.params = mergedParams
        if fixed.secret.isEmpty { fixed.secret = node.secret }
        return fixed
    }

    private static func vmess(_ s: String) -> ProxyNode? {
        let body = String(s.dropFirst("vmess://".count))
        guard let data = b64(body),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func str(_ k: String) -> String {
            if let s = obj[k] as? String { return s }
            if let n = obj[k] as? NSNumber { return n.stringValue }
            return ""
        }
        let host = str("add")
        let port = Int(str("port")) ?? 443
        var p: [String: String] = [
            "aid": str("aid").isEmpty ? "0" : str("aid"),
            "scy": str("scy").isEmpty ? "auto" : str("scy"),
            "net": str("net").isEmpty ? "tcp" : str("net"),
            "type": str("type"),
            "host": str("host"),
            "path": str("path"),
            "tls": str("tls"),
            "sni": str("sni"),
            "fp": str("fp"),
            "alpn": str("alpn"),
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
