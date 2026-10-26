import Foundation

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
// worker script restored later
export default { async fetch() { return new Response("ok"); } };
"""#
}
