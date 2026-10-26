import SwiftUI

// MARK: - VPN 主页

struct ProxyHomeView: View {
    @ObservedObject private var store = ProxyStore.shared
    @ObservedObject private var vpn = VPNManager.shared
    @State private var error: String?
    @State private var category = "全部"
    @State private var editing: ProxyNode?
    @State private var confirmClear = false
    @State private var toast: String?

    private func title(_ proto: String) -> String {
        switch proto {
        case "ss": return "Shadowsocks"
        case "vless": return "VLESS"
        case "vmess": return "VMess"
        case "trojan": return "Trojan"
        case "hysteria2": return "Hysteria2"
        default: return proto.uppercased()
        }
    }

    private var protocols: [String] {
        var seen: [String] = []
        for n in store.nodes where !seen.contains(n.proto) { seen.append(n.proto) }
        return seen
    }

    private var visibleProtocols: [String] {
        category == "全部" ? protocols : protocols.filter { title($0) == category }
    }

    private func nodes(of proto: String) -> [ProxyNode] {
        store.nodes.filter { $0.proto == proto }
    }

    private var reachableCount: Int { store.results.values.filter { $0.isReachable }.count }
    private var testedCount: Int { store.results.values.filter { $0.countsAsTested }.count }

    var body: some View {
        List {
            vpnSection
            diagnosticsSection
            nodeHeaderSection
            ForEach(visibleProtocols, id: \.self) { proto in
                Section(header: Text("\(title(proto))（\(nodes(of: proto).count)）")) {
                    ForEach(nodes(of: proto)) { n in row(n) }
                        .onDelete { idx in
                            let list = nodes(of: proto)
                            for i in idx { store.remove(list[i]) }
                        }
                }
            }
            addSection
            exportSection
        }
        .navigationTitle("VPN 与节点")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !store.nodes.isEmpty {
                    EditButton()
                    Button(role: .destructive) { confirmClear = true } label: { Image(systemName: "trash") }
                }
            }
        }
        .confirmationDialog("删除全部节点？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("删除全部", role: .destructive) { store.removeAll() }
        }
        .sheet(item: $editing) { n in NodeEditView(node: n) }
        .task {
            await vpn.load()
            await store.refreshLatency(vpnConnected: vpn.isConnected)
        }
        .onChange(of: vpn.status) { s in
            if s == .connected || s == .disconnected {
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await store.refreshLatency(vpnConnected: vpn.isConnected)
                }
            }
        }
        .onChange(of: vpn.error) { e in if let e { error = e } }
        .onChange(of: store.selectionMode) { _ in Task { await vpn.restartIfActive(store: store) } }
        .onChange(of: store.bypassCN) { _ in Task { await vpn.restartIfActive(store: store) } }
        .errorAlert($error)
        .alert("提示", isPresented: Binding(get: { toast != nil }, set: { _ in })) {
            Button("好") { toast = nil }
        } message: { Text(toast ?? "") }
    }

    private var vpnSection: some View {
        Section(footer: Text(vpn.extensionBundleID == nil
                             ? "当前安装包不含 VPN 扩展：节点管理可用，开关需要「VPN 版」IPA。"
                             : "内置 VPN 使用选中的节点。也可把节点交给 Shadowrocket 等外部客户端，但连接和分流需在外部客户端内操作。")) {
            Toggle(isOn: Binding(
                get: { vpn.isActive },
                set: { on in Task { await vpn.set(on: on, store: store) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VPN").font(.headline)
                    Text(vpn.statusText).font(.caption).foregroundColor(.secondary)
                }
            }
            Picker("节点选择", selection: $store.selectionMode) {
                Text("手动选择").tag(ProxySelectionMode.manual)
                Text("自动选择").tag(ProxySelectionMode.automatic)
            }
            NavigationLink { RoutingRulesView() } label: {
                Label("自定义分流规则（\(store.routingRules.count)）", systemImage: "arrow.triangle.branch")
            }
            Toggle("大陆常见域名直连", isOn: $store.bypassCN)
        }
    }

    private var diagnosticsSection: some View {
        Section(footer: Text("测试 DNS、IPv4 / IPv6 和 HTTP，并保存可分享的诊断记录。")) {
            NavigationLink { ConnectivityDiagnosticsView() } label: {
                HStack {
                    Label("连接诊断", systemImage: "stethoscope")
                    Spacer()
                    Text(vpn.isConnected ? "VPN 已连接" : "需先连接 VPN")
                        .font(.caption)
                        .foregroundColor(vpn.isConnected ? .green : .secondary)
                }
            }
            NavigationLink { VPNLogView() } label: {
                Label("VPN 运行日志", systemImage: "doc.text.magnifyingglass")
            }
        }
    }

    private var nodeHeaderSection: some View {
        Section(header: HStack {
            Text("节点")
            Spacer()
            Text("连通 \(reachableCount)/\(testedCount)")
                .font(.caption).foregroundColor(.secondary)
            Button("刷新延迟") {
                Task { await store.refreshLatency(vpnConnected: vpn.isConnected) }
            }.font(.caption)
        }, footer: Text(vpn.isConnected
            ? "开启 VPN 时会逐个节点通过 HTTPS（Cloudflare）探测真实代理延迟；“探测失败”不等于节点失效。左滑节点可编辑地址、端口等设置。"
            : "未连接内置 VPN 时也可刷新：测试节点 TCP 端口是否可连及建连延迟，不代表代理握手或实际出站速度。左滑节点可编辑。")) {
            Picker("节点分类", selection: $category) {
                Text("全部").tag("全部")
                ForEach(protocols, id: \.self) { p in Text(title(p)).tag(title(p)) }
            }
        }
    }

    private func row(_ n: ProxyNode) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(n.name)
                Text(n.detail).font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            if let r = store.results[n.id] {
                Text(r.label).font(.caption).foregroundColor(r.color)
            }
            if store.selectedID == n.id {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.orange)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            store.select(n)
            Task { await vpn.restartIfActive(store: store) }
        }
        .swipeActions(edge: .leading) {
            Button { editing = n } label: { Text("编辑") }.tint(.blue)
        }
        .contextMenu {
            Button("复制分享链接") {
                let link = LinkParser.shareLink(n)
                UIPasteboard.general.string = link.isEmpty ? n.detail : link
            }
            Button("编辑") { editing = n }
        }
    }

    private var addSection: some View {
        Section("添加节点") {
            NavigationLink { ImportNodesView() } label: {
                Label("从链接 / 订阅导入", systemImage: "link")
            }
            NavigationLink { NodeDeployView() } label: {
                Label("部署 Cloudflare Worker 节点", systemImage: "cloud")
            }
        }
    }

    private var exportSection: some View {
        Section("导出到其他客户端") {
            let count = ClashConfig.exportableNodeCount(nodes: store.nodes)
            Button("复制 Clash 配置（\(count) 节点）") {
                let text = ClashConfig.build(nodes: store.nodes, selectedID: store.selectedID,
                                             mode: store.selectionMode, bypassCN: store.bypassCN,
                                             rules: store.routingRules)
                UIPasteboard.general.string = text
                toast = "已复制 Clash 配置"
            }
            .disabled(count == 0)
        }
    }
}

// MARK: - Latency display helper

extension ProxyLatencyResult {
    var label: String {
        switch self {
        case .latency(let ms), .tcpLatency(let ms): return "\(ms) ms"
        case .failed: return "探测失败"
        case .untested: return ""
        }
    }
    var color: Color {
        switch self {
        case .latency(let ms), .tcpLatency(let ms): return ms < 200 ? .green : .orange
        case .failed: return .orange
        case .untested: return .secondary
        }
    }
    var isReachable: Bool {
        if case .failed = self { return false }
        if case .untested = self { return false }
        return true
    }
    var countsAsTested: Bool {
        if case .untested = self { return false }
        return true
    }
}

// MARK: - 节点编辑

struct NodeEditView: View {
    @ObservedObject private var store = ProxyStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var node: ProxyNode
    @State private var portText: String

    init(node: ProxyNode) {
        _node = State(initialValue: node)
        _portText = State(initialValue: String(node.port))
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
                        Picker("加密方式", selection: Binding(
                            get: { node.params["method"] ?? "aes-128-gcm" },
                            set: { node.params["method"] = $0 }
                        )) {
                            Text("aes-128-gcm").tag("aes-128-gcm")
                            Text("aes-256-gcm").tag("aes-256-gcm")
                            Text("chacha20-ietf-poly1305").tag("chacha20-ietf-poly1305")
                            Text("2022-blake3-aes-128-gcm").tag("2022-blake3-aes-128-gcm")
                            Text("2022-blake3-aes-256-gcm").tag("2022-blake3-aes-256-gcm")
                        }
                    }
                }
                Section(footer: Text("改了参数后分享链接会按新值重新生成。加密方式必须与服务器一致，否则 TCP 能通但 HTTPS 会超时。")) {
                    Text(node.detail).font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("编辑节点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var n = node
                        n.port = Int(portText) ?? n.port
                        n.raw = ""
                        store.update(n)
                        Task { await VPNManager.shared.restartIfActive(store: store) }
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 自定义分流规则

struct RoutingRulesView: View {
    @ObservedObject private var store = ProxyStore.shared
    @State private var kind: ProxyRoutingRule.Kind = .domainSuffix
    @State private var value = ""
    @State private var target: ProxyRoutingRule.Target = .direct

    var body: some View {
        List {
            Section(footer: Text("规则按顺序匹配，早于「大陆常见域名直连」。修改后需重新连接 VPN 生效。")) {
                ForEach(store.routingRules) { r in
                    HStack {
                        Text(r.kind == .domainSuffix ? "域名" : "IP")
                        Text(r.value).foregroundColor(.secondary)
                        Spacer()
                        Text(r.target == .direct ? "直连" : "代理")
                    }
                }
                .onDelete { idx in
                    store.routingRules.remove(atOffsets: idx)
                    Task { await VPNManager.shared.restartIfActive(store: store) }
                }
            }
            Section("添加规则") {
                Picker("类型", selection: $kind) {
                    Text("域名后缀").tag(ProxyRoutingRule.Kind.domainSuffix)
                    Text("IP CIDR").tag(ProxyRoutingRule.Kind.ipCIDR)
                }
                TextField(kind == .domainSuffix ? "例如 example.com" : "例如 10.0.0.0/8", text: $value)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("走向", selection: $target) {
                    Text("直连").tag(ProxyRoutingRule.Target.direct)
                    Text("代理").tag(ProxyRoutingRule.Target.proxy)
                }
                Button("添加") {
                    let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !v.isEmpty else { return }
                    store.routingRules.append(ProxyRoutingRule(kind: kind, value: v, target: target))
                    value = ""
                    Task { await VPNManager.shared.restartIfActive(store: store) }
                }
            }
        }
        .navigationTitle("分流规则")
    }
}

// MARK: - 部署节点

struct NodeDeployView: View {
    @ObservedObject private var store = ProxyStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = "cf-vless"
    @State private var uuid = UUID().uuidString
    @State private var address = ""
    @State private var busy = false
    @State private var result: String?

    var body: some View {
        Form {
            Section(footer: Text("部署一个 VLESS + WebSocket 的 Worker，成功后节点自动加入列表并选中。")) {
                TextField("Worker 名称", text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("UUID", text: $uuid)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section(footer: Text("留空则直接连 workers.dev 域名。")) {
                TextField("连接地址（可填优选 IP，可留空）", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section {
                Button {
                    Task { await deploy() }
                } label: {
                    HStack { Spacer(); if busy { ProgressView() } else { Text("部署并添加节点") }; Spacer() }
                }
                .disabled(busy || name.isEmpty || uuid.isEmpty)
            }
            if let r = result { Section { Text(r).font(.footnote) } }
        }
        .navigationTitle("部署 Worker")
    }

    private func deploy() async {
        busy = true
        defer { busy = false }
        let host = address.isEmpty ? "\(name).workers.dev" : address
        let node = NodeWorker.makeVLESS(name: name, address: host, uuid: uuid)
        store.add(node)
        store.select(node)
        result = "已添加节点 \(host)"
    }
}

// MARK: - 导入节点

struct ImportNodesView: View {
    @ObservedObject private var store = ProxyStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var nodes: [ProxyNode] = []
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text).frame(minHeight: 120)
                Text("粘贴节点链接（vless / vmess / trojan / ss / hysteria2），或订阅地址 https://…")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Section {
                Button("解析") { Task { await parse() } }
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error {
                Section { Text(error).foregroundColor(.red).font(.footnote) }
            }
            if !nodes.isEmpty {
                Section("将导入 \(nodes.count) 个节点") {
                    ForEach(nodes) { n in
                        VStack(alignment: .leading) {
                            Text(n.name)
                            Text(n.detail).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    Button("全部加入") {
                        for n in nodes { store.add(n) }
                        if store.selected == nil { store.select(nodes[0]) }
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("导入节点")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
        }
    }

    private func parse() async {
        busy = true
        error = nil
        nodes = []
        defer { busy = false }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://") {
                nodes = try await LinkParser.fetchSubscription(t)
            } else {
                nodes = LinkParser.parseMany(t)
            }
            if nodes.isEmpty { error = "没有解析到有效节点" }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - VPN 日志

struct VPNLogView: View {
    @ObservedObject private var vpn = VPNManager.shared
    @State private var text = "读取中…"

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .navigationTitle("VPN 日志")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button("复制") { UIPasteboard.general.string = text }
                Button("刷新") { Task { text = await vpn.fetchLog() } }
            }
        }
        .task { text = await vpn.fetchLog() }
    }
}
