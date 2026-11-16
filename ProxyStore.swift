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
    /// 自动优选（urltest）组的探测间隔与容差，改完自动重连生效。
    @Published var autoIntervalMinutes: Int = 5 {
        didSet { UserDefaults.standard.set(autoIntervalMinutes, forKey: "vpn_auto_interval") }
    }
    @Published var autoToleranceMilliseconds: Int = 50 {
        didSet { UserDefaults.standard.set(autoToleranceMilliseconds, forKey: "vpn_auto_tolerance") }
    }
    @Published var results: [UUID: ProxyProbeResult] = [:]
    @Published var isRefreshing = false
    @Published var isFindingFastest = false
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
            }
            if changed { save() }
        }
        if let s = UserDefaults.standard.string(forKey: "vpn_selected") { selectedID = UUID(uuidString: s) }
        bypassCN = UserDefaults.standard.object(forKey: "vpn_bypass") as? Bool ?? true
        alwaysOn = UserDefaults.standard.bool(forKey: "vpn_always_on")
        let savedInterval = UserDefaults.standard.integer(forKey: "vpn_auto_interval")
        if savedInterval > 0 { autoIntervalMinutes = savedInterval }
        let savedTolerance = UserDefaults.standard.integer(forKey: "vpn_auto_tolerance")
        if savedTolerance > 0 { autoToleranceMilliseconds = savedTolerance }
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
        // 被删掉的节点如果还当着别人的前置节点，把这些链拆掉，避免配置里出现悬空 detour。
        for index in nodes.indices {
            if let detour = nodes[index].detourID, ids.contains(detour) {
                nodes[index].detourID = nil
            }
        }
        if hitActive { selectedID = nodes.first?.id }
        return hitActive
    }

    func removeAll() {
        nodes = []
        selectedID = nil
        results = [:]
    }

    /// 节点列表始终显示直连 TCP 延迟（与 main 一致）。
    /// `vpnConnected` 保留给旧调用点，但不再改成 sing-box 代理探测，避免几百个节点把隧道打满。
    func refreshLatency(vpnConnected: Bool) async {
        _ = vpnConnected
        if isRefreshing || nodes.isEmpty { return }
        isRefreshing = true
        refreshError = nil
        defer { isRefreshing = false }
        results = await ProxyLatencyTester.measureDirectTCP(nodes: nodes)
    }

    var autoPolicy: SingBoxAutoPolicy {
        SingBoxAutoPolicy(intervalMinutes: autoIntervalMinutes,
                          toleranceMilliseconds: autoToleranceMilliseconds)
    }

    /// 前置节点链（前置 → …），用于界面显示；遇到环或缺失就截断。
    func detourChain(for node: ProxyNode) -> [ProxyNode] {
        SingBoxConfig.detourChain(nodes: nodes, node: node)
    }

    /// 节点标签：`前置 A → 落地 B`
    func chainLabel(for node: ProxyNode) -> String? {
        let chain = detourChain(for: node)
        guard !chain.isEmpty else { return nil }
        let names = chain.reversed().map(\.name) + [node.name]
        return names.joined(separator: " → ")
    }

    /// 能不能把 candidate 当作 node 的前置节点：不能是自己，也不能构成环。
    func canUseAsDetour(_ candidate: UUID, for nodeID: UUID) -> Bool {
        guard candidate != nodeID else { return false }
        var visited: Set<UUID> = [nodeID]
        var current: UUID? = candidate
        var depth = 0
        while let id = current {
            if !visited.insert(id).inserted { return false }
            depth += 1
            if depth > 8 { return false }
            current = nodes.first(where: { $0.id == id })?.detourID
        }
        return true
    }

    /// 一键测速并切到最快节点。VPN 已连接时用 sing-box 的代理延迟，否则用 TCP 建连延迟。
    @discardableResult
    func testAllAndSelectFastest(vpnConnected: Bool) async -> ProxyNode? {
        guard !nodes.isEmpty, !isFindingFastest else { return nil }
        isFindingFastest = true
        defer { isFindingFastest = false }

        if vpnConnected {
            let usable = nodes.filter(SingBoxConfig.isSupported)
            if let probed = try? await ProxyLatencyTester.measureViaSingBox(nodes: usable,
                                                                           controlURL: SingBoxConfig.controlURL),
               !probed.isEmpty {
                for (id, result) in probed { results[id] = result }
                if let best = fastest(in: usable, results: probed) {
                    selectedID = best.id
                    return best
                }
            }
        }
        let direct = await ProxyLatencyTester.measureDirectTCP(nodes: nodes)
        results = direct
        guard let best = fastest(in: nodes, results: direct) else { return nil }
        selectedID = best.id
        return best
    }

    private func fastest(in list: [ProxyNode], results: [UUID: ProxyProbeResult]) -> ProxyNode? {
        var bestNode: ProxyNode?
        var bestMilliseconds = Int.max
        for node in list {
            guard let result = results[node.id] else { continue }
            let milliseconds: Int
            switch result {
            case .latency(let value), .tcpLatency(let value): milliseconds = value
            case .unreachable, .probeFailed, .requiresVPN: continue
            }
            if milliseconds < bestMilliseconds {
                bestMilliseconds = milliseconds
                bestNode = node
            }
        }
        return bestNode
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
