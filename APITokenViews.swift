import SwiftUI

struct APITokensData {
    var tokens: [JSONValue]
    var verify: JSONValue?
}

struct APITokensView: View {
    @EnvironmentObject var session: Session
    @State private var creating = false
    @State private var shownToken: String?
    @State private var detail: TokenDetailItem?
    @State private var error: String?

    var body: some View {
        let ctx = session.ctx
        LoadView(load: { () async throws -> APITokensData in
            let tokens: [JSONValue] = try await ctx.c.get("user/tokens", query: ["per_page": "50"])
            let verify: JSONValue? = try? await ctx.c.get("user/tokens/verify")
            return APITokensData(tokens: tokens, verify: verify)
        }) { data, reload in
            List {
                if let v = data.verify {
                    Section("当前登录凭据") {
                        LabeledContent("状态", value: v["status"]?.description ?? "-")
                        if let e = v["expires_on"]?.description, e != "NULL" {
                            LabeledContent("到期", value: String(e.prefix(10)))
                        }
                    }
                }
                Section(header: Text("Token（\(data.tokens.count)）"),
                        footer: Text("管理 Token 需要当前凭据有“API 令牌：编辑”权限，或使用邮箱 + Global Key 登录。")) {
                    ForEach(Array(data.tokens.enumerated()), id: \.offset) { _, t in
                        let id = t["id"]?.description ?? ""
                        Button { detail = TokenDetailItem(token: t) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(t["name"]?.description ?? "").font(.headline)
                                    Spacer()
                                    Text(t["status"]?.description == "active" ? "有效" : (t["status"]?.description ?? ""))
                                        .font(.caption)
                                        .foregroundColor(t["status"]?.description == "active" ? .green : .orange)
                                }
                                if let e = t["expires_on"]?.description, e != "NULL" {
                                    Text("到期 \(e.prefix(10))").font(.caption).foregroundColor(.secondary)
                                } else {
                                    Text("永不过期").font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                        .foregroundColor(.primary)
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                Task {
                                    do {
                                        try await ctx.c.delete("user/tokens/\(id)")
                                        await reload()
                                    } catch { self.error = error.localizedDescription }
                                }
                            }
                            Button("重新生成") {
                                Task {
                                    do {
                                        let v: String = try await ctx.c.request(
                                            "PUT", "user/tokens/\(id)/value", body: Data("{}".utf8))
                                        shownToken = v
                                    } catch { self.error = error.localizedDescription }
                                }
                            }.tint(.orange)
                        }
                    }
                }
            }
            .refreshable { await reload() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $creating) {
                APITokenCreateView { value in
                    shownToken = value
                    Task { await reload() }
                }
            }
            .sheet(item: $detail) { item in
                APITokenDetailView(token: item.token)
            }
        }
        .navigationTitle("API Token")
        .alert("请立即保存 Token", isPresented: Binding(get: { shownToken != nil }, set: { _ in })) {
            Button("复制") {
                UIPasteboard.general.string = shownToken
                shownToken = nil
            }
            Button("关闭", role: .cancel) { shownToken = nil }
        } message: {
            Text("Token 只显示这一次：\n\(shownToken ?? "")")
        }
        .errorAlert($error)
    }
}

struct TokenDetailItem: Identifiable {
    let id = UUID()
    let token: JSONValue
}

struct APITokenDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let token: JSONValue

    var body: some View {
        NavigationStack {
            List {
                Section("信息") {
                    LabeledContent("名称", value: token["name"]?.description ?? "-")
                    LabeledContent("状态", value: token["status"]?.description ?? "-")
                    if let i = token["issued_on"]?.description, i != "NULL" {
                        LabeledContent("创建", value: String(i.prefix(10)))
                    }
                }
                ForEach(Array((token["policies"]?.array ?? []).enumerated()), id: \.offset) { idx, p in
                    Section("权限策略 \(idx + 1)（\(p["effect"]?.description == "allow" ? "允许" : "拒绝")）") {
                        ForEach(Array((p["permission_groups"]?.array ?? []).enumerated()), id: \.offset) { _, g in
                            Text(g["name"]?.description ?? "").font(.subheadline)
                        }
                        ForEach(p["resources"]?.object.keys.sorted() ?? [], id: \.self) { k in
                            Text(k).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Token 详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

// MARK: - 创建

struct PermGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let isZone: Bool
}

struct APITokenCreateView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let onCreated: (String) -> Void

    @State private var name = ""
    @State private var groups: [PermGroup] = []
    @State private var selected = Set<String>()
    @State private var search = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    private var filtered: [PermGroup] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? groups : groups.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section(footer: Text("账户级权限作用于当前账户，区域级权限作用于所有域名。")) {
                    TextField("Token 名称", text: $name)
                }
                Section("权限（已选 \(selected.count)）") {
                    if loading { ProgressView() }
                    ForEach(filtered) { g in
                        Button {
                            if selected.contains(g.id) { selected.remove(g.id) } else { selected.insert(g.id) }
                        } label: {
                            HStack {
                                Text(g.name).font(.subheadline).foregroundColor(.primary)
                                Spacer()
                                Text(g.isZone ? "区域" : "账户").font(.caption2).foregroundColor(.secondary)
                                if selected.contains(g.id) {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.orange)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "搜索权限，例如 Workers、DNS")
            .navigationTitle("创建 Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "创建中…" : "创建") { Task { await create() } }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || selected.isEmpty)
                }
            }
            .task { await load() }
            .errorAlert($error)
        }
    }

    private func load() async {
        let ctx = session.ctx
        do {
            let list: [JSONValue] = try await ctx.c.get("user/tokens/permission_groups")
            var out: [PermGroup] = []
            for g in list {
                guard let id = g["id"]?.description, let n = g["name"]?.description else { continue }
                let scopes = (g["scopes"]?.array ?? []).map { $0.description }
                let zone = scopes.contains("com.cloudflare.api.account.zone")
                let account = scopes.contains("com.cloudflare.api.account")
                if zone || account { out.append(PermGroup(id: id, name: n, isZone: zone && !account)) }
            }
            groups = out.sorted { $0.name < $1.name }
        } catch { self.error = error.localizedDescription }
        loading = false
    }

    private func create() async {
        saving = true
        defer { saving = false }
        let ctx = session.ctx
        let chosen = groups.filter { selected.contains($0.id) }
        func policy(_ gs: [PermGroup], _ resources: JSONValue) -> JSONValue {
            .object(["effect": .string("allow"),
                     "resources": resources,
                     "permission_groups": .array(gs.map { .object(["id": .string($0.id)]) })])
        }
        var policies: [JSONValue] = []
        let acct = chosen.filter { !$0.isZone }
        let zone = chosen.filter { $0.isZone }
        if !acct.isEmpty {
            policies.append(policy(acct, .object(["com.cloudflare.api.account.\(ctx.acc)": .string("*")])))
        }
        if !zone.isEmpty {
            policies.append(policy(zone, .object(["com.cloudflare.api.account.zone.*": .string("*")])))
        }
        let body = JSONValue.object(["name": .string(name.trimmingCharacters(in: .whitespaces)),
                                     "policies": .array(policies)])
        do {
            let res: JSONValue = try await ctx.c.send("POST", "user/tokens", json: body)
            if let v = res["value"]?.description, v != "NULL" {
                onCreated(v)
                dismiss()
            } else {
                self.error = "已创建，但没有返回 Token 值"
            }
        } catch { self.error = error.localizedDescription }
    }
}
