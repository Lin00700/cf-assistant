import SwiftUI

enum RulePhase: String, CaseIterable, Identifiable {
    case firewall, managed, rate, cache, redirect
    case transformReq, transformResp, config, origin, compression

    var id: String { rawValue }

    var title: String {
        switch self {
        case .firewall: return "自定义 WAF 规则"
        case .managed: return "托管 WAF 规则"
        case .rate: return "速率限制"
        case .cache: return "缓存规则"
        case .redirect: return "重定向规则"
        case .transformReq: return "请求转换"
        case .transformResp: return "响应头转换"
        case .config: return "配置规则"
        case .origin: return "源站规则"
        case .compression: return "压缩规则"
        }
    }

    var phase: String {
        switch self {
        case .firewall: return "http_request_firewall_custom"
        case .managed: return "http_request_firewall_managed"
        case .rate: return "http_ratelimit"
        case .cache: return "http_request_cache_settings"
        case .redirect: return "http_request_dynamic_redirect"
        case .transformReq: return "http_request_transform"
        case .transformResp: return "http_response_headers_transform"
        case .config: return "http_config_settings"
        case .origin: return "http_request_origin"
        case .compression: return "http_response_compression"
        }
    }

    var canAdd: Bool { self != .managed }
    var canDelete: Bool { self != .managed }

    var actions: [String] {
        switch self {
        case .firewall, .rate:
            return ["block", "managed_challenge", "challenge", "js_challenge", "log"]
        default:
            return []
        }
    }
}

struct RuleDraft: Identifiable {
    let id = UUID()
    var description = ""
    var expression = "true"
    var action = "block"
    var enabled = true
    var period = 60
    var requests = 100
    var timeout = 60
    var targetURL = "https://"
    var status = 301
    var cache = false
    var ttl = 3600
    var headerName = "X-Custom"
    var headerValue = ""
    var headerOp = "set"
    var originHost = ""
    var security = "medium"

    func payload(_ kind: RulePhase) -> [String: Any] {
        var rule: [String: Any] = [
            "description": description,
            "expression": expression.trimmingCharacters(in: .whitespacesAndNewlines),
            "enabled": enabled
        ]
        switch kind {
        case .firewall:
            rule["action"] = action
        case .rate:
            rule["action"] = action
            rule["ratelimit"] = [
                "characteristics": ["cf.colo.id", "ip.src"],
                "period": period,
                "requests_per_period": requests,
                "mitigation_timeout": timeout
            ]
        case .cache:
            rule["action"] = "set_cache_settings"
            if cache {
                rule["action_parameters"] = [
                    "cache": true,
                    "edge_ttl": ["mode": "override_origin", "default": ttl]
                ]
            } else {
                rule["action_parameters"] = ["cache": false]
            }
        case .redirect:
            rule["action"] = "redirect"
            rule["action_parameters"] = [
                "from_value": [
                    "status_code": status,
                    "target_url": ["value": targetURL],
                    "preserve_query_string": true
                ]
            ]
        case .transformReq, .transformResp:
            rule["action"] = "rewrite"
            var header: [String: Any] = ["operation": headerOp]
            if headerOp != "remove" { header["value"] = headerValue }
            rule["action_parameters"] = ["headers": [headerName: header]]
        case .config:
            rule["action"] = "set_config"
            rule["action_parameters"] = ["security_level": security]
        case .origin:
            rule["action"] = "route"
            rule["action_parameters"] = [
                "host_header": originHost,
                "origin": ["host": originHost]
            ]
        case .compression:
            rule["action"] = "compress_response"
            rule["action_parameters"] = ["algorithms": [["name": "gzip"], ["name": "brotli"]]]
        case .managed:
            break
        }
        return rule
    }
}

struct PhaseRulesView: View {
    @EnvironmentObject var session: Session
    let zoneID: String
    let kind: RulePhase

    @State private var rules: [JSONValue] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var draft: RuleDraft?

    var body: some View {
        List {
            Section {
                ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                    NavigationLink {
                        JSONDetailView(title: rule["description"]?.string ?? "规则", value: rule)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule["description"]?.string ?? rule["action"]?.string ?? "规则")
                                .font(.headline)
                            Text(rule["expression"]?.string ?? "")
                                .font(.caption).foregroundColor(.secondary).lineLimit(2)
                            Text(rule["action"]?.string ?? "")
                                .font(.caption2).foregroundColor(InkTheme.seal)
                        }
                    }
                    .swipeActions {
                        if kind.canDelete {
                            Button("删除", role: .destructive) { Task { await remove(index) } }
                        }
                    }
                }
            } footer: {
                Text(kind == .managed
                     ? "托管规则集只展示。启用开关如果接口拒绝，会显示错误。"
                     : "表达式使用 Cloudflare wirefilter。true 会匹配全部请求。")
            }
            if kind != .managed {
                Section {
                    ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                        Toggle(rule["description"]?.string ?? "启用", isOn: Binding(
                            get: { rule["enabled"]?.bool ?? true },
                            set: { value in Task { await setEnabled(index, value) } }
                        ))
                    }
                }
            }
        }
        .navigationTitle(kind.title)
        .overlay {
            if !loaded { ProgressView() }
            else if rules.isEmpty { EmptyHint(text: "还没有规则") }
        }
        .toolbar {
            if kind.canAdd {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { draft = RuleDraft() } label: { Image(systemName: "plus") }
                }
            }
        }
        .sheet(item: $draft) { item in
            RuleDraftForm(kind: kind, draft: item) { made in
                Task { await add(made) }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .errorAlert($error)
    }

    private var entrypoint: String { "zones/\(zoneID)/rulesets/phases/\(kind.phase)/entrypoint" }

    private func load() async {
        do {
            let value = try await session.ctx.c.resultValue("GET", entrypoint)
            rules = value["rules"]?.array ?? []
            error = nil
        } catch {
            let msg = error.localizedDescription.lowercased()
            if msg.contains("404") || msg.contains("not found") || msg.contains("could not find") {
                rules = []
                self.error = nil
            } else if rules.isEmpty {
                self.error = error.localizedDescription
            }
        }
        loaded = true
    }

    private func put(_ all: [[String: Any]]) async {
        do {
            _ = try await session.ctx.c.resultValue("PUT", entrypoint, body: try jsonBody(["rules": all]))
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func slim(_ rule: JSONValue) -> [String: Any] {
        let keep = ["id", "action", "expression", "description", "enabled", "ratelimit",
                    "action_parameters", "logging"]
        var out: [String: Any] = [:]
        for key in keep {
            if let value = rule[key], !value.isNull {
                out[key] = jsonToAny(value)
            }
        }
        return out
    }

    private func add(_ made: RuleDraft) async {
        var all = rules.map { slim($0) }
        all.append(made.payload(kind))
        await put(all)
    }

    private func remove(_ index: Int) async {
        var all = rules.map { slim($0) }
        guard all.indices.contains(index) else { return }
        all.remove(at: index)
        await put(all)
    }

    private func setEnabled(_ index: Int, _ enabled: Bool) async {
        var all = rules.map { slim($0) }
        guard all.indices.contains(index) else { return }
        all[index]["enabled"] = enabled
        await put(all)
    }
}

struct RuleDraftForm: View {
    @Environment(\.dismiss) private var dismiss
    let kind: RulePhase
    @State var draft: RuleDraft
    var onSave: (RuleDraft) -> Void
    @State private var error: String?

    init(kind: RulePhase, draft: RuleDraft, onSave: @escaping (RuleDraft) -> Void) {
        self.kind = kind
        self._draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("说明") {
                    TextField("规则名称", text: $draft.description)
                    TextField("表达式", text: $draft.expression, axis: .vertical)
                        .lineLimit(3...6)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    presets
                    Toggle("启用", isOn: $draft.enabled)
                }
                kindFields
                if let error { Text(error).foregroundColor(.red).font(.footnote) }
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { commit() }
                        .disabled(draft.description.trimmingCharacters(in: .whitespaces).isEmpty
                                  || draft.expression.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var presets: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                preset("全部", "true")
                preset("指定 IP", "ip.src eq 1.2.3.4")
                preset("国家", "ip.src.country eq \"CN\"")
                preset("路径", "http.request.uri.path contains \"/admin\"")
                preset("机器人", "(cf.client.bot)")
                preset("登录", "http.request.uri.path contains \"/login\"")
            }
        }
    }

    private func preset(_ title: String, _ expression: String) -> some View {
        Button(title) { draft.expression = expression }
            .buttonStyle(.bordered)
            .font(.caption)
    }

    @ViewBuilder
    private var kindFields: some View {
        switch kind {
        case .firewall, .rate:
            Section("动作") {
                Picker("动作", selection: $draft.action) {
                    ForEach(kind.actions, id: \.self) { Text(actionTitle($0)).tag($0) }
                }
            }
            if kind == .rate {
                Section("阈值") {
                    Stepper("周期 \(draft.period) 秒", value: $draft.period, in: 10...3600, step: 10)
                    Stepper("请求数 \(draft.requests)", value: $draft.requests, in: 1...100000, step: 10)
                    Stepper("缓解 \(draft.timeout) 秒", value: $draft.timeout, in: 0...86400, step: 10)
                }
            }
        case .cache:
            Section("缓存") {
                Toggle("缓存（关闭则绕过）", isOn: $draft.cache)
                if draft.cache {
                    Stepper("边缘 TTL \(draft.ttl) 秒", value: $draft.ttl, in: 1...31536000, step: 60)
                }
            }
        case .redirect:
            Section("目标") {
                TextField("https://example.com/new", text: $draft.targetURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("状态码", selection: $draft.status) {
                    Text("301").tag(301); Text("302").tag(302); Text("307").tag(307); Text("308").tag(308)
                }
            }
        case .transformReq, .transformResp:
            Section("标头") {
                TextField("名称", text: $draft.headerName).textInputAutocapitalization(.never)
                Picker("操作", selection: $draft.headerOp) {
                    Text("设置").tag("set"); Text("删除").tag("remove")
                }
                if draft.headerOp != "remove" {
                    TextField("值", text: $draft.headerValue).textInputAutocapitalization(.never)
                }
            }
        case .config:
            Section("安全级别") {
                Picker("级别", selection: $draft.security) {
                    Text("基本关闭").tag("essentially_off")
                    Text("低").tag("low"); Text("中").tag("medium"); Text("高").tag("high")
                    Text("I'm Under Attack").tag("under_attack")
                }
            }
        case .origin:
            Section("源站主机") {
                TextField("origin.example.com", text: $draft.originHost)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        case .compression, .managed:
            EmptyView()
        }
    }

    private func actionTitle(_ action: String) -> String {
        switch action {
        case "block": return "拦截"
        case "managed_challenge": return "托管质询"
        case "challenge": return "验证码"
        case "js_challenge": return "JS 质询"
        case "log": return "仅记录"
        default: return action
        }
    }

    private func commit() {
        if kind == .redirect, URL(string: draft.targetURL)?.scheme == nil {
            error = "重定向目标需要包含 https://"
            return
        }
        if kind == .origin, draft.originHost.trimmingCharacters(in: .whitespaces).isEmpty {
            error = "请填写源站主机名"
            return
        }
        onSave(draft)
        dismiss()
    }
}

struct PageRulesView: View {
    @EnvironmentObject var session: Session
    let zoneID: String
    let zoneName: String
    @State private var rules: [JSONValue] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var creating = false

    var body: some View {
        List {
            ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                VStack(alignment: .leading, spacing: 3) {
                    Text(rule["targets"]?.array.first?["constraint"]?["value"]?.string ?? "页面规则")
                        .font(.headline)
                    Text(rule["status"]?.string ?? "")
                        .font(.caption).foregroundColor(.secondary)
                }
                .swipeActions {
                    Button("删除", role: .destructive) {
                        guard let id = rule["id"]?.string else { return }
                        Task { await remove(id) }
                    }
                }
            }
        }
        .navigationTitle("页面规则")
        .overlay { if !loaded { ProgressView() } else if rules.isEmpty { EmptyHint(text: "没有页面规则") } }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $creating) { PageRuleSheet(zoneID: zoneID, zoneName: zoneName) { Task { await load() } } }
        .refreshable { await load() }
        .task { await load() }
        .errorAlert($error)
    }

    private func load() async {
        do {
            rules = jsonItems(try await session.ctx.c.resultValue("GET", "zones/\(zoneID)/pagerules"))
            error = nil
        } catch { if rules.isEmpty { self.error = error.localizedDescription } }
        loaded = true
    }

    private func remove(_ id: String) async {
        do {
            try await session.ctx.c.deleteLoose("zones/\(zoneID)/pagerules/\(cfEncode(id))")
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

struct PageRuleSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let zoneID: String
    let zoneName: String
    var onCreated: () -> Void
    @State private var pattern = ""
    @State private var kind = "https"
    @State private var cache = "bypass"
    @State private var security = "high"
    @State private var forward = "https://"
    @State private var code = 301
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("URL 匹配，例如 example.com/*", text: $pattern)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("动作", selection: $kind) {
                    Text("始终 HTTPS").tag("https")
                    Text("缓存级别").tag("cache")
                    Text("安全级别").tag("security")
                    Text("转发").tag("forward")
                }
                if kind == "cache" {
                    Picker("缓存", selection: $cache) {
                        Text("绕过").tag("bypass"); Text("基本").tag("basic")
                        Text("简化").tag("simplified"); Text("激进").tag("aggressive")
                    }
                }
                if kind == "security" {
                    Picker("级别", selection: $security) {
                        Text("低").tag("low"); Text("中").tag("medium"); Text("高").tag("high")
                        Text("I'm Under Attack").tag("under_attack")
                    }
                }
                if kind == "forward" {
                    TextField("目标 URL", text: $forward).textInputAutocapitalization(.never)
                    Picker("状态码", selection: $code) { Text("301").tag(301); Text("302").tag(302) }
                }
                if let error { Text(error).foregroundColor(.red).font(.footnote) }
            }
            .navigationTitle("新建页面规则")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { if pattern.isEmpty { pattern = zoneName + "/*" } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("创建") { Task { await go() } } }
            }
        }
    }

    private func go() async {
        var action: [String: Any] = ["id": "always_use_https"]
        switch kind {
        case "cache": action = ["id": "cache_level", "value": cache]
        case "security": action = ["id": "security_level", "value": security]
        case "forward": action = ["id": "forwarding_url", "value": ["url": forward, "status_code": code]]
        default: break
        }
        let body: [String: Any] = [
            "targets": [["target": "url", "constraint": ["operator": "matches", "value": pattern]]],
            "actions": [action],
            "priority": 1,
            "status": "active"
        ]
        do {
            _ = try await session.ctx.c.resultValue("POST", "zones/\(zoneID)/pagerules", body: try jsonBody(body))
            onCreated(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct IPAccessRulesView: View {
    @EnvironmentObject var session: Session
    var zoneID: String?
    @State private var rules: [JSONValue] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var creating = false

    private var path: String {
        if let zoneID { return "zones/\(zoneID)/firewall/access_rules/rules" }
        return "accounts/\(session.accountId)/firewall/access_rules/rules"
    }

    var body: some View {
        List {
            ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                VStack(alignment: .leading, spacing: 3) {
                    Text(rule["configuration"]?["value"]?.string ?? "规则").font(.headline)
                    Text("\(rule["mode"]?.string ?? "") · \(rule["notes"]?.string ?? "")")
                        .font(.caption).foregroundColor(.secondary)
                }
                .swipeActions {
                    Button("删除", role: .destructive) {
                        guard let id = rule["id"]?.string else { return }
                        Task { await remove(id) }
                    }
                }
            }
        }
        .navigationTitle(zoneID == nil ? "账户 IP 规则" : "IP 访问规则")
        .overlay { if !loaded { ProgressView() } else if rules.isEmpty { EmptyHint(text: "没有 IP 规则") } }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $creating) {
            IPRuleSheet(path: path) { Task { await load() } }
        }
        .refreshable { await load() }
        .task { await load() }
        .errorAlert($error)
    }

    private func load() async {
        do {
            rules = jsonItems(try await session.ctx.c.resultValue("GET", path))
            error = nil
        } catch { if rules.isEmpty { self.error = error.localizedDescription } }
        loaded = true
    }

    private func remove(_ id: String) async {
        do {
            try await session.ctx.c.deleteLoose(path + "/\(cfEncode(id))")
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

struct IPRuleSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let path: String
    var onCreated: () -> Void
    @State private var target = "ip"
    @State private var value = ""
    @State private var mode = "block"
    @State private var notes = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("对象", selection: $target) {
                    Text("IP").tag("ip"); Text("IP 段").tag("ip_range")
                    Text("国家").tag("country"); Text("ASN").tag("asn")
                }
                TextField(target == "country" ? "CN" : (target == "asn" ? "13335" : "1.2.3.4"), text: $value)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("动作", selection: $mode) {
                    Text("拦截").tag("block"); Text("验证码").tag("challenge")
                    Text("JS 质询").tag("js_challenge"); Text("托管质询").tag("managed_challenge")
                    Text("允许").tag("whitelist")
                }
                TextField("备注", text: $notes)
                if let error { Text(error).foregroundColor(.red).font(.footnote) }
            }
            .navigationTitle("新建 IP 规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { Task { await go() } }.disabled(value.isEmpty)
                }
            }
        }
    }

    private func go() async {
        let body: [String: Any] = [
            "mode": mode,
            "configuration": ["target": target, "value": value.trimmingCharacters(in: .whitespacesAndNewlines)],
            "notes": notes
        ]
        do {
            _ = try await session.ctx.c.resultValue("POST", path, body: try jsonBody(body))
            onCreated(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct ZoneCatalogView: View {
    let zone: Zone

    var body: some View {
        List {
            ruleSection
            securitySection
            networkSection
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("规则与安全")
    }

    private var ruleSection: some View {
        Section("规则") {
            ForEach(RulePhase.allCases) { phase in
                NavigationLink(phase.title) { PhaseRulesView(zoneID: zone.id, kind: phase) }
            }
            NavigationLink("页面规则") { PageRulesView(zoneID: zone.id, zoneName: zone.name) }
            NavigationLink("IP 访问规则") { IPAccessRulesView(zoneID: zone.id) }
        }
    }

    private var securitySection: some View {
        Section("安全 / SSL / 缓存") {
            NavigationLink("Bot 管理") {
                JSONSettingsView(title: "Bot 管理", path: "zones/\(zone.id)/bot_management", write: "PUT",
                                 footer: "只提交接口返回的开关和文本。企业版没有的字段不会出现。")
            }
            NavigationLink("DNSSEC") {
                JSONSettingsView(title: "DNSSEC", path: "zones/\(zone.id)/dnssec", write: "PATCH", only: ["status"],
                                 footer: "打开后状态变为 active。DS 记录在只读区。")
            }
            NavigationLink("分层缓存") {
                JSONSettingsView(title: "分层缓存", path: "zones/\(zone.id)/argo/tiered_caching", write: "PATCH", only: ["value"])
            }
            NavigationLink("智能路由") {
                JSONSettingsView(title: "智能路由", path: "zones/\(zone.id)/argo/smart_routing", write: "PATCH", only: ["value"])
            }
            NavigationLink("Cache Reserve") {
                JSONSettingsView(title: "Cache Reserve", path: "zones/\(zone.id)/cache/cache_reserve", write: "PATCH", only: ["value"])
            }
        }
    }

    private var networkSection: some View {
        Section("网络与边缘") {
            ForEach(ZoneAPI.allCases) { api in
                NavigationLink(api.title) { RemoteListView(source: .zone(api, zone.id)) }
            }
        }
    }
}
