import SwiftUI

enum CreateKind {
    case none, name, vectorize, hyperdrive, turnstile, accessApp, originCA
}

enum AccountAPI: String, CaseIterable, Identifiable {
    case queues, durableObjects, hyperdrive, vectorize, turnstile
    case accessApps, accessGroups, accessServiceTokens, accessIdPs
    case gatewayRules, devicePosture, devicePolicies
    case aiGateways, aiModels, callsApps, rulesLists, accountLogpush
    case magicGRE, magicIPsec, dnsFirewall, dispatchNamespaces
    case streamVideos, streamLive, lbPools, lbMonitors, registrar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .queues: return "Queues"
        case .durableObjects: return "Durable Objects"
        case .hyperdrive: return "Hyperdrive"
        case .vectorize: return "Vectorize"
        case .turnstile: return "Turnstile"
        case .accessApps: return "Access 应用"
        case .accessGroups: return "Access 组"
        case .accessServiceTokens: return "服务令牌"
        case .accessIdPs: return "身份提供商"
        case .gatewayRules: return "Gateway 规则"
        case .devicePosture: return "设备态势"
        case .devicePolicies: return "设备策略"
        case .aiGateways: return "AI Gateway"
        case .aiModels: return "Workers AI 模型"
        case .callsApps: return "Realtime / Calls"
        case .rulesLists: return "规则列表"
        case .accountLogpush: return "账户 Logpush"
        case .magicGRE: return "Magic GRE"
        case .magicIPsec: return "Magic IPsec"
        case .dnsFirewall: return "DNS Firewall"
        case .dispatchNamespaces: return "Workers for Platforms"
        case .streamVideos: return "Stream 视频"
        case .streamLive: return "Stream 直播"
        case .lbPools: return "负载均衡池"
        case .lbMonitors: return "负载均衡监视器"
        case .registrar: return "注册商域名"
        }
    }

    var group: String {
        switch self {
        case .queues, .durableObjects, .dispatchNamespaces, .aiModels, .aiGateways, .callsApps:
            return "计算"
        case .hyperdrive, .vectorize, .rulesLists:
            return "数据"
        case .turnstile, .streamVideos, .streamLive:
            return "媒体与安全"
        case .accessApps, .accessGroups, .accessServiceTokens, .accessIdPs, .gatewayRules, .devicePosture, .devicePolicies:
            return "Zero Trust"
        case .magicGRE, .magicIPsec, .dnsFirewall, .lbPools, .lbMonitors, .accountLogpush:
            return "网络"
        case .registrar:
            return "账户"
        }
    }

    var path: String {
        switch self {
        case .queues: return "queues"
        case .durableObjects: return "workers/durable_objects/namespaces"
        case .hyperdrive: return "hyperdrive/configs"
        case .vectorize: return "vectorize/v2/indexes"
        case .turnstile: return "challenges/widgets"
        case .accessApps: return "access/apps"
        case .accessGroups: return "access/groups"
        case .accessServiceTokens: return "access/service_tokens"
        case .accessIdPs: return "access/identity_providers"
        case .gatewayRules: return "gateway/rules"
        case .devicePosture: return "devices/posture"
        case .devicePolicies: return "devices/policies"
        case .aiGateways: return "ai-gateway/gateways"
        case .aiModels: return "ai/models"
        case .callsApps: return "calls/apps"
        case .rulesLists: return "rules/lists"
        case .accountLogpush: return "logpush/jobs"
        case .magicGRE: return "magic/gre_tunnels"
        case .magicIPsec: return "magic/ipsec_tunnels"
        case .dnsFirewall: return "dns_firewall"
        case .dispatchNamespaces: return "workers/dispatch/namespaces"
        case .streamVideos: return "stream"
        case .streamLive: return "stream/live_inputs"
        case .lbPools: return "load_balancers/pools"
        case .lbMonitors: return "load_balancers/monitors"
        case .registrar: return "registrar/domains"
        }
    }

    var idKey: String {
        switch self {
        case .queues: return "queue_id"
        case .turnstile: return "sitekey"
        case .vectorize, .registrar: return "name"
        case .streamVideos, .streamLive: return "uid"
        default: return "id"
        }
    }

    var canDelete: Bool {
        switch self {
        case .durableObjects, .accessIdPs, .devicePosture, .devicePolicies, .aiModels,
             .magicGRE, .magicIPsec, .dnsFirewall, .registrar, .dispatchNamespaces, .callsApps:
            return false
        default:
            return true
        }
    }

    var createKind: CreateKind {
        switch self {
        case .queues, .rulesLists, .aiGateways: return .name
        case .vectorize: return .vectorize
        case .hyperdrive: return .hyperdrive
        case .turnstile: return .turnstile
        case .accessApps: return .accessApp
        default: return .none
        }
    }

    func nameBody(_ name: String) -> [String: Any]? {
        switch self {
        case .queues: return ["queue_name": name]
        case .rulesLists: return ["name": name, "kind": "ip", "description": "由 CF 助手创建"]
        case .aiGateways: return ["id": name, "cache_ttl": 0, "cache_invalidate_on_update": false, "collect_logs": true]
        default: return nil
        }
    }

    var note: String {
        switch self {
        case .magicGRE, .magicIPsec:
            return "只读。Magic 隧道的写入可能中断专线，这里不提供删除。"
        case .durableObjects:
            return "命名空间由 Worker 迁移创建。这里列出账户里已经存在的 Durable Object。"
        case .registrar:
            return "购买、转移和续费结账走控制台账单，接口只能查看域名状态。"
        case .callsApps:
            return "列出 Realtime / Calls 应用。创建应用需要额外的密钥材料，请在详情里核对字段。"
        default:
            return "权限不足或账户未开通时，只会显示接口错误，不影响其他功能。"
        }
    }
}

enum ZoneAPI: String, CaseIterable, Identifiable {
    case waitingRooms, healthChecks, loadBalancers, customHostnames, zoneLogpush
    case snippets, spectrumApps, certPacks, customCertificates, customPages
    case web3Hostnames, uaRules, legacyFirewall, managedHeaders, originCA

    var id: String { rawValue }

    var title: String {
        switch self {
        case .waitingRooms: return "等待室"
        case .healthChecks: return "健康检查"
        case .loadBalancers: return "负载均衡"
        case .customHostnames: return "自定义主机名"
        case .zoneLogpush: return "Logpush"
        case .snippets: return "Snippets"
        case .spectrumApps: return "Spectrum"
        case .certPacks: return "证书包"
        case .customCertificates: return "自定义证书"
        case .customPages: return "自定义错误页"
        case .web3Hostnames: return "Web3 主机名"
        case .uaRules: return "User-Agent 规则"
        case .legacyFirewall: return "防火墙规则（旧版）"
        case .managedHeaders: return "托管转换头"
        case .originCA: return "Origin CA"
        }
    }

    var path: String {
        switch self {
        case .waitingRooms: return "waiting_rooms"
        case .healthChecks: return "healthchecks"
        case .loadBalancers: return "load_balancers"
        case .customHostnames: return "custom_hostnames"
        case .zoneLogpush: return "logpush/jobs"
        case .snippets: return "snippets"
        case .spectrumApps: return "spectrum/apps"
        case .certPacks: return "ssl/certificate_packs"
        case .customCertificates: return "custom_certificates"
        case .customPages: return "custom_pages"
        case .web3Hostnames: return "web3/hostnames"
        case .uaRules: return "firewall/ua_rules"
        case .legacyFirewall: return "firewall/rules"
        case .managedHeaders: return "managed_headers"
        case .originCA: return "certificates"
        }
    }

    var idKey: String {
        switch self {
        case .snippets: return "name"
        default: return "id"
        }
    }

    var canDelete: Bool {
        switch self {
        case .certPacks, .customCertificates, .customPages, .managedHeaders, .originCA:
            return false
        default:
            return true
        }
    }

    var createKind: CreateKind { self == .originCA ? .originCA : .none }

    var note: String {
        switch self {
        case .originCA: return "签发需要粘贴 CSR。列表本身只展示已经签发的源站证书。"
        case .snippets: return "可以查看和删除。上传 snippet 包需要多文件部署，这里不做。"
        case .managedHeaders: return "托管请求头 / 响应头为只读展示。"
        default: return "权限不足时只显示错误，不影响域名里的其他功能。"
        }
    }
}

enum RemoteSource {
    case account(AccountAPI)
    case zone(ZoneAPI, String)

    var title: String {
        switch self {
        case .account(let api): return api.title
        case .zone(let api, _): return api.title
        }
    }
    var note: String {
        switch self {
        case .account(let api): return api.note
        case .zone(let api, _): return api.note
        }
    }
    var taskID: String {
        switch self {
        case .account(let api): return "a:" + api.rawValue
        case .zone(let api, let zone): return "z:\(api.rawValue):\(zone)"
        }
    }
    var idKey: String {
        switch self {
        case .account(let api): return api.idKey
        case .zone(let api, _): return api.idKey
        }
    }
    var canDelete: Bool {
        switch self {
        case .account(let api): return api.canDelete
        case .zone(let api, _): return api.canDelete
        }
    }
    var createKind: CreateKind {
        switch self {
        case .account(let api): return api.createKind
        case .zone(let api, _): return api.createKind
        }
    }
    var zoneID: String? {
        if case .zone(_, let id) = self { return id }
        return nil
    }
    var isTurnstile: Bool {
        if case .account(.turnstile) = self { return true }
        return false
    }

    func load(_ ctx: Ctx) async throws -> [JSONValue] {
        switch self {
        case .account(let api):
            let v = try await ctx.c.resultValue("GET", "accounts/\(ctx.acc)/\(api.path)")
            return jsonItems(v)
        case .zone(let api, let zone):
            if api == .originCA {
                return jsonItems(try await ctx.c.resultValue("GET", "certificates", query: ["zone_id": zone]))
            }
            if api == .certPacks {
                return jsonItems(try await ctx.c.resultValue(
                    "GET", "zones/\(zone)/\(api.path)", query: ["status": "all"]))
            }
            return jsonItems(try await ctx.c.resultValue("GET", "zones/\(zone)/\(api.path)"))
        }
    }

    func remove(_ ctx: Ctx, _ item: JSONValue) async throws {
        guard let raw = item[idKey]?.string ?? item["id"]?.string ?? item["name"]?.string else {
            throw CFClientError.message("这条记录没有可删除的标识")
        }
        let enc = cfEncode(raw)
        let path: String
        switch self {
        case .account(let api):
            path = "accounts/\(ctx.acc)/\(api.path)/\(enc)"
        case .zone(let api, let zone):
            if api == .originCA {
                path = "certificates/\(enc)"
            } else {
                path = "zones/\(zone)/\(api.path)/\(enc)"
            }
        }
        try await ctx.c.deleteLoose(path)
    }

    func createNamed(_ ctx: Ctx, _ name: String) async throws {
        guard case .account(let api) = self, let body = api.nameBody(name) else {
            throw CFClientError.message("这个资源不能只靠名称创建")
        }
        _ = try await ctx.c.resultValue("POST", "accounts/\(ctx.acc)/\(api.path)", body: try jsonBody(body))
    }
}

struct RemoteListView: View {
    @EnvironmentObject var session: Session
    let source: RemoteSource

    @State private var rows: [JSONRow] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var query = ""
    @State private var creating = false
    @State private var secretText: String?

    private var filtered: [JSONRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return rows }
        return rows.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.subtitle.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        List {
            Section {
                if let error, rows.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).foregroundColor(.red).font(.footnote)
                        Button("重试") { Task { await reload() } }
                    }
                }
                ForEach(filtered) { row in
                    NavigationLink {
                        JSONDetailView(title: row.title, value: row.value)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title).font(.headline).lineLimit(1)
                            if !row.subtitle.isEmpty {
                                Text(row.subtitle).font(.caption).foregroundColor(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .swipeActions {
                        if source.canDelete {
                            Button("删除", role: .destructive) { Task { await remove(row) } }
                        }
                    }
                    .contextMenu {
                        Button("复制名称") { UIPasteboard.general.string = row.title }
                        Button("复制 JSON") { UIPasteboard.general.string = jsonPretty(row.value) }
                        if source.isTurnstile, let key = row.value["sitekey"]?.string {
                            Button("轮换密钥") { Task { await rotate(key) } }
                        }
                    }
                }
            } footer: {
                Text(source.note)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(source.title)
        .searchable(text: $query, prompt: "搜索")
        .refreshable { await reload() }
        .overlay {
            if !loaded {
                ProgressView()
            } else if filtered.isEmpty && error == nil {
                EmptyHint(text: "没有\(source.title)")
            }
        }
        .toolbar {
            if source.createKind != .none {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                }
            }
        }
        .sheet(isPresented: $creating) {
            CreateRouter(source: source) { Task { await reload() } }
        }
        .task(id: source.taskID) { await reload() }
        .alert("新密钥（只显示一次）", isPresented: Binding(
            get: { secretText != nil },
            set: { if !$0 { secretText = nil } }
        )) {
            Button("复制") { UIPasteboard.general.string = secretText }
            Button("好", role: .cancel) { secretText = nil }
        } message: {
            Text(secretText ?? "")
        }
        .errorAlert($error)
    }

    private func reload() async {
        do {
            let items = try await source.load(session.ctx)
            rows = items.enumerated().map { index, value in
                let raw = value[source.idKey]?.string ?? jsonTitle(value)
                return JSONRow(id: "\(index)-\(raw)", value: value, title: jsonTitle(value), subtitle: jsonSubtitle(value))
            }
            error = nil
        } catch {
            if rows.isEmpty { self.error = error.localizedDescription }
        }
        loaded = true
    }

    private func remove(_ row: JSONRow) async {
        do {
            try await source.remove(session.ctx, row.value)
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func rotate(_ sitekey: String) async {
        do {
            let v = try await session.ctx.c.resultValue(
                "POST", "accounts/\(session.ctx.acc)/challenges/widgets/\(cfEncode(sitekey))/rotate_secret")
            secretText = v["secret"]?.string ?? jsonPretty(v)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
