import SwiftUI

/// 修改 deployment_configs.{env}.{key}，条目值为 .null 表示删除
func pagesPatchEnv(_ ctx: Ctx, _ project: String, _ env: String,
                   _ key: String, _ entries: [String: JSONValue]) async throws {
    let body = JSONValue.object([
        "deployment_configs": .object([
            env: .object([key: .object(entries)])
        ])
    ])
    try await ctx.c.send("PATCH", "accounts/\(ctx.acc)/pages/projects/\(project)", json: body)
}

// MARK: - 设置页（对应控制台“设置”分页）

struct PagesSettingsContent: View {
    @EnvironmentObject var session: Session
    let project: PagesProject

    var body: some View {
        let ctx = session.ctx
        let pname = project.name
        LoadView(load: { () async throws -> JSONValue in
            try await ctx.c.get("accounts/\(ctx.acc)/pages/projects/\(pname)")
        }) { r, reload in
            let prod = r["deployment_configs"]?["production"]
            let prev = r["deployment_configs"]?["preview"]
            let src = r["source"]?["config"]
            let build = r["build_config"]

            List {
                Section("构建") {
                    if let owner = src?["owner"]?.description, let repo = src?["repo_name"]?.description {
                        LabeledContent("Git 仓库", value: "\(owner)/\(repo)")
                    } else {
                        LabeledContent("Git 仓库", value: "未连接（直接上传）")
                    }
                    LabeledContent("生产分支", value: project.production_branch ?? "-")
                    if let c = build?["build_command"]?.description, c != "NULL", !c.isEmpty {
                        LabeledContent("构建命令", value: c)
                    }
                    if let c = build?["destination_dir"]?.description, c != "NULL", !c.isEmpty {
                        LabeledContent("输出目录", value: c)
                    }
                    if let c = build?["root_dir"]?.description, c != "NULL", !c.isEmpty {
                        LabeledContent("根目录", value: c)
                    }
                }

                Section("变量和机密") {
                    NavigationLink {
                        PagesVariablesView(project: pname)
                    } label: {
                        HStack {
                            Label("文本变量和机密", systemImage: "key.fill")
                            Spacer()
                            Text("生产 \(Self.count(prod, "env_vars")) · 预览 \(Self.count(prev, "env_vars"))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }

                Section("绑定") {
                    NavigationLink {
                        PagesBindingsView(project: pname)
                    } label: {
                        HStack {
                            Label("KV / D1 / R2", systemImage: "externaldrive.connected.to.line.below")
                            Spacer()
                            Text("生产 \(Self.bindingCount(prod)) · 预览 \(Self.bindingCount(prev))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }

                Section("兼容性") {
                    LabeledContent("生产日期", value: Self.text(prod?["compatibility_date"]))
                    LabeledContent("预览日期", value: Self.text(prev?["compatibility_date"]))
                    let flags = (prod?["compatibility_flags"]?.array ?? []).map { $0.description }
                    if !flags.isEmpty { LabeledContent("生产标志", value: flags.joined(separator: ", ")) }
                }

                Section(footer: Text("绑定和变量的修改只对之后的新部署生效。")) {
                    if let url = URL(string: "https://dash.cloudflare.com/\(ctx.acc)/pages/view/\(pname)/settings") {
                        Link(destination: url) { Label("在浏览器打开控制台设置", systemImage: "safari") }
                    }
                }
            }
            .refreshable { await reload() }
        }
    }

    static func count(_ cfg: JSONValue?, _ key: String) -> Int {
        cfg?[key]?.object.count ?? 0
    }

    static func bindingCount(_ cfg: JSONValue?) -> Int {
        count(cfg, "kv_namespaces") + count(cfg, "d1_databases") + count(cfg, "r2_buckets")
    }

    static func text(_ v: JSONValue?) -> String {
        guard let s = v?.description, s != "NULL", !s.isEmpty else { return "-" }
        return s
    }
}

// MARK: - 变量和机密

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
                                        try await pagesPatchEnv(ctx, pname, e, "env_vars", [key: .null])
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
                        try await pagesPatchEnv(ctx, pname, e, "env_vars", [name: entry])
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
}

// MARK: - 绑定（KV / D1 / R2）

struct PagesBindingsData {
    var config: JSONValue
    var kvNames: [String: String]
    var d1Names: [String: String]
}

struct PagesBindingsView: View {
    @EnvironmentObject var session: Session
    let project: String
    @State private var env = "production"
    @State private var adding = false
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

            LoadView(load: { () async throws -> PagesBindingsData in
                let r: JSONValue = try await ctx.c.get("accounts/\(ctx.acc)/pages/projects/\(pname)")
                let kv: [KVNamespace]? = try? await ctx.c.get(
                    "accounts/\(ctx.acc)/storage/kv/namespaces", query: ["per_page": "100"])
                let d1: [D1Database]? = try? await ctx.c.get(
                    "accounts/\(ctx.acc)/d1/database", query: ["per_page": "100"])
                var kvNames: [String: String] = [:]
                for n in kv ?? [] { kvNames[n.id] = n.title }
                var d1Names: [String: String] = [:]
                for d in d1 ?? [] { d1Names[d.uuid] = d.name }
                return PagesBindingsData(config: r["deployment_configs"]?[e] ?? .null,
                                         kvNames: kvNames, d1Names: d1Names)
            }) { data, reload in
                let kvs = data.config["kv_namespaces"]?.object ?? [:]
                let d1s = data.config["d1_databases"]?.object ?? [:]
                let r2s = data.config["r2_buckets"]?.object ?? [:]
                List {
                    bindingSection("KV 命名空间", key: "kv_namespaces", items: kvs, ctx: ctx, pname: pname, e: e,
                                   reload: reload) { obj in
                        let id = obj["namespace_id"]?.description ?? ""
                        return data.kvNames[id] ?? id
                    }
                    bindingSection("D1 数据库", key: "d1_databases", items: d1s, ctx: ctx, pname: pname, e: e,
                                   reload: reload) { obj in
                        let id = obj["id"]?.description ?? ""
                        return data.d1Names[id] ?? id
                    }
                    bindingSection("R2 存储桶", key: "r2_buckets", items: r2s, ctx: ctx, pname: pname, e: e,
                                   reload: reload) { obj in
                        obj["name"]?.description ?? ""
                    }
                    Section(footer: Text("绑定的修改只对之后的新部署生效。")) { EmptyView() }
                }
                .refreshable { await reload() }
                .sheet(isPresented: $adding) {
                    PagesBindingSheet(project: pname, env: e) { Task { await reload() } }
                }
            }
            .id(env)
        }
        .navigationTitle("绑定")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
            }
        }
        .errorAlert($error)
    }

    @ViewBuilder
    private func bindingSection(_ title: String, key: String, items: [String: JSONValue],
                                ctx: Ctx, pname: String, e: String,
                                reload: @escaping () async -> Void,
                                target: @escaping (JSONValue) -> String) -> some View {
        Section(title) {
            ForEach(items.keys.sorted(), id: \.self) { name in
                HStack {
                    Text(name).font(.headline)
                    Spacer()
                    Text(target(items[name] ?? .null)).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                .swipeActions {
                    Button("删除", role: .destructive) {
                        Task {
                            do {
                                try await pagesPatchEnv(ctx, pname, e, key, [name: .null])
                                await reload()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
            if items.isEmpty { Text("没有绑定").foregroundColor(.secondary) }
        }
    }
}

struct PagesBindingSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let project: String
    let env: String
    let onSaved: () -> Void

    private struct Opt: Identifiable { let id: String; let label: String }

    @State private var kind = 0   // 0 KV, 1 D1, 2 R2
    @State private var name = ""
    @State private var kv: [Opt] = []
    @State private var d1: [Opt] = []
    @State private var r2: [Opt] = []
    @State private var selected = ""
    @State private var saving = false
    @State private var error: String?

    private var options: [Opt] { kind == 0 ? kv : (kind == 1 ? d1 : r2) }

    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $kind) {
                    Text("KV").tag(0)
                    Text("D1").tag(1)
                    Text("R2").tag(2)
                }
                .pickerStyle(.segmented)

                Section(footer: Text("变量名称是在 Functions 代码里使用的名字，例如 KV、DB、BUCKET。")) {
                    TextField("变量名称", text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if options.isEmpty {
                        Text("当前账户下没有可用的资源").foregroundColor(.secondary)
                    } else {
                        Picker(kind == 0 ? "命名空间" : (kind == 1 ? "数据库" : "存储桶"), selection: $selected) {
                            ForEach(options) { Text($0.label).tag($0.id) }
                        }
                    }
                }
            }
            .navigationTitle("添加绑定（\(env == "production" ? "生产" : "预览")）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") { Task { await save() } }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || selected.isEmpty)
                }
            }
            .task { await loadOptions() }
            .onChange(of: kind) { _ in selected = options.first?.id ?? "" }
            .errorAlert($error)
        }
    }

    private func loadOptions() async {
        let ctx = session.ctx
        let k: [KVNamespace]? = try? await ctx.c.get("accounts/\(ctx.acc)/storage/kv/namespaces",
                                                      query: ["per_page": "100"])
        let d: [D1Database]? = try? await ctx.c.get("accounts/\(ctx.acc)/d1/database", query: ["per_page": "100"])
        let r: R2BucketList? = try? await ctx.c.get("accounts/\(ctx.acc)/r2/buckets")
        kv = (k ?? []).map { Opt(id: $0.id, label: $0.title) }
        d1 = (d ?? []).map { Opt(id: $0.uuid, label: $0.name) }
        r2 = (r?.buckets ?? []).map { Opt(id: $0.name, label: $0.name) }
        selected = options.first?.id ?? ""
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let ctx = session.ctx
        let n = name.trimmingCharacters(in: .whitespaces)
        do {
            switch kind {
            case 0:
                try await pagesPatchEnv(ctx, project, env, "kv_namespaces",
                                        [n: .object(["namespace_id": .string(selected)])])
            case 1:
                try await pagesPatchEnv(ctx, project, env, "d1_databases",
                                        [n: .object(["id": .string(selected)])])
            default:
                try await pagesPatchEnv(ctx, project, env, "r2_buckets",
                                        [n: .object(["name": .string(selected)])])
            }
            onSaved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - 自定义域名

struct PagesDomain: Decodable, Identifiable {
    let id: String
    let name: String
    let status: String?
}

struct PagesDomainsContent: View {
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
                Section {
                    Button { adding = true } label: { Label("添加自定义域名", systemImage: "plus") }
                }
                Section {
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
                    if domains.isEmpty { Text("没有自定义域名").foregroundColor(.secondary) }
                }
            }
            .refreshable { await reload() }
            .sheet(isPresented: $adding) {
                HostnameSheet(title: "添加自定义域名",
                              hint: "域名在当前账户下时通常会自动创建指向 \(pname).pages.dev 的 CNAME；否则需要自行添加 CNAME 记录，状态会显示“验证中”直到生效。") { host in
                    try await ctx.c.send("POST", "accounts/\(ctx.acc)/pages/projects/\(pname)/domains",
                                         json: ["name": host])
                    await reload()
                }
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
