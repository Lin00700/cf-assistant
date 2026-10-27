import SwiftUI
import NetworkExtension

struct ProxyHomeView: View {
    @ObservedObject private var store = ProxyStore.shared
    @ObservedObject private var vpn = VPNManager.shared
    @ObservedObject private var traffic = VPNTraffic.shared
    @State private var error: String?
    @State private var confirmResetTraffic = false
    @State private var confirmClear = false
    @State private var editing: ProxyNode?
    @State private var toast: String?
    @State private var category = "全部"

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
        for n in store.nodes where !seen.contains(n.proto) {
            seen.append(n.proto)
        }
        return seen
    }

    private var visibleProtocols: [String] {
        if category == "全部" { return protocols }
        return protocols.filter { title($0) == category }
    }

    private func nodes(of proto: String) -> [ProxyNode] {
        store.nodes.filter { $0.proto == proto }
    }

    var body: some View {
        List {
            Section {
                vpnToggle
                if vpn.isConnected || traffic.sessionUp > 0 || traffic.sessionDown > 0 {
                    trafficRows
                }
                Picker("节点选择", selection: $store.selectionMode) {
                    Text("手动选择").tag(ProxySelectionMode.manual)
                    Text("自动选择").tag(ProxySelectionMode.automatic)
                }
                NavigationLink {
                    RoutingRulesView()
                } label: {
                    Label("自定义分流规则（\(store.routingRules.count)）", systemImage: "arrow.triangle.branch")
                }
                NavigationLink {
                    TrafficCategoriesView()
                } label: {
                    Label("软件流量分类", systemImage: "square.grid.2x2")
                }
                Toggle("大陆常见域名直连", isOn: $store.bypassCN)
                Toggle("始终连接", isOn: $store.alwaysOn)
            } footer: {
                Text(vpn.extensionBundleID == nil
                     ? "当前安装包不含 VPN 扩展。"
                     : "内置 VPN 使用选中的节点。")
            }

            Section {
                NavigationLink {
                    ConnectivityDiagnosticsView()
                } label: {
                    Label("连接诊断", systemImage: "stethoscope")
                }
                NavigationLink {
                    VPNLogView()
                } label: {
                    Label("VPN 运行日志", systemImage: "doc.text.magnifyingglass")
                }
            }

            Section {
                Picker("分类", selection: $category) {
                    Text("全部").tag("全部")
                    ForEach(protocols, id: \.self) { p in
                        Text(title(p)).tag(title(p))
                    }
                }
                Button("刷新延迟") {
                    Task { await store.refreshLatency(vpnConnected: vpn.isConnected) }
                }
            } header: {
                Text("节点")
            }

            ForEach(visibleProtocols, id: \.self) { proto in
                Section(title(proto)) {
                    ForEach(nodes(of: proto)) { n in
                        nodeRow(n)
                    }
                    .onDelete { offsets in
                        let list = nodes(of: proto)
                        for i in offsets {
                            store.remove(list[i])
                        }
                    }
                }
            }

            Section("添加") {
                NavigationLink {
                    ImportNodesView()
                } label: {
                    Label("从链接 / 订阅导入", systemImage: "link")
                }
            }

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
                    toast = "已复制"
                }
                .disabled(store.nodes.isEmpty)
            }
        }
        .navigationTitle("VPN 与节点")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !store.nodes.isEmpty {
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .confirmationDialog("删除全部节点？", isPresented: $confirmClear) {
            Button("删除全部", role: .destructive) { store.removeAll() }
        }
        .confirmationDialog("流量归零", isPresented: $confirmResetTraffic) {
            Button("仅清本次会话") { traffic.resetSession() }
            Button("全部归零", role: .destructive) { traffic.resetAll() }
        }
        .sheet(item: $editing) { n in
            NodeEditView(node: n)
        }
        .task {
            await vpn.load()
            await store.refreshLatency(vpnConnected: vpn.isConnected)
        }
        .onChange(of: vpn.status) { _, status in
            if status == .connected || status == .disconnected {
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await store.refreshLatency(vpnConnected: vpn.isConnected)
                }
            }
        }
        .onChange(of: vpn.error) { _, e in
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
        .alert("提示", isPresented: Binding(
            get: { toast != nil },
            set: { if !$0 { toast = nil } }
        )) {
            Button("好") { toast = nil }
        } message: {
            Text(toast ?? "")
        }
    }

    private var vpnToggle: some View {
        Toggle(isOn: Binding(
            get: { vpn.isActive },
            set: { on in
                Task { await vpn.set(on: on, store: store) }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("VPN")
                Text(vpn.statusText).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var trafficRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("↑ \(VPNTraffic.formatRate(traffic.uploadRate))")
                Spacer()
                Text("↓ \(VPNTraffic.formatRate(traffic.downloadRate))")
            }
            .font(.callout.monospacedDigit())
            Text("会话 ↑\(VPNTraffic.formatBytes(traffic.sessionUp)) ↓\(VPNTraffic.formatBytes(traffic.sessionDown))")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
            HStack {
                Text("累计 ↑\(VPNTraffic.formatBytes(traffic.totalUp)) ↓\(VPNTraffic.formatBytes(traffic.totalDown))")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                Spacer()
                Button("归零") { confirmResetTraffic = true }
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private func nodeRow(_ n: ProxyNode) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(n.name)
                Text(n.detail).font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            if let r = store.results[n.id] {
                Text(r.label).font(.caption.monospacedDigit()).foregroundColor(.secondary)
            }
            if store.selectedID == n.id {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedID = n.id
            Task { await vpn.restartIfActive(store: store) }
        }
        .swipeActions(edge: .leading) {
            Button("编辑") { editing = n }
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
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", text: $portText)
                        .keyboardType(.numberPad)
                    TextField(node.proto == "ss" ? "密码" : "UUID", text: $node.secret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
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
            Section {
                ForEach(store.routingRules) { r in
                    HStack {
                        Text(r.value)
                        Spacer()
                        Text(r.target == .direct ? "直连" : "代理")
                            .foregroundColor(.secondary)
                    }
                }
                .onDelete { idx in
                    store.routingRules.remove(atOffsets: idx)
                }
            }
            Section("添加") {
                Picker("类型", selection: $kind) {
                    Text("域名后缀").tag(ProxyRoutingRule.Kind.domainSuffix)
                    Text("IP CIDR").tag(ProxyRoutingRule.Kind.ipCIDR)
                }
                TextField("值", text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
                    Label(category.title, systemImage: category.symbol)
                }
            }
        }
        .navigationTitle("软件流量分类")
    }
}

struct NodeDeployView: View {
    var body: some View {
        Text("请在完整版使用部署").padding()
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
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 120)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section {
                Button("解析") {
                    Task { await parse() }
                }
                .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error {
                Section {
                    Text(error).foregroundColor(.red).font(.footnote)
                }
            }
            if !nodes.isEmpty {
                Section("将导入 \(nodes.count) 个") {
                    ForEach(nodes) { n in
                        Text(n.name)
                    }
                    Button("全部加入") {
                        store.add(nodes)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("导入节点")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
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
            if nodes.isEmpty {
                error = "没有解析到有效节点"
            }
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
                Button("刷新") {
                    Task { text = await vpn.fetchLog() }
                }
            }
        }
        .task {
            text = await vpn.fetchLog()
        }
    }
}
