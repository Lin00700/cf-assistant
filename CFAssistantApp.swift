import SwiftUI

@main
struct CFAssistantApp: App {
    @StateObject private var session = Session()

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
                .tint(InkTheme.cinnabar)
                .id(session.accountId)
            }
        }
    }
}
