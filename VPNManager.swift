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
                self.status = m.connection.status
            }
        }
    }

    /// 向 VPN 扩展要最近的运行日志
    func fetchLog() async -> String {
        guard let session = manager?.connection as? NETunnelProviderSession, status != .disconnected, status != .invalid else {
            return "VPN 未连接，没有日志。请先打开 VPN 再来看。"
        }
        return await withCheckedContinuation { cont in
            do {
                try session.sendProviderMessage(Data("log".utf8)) { data in
                    let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    cont.resume(returning: text.isEmpty ? "（扩展没有返回日志）" : text)
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
