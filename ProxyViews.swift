import SwiftUI
import UIKit

struct ProxyHomeView: View {
    @ObservedObject private var store = ProxyStore.shared
    @ObservedObject private var vpn = VPNManager.shared
    @State private var error: String?
    @State private var selecting = false
    @State private var checked = Set<UUID>()
    @State private var pendingIDs: [UUID] = []
    @State private var confirmDelete = false
    @State private var confirmAll = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { vpn.isActive },
                    set: { on in Task { await vpn.set(on: on, store: store) } }
                )) {
                    Text(vpn.statusText)
                }
                TrafficMeterRows()
                Picker("模式", selection: Binding(
                    get: { store.selectionMode },
                    set: { mode in
                        store.selectionMode = mode
                        Task { await vpn.restartIfActive(store: store) }
                    }
                )) {
                    ForEach(ProxySelectionMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("大陆直连", isOn: $store.bypassCN)
                Toggle("始终连接", isOn: $store.alwaysOn)
                NavigationLink("自动优选设置") { AutoSelectSettingsView() }
                NavigationLink("分流规则（\(store.routingRules.count)）") { RoutingRulesView() }
                NavigationLink("流量分类") { TrafficCategoriesView() }
            } footer: {
                Text("自动优选由 sing-box 的 urltest 组按延迟排序并自动故障切换；手动模式只走选中的节点。")
            }
            Section {
                NavigationLink("连接诊断") { ConnectivityDiagnosticsView() }
                NavigationLink("MTU 探测") { MTUFinderView() }
                NavigationLink("DNS 解析器测速") { DNSBenchmarkView() }
                NavigationLink("实时 VPN 日志") { VPNLogView() }
                NavigationLink("sing-box 配置") { TunnelDebugView() }
            }
            ProxyNodeSections(selecting: $selecting, checked: $checked) { ids in
                pendingIDs = Array(ids)
                confirmDelete = true
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting {
                Button {
                    pendingIDs = Array(checked)
                    confirmDelete = true
                } label: {
                    Text("删除所选 (\(checked.count))")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(InkTheme.seal)
                .disabled(checked.isEmpty)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .navigationTitle("VPN 与节点")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Button("全部删除", role: .destructive) { confirmAll = true }
                        .disabled(store.nodes.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(selecting ? "完成" : "选择") {
                    selecting.toggle()
                    if !selecting { checked.removeAll() }
                }
                .disabled(store.nodes.isEmpty && !selecting)
            }
        }
        .confirmationDialog(
            "删除 \(pendingIDs.count) 个节点？",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("删除 \(pendingIDs.count) 个", role: .destructive) {
                applyDelete(Set(pendingIDs))
            }
            Button("取消", role: .cancel) { pendingIDs = [] }
        } message: {
            Text("删除后会立刻更新本机保存的节点。若包含当前连接的节点，将改用剩余的第一个；一个都不剩就断开 VPN。")
        }
        .confirmationDialog(
            "删除全部 \(store.nodes.count) 个节点？",
            isPresented: $confirmAll,
            titleVisibility: .visible
        ) {
            Button("全部删除", role: .destructive) {
                applyDelete(Set(store.nodes.map(\.id)))
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("列表里的节点都会删掉，并断开 VPN。")
        }
        .task {
            await vpn.load()
            await store.refreshLatency(vpnConnected: vpn.isConnected)
        }
        .onChange(of: vpn.error) { e in
            error = e
        }
        .alert("出错了", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("好") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func applyDelete(_ ids: Set<UUID>) {
        let hitActive = store.removeIDs(ids)
        checked.subtract(ids)
        pendingIDs = []
        if store.nodes.isEmpty {
            selecting = false
            checked.removeAll()
            Task { await vpn.set(on: false, store: store) }
        } else if hitActive {
            Task { await vpn.restartIfActive(store: store) }
        }
    }
}

struct TrafficMeterRows: View {
    @ObservedObject private var traffic = VPNTraffic.shared
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("↑ \(VPNTraffic.formatRate(traffic.uploadRate))")
                Spacer()
                Text("↓ \(VPNTraffic.formatRate(traffic.downloadRate))")
            }
            .font(.callout.monospacedDigit())
            Text("会话 ↑\(VPNTraffic.formatBytes(traffic.sessionUp))  ↓\(VPNTraffic.formatBytes(traffic.sessionDown))")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
            HStack {
                Text("累计 ↑\(VPNTraffic.formatBytes(traffic.totalUp))  ↓\(VPNTraffic.formatBytes(traffic.totalDown))")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                Spacer()
                Button("归零") { confirmReset = true }
                    .font(.caption)
            }
        }
        .confirmationDialog("流量归零", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("仅清本次会话") { traffic.resetSession() }
            Button("全部归零", role: .destructive) { traffic.resetAll() }
            Button("取消", role: .cancel) {}
        }
    }
}

struct ProxyNodeSections: View {
    @ObservedObject private var store = ProxyStore.shared
    @ObservedObject private var vpn = VPNManager.shared
    @Binding var selecting: Bool
    @Binding var checked: Set<UUID>
    var askDelete: (Set<UUID>) -> Void
    @State private var editing: ProxyNode?

    /// 已知协议按固定顺序，节点实际用到的其它写法追加在后面。没有节点的分组不显示。
    private var protocols: [String] {
        let present = Set(store.nodes.map { ProxyProtocol.canonical($0.proto) })
        var ordered = ProxyProtocol.order.filter { present.contains($0) }
        var seen = Set(ordered)
        for node in store.nodes {
            let key = ProxyProtocol.canonical(node.proto)
            if seen.insert(key).inserted { ordered.append(key) }
        }
        return ordered
    }

    private func title(_ proto: String) -> String {
        ProxyProtocol.title(proto)
    }

    private func nodes(of proto: String) -> [ProxyNode] {
        let key = ProxyProtocol.canonical(proto)
        return store.nodes.filter { ProxyProtocol.canonical($0.proto) == key }
    }

    var body: some View {
        Group {
            Section {
                Button {
                    Task {
                        _ = await store.testAllAndSelectFastest(vpnConnected: vpn.isConnected)
                        await vpn.restartIfActive(store: store)
                    }
                } label: {
                    if store.isFindingFastest {
                        HStack { ProgressView(); Text("正在测速…") }
                    } else {
                        Label("测速并切到最快节点", systemImage: "speedometer")
                    }
                }
                .disabled(store.isFindingFastest || store.nodes.isEmpty)
                Button {
                    Task { await store.refreshLatency(vpnConnected: vpn.isConnected) }
                } label: {
                    if store.isRefreshing {
                        HStack { ProgressView(); Text("正在测试 TCP…") }
                    } else {
                        Text("刷新延迟")
                    }
                }
            } footer: {
                Text("VPN 已连接时用 sing-box 的代理延迟测速（含握手），否则测节点 TCP 建连延迟。测完自动切到最快节点；已连接会自动重连。左滑编辑，右滑删除。")
            }
            ForEach(protocols, id: \.self) { proto in
                let group = nodes(of: proto)
                let groupIDs = Set(group.map(\.id))
                let groupAll = !groupIDs.isEmpty && groupIDs.isSubset(of: checked)
                Section {
                    if selecting {
                        Button(groupAll ? "取消全选本组" : "全选本组") {
                            if groupAll {
                                checked.subtract(groupIDs)
                            } else {
                                checked.formUnion(groupIDs)
                            }
                        }
                    }
                    ForEach(group) { node in
                        ProxyNodeLatencyRow(
                            node: node,
                            active: store.selectedID == node.id,
                            marked: checked.contains(node.id),
                            choosing: selecting,
                            result: store.results[node.id],
                            chain: store.chainLabel(for: node),
                            note: SingBoxConfig.unsupportedReason(node)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selecting {
                                if checked.contains(node.id) { checked.remove(node.id) }
                                else { checked.insert(node.id) }
                            } else {
                                store.selectedID = node.id
                                Task { await vpn.restartIfActive(store: store) }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button("编辑") { editing = node }
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) { askDelete([node.id]) }
                        }
                    }
                } header: {
                    Text("\(title(proto))（\(group.count)）")
                }
            }
            Section("添加节点") {
                NavigationLink { ImportNodesView() } label: {
                    Label("从链接 / 订阅 / 二维码 / JSON 导入", systemImage: "link")
                }
                NavigationLink { NodeDeployView() } label: {
                    Label("部署 Cloudflare Worker 节点", systemImage: "cloud")
                }
            }
        }
        .sheet(item: $editing) { node in
            NodeEditView(node: node)
        }
    }
}

struct ProxyNodeLatencyRow: View {
    let node: ProxyNode
    let active: Bool
    let marked: Bool
    let choosing: Bool
    let result: ProxyProbeResult?
    var chain: String? = nil
    var note: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if choosing {
                Image(systemName: marked ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(marked ? InkTheme.seal : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(node.name)
                    if chain != nil {
                        Image(systemName: "link")
                            .font(.caption2)
                            .foregroundColor(InkTheme.seal)
                    }
                }
                Text(node.detail).font(.caption2).foregroundColor(.secondary)
                if let chain {
                    Text(chain)
                        .font(.caption2)
                        .foregroundColor(InkTheme.seal)
                }
                if let note {
                    Text(note)
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
            Spacer()
            if let result {
                Text(result.label)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(Self.tint(result))
            }
            if active && !choosing {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Color(red: 0.15, green: 0.55, blue: 0.28))
            }
        }
    }

    static func tint(_ result: ProxyProbeResult) -> Color {
        switch result {
        case .latency(let ms), .tcpLatency(let ms):
            return ms < 300 ? Color(red: 0.15, green: 0.55, blue: 0.28) : Color.orange
        case .unreachable, .probeFailed:
            return Color(red: 0.86, green: 0.38, blue: 0.12)
        case .requiresVPN:
            return .secondary
        }
    }
}

struct NodeEditView: View {
    @ObservedObject private var store = ProxyStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var node: ProxyNode
    @State private var portText: String
    /// Empty means “keep the imported value”, including no method at all.
    /// The picker must not substitute aes-128-gcm, or a save rewrites the cipher.
    @State private var method: String
    @State private var detourID: UUID?
    @State private var extraParams: String
    private let original: ProxyNode

    private static let ssMethods = [
        "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305",
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305"
    ]

    init(node: ProxyNode) {
        original = node
        _node = State(initialValue: node)
        _portText = State(initialValue: String(node.port))
        _method = State(initialValue: node.params["method"] ?? "")
        _detourID = State(initialValue: node.detourID)
        _extraParams = State(initialValue: NodeEditView.paramsText(node.params))
    }

    private static func paramsText(_ params: [String: String]) -> String {
        params.keys.sorted()
            .filter { $0 != "method" }
            .map { key in "\(key)=\(params[key] ?? "")" }
            .joined(separator: "\n")
    }

    private static func parseParams(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    private var secretLabel: String {
        switch ProxyProtocol.canonical(node.proto) {
        case "vless", "vmess": return "UUID"
        case "tuic": return "UUID（密码在高级参数）"
        case "wireguard": return "私钥 PrivateKey"
        case "ssh": return "密码"
        default: return "密码"
        }
    }

    private var detourCandidates: [ProxyNode] {
        store.nodes.filter { $0.id != node.id && store.canUseAsDetour($0.id, for: node.id) }
    }

    private var chainPreview: String? {
        var copy = node
        copy.detourID = detourID
        let chain = store.detourChain(for: copy)
        guard !chain.isEmpty else { return nil }
        return (chain.reversed().map(\.name) + [copy.name]).joined(separator: " → ")
    }

    private var methodChoices: [String] {
        var list = Self.ssMethods
        if !method.isEmpty && !list.contains(method) { list.insert(method, at: 0) }
        return list
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本") {
                    TextField("名称", text: $node.name)
                    TextField("地址（域名或 IP）", text: $node.server)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("端口", text: $portText).keyboardType(.numberPad)
                    TextField(secretLabel, text: $node.secret)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if ProxyProtocol.canonical(node.proto) == "ss" {
                        Picker("加密方式", selection: $method) {
                            Text("沿用导入").tag("")
                            ForEach(methodChoices, id: \.self) { item in
                                Text(item).tag(item)
                            }
                        }
                    }
                }
                Section("链式代理（前置节点）") {
                    Picker("前置节点", selection: $detourID) {
                        Text("不前置（直连落地）").tag(UUID?.none)
                        ForEach(detourCandidates) { candidate in
                            Text(candidate.name).tag(UUID?.some(candidate.id))
                        }
                    }
                    if let chainPreview {
                        Text(chainPreview)
                            .font(.caption2)
                            .foregroundColor(InkTheme.seal)
                    }
                } footer: {
                    Text("选了前置节点后，流量先经过前置节点再到本节点（双跳）。不会列出会构成环的前置节点。")
                }
                Section("高级参数（每行 key=value）") {
                    TextEditor(text: $extraParams)
                        .frame(minHeight: 88)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("WireGuard 需要 peer_public_key、local_address；TUIC 需要 password；SSH 需要 user；ShadowTLS 可用 version、sni。")
                }
                Section(footer: Text("加密方式必须与服务器一致。未改过的字段仍按导入链接生成出站。")) {
                    Text(node.detail).font(.footnote).foregroundColor(.secondary)
                    if let reason = SingBoxConfig.unsupportedReason(node) {
                        Text(reason).font(.caption).foregroundColor(.orange)
                    }
                    if ProxyProtocol.canonical(node.proto) != "ss" {
                        Text(cipherSummary)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("编辑节点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
        }
    }

    private var cipherSummary: String {
        let security = node.p("security") ?? node.p("tls") ?? "-"
        let flow = node.p("flow") ?? "-"
        let sni = node.p("sni") ?? node.p("peer") ?? node.p("host") ?? "-"
        let transport = node.p("type") ?? node.p("net") ?? "tcp"
        let path = node.p("path") ?? node.p("serviceName") ?? "-"
        return "security \(security)  flow \(flow)  sni \(sni)  transport \(transport)  path \(path)"
    }

    private func save() {
        var next = node
        next.port = Int(portText) ?? next.port
        var params = NodeEditView.parseParams(extraParams)
        if ProxyProtocol.canonical(next.proto) == "ss" {
            if method.isEmpty {
                params.removeValue(forKey: "method")
            } else {
                params["method"] = method
            }
        }
        next.params = params
        next.detourID = detourID
        let sameLink = next.server == original.server && next.port == original.port
            && next.secret == original.secret && next.params == original.params
        if !sameLink { next.raw = "" }
        store.update(next)
        Task { await VPNManager.shared.restartIfActive(store: store) }
        dismiss()
    }
}

struct TunnelDebugView: View {
    @ObservedObject private var vpn = VPNManager.shared
    @ObservedObject private var store = ProxyStore.shared
    @State private var log = ""
    @State private var sharing = false

    private var storeLine: String {
        guard let node = store.selected else { return "（无）" }
        return "\(node.name)  \(node.server):\(node.port)  \(node.id.uuidString.lowercased())"
    }

    private var configText: String {
        let raw = SingBoxConfig.build(nodes: store.nodes, selectedID: store.selected?.id,
                                      mode: store.selectionMode, bypassCN: store.bypassCN,
                                      rules: store.routingRules,
                                      categoryPolicies: store.categoryPolicies,
                                      auto: store.autoPolicy)
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else { return raw }
        return text
    }

    private var bodyText: String {
        """
        ===== 当前选中 =====
        界面选中：\(storeLine)
        下面这份 JSON 与 VPNManager.set(on:) 调用的 SingBoxConfig.build 参数相同。

        ===== config =====
        \(configText)

        ===== sing-box / 扩展日志 =====
        \(log.isEmpty ? "（日志为空）" : log)
        """
    }

    var body: some View {
        ScrollView {
            Text(bodyText)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("sing-box 配置")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("分享") { sharing = true }
            }
        }
        .sheet(isPresented: $sharing) {
            ShareSheet(items: [bodyText])
        }
        .task { log = await vpn.fetchLog() }
    }
}

struct RoutingRulesView: View {
    @ObservedObject private var store = ProxyStore.shared
    @State private var kind: ProxyRoutingRule.Kind = .domainSuffix
    @State private var value = ""
    @State private var target: ProxyRoutingRule.Target = .direct

    var body: some View {
        List {
            if store.routingRules.isEmpty {
                Text("暂无规则。可添加域名后缀或 IP CIDR。")
                    .foregroundColor(.secondary)
                    .font(.footnote)
            }
            ForEach(store.routingRules) { r in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.value)
                        Text(r.kind == .domainSuffix ? "域名后缀" : "IP CIDR")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(r.target == .direct ? "直连" : "代理")
                        .foregroundColor(.secondary)
                }
            }
            .onDelete { idx in
                store.routingRules.remove(atOffsets: idx)
                Task { await VPNManager.shared.restartIfActive(store: store) }
            }

            Section("添加规则") {
                Picker("类型", selection: $kind) {
                    Text("域名后缀").tag(ProxyRoutingRule.Kind.domainSuffix)
                    Text("IP CIDR").tag(ProxyRoutingRule.Kind.ipCIDR)
                }
                TextField(kind == .domainSuffix ? "例如 google.com" : "例如 1.1.1.1/32", text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("走向", selection: $target) {
                    Text("直连").tag(ProxyRoutingRule.Target.direct)
                    Text("代理").tag(ProxyRoutingRule.Target.proxy)
                }
                Button("添加") {
                    let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !v.isEmpty else { return }
                    store.routingRules.append(
                        ProxyRoutingRule(kind: kind, value: v, target: target)
                    )
                    value = ""
                    Task { await VPNManager.shared.restartIfActive(store: store) }
                }
            }

            Section {
                Button("应用并重连 VPN") {
                    Task { await VPNManager.shared.restartIfActive(store: store) }
                }
            } footer: {
                Text("修改规则后若 VPN 已连接会自动重连；也可手动点上面按钮。")
            }
        }
        .navigationTitle("分流规则")
    }
}

struct TrafficCategoriesView: View {
    @ObservedObject private var store = ProxyStore.shared

    var body: some View {
        List {
            Section {
                ForEach(ProxyTrafficCategory.allCases) { category in
                    Picker(selection: Binding(
                        get: { store.policy(for: category) },
                        set: { newValue in
                            store.setPolicy(newValue, for: category)
                            Task { await VPNManager.shared.restartIfActive(store: store) }
                        }
                    )) {
                        ForEach(ProxyGroupPolicy.allCases, id: \.self) { p in
                            Text(p.title).tag(p)
                        }
                    } label: {
                        Label(category.title, systemImage: category.symbol)
                    }
                }
            } footer: {
                Text("按软件类型指定走向。默认「跟随节点选择」。修改后会自动重连 VPN。")
            }
        }
        .navigationTitle("流量分类")
    }
}

struct ImportNodesView: View {
    @ObservedObject private var store = ProxyStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var nodes: [ProxyNode] = []
    @State private var error: String?
    @State private var scanning = false

    var body: some View {
        Form {
            Section("粘贴内容") {
                TextEditor(text: $text)
                    .frame(minHeight: 120)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    if let clipboard = UIPasteboard.general.string { text = clipboard }
                } label: {
                    Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                }
                Button { scanning = true } label: {
                    Label("扫描二维码", systemImage: "qrcode.viewfinder")
                }
            } footer: {
                Text("支持 vless / vmess / trojan / ss / hysteria2 / tuic / wireguard(wg) / shadowtls / anytls / ssh 分享链接，Base64 订阅，sing-box JSON 配置，以及 WireGuard .conf。")
            }
            Section {
                Button("解析") { parse() }
                if let error { Text(error).foregroundColor(.red).font(.footnote) }
            }
            if !nodes.isEmpty {
                Section("识别到 \(nodes.count) 个节点") {
                    ForEach(nodes) { node in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.name)
                            Text(node.detail).font(.caption2).foregroundColor(.secondary)
                            if let reason = SingBoxConfig.unsupportedReason(node) {
                                Text(reason).font(.caption2).foregroundColor(.orange)
                            }
                        }
                    }
                    Button("加入 \(nodes.count) 个") {
                        store.add(nodes)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("导入")
        .sheet(isPresented: $scanning) {
            QRScannerSheet { code in
                text = code
                parse()
            }
        }
    }

    private func parse() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            error = "请先把链接粘贴进来，或扫描二维码"
            return
        }
        error = nil
        Task {
            do {
                if t.lowercased().hasPrefix("http") {
                    nodes = try await LinkParser.fetchSubscription(t)
                } else {
                    nodes = LinkParser.parseMany(t)
                }
                if nodes.isEmpty {
                    error = "没有识别到节点。请确认链接格式，或整段 sing-box JSON 配置。"
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct VPNLogView: View {
    @ObservedObject private var vpn = VPNManager.shared
    @State private var text = ""
    @State private var live = true
    @State private var filter = ""
    @State private var sharing = false

    private var shown: String {
        let keyword = filter.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return text }
        let lines = text.components(separatedBy: .newlines)
            .filter { $0.localizedCaseInsensitiveContains(keyword) }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        List {
            Section {
                Toggle("实时刷新（2 秒）", isOn: $live)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("筛选关键字，例如 error", text: $filter)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Button { sharing = true } label: {
                    Label("分享日志", systemImage: "square.and.arrow.up")
                }
            }
            Section {
                if shown.isEmpty {
                    Text(text.isEmpty ? "（暂无日志）" : "没有匹配的行")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text(shown)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("VPN 日志")
        .sheet(isPresented: $sharing) {
            ShareSheet(items: [shown.isEmpty ? text : shown])
        }
        .task { text = await vpn.fetchLog() }
        .task(id: live) {
            guard live else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { break }
                text = await vpn.fetchLog()
            }
        }
    }
}

struct AutoSelectSettingsView: View {
    @ObservedObject private var store = ProxyStore.shared

    private static let intervals = [1, 3, 5, 10, 30]
    private static let tolerances = [0, 20, 50, 100, 200]

    var body: some View {
        List {
            Section {
                Picker("测速间隔", selection: Binding(
                    get: { store.autoIntervalMinutes },
                    set: { value in
                        store.autoIntervalMinutes = value
                        Task { await VPNManager.shared.restartIfActive(store: store) }
                    }
                )) {
                    ForEach(Self.intervals, id: \.self) { value in
                        Text("\(value) 分钟").tag(value)
                    }
                }
                Picker("切换容差", selection: Binding(
                    get: { store.autoToleranceMilliseconds },
                    set: { value in
                        store.autoToleranceMilliseconds = value
                        Task { await VPNManager.shared.restartIfActive(store: store) }
                    }
                )) {
                    ForEach(Self.tolerances, id: \.self) { value in
                        Text(value == 0 ? "不容差（最灵敏）" : "\(value) ms").tag(value)
                    }
                }
            } footer: {
                Text("sing-box 按间隔测各节点延迟，只有新节点快出容差以上才切换，避免来回跳。只在「自动优选」模式下生效。")
            }
            Section {
                Button {
                    Task {
                        _ = await store.testAllAndSelectFastest(vpnConnected: VPNManager.shared.isConnected)
                        await VPNManager.shared.restartIfActive(store: store)
                    }
                } label: {
                    if store.isFindingFastest {
                        HStack { ProgressView(); Text("正在测速…") }
                    } else {
                        Label("立即测速并切到最快节点", systemImage: "speedometer")
                    }
                }
                .disabled(store.isFindingFastest || store.nodes.isEmpty)
            } footer: {
                Text("手动模式下点这个按钮会切成最快的节点；自动优选模式下 urltest 组本来就会自己挑。")
            }
        }
        .navigationTitle("自动优选")
    }
}

struct NodeDeployView: View {
    @ObservedObject private var store = ProxyStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = "cf-vless"
    @State private var uuid = UUID().uuidString
    @State private var address = ""

    var body: some View {
        Form {
            Section(footer: Text("生成 VLESS + WebSocket 节点并加入列表。Worker 脚本仍需部署到 Cloudflare。")) {
                TextField("名称", text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("UUID", text: $uuid)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("连接地址（workers.dev 或优选 IP）", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section {
                Button("加入节点") {
                    let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, !uuid.isEmpty, !host.isEmpty else { return }
                    store.add(NodeWorker.node(name: name, host: host, address: host, uuid: uuid), select: true)
                    dismiss()
                }
                .disabled(name.isEmpty || uuid.isEmpty || address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle("部署 Worker 节点")
    }
}
