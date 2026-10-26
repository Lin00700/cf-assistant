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
            let name = plugin.split(separator: ";", maxSplits: 1).map(String.init)
            params["plugin"] = name[0] == "simple-obfs" ? "obfs-local" : name[0]
            params["plugin_opts"] = name.count > 1 ? name[1] : ""
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

// MARK: - sing-box 配置（对应 sing-box 1.11 的配置格式）

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

    static func build(nodes: [ProxyNode], selectedID: UUID?, mode: ProxySelectionMode,
                      bypassCN: Bool, rules: [ProxyRoutingRule]) -> String {
        let usable = nodes.filter(isSupported)
        let tags = usable.map { nodeTag($0) }
        let selectedTag = usable.first(where: { $0.id == selectedID }).map { nodeTag($0) } ?? tags.first ?? "direct"

        let direct: [String: Any] = ["type": "direct", "tag": "direct"]
        var outbounds: [[String: Any]] = usable.map { outbound($0, tag: nodeTag($0)) }
        outbounds.append(direct)
        if tags.isEmpty {
            outbounds.append(["type": "selector", "tag": "proxy", "outbounds": ["direct"]])
        } else {
            let auto: [String: Any] = ["type": "urltest", "tag": "auto", "outbounds": tags,
                                       "url": nodeProbeURL, "interval": "10m", "tolerance": 50]
            let members: [String] = mode == .automatic ? ["auto"] + tags : tags + ["auto"]
            let selector: [String: Any] = ["type": "selector", "tag": "proxy", "outbounds": members,
                                           "default": mode == .automatic ? "auto" : selectedTag]
            outbounds.append(auto)
            outbounds.append(selector)
        }

        var routeRules: [[String: Any]] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
            ["ip_is_private": true, "outbound": "direct"]
        ]
        var dnsRules: [[String: Any]] = [["outbound": "any", "server": "dns-local"]]

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

        let dnsServers: [[String: Any]] = [
            ["tag": "dns-remote", "address": "tls://8.8.8.8", "detour": "proxy"],
            ["tag": "dns-local", "address": "223.5.5.5", "detour": "direct"]
        ]
        let dns: [String: Any] = ["servers": dnsServers, "rules": dnsRules, "final": "dns-remote", "strategy": "ipv4_only"]
        let tun: [String: Any] = ["type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "mtu": 9000,
                                  "auto_route": true, "strict_route": false, "stack": "gvisor"]
        let route: [String: Any] = ["rules": routeRules, "final": "proxy", "auto_detect_interface": true]
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

// MARK: - 节点存储

@MainActor
final class ProxyStore: ObservableObject {
    static let shared = ProxyStore()

    @Published var nodes: [ProxyNode] = [] { didSet { save() } }
    @Published var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "vpn_selected") }
    }
    @Published var bypassCN: Bool = true {
        didSet { UserDefaults.standard.set(bypassCN, forKey: "vpn_bypass") }
    }
    @Published var selectionMode: ProxySelectionMode = .manual {
        didSet { UserDefaults.standard.set(selectionMode.rawValue, forKey: "vpn_mode") }
    }
    @Published var routingRules: [ProxyRoutingRule] = [] { didSet { saveRules() } }
    @Published var results: [UUID: ProxyProbeResult] = [:]
    @Published var isRefreshing = false
    @Published var refreshError: String?

    private static let key = "vpn.nodes"
    private static let rulesKey = "vpn_rules"

    init() {
        if let d = Keychain.get(Self.key), let arr = try? JSONDecoder().decode([ProxyNode].self, from: d) {
            nodes = arr
        }
        if let s = UserDefaults.standard.string(forKey: "vpn_selected") { selectedID = UUID(uuidString: s) }
        bypassCN = UserDefaults.standard.object(forKey: "vpn_bypass") as? Bool ?? true
        if let raw = UserDefaults.standard.string(forKey: "vpn_mode"), let m = ProxySelectionMode(rawValue: raw) {
            selectionMode = m
        }
        if let d = UserDefaults.standard.data(forKey: Self.rulesKey),
           let arr = try? JSONDecoder().decode([ProxyRoutingRule].self, from: d) {
            routingRules = arr
        }
    }

    var selected: ProxyNode? { nodes.first { $0.id == selectedID } ?? nodes.first }

    private func save() {
        if let d = try? JSONEncoder().encode(nodes) { Keychain.set(d, key: Self.key) }
    }

    private func saveRules() {
        if let d = try? JSONEncoder().encode(routingRules) { UserDefaults.standard.set(d, forKey: Self.rulesKey) }
    }

    func add(_ node: ProxyNode, select: Bool = false) {
        nodes.append(node)
        if select || selectedID == nil { selectedID = node.id }
    }

    func add(_ list: [ProxyNode]) {
        for n in list { add(n) }
    }

    func update(_ node: ProxyNode) {
        if let i = nodes.firstIndex(where: { $0.id == node.id }) { nodes[i] = node }
    }

    func remove(_ node: ProxyNode) {
        nodes.removeAll { $0.id == node.id }
        results[node.id] = nil
        if selectedID == node.id { selectedID = nodes.first?.id }
    }

    func removeAll() {
        nodes = []
        selectedID = nil
        results = [:]
    }

    /// VPN 已连接：通过 sing-box 的代理延迟接口测真实延迟；未连接：测 TCP 端口
    func refreshLatency(vpnConnected: Bool) async {
        if isRefreshing || nodes.isEmpty { return }
        isRefreshing = true
        refreshError = nil
        defer { isRefreshing = false }
        if vpnConnected {
            let usable = nodes.filter(SingBoxConfig.isSupported)
            do {
                results = try await ProxyLatencyTester.measureViaSingBox(nodes: usable, controlURL: SingBoxConfig.controlURL)
            } catch {
                refreshError = error.localizedDescription
                var failed: [UUID: ProxyProbeResult] = [:]
                for n in nodes { failed[n.id] = .probeFailed }
                results = failed
            }
        } else {
            results = await ProxyLatencyTester.measureDirectTCP(nodes: nodes)
        }
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
