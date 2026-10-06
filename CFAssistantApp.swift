import SwiftUI

@main
struct CFAssistantApp: App {
    @StateObject private var session = Session()

    var body: some Scene {
        WindowGroup {
            Group {
                if session.client == nil {
                    LoginView()
                } else {
                    RootView()
                }
            }
            .environmentObject(session)
        }
    }
}
