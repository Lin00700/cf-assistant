import SwiftUI

// MARK: - 项目入口

struct PagesProjectView: View {
    let project: PagesProject

    var body: some View {
        List {
            Section {
                NavigationLink {
                    PagesDeploymentsView(project: project)
                } label: { Label("部署记录", systemImage: "clock.arrow.circlepath") }
                NavigationLink {
                    PagesVariablesView(project: project.name)
                } label: { Label("变量和机密", systemImage: "key.fill") }
                NavigationLink {
                    PagesDomainsView(project: project.name)
                } label: { Label("自定义域名", systemImage: "link") }
            }
            if let sub = project.subdomain, let url = URL(string: "https://\(sub)") {
                Section("默认地址") {
                    Link(sub, destination: url)
                }
            }
        }
        .navigationTitle(project.name)
    }
}

// MARK: - 环境变量

struct PagesVariablesView: View {
    @EnvironmentObject var session: Session
    let project: String
    @State private var env = "production"
    @State private var target: VarTarget?
    @State private var error: String?

    var body: some View {
        let ctx = session.ctx
        let pname = project
        let e = env
        VStack(spacing: 0) {
            Picker("环境", selection: $env) {
                Text("生产").tag("production")
                Text("预览").tag("preview")
            }
            .pickerStyle(.segmented)
            .padding()

            LoadView(load: { () async throws -> [String: JSONValue] in
                let r: JSONValue = try await ctx.c.get("accounts/\(ctx.acc)/pages/projects/\(pname)")
                return r["deployment_configs"]?[e]?["env_vars"]?.object ?? [:]
            }) { vars, reload in
                List {
                    ForEach(vars.keys.sorted(), id: \.self) { key in
                        let v = vars[key]
                        let isSecret = v?["type"]?.description == "secret_text"
                        Button {
                            target = VarTarget(name: key,
                                               value: isSecret ? "" : (v?["value"]?.description ?? ""),
                                               kind: isSecret ? .secret : .text)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(key).font(.headline)
                                    if isSecret {
                                        Image(systemName: "lock.fill").font(.caption).foregroundColor(.secondary)
                                    }
                                }
                                Text(isSecret ? "••••••" : (v?["value"]?.description ?? ""))
                                    .font(.caption).foregroundColor(.secondary).lineLimit(2)
                            }
                        }
                        .foregroundColor(.primary)
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                Task {
                                    do {
                                        try await Self.patch(ctx, pname, e, [key: .null])
                                        await reload()
                                    } catch { self.error = error.localizedDescription }
                                }
                            }
                        }
                    }
                }
                .overlay { if vars.isEmpty { EmptyHint(text: "没有变量") } }
                .refreshable { await reload() }
                .sheet(item: $target) { t in
                    VariableEditSheet(isEdit: t.name != nil, allowSecret: true,
                                      name: t.name ?? "", value: t.value, kind: t.kind) { name, value, kind in
                        let entry = JSONValue.object([
                            "type": .string(kind == .secret ? "secret_text" : "plain_text"),
                            "value": .string(value)
                        ])
                        try await Self.patch(ctx, pname, e, [name: entry])
                        await reload()
                    }
                }
            }
            .id(env)
        }
        .navigationTitle("变量和机密")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { target = VarTarget(name: nil, value: "", kind: .text) } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .errorAlert($error)
    }

    /// 值为 .null 表示删除该变量
    static func patch(_ ctx: Ctx, _ project: String, _ env: String, _ vars: [String: JSONValue]) async throws {
        let body = JSONValue.object([
            "deployment_configs": .object([
                env: .object(["env_vars": .object(vars)])
            ])
        ])
        try await ctx.c.send("PATCH", "accounts/\(ctx.acc)/pages/projects/\(project)", json: body)
    }
}

// MARK: - 自定义域名

struct PagesDomain: Decodable, Identifiable {
    let id: String
    let name: String
    let status: String?
}

struct PagesDomainsView: View {
    @EnvironmentObject var session: Session
    let project: String
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        let ctx = session.ctx
        let pname = project
        LoadView(load: { () async throws -> [PagesDomain] in
            try await ctx.c.get("accounts/\(ctx.acc)/pages/projects/\(pname)/domains")
        }) { domains, reload in
            List {
                ForEach(domains) { d in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name).font(.headline)
                            Text(Self.statusText(d.status)).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Circle().fill(d.status == "active" ? Color.green : Color.orange)
                            .frame(width: 10, height: 10)
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            Task {
                                do {
                                    try await ctx.c.delete(
                                        "accounts/\(ctx.acc)/pages/projects/\(pname)/domains/\(d.name)")
                                    await reload()
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
            }
            .overlay { if domains.isEmpty { EmptyHint(text: "没有自定义域名") } }
            .refreshable { await reload() }
            .sheet(isPresented: $adding) {
                HostnameSheet(title: "添加自定义域名",
                              hint: "域名在当前账户下时会自动创建指向 \(pname).pages.dev 的 CNAME；否则需要自行添加 CNAME 记录，状态会显示“验证中”直到生效。") { host in
                    try await ctx.c.send("POST", "accounts/\(ctx.acc)/pages/projects/\(pname)/domains",
                                         json: ["name": host])
                    await reload()
                }
            }
        }
        .navigationTitle("自定义域名")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
            }
        }
        .errorAlert($error)
    }

    static func statusText(_ s: String?) -> String {
        switch s {
        case "active": return "已生效"
        case "pending", "initializing": return "验证中"
        case "blocked": return "被阻止"
        case "deactivated": return "已停用"
        default: return s ?? "未知"
        }
    }
}
