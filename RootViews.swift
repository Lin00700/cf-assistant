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
                Section(footer: Text("优选 IP 只在本机测速，不需要登录 Cloudflare。")) {
                    NavigationLink { PreferredIPView() } label: { Label("不登录，直接使用优选 IP 工具", systemImage: "speedometer") }
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
            .scrollContentBackground(.hidden)
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
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        TabView {
            NavigationStack { OverviewView() }
                .chineseNavigationChrome()
                .tabItem { Label("概览", systemImage: "square.grid.2x2.fill") }
            NavigationStack { ZonesView() }
                .chineseNavigationChrome()
                .tabItem { Label("域名", systemImage: "globe") }
            NavigationStack { DeveloperView() }
                .chineseNavigationChrome()
                .tabItem { Label("开发者", systemImage: "chevron.left.forwardslash.chevron.right") }
            NavigationStack { StorageView() }
                .chineseNavigationChrome()
                .tabItem { Label("存储", systemImage: "externaldrive.fill") }
            NavigationStack { AIChatView() }
                .chineseNavigationChrome()
                .tabItem { Label("AI", systemImage: "sparkles") }
            NavigationStack { MoreView() }
                .chineseNavigationChrome()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .tint(InkTheme.cinnabar)
        .toolbarBackground(InkTheme.paper.opacity(0.96), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarColorScheme(InkTheme.chromeScheme, for: .tabBar)
        .background(Color.clear)
        .id("\(session.accountId)-\(theme.skin.rawValue)")
    }
}

struct DeveloperView: View {
    var body: some View {
        List {
            NavigationLink { ProxyHomeView() } label: { Label("VPN 与代理节点", systemImage: "lock.shield.fill") }
            NavigationLink { WorkersView() } label: { Label("Workers", systemImage: "bolt.fill") }
            NavigationLink { PagesView() } label: { Label("Pages", systemImage: "doc.richtext.fill") }
            NavigationLink { TunnelsView() } label: { Label("Tunnels 隧道", systemImage: "point.3.connected.trianglepath.dotted") }
            NavigationLink { PreferredIPView() } label: { Label("优选 IP", systemImage: "speedometer") }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("开发者")
    }
}

struct MoreView: View {
    @EnvironmentObject var session: Session

    var body: some View {
        List {
            Section("外观") {
                NavigationLink { AppearanceSettingsView() } label: {
                    Label("背景与主题", systemImage: "paintpalette")
                }
            }
            Section("工具") {
                NavigationLink { APITokensView() } label: { Label("API Token 管理", systemImage: "key.horizontal") }
            }
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
        .scrollContentBackground(.hidden)
        .navigationTitle("设置")
    }
}
