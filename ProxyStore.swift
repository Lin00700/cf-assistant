import Foundation

@MainActor
final class ProxyStore: ObservableObject {
    static let shared = ProxyStore()

    @Published var nodes: [ProxyNode] = [] { didSet { save() } }
    @Published var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "vpn_selected") }
    }
    @Published var bypassCN: Bool = true {
        didSet {
            UserDefaults.standard.set(bypassCN, forKey: "vpn_bypass")
            scheduleVPNRestart()
        }
    }
    @Published var selectionMode: ProxySelectionMode = .manual {
        didSet {
            UserDefaults.standard.set(selectionMode.rawValue, forKey: "vpn_mode")
            scheduleVPNRestart()
        }
    }
    @Published var routingRules: [ProxyRoutingRule] = [] {
        didSet {
            saveRules()
            scheduleVPNRestart()
        }
    }
    @Published var categoryPolicies: [ProxyTrafficCategory: ProxyGroupPolicy] = [:] {
        didSet {
            saveCategoryPolicies()
            scheduleVPNRestart()
        }
    }
    @Published var alwaysOn: Bool = false {
        didSet {
            UserDefaults.standard.set(alwaysOn, forKey: "vpn_always_on")
            scheduleVPNRestart()
        }
    }
    @Published var results: [UUID: ProxyProbeResult] = [:]
    @Published var isRefreshing = false
    @Published var refreshError: String?

    private var isReady = false
    private static let key = "vpn.nodes"
    private static let rulesKey = "vpn_rules"
    private static let categoryKey = "vpn_category_policies"

    init() {
        if let d = Keychain.get(Self.key), let arr = try? JSONDecoder().decode([ProxyNode].self, from: d) {
            nodes = arr
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
        isReady = true
    }

    private func scheduleVPNRestart() {
        guard isReady else { return }
        Task {
            let vpn = VPNManager.shared
            if alwaysOn && !vpn.isActive {
                await vpn.set(on: true, store: self)
            } else {
                await vpn.restartIfActive(store: self)
            }
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

enum NodeWorker {
    static func script(uuid: String) -> String {
        "export default { async fetch() { return new Response(\"ok\"); } };"
    }

    static func node(name: String, host: String, address: String, uuid: String) -> ProxyNode {
        ProxyNode(name: name, proto: "vless", server: address, port: 443, secret: uuid,
                  params: ["type": "ws", "security": "tls", "sni": host, "host": host,
                           "path": "/", "fp": "chrome"])
    }
}
