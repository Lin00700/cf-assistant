import SwiftUI

struct PagesStage: Decodable { let name: String?; let status: String? }

struct PagesDeployment: Decodable, Identifiable {
    let id: String
    let environment: String?
    let created_on: String?
    let url: String?
    let latest_stage: PagesStage?
}

struct PagesProject: Decodable, Identifiable, Hashable {
    let name: String
    let subdomain: String?
    let production_branch: String?
    var id: String { name }

    static func == (l: PagesProject, r: PagesProject) -> Bool { l.name == r.name }
    func hash(into h: inout Hasher) { h.combine(name) }
}

struct PagesView: View {
    @EnvironmentObject var session: Session

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
            .navigationDestination(for: PagesProject.self) { PagesDeploymentsView(project: $0) }
        }
        .navigationTitle("Pages")
    }
}

struct PagesDeploymentsView: View {
    @EnvironmentObject var session: Session
    let project: PagesProject
    @State private var error: String?

    var body: some View {
        let ctx = session.ctx
        let pname = project.name
        LoadView(load: { () async throws -> [PagesDeployment] in
            try await ctx.c.get("accounts/\(ctx.acc)/pages/projects/\(pname)/deployments")
        }) { deployments, reload in
            List(deployments) { d in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(d.environment ?? "-").font(.caption.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background((d.environment == "production" ? Color.green : Color.gray).opacity(0.2))
                            .cornerRadius(4)
                        Text(d.latest_stage?.status ?? "").font(.caption).foregroundColor(.secondary)
                        Spacer()
                        if let c = d.created_on {
                            Text(c.prefix(16).replacingOccurrences(of: "T", with: " "))
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    if let u = d.url, let link = URL(string: u) {
                        Link(u, destination: link).font(.caption).lineLimit(1)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button("删除", role: .destructive) {
                        Task {
                            do {
                                try await ctx.c.delete(
                                    "accounts/\(ctx.acc)/pages/projects/\(pname)/deployments/\(d.id)",
                                    query: ["force": "true"])
                                await reload()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
                .swipeActions(edge: .leading) {
                    Button("重试") {
                        Task {
                            do {
                                let _: JSONValue = try await ctx.c.request(
                                    "POST",
                                    "accounts/\(ctx.acc)/pages/projects/\(pname)/deployments/\(d.id)/retry")
                                await reload()
                            } catch { self.error = error.localizedDescription }
                        }
                    }.tint(.blue)
                    Button("回滚") {
                        Task {
                            do {
                                let _: JSONValue = try await ctx.c.request(
                                    "POST",
                                    "accounts/\(ctx.acc)/pages/projects/\(pname)/deployments/\(d.id)/rollback")
                                await reload()
                            } catch { self.error = error.localizedDescription }
                        }
                    }.tint(.orange)
                }
            }
            .overlay { if deployments.isEmpty { EmptyHint(text: "没有部署记录") } }
            .refreshable { await reload() }
        }
        .navigationTitle(project.name)
        .errorAlert($error)
    }
}
