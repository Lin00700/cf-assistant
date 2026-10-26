import Foundation
import NetworkExtension

@MainActor
final class VPNManager: ObservableObject {
    static let shared = VPNManager()

    @Published var status: NEVPNStatus = .invalid
    @Published var error: String?

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private let clashAPI = URL(string: "http://127.0.0.1:\(SingBoxConfig.controlPort)")!

    var isActive: Bool { status == .connected || status == .connecting || status == .reasserting }
    var isConnected: Bool { status == .connected }

    var statusText: String {
        switch status {
        case .connected: return "已连接"
        case .connecting: return "连接中…"
        case .reasserting: return "重新连接中…"
        case .disconnecting: return "断开中…"
        case .disconnected: return "未连接"
        default: return "未启用"
        }
    }

    /// 安装包里的 VPN 扩展（PlugIns/*.appex）的 Bundle ID。没有扩展说明装的是普通版 IPA
    var extensionBundleID: String? {
        guard let dir = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        for u in items where u.pathExtension == "appex" {
            if let id = Bundle(url: u)?.bundleIdentifier { return id }
        }
        return nil
    }

    func load() async {
        do {
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            if let m = all.first { attach(m) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func attach(_ m: NETunnelProviderManager) {
        manager = m
        status = m.connection.status
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: m.connection, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let m = self.manager else { return }
                self.status = m.connection.status
            }
        }
    }

    func set(on: Bool, node: ProxyNode?, bypassCN: Bool) async {
        error = nil
        do {
            if on {
                guard let node else { error = "请先添加并选择一个节点"; return }
                guard let extID = extensionBundleID else {
                    error = "这个安装包不含 VPN 扩展，请使用「VPN 版」IPA"
                    return
                }
                let store = ProxyStore.shared
                let nodes = store.nodes.contains(where: { $0.id == node.id }) ? store.nodes : [node]
                let config = SingBoxConfig.build(
                    nodes: nodes,
                    selectedID: node.id,
                    selectionMode: store.selectionMode,
                    bypassCN: bypassCN,
                    routingRules: store.routingRules
                )
                guard config.utf8.count <= SingBoxConfig.maxProviderConfigSourceBytes else {
                    error = "VPN 配置超过系统可处理上限；现有节点未被更改或删除"
                    return
                }
                guard let compressedConfig = SingBoxConfig.compressedProviderConfig(config) else {
                    error = "VPN 配置压缩失败；现有节点未被更改或删除，请重试"
                    return
                }
                guard compressedConfig.count <= 480 * 1024 else {
                    error = "压缩后的 VPN 配置仍超过系统上限；现有节点未被更改或删除"
                    return
                }
                let m = manager ?? NETunnelProviderManager()
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = extID
                proto.serverAddress = node.server
                proto.providerConfiguration = ["configCompressed": compressedConfig]
                m.protocolConfiguration = proto
                m.localizedDescription = "CF助手"
                m.isEnabled = true
                try await m.saveToPreferences()
                try await m.loadFromPreferences()
                attach(m)
                try m.connection.startVPNTunnel()
            } else {
                manager?.connection.stopVPNTunnel()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 切换实际运行的出站组与手动节点，不需要重启 VPN。
    func select(node: ProxyNode, mode: ProxySelectionMode) async throws {
        guard isConnected else { return }
        if mode == .manual {
            try await updateSelector(tag: "manual", outbound: SingBoxConfig.nodeTag(node))
        }
        try await updateSelector(tag: "proxy", outbound: mode.outboundTag)
    }

    func setSelectionMode(_ mode: ProxySelectionMode, node: ProxyNode?) async throws {
        guard isConnected else { return }
        if mode == .manual, let node {
            try await updateSelector(tag: "manual", outbound: SingBoxConfig.nodeTag(node))
        }
        try await updateSelector(tag: "proxy", outbound: mode.outboundTag)
    }

    /// VPN 已连接时测真实代理请求；未连接时测 TCP 节点端口连通性。
    func measureNodeLatencies(nodes: [ProxyNode]) async throws -> [UUID: ProxyProbeResult] {
        guard !nodes.isEmpty else { return [:] }
        guard isConnected else {
            return await ProxyLatencyTester.measureDirectTCP(nodes: nodes)
        }

        let manualDelayURL = clashAPI.appendingPathComponent("group")
            .appendingPathComponent("manual").appendingPathComponent("delay")
        var components = URLComponents(url: manualDelayURL,
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "url", value: "https://www.gstatic.com/generate_204"),
            URLQueryItem(name: "timeout", value: "20000")
        ]
        guard let url = components.url else { throw CFClientError.message("无法构造延迟测试请求") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 24
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CFClientError.message("sing-box 延迟测试失败（HTTP \(status)）；请确认 VPN 已完全连接后重试")
        }
        let values = try JSONDecoder().decode([String: Int].self, from: data)
        let latencyByTag = Dictionary(uniqueKeysWithValues: values.map { ($0.key, $0.value) })

        // The selector probe above refreshes shared URL-test history for every node.
        // Ask the auto group to recalculate its winner from those fresh measurements.
        let autoDelayURL = clashAPI.appendingPathComponent("group")
            .appendingPathComponent("auto").appendingPathComponent("delay")
        var autoComponents = URLComponents(url: autoDelayURL,
                                           resolvingAgainstBaseURL: false)!
        autoComponents.queryItems = components.queryItems
        guard let autoURL = autoComponents.url else { throw CFClientError.message("无法构造自动选优请求") }
        var autoRequest = URLRequest(url: autoURL)
        autoRequest.timeoutInterval = 12
        let (_, autoResponse) = try await URLSession.shared.data(for: autoRequest)
        guard let autoHTTP = autoResponse as? HTTPURLResponse, (200..<300).contains(autoHTTP.statusCode) else {
            let status = (autoResponse as? HTTPURLResponse)?.statusCode ?? -1
            throw CFClientError.message("自动节点组选优失败（HTTP \(status)）")
        }
        return Dictionary(uniqueKeysWithValues: nodes.map { node in
            (node.id, ProxyProbeResult.from(milliseconds: latencyByTag[SingBoxConfig.nodeTag(node)]))
        })
    }

    /// 节点列表、分流规则或大陆直连选项变更时重启隧道以载入新配置。
    func reconfigure() async {
        guard isConnected else { return }
        guard let node = ProxyStore.shared.selected else {
            manager?.connection.stopVPNTunnel()
            return
        }
        manager?.connection.stopVPNTunnel()
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if manager?.connection.status == .disconnected { break }
        }
        await set(on: true, node: node, bypassCN: ProxyStore.shared.bypassCN)
    }

    private func updateSelector(tag: String, outbound: String) async throws {
        let selectorURL = clashAPI.appendingPathComponent("proxies").appendingPathComponent(tag)
        var request = URLRequest(url: selectorURL)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": outbound])
        request.timeoutInterval = 5
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CFClientError.message("代理组切换失败（HTTP \(status)）")
        }
    }
}
