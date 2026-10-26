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
                let prev = self.status
                self.status = m.connection.status
                // 连接中/已连接后立刻断开：多半是扩展 startTunnel 失败
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

    /// 向 VPN 扩展要最近的运行日志
    func fetchLog() async -> String {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            return "无法取得 NETunnelProviderSession（manager 未就绪）。"
        }
        // connecting / reasserting 时也允许取日志，方便排查启动失败
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
                guard let extID = extensionBundleID else {
                    error = "这个安装包不含 VPN 扩展，请使用「VPN 版」IPA"
                    return
                }
                let config = SingBoxConfig.build(nodes: store.nodes, selectedID: store.selected?.id,
                                                 mode: store.selectionMode, bypassCN: store.bypassCN,
                                                 rules: store.routingRules)
                let m = manager ?? NETunnelProviderManager()
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = extID
                proto.serverAddress = store.selected?.server ?? "sing-box"
                proto.providerConfiguration = ["config": config]
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

    /// 配置改动（节点、模式、规则）后让 VPN 用新配置重连
    func restartIfActive(store: ProxyStore) async {
        guard isActive else { return }
        await set(on: false, store: store)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await set(on: true, store: store)
    }
}
