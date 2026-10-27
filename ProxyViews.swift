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
                Section(header: Text("\(title(proto))（\(nodes(of: proto).count)）").foregroundColor(InkTheme.inkSoft)) {
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
        .scrollContentBackground(.hidden)
        .background(InkTheme.paperGradient.ignoresSafeArea())
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
        .onChange(of: vpn.status) { _, s in
            if s == .connected || s == .disconnected {
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await store.refreshLatency(vpnConnected: vpn.isConnected)
                }
            }
        }
        .onChange(of: vpn.error) { _, e in
            if let e { error = e }
        }
        .errorAlert($error)
        .alert("提示", isPresented: Binding(get: { toast != nil }, set: { if !$0 { toast = nil } })) {
            Button("好") { toast = nil }
        } message: { Text(toast ?? "") }
    }

    private var vpnSection: some View {
        Section(footer: Text(vpn.extensionBundleID == nil
                             ? "当前安装包不含 VPN 扩展：节点管理可用，开关需要「VPN 版」IPA。"
                             : "内置 VPN 使用选中的节点。")
            .foregroundColor(InkTheme.inkSoft)) {
            Toggle(isOn: Binding(
                get: { vpn.isActive },
                set: { on in Task { await vpn.set(on: on, store: store) } }
            )) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(vpn.isActive ? InkTheme.cinnabar : InkTheme.ink.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: vpn.isActive ? "seal.fill" : "seal")
                            .foregroundColor(vpn.isActive ? InkTheme.paper : InkTheme.inkSoft)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VPN").font(.headline).foregroundColor(InkTheme.ink)
                        Text(vpn.statusText).font(.caption).foregroundColor(InkTheme.inkSoft)
                    }
                }
            }
            .tint(InkTheme.cinnabar)
            Picker("节点选择", selection: $store.selectionMode) {
                Text("手动选择").tag(ProxySelectionMode.manual)
                Text("自动选择").tag(ProxySelectionMode.automatic)
            }
            NavigationLink { RoutingRulesView() } label: {
                Label("自定义分流规则（\(store.routingRules.count)）", systemImage: "arrow.triangle.branch")
            }
            NavigationLink { TrafficCategoriesView() } label: {
                Label("软件流量分类", systemImage: "square.grid.2x2")
            }
            Toggle("大陆常见域名直连", isOn: $store.bypassCN).tint(InkTheme.cinnabar)
            Toggle("始终连接", isOn: $store.alwaysOn).tint(InkTheme.cinnabar)
        }
        .listRowBackground(InkTheme.paper.opacity(0.72))
    }

    private var diagnosticsSection: some View {
        Section {
            NavigationLink { ConnectivityDiagnosticsView() } label: {
                HStack {
                    Label("连接诊断", systemImage: "stethoscope")
                    Spacer()
                    Text(vpn.isConnected ? "VPN 已连接" : "需先连接 VPN")
                        .font(.caption)
                        .foregroundColor(vpn.isConnected ? InkTheme.pine : InkTheme.inkSoft)
                }
            }
            NavigationLink { VPNLogView() } label: {
                Label("VPN 运行日志", systemImage: "doc.text.magnifyingglass")
            }
        }
        .listRowBackground(InkTheme.paper.opacity(0.72))
    }

    private var nodeHeaderSection: some View {
        Section {
            Picker("节点分类", selection: $category) {
                Text("全部").tag("全部")
                ForEach(protocols, id: \.self) { p in Text(title(p)).tag(title(p)) }
            }
            Button("刷新延迟") {
                Task { await store.refreshLatency(vpnConnected: vpn.isConnected) }
            }
            .font(.caption)
            .foregroundColor(InkTheme.cinnabar)
        } header: {
            HStack {
                Text("节点")
                Spacer()
                Text("连通 \(reachableCount)/\(testedCount)")
                    .font(.caption).foregroundColor(InkTheme.inkSoft)
            }
        }
    }

    private func row(_ n: ProxyNode) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1)
                .fill(store.selectedID == n.id ? InkTheme.cinnabar : InkTheme.gold.opacity(0.55))
                .frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(n.name).foregroundColor(InkTheme.ink)
                Text(n.detail).font(.caption2).foregroundColor(InkTheme.inkSoft)
            }
            Spacer()
            if let r = store.results[n.id] {
                Text(r.label).font(.caption.monospacedDigit()).foregroundColor(color(for: r))
            }
            if store.selectedID == n.id {
                Image(systemName: "seal.fill").foregroundColor(InkTheme.cinnabar)
            }
        }
        .listRowBackground(InkTheme.paper.opacity(0.72))
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedID = n.id
            Task { await vpn.restartIfActive(store: store) }
        }
        .swipeActions(edge: .leading) {
            Button { editing = n } label: { Text("编辑") }.tint(InkTheme.cinnabar)
        }
    }

    private func color(for r: ProxyProbeResult) -> Color {
        switch r {
        case .latency(let ms), .tcpLatency(let ms): return ms < 200 ? InkTheme.pine : InkTheme.gold
        case .unreachable, .probeFailed: return InkTheme.cinnabar
        case .requiresVPN: return InkTheme.inkSoft
        }
    }

    private var addSection: some View {
        Section("添加节点") {
            NavigationLink { ImportNodesView() } label: {
                Label("从链接 / 订阅导入", systemImage: "link")
            }
        }
    }

    private var exportSection: some View {
        Section("导出") {
            Button("复制 Clash 配置") {
                let text = ClashConfig.build(
                    nodes: store.nodes,
                    selectedID: store.selectedID,
                    selectionMode: store.selectionMode,
                    bypassCN: store.bypassCN,
                    routingRules: store.routingRules,
                    categoryPolicies: store.categoryPolicies
                )
                UIPasteboard.general.string = text
                toast = "已复制 Clash 配置"
            }
            .disabled(store.nodes.isEmpty)
        }
    }
}

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
                Section {
                    TextField("名称", text: $node.name)
                    TextField("地址", text: $node.server)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("端口", text: $portText).keyboardType(.numberPad)
                    TextField(node.proto == "ss" ? "密码" : "UUID", text: $node.secret)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if node.proto == "ss" {
                        Picker("加密", selection: Binding(
                            get: { node.params["method"] ?? "aes-128-gcm" },
                            set: { node.params["method"] = $0 }
                        )) {
                            Text("aes-128-gcm").tag("aes-128-gcm")
                            Text("aes-256-gcm").tag("aes-256-gcm")
                            Text("chacha20-ietf-poly1305").tag("chacha20-ietf-poly1305")
                        }
                    }
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
                        store.update(n)
                        Task { await VPNManager.shared.restartIfActive(store: store) }
                        dismiss()
                    }
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
            ForEach(store.routingRules) { r in
                HStack {
                    Text(r.value)
                    Spacer()
                    Text(r.target == .direct ? "直连" : "代理").foregroundColor(.secondary)
                }
            }
            .onDelete { idx in store.routingRules.remove(atOffsets: idx) }
            Section("添加") {
                Picker("类型", selection: $kind) {
                    Text("域名后缀").tag(ProxyRoutingRule.Kind.domainSuffix)
                    Text("IP CIDR").tag(ProxyRoutingRule.Kind.ipCIDR)
                }
                TextField("值", text: $value)
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
                }
            }
        }
        .navigationTitle("分流规则")
    }
}

struct TrafficCategoriesView: View {
    @ObservedObject private var store = ProxyStore.shared

    var body: some View {
        List {
            ForEach(ProxyTrafficCategory.allCases) { category in
                Picker(selection: Binding(
                    get: { store.policy(for: category) },
                    set: { store.setPolicy($0, for: category) }
                )) {
                    ForEach(ProxyGroupPolicy.allCases, id: \.self) { p in
                        Text(p.title).tag(p)
                    }
                } label: {
                    Text(category.title)
                }
            }
        }
        .navigationTitle("软件流量分类")
    }
}

struct ImportNodesView: View {
    @ObservedObject private var store = ProxyStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var nodes: [ProxyNode] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            TextEditor(text: $text).frame(minHeight: 120)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("解析") { Task { await parse() } }
                .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let error { Text(error).foregroundColor(.red).font(.footnote) }
            if !nodes.isEmpty {
                ForEach(nodes) { n in Text(n.name) }
                Button("全部加入") { store.add(nodes); dismiss() }
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
            if t.lowercased().hasPrefix("http") {
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

struct VPNLogView: View {
    @ObservedObject private var vpn = VPNManager.shared
    @State private var text = "读取中…"

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("VPN 日志")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("刷新") { Task { text = await vpn.fetchLog() } }
            }
        }
        .task { text = await vpn.fetchLog() }
    }
}

struct NodeDeployView: View {
    var body: some View {
        Text("请在完整版使用部署").padding()
    }
}
