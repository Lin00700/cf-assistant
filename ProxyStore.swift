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
    @Published var results: [UUID: ProxyProbeResult] = [:]
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
                results[fixed.id] = nil
                next[index] = fixed
                changed = true
            }
        }
        if changed { nodes = next }
    }

    func update(_ node: ProxyNode) {
        if let i = nodes.firstIndex(where: { $0.id == node.id }) { nodes[i] = node }
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
        for id in ids { results[id] = nil }
        if hitActive { selectedID = nodes.first?.id }
        return hitActive
    }

    func removeAll() {
        nodes = []
        selectedID = nil
        results = [:]
    }

    /// 未连接 VPN 时显示 TCP 建连延迟；已连接时显示经每个节点的代理 HTTPS 延迟。
    func refreshLatency(vpnConnected: Bool) async {
        if isRefreshing || nodes.isEmpty { return }
        isRefreshing = true
        refreshError = nil
        defer { isRefreshing = false }
        if vpnConnected {
            let usable = nodes.filter(SingBoxConfig.isSupported)
            do {
                let measured = try await ProxyLatencyTester.measureViaSingBox(
                    nodes: usable,
                    controlURL: SingBoxConfig.controlURL
                )
                var next = measured
                for node in nodes where next[node.id] == nil {
                    next[node.id] = .probeFailed
                }
                results = next
            } catch {
                refreshError = error.localizedDescription
                results = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, .probeFailed) })
            }
        } else {
            results = await ProxyLatencyTester.measureDirectTCP(nodes: nodes)
        }
    }

    /// 可选的代理 HTTPS 探测。不写入 `results`，因此不会盖掉 TCP 毫秒。
    func refreshProxyLatency() async -> String? {
        let usable = nodes.filter(SingBoxConfig.isSupported)
        do {
            let probed = try await ProxyLatencyTester.measureViaSingBox(nodes: usable, controlURL: SingBoxConfig.controlURL)
            let ok = probed.values.filter(\.isReachable).count
            return "代理探测 \(ok)/\(probed.count)"
        } catch {
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
