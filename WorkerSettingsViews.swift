import SwiftUI

// MARK: - 详情入口

struct WorkerDetailView: View {
    @EnvironmentObject var session: Session
    let name: String
    let onChanged: () -> Void

    @State private var devEnabled: Bool?
    @State private var devHost: String?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                NavigationLink {
                    WorkerEditorView(name: name, isNew: false, onSaved: onChanged)
                } label: { Label("代码", systemImage: "chevron.left.forwardslash.chevron.right") }
                NavigationLink {
                    WorkerVariablesView(script: name)
                } label: { Label("变量和机密", systemImage: "key.fill") }
                NavigationLink {
                    WorkerDomainsView(script: name)
                } label: { Label("自定义域名", systemImage: "link") }
            }

            Section("workers.dev") {
                Toggle("启用 workers.dev 访问", isOn: Binding(
                    get: { devEnabled ?? false },
                    set: { new in Task { await setDev(new) } }
                ))
                .disabled(devEnabled == nil)
                if devEnabled == true, let host = devHost, let url = URL(string: "https://\(host)") {
                    Link(host, destination: url).font(.footnote)
                }
            }
        }
        .navigationTitle(name)
        .task { await loadDev() }
        .errorAlert($error)
    }

    private struct DevStatus: Decodable { let enabled: Bool? }

    private func loadDev() async {
        let ctx = session.ctx
        let status: DevStatus? = try? await ctx.c.get("accounts/\(ctx.acc)/workers/scripts/\(name)/subdomain")
        let sub: WorkerSubdomain? = try? await ctx.c.get("accounts/\(ctx.acc)/workers/subdomain")
        devEnabled = status?.enabled ?? false
        if let s = sub?.subdomain { devHost = "\(name).\(s).workers.dev" }
    }

    private func setDev(_ on: Bool) async {
        let ctx = session.ctx
        do {
            try await ctx.c.send("POST", "accounts/\(ctx.acc)/workers/scripts/\(name)/subdomain",
                                 json: ["enabled": on])
            devEnabled = on
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - 变量和机密

private struct SecretBody: Encodable {
    let name: String
    let text: String
    let type: String
}

struct WorkerVariablesView: View {
    @EnvironmentObject var session: Session
    let script: String
    @State private var target: VarTarget?
    @State private var error: String?

    var body: some View {
        let ctx = session.ctx
        let sname = script
        LoadView(load: { () async throws -> [JSONValue] in
            let r: JSONValue = try await ctx.c.get("accounts/\(ctx.acc)/workers/scripts/\(sname)/settings")
            return r["bindings"]?.array ?? []
        }) { bindings, reload in
            let plain = bindings.filter { $0["type"]?.description == "plain_text" }
            let secrets = bindings.filter { $0["type"]?.description == "secret_text" }
            let others = bindings.filter {
                let t = $0["type"]?.description
                return t != "plain_text" && t != "secret_text"
            }
            List {
                Section("变量") {
                    ForEach(Array(plain.enumerated()), id: \.offset) { _, b in
                        let n = b["name"]?.description ?? ""
                        let v = b["text"]?.description ?? ""
                        Button { target = VarTarget(name: n, value: v, kind: .text) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(n).font(.headline)
                                Text(v).font(.caption).foregroundColor(.secondary).lineLimit(2)
                            }
                        }
                        .foregroundColor(.primary)
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                Task {
                                    do {
                                        let next = Self.normalized(bindings).filter { $0["name"]?.description != n }
                                        try await Self.patchBindings(ctx, sname, next)
                                        await reload()
                                    } catch { self.error = error.localizedDescription }
                                }
                            }
                        }
                    }
                    if plain.isEmpty { Text("没有文本变量").foregroundColor(.secondary) }
                }

                Section("机密") {
                    ForEach(Array(secrets.enumerated()), id: \.offset) { _, b in
                        let n = b["name"]?.description ?? ""
                        Button { target = VarTarget(name: n, value: "", kind: .secret) } label: {
                            HStack {
                                Text(n).font(.headline)
                                Spacer()
                                Text("••••••").foregroundColor(.secondary)
                            }
                        }
                        .foregroundColor(.primary)
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                Task {
                                    do {
                                        let enc = n.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? n
                                        try await ctx.c.delete(
                                            "accounts/\(ctx.acc)/workers/scripts/\(sname)/secrets/\(enc)")
                                        await reload()
                                    } catch { self.error = error.localizedDescription }
                                }
                            }
                        }
                    }
                    if secrets.isEmpty { Text("没有机密").foregroundColor(.secondary) }
                }

                if !others.isEmpty {
                    Section("其他绑定（只读）") {
                        ForEach(Array(others.enumerated()), id: \.offset) { _, b in
                            HStack {
                                Text(b["name"]?.description ?? "").font(.subheadline)
                                Spacer()
                                Text(b["type"]?.description ?? "").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .refreshable { await reload() }
            .sheet(item: $target) { t in
                VariableEditSheet(isEdit: t.name != nil, allowSecret: true,
                                  name: t.name ?? "", value: t.value, kind: t.kind) { name, value, kind in
                    if kind == .secret {
                        try await ctx.c.send("PUT", "accounts/\(ctx.acc)/workers/scripts/\(sname)/secrets",
                                             json: SecretBody(name: name, text: value, type: "secret_text"))
                    } else {
                        var next = Self.normalized(bindings).filter { $0["name"]?.description != name }
                        next.append(.object(["type": .string("plain_text"),
                                             "name": .string(name),
                                             "text": .string(value)]))
                        try await Self.patchBindings(ctx, sname, next)
                    }
                    await reload()
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { target = VarTarget(name: nil, value: "", kind: .text) } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .navigationTitle("变量和机密")
        .errorAlert($error)
    }

    /// 机密在 PATCH settings 里用 inherit 保留，其余绑定原样回传
    static func normalized(_ bindings: [JSONValue]) -> [JSONValue] {
        bindings.map { b in
            if b["type"]?.description == "secret_text" {
                return .object(["type": .string("inherit"), "name": .string(b["name"]?.description ?? "")])
            }
            return b
        }
    }

    static func patchBindings(_ ctx: Ctx, _ script: String, _ bindings: [JSONValue]) async throws {
        let settings = JSONValue.object(["bindings": .array(bindings)])
        let data = try JSONEncoder().encode(settings)
        let (body, ct) = buildMultipart([
            MultipartPart(name: "settings", filename: nil, contentType: "application/json", data: data)
        ])
        let _: JSONValue = try await ctx.c.request(
            "PATCH", "accounts/\(ctx.acc)/workers/scripts/\(script)/settings",
            body: body, contentType: ct)
    }
}

// MARK: - 自定义域名

struct WorkerDomain: Decodable, Identifiable {
    let id: String
    let hostname: String
    let zone_name: String?
    let environment: String?
}

private struct WorkerDomainBody: Encodable {
    let environment: String
    let hostname: String
    let service: String
    let zone_id: String
}

struct WorkerDomainsView: View {
    @EnvironmentObject var session: Session
    let script: String
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        let ctx = session.ctx
        let sname = script
        LoadView(load: { () async throws -> [WorkerDomain] in
            try await ctx.c.get("accounts/\(ctx.acc)/workers/domains", query: ["service": sname])
        }) { domains, reload in
            List {
                ForEach(domains) { d in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.hostname).font(.headline)
                        Text(d.zone_name ?? "").font(.caption).foregroundColor(.secondary)
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            Task {
                                do {
                                    try await ctx.c.delete("accounts/\(ctx.acc)/workers/domains/\(d.id)")
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
                              hint: "域名所在的 Zone 必须在当前账户下，Cloudflare 会自动创建 DNS 记录和证书。") { host in
                    let zones: [Zone] = try await ctx.c.get("zones", query: ["per_page": "50"])
                    let match = zones
                        .filter { host == $0.name || host.hasSuffix("." + $0.name) }
                        .max { $0.name.count < $1.name.count }
                    guard let z = match else {
                        throw CFClientError.message("\(host) 不属于当前账户下的任何域名")
                    }
                    try await ctx.c.send("PUT", "accounts/\(ctx.acc)/workers/domains",
                                         json: WorkerDomainBody(environment: "production", hostname: host,
                                                                service: sname, zone_id: z.id))
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
}
