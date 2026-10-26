import Foundation
import Compression

// MARK: - 节点模型

enum ProxySelectionMode: String, Codable, CaseIterable, Identifiable {
    case manual
    case automatic

    var id: String { rawValue }
    var title: String { self == .manual ? "手动选择" : "自动选择" }
    var outboundTag: String { self == .manual ? "manual" : "auto" }
}

enum ProxyRoutingRuleKind: String, Codable, CaseIterable, Identifiable {
    case domainSuffix
    case ipCIDR

    var id: String { rawValue }
    var title: String { self == .domainSuffix ? "域名后缀" : "IP / CIDR" }
    var placeholder: String { self == .domainSuffix ? "example.com" : "192.0.2.0/24" }
}

enum ProxyRoutingTarget: String, Codable, CaseIterable, Identifiable {
    case proxy
    case direct

    var id: String { rawValue }
    var title: String { self == .proxy ? "走代理" : "直连" }
}

struct ProxyRoutingRule: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var kind: ProxyRoutingRuleKind
    var value: String
    var target: ProxyRoutingTarget
}

struct ProxySubscription: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var url: String
    var updatedAt = Date()
}

struct ProxyNode: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var proto: String            // vless / vmess / trojan / ss / hysteria2
    var server: String
    var port: Int
    var secret: String           // uuid / password
    var params: [String: String] = [:]
    var raw: String = ""         // 原始分享链接（导入时保留）
    var subscriptionID: UUID? = nil

    var detail: String { "\(proto.uppercased()) · \(server):\(port)" }

    func p(_ k: String) -> String? {
        guard let v = params[k], !v.isEmpty else { return nil }
        return v
    }
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
        if let i = body.firstIndex(of: "?") { body = String(body[..<i]) }
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
        return ProxyNode(name: name.isEmpty ? host : name, proto: "ss", server: host, port: port,
                         secret: pass, params: ["method": method], raw: s)
    }

    /// 导入节点保留原始链接；编辑过的节点由当前配置重新生成分享链接。
    static func shareLink(_ n: ProxyNode) -> String {
        if !n.raw.isEmpty { return n.raw }
        switch n.proto.lowercased() {
        case "vless", "trojan", "hysteria2", "hy2":
            var items = n.params.keys.sorted().compactMap { key -> URLQueryItem? in
                guard let value = n.p(key) else { return nil }
                return URLQueryItem(name: key, value: value)
            }
            if n.proto.lowercased() == "vless", !items.contains(where: { $0.name == "encryption" }) {
                items.append(URLQueryItem(name: "encryption", value: "none"))
            }
            var c = URLComponents()
            c.scheme = n.proto.lowercased() == "hy2" ? "hysteria2" : n.proto.lowercased()
            c.user = n.secret
            c.host = n.server
            c.port = n.port
            c.queryItems = items.isEmpty ? nil : items
            c.fragment = n.name
            return c.string ?? ""
        case "vmess":
            var object: [String: String] = [
                "v": "2", "ps": n.name, "add": n.server, "port": String(n.port),
                "id": n.secret, "aid": n.p("aid") ?? "0",
                "net": n.p("type") ?? n.p("net") ?? "tcp",
                "host": n.p("host") ?? "", "path": n.p("path") ?? "",
                "tls": n.p("security") == "tls" ? "tls" : "",
                "sni": n.p("sni") ?? "", "alpn": n.p("alpn") ?? "",
                "fp": n.p("fp") ?? "", "scy": n.p("scy") ?? "auto"
            ]
            if let type = n.p("type") { object["type"] = type }
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
            return "vmess://" + data.base64EncodedString()
        case "ss", "shadowsocks":
            var c = URLComponents()
            c.scheme = "ss"
            c.user = n.p("method") ?? "aes-128-gcm"
            c.password = n.secret
            c.host = n.server
            c.port = n.port
            c.fragment = n.name
            return c.string ?? ""
        default:
            return ""
        }
    }
}

// MARK: - sing-box 配置（对应 sing-box 1.11 的配置格式）

enum SingBoxConfig {
    static let controlPort = 49173
    static let maxProviderConfigSourceBytes = 16 * 1024 * 1024

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

    static func nodeTag(_ node: ProxyNode) -> String {
        "node-" + node.id.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    static func build(nodes: [ProxyNode], selectedID: UUID?, selectionMode: ProxySelectionMode,
                      bypassCN: Bool, routingRules: [ProxyRoutingRule]) -> String {
        let activeNodes = nodes
        let nodeTags = activeNodes.map(nodeTag)
        let selectedTag = activeNodes.first(where: { $0.id == selectedID }).map(nodeTag) ?? nodeTags.first ?? ""
        var routeRules: [[String: Any]] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
            ["ip_is_private": true, "outbound": "direct"]
        ]
        var dnsRules: [[String: Any]] = [["outbound": "any", "server": "dns-local"]]

        for rule in routingRules where !rule.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let target = rule.target == .direct ? "direct" : "proxy"
            switch rule.kind {
            case .domainSuffix:
                routeRules.append(["domain_suffix": [rule.value], "outbound": target])
            case .ipCIDR:
                routeRules.append(["ip_cidr": [rule.value], "outbound": target])
            }
        }
        if bypassCN {
            routeRules.append(["domain_suffix": cnSuffixes, "outbound": "direct"])
            dnsRules.append(["domain_suffix": cnSuffixes, "server": "dns-local"])
        }
        let dnsServers: [[String: Any]] = [
            ["tag": "dns-remote", "address": "tls://8.8.8.8", "detour": "proxy"],
            ["tag": "dns-local", "address": "223.5.5.5", "detour": "direct"]
        ]
        let dns: [String: Any] = ["servers": dnsServers, "rules": dnsRules, "final": "dns-remote", "strategy": "ipv4_only"]
        let tun: [String: Any] = ["type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "mtu": 9000,
                                  "auto_route": true, "strict_route": false, "stack": "gvisor"]
        let direct: [String: Any] = ["type": "direct", "tag": "direct"]
        let manual: [String: Any] = ["type": "selector", "tag": "manual", "outbounds": nodeTags,
                                     "default": selectedTag, "interrupt_exist_connections": true]
        let automatic: [String: Any] = ["type": "urltest", "tag": "auto", "outbounds": nodeTags,
                                        "url": "https://www.gstatic.com/generate_204", "interval": "10m",
                                        "tolerance": 50, "interrupt_exist_connections": true]
        let proxy: [String: Any] = ["type": "selector", "tag": "proxy", "outbounds": ["manual", "auto"],
                                    "default": selectionMode.outboundTag, "interrupt_exist_connections": true]
        let route: [String: Any] = ["rules": routeRules, "final": "proxy", "auto_detect_interface": true]
        let log: [String: Any] = ["level": "warn", "timestamp": true]
        let experimental: [String: Any] = ["clash_api": ["external_controller": "127.0.0.1:\(controlPort)"]]
        let cfg: [String: Any] = [
            "log": log, "dns": dns, "inbounds": [tun], "experimental": experimental,
            "outbounds": activeNodes.enumerated().map { outbound($0.element, tag: nodeTags[$0.offset]) }
                + [manual, automatic, proxy, direct],
            "route": route
        ]
        let data = (try? JSONSerialization.data(withJSONObject: cfg, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Provider configuration is stored in iOS preferences, which have a 512 KiB limit.
    /// Keep the full node list while storing a compact, length-prefixed zlib payload there.
    static func compressedProviderConfig(_ config: String) -> Data? {
        let source = Data(config.utf8)
        guard !source.isEmpty, source.count <= maxProviderConfigSourceBytes else { return nil }

        var compressed = Data(count: source.count + source.count / 100 + 1024)
        let scratchSize = compression_encode_scratch_buffer_size(COMPRESSION_ZLIB)
        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: max(1, scratchSize), alignment: MemoryLayout<UInt8>.alignment
        )
        defer { scratch.deallocate() }

        let compressedSize = source.withUnsafeBytes { sourceBuffer -> Int in
            guard let sourceBytes = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compressed.withUnsafeMutableBytes { destinationBuffer -> Int in
                guard let destinationBytes = destinationBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(
                    destinationBytes, destinationBuffer.count,
                    sourceBytes, sourceBuffer.count, scratch, COMPRESSION_ZLIB
                )
            }
        }
        guard compressedSize > 0 else { return nil }

        var payload = Data()
        var uncompressedSize = UInt64(source.count).bigEndian
        withUnsafeBytes(of: &uncompressedSize) { payload.append(contentsOf: $0) }
        payload.append(compressed.prefix(compressedSize))
        return payload
    }
}

// MARK: - 节点存储

@MainActor
final class ProxyStore: ObservableObject {
    static let shared = ProxyStore()

    @Published var nodes: [ProxyNode] = [] { didSet { save() } }
    @Published var subscriptions: [ProxySubscription] = [] { didSet { saveSubscriptions() } }
    @Published var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "vpn_selected") }
    }
    @Published var selectionMode: ProxySelectionMode = .manual {
        didSet { UserDefaults.standard.set(selectionMode.rawValue, forKey: "vpn_selection_mode") }
    }
    @Published var bypassCN: Bool = true {
        didSet { UserDefaults.standard.set(bypassCN, forKey: "vpn_bypass") }
    }
    @Published var routingRules: [ProxyRoutingRule] = [] { didSet { saveRules() } }

    private static let key = "vpn.nodes"
    private static let subscriptionsKey = "vpn.subscriptions"
    private static let rulesKey = "vpn.routing_rules"

    init() {
        if let d = Keychain.get(Self.key), let arr = try? JSONDecoder().decode([ProxyNode].self, from: d) {
            nodes = arr
        }
        if let d = Keychain.get(Self.subscriptionsKey),
           let arr = try? JSONDecoder().decode([ProxySubscription].self, from: d) {
            subscriptions = arr
        }
        if let d = Keychain.get(Self.rulesKey),
           let arr = try? JSONDecoder().decode([ProxyRoutingRule].self, from: d) {
            routingRules = arr
        }
        if let s = UserDefaults.standard.string(forKey: "vpn_selected") { selectedID = UUID(uuidString: s) }
        if let mode = UserDefaults.standard.string(forKey: "vpn_selection_mode"),
           let decoded = ProxySelectionMode(rawValue: mode) { selectionMode = decoded }
        bypassCN = UserDefaults.standard.object(forKey: "vpn_bypass") as? Bool ?? true
    }

    var selected: ProxyNode? { nodes.first { $0.id == selectedID } ?? nodes.first }

    private func save() {
        if let d = try? JSONEncoder().encode(nodes) { Keychain.set(d, key: Self.key) }
    }

    private func saveSubscriptions() {
        if let d = try? JSONEncoder().encode(subscriptions) { Keychain.set(d, key: Self.subscriptionsKey) }
    }

    private func saveRules() {
        if let d = try? JSONEncoder().encode(routingRules) { Keychain.set(d, key: Self.rulesKey) }
    }

    func add(_ node: ProxyNode, select: Bool = false) {
        nodes.append(node)
        if select || selectedID == nil { selectedID = node.id }
    }

    func add(_ list: [ProxyNode]) {
        for n in list { add(n) }
    }

    func update(_ node: ProxyNode) {
        guard let index = nodes.firstIndex(where: { $0.id == node.id }) else { return }
        nodes[index] = node
    }

    @discardableResult
    func importSubscription(url: String, nodes importedNodes: [ProxyNode]) -> ProxySubscription {
        let normalizedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = subscriptions.first { $0.url == normalizedURL }
        let subscription = existing ?? ProxySubscription(
            name: URLComponents(string: normalizedURL)?.host ?? "代理订阅",
            url: normalizedURL
        )
        let removedIDs = Set(nodes.filter { $0.subscriptionID == subscription.id }.map(\.id))
        nodes.removeAll { $0.subscriptionID == subscription.id }
        var replacement = subscription
        replacement.updatedAt = Date()
        if existing == nil {
            subscriptions.append(replacement)
        } else if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
            subscriptions[index] = replacement
        }
        let associatedNodes = importedNodes.map { node -> ProxyNode in
            var node = node
            node.subscriptionID = subscription.id
            return node
        }
        nodes.append(contentsOf: associatedNodes)
        if selectedID == nil || selectedID.map({ removedIDs.contains($0) }) == true {
            selectedID = associatedNodes.first?.id ?? nodes.first?.id
        }
        return replacement
    }

    func deleteSubscription(_ id: UUID, removeNodes: Bool) {
        subscriptions.removeAll { $0.id == id }
        if removeNodes {
            remove(ids: Set(nodes.filter { $0.subscriptionID == id }.map(\.id)))
        } else {
            for index in nodes.indices where nodes[index].subscriptionID == id {
                nodes[index].subscriptionID = nil
            }
        }
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        nodes.removeAll { ids.contains($0.id) }
        if let selectedID, ids.contains(selectedID) { self.selectedID = nodes.first?.id }
    }

    func removeAllNodes() {
        remove(ids: Set(nodes.map(\.id)))
    }

    func remove(at offsets: IndexSet) {
        remove(ids: Set(offsets.map { nodes[$0].id }))
    }
}

// MARK: - 部署到 Cloudflare Worker 的 VLESS-WS 节点

enum NodeWorker {
    static func script(uuid: String) -> String {
        js.replacingOccurrences(of: "__UUID__", with: uuid)
    }

    static func node(name: String, host: String, address: String, uuid: String) -> ProxyNode {
        ProxyNode(name: name, proto: "vless", server: address, port: 443, secret: uuid,
                  params: ["type": "ws", "security": "tls", "sni": host, "host": host,
                           "path": "/", "fp": "chrome"])
    }

    private static let js = #"""
    import { connect } from 'cloudflare:sockets';

    const UUID = '__UUID__';

    function uuidBytes(u) {
      const h = u.replace(/-/g, '');
      const a = new Uint8Array(16);
      for (let i = 0; i < 16; i++) a[i] = parseInt(h.substr(i * 2, 2), 16);
      return a;
    }
    const ID = uuidBytes(UUID);

    function parseHeader(buf) {
      if (buf.length < 24) return null;
      for (let i = 0; i < 16; i++) if (buf[1 + i] !== ID[i]) return null;
      let p = 18 + buf[17];
      const cmd = buf[p++];
      if (cmd !== 1) return null;
      const port = (buf[p] << 8) | buf[p + 1];
      p += 2;
      const atype = buf[p++];
      let host;
      if (atype === 1) {
        host = buf.slice(p, p + 4).join('.');
        p += 4;
      } else if (atype === 2) {
        const l = buf[p++];
        host = new TextDecoder().decode(buf.slice(p, p + l));
        p += l;
      } else if (atype === 3) {
        const parts = [];
        for (let i = 0; i < 8; i++) parts.push(((buf[p + i * 2] << 8) | buf[p + i * 2 + 1]).toString(16));
        host = parts.join(':');
        p += 16;
      } else {
        return null;
      }
      return { version: buf[0], host, port, offset: p };
    }

    function handleSession(ws) {
      let writer = null;
      let started = false;
      let queue = Promise.resolve();
      const closeAll = () => { try { ws.close(); } catch (e) {} };

      ws.addEventListener('message', (ev) => {
        queue = queue.then(async () => {
          const data = new Uint8Array(ev.data);
          if (started) {
            await writer.write(data);
            return;
          }
          const h = parseHeader(data);
          if (!h) { ws.close(1008, 'bad request'); return; }
          started = true;
          const sock = connect({ hostname: h.host, port: h.port });
          writer = sock.writable.getWriter();
          await writer.write(data.slice(h.offset));
          let first = true;
          sock.readable.pipeTo(new WritableStream({
            write(chunk) {
              if (first) {
                first = false;
                const out = new Uint8Array(2 + chunk.length);
                out[0] = h.version;
                out.set(chunk, 2);
                ws.send(out);
              } else {
                ws.send(chunk);
              }
            },
            close() { closeAll(); },
            abort() { closeAll(); },
          })).catch(closeAll);
        }).catch(closeAll);
      });

      const stop = () => { try { if (writer) writer.close(); } catch (e) {} };
      ws.addEventListener('close', stop);
      ws.addEventListener('error', stop);
    }

    export default {
      async fetch(request) {
        if (request.headers.get('Upgrade') !== 'websocket') {
          return new Response('Hello World!', { status: 200 });
        }
        const pair = new WebSocketPair();
        const [client, server] = Object.values(pair);
        server.accept();
        handleSession(server);
        return new Response(null, { status: 101, webSocket: client });
      },
    };
    """#
}
