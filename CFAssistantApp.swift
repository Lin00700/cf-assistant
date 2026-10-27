import SwiftUI

@main
struct CFAssistantApp: App {
    @StateObject private var session = Session()
    @ObservedObject private var theme = ThemeStore.shared

    var body: some Scene {
        WindowGroup {
            ZStack {
                AppBackdropView()
                    .id("backdrop-\(theme.skin.rawValue)")
                Group {
                    if session.client == nil {
                        LoginView()
                    } else {
                        RootView()
                    }
                }
                .environmentObject(session)
                .environmentObject(theme)
                .tint(InkTheme.cinnabar)
                // 换肤时强制整树重建，所有 InkTheme 颜色立即生效
                .id("root-\(theme.skin.rawValue)-\(session.accountId)")
            }
            .preferredColorScheme(theme.skin == .moon ? .dark : .light)
        }
    }
}
