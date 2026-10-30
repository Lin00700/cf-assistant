import AppIntents
import NetworkExtension

/// Shared by the host app and ControlWidget extension.
/// Keep the action in the extension process so a Control Center tap doesn't open the app.
struct ToggleVPNIntent: SetValueIntent {
    static var title: LocalizedStringResource = "开关云朵"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "开启")
    var value: Bool

    func perform() async throws -> some IntentResult {
        guard let manager = try await VPNControlConfiguration.loadManager() else {
            if value { throw VPNControlError.notConfigured }
            return .result()
        }

        if value {
            if !manager.isEnabled {
                manager.isEnabled = true
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            }
            switch manager.connection.status {
            case .connected, .connecting, .reasserting:
                break
            case .disconnecting:
                if try await VPNControlConfiguration.waitForDisconnection(manager.connection) {
                    try manager.connection.startVPNTunnel()
                }
            default:
                try manager.connection.startVPNTunnel()
            }
        } else {
            if manager.isOnDemandEnabled {
                manager.isOnDemandEnabled = false
                manager.onDemandRules = []
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            }
            manager.connection.stopVPNTunnel()
        }
        return .result()
    }
}

enum VPNControlConfiguration {
    static let tunnelProviderBundleIdentifier = "com.cfassistant.ios.tunnel"
    static let profileName = "CF助手"

    static func loadManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let matches = managers.filter(isCFVPN)
        return matches.first(where: isActive) ?? matches.first
    }

    static func waitForDisconnection(_ connection: NEVPNConnection) async throws -> Bool {
        for _ in 0..<32 {
            if connection.status != .disconnecting { return connection.status == .disconnected }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        if connection.status == .disconnecting { throw VPNControlError.transitionTimedOut }
        return connection.status == .disconnected
    }

    private static func isCFVPN(_ manager: NETunnelProviderManager) -> Bool {
        guard manager.localizedDescription == profileName,
              let tunnel = manager.protocolConfiguration as? NETunnelProviderProtocol else { return false }
        return tunnel.providerBundleIdentifier == tunnelProviderBundleIdentifier
    }

    private static func isActive(_ manager: NETunnelProviderManager) -> Bool {
        switch manager.connection.status {
        case .connected, .connecting, .reasserting, .disconnecting: return true
        default: return false
        }
    }
}

enum VPNControlError: Error, LocalizedError {
    case notConfigured
    case transitionTimedOut

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "未找到 CF 助手的 VPN 配置。请先打开 CF 助手，添加可用节点并在 App 内连接一次，然后再使用云朵控制。"
        case .transitionTimedOut:
            return "VPN 仍在断开，稍后再点云朵开启。"
        }
    }
}
