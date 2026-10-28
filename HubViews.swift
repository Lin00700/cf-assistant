import SwiftUI

enum HomeDest: String, CaseIterable, Identifiable {
    case members, audit, alerts, billing, analytics, dash, catalog, zones
    var id: String { rawValue }
    var title: String {
        switch self {
        case .members: return "成员"
        case .audit: return "审计"
        case .alerts: return "通知"
        case .billing: return "账单"
        case .analytics: return "Workers"
        case .dash: return "连接"
        case .catalog: return "云产品"
        case .zones: return "域名"
        }
    }
    var icon: String {
        switch self {
        case .members: return "person.2"
        case .audit: return "list.clipboard"
        case .alerts: return "bell"
        case .billing: return "creditcard"
        case .analytics: return "chart.xyaxis.line"
        case .dash: return "globe"
        case .catalog: return "square.stack.3d.up"
        case .zones: return "globe.asia.australia"
        }
    }
}

struct HomeDestView: View {
    let dest: HomeDest
    var body: some View {
        switch dest {
        case .members: MembersView()
        case .audit: AuditLogView()
        case .alerts: AlertPoliciesView()
        case .billing: BillingOverviewView()
        case .analytics: WorkersAnalyticsView()
        case .dash: VPNDashboardView()
        case .catalog: CloudCatalogView()
        case .zones: ZonesView()
        }
    }
}

struct HomeShortcutGrid: View {
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible())]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("控制台").font(.custom("SongtiSC-Bold", size: 22, relativeTo: .title3))
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(HomeDest.allCases) { dest in
                    NavigationLink { HomeDestView(dest: dest) } label: {
                        HStack {
                            Image(systemName: dest.icon).foregroundColor(InkTheme.seal)
                            Text(dest.title).foregroundColor(InkTheme.ink)
                            Spacer()
                        }
                        .cardStyle()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct ProductsView: View {
    var body: some View {
        List {
            ProductComputeSection()
            ProductDataSection()
            ProductMediaSection()
            ProductToolSection()
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("产品")
    }
}

private struct ProductComputeSection: View {
    var body: some View {
        Section("计算") {
            NavigationLink { WorkersView() } label: { Label("Workers", systemImage: "bolt.fill") }
            NavigationLink { PagesView() } label: { Label("Pages", systemImage: "doc.richtext.fill") }
            NavigationLink { TunnelsView() } label: { Label("Tunnels", systemImage: "point.3.connected.trianglepath.dotted") }
            NavigationLink { WorkersAnalyticsView() } label: { Label("Workers 分析", systemImage: "chart.xyaxis.line") }
            NavigationLink { WorkersAIView() } label: { Label("Workers AI", systemImage: "sparkles") }
            ForEach([AccountAPI.queues, .durableObjects, .dispatchNamespaces, .aiGateways, .callsApps]) { api in
                NavigationLink(api.title) { RemoteListView(source: .account(api)) }
            }
        }
    }
}

private struct ProductDataSection: View {
    var body: some View {
        Section("存储与数据") {
            NavigationLink { StorageView() } label: { Label("KV / D1 / R2", systemImage: "externaldrive.fill") }
            ForEach([AccountAPI.hyperdrive, .vectorize, .rulesLists]) { api in
                NavigationLink(api.title) { RemoteListView(source: .account(api)) }
            }
        }
    }
}

private struct ProductMediaSection: View {
    var body: some View {
        Section("媒体与 Zero Trust") {
            NavigationLink { ImagesBrowserView() } label: { Label("Images", systemImage: "photo.on.rectangle") }
            ForEach([AccountAPI.streamVideos, .streamLive, .turnstile]) { api in
                NavigationLink(api.title) { RemoteListView(source: .account(api)) }
            }
            NavigationLink { ZeroTrustHub() } label: { Label("Zero Trust", systemImage: "lock.shield") }
        }
    }
}

private struct ProductToolSection: View {
    var body: some View {
        Section("工具") {
            NavigationLink { AIChatView() } label: { Label("AI 对话", systemImage: "sparkles") }
            NavigationLink { PreferredIPView() } label: { Label("优选 IP", systemImage: "speedometer") }
            NavigationLink { DeveloperView() } label: { Label("开发者目录", systemImage: "chevron.left.forwardslash.chevron.right") }
            NavigationLink { CloudCatalogView() } label: { Label("全部云产品", systemImage: "square.grid.2x2") }
        }
    }
}

struct ZeroTrustHub: View {
    private let apis: [AccountAPI] = [
        .accessApps, .accessGroups, .accessServiceTokens, .accessIdPs,
        .gatewayRules, .devicePosture, .devicePolicies
    ]
    var body: some View {
        List {
            ForEach(apis) { api in
                NavigationLink(api.title) { RemoteListView(source: .account(api)) }
            }
        }
        .navigationTitle("Zero Trust")
        .scrollContentBackground(.hidden)
    }
}

struct CloudCatalogView: View {
    private let order = ["计算", "数据", "媒体与安全", "Zero Trust", "网络", "账户"]
    var body: some View {
        List {
            ForEach(order, id: \.self) { group in
                Section(group) {
                    ForEach(AccountAPI.allCases.filter { $0.group == group }) { api in
                        NavigationLink(api.title) { RemoteListView(source: .account(api)) }
                    }
                }
            }
        }
        .navigationTitle("云产品")
        .scrollContentBackground(.hidden)
    }
}
