import Foundation

// MARK: - 节点模型

struct ProxyNode: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var proto: String            // vless / vmess / trojan / ss / hysteria2 / tuic / wireguard / shadowtls / ssh / anytls
    var server: String
    var port: Int
    var secret: String           // uuid / password / wireguard private key
    var params: [String: String] = [:]
    var raw: String = ""         // 原始分享链接（导入时保留）
    /// 链式代理：先走这个节点，再由本节点落地。nil 表示直连本节点。
    var detourID: UUID? = nil
    /// 从 sing-box JSON 原始导入时保留的出站模板，生成配置时原样复用（只改 tag / detour）。
    var jsonTemplate: String? = nil

    var detail: String {
        var s = "\(ProxyProtocol.title(proto)) · \(server):\(port)"
        if ProxyProtocol.canonical(proto) == "ss", let m = p("method") { s += " · \(m)" }
        return s
    }

    var hasJSONTemplate: Bool {
        guard let jsonTemplate else { return false }
        return !jsonTemplate.isEmpty
    }

    func p(_ k: String) -> String? {
        guard let v = params[k], !v.isEmpty else { return nil }
        return v
    }
}

// MARK: - 协议

enum ProxyProtocol {
    static let order = ["vless", "vmess", "trojan", "ss", "hysteria2",
                        "tuic", "wireguard", "shadowtls", "ssh", "anytls"]

    static func canonical(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ss", "shadowsocks": return "ss"
        case "hy2", "hysteria2": return "hysteria2"
        case "wg", "wireguard": return "wireguard"
        case "shadow-tls", "shadowtls", "shadow_tls": return "shadowtls"
        case "anytls": return "anytls"
        case "tuic": return "tuic"
        case "ssh": return "ssh"
        case "vless": return "vless"
        case "vmess": return "vmess"
        case "trojan": return "trojan"
        default: return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    static func title(_ raw: String) -> String {
        switch canonical(raw) {
        case "ss": return "Shadowsocks"
        case "vless": return "VLESS"
        case "vmess": return "VMess"
        case "trojan": return "Trojan"
        case "hysteria2": return "Hysteria2"
        case "tuic": return "TUIC"
        case "wireguard": return "WireGuard"
        case "shadowtls": return "ShadowTLS"
        case "ssh": return "SSH"
        case "anytls": return "AnyTLS"
        default: return raw.uppercased()
        }
    }

    /// 协议在分享链接里的默认端口，解析不带端口的链接时用。
    static func defaultTLS(_ canonical: String) -> Bool {
        switch canonical {
        case "trojan", "hysteria2", "tuic", "anytls", "shadowtls": return true
        default: return false
        }
    }
}

// MARK: - 节点选择与分流规则

enum ProxySelectionMode: String, Codable, CaseIterable {
    case manual
    case automatic

    var title: String {
        switch self {
        case .manual: return "手动选择"
        case .automatic: return "自动优选（测速 + 故障切换）"
        }
    }
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

    private static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func stringList(_ value: Any?) -> [String] {
        if let list = value as? [String] { return list }
        if let list = value as? [Any] { return list.compactMap { $0 as? String } }
        if let one = value as? String { return [one] }
        return []
    }

    static func parse(_ text: String) -> ProxyNode? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let l = s.lowercased()
        if l.hasPrefix("vmess://") { return vmess(s) }
        if l.hasPrefix("ss://") { return shadowsocks(s) }
        if l.hasPrefix("vless://") { return generic(s, proto: "vless") }
        if l.hasPrefix("trojan://") { return generic(s, proto: "trojan") }
        if l.hasPrefix("hysteria2://") || l.hasPrefix("hy2://") { return generic(s, proto: "hysteria2") }
        if l.hasPrefix("tuic://") { return tuic(s) }
        if l.hasPrefix("anytls://") { return generic(s, proto: "anytls") }
        if l.hasPrefix("shadowtls://") || l.hasPrefix("shadow-tls://") { return generic(s, proto: "shadowtls") }
        if l.hasPrefix("ssh://") { return ssh(s) }
        if l.hasPrefix("wireguard://") || l.hasPrefix("wg://") { return wireguardLink(s) }
        if s.contains("[Interface]") && s.contains("[Peer]") { return wireGuardConf(s) }
        if s.hasPrefix("{") || s.hasPrefix("[") { return parseSingBoxJSON(s)?.first }
        return nil
    }

    /// 订阅内容：Base64、逐行分享链接、sing-box JSON 或 WireGuard 配置
    static func parseMany(_ text: String) -> [ProxyNode] {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = b64(t), let decoded = String(data: d, encoding: .utf8) {
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("://") || trimmed.contains("[Interface]") || trimmed.hasPrefix("{") {
                t = trimmed
            }
        }
        if t.hasPrefix("{") || t.hasPrefix("[") {
            if let nodes = parseSingBoxJSON(t), !nodes.isEmpty { return nodes }
        }
        if t.contains("[Interface]") && t.contains("[Peer]") {
            if let node = wireGuardConf(t) { return [node] }
        }
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
        let port = url.port ?? 443
        let secret = credential(url.user ?? "", proto: proto)
        var params: [String: String] = [:]
        if let items = URLComponents(string: s)?.queryItems {
            for i in items { if let v = i.value { params[i.name] = v } }
        }
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
        if !body.contains("@"), let data = b64(body),
           let text = String(data: data, encoding: .utf8), text.contains("@") {
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
        let params = queryParams(query)
        let name = fragment.isEmpty ? host : fragment
        return ProxyNode(name: name, proto: proto, server: host, port: port,
                         secret: credential(user, proto: proto), params: params, raw: s)
    }

    /// `auto:uuid` / `:uuid` on a VLESS link is still just the UUID. Passwords stay intact.
    private static func credential(_ user: String, proto: String) -> String {
        let decoded = user.removingPercentEncoding ?? user
        let canon = ProxyProtocol.canonical(proto)
        guard canon == "vless" || canon == "vmess" else { return decoded }
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
        guard let parsed, serverLooksDialable(parsed.server),
              parsed.server != node.server || parsed.secret != node.secret || parsed.port != node.port else {
            return node
        }
        var fixed = parsed
        fixed.id = node.id
        if !node.raw.isEmpty { fixed.raw = node.raw }
        if !serverLooksLikeBlob(node.name), node.name != node.server {
            fixed.name = node.name
        }
        var params = node.params
        for (key, value) in parsed.params where !value.isEmpty { params[key] = value }
        fixed.params = params
        if fixed.secret.isEmpty { fixed.secret = node.secret }
        fixed.detourID = node.detourID
        fixed.jsonTemplate = node.jsonTemplate
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

    /// `tuic://uuid:password@host:port?congestion_control=bbr&...#name`
    private static func tuic(_ s: String) -> ProxyNode? {
        guard var node = generic(s, proto: "tuic") else { return nil }
        let parts = node.secret.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2 {
            node.secret = parts[0]
            if node.params["password"] == nil { node.params["password"] = parts[1] }
        }
        if node.params["sni"] == nil, let h = node.p("host") { node.params["sni"] = h }
        node.params["security"] = "tls"
        return node
    }

    /// `ssh://user:password@host:port#name`，也支持 `?private_key=` / `?host_key=`
    private static func ssh(_ s: String) -> ProxyNode? {
        guard var node = generic(s, proto: "ssh") else { return nil }
        let parts = node.secret.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2 {
            node.params["user"] = parts[0]
            node.secret = parts[1]
        } else if parts.count == 1, !parts[0].isEmpty, node.params["user"] == nil {
            // 只有 user 时，密码或私钥在 query 里
            node.params["user"] = parts[0]
            node.secret = node.params["password"] ?? ""
        }
        return node
    }

    /// `wireguard://<private_key>@host:port?publickey=...&address=10.0.0.2/32&reserved=1,2,3#name`
    private static func wireguardLink(_ s: String) -> ProxyNode? {
        var body = s
        if let range = body.range(of: "://") { body = String(body[range.upperBound...]) }
        var name = ""
        if let i = body.firstIndex(of: "#") {
            name = String(body[body.index(after: i)...]).removingPercentEncoding ?? ""
            body = String(body[..<i])
        }
        var query = ""
        if let i = body.firstIndex(of: "?") {
            query = String(body[body.index(after: i)...])
            body = String(body[..<i])
        }
        var userinfo = ""
        var hostport = body
        if let at = body.lastIndex(of: "@") {
            userinfo = String(body[..<at])
            hostport = String(body[body.index(after: at)...])
        }
        userinfo = userinfo.removingPercentEncoding ?? userinfo
        guard let colon = hostport.lastIndex(of: ":"),
              let port = Int(hostport[hostport.index(after: colon)...].filter(\.isNumber)),
              (1...65535).contains(port) else { return nil }
        let host = String(hostport[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard serverLooksDialable(host), !userinfo.isEmpty else { return nil }
        var params = queryParams(query)
        if params["peer_public_key"] == nil, let pk = params["publickey"] { params["peer_public_key"] = pk }
        if params["local_address"] == nil, let address = params["address"] { params["local_address"] = address }
        if params["local_address"] == nil, let ip = params["ip"] { params["local_address"] = ip }
        return ProxyNode(name: name.isEmpty ? host : name, proto: "wireguard", server: host,
                         port: port, secret: userinfo, params: params, raw: s)
    }

    /// WireGuard `.conf`（[Interface] / [Peer]）转成节点
    private static func wireGuardConf(_ text: String) -> ProxyNode? {
        var section = ""
        var fields: [String: String] = [:]
        var peer: [String: String] = [:]
        var commentName = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") || line.hasPrefix(";") {
                let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if commentName.isEmpty, let eq = body.firstIndex(of: "=") {
                    let key = String(body[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
                    if key == "name" {
                        commentName = String(body[body.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    }
                }
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = line.dropFirst().dropLast().lowercased()
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if section == "interface" {
                fields[key] = value
            } else if section == "peer" && peer[key] == nil {
                peer[key] = value
            }
        }
        guard let privateKey = fields["privatekey"], !privateKey.isEmpty,
              let endpoint = peer["endpoint"] else { return nil }
        var host = endpoint
        var port = 51820
        if let colon = endpoint.lastIndex(of: ":") {
            host = String(endpoint[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            port = Int(endpoint[endpoint.index(after: colon)...]) ?? 51820
        }
        guard serverLooksDialable(host) else { return nil }
        var params: [String: String] = [:]
        if let pub = peer["publickey"] { params["peer_public_key"] = pub }
        if let psk = peer["presharedkey"] { params["pre_shared_key"] = psk }
        if let address = fields["address"] {
            let first = address.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? address
            params["local_address"] = first
        }
        if let mtu = fields["mtu"] { params["mtu"] = mtu }
        if let allowed = peer["allowedips"] { params["allowed_ips"] = allowed }
        if let keepalive = peer["persistentkeepalive"] { params["persistent_keepalive_interval"] = keepalive }
        if let reserved = peer["reserved"] { params["reserved"] = reserved }
        let name = commentName.isEmpty ? host : commentName
        return ProxyNode(name: name, proto: "wireguard", server: host, port: port,
                         secret: privateKey, params: params, raw: text)
    }

    // MARK: - sing-box JSON 导入

    /// 解析 sing-box 配置（outbounds / endpoints）或单个出站 JSON。
    /// 每个出站保留原始 JSON 作为模板，生成配置时原样复用，未识别的字段不会丢。
    static func parseSingBoxJSON(_ text: String) -> [ProxyNode]? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        var items: [[String: Any]] = []
        var asEndpoint: [Bool] = []
        if let array = root as? [[String: Any]] {
            items = array
            asEndpoint = Array(repeating: false, count: items.count)
        } else if let obj = root as? [String: Any] {
            if let outbounds = obj["outbounds"] as? [[String: Any]] {
                items.append(contentsOf: outbounds)
                asEndpoint.append(contentsOf: Array(repeating: false, count: outbounds.count))
            }
            if let endpoints = obj["endpoints"] as? [[String: Any]] {
                items.append(contentsOf: endpoints)
                asEndpoint.append(contentsOf: Array(repeating: true, count: endpoints.count))
            }
            if items.isEmpty, obj["type"] != nil {
                items = [obj]
                asEndpoint = [false]
            }
        }

        var nodes: [ProxyNode] = []
        var tagMap: [String: UUID] = [:]
        var pendingDetours: [(UUID, String)] = []
        for (index, item) in items.enumerated() {
            let endpoint = index < asEndpoint.count ? asEndpoint[index] : false
            guard let node = nodeFromSingBoxOutbound(item, endpoint: endpoint) else { continue }
            nodes.append(node)
            let tag = (item["tag"] as? String) ?? ""
            if !tag.isEmpty { tagMap[tag] = node.id }
            if let detour = item["detour"] as? String, !detour.isEmpty {
                pendingDetours.append((node.id, detour))
            }
        }
        guard !nodes.isEmpty else { return nil }
        if !pendingDetours.isEmpty {
            var fixed = nodes
            for (id, tag) in pendingDetours {
                guard let target = tagMap[tag], target != id else { continue }
                if let i = fixed.firstIndex(where: { $0.id == id }) { fixed[i].detourID = target }
            }
            nodes = fixed
        }
        return nodes
    }

    private static func nodeFromSingBoxOutbound(_ obj: [String: Any], endpoint: Bool) -> ProxyNode? {
        guard let rawType = (obj["type"] as? String)?.lowercased() else { return nil }
        let skipped: Set<String> = ["direct", "block", "dns", "selector", "urltest", "tor", "http", "socks"]
        if skipped.contains(rawType) { return nil }
        let proto = ProxyProtocol.canonical(rawType)
        let tag = (obj["tag"] as? String) ?? ""

        var server = (obj["server"] as? String) ?? ""
        var port = intValue(obj["server_port"]) ?? 0
        var secret = ""
        var params: [String: String] = [:]

        switch proto {
        case "ss":
            secret = (obj["password"] as? String) ?? ""
            if let m = obj["method"] as? String { params["method"] = m }
            if let plugin = obj["plugin"] as? String { params["plugin"] = plugin }
            if let opts = obj["plugin_opts"] as? String { params["plugin_opts"] = opts }
        case "vless":
            secret = (obj["uuid"] as? String) ?? ""
            if let flow = obj["flow"] as? String, !flow.isEmpty { params["flow"] = flow }
        case "vmess":
            secret = (obj["uuid"] as? String) ?? ""
            if let scy = obj["security"] as? String { params["scy"] = scy }
            if let aid = intValue(obj["alter_id"]), aid != 0 { params["aid"] = String(aid) }
        case "trojan":
            secret = (obj["password"] as? String) ?? ""
        case "hysteria2":
            secret = (obj["password"] as? String) ?? ""
            if let obfs = obj["obfs"] as? [String: Any] {
                if let t = obfs["type"] as? String { params["obfs"] = t }
                if let pw = obfs["password"] as? String { params["obfs-password"] = pw }
            }
            if let up = intValue(obj["up_mbps"]) { params["up"] = String(up) }
            if let down = intValue(obj["down_mbps"]) { params["down"] = String(down) }
        case "tuic":
            secret = (obj["uuid"] as? String) ?? ""
            if let pw = obj["password"] as? String { params["password"] = pw }
            if let cc = obj["congestion_control"] as? String { params["congestion_control"] = cc }
            if let mode = obj["udp_relay_mode"] as? String { params["udp_relay_mode"] = mode }
        case "ssh":
            secret = (obj["password"] as? String) ?? ""
            if let user = obj["user"] as? String { params["user"] = user }
            if let keys = obj["private_key"] as? [String], let key = keys.first { params["private_key"] = key }
            if let keys = obj["host_key"] as? [String] {
                params["host_key"] = keys.joined(separator: ",")
            }
        case "shadowtls":
            secret = (obj["password"] as? String) ?? ""
            params["version"] = String(intValue(obj["version"]) ?? 3)
        case "anytls":
            secret = (obj["password"] as? String) ?? ""
        case "wireguard":
            if let peers = obj["peers"] as? [[String: Any]], let first = peers.first {
                server = (first["address"] as? String) ?? server
                port = intValue(first["port"]) ?? port
                if let pub = first["public_key"] as? String { params["peer_public_key"] = pub }
                if let psk = first["pre_shared_key"] as? String { params["pre_shared_key"] = psk }
                if let allowed = first["allowed_ips"] as? [String] {
                    params["allowed_ips"] = allowed.joined(separator: ",")
                }
                if let reserved = first["reserved"] as? [Int] {
                    params["reserved"] = reserved.map(String.init).joined(separator: ",")
                }
            }
            secret = (obj["private_key"] as? String) ?? ""
            let local = stringList(obj["address"]) + stringList(obj["local_address"])
            if let firstLocal = local.first { params["local_address"] = firstLocal }
            if let pub = obj["peer_public_key"] as? String { params["peer_public_key"] = pub }
            if let psk = obj["pre_shared_key"] as? String { params["pre_shared_key"] = psk }
            if let mtu = intValue(obj["mtu"]) { params["mtu"] = String(mtu) }
        default:
            return nil
        }

        if let tls = obj["tls"] as? [String: Any] {
            if let named = tls["server_name"] as? String, !named.isEmpty { params["sni"] = named }
            let alpn = stringList(tls["alpn"])
            if !alpn.isEmpty { params["alpn"] = alpn.joined(separator: ",") }
            if (tls["insecure"] as? Bool) == true { params["insecure"] = "1" }
            if let utls = tls["utls"] as? [String: Any], let fp = utls["fingerprint"] as? String {
                params["fp"] = fp
            }
            if let reality = tls["reality"] as? [String: Any] {
                params["security"] = "reality"
                if let key = reality["public_key"] as? String { params["pbk"] = key }
                let shortIDs = stringList(reality["short_id"])
                if let sid = shortIDs.first { params["sid"] = sid }
            } else if params["security"] == nil {
                params["security"] = "tls"
            }
        }
        if let transport = obj["transport"] as? [String: Any], let type = transport["type"] as? String {
            params["type"] = type
            if let path = transport["path"] as? String { params["path"] = path }
            if let host = transport["host"] as? String {
                params["host"] = host
            } else if let headers = transport["headers"] as? [String: Any] {
                if let host = headers["Host"] as? String { params["host"] = host }
                else if let host = headers["host"] as? String { params["host"] = host }
            }
            if let service = transport["service_name"] as? String { params["serviceName"] = service }
        }

        if proto == "wireguard" {
            guard !server.isEmpty, (1...65535).contains(port), !secret.isEmpty else { return nil }
        } else if !server.isEmpty, port == 0 {
            port = 443
        }
        guard !server.isEmpty, (1...65535).contains(port) else { return nil }

        var template: String? = nil
        // endpoint 形式的 WireGuard 与出站字段不同，按字段重建；其余出站原样保留 JSON。
        if !endpoint,
           let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
           let text = String(data: data, encoding: .utf8) {
            template = text
        }

        return ProxyNode(name: tag.isEmpty ? server : tag, proto: proto, server: server, port: port,
                         secret: secret, params: params, raw: "", detourID: nil, jsonTemplate: template)
    }

    /// 导出分享链接（导入的节点用原链接；Worker 生成的 VLESS 节点现场拼）
    static func shareLink(_ n: ProxyNode) -> String {
        if !n.raw.isEmpty { return n.raw }
        guard ProxyProtocol.canonical(n.proto) == "vless" else { return "" }
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
