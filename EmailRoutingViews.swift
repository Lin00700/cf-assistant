import SwiftUI

struct EmailRoutingData {
    var settings: JSONValue?
    var rules: [JSONValue]
    var addresses: [JSONValue]
    var catchAll: JSONValue?
}

struct EmailRoutingView: View {
    @EnvironmentObject var session: Session
    let zone: Zone
    @State private var addingRule = false
    @State private var addingAddress = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        let ctx = session.ctx
        let zid = zone.id
        LoadView(load: { () async throws -> EmailRoutingData in
            let settings: JSONValue? = try? await ctx.c.get("zones/\(zid)/email/routing")
            let rules: [JSONValue] = (try? await ctx.c.get("zones/\(zid)/email/routing/rules",
                                                           query: ["per_page": "50"])) ?? []
            let addrs: [JSONValue] = (try? await ctx.c.get("accounts/\(ctx.acc)/email/routing/addresses",
                                                           query: ["per_page": "50"])) ?? []
            let catchAll: JSONValue? = try? await ctx.c.get("zones/\(zid)/email/routing/rules/catch_all")
            return EmailRoutingData(settings: settings, rules: rules, addresses: addrs, catchAll: catchAll)
        }) { data, reload in
            let enabled = data.settings?["enabled"]?.description == "true"
            let verified = data.addresses.filter { $0["verified"] != nil && $0["verified"]?.description != "NULL" }
                .compactMap { $0["email"]?.description }
            let customRules = data.rules.filter { r in
                (r["matchers"]?.array ?? []).contains { $0["type"]?.description == "literal" }
            }

            List {
                Section(header: Text("状态"),
                        footer: Text("首次启用会自动添加所需的 MX 和 SPF 记录，需要这个域名的 DNS 由 Cloudflare 托管。")) {
                    LabeledContent("邮件路由", value: enabled ? "已启用" : "未启用")
                    Button(enabled ? "停用" : "启用", role: enabled ? .destructive : nil) {
                        Task {
                            do {
                                try await ctx.c.send("POST", "zones/\(zid)/email/routing/\(enabled ? "disable" : "enable")",
                                                     json: [String: String]())
                                await reload()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }

                Section(header: Text("目标地址"),
                        footer: Text("目标地址需要先点击邮件里的验证链接才能用于转发。")) {
                    ForEach(Array(data.addresses.enumerated()), id: \.offset) { _, a in
                        let email = a["email"]?.description ?? ""
                        let ok = (a["verified"]?.description ?? "NULL") != "NULL"
                        HStack {
                            Text(email).font(.subheadline)
                            Spacer()
                            Text(ok ? "已验证" : "待验证").font(.caption)
                                .foregroundColor(ok ? .green : .orange)
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                Task {
                                    do {
                                        let tag = a["tag"]?.description ?? ""
                                        try await ctx.c.delete("accounts/\(ctx.acc)/email/routing/addresses/\(tag)")
                                        await reload()
                                    } catch { self.error = error.localizedDescription }
                                }
                            }
                        }
                    }
                    Button { addingAddress = true } label: { Label("添加目标地址", systemImage: "plus") }
                }

                Section("转发规则（\(customRules.count)）") {
                    ForEach(Array(customRules.enumerated()), id: \.offset) { _, r in
                        let tag = r["tag"]?.description ?? ""
                        let from = (r["matchers"]?.array ?? []).first?["value"]?.description ?? ""
                        let to = (r["actions"]?.array ?? []).first.map { Self.actionText($0) } ?? ""
                        VStack(alignment: .leading, spacing: 3) {
                            Toggle(isOn: Binding(
                                get: { r["enabled"]?.description == "true" },
                                set: { on in
                                    Task {
                                        do {
                                            try await Self.putRule(ctx, zid, tag, r, enabled: on)
                                            await reload()
                                        } catch { self.error = error.localizedDescription; await reload() }
                                    }
                                })) {
                                Text(from).font(.subheadline.bold())
                            }
                            Text("→ \(to)").font(.caption).foregroundColor(.secondary)
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                Task {
                                    do {
                                        try await ctx.c.delete("zones/\(zid)/email/routing/rules/\(tag)")
                                        await reload()
                                    } catch { self.error = error.localizedDescription }
                                }
                            }
                        }
                    }
                    Button { addingRule = true } label: { Label("添加转发规则", systemImage: "plus") }
                        .disabled(verified.isEmpty)
                    if verified.isEmpty {
                        Text("先添加并验证至少一个目标地址").font(.footnote).foregroundColor(.secondary)
                    }
                }

                Section(header: Text("兜底规则"), footer: Text("没有匹配到任何规则的邮件会走这里。")) {
                    let ce = data.catchAll?["enabled"]?.description == "true"
                    let act = (data.catchAll?["actions"]?.array ?? []).first
                    LabeledContent("当前", value: ce ? (act.map { Self.actionText($0) } ?? "-") : "已停用")
                    Menu("修改兜底规则") {
                        Button("停用") {
                            Task { await setCatchAll(ctx, zid, enabled: false, type: "drop", dest: nil, reload) }
                        }
                        Button("丢弃") {
                            Task { await setCatchAll(ctx, zid, enabled: true, type: "drop", dest: nil, reload) }
                        }
                        ForEach(verified, id: \.self) { email in
                            Button("转发到 \(email)") {
                                Task { await setCatchAll(ctx, zid, enabled: true, type: "forward", dest: email, reload) }
                            }
                        }
                    }
                }
            }
            .refreshable { await reload() }
            .sheet(isPresented: $addingAddress) {
                EmailAddressSheet { email in
                    try await ctx.c.send("POST", "accounts/\(ctx.acc)/email/routing/addresses", json: ["email": email])
                    message = "已发送验证邮件到 \(email)，点击邮件中的链接后即可使用"
                    await reload()
                }
            }
            .sheet(isPresented: $addingRule) {
                EmailRuleSheet(zoneName: zone.name, destinations: verified) { local, dest in
                    let addr = "\(local)@\(zone.name)"
                    let body = JSONValue.object([
                        "name": .string("转发 \(addr)"),
                        "enabled": .bool(true),
                        "matchers": .array([.object(["type": .string("literal"), "field": .string("to"),
                                                     "value": .string(addr)])]),
                        "actions": .array([.object(["type": .string("forward"),
                                                    "value": .array([.string(dest)])])])
                    ])
                    try await ctx.c.send("POST", "zones/\(zid)/email/routing/rules", json: body)
                    await reload()
                }
            }
        }
        .navigationTitle("邮件路由")
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { _ in })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
        .errorAlert($error)
    }

    static func actionText(_ a: JSONValue) -> String {
        let t = a["type"]?.description ?? ""
        if t == "drop" { return "丢弃" }
        if t == "worker" { return "Worker \((a["value"]?.array.first?.description) ?? "")" }
        let dest = (a["value"]?.array ?? []).map { $0.description }.joined(separator: ", ")
        return "转发到 \(dest)"
    }

    static func putRule(_ ctx: Ctx, _ zid: String, _ tag: String, _ rule: JSONValue, enabled: Bool) async throws {
        var o: [String: JSONValue] = [:]
        for k in ["name", "matchers", "actions", "priority"] {
            if let v = rule[k] { o[k] = v }
        }
        o["enabled"] = .bool(enabled)
        try await ctx.c.send("PUT", "zones/\(zid)/email/routing/rules/\(tag)", json: JSONValue.object(o))
    }

    private func setCatchAll(_ ctx: Ctx, _ zid: String, enabled: Bool, type: String, dest: String?,
                             _ reload: @escaping () async -> Void) async {
        var action: [String: JSONValue] = ["type": .string(type)]
        if let d = dest { action["value"] = .array([.string(d)]) }
        let body = JSONValue.object([
            "enabled": .bool(enabled),
            "name": .string("兜底规则"),
            "matchers": .array([.object(["type": .string("all")])]),
            "actions": .array([.object(action)])
        ])
        do {
            try await ctx.c.send("PUT", "zones/\(zid)/email/routing/rules/catch_all", json: body)
        } catch { self.error = error.localizedDescription }
        await reload()
    }
}

struct EmailAddressSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSubmit: (String) async throws -> Void
    @State private var email = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("Cloudflare 会向这个邮箱发送验证邮件。")) {
                    TextField("收件邮箱，例如 me@gmail.com", text: $email)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                }
            }
            .navigationTitle("添加目标地址")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "提交中…" : "添加") { Task { await go() } }
                        .disabled(saving || !email.contains("@"))
                }
            }
            .errorAlert($error)
        }
        .presentationDetents([.medium])
    }

    private func go() async {
        saving = true
        defer { saving = false }
        do {
            try await onSubmit(email.trimmingCharacters(in: .whitespaces).lowercased())
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct EmailRuleSheet: View {
    @Environment(\.dismiss) private var dismiss
    let zoneName: String
    let destinations: [String]
    let onSubmit: (String, String) async throws -> Void
    @State private var local = ""
    @State private var dest = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("自定义地址")) {
                    HStack {
                        TextField("名称", text: $local)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("@\(zoneName)").foregroundColor(.secondary)
                    }
                }
                Section("转发到") {
                    Picker("目标地址", selection: $dest) {
                        ForEach(destinations, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            .navigationTitle("添加转发规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") { Task { await go() } }
                        .disabled(saving || local.trimmingCharacters(in: .whitespaces).isEmpty || dest.isEmpty)
                }
            }
            .onAppear { if dest.isEmpty { dest = destinations.first ?? "" } }
            .errorAlert($error)
        }
        .presentationDetents([.medium])
    }

    private func go() async {
        saving = true
        defer { saving = false }
        do {
            try await onSubmit(local.trimmingCharacters(in: .whitespaces).lowercased(), dest)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
