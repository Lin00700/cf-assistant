import SwiftUI

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
                Picker("模式", selection: $store.selectionMode) {
                    Text("手动").tag(ProxySelectionMode.manual)
                    Text("自动").tag(ProxySelectionMode.automatic)
                }
                Toggle("大陆直连", isOn: $store.bypassCN)
                Toggle("始终连接", isOn: $store.alwaysOn)
                NavigationLink("分流规则（\(store.routingRules.count)）") { RoutingRulesView() }
                NavigationLink("流量分类") { TrafficCategoriesView() }
            }
            Section {
                NavigationLink("连接诊断") { ConnectivityDiagnosticsView() }
                NavigationLink("VPN 日志") { VPNLogView() }
                NavigationLink("sing-box 配置") { SingBoxConfigDebugView() }
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

    /// Main's protocol order: vless, vmess, trojan, ss, hysteria2.
    /// Any other proto the nodes actually use (TUIC, aliases, …) is appended.
    /// A group is omitted when it has no nodes.
    private static let knownOrder = ["vless", "vmess", "trojan", "ss", "hysteria2"]

    private func canonical(_ proto: String) -> String {
        switch proto.lowercased() {
        case "ss", "shadowsocks": return "ss"
        case "hy2", "hysteria2": return "hysteria2"
        default: return proto.lowercased()
        }
    }

    private var protocols: [String] {
        let present = Set(store.nodes.map { canonical($0.proto) })
        var ordered = Self.knownOrder.filter { present.contains($0) }
        var seen = Set(ordered)
        for node in store.nodes {
            let key = canonical(node.proto)
            if seen.insert(key).inserted { ordered.append(key) }
        }
        return ordered
    }

    private func title(_ proto: String) -> String {
        switch canonical(proto) {
        case "ss": return "Shadowsocks"
        case "vless": return "VLESS"
        case "vmess": return "VMess"
        case "trojan": return "Trojan"
        case "hysteria2": return "Hysteria2"
        case "tuic": return "TUIC"
        default: return proto.uppercased()
        }
    }

    private func nodes(of proto: String) -> [ProxyNode] {
        let key = canonical(proto)
        return store.nodes.filter { canonical($0.proto) == key }
    }

    var body: some View {
        Group {
            Section {
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
                Text("未连接内置 VPN 时也可刷新：测试节点 TCP 端口是否可达及建连延迟。左滑编辑，右滑删除。")
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
                            result: store.results[node.id]
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
                    Label("从链接 / 订阅导入", systemImage: "link")
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

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if choosing {
                Image(systemName: marked ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(marked ? InkTheme.seal : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                Text(node.detail).font(.caption2).foregroundColor(.secondary)
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
                    TextField(node.proto == "vless" || node.proto == "vmess" ? "UUID" : "密码", text: $node.secret)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if node.proto == "ss" {
                        Picker("加密方式", selection: $method) {
                            Text("沿用导入").tag("")
                            ForEach(methodChoices, id: \.self) { item in
                                Text(item).tag(item)
                            }
                        }
                    }
                }
                Section(footer: Text("加密方式必须与服务器一致。未改过的字段仍按导入链接生成出站。")) {
                    Text(node.detail).font(.footnote).foregroundColor(.secondary)
                    if node.proto != "ss" {
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
        if next.proto == "ss" {
            if method.isEmpty {
                next.params.removeValue(forKey: "method")
            } else {
                next.params["method"] = method
            }
        }
        let sameLink = next.server == original.server && next.port == original.port
            && next.secret == original.secret && next.params == original.params
        if !sameLink { next.raw = "" }
        store.update(next)
        Task { await VPNManager.shared.restartIfActive(store: store) }
        dismiss()
    }
}

struct SingBoxConfigDebugView: View {
    @ObservedObject private var store = ProxyStore.shared
    @State private var copied = false

    private var json: String {
        let raw = SingBoxConfig.build(nodes: store.nodes, selectedID: store.selected?.id,
                                      mode: store.selectionMode, bypassCN: store.bypassCN,
                                      rules: store.routingRules,
                                      categoryPolicies: store.categoryPolicies)
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else { return raw }
        return text
    }

    var body: some View {
        ScrollView {
            Text(json)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("sing-box 配置")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(copied ? "已复制" : "复制") {
                    UIPasteboard.general.string = json
                    copied = true
                }
            }
        }
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

    var body: some View {
        Form {
            TextEditor(text: $text).frame(minHeight: 100)
            Button("解析") {
                Task {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    do {
                        if t.lowercased().hasPrefix("http") {
                            nodes = try await LinkParser.fetchSubscription(t)
                        } else {
                            nodes = LinkParser.parseMany(t)
                        }
                        if nodes.isEmpty { error = "无节点" }
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
            if let error { Text(error).foregroundColor(.red) }
            if !nodes.isEmpty {
                Button("加入 \(nodes.count) 个") {
                    store.add(nodes)
                    dismiss()
                }
            }
        }
        .navigationTitle("导入")
    }
}

struct VPNLogView: View {
    @ObservedObject private var vpn = VPNManager.shared
    @State private var text = ""
    var body: some View {
        ScrollView {
            Text(text).font(.system(size: 11, design: .monospaced)).padding()
        }
        .navigationTitle("日志")
        .task { text = await vpn.fetchLog(allowDisconnected: true) }
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
