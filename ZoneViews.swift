import SwiftUI

// MARK: - 域名详情入口

struct ZoneDetailView: View {
    let zone: Zone

    var body: some View {
        List {
            Section {
                NavigationLink { DNSRecordsView(zone: zone) } label: {
                    Label("DNS 记录", systemImage: "list.bullet.rectangle")
                }
                NavigationLink { ZoneAnalyticsView(zone: zone) } label: {
                    Label("流量分析", systemImage: "chart.bar.xaxis")
                }
                NavigationLink { ZoneSettingsView(zone: zone) } label: {
                    Label("SSL / 缓存 / 安全", systemImage: "lock.shield")
                }
                NavigationLink { WorkerRoutesView(zone: zone) } label: {
                    Label("Workers 路由", systemImage: "arrow.triangle.branch")
                }
                NavigationLink { EmailRoutingView(zone: zone) } label: {
                    Label("邮件路由", systemImage: "envelope")
                }
            }
            Section("信息") {
                LabeledContent("状态", value: zone.status == "active" ? "已启用" : (zone.status ?? "-"))
                LabeledContent("套餐", value: zone.plan?.name ?? "-")
                LabeledContent("Zone ID") {
                    Text(zone.id).font(.caption2).textSelection(.enabled)
                }
            }
        }
        .navigationTitle(zone.name)
    }
}

// MARK: - 设置 + 清除缓存

private struct PurgeFiles: Encodable { let files: [String] }

struct ZoneSettingsView: View {
    @EnvironmentObject var session: Session
    let zone: Zone
    @State private var error: String?
    @State private var message: String?
    @State private var confirmPurge = false
    @State private var purgeURLs = false

    var body: some View {
        let ctx = session.ctx
        let zid = zone.id
        LoadView(load: { () async throws -> [String: JSONValue] in
            let list: [JSONValue] = try await ctx.c.get("zones/\(zid)/settings")
            var d: [String: JSONValue] = [:]
            for s in list {
                if let id = s["id"]?.description { d[id] = s["value"] ?? .null }
            }
            return d
        }) { vals, reload in
            List {
                Section("SSL / TLS") {
                    Picker("加密模式", selection: strBinding("ssl", "off", vals, ctx, reload)) {
                        Text("关闭").tag("off")
                        Text("灵活").tag("flexible")
                        Text("完全").tag("full")
                        Text("完全（严格）").tag("strict")
                    }
                    Toggle("始终使用 HTTPS", isOn: boolBinding("always_use_https", vals, ctx, reload))
                    Toggle("自动 HTTPS 重写", isOn: boolBinding("automatic_https_rewrites", vals, ctx, reload))
                    Picker("最低 TLS 版本", selection: strBinding("min_tls_version", "1.0", vals, ctx, reload)) {
                        Text("1.0").tag("1.0")
                        Text("1.1").tag("1.1")
                        Text("1.2").tag("1.2")
                        Text("1.3").tag("1.3")
                    }
                }

                Section("安全") {
                    Picker("安全级别", selection: strBinding("security_level", "medium", vals, ctx, reload)) {
                        Text("基本关闭").tag("essentially_off")
                        Text("低").tag("low")
                        Text("中").tag("medium")
                        Text("高").tag("high")
                        Text("I'm Under Attack").tag("under_attack")
                    }
                    Toggle("电子邮件地址混淆", isOn: boolBinding("email_obfuscation", vals, ctx, reload))
                }

                Section("网络与性能") {
                    Toggle("开发模式（3 小时内绕过缓存）", isOn: boolBinding("development_mode", vals, ctx, reload))
                    Toggle("Brotli 压缩", isOn: boolBinding("brotli", vals, ctx, reload))
                    Toggle("HTTP/3 (QUIC)", isOn: boolBinding("http3", vals, ctx, reload))
                    Toggle("IPv6 兼容", isOn: boolBinding("ipv6", vals, ctx, reload))
                    Toggle("WebSockets", isOn: boolBinding("websockets", vals, ctx, reload))
                }

                Section(header: Text("缓存"), footer: Text("按 URL 清除时每行一个完整地址，例如 https://example.com/a.css。")) {
                    Button(role: .destructive) { confirmPurge = true } label: {
                        Label("清除全部缓存", systemImage: "trash")
                    }
                    Button { purgeURLs = true } label: {
                        Label("按 URL 清除", systemImage: "link")
                    }
                }
            }
            .refreshable { await reload() }
            .confirmationDialog("清除 \(zone.name) 的全部缓存？源站会短时间内收到更多回源请求。",
                                isPresented: $confirmPurge, titleVisibility: .visible) {
                Button("清除全部缓存", role: .destructive) {
                    Task {
                        do {
                            try await ctx.c.send("POST", "zones/\(zid)/purge_cache", json: ["purge_everything": true])
                            message = "已提交清除请求，通常几秒内生效"
                        } catch { self.error = error.localizedDescription }
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .sheet(isPresented: $purgeURLs) {
                PurgeURLsSheet { urls in
                    try await ctx.c.send("POST", "zones/\(zid)/purge_cache", json: PurgeFiles(files: urls))
                    message = "已提交 \(urls.count) 个 URL 的清除请求"
                }
            }
        }
        .navigationTitle("SSL / 缓存 / 安全")
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { _ in })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
        .errorAlert($error)
    }

    private func update(_ ctx: Ctx, _ key: String, _ value: String, _ reload: @escaping () async -> Void) async {
        do {
            try await ctx.c.send("PATCH", "zones/\(zone.id)/settings/\(key)", json: ["value": value])
        } catch {
            self.error = error.localizedDescription
        }
        await reload()
    }

    private func strBinding(_ key: String, _ def: String, _ vals: [String: JSONValue], _ ctx: Ctx,
                            _ reload: @escaping () async -> Void) -> Binding<String> {
        Binding(get: { vals[key]?.description ?? def },
                set: { new in Task { await update(ctx, key, new, reload) } })
    }

    private func boolBinding(_ key: String, _ vals: [String: JSONValue], _ ctx: Ctx,
                             _ reload: @escaping () async -> Void) -> Binding<Bool> {
        Binding(get: { vals[key]?.description == "on" },
                set: { on in Task { await update(ctx, key, on ? "on" : "off", reload) } })
    }
}

struct PurgeURLsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSubmit: ([String]) async throws -> Void
    @State private var text = ""
    @State private var running = false
    @State private var error: String?

    private var urls: [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("http") }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(8)
                Text("已识别 \(urls.count) 个 URL").font(.caption).foregroundColor(.secondary).padding(8)
            }
            .navigationTitle("按 URL 清除缓存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(running ? "提交中…" : "清除") { Task { await run() } }
                        .disabled(running || urls.isEmpty)
                }
            }
            .errorAlert($error)
        }
    }

    private func run() async {
        running = true
        defer { running = false }
        do {
            try await onSubmit(Array(urls.prefix(30)))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Workers 路由

struct WorkerRoute: Decodable, Identifiable {
    let id: String
    let pattern: String
    let script: String?
}

private struct WorkerRouteBody: Encodable {
    let pattern: String
    let script: String?
}

struct WorkerRoutesData {
    var routes: [WorkerRoute]
    var scripts: [String]
}

struct WorkerRoutesView: View {
    @EnvironmentObject var session: Session
    let zone: Zone
    @State private var editing: RouteTarget?
    @State private var error: String?

    struct RouteTarget: Identifiable {
        let id = UUID()
        let route: WorkerRoute?
    }

    var body: some View {
        let ctx = session.ctx
        let zid = zone.id
        LoadView(load: { () async throws -> WorkerRoutesData in
            let routes: [WorkerRoute] = try await ctx.c.get("zones/\(zid)/workers/routes")
            let scripts: [WorkerScript]? = try? await ctx.c.get("accounts/\(ctx.acc)/workers/scripts")
            return WorkerRoutesData(routes: routes, scripts: (scripts ?? []).map { $0.id })
        }) { data, reload in
            List {
                ForEach(data.routes) { r in
                    Button { editing = RouteTarget(route: r) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.pattern).font(.system(.subheadline, design: .monospaced))
                            Text(r.script.map { "→ \($0)" } ?? "未绑定 Worker（直接放行）")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.primary)
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            Task {
                                do {
                                    try await ctx.c.delete("zones/\(zid)/workers/routes/\(r.id)")
                                    await reload()
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
            }
            .overlay { if data.routes.isEmpty { EmptyHint(text: "没有 Workers 路由") } }
            .refreshable { await reload() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { editing = RouteTarget(route: nil) } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { t in
                RouteEditSheet(route: t.route, scripts: data.scripts, zoneName: zone.name) { pattern, script in
                    let body = WorkerRouteBody(pattern: pattern, script: script)
                    if let r = t.route {
                        try await ctx.c.send("PUT", "zones/\(zid)/workers/routes/\(r.id)", json: body)
                    } else {
                        try await ctx.c.send("POST", "zones/\(zid)/workers/routes", json: body)
                    }
                    await reload()
                }
            }
        }
        .navigationTitle("Workers 路由")
        .errorAlert($error)
    }
}

struct RouteEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let route: WorkerRoute?
    let scripts: [String]
    let zoneName: String
    let onSave: (String, String?) async throws -> Void

    @State private var pattern: String
    @State private var script: String
    @State private var saving = false
    @State private var error: String?

    init(route: WorkerRoute?, scripts: [String], zoneName: String,
         onSave: @escaping (String, String?) async throws -> Void) {
        self.route = route
        self.scripts = scripts
        self.zoneName = zoneName
        self.onSave = onSave
        _pattern = State(initialValue: route?.pattern ?? "")
        _script = State(initialValue: route?.script ?? scripts.first ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("例如 \(zoneName)/* 或 api.\(zoneName)/v1/*。")) {
                    TextField("路由模式", text: $pattern)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Worker", selection: $script) {
                        Text("无（该路径不经过 Worker）").tag("")
                        ForEach(scripts, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            .navigationTitle(route == nil ? "添加路由" : "编辑路由")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") { Task { await save() } }
                        .disabled(saving || pattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .errorAlert($error)
        }
        .presentationDetents([.medium])
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await onSave(pattern.trimmingCharacters(in: .whitespaces), script.isEmpty ? nil : script)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
