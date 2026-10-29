import Foundation
import NetworkExtension

@MainActor
final class VPNManager: ObservableObject {
    static let shared = VPNManager()

    @Published var status: NEVPNStatus = .invalid
    @Published var error: String?

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
            if !isActive, let failure = TunnelStartupFailureStore.lastMessage() {
                self.error = "最近一次 VPN 启动失败（错误信息已脱敏）：\(failure)"
            }
        } catch {
            if let failure = TunnelStartupFailureStore.lastMessage() {
                self.error = "最近一次 VPN 启动失败（错误信息已脱敏）：\(failure)"
            } else {
                self.error = TunnelStartupFailureStore.sanitize(error.localizedDescription)
            }
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
                    if let failure = TunnelStartupFailureStore.lastMessage() {
                        self.error = "VPN 启动失败（错误信息已脱敏）：\(failure)"
                    } else if !TunnelStartupFailureStore.sharedContainerAvailable {
                        self.error = "VPN 未能启动；当前安装包无法读取脱敏失败详情。请确认重签时保留 App Group entitlement：\(TunnelStartupFailureStore.appGroupIdentifier)"
                    } else if self.error == nil {
                        self.error = "VPN 未能保持连接（扩展启动失败或配置被拒）。请确认已装「VPN 版」IPA，并检查节点加密方式后重试。"
                    }
                }
                if self.status == .connected {
                    self.error = nil
                    TunnelStartupFailureStore.clear()
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

    /// Resolve cloudflare.com through sing-box inside the extension. Does not use the system resolver.
    func querySingBoxDNS() async -> String {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            return "FAIL 无法取得扩展会话"
        }
        return await withCheckedContinuation { cont in
            do {
                try session.sendProviderMessage(Data("dns".utf8)) { data in
                    guard let data, let text = String(data: data, encoding: .utf8),
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        cont.resume(returning: "FAIL 扩展未返回 sing-box DNS 结果")
                        return
                    }
                    cont.resume(returning: text)
                }
            } catch {
                cont.resume(returning: "FAIL \(error.localizedDescription)")
            }
        }
    }

    func fetchLog() async -> String {
        if status == .invalid || status == .disconnected {
            if let failure = TunnelStartupFailureStore.lastMessage() {
                return "最近一次 VPN 启动失败（错误信息已脱敏）：\(failure)"
            }
            if !TunnelStartupFailureStore.sharedContainerAvailable {
                return "无法读取隧道启动失败详情：请确认重签安装包保留 App Group entitlement：\(TunnelStartupFailureStore.appGroupIdentifier)"
            }
            return "VPN 未连接（状态：\(statusText)）。若刚打开又自动关掉，请到系统「设置 → 通用 → VPN 与设备管理」看配置是否还在，并确认装的是 VPN 版 IPA。"
        }
        guard let session = manager?.connection as? NETunnelProviderSession else {
            return "无法取得 NETunnelProviderSession（manager 未就绪）。"
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
                        cont.resume(returning: TunnelStartupFailureStore.sanitize(text))
                    }
                }
            } catch {
                cont.resume(returning: "读取失败：\(error.localizedDescription)")
            }
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
                store.normalizeDecodedNodes()
                if store.selectionMode == .manual, let node = store.selected,
                   !LinkParser.serverLooksDialable(node.server) {
                    let title = node.name.count > 24 ? String(node.name.prefix(24)) + "…" : node.name
                    error = "当前节点「\(title)」的地址无法识别，不能连接。请改选 TCP 已测通的节点。"
                    return
                }
                guard let extID = extensionBundleID else {
                    error = "这个安装包不含 VPN 扩展，请使用「VPN 版」IPA"
                    return
                }
                let config = SingBoxConfig.build(nodes: store.nodes, selectedID: store.selected?.id,
                                                 mode: store.selectionMode, bypassCN: store.bypassCN,
                                                 rules: store.routingRules,
                                                 categoryPolicies: store.categoryPolicies)
                let m = manager ?? NETunnelProviderManager()
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = extID
                // Match the working profile: iOS Server shows the parsed node
                // label, while the actual remote host remains in sing-box config.
                proto.serverAddress = store.selected?.name ?? "127.0.0.1"
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
                TunnelStartupFailureStore.clear()
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
            let failure = TunnelStartupFailureStore.safeSummary(for: error)
            if on {
                TunnelStartupFailureStore.save(failure)
                self.error = "VPN 启动请求失败（错误信息已脱敏）：\(failure)"
            } else {
                self.error = TunnelStartupFailureStore.sanitize(error.localizedDescription)
            }
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
