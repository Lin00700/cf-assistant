import AppIntents
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
            ControlWidgetToggle("云朵", isOn: isOn, action: ToggleVPNIntent()) { on in
                Label(on ? "已开" : "已关", systemImage: on ? "cloud.fill" : "cloud")
            }
        }
        .displayName("云朵")
        .description("直接开关 CF 助手 VPN")
    }
}

struct VPNCloudValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        guard let manager = try await VPNControlConfiguration.loadManager() else { return false }
        switch manager.connection.status {
        case .connected, .connecting, .reasserting, .disconnecting:
            return true
        default:
            return false
        }
    }
}
