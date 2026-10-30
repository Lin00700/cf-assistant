import WidgetKit

/// Keep the iOS 18 Control Center toggle in sync with VPN state changes.
enum VPNControlRefresh {
    static func reload() {
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: "com.cfassistant.ios.cloud")
        }
    }
}
