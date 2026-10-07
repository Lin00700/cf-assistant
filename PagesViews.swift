import SwiftUI

// MARK: - 模型

struct PagesStage: Decodable {
    let name: String?
    let status: String?
    let started_on: String?
    let ended_on: String?
}

struct PagesTriggerMeta: Decodable {
    let branch: String?
    let commit_hash: String?
    let commit_message: String?
}

struct PagesTrigger: Decodable {
    let type: String?
    let metadata: PagesTriggerMeta?
}

struct PagesDeployment: Decodable, Identifiable {
    let id: String
    let environment: String?
    let created_on: String?
    let url: String?
    let aliases: [String]?
    let latest_stage: PagesStage?
    let stages: [PagesStage]?
    let deployment_trigger: PagesTrigger?
}

struct PagesProject: Decodable, Identifiable, Hashable {
    let name: String
    let subdomain: String?
    let production_branch: String?
    var id: String { name }

    static func == (l: PagesProject, r: PagesProject) -> Bool { l.name == r.name }
    func hash(into h: inout Hasher) { h.combine(name) }
}

func pagesDate(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func pagesStatusText(_ s: String?) -> String {
    switch s {
    case "success": return "成功"
    case "failure": return "失败"
    case "active": return "进行中"
    case "idle": return "等待中"
    case "canceled": return "已取消"
    case "skipped": return "已跳过"
    default: return s ?? "-"
    }
}

func pagesStatusColor(_ s: String?) -> Color {
    switch s {
    case "success": return .green
    case "failure": return .red
    case "active": return .blue
    default: return .gray
    }
}

// MARK: - 项目列表

struct PagesView: View {
    @EnvironmentObject var session: Session
    @State private var deploying = false

    var body: some View {
        let ctx = session.ctx
        LoadView(load: { () async throws -> [PagesProject] in
            try await ctx.c.get("accounts/\(ctx.acc)/pages/projects")
        }) { projects, reload in
            List(projects) { p in
                NavigationLink(value: p) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.headline)
                        if let s = p.subdomain {
                            Text(s).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .overlay { if projects.isEmpty { EmptyHint(text: "没有 Pages 项目") } }
            .refreshable { await reload() }
            .navigationDestination(for: PagesProject.self) { PagesProjectView(project: $0) }
            .sheet(isPresented: $deploying) {
                PagesDeployView(projectName: "", fixedProject: false) { Task { await reload() } }
            }
        }
        .navigationTitle("Pages")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { deploying = true } label: { Label("部署", systemImage: "plus") }
            }
        }
    }
}

// MARK: - 项目页（仿控制台四个分页）

enum PagesTab: String, CaseIterable, Identifiable {
    case deployments = "部署"
    case metrics = "指标"
    case domains = "自定义域名"
    case settings = "设置"
    var id: String { rawValue }
}

struct PagesProjectView: View {
    @EnvironmentObject var session: Session
    let project: PagesProject
    @State private var tab: PagesTab = .deployments
    @State private var deploying = false
    @State private var refresh = UUID()

    var body: some View {
        let acc = session.accountId
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(PagesTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Group {
                switch tab {
                case .deployments:
                    PagesDeploymentsContent(project: project.name).id(refresh)
                case .metrics:
                    PagesMetricsView(project: project.name)
                case .domains:
                    PagesDomainsContent(project: project.name)
                case .settings:
                    PagesSettingsContent(project: project)
                }
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { deploying = true } label: { Label("新部署", systemImage: "arrow.up.circle") }
                    if let sub = project.subdomain, let url = URL(string: "https://\(sub)") {
                        Link(destination: url) { Label("在浏览器打开站点", systemImage: "safari") }
                    }
                    if let url = URL(string: "https://dash.cloudflare.com/\(acc)/pages/view/\(project.name)") {
                        Link(destination: url) { Label("在 Cloudflare 控制台打开", systemImage: "arrow.up.right.square") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $deploying) {
            PagesDeployView(projectName: project.name, fixedProject: true) { refresh = UUID() }
        }
    }
}
