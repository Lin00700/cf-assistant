import Foundation
import Darwin
import NetworkExtension

@MainActor
final class VPNManager: ObservableObject {
    static let shared = VPNManager()

    @Published var status: NEVPNStatus = .invalid
    @Published var error: String?
    /// Exact JSON last passed to the extension as providerConfiguration["config"].
    @Published var sentConfig: String = ""

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

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
        syncTrafficMonitor()
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: m.connection, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let m = self.manager else { return }
                let prev = self.status
                self.status = m.connection.status
                self.syncTrafficMonitor()
                if (prev == .connecting || prev == .connected || prev == .reasserting),
                   self.status == .disconnected {
                    if self.error == nil {
                        self.error = "VPN 未能保持连接（扩展启动失败或配置被拒）。请确认已装「VPN 版」IPA，并检查节点加密方式后重试。"
                    }
                }
                if self.status == .connected {
                    self.error = nil
                }
            }
        }
    }

    private func syncTrafficMonitor() {
        if status == .connected {
            VPNTraffic.shared.startMonitoring()
        } else {
            VPNTraffic.shared.stopMonitoring()
        }
    }

    func fetchLog() async -> String {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            return "无法取得 NETunnelProviderSession（manager 未就绪）。"
        }
        if status == .invalid || status == .disconnected {
            return "VPN 未连接（状态：\(statusText)）。若刚打开又自动关掉，请到系统「设置 → 通用 → VPN 与设备管理」看配置是否还在，并确认装的是 VPN 版 IPA。"
        }
        return await withCheckedContinuation { cont in
            do {
                try session.sendProviderMessage(Data("log".utf8)) { data in
                    guard let data else {
                        cont.resume(returning: "扩展回了 nil 数据（进程可能已退出或消息通道未就绪）。")
                        return
                    }
                    let text = String(data: data, encoding: .utf8) ?? ""
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        cont.resume(returning: "（扩展返回空字符串）状态=\(self.statusText)")
                    } else {
                        cont.resume(returning: text)
                    }
                }
            } catch {
                cont.resume(returning: "读取失败：\(error.localizedDescription)")
            }
        }
    }

    /// A records for hostname nodes, so their /32s can bypass the tun. Bounded so a dead resolver cannot stall connect.
    private static func resolvedNodeCIDRs(_ nodes: [ProxyNode]) async -> [String] {
        var cidrs: [String] = []
        for node in nodes where SingBoxConfig.isSupported(node) {
            let host = node.server
            if host.split(separator: ".").count == 4, host.split(separator: ".").allSatisfy({ Int($0) != nil }) {
                continue
            }
            let ips = await lookupIPv4(host)
            for ip in ips where !cidrs.contains("\(ip)/32") {
                cidrs.append("\(ip)/32")
            }
        }
        return cidrs
    }

    private static func lookupIPv4(_ host: String) async -> [String] {
        await withTaskGroup(of: [String].self) { group in
            group.addTask {
                await Task.detached(priority: .utility) {
                    var hints = addrinfo()
                    hints.ai_family = AF_INET
                    hints.ai_socktype = Int32(SOCK_STREAM)
                    var resolved: UnsafeMutablePointer<addrinfo>?
                    guard getaddrinfo(host, nil, &hints, &resolved) == 0, let first = resolved else { return [] }
                    defer { freeaddrinfo(first) }
                    var addresses: [String] = []
                    var current: UnsafeMutablePointer<addrinfo>? = first
                    while let item = current {
                        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen,
                                       &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                            let address = String(cString: buffer)
                            if !addresses.contains(address) { addresses.append(address) }
                        }
                        current = item.pointee.ai_next
                    }
                    return addresses
                }.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    func set(on: Bool, store: ProxyStore) async {
        error = nil
        do {
            if on {
                guard store.nodes.contains(where: SingBoxConfig.isSupported) else {
                    error = "请先添加并选择一个可用节点"
                    return
                }
                guard let extID = extensionBundleID else {
                    error = "这个安装包不含 VPN 扩展，请使用「VPN 版」IPA"
                    return
                }
                let selectedID = store.selectedID ?? store.nodes.first?.id
                let extra = await Self.resolvedNodeCIDRs(store.nodes)
                let config = SingBoxConfig.build(nodes: store.nodes, selectedID: selectedID,
                                                 mode: store.selectionMode, bypassCN: store.bypassCN,
                                                 rules: store.routingRules,
                                                 categoryPolicies: store.categoryPolicies,
                                                 resolvedExcludes: extra)
                sentConfig = config
                let m = manager ?? NETunnelProviderManager()
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = extID
                proto.serverAddress = store.selected?.server ?? "sing-box"
                proto.providerConfiguration = ["config": config]
                m.protocolConfiguration = proto
                m.localizedDescription = "CF助手"
                m.isEnabled = true
                m.isOnDemandEnabled = store.alwaysOn
                if store.alwaysOn {
                    let rule = NEOnDemandRuleConnect()
                    rule.interfaceTypeMatch = .any
                    m.onDemandRules = [rule]
                } else {
                    m.onDemandRules = []
                }
                try await m.saveToPreferences()
                try await m.loadFromPreferences()
                attach(m)
                try m.connection.startVPNTunnel()
            } else {
                if let m = manager {
                    m.isOnDemandEnabled = false
                    m.onDemandRules = []
                    try? await m.saveToPreferences()
                }
                manager?.connection.stopVPNTunnel()
                VPNTraffic.shared.stopMonitoring()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func restartIfActive(store: ProxyStore) async {
        guard isActive else { return }
        await set(on: false, store: store)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await set(on: true, store: store)
    }

    func measureProxyEgress(node: ProxyNode) async throws -> ProxyProbeResult {
        guard isConnected else { throw CFClientError.message("VPN 未连接，无法进行代理 HTTPS 探测") }
        let results = try await ProxyLatencyTester.measureViaSingBox(nodes: [node], controlURL: SingBoxConfig.controlURL)
        guard let result = results[node.id] else {
            throw CFClientError.message("sing-box 未返回指定节点的 HTTPS 探测结果")
        }
        return result
    }
}
