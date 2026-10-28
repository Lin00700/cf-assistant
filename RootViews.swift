import SwiftUI

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
                    InkBanner(height: 168) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("云上站点，尽在掌中")
                                .font(.custom("SongtiSC-Bold", size: 22, relativeTo: .title3))
                                .foregroundColor(InkTheme.ink)
                            Text("水墨云图 · Cloudflare")
                                .font(.subheadline)
                                .foregroundColor(InkTheme.inkSoft)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section {
                    Picker("登录方式", selection: $mode) {
                        Text("API Token").tag(Credentials.Mode.token)
                        Text("邮箱 + Global Key").tag(Credentials.Mode.globalKey)
                    }
                    .pickerStyle(.segmented)
                }
                Section(footer: Text("凭据只保存在本机钥匙串。")) {
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
                    NavigationLink { PreferredIPView() } label: {
                        Label("优选 IP 工具", systemImage: "speedometer")
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

struct RootView: View {
    @EnvironmentObject var session: Session
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appearance.chineseSkin") private var skinRaw = ChineseSkin.ink.rawValue

    private var skin: ChineseSkin {
        ChineseSkin(rawValue: skinRaw) ?? .ink
    }

    private var darkChrome: Bool {
        skin.isDark || (skin == .ink && scheme == .dark)
    }

    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { OverviewView() }
                .chineseNavigationChrome()
                .tabItem { Label("首页", systemImage: "square.grid.2x2.fill") }
                .tag(0)
            NavigationStack { ZonesView() }
                .chineseNavigationChrome()
                .tabItem { Label("域名", systemImage: "globe") }
                .tag(1)
            NavigationStack { ProductsView() }
                .chineseNavigationChrome()
                .tabItem { Label("产品", systemImage: "square.stack.3d.up.fill") }
                .tag(2)
            NavigationStack { VPNDashboardView() }
                .chineseNavigationChrome()
                .tabItem { Label("VPN", systemImage: "lock.shield.fill") }
                .tag(3)
            NavigationStack { MeView() }
                .chineseNavigationChrome()
                .tabItem { Label("我的", systemImage: "person.crop.circle.fill") }
                .tag(4)
        }
        .modifier(VPNHomeBallOverlay(tab: $tab))
        .tint(skin.accent)
        .toolbarBackground(InkTheme.paper.opacity(0.96), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarColorScheme(darkChrome ? .dark : .light, for: .tabBar)
        .id("\(session.accountId)-\(skinRaw)")
    }
}

private struct VPNHomeBallOverlay: ViewModifier {
    @Binding var tab: Int

    func body(content: Content) -> some View {
        #if VPN_BUILD
        content.overlay(alignment: .topLeading) {
            if tab == 0 {
                VPNFloatBall(container: UIScreen.main.bounds.size) { tab = 3 }
            }
        }
        #else
        content
        #endif
    }
}

struct DeveloperView: View {
    var body: some View {
        List {
            NavigationLink { VPNDashboardView() } label: {
                Label("连接仪表盘", systemImage: "globe")
            }
            NavigationLink { ProxyHomeView() } label: {
                Label("VPN 与代理节点", systemImage: "lock.shield.fill")
            }
            NavigationLink { WorkersView() } label: {
                Label("Workers", systemImage: "bolt.fill")
            }
            NavigationLink { PagesView() } label: {
                Label("Pages", systemImage: "doc.richtext.fill")
            }
            NavigationLink { TunnelsView() } label: {
                Label("Tunnels 隧道", systemImage: "point.3.connected.trianglepath.dotted")
            }
            NavigationLink { PreferredIPView() } label: {
                Label("优选 IP", systemImage: "speedometer")
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("开发者")
    }
}

struct MeView: View {
    @EnvironmentObject var session: Session

    var body: some View {
        List {
            if session.accounts.count > 1 {
                Section("切换账户") {
                    Picker("账户", selection: Binding(
                        get: { session.accountId },
                        set: { session.selectAccount($0) }
                    )) {
                        ForEach(session.accounts) { account in
                            Text(account.name).tag(account.id)
                        }
                    }
                }
            }
            Section("账户") {
                NavigationLink { AccountHomeView() } label: { Label("账户主页", systemImage: "person.text.rectangle") }
                NavigationLink { MembersView() } label: { Label("成员", systemImage: "person.2") }
                NavigationLink { BillingOverviewView() } label: { Label("账单", systemImage: "creditcard") }
                NavigationLink { AuditLogView() } label: { Label("审计日志", systemImage: "list.clipboard") }
                NavigationLink { AlertPoliciesView() } label: { Label("通知", systemImage: "bell") }
                NavigationLink { APITokensView() } label: { Label("API Token", systemImage: "key.fill") }
                NavigationLink { IPAccessRulesView(zoneID: nil) } label: { Label("账户 IP 规则", systemImage: "shield") }
            }
            Section("外观") {
                NavigationLink { AppearanceSettingsView() } label: { Label("背景与主题", systemImage: "paintpalette.fill") }
            }
            Section("智能") {
                NavigationLink { AIChatView() } label: { Label("AI 对话", systemImage: "sparkles") }
                NavigationLink { AISettingsView() } label: { Label("AI 设置", systemImage: "slider.horizontal.3") }
            }
            Section {
                Button(role: .destructive) { session.logout() } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("我的")
    }
}

