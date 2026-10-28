import AppIntents
import NetworkExtension
import SwiftUI
import WidgetKit

@main
struct CFControlBundle: WidgetBundle {
    var body: some Widget {
        VPNCloudControl()
    }
}

struct VPNCloudControl: ControlWidget {
    static let kind = "com.cfassistant.ios.cloud"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: VPNCloudValueProvider()) { isOn in
            // 图库预览用静态 Label 的 SF Symbol；开关状态再用 valueLabel 换图标。
            ControlWidgetToggle(isOn: isOn, action: ToggleVPNIntent()) {
                Label("云朵", systemImage: "cloud")
                    .tint(Color(red: 0.78, green: 0.16, blue: 0.14))
            } valueLabel: { on in
                Label(on ? "已开" : "已关", systemImage: on ? "cloud.fill" : "cloud")
                    .tint(Color(red: 0.78, green: 0.16, blue: 0.14))
            }
        }
        .displayName("云朵")
        .description("开关 VPN")
    }
}

struct VPNCloudValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        guard let manager = all.first else { return false }
        switch manager.connection.status {
        case .connected, .connecting, .reasserting: return true
        default: return false
        }
    }
}

struct ToggleVPNIntent: SetValueIntent {
    static var title: LocalizedStringResource = "开关云朵"

    @Parameter(title: "开启")
    var value: Bool

    func perform() async throws -> some IntentResult {
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        guard let manager = all.first else {
            throw VPNControlError.notConfigured
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
            default:
                try manager.connection.startVPNTunnel()
            }
        } else {
            if manager.isOnDemandEnabled {
                manager.isOnDemandEnabled = false
                manager.onDemandRules = []
                try? await manager.saveToPreferences()
            }
            manager.connection.stopVPNTunnel()
        }
        return .result()
    }
}

enum VPNControlError: Error, LocalizedError {
    case notConfigured

    var errorDescription: String? {
        "请先在 App 内连接一次 VPN"
    }
}
