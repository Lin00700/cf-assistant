import SwiftUI

// MARK: - 登录

struct LoginView: View {
    @EnvironmentObject var session: Session
    @State private var mode: Credentials.Mode = .token
    @State private var token = ""
    @State private var email = ""
    @State private var globalKey = ""
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("登录方式", selection: $mode) {
                        Text("API Token").tag(Credentials.Mode.token)
                        Text("邮箱 + Global Key").tag(Credentials.Mode.globalKey)
                    }
                    .pickerStyle(.segmented)
                }
                Section(footer: Text("凭据只保存在本机钥匙串，仅用于直接请求 Cloudflare API。")) {
                    if mode == .token {
                        SecureField("API Token", text: $token)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        TextField("Cloudflare 邮箱", text: $email)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                        SecureField("Global API Key", text: $globalKey)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                Section {
                    Button {
                        Task { await doLogin() }
                    } label: {
                        HStack {
                            Spacer()
                            if loading { ProgressView() } else { Text("登录") }
                            Spacer()
                        }
                    }
                    .disabled(loading || !valid)
                }
            }
            .navigationTitle("CF 助手")
            .errorAlert($error)
        }
    }

    private var valid: Bool {
        mode == .token ? !token.trimmingCharacters(in: .whitespaces).isEmpty
                       : (!email.isEmpty && !globalKey.isEmpty)
    }

    private func doLogin() async {
        loading = true
        defer { loading = false }
        var c = Credentials(mode: mode)
        c.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        c.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        c.globalKey = globalKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try await session.login(c) } catch { self.error = error.localizedDescription }
    }
}

// MARK: - 主界面

struct RootView: View {
    @EnvironmentObject var session: Session

    var body: some View {
        TabView {
            NavigationStack { OverviewView() }
                .tabItem { Label("概览", systemImage: "square.grid.2x2.fill") }
            NavigationStack { ZonesView() }
                .tabItem { Label("域名", systemImage: "globe") }
            NavigationStack { DeveloperView() }
                .tabItem { Label("开发者", systemImage: "chevron.left.forwardslash.chevron.right") }
            NavigationStack { StorageView() }
                .tabItem { Label("存储", systemImage: "externaldrive.fill") }
            NavigationStack { MoreView() }
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .tint(.orange)
        .id(session.accountId)   // 切换账户时重建所有页面
    }
}

struct DeveloperView: View {
    var body: some View {
        List {
            NavigationLink { WorkersView() } label: { Label("Workers", systemImage: "bolt.fill") }
            NavigationLink { PagesView() } label: { Label("Pages", systemImage: "doc.richtext.fill") }
            NavigationLink { TunnelsView() } label: { Label("Tunnels 隧道", systemImage: "point.3.connected.trianglepath.dotted") }
        }
        .navigationTitle("开发者")
    }
}

struct MoreView: View {
    @EnvironmentObject var session: Session

    var body: some View {
        List {
            Section("账户") {
                if session.accounts.count > 1 {
                    Picker("当前账户", selection: $session.accountId) {
                        ForEach(session.accounts) { Text($0.name).tag($0.id) }
                    }
                } else if let a = session.accounts.first {
                    LabeledContent("当前账户", value: a.name)
                }
                Button("退出登录", role: .destructive) { session.logout() }
            }
        }
        .navigationTitle("设置")
    }
}
