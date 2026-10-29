import Foundation

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
    @Published var categoryPolicies: [ProxyTrafficCategory: ProxyGroupPolicy] = [:] {
        didSet { saveCategoryPolicies() }
    }
    @Published var alwaysOn: Bool = false {
        didSet { UserDefaults.standard.set(alwaysOn, forKey: "vpn_always_on") }
    }
    @Published var directTCPResults: [UUID: ProxyProbeResult] = [:]
    @Published var proxyHTTPSResults: [UUID: ProxyProbeResult] = [:]
    @Published var isRefreshing = false
    @Published var refreshError: String?

    private static let key = "vpn.nodes"
    private static let rulesKey = "vpn_rules"
    private static let categoryKey = "vpn_category_policies"

    init() {
        if let d = Keychain.get(Self.key), let arr = try? JSONDecoder().decode([ProxyNode].self, from: d) {
            let fixed = arr.map(LinkParser.normalized)
            nodes = fixed
            let changed = zip(arr, fixed).contains { old, new in
                old.server != new.server || old.secret != new.secret || old.port != new.port
                    || old.name != new.name || old.params != new.params
            }
            if changed { save() }
        }
        if let s = UserDefaults.standard.string(forKey: "vpn_selected") { selectedID = UUID(uuidString: s) }
        bypassCN = UserDefaults.standard.object(forKey: "vpn_bypass") as? Bool ?? true
        alwaysOn = UserDefaults.standard.bool(forKey: "vpn_always_on")
        if let raw = UserDefaults.standard.string(forKey: "vpn_mode"), let m = ProxySelectionMode(rawValue: raw) {
            selectionMode = m
        }
        if let d = UserDefaults.standard.data(forKey: Self.rulesKey),
           let arr = try? JSONDecoder().decode([ProxyRoutingRule].self, from: d) {
            routingRules = arr
        }
        if let d = UserDefaults.standard.data(forKey: Self.categoryKey),
           let raw = try? JSONDecoder().decode([String: String].self, from: d) {
            var map: [ProxyTrafficCategory: ProxyGroupPolicy] = [:]
            for (k, v) in raw {
                if let c = ProxyTrafficCategory(rawValue: k), let p = ProxyGroupPolicy(rawValue: v) {
                    map[c] = p
                }
            }
            categoryPolicies = map
        }
    }

    var selected: ProxyNode? { nodes.first { $0.id == selectedID } ?? nodes.first }

    private func save() {
        if let d = try? JSONEncoder().encode(nodes) { Keychain.set(d, key: Self.key) }
    }

    private func saveRules() {
        if let d = try? JSONEncoder().encode(routingRules) { UserDefaults.standard.set(d, forKey: Self.rulesKey) }
    }

    private func saveCategoryPolicies() {
        var raw: [String: String] = [:]
        for (c, p) in categoryPolicies { raw[c.rawValue] = p.rawValue }
        if let d = try? JSONEncoder().encode(raw) { UserDefaults.standard.set(d, forKey: Self.categoryKey) }
    }

    func policy(for category: ProxyTrafficCategory) -> ProxyGroupPolicy {
        categoryPolicies[category] ?? .follow
    }

    func setPolicy(_ policy: ProxyGroupPolicy, for category: ProxyTrafficCategory) {
        var next = categoryPolicies
        if policy == .follow {
            next.removeValue(forKey: category)
        } else {
            next[category] = policy
        }
        categoryPolicies = next
    }

    func add(_ node: ProxyNode, select: Bool = false) {
        nodes.append(node)
        if select || selectedID == nil { selectedID = node.id }
    }

    func add(_ list: [ProxyNode]) {
        for n in list { add(n) }
    }

    /// Rewrite saved nodes whose server is still a base64 share blob. Clears a stale probe when the address changes.
    func normalizeDecodedNodes() {
        var next = nodes
        var changed = false
        for index in next.indices {
            let fixed = LinkParser.normalized(next[index])
            if fixed.server != next[index].server || fixed.secret != next[index].secret || fixed.port != next[index].port {
                directTCPResults[fixed.id] = nil
                proxyHTTPSResults[fixed.id] = nil
                next[index] = fixed
                changed = true
            }
        }
        if changed { nodes = next }
    }

    func update(_ node: ProxyNode) {
        if let i = nodes.firstIndex(where: { $0.id == node.id }) {
            let old = nodes[i]
            if old.server != node.server || old.port != node.port || old.proto != node.proto
                || old.secret != node.secret || old.params != node.params {
                directTCPResults[node.id] = nil
                proxyHTTPSResults[node.id] = nil
            }
            nodes[i] = node
        }
    }

    func remove(_ node: ProxyNode) {
        _ = removeIDs([node.id])
    }

    /// 删掉这批节点并写回持久化。返回值表示当前选中节点被删掉了。
    @discardableResult
    func removeIDs(_ ids: Set<UUID>) -> Bool {
        let hitActive = selectedID.map { ids.contains($0) } ?? false
        guard !ids.isEmpty else { return false }
        nodes.removeAll { ids.contains($0.id) }
        for id in ids {
            directTCPResults[id] = nil
            proxyHTTPSResults[id] = nil
        }
        if hitActive { selectedID = nodes.first?.id }
        return hitActive
    }

    func removeAll() {
        nodes = []
        selectedID = nil
        directTCPResults = [:]
        proxyHTTPSResults = [:]
    }

    /// 分开保存两种测量：未连接 VPN 时测直连 TCP，连接后测 sing-box 代理 HTTPS。
    /// 不在 VPN 已连接时把可能经过隧道的 TCP 测量冒充直连结果，也不覆盖另一组结果。
    func refreshLatency(vpnConnected: Bool) async {
        if isRefreshing || nodes.isEmpty { return }
        isRefreshing = true
        refreshError = nil
        defer { isRefreshing = false }
        guard VPNManager.shared.isConnected == vpnConnected else { return }
        if vpnConnected {
            proxyHTTPSResults = [:]
            let usable = nodes.filter(SingBoxConfig.isSupported)
            let usableIDs = Set(usable.map(\.id))
            do {
                let measured = try await ProxyLatencyTester.measureViaSingBox(
                    nodes: usable,
                    controlURL: SingBoxConfig.controlURL
                )
                guard VPNManager.shared.isConnected else { return }
                var next = measured
                for node in nodes where next[node.id] == nil {
                    next[node.id] = usableIDs.contains(node.id) ? .probeFailed : .unsupported
                }
                proxyHTTPSResults = next
            } catch {
                guard VPNManager.shared.isConnected else { return }
                refreshError = error.localizedDescription
                proxyHTTPSResults = Dictionary(uniqueKeysWithValues: nodes.map {
                    ($0.id, usableIDs.contains($0.id) ? .probeFailed : .unsupported)
                })
            }
        } else {
            directTCPResults = [:]
            let measured = await ProxyLatencyTester.measureDirectTCP(nodes: nodes)
            guard !VPNManager.shared.isConnected else { return }
            var next = measured
            for node in nodes where next[node.id] == nil {
                next[node.id] = .unreachable
            }
            directTCPResults = next
        }
    }

    /// 单独刷新代理 HTTPS 缓存，不会改写直连 TCP 测量。
    func refreshProxyLatency() async -> String? {
        let usable = nodes.filter(SingBoxConfig.isSupported)
        let usableIDs = Set(usable.map(\.id))
        do {
            let values = try await ProxyLatencyTester.measureViaSingBox(nodes: usable, controlURL: SingBoxConfig.controlURL)
            var probed = values
            for node in nodes where probed[node.id] == nil {
                probed[node.id] = usableIDs.contains(node.id) ? .probeFailed : .unsupported
            }
            proxyHTTPSResults = probed
            let ok = probed.values.filter(\.isReachable).count
            return "代理探测 \(ok)/\(probed.count)"
        } catch {
            proxyHTTPSResults = Dictionary(uniqueKeysWithValues: nodes.map {
                ($0.id, usableIDs.contains($0.id) ? .probeFailed : .unsupported)
            })
            return error.localizedDescription
        }
    }
}

enum NodeWorker {
    static func script(uuid: String) -> String {
        """
        import { connect } from 'cloudflare:sockets';
        let userID = '\(uuid)';
        export default {
          async fetch(request) {
            const upgradeHeader = request.headers.get('Upgrade');
            if (!upgradeHeader || upgradeHeader !== 'websocket') {
              return new Response('Expected Upgrade: websocket', { status: 426 });
            }
            const [client, server] = new WebSocketPair();
            server.accept();
            handleSession(server);
            return new Response(null, { status: 101, webSocket: client });
          }
        };
        async function handleSession(ws) {
          // minimal placeholder – full worker script is deployed from app when available
          ws.addEventListener('message', () => {});
        }
        """
    }

    static func node(name: String, host: String, address: String, uuid: String) -> ProxyNode {
        ProxyNode(name: name, proto: "vless", server: address, port: 443, secret: uuid,
                  params: ["type": "ws", "security": "tls", "sni": host, "host": host,
                           "path": "/", "fp": "chrome"])
    }
}
