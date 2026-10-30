import SwiftUI
import NetworkExtension
import UIKit

struct ProxyHomeView: View {
    @ObservedObject private var store = ProxyStore.shared
    @ObservedObject private var vpn = VPNManager.shared
    @State private var editingNode: ProxyNode?
    @State private var showingDeleteAll = false
    @State private var alertMessage: ProxyHomeAlert?

    var body: some View {
        ProxyHomeList(
            store: store,
            vpn: vpn,
            onEditNode: { editingNode = $0 },
            onToast: { alertMessage = ProxyHomeAlert(title: "提示", message: $0) }
        )
        .navigationTitle("VPN 与节点")
        .toolbar { toolbarContent }
        .confirmationDialog("删除全部节点？", isPresented: $showingDeleteAll, titleVisibility: .visible) {
            Button("删除全部", role: .destructive) { store.removeAll() }
            Button("取消", role: .cancel) {}
        }
        .sheet(item: $editingNode) { node in
            NodeEditView(node: node)
        }
        .task {
            await vpn.load()
            await store.refreshLatency(vpnConnected: vpn.isConnected)
        }
        .onChange(of: vpn.status) { status in
            refreshAfterStatusChange(status)
        }
        .onChange(of: vpn.error) { message in
            if let message {
                alertMessage = ProxyHomeAlert(title: "出错了", message: message)
            }
        }
        .alert(item: $alertMessage) { item in
            Alert(
                title: Text(item.title),
                message: Text(item.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if !store.nodes.isEmpty {
                EditButton()
                Button(role: .destructive) {
                    showingDeleteAll = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("删除全部节点")
            }
        }
    }

    private func refreshAfterStatusChange(_ status: NEVPNStatus) {
        guard status == .connected || status == .disconnected else { return }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await store.refreshLatency(vpnConnected: vpn.isConnected)
        }
    }
}

private struct ProxyHomeAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct ProxyHomeList: View {
    @ObservedObject var store: ProxyStore
    @ObservedObject var vpn: VPNManager
    let onEditNode: (ProxyNode) -> Void
    let onToast: (String) -> Void

    var body: some View {
        List {
            VPNControlSection(store: store, vpn: vpn)
            ProxyDiagnosticsSection()
            ProxyNodeListSection(store: store, vpn: vpn, onEditNode: onEditNode)
            ProxyNodeActionsSection(store: store, onToast: onToast)
        }
        .scrollContentBackground(.hidden)
        .background(InkTheme.paperGradient.ignoresSafeArea())
    }
}

private struct VPNControlSection: View {
    @ObservedObject var store: ProxyStore
    @ObservedObject var vpn: VPNManager

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { vpn.isActive },
                set: { enabled in store.requestVPNState(enabled) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VPN")
                    Text(vpn.statusText)
                        .font(.caption)
                        .foregroundColor(InkTheme.inkSoft)
                }
            }
            .tint(InkTheme.cinnabar)

            TrafficMeterRows()

            Picker("节点选择", selection: $store.selectionMode) {
                Text("手动选择").tag(ProxySelectionMode.manual)
                Text("自动选择").tag(ProxySelectionMode.automatic)
            }
            Toggle("大陆常见域名直连", isOn: $store.bypassCN)
            Toggle("始终连接", isOn: $store.alwaysOn)
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
        } footer: {
            Text(vpn.extensionBundleID == nil
                 ? "当前安装包不含 VPN 扩展：节点管理可用，VPN 开关需要 VPN 版 IPA。"
                 : "内置 VPN 使用当前选中的节点。连接后显示上下行速率与流量统计。")
                .foregroundColor(InkTheme.inkSoft)
        }
    }
}

private struct ProxyDiagnosticsSection: View {
    var body: some View {
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
    }
}

private struct ProxyNodeListSection: View {
    @ObservedObject var store: ProxyStore
    @ObservedObject var vpn: VPNManager
    let onEditNode: (ProxyNode) -> Void

    var body: some View {
        Section {
            Button {
                Task { await store.refreshLatency(vpnConnected: vpn.isConnected) }
            } label: {
                Label(store.isRefreshing ? "正在刷新延迟…" : "刷新延迟", systemImage: "speedometer")
            }
            .disabled(store.isRefreshing || store.nodes.isEmpty)

            if let message = store.refreshError {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.red)
            }

            ForEach(store.nodes) { node in
                ProxyNodeRow(
                    node: node,
                    result: store.results[node.id],
                    selected: store.selectedID == node.id,
                    onSelect: { select(node) },
                    onEdit: { onEditNode(node) }
                )
            }
            .onDelete(perform: deleteNodes)
        } header: {
            Text("节点（\(store.nodes.count)）")
                .foregroundColor(InkTheme.inkSoft)
        }
    }

    private func select(_ node: ProxyNode) {
        store.selectedID = node.id
    }

    private func deleteNodes(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where store.nodes.indices.contains(index) {
            store.remove(store.nodes[index])
        }
    }
}

private struct ProxyNodeActionsSection: View {
    @ObservedObject var store: ProxyStore
    let onToast: (String) -> Void

    var body: some View {
        Section {
            NavigationLink {
                ImportNodesView()
            } label: {
                Label("从链接 / 订阅导入", systemImage: "square.and.arrow.down")
            }
            Button {
                copyClashConfiguration()
            } label: {
                Label("复制 Clash 配置", systemImage: "doc.on.doc")
            }
            .disabled(store.nodes.isEmpty)
        }
    }

    private func copyClashConfiguration() {
        let text = ClashConfig.build(
            nodes: store.nodes,
            selectedID: store.selectedID,
            selectionMode: store.selectionMode,
            bypassCN: store.bypassCN,
            routingRules: store.routingRules,
            categoryPolicies: store.categoryPolicies
        )
        guard !text.isEmpty else {
            onToast("当前没有可导出的节点")
            return
        }
        UIPasteboard.general.string = text
        onToast("已复制到剪贴板")
    }
}

private struct ProxyNodeRow: View {
    let node: ProxyNode
    let result: ProxyProbeResult?
    let selected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(node.name)
                    .foregroundColor(InkTheme.ink)
                Text(node.detail)
                    .font(.caption2)
                    .foregroundColor(InkTheme.inkSoft)
            }
            Spacer(minLength: 8)
            if let result {
                Text(result.label)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(result.isReachable ? InkTheme.pine : .secondary)
            }
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(InkTheme.cinnabar)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button(action: onEdit) {
                Label("编辑", systemImage: "pencil")
            }
            .tint(InkTheme.cinnabar)
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
                TextField("名称", text: $node.name)
                TextField("地址", text: $node.server)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("端口", text: $portText)
                    .keyboardType(.numberPad)
                TextField(node.proto == "ss" ? "密码" : "UUID / 密码", text: $node.secret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if node.proto == "ss" {
                    Picker("加密", selection: encryptionMethod) {
                        Text("aes-128-gcm").tag("aes-128-gcm")
                        Text("aes-256-gcm").tag("aes-256-gcm")
                        Text("chacha20-ietf-poly1305").tag("chacha20-ietf-poly1305")
                    }
                }
                if !node.params.isEmpty {
                    Section("高级参数") {
                        ForEach(node.params.keys.sorted(), id: \.self) { key in
                            LabeledContent(key, value: node.params[key] ?? "")
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
                    Button("保存", action: save)
                }
            }
        }
    }

    private var encryptionMethod: Binding<String> {
        Binding(
            get: { node.params["method"] ?? "aes-128-gcm" },
            set: { node.params["method"] = $0 }
        )
    }

    private func save() {
        node.port = Int(portText) ?? node.port
        store.update(node)
        dismiss()
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
            ForEach(store.routingRules) { rule in
                RoutingRuleRow(rule: rule)
            }
            .onDelete { store.routingRules.remove(atOffsets: $0) }

            RoutingRuleEditorSection(kind: $kind, value: $value, target: $target) {
                addRule()
            }

            Section {
                Button("应用并重连 VPN") {
                    store.applyVPNChangesNow()
                }
            } footer: {
                Text("修改规则会自动保存并应用；也可手动点上面按钮。")
            }
        }
        .navigationTitle("分流规则")
    }

    private func addRule() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.routingRules.append(ProxyRoutingRule(kind: kind, value: trimmed, target: target))
        value = ""
    }
}

private struct RoutingRuleRow: View {
    let rule: ProxyRoutingRule

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.value)
                Text(rule.kind == .domainSuffix ? "域名后缀" : "IP CIDR")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(rule.target == .direct ? "直连" : "代理")
                .foregroundColor(.secondary)
        }
    }
}

private struct RoutingRuleEditorSection: View {
    @Binding var kind: ProxyRoutingRule.Kind
    @Binding var value: String
    @Binding var target: ProxyRoutingRule.Target
    let onAdd: () -> Void

    var body: some View {
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
            Button("添加", action: onAdd)
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

struct TrafficCategoriesView: View {
    @ObservedObject private var store = ProxyStore.shared

    var body: some View {
        List {
            Section {
                ForEach(ProxyTrafficCategory.allCases) { category in
                    Picker(selection: policyBinding(for: category)) {
                        ForEach(ProxyGroupPolicy.allCases, id: \.self) { policy in
                            Text(policy.title).tag(policy)
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

    private func policyBinding(for category: ProxyTrafficCategory) -> Binding<ProxyGroupPolicy> {
        Binding(
            get: { store.policy(for: category) },
            set: { store.setPolicy($0, for: category) }
        )
    }
}

struct ImportNodesView: View {
    @ObservedObject private var store = ProxyStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var nodes: [ProxyNode] = []
    @State private var error: String?
    @State private var isLoading = false

    var body: some View {
        Form {
            TextEditor(text: $text)
                .frame(minHeight: 120)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(isLoading ? "正在解析…" : "解析") {
                Task { await parse() }
            }
            .disabled(isLoading || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let error {
                Text(error)
                    .foregroundColor(.red)
                    .font(.footnote)
            }
            if !nodes.isEmpty {
                Section("预览（\(nodes.count) 个节点）") {
                    ForEach(nodes) { node in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.name)
                            Text(node.detail)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
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
        isLoading = true
        error = nil
        nodes = []
        defer { isLoading = false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.lowercased().hasPrefix("http") {
                nodes = try await LinkParser.fetchSubscription(trimmed)
            } else {
                nodes = LinkParser.parseMany(trimmed)
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
                Button("刷新") { Task { await loadLog() } }
            }
        }
        .task { await loadLog() }
    }

    private func loadLog() async {
        text = await vpn.fetchLog()
    }
}

struct NodeDeployView: View {
    var body: some View {
        Text("部署")
            .padding()
    }
}
