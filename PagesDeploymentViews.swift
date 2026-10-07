import SwiftUI

// MARK: - 部署列表

struct PagesDeploymentsContent: View {
    @EnvironmentObject var session: Session
    let project: String
    @State private var error: String?

    var body: some View {
        let ctx = session.ctx
        let pname = project
        LoadView(load: { () async throws -> [PagesDeployment] in
            try await ctx.c.get("accounts/\(ctx.acc)/pages/projects/\(pname)/deployments")
        }) { deployments, reload in
            List(deployments) { d in
                NavigationLink {
                    PagesDeploymentDetailView(project: pname, deployment: d)
                } label: {
                    PagesDeploymentRow(d: d)
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
        .errorAlert($error)
    }
}

struct PagesDeploymentRow: View {
    let d: PagesDeployment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(d.environment == "production" ? "生产" : "预览")
                    .font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((d.environment == "production" ? Color.green : Color.gray).opacity(0.2))
                    .cornerRadius(4)
                Circle().fill(pagesStatusColor(d.latest_stage?.status)).frame(width: 8, height: 8)
                Text(pagesStatusText(d.latest_stage?.status)).font(.caption).foregroundColor(.secondary)
                Spacer()
                if let t = pagesDate(d.created_on) {
                    Text(t.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            if let m = d.deployment_trigger?.metadata, let msg = m.commit_message, !msg.isEmpty {
                Text(msg).font(.subheadline).lineLimit(1)
                Text("\(m.branch ?? "") \(String((m.commit_hash ?? "").prefix(7)))")
                    .font(.caption2).foregroundColor(.secondary)
            }
            if let u = d.url {
                Text(u.replacingOccurrences(of: "https://", with: ""))
                    .font(.caption).foregroundColor(.blue).lineLimit(1)
            }
        }
    }
}

// MARK: - 部署详情

struct PagesDeploymentDetailView: View {
    let project: String
    let deployment: PagesDeployment

    var body: some View {
        let d = deployment
        List {
            Section("访问") {
                if let u = d.url, let link = URL(string: u) {
                    Link(destination: link) { Label("在浏览器打开", systemImage: "safari") }
                    Button {
                        UIPasteboard.general.string = u
                    } label: { Label("复制链接", systemImage: "doc.on.doc") }
                    Text(u).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                }
                ForEach(d.aliases ?? [], id: \.self) { a in
                    if let link = URL(string: a) {
                        Link(a.replacingOccurrences(of: "https://", with: ""), destination: link)
                            .font(.footnote)
                    }
                }
            }

            Section("信息") {
                LabeledContent("环境", value: d.environment == "production" ? "生产" : "预览")
                LabeledContent("状态", value: pagesStatusText(d.latest_stage?.status))
                if let t = pagesDate(d.created_on) {
                    LabeledContent("创建时间", value: t.formatted(date: .abbreviated, time: .standard))
                }
                if let m = d.deployment_trigger?.metadata {
                    if let b = m.branch { LabeledContent("分支", value: b) }
                    if let h = m.commit_hash { LabeledContent("提交", value: String(h.prefix(7))) }
                    if let msg = m.commit_message, !msg.isEmpty {
                        Text(msg).font(.footnote).foregroundColor(.secondary)
                    }
                }
                LabeledContent("部署 ID", value: String(d.id.prefix(8)))
            }

            if let stages = d.stages, !stages.isEmpty {
                Section("阶段") {
                    ForEach(Array(stages.enumerated()), id: \.offset) { _, s in
                        HStack {
                            Circle().fill(pagesStatusColor(s.status)).frame(width: 8, height: 8)
                            Text(Self.stageName(s.name))
                            Spacer()
                            Text(Self.duration(s)).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section {
                NavigationLink {
                    PagesLogView(project: project, deploymentId: d.id)
                } label: { Label("构建日志（终端）", systemImage: "terminal") }
            }
        }
        .navigationTitle("部署详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func stageName(_ n: String?) -> String {
        switch n {
        case "queued": return "排队"
        case "initialize": return "初始化"
        case "clone_repo": return "克隆仓库"
        case "build": return "构建"
        case "deploy": return "部署"
        default: return n ?? "-"
        }
    }

    static func duration(_ s: PagesStage) -> String {
        guard let a = pagesDate(s.started_on) else { return "" }
        guard let b = pagesDate(s.ended_on) else { return "进行中" }
        return String(format: "%.1f 秒", b.timeIntervalSince(a))
    }
}

// MARK: - 构建日志（终端样式）

struct PagesLogLine: Decodable {
    let ts: String?
    let line: String?
}

struct PagesLogResult: Decodable {
    let data: [PagesLogLine]?
}

struct PagesLogView: View {
    @EnvironmentObject var session: Session
    let project: String
    let deploymentId: String

    var body: some View {
        let ctx = session.ctx
        let p = project
        let d = deploymentId
        LoadView(load: { () async throws -> PagesLogResult in
            try await ctx.c.get("accounts/\(ctx.acc)/pages/projects/\(p)/deployments/\(d)/history/logs")
        }) { res, reload in
            let lines = res.data ?? []
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if lines.isEmpty {
                        Text("没有日志。直接上传的部署通常没有构建日志。")
                            .foregroundColor(.gray)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                        Text("\(Self.time(l.ts)) \(l.line ?? "")")
                            .foregroundColor(Color.green)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .background(Color.black)
            .refreshable { await reload() }
        }
        .navigationTitle("构建日志")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func time(_ ts: String?) -> String {
        guard let d = pagesDate(ts) else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return "[\(f.string(from: d))]"
    }
}

// MARK: - 指标

struct PagesMetricsView: View {
    @EnvironmentObject var session: Session
    let project: String
    @State private var fn24: Double?
    @State private var fnErr24: Double?
    @State private var fn7d: Double?

    var body: some View {
        let ctx = session.ctx
        let pname = project
        LoadView(load: { () async throws -> [PagesDeployment] in
            try await ctx.c.get("accounts/\(ctx.acc)/pages/projects/\(pname)/deployments")
        }) { deps, reload in
            let ok = deps.filter { $0.latest_stage?.status == "success" }.count
            let bad = deps.filter { $0.latest_stage?.status == "failure" }.count
            let prod = deps.filter { $0.environment == "production" }.count
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("近期部署").font(.title3.bold())
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                        StatCard(title: "部署总数", value: deps.count, caption: "最近记录")
                        StatCard(title: "生产部署", value: prod, caption: "production")
                        StatCard(title: "成功", value: ok, caption: "")
                        StatCard(title: "失败", value: bad, caption: "")
                    }
                    if let t = pagesDate(deps.first?.created_on) {
                        Text("最近一次部署：\(t.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote).foregroundColor(.secondary)
                    }

                    Text("Functions 请求").font(.title3.bold()).padding(.top, 8)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                        metric("近 24 小时", fn24)
                        metric("24 小时错误", fnErr24)
                        metric("近 7 天", fn7d)
                    }
                    Text("Functions 请求为账户内所有 Pages 项目合计；需要 Token 有 Account Analytics 读取权限，显示“—”表示查询不可用。")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding()
            }
            .refreshable { await reload(); await loadFunctions(ctx) }
        }
        .task { await loadFunctions(ctx) }
    }

    private func metric(_ title: String, _ v: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundColor(.secondary)
            Text(v.map { formatCount($0) } ?? "—").font(.system(size: 30, weight: .bold))
        }
        .cardStyle()
    }

    private func loadFunctions(_ ctx: Ctx) async {
        let now = Date()
        let iso = ISO8601DateFormatter()
        let q = """
        query($acc: String!, $start: Time!, $end: Time!) {
          viewer { accounts(filter: {accountTag: $acc}) {
            pagesFunctionsInvocationsAdaptiveGroups(limit: 1000, filter: {datetime_geq: $start, datetime_leq: $end}) {
              sum { requests errors }
            }
          } }
        }
        """
        func run(_ since: TimeInterval) async -> (Double, Double)? {
            let vars = ["acc": ctx.acc,
                        "start": iso.string(from: now.addingTimeInterval(-since)),
                        "end": iso.string(from: now)]
            guard let v = try? await ctx.c.graphql(q, variables: vars),
                  let rows = v["data"]?["viewer"]?["accounts"]?[0]?["pagesFunctionsInvocationsAdaptiveGroups"]?.array
            else { return nil }
            let req = rows.reduce(0.0) { $0 + ($1["sum"]?["requests"]?.number ?? 0) }
            let err = rows.reduce(0.0) { $0 + ($1["sum"]?["errors"]?.number ?? 0) }
            return (req, err)
        }
        if let a = await run(86_400) { fn24 = a.0; fnErr24 = a.1 }
        if let b = await run(7 * 86_400) { fn7d = b.0 }
    }
}
