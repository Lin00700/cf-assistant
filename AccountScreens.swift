import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct AccountHomeView: View {
    @EnvironmentObject var session: Session
    @State private var account: JSONValue = .null
    @State private var user: JSONValue = .null
    @State private var verify: JSONValue = .null
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        List {
            Section("账户") {
                LabeledContent("名称", value: account["name"]?.string ?? session.accounts.first { $0.id == session.accountId }?.name ?? "")
                Button("复制账户 ID") { UIPasteboard.general.string = session.accountId }
                if let created = account["created_on"]?.string {
                    LabeledContent("创建于", value: String(created.prefix(19)))
                }
            }
            Section("用户") {
                if let email = user["email"]?.string { LabeledContent("邮箱", value: email) }
                if let name = user["username"]?.string ?? user["name"]?.string { LabeledContent("用户", value: name) }
                if let status = verify["status"]?.string { LabeledContent("令牌状态", value: status) }
            }
            Section("管理") {
                NavigationLink("成员") { MembersView() }
                NavigationLink("账单") { BillingOverviewView() }
                NavigationLink("审计日志") { AuditLogView() }
                NavigationLink("通知策略") { AlertPoliciesView() }
                NavigationLink("API Token") { APITokensView() }
                NavigationLink("账户 IP 规则") { IPAccessRulesView(zoneID: nil) }
            }
            if let error {
                Section { Text(error).font(.footnote).foregroundColor(.secondary) }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("账户")
        .refreshable { await load() }
        .overlay { if !loaded { ProgressView() } }
        .task { await load() }
    }

    private func load() async {
        let ctx = session.ctx
        account = (try? await ctx.c.resultValue("GET", "accounts/\(ctx.acc)")) ?? .null
        user = (try? await ctx.c.resultValue("GET", "user")) ?? .null
        verify = (try? await ctx.c.resultValue("GET", "user/tokens/verify")) ?? .null
        if account.isNull && user.isNull {
            error = "读不到账户资料。Global API Key 通常可以，Token 需要账户读取权限。"
        } else {
            error = nil
        }
        loaded = true
    }
}

struct MembersView: View {
    @EnvironmentObject var session: Session
    @State private var members: [JSONValue] = []
    @State private var roles: [JSONValue] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var inviting = false

    var body: some View {
        List {
            ForEach(Array(members.enumerated()), id: \.offset) { _, member in
                VStack(alignment: .leading, spacing: 3) {
                    Text(member["email"]?.string ?? member["user"]?["email"]?.string ?? "成员").font(.headline)
                    Text(roleLine(member)).font(.caption).foregroundColor(.secondary)
                }
                .swipeActions {
                    Button("移除", role: .destructive) {
                        guard let id = member["id"]?.string else { return }
                        Task { await remove(id) }
                    }
                }
            }
        }
        .navigationTitle("成员")
        .overlay { if !loaded { ProgressView() } else if members.isEmpty && error == nil { EmptyHint(text: "没有成员") } }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { inviting = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $inviting) {
            MemberInviteSheet(roles: roles) { Task { await load() } }
        }
        .refreshable { await load() }
        .task { await load() }
        .errorAlert($error)
    }

    private func roleLine(_ member: JSONValue) -> String {
        let names = member["roles"]?.array.compactMap { $0["name"]?.string } ?? []
        let status = member["status"]?.string ?? ""
        return ([status] + names).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func load() async {
        let ctx = session.ctx
        do {
            members = jsonItems(try await ctx.c.resultValue("GET", "accounts/\(ctx.acc)/members"))
            if let value = try? await ctx.c.resultValue("GET", "accounts/\(ctx.acc)/roles") {
                roles = jsonItems(value)
            }
            error = nil
        } catch { if members.isEmpty { self.error = error.localizedDescription } }
        loaded = true
    }

    private func remove(_ id: String) async {
        do {
            try await session.ctx.c.deleteLoose("accounts/\(session.ctx.acc)/members/\(cfEncode(id))")
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

struct MemberInviteSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let roles: [JSONValue]
    var onDone: () -> Void
    @State private var email = ""
    @State private var roleID = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("邮箱", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                if roles.isEmpty {
                    Text("没有读到可分配的角色。邀请可能失败。").font(.footnote).foregroundColor(.secondary)
                } else {
                    Picker("角色", selection: $roleID) {
                        Text("请选择").tag("")
                        ForEach(roles, id: \.description) { role in
                            Text(role["name"]?.string ?? "角色").tag(role["id"]?.string ?? "")
                        }
                    }
                }
                if let error { Text(error).foregroundColor(.red).font(.footnote) }
            }
            .navigationTitle("邀请成员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("邀请") { Task { await go() } }.disabled(email.isEmpty || roleID.isEmpty)
                }
            }
        }
    }

    private func go() async {
        let body: [String: Any] = ["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "roles": [roleID]]
        do {
            _ = try await session.ctx.c.resultValue("POST", "accounts/\(session.ctx.acc)/members", body: try jsonBody(body))
            onDone(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct AuditLogView: View {
    @EnvironmentObject var session: Session
    @State private var items: [JSONValue] = []
    @State private var page = 1
    @State private var query = ""
    @State private var loaded = false
    @State private var error: String?
    @State private var canMore = false

    private var filtered: [JSONValue] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return items }
        return items.filter { auditText($0).lowercased().contains(q) }
    }

    var body: some View {
        List {
            ForEach(Array(filtered.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item["action"]?["type"]?.string ?? "事件").font(.headline)
                    Text(auditText(item)).font(.caption).foregroundColor(.secondary).lineLimit(3)
                }
            }
            if canMore {
                Button("加载更多") { Task { await load(reset: false) } }
            }
        }
        .navigationTitle("审计日志")
        .searchable(text: $query, prompt: "搜索动作、邮箱、资源")
        .overlay { if !loaded { ProgressView() } else if filtered.isEmpty && error == nil { EmptyHint(text: "没有审计记录") } }
        .refreshable { await load(reset: true) }
        .task { await load(reset: true) }
        .errorAlert($error)
    }

    private func auditText(_ item: JSONValue) -> String {
        let email = item["actor"]?["email"]?.string ?? ""
        let ip = item["actor"]?["ip"]?.string ?? ""
        let when = String((item["when"]?.string ?? "").prefix(19))
        let resource = item["resource"]?["type"]?.string ?? ""
        return [when, email, ip, resource].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func load(reset: Bool) async {
        let next = reset ? 1 : page + 1
        do {
            let value = try await session.ctx.c.resultValue(
                "GET", "accounts/\(session.ctx.acc)/audit_logs",
                query: ["per_page": "50", "page": String(next), "direction": "desc"])
            let batch = jsonItems(value)
            if reset { items = batch } else { items.append(contentsOf: batch) }
            page = next
            canMore = batch.count >= 50
            error = nil
        } catch { if items.isEmpty { self.error = error.localizedDescription } }
        loaded = true
    }
}

struct AlertPoliciesView: View {
    @EnvironmentObject var session: Session
    @State private var policies: [JSONValue] = []
    @State private var overrides: [String: Bool] = [:]
    @State private var loaded = false
    @State private var error: String?
    @State private var creating = false

    var body: some View {
        List {
            ForEach(Array(policies.enumerated()), id: \.offset) { _, item in
                let id = item["id"]?.string ?? ""
                Toggle(isOn: Binding(
                    get: { overrides[id] ?? (item["enabled"]?.bool ?? false) },
                    set: { value in
                        var copy = overrides
                        copy[id] = value
                        overrides = copy
                        Task { await setEnabled(item, value) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item["name"]?.string ?? "策略")
                        Text(item["alert_type"]?.string ?? "").font(.caption).foregroundColor(.secondary)
                    }
                }
                .swipeActions {
                    Button("删除", role: .destructive) { Task { await remove(id) } }
                }
            }
        }
        .navigationTitle("通知")
        .overlay { if !loaded { ProgressView() } else if policies.isEmpty && error == nil { EmptyHint(text: "没有通知策略") } }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $creating) { AlertCreateSheet { Task { await load() } } }
        .refreshable { await load() }
        .task { await load() }
        .errorAlert($error)
    }

    private func load() async {
        do {
            policies = jsonItems(try await session.ctx.c.resultValue("GET", "accounts/\(session.ctx.acc)/alerting/v3/policies"))
            overrides = [:]
            error = nil
        } catch { if policies.isEmpty { self.error = error.localizedDescription } }
        loaded = true
    }

    private func setEnabled(_ item: JSONValue, _ on: Bool) async {
        guard let id = item["id"]?.string else { return }
        var obj = jsonObject(item)
        obj["enabled"] = on
        obj.removeValue(forKey: "id")
        do {
            _ = try await session.ctx.c.resultValue(
                "PATCH", "accounts/\(session.ctx.acc)/alerting/v3/policies/\(cfEncode(id))",
                body: try jsonBody(obj))
            await load()
        } catch {
            var copy = overrides
            copy.removeValue(forKey: id)
            overrides = copy
            self.error = error.localizedDescription
        }
    }

    private func remove(_ id: String) async {
        guard !id.isEmpty else { return }
        do {
            try await session.ctx.c.deleteLoose("accounts/\(session.ctx.acc)/alerting/v3/policies/\(cfEncode(id))")
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

struct AlertOpt: Identifiable, Hashable {
    let id: String
    let name: String
}

struct AlertCreateSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    var onDone: () -> Void
    @State private var name = ""
    @State private var type = ""
    @State private var options: [AlertOpt] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("策略名称", text: $name)
                if options.isEmpty {
                    TextField("alert_type", text: $type).textInputAutocapitalization(.never).autocorrectionDisabled()
                } else {
                    Picker("类型", selection: $type) {
                        Text("请选择").tag("")
                        ForEach(options) { opt in Text(opt.name).tag(opt.id) }
                    }
                }
                Text("过滤条件和通知渠道如果接口要求更完整的字段，错误会直接显示。能读到邮箱目的地时会自动附上。")
                    .font(.footnote).foregroundColor(.secondary)
                if let error { Text(error).foregroundColor(.red).font(.footnote) }
            }
            .navigationTitle("新建通知")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { Task { await go() } }.disabled(name.isEmpty || type.isEmpty)
                }
            }
            .task { await loadTypes() }
        }
    }

    private func loadTypes() async {
        guard let value = try? await session.ctx.c.resultValue("GET", "accounts/\(session.ctx.acc)/alerting/v3/available_alerts") else { return }
        let rows = jsonItems(value)
        if !rows.isEmpty {
            options = rows.compactMap { item in
                let id = item["type"]?.string ?? item["alert_type"]?.string ?? item["id"]?.string
                guard let id, !id.isEmpty else { return nil }
                return AlertOpt(id: id, name: item["display_name"]?.string ?? item["name"]?.string ?? id)
            }
        } else {
            options = value.object.keys.sorted().map { AlertOpt(id: $0, name: $0) }
        }
        if type.isEmpty { type = options.first?.id ?? "" }
    }

    private func go() async {
        let ctx = session.ctx
        var body: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "alert_type": type,
            "enabled": true,
            "filters": [:] as [String: Any],
            "description": "由 CF 助手创建"
        ]
        if let dest = try? await ctx.c.resultValue("GET", "accounts/\(ctx.acc)/alerting/v3/destinations") {
            let ids = (dest["email"]?.array ?? []).compactMap { $0["id"]?.string }
            if !ids.isEmpty {
                body["mechanisms"] = ["email": ids.map { ["id": $0] }]
            }
        }
        do {
            _ = try await ctx.c.resultValue("POST", "accounts/\(ctx.acc)/alerting/v3/policies", body: try jsonBody(body))
            onDone(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct BillingOverviewView: View {
    @EnvironmentObject var session: Session
    @State private var profile: JSONValue = .null
    @State private var subs: [JSONValue] = []
    @State private var profileError: String?
    @State private var subError: String?
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                if let profileError {
                    Text(profileError).font(.footnote).foregroundColor(.secondary)
                } else {
                    ForEach(profileRows, id: \.0) { row in
                        LabeledContent(row.0) { Text(row.1).font(.footnote).textSelection(.enabled).multilineTextAlignment(.trailing) }
                    }
                }
            } header: { Text("资料") } footer: {
                Text("支付方式的增删和发票 PDF 不在公开 API 里，这里只展示账户能读到的订阅和账单资料。")
            }
            Section("订阅") {
                if let subError { Text(subError).font(.footnote).foregroundColor(.secondary) }
                ForEach(Array(subs.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item["rate_plan"]?["public_name"]?.string ?? item["product"]?["name"]?.string ?? "订阅")
                            .font(.headline)
                        Text(subLine(item)).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("账单")
        .overlay { if !loaded { ProgressView() } }
        .refreshable { await load() }
        .task { await load() }
    }

    private var profileRows: [(String, String)] { flatten(profile) }

    private func flatten(_ value: JSONValue, prefix: String = "") -> [(String, String)] {
        var out: [(String, String)] = []
        for key in value.object.keys.sorted() {
            let child = value[key] ?? .null
            let name = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let s = child.string, !s.isEmpty { out.append((name, s)) }
            else if prefix.isEmpty, !child.object.isEmpty { out.append(contentsOf: flatten(child, prefix: key)) }
        }
        return out
    }

    private func subLine(_ item: JSONValue) -> String {
        let state = item["state"]?.string ?? ""
        let price = item["price"]?.string ?? ""
        let currency = item["currency"]?.string ?? ""
        let end = String((item["current_period_end"]?.string ?? "").prefix(10))
        return [state, price, currency, end].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func load() async {
        let ctx = session.ctx
        do { profile = try await ctx.c.resultValue("GET", "accounts/\(ctx.acc)/billing/profile"); profileError = nil }
        catch { profileError = error.localizedDescription }
        do { subs = jsonItems(try await ctx.c.resultValue("GET", "accounts/\(ctx.acc)/subscriptions")); subError = nil }
        catch { subError = error.localizedDescription }
        loaded = true
    }
}

struct ScriptStat: Identifiable {
    var id: String { name }
    var name: String
    var requests: Double
    var errors: Double
}

struct WorkersAnalyticsView: View {
    @EnvironmentObject var session: Session
    @State private var stats: [ScriptStat] = []
    @State private var range = "day"
    @State private var loaded = false
    @State private var error: String?

    private var maxReq: Double { max(stats.map(\.requests).max() ?? 1, 1) }

    var body: some View {
        List {
            Picker("范围", selection: $range) {
                Text("今日").tag("day")
                Text("7 日").tag("week")
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            if let error { Text(error).font(.footnote).foregroundColor(.red) }
            ForEach(stats) { stat in
                NavigationLink {
                    WorkerDetailView(name: stat.name) {}
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(stat.name).font(.headline)
                        Text("请求 \(formatCount(stat.requests)) · 错误 \(formatCount(stat.errors))")
                            .font(.caption).foregroundColor(.secondary)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(InkTheme.seal.opacity(0.85))
                                .frame(width: max(4, geo.size.width * stat.requests / maxReq))
                        }
                        .frame(height: 8)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Workers 分析")
        .overlay { if !loaded { ProgressView() } else if stats.isEmpty && error == nil { EmptyHint(text: "这段时间没有调用") } }
        .refreshable { await load() }
        .task(id: range) { await load() }
    }

    private func load() async {
        let ctx = session.ctx
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()
        let start = range == "week" ? now.addingTimeInterval(-7 * 86400) : cal.startOfDay(for: now)
        let iso = ISO8601DateFormatter()
        let vars = ["acc": ctx.acc, "start": iso.string(from: start), "end": iso.string(from: now)]
        do {
            stats = try await query(ctx, vars, withErrors: true)
            error = nil
        } catch {
            do { stats = try await query(ctx, vars, withErrors: false); error = nil }
            catch { self.error = error.localizedDescription }
        }
        loaded = true
    }

    private func query(_ ctx: Ctx, _ vars: [String: String], withErrors: Bool) async throws -> [ScriptStat] {
        let sum = withErrors ? "requests errors" : "requests"
        let value = try await ctx.c.graphql("""
        query($acc: String!, $start: Time!, $end: Time!) {
          viewer { accounts(filter: {accountTag: $acc}) {
            workersInvocationsAdaptiveGroups(limit: 10000, filter: {datetime_geq: $start, datetime_leq: $end}) {
              dimensions { scriptName }
              sum { \(sum) }
            }
          } }
        }
        """, variables: vars)
        let rows = value["data"]?["viewer"]?["accounts"]?[0]?["workersInvocationsAdaptiveGroups"]?.array ?? []
        var map: [String: ScriptStat] = [:]
        for row in rows {
            let name = row["dimensions"]?["scriptName"]?.string ?? "(unknown)"
            let req = row["sum"]?["requests"]?.number ?? 0
            let err = row["sum"]?["errors"]?.number ?? 0
            var stat = map[name] ?? ScriptStat(name: name, requests: 0, errors: 0)
            stat.requests += req
            stat.errors += err
            map[name] = stat
        }
        return map.values.sorted { $0.requests > $1.requests }
    }
}

struct WorkersAIView: View {
    @EnvironmentObject var session: Session
    @State private var model = "@cf/meta/llama-3.1-8b-instruct"
    @State private var prompt = ""
    @State private var output = ""
    @State private var busy = false
    @State private var error: String?

    private let presets = [
        "@cf/meta/llama-3.1-8b-instruct",
        "@cf/meta/llama-3.2-3b-instruct",
        "@cf/mistral/mistral-7b-instruct-v0.2",
        "@cf/google/gemma-2-9b-it"
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("模型", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                Menu("常用模型") {
                    ForEach(presets, id: \.self) { item in Button(item) { model = item } }
                }
                NavigationLink("浏览账户模型目录") { RemoteListView(source: .account(.aiModels)) }
            }
            .frame(height: 220)
            TextEditor(text: $prompt)
                .padding(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3)))
                .padding(.horizontal)
                .frame(minHeight: 100, maxHeight: 140)
            Button { Task { await run() } } label: {
                if busy { ProgressView() } else { Label("运行", systemImage: "play.fill") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.top, 8)
            if let error { Text(error).font(.footnote).foregroundColor(.red).padding(.horizontal) }
            ScrollView {
                Text(output.isEmpty ? "结果会显示在这里。" : output)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
        }
        .navigationTitle("Workers AI")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run() async {
        busy = true
        defer { busy = false }
        error = nil
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any] = ["messages": [["role": "user", "content": prompt]]]
        do {
            let value = try await session.ctx.c.resultValue(
                "POST", "accounts/\(session.ctx.acc)/ai/run/\(name)", body: try jsonBody(body))
            output = value["response"]?.string ?? value["result"]?["response"]?.string ?? value["text"]?.string ?? jsonPretty(value)
        } catch { self.error = error.localizedDescription }
    }
}

struct ImagesBrowserView: View {
    @EnvironmentObject var session: Session
    @State private var images: [JSONValue] = []
    @State private var stats = ""
    @State private var loaded = false
    @State private var error: String?
    @State private var photo: PhotosPickerItem?

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 10)]

    var body: some View {
        ScrollView {
            if !stats.isEmpty {
                Text(stats).font(.footnote).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            }
            if let error, images.isEmpty { Text(error).foregroundColor(.red).padding() }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    imageCell(image)
                }
            }
            .padding()
            if loaded && images.isEmpty && error == nil { EmptyHint(text: "没有图片") }
        }
        .navigationTitle("Images")
        .overlay { if !loaded { ProgressView() } }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                PhotosPicker(selection: $photo, matching: .images) { Image(systemName: "plus") }
            }
        }
        .onChange(of: photo) { item in
            guard let item else { return }
            Task { await upload(item) }
        }
        .refreshable { await load() }
        .task { await load() }
        .errorAlert($error)
    }

    private func imageCell(_ image: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let url = image["variants"]?.array.first?.string, let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: Color.gray.opacity(0.15)
                    }
                }
                .frame(height: 88)
                .clipped()
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.15)).frame(height: 88)
                    .overlay(Image(systemName: "photo"))
            }
            Text(image["filename"]?.string ?? image["id"]?.string ?? "图片")
                .font(.caption2).lineLimit(1)
        }
        .contextMenu {
            Button("复制 ID") { UIPasteboard.general.string = image["id"]?.string }
            Button("删除", role: .destructive) {
                guard let id = image["id"]?.string else { return }
                Task { await remove(id) }
            }
        }
    }

    private func load() async {
        let ctx = session.ctx
        do {
            images = jsonItems(try await ctx.c.resultValue("GET", "accounts/\(ctx.acc)/images/v1"))
            error = nil
        } catch { if images.isEmpty { self.error = error.localizedDescription } }
        if let statsValue = try? await ctx.c.resultValue("GET", "accounts/\(ctx.acc)/images/v1/stats") {
            let current = statsValue["count"]?["current"]?.string ?? ""
            let allowed = statsValue["count"]?["allowed"]?.string ?? ""
            if !current.isEmpty { stats = "已用 \(current) / \(allowed)" }
        }
        loaded = true
    }

    private func upload(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                error = "无法读取照片"; return
            }
            let jpg = UIImage(data: data)?.jpegData(compressionQuality: 0.86) ?? data
            if jpg.count > 15_000_000 { error = "图片超过 15MB"; return }
            let part = MultipartPart(name: "file", filename: "photo.jpg", contentType: "image/jpeg", data: jpg)
            let built = buildMultipart([part])
            _ = try await session.ctx.c.raw("POST", "accounts/\(session.ctx.acc)/images/v1", body: built.body, contentType: built.contentType)
            await load()
        } catch { self.error = error.localizedDescription }
    }

    private func remove(_ id: String) async {
        do {
            try await session.ctx.c.deleteLoose("accounts/\(session.ctx.acc)/images/v1/\(cfEncode(id))")
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

struct R2ObjectsView: View {
    @EnvironmentObject var session: Session
    let bucket: String
    @State private var objects: [JSONValue] = []
    @State private var prefix = ""
    @State private var cursor: String?
    @State private var truncated = false
    @State private var loaded = false
    @State private var error: String?
    @State private var importing = false
    @State private var showPhotos = false
    @State private var photo: PhotosPickerItem?
    @State private var share: SharePayload?

    var body: some View {
        List {
            ForEach(Array(objects.enumerated()), id: \.offset) { _, object in
                NavigationLink {
                    R2ObjectDetail(bucket: bucket, object: object)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(object["key"]?.string ?? "对象").font(.headline).lineLimit(1)
                        Text(jsonSubtitle(object)).font(.caption).foregroundColor(.secondary)
                    }
                }
                .swipeActions {
                    Button("删除", role: .destructive) {
                        guard let key = object["key"]?.string else { return }
                        Task { await remove(key) }
                    }
                }
            }
            if truncated { Button("加载更多") { Task { await load(reset: false) } } }
        }
        .navigationTitle(bucket)
        .searchable(text: $prefix, prompt: "按前缀筛选")
        .onSubmit(of: .search) { Task { await load(reset: true) } }
        .overlay { if !loaded { ProgressView() } else if objects.isEmpty && error == nil { EmptyHint(text: "桶是空的") } }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("从文件上传") { importing = true }
                    Button("从照片上传") { showPhotos = true }
                } label: { Image(systemName: "plus") }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            Task { await importFile(result) }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
        .onChange(of: photo) { item in
            guard let item else { return }
            Task { await importPhoto(item) }
        }
        .sheet(item: $share) { payload in ActivityShare(items: [payload.url]) }
        .refreshable { await load(reset: true) }
        .task { await load(reset: true) }
        .errorAlert($error)
    }

    private func load(reset: Bool) async {
        var query = ["prefix": prefix]
        if !reset, let cursor, !cursor.isEmpty { query["cursor"] = cursor }
        do {
            let data = try await session.ctx.c.raw("GET", "accounts/\(session.ctx.acc)/r2/buckets/\(cfEncode(bucket))/objects", query: query)
            let page = try JSONDecoder().decode(CFPage.self, from: data)
            if !page.success { throw CFClientError.message(page.errors?.compactMap(\.message).first ?? "列表失败") }
            let batch = jsonItems(page.result ?? .null)
            if reset { objects = batch } else { objects.append(contentsOf: batch) }
            cursor = page.result_info?.cursor
            truncated = page.result_info?.is_truncated ?? false
            error = nil
        } catch {
            if objects.isEmpty { self.error = error.localizedDescription }
        }
        loaded = true
    }

    private func upload(_ data: Data, name: String, type: String) async throws {
        if data.count > 32_000_000 { throw CFClientError.message("超过 32MB，请在电脑上上传") }
        let path = "accounts/\(session.ctx.acc)/r2/buckets/\(cfEncode(bucket))/objects/\(cfEncode(name))"
        _ = try await session.ctx.c.raw("PUT", path, body: data, contentType: type)
        await load(reset: true)
    }

    private func importFile(_ result: Result<URL, Error>) async {
        do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try await upload(Data(contentsOf: url), name: url.lastPathComponent, type: "application/octet-stream")
        } catch { self.error = error.localizedDescription }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let jpg = UIImage(data: data)?.jpegData(compressionQuality: 0.86) ?? data
            try await upload(jpg, name: "photo-\(Int(Date().timeIntervalSince1970)).jpg", type: "image/jpeg")
        } catch { self.error = error.localizedDescription }
    }

    private func remove(_ key: String) async {
        do {
            try await session.ctx.c.deleteLoose("accounts/\(session.ctx.acc)/r2/buckets/\(cfEncode(bucket))/objects/\(cfEncode(key))")
            await load(reset: true)
        } catch { self.error = error.localizedDescription }
    }
}

struct R2ObjectDetail: View {
    @EnvironmentObject var session: Session
    let bucket: String
    let object: JSONValue
    @State private var error: String?
    @State private var busy = false
    @State private var share: SharePayload?

    var body: some View {
        List {
            LabeledContent("键", value: object["key"]?.string ?? "")
            if let size = object["size"]?.number { LabeledContent("大小", value: cfByteCount(Int64(size))) }
            if let uploaded = object["uploaded"]?.string { LabeledContent("上传", value: String(uploaded.prefix(19))) }
            Button {
                Task { await download() }
            } label: {
                if busy { ProgressView() } else { Label("下载并分享", systemImage: "square.and.arrow.up") }
            }
            .disabled(busy)
        }
        .navigationTitle("对象")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $share) { payload in ActivityShare(items: [payload.url]) }
        .errorAlert($error)
    }

    private func download() async {
        guard let key = object["key"]?.string else { return }
        if let size = object["size"]?.number, size > 32_000_000 {
            error = "对象超过 32MB，请在电脑上下载"
            return
        }
        busy = true
        defer { busy = false }
        do {
            let data = try await session.ctx.c.raw(
                "GET", "accounts/\(session.ctx.acc)/r2/buckets/\(cfEncode(bucket))/objects/\(cfEncode(key))")
            if data.count < 4000, let text = String(data: data, encoding: .utf8), text.contains("\"success\"") {
                if let page = try? JSONDecoder().decode(CFPage.self, from: data), !page.success {
                    throw CFClientError.message(page.errors?.compactMap(\.message).first ?? "下载失败")
                }
            }
            let safe = (key as NSString).lastPathComponent
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe.isEmpty ? "object.bin" : safe)
            try data.write(to: url, options: .atomic)
            share = SharePayload(url: url)
        } catch { self.error = error.localizedDescription }
    }
}
