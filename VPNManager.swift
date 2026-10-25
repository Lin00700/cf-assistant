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
                let m = manager ?? NETunnelProviderManager()
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = extID
                proto.serverAddress = node.server
                proto.providerConfiguration = ["config": SingBoxConfig.build(node: node, bypassCN: bypassCN)]
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
}
