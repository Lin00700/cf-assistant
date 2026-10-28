import SwiftUI

@main
struct CFAssistantApp: App {
    @StateObject private var session = Session()
    @AppStorage("appearance.chineseSkin") private var skinRaw = ChineseSkin.ink.rawValue

    private var skin: ChineseSkin {
        ChineseSkin(rawValue: skinRaw) ?? .ink
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                AppBackdropView()
                Group {
                    if session.client == nil {
                        LoginView()
                    } else {
                        RootView()
                    }
                }
                .environmentObject(session)
                .tint(skin.accent)
                .id("\(session.accountId)-\(skinRaw)")
                .onAppear {
                    InkChrome.apply()
                    #if VPN_BUILD
                    Task { await VPNManager.shared.load() }
                    #endif
                }
                .onChange(of: skinRaw) { _ in InkChrome.apply() }
            }
            .preferredColorScheme(skin.lockedScheme)
        }
    }
}
