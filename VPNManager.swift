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

    /// PlugIns 里同时有 CFTunnel.appex（packet-tunnel）和 CFControl.appex（WidgetKit 控件），
    /// 不能取第一个 .appex，必须按 NSExtensionPointIdentifier 认出真正的隧道扩展。
    /// 不写死 bundle id：重签工具可能改掉前缀。
    var extensionBundleID: String? {
        guard let dir = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        let appexes = items.filter { $0.pathExtension == "appex" }

        // 1) 扩展点声明为 packet-tunnel 的那个
        for u in appexes {
            guard let bundle = Bundle(url: u),
                  let id = bundle.bundleIdentifier,
                  let ext = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                  let point = ext["NSExtensionPointIdentifier"] as? String,
                  point == "com.apple.networkextension.packet-tunnel"
            else { continue }
            return id
        }
        // 2) 退回按名字 / bundle id 后缀认
        for u in appexes where u.deletingPathExtension().lastPathComponent == "CFTunnel" {
            if let id = Bundle(url: u)?.bundleIdentifier { return id }
        }
        for u in appexes {
            if let id = Bundle(url: u)?.bundleIdentifier, id.hasSuffix(".tunnel") { return id }
        }
        return nil
    }

    private func providerID(of m: NETunnelProviderManager) -> String? {
        (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
    }

    func load() async {
        do {
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            guard !all.isEmpty else { return }
            let extID = extensionBundleID
            let chosen = all.first { providerID(of: $0) == extID } ?? all.first!
            // 旧版本可能把 CFControl.appex 当成 provider 存进了系统偏好；连之前顺手改正，
            // 免得系统里一直留着一个指向 WidgetKit 控件的 VPN 配置。
            if let extID, providerID(of: chosen) != extID,
               let proto = chosen.protocolConfiguration as? NETunnelProviderProtocol {
                proto.providerBundleIdentifier = extID
                chosen.protocolConfiguration = proto
                try? await chosen.saveToPreferences()
                try? await chosen.loadFromPreferences()
            }
            attach(chosen)
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
                                                 categoryPolicies: store.categoryPolicies,
                                                 auto: store.autoPolicy)
                let m = manager ?? NETunnelProviderManager()
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = extID
                // 系统设置里显示 127.0.0.1，对应通的状态
                proto.serverAddress = "127.0.0.1"
                proto.providerConfiguration = ["config": config]
                m.protocolConfiguration = proto
                m.localizedDescription = "CF助手"
                m.isEnabled = true
                // 按需连接默认开，系统设置显示绿开关
                m.isOnDemandEnabled = true
                let rule = NEOnDemandRuleConnect()
                rule.interfaceTypeMatch = .any
                m.onDemandRules = [rule]
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
