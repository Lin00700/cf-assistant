import SwiftUI

// MARK: - VPN 主页

private struct ProxyNodeCategory: Identifiable {
    var id: String { title }
    let title: String
    let nodes: [ProxyNode]
}

private struct ProxyNodeLatencyLabel: View {
    let result: ProxyProbeResult?

    private var color: Color {
        guard let result else { return .secondary }
        switch result {
        case .latency(let milliseconds):
            if milliseconds < 150 { return .green }
            if milliseconds < 400 { return .orange }
            return .red
        case .tcpLatency(let milliseconds):
            if milliseconds < 150 { return .green }
            if milliseconds < 400 { return .orange }
            return .red
        case .unreachable:
            return .red
        case .requiresVPN:
            return .secondary
        }
    }

    var body: some View {
        Text(result?.label ?? "未测")
            .font(.caption.monospacedDigit())
            .foregroundColor(color)
    }
}

private struct ProxyNodeRow: View {
    let node: ProxyNode
    let subscriptionName: String?
    let latencyResult: ProxyProbeResult?
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name).foregroundColor(.primary)
                    Text(node.detail).font(.caption).foregroundColor(.secondary)
                    if let subscriptionName {
                        Text("订阅：\(subscriptionName)").font(.caption2).foregroundColor(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    ProxyNodeLatencyLabel(result: latencyResult)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.orange)
                    }
                }
            }
        }
        .contextMenu {
            Button(action: onEdit) {
                Label("编辑节点", systemImage: "pencil")
            }
            Button("复制分享链接", action: onCopy)
            Button(role: .destructive, action: onDelete) {
                Label("删除节点", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
            Button(action: onEdit) {
                Label("编辑", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }
}

private struct ProxyNodeCategorySection: View {
    let category: ProxyNodeCategory
    let latencyByNode: [UUID: ProxyProbeResult]
    let selectionMode: ProxySelectionMode
    let selectedID: UUID?
    let subscriptionName: (ProxyNode) -> String?
    let onSelect: (ProxyNode) -> Void
    let onEdit: (ProxyNode) -> Void
    let onCopy: (ProxyNode) -> Void
    let onDeleteNode: (ProxyNode) -> Void
    let onDelete: (Set<UUID>) -> Void

    var body: some View {
        Section {
            ForEach(category.nodes) { node in
                ProxyNodeRow(
                    node: node,
                    subscriptionName: subscriptionName(node),
                    latencyResult: latencyByNode[node.id],
                    isSelected: selectionMode == .manual && node.id == selectedID,
                    onSelect: { onSelect(node) },
                    onEdit: { onEdit(node) },
                    onCopy: { onCopy(node) },
                    onDelete: { onDeleteNode(node) }
                )
            }
            .onDelete { offsets in
                let ids = Set(offsets.map { category.nodes[$0].id })
                onDelete(ids)
            }
        } header: {
            Text("\(category.title)（\(category.nodes.count)）")
        }
    }
}

private struct ProxyNodeListSection: View {
    let nodes: [ProxyNode]
    let categoryNames: [String]
    @Binding var protocolFilter: String
    let isVPNConnected: Bool
    let testedLatencyCount: Int
    let reachableLatencyCount: Int
    let isRefreshingLatency: Bool
    let onRefresh: () -> Void

    var body: some View {
        Section {
            if nodes.isEmpty {
                EmptyHint(text: "还没有节点，下面可以部署或导入")
            }
            if !nodes.isEmpty {
                Picker("节点分类", selection: $protocolFilter) {
                    Text("全部").tag("全部")
                    ForEach(categoryNames, id: \.self) { category in
                        Text(category).tag(category)
                    }
                }
            }
        } header: {
            HStack {
                Text("节点")
                Spacer()
                if testedLatencyCount > 0 {
                    Text("连通 \(reachableLatencyCount)/\(testedLatencyCount)")
                        .font(.caption).foregroundColor(.secondary)
                }
                Button(action: onRefresh) {
                    if isRefreshingLatency {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("刷新延迟", systemImage: "arrow.clockwise")
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .disabled(isRefreshingLatency || nodes.isEmpty)
            }
        } footer: {
            Text(isVPNConnected
                 ? "开启 VPN 时会逐个节点发起 HTTPS 探测，显示包含代理协议握手和目标请求时间的真实代理延迟。左滑节点可编辑地址、端口等设置。"
                 : "未连接内置 VPN 时也可刷新：测试节点 TCP 端口是否可连及建连延迟，不代表代理握手或实际出站速度；Hysteria2 使用 UDP，需连接 VPN 才能准确测试。左滑节点可编辑地址、端口等设置。")
        }
    }
}

private struct ProxyNodeAddSection: View {
    let subscriptionCount: Int

    var body: some View {
        Section("添加节点") {
            NavigationLink { NodeDeployView() } label: {
                Label("部署新节点到 Cloudflare", systemImage: "icloud.and.arrow.up")
            }
            NavigationLink { ImportNodesView() } label: {
                Label("导入链接 / 订阅", systemImage: "square.and.arrow.down")
            }
            NavigationLink { ProxySubscriptionsView() } label: {
                Label("管理订阅（\(subscriptionCount)）", systemImage: "list.bullet.rectangle")
            }
        }
    }
}

private struct ProxyExternalClientSection: View {
    let nodes: [ProxyNode]
    let selectedID: UUID?
    let selectedNode: ProxyNode?
    let selectionMode: ProxySelectionMode
    let bypassCN: Bool
    let routingRules: [ProxyRoutingRule]
    @Binding var exportMessage: String?
    @Binding var exportURL: URL?
    @Binding var error: String?
    let onOpenShadowrocket: (ProxyNode) -> Void

    var body: some View {
        Section {
            Button("生成并复制 Clash Meta / Mihomo 配置", action: exportConfiguration)
            if let exportMessage {
                Text(exportMessage).font(.caption).foregroundColor(.secondary)
            }
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("分享 / 导入 Clash 配置文件", systemImage: "square.and.arrow.up")
                }
            }
            if let node = selectedNode, !LinkParser.shareLink(node).isEmpty {
                Button("复制选中节点分享链接") {
                    UIPasteboard.general.string = LinkParser.shareLink(node)
                }
                Button("用 Shadowrocket 打开选中节点") {
                    onOpenShadowrocket(node)
                }
            }
        } header: {
            Text("外部客户端模式")
        } footer: {
            Text("Clash Meta / Mihomo 可导入支持的节点、自动/手动组和分流规则；不兼容的传输类型会跳过。Shadowrocket 可接收单节点链接。外部客户端的 VPN 连接由它自身管理。")
        }
    }

    private func exportConfiguration() {
        let exportableCount = ClashConfig.exportableNodeCount(nodes: nodes)
        let config = ClashConfig.build(
            nodes: nodes,
            selectedID: selectedID,
            selectionMode: selectionMode,
            bypassCN: bypassCN,
            routingRules: routingRules
        )
        guard !config.isEmpty else {
            exportMessage = "没有可导出的 Clash 节点"
            return
        }
        UIPasteboard.general.string = config
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("cf-assistant-clash-meta.yaml")
        do {
            try Data(config.utf8).write(to: fileURL, options: .atomic)
            exportURL = fileURL
            let skippedCount = nodes.count - exportableCount
            let skippedText = skippedCount > 0 ? "；另有 \(skippedCount) 个不兼容节点未导出" : ""
            exportMessage = "已复制并生成配置文件（\(exportableCount) 个节点）\(skippedText)"
        } catch {
            self.error = "写入 Clash 配置失败：\(error.localizedDescription)"
        }
    }
}

struct ProxyHomeView: View {
    @ObservedObject private var store = ProxyStore.shared
    @ObservedObject private var vpn = VPNManager.shared
    @State private var error: String?
    @State private var latencyByNode: [UUID: ProxyProbeResult] = [:]
    @State private var isRefreshingLatency = false
    @State private var protocolFilter = "全部"
    @State private var clashExportMessage: String?
    @State private var clashExportURL: URL?
    @State private var nodeBeingEdited: ProxyNode?
    @State private var nodeToDelete: ProxyNode?
    @State private var showingDeleteNodeConfirmation = false
    @State private var showingDeleteAllConfirmation = false

    var body: some View {
        List {
            Section(footer: Text(vpn.extensionBundleID == nil
                                 ? "当前安装包不含 VPN 扩展：节点管理可用，开关需要「VPN 版」IPA。"
                                 : "内置 VPN 使用选中的节点。也可把节点交给 Shadowrocket 等外部客户端，但连接和分流需在外部客户端内操作。")) {
                Toggle(isOn: Binding(
                    get: { vpn.isActive },
                    set: { on in Task { await vpn.set(on: on, node: store.selected, bypassCN: store.bypassCN) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VPN").font(.headline)
                        Text(vpn.statusText).font(.caption).foregroundColor(.secondary)
                    }
                }
                Picker("节点选择", selection: Binding(
                    get: { store.selectionMode },
                    set: { setSelectionMode($0) }
                )) {
                    ForEach(ProxySelectionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                NavigationLink {
                    ProxyRoutingRulesView()
                } label: {
                    Label("自定义分流规则（\(store.routingRules.count)）", systemImage: "arrow.triangle.branch")
                }
                Toggle("大陆常见域名直连", isOn: $store.bypassCN)
            }

            ProxyNodeListSection(
                nodes: store.nodes,
                categoryNames: categoryNames,
                protocolFilter: $protocolFilter,
                isVPNConnected: vpn.isConnected,
                testedLatencyCount: testedLatencyCount,
                reachableLatencyCount: reachableLatencyCount,
                isRefreshingLatency: isRefreshingLatency,
                onRefresh: { Task { await refreshLatency() } }
            )

            ForEach(visibleProtocolGroups) { group in
                ProxyNodeCategorySection(
                    category: group,
                    latencyByNode: latencyByNode,
                    selectionMode: store.selectionMode,
                    selectedID: store.selected?.id,
                    subscriptionName: { subscriptionName(for: $0) },
                    onSelect: { choose($0) },
                    onEdit: { nodeBeingEdited = $0 },
                    onCopy: { UIPasteboard.general.string = LinkParser.shareLink($0) },
                    onDeleteNode: { requestDelete($0) },
                    onDelete: { store.remove(ids: $0) }
                )
            }

            ProxyNodeAddSection(subscriptionCount: store.subscriptions.count)

            if !store.nodes.isEmpty {
                ProxyExternalClientSection(
                    nodes: store.nodes,
                    selectedID: store.selectedID,
                    selectedNode: store.selected,
                    selectionMode: store.selectionMode,
                    bypassCN: store.bypassCN,
                    routingRules: store.routingRules,
                    exportMessage: $clashExportMessage,
                    exportURL: $clashExportURL,
                    error: $error,
                    onOpenShadowrocket: openShadowrocket
                )
            }
        }
        .navigationTitle("VPN 与节点")
        .task { await vpn.load() }
        .sheet(item: $nodeBeingEdited) { node in
            NavigationStack {
                ProxyNodeEditorView(node: node) { updated in
                    store.update(updated)
                }
            }
        }
        .onChange(of: store.nodes) { _ in restartTunnelForConfigurationChange() }
        .onChange(of: store.bypassCN) { _ in restartTunnelForConfigurationChange() }
        .onChange(of: store.routingRules) { _ in restartTunnelForConfigurationChange() }
        .onChange(of: vpn.error) { e in if let e { error = e } }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                EditButton()
                if !store.nodes.isEmpty {
                    Button {
                        showingDeleteAllConfirmation = true
                    } label: {
                        Label("全删", systemImage: "trash")
                    }
                    .accessibilityLabel("删除全部节点")
                }
            }
        }
        .confirmationDialog("删除节点", isPresented: $showingDeleteNodeConfirmation, titleVisibility: .visible) {
            Button("删除「\(nodeToDelete?.name ?? "此节点")」", role: .destructive) {
                if let nodeToDelete { store.remove(ids: [nodeToDelete.id]) }
                self.nodeToDelete = nil
            }
            Button("取消", role: .cancel) { nodeToDelete = nil }
        } message: {
            Text("只会从本机节点列表中移除，不会删除订阅地址或 Cloudflare 上的 Worker。")
        }
        .confirmationDialog("删除全部节点？", isPresented: $showingDeleteAllConfirmation, titleVisibility: .visible) {
            Button("删除全部 \(store.nodes.count) 个节点", role: .destructive) {
                store.removeAllNodes()
                latencyByNode = [:]
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会清空本机保存的节点；订阅地址、分流规则和 Cloudflare 上已部署的 Worker 都会保留。")
        }
        .errorAlert($error)
    }

    private func choose(_ n: ProxyNode) {
        store.selectedID = n.id
        store.selectionMode = .manual
        Task {
            do { try await vpn.select(node: n, mode: .manual) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func requestDelete(_ node: ProxyNode) {
        nodeToDelete = node
        showingDeleteNodeConfirmation = true
    }

    private func setSelectionMode(_ mode: ProxySelectionMode) {
        store.selectionMode = mode
        Task {
            do { try await vpn.setSelectionMode(mode, node: store.selected) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func restartTunnelForConfigurationChange() {
        guard vpn.isConnected else { return }
        Task { await vpn.reconfigure() }
    }

    private var categoryNames: [String] {
        let present = Set(store.nodes.map(categoryName(for:)))
        let common = ["V2Ray (VLESS / VMess)", "Shadowsocks", "Trojan", "Hysteria2"]
        return common.filter { present.contains($0) } + present.subtracting(common).sorted()
    }

    private var visibleProtocolGroups: [ProxyNodeCategory] {
        let names = protocolFilter == "全部" ? categoryNames : [protocolFilter]
        return names.compactMap { name in
            let matches = store.nodes.filter { categoryName(for: $0) == name }
            return matches.isEmpty ? nil : ProxyNodeCategory(title: name, nodes: matches)
        }
    }

    private func categoryName(for node: ProxyNode) -> String {
        switch node.proto.lowercased() {
        case "vless", "vmess": return "V2Ray (VLESS / VMess)"
        case "ss", "shadowsocks": return "Shadowsocks"
        case "trojan": return "Trojan"
        case "hysteria2", "hy2": return "Hysteria2"
        default: return "其他 · \(node.proto.uppercased())"
        }
    }

    private func subscriptionName(for node: ProxyNode) -> String? {
        guard let id = node.subscriptionID else { return nil }
        return store.subscriptions.first(where: { $0.id == id })?.name ?? "已移除订阅"
    }

    private var testedLatencyCount: Int {
        store.nodes.compactMap { latencyByNode[$0.id] }.filter { $0.countsAsTested }.count
    }

    private var reachableLatencyCount: Int {
        store.nodes.compactMap { latencyByNode[$0.id] }.filter { $0.isReachable }.count
    }

    @MainActor
    private func refreshLatency() async {
        guard !isRefreshingLatency, !store.nodes.isEmpty else { return }
        isRefreshingLatency = true
        latencyByNode = [:]
        defer { isRefreshingLatency = false }
        do { latencyByNode = try await vpn.measureNodeLatencies(nodes: store.nodes) }
        catch { self.error = error.localizedDescription }
    }

    private func openShadowrocket(_ n: ProxyNode) {
        let link = LinkParser.shareLink(n)
        UIPasteboard.general.string = link
        if let enc = link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "shadowrocket://add/" + enc) {
            UIApplication.shared.open(url)
        }
    }
}

struct ProxyNodeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    private let originalNode: ProxyNode
    @State private var draft: ProxyNode
    @State private var portText: String
    @State private var showSecret = false
    @State private var error: String?
    let onSave: (ProxyNode) -> Void

    init(node: ProxyNode, onSave: @escaping (ProxyNode) -> Void) {
        originalNode = node
        _draft = State(initialValue: node)
        _portText = State(initialValue: String(node.port))
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("节点名称", text: $draft.name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("地址 / IP", text: $draft.server)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("端口", text: $portText)
                    .keyboardType(.numberPad)
                LabeledContent("协议", value: draft.proto.uppercased())
                HStack {
                    Group {
                        if showSecret {
                            TextField("UUID / 密码", text: $draft.secret)
                        } else {
                            SecureField("UUID / 密码", text: $draft.secret)
                        }
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        showSecret.toggle()
                    } label: {
                        Image(systemName: showSecret ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showSecret ? "隐藏认证信息" : "显示认证信息")
                }
            }

            if draft.proto == "ss" || draft.proto == "shadowsocks" {
                Section("Shadowsocks") {
                    parameterField("加密方式", key: "method", placeholder: "aes-128-gcm")
                }
            }
            if draft.proto == "vmess" {
                Section("VMess") {
                    parameterField("加密方式", key: "scy", placeholder: "auto")
                    parameterField("Alter ID", key: "aid", placeholder: "0")
                }
            }
            if draft.proto == "vless" {
                Section("VLESS") {
                    parameterField("Flow", key: "flow")
                    parameterField("Reality 公钥", key: "pbk")
                    parameterField("Reality Short ID", key: "sid")
                }
            }
            if draft.proto == "hysteria2" || draft.proto == "hy2" {
                Section("Hysteria2") {
                    parameterField("混淆类型", key: "obfs")
                    parameterField("混淆密码", key: "obfs-password")
                }
            }

            Section("TLS 与传输") {
                parameterField("安全方式 (none / tls / reality)", key: "security")
                parameterField("SNI / TLS 域名", key: "sni")
                parameterField("TLS Peer", key: "peer")
                parameterField("ALPN（逗号分隔）", key: "alpn")
                parameterField("客户端指纹", key: "fp")
                parameterField("传输类型 (tcp / ws / grpc)", key: "type")
                parameterField("Host", key: "host")
                parameterField("路径", key: "path")
                parameterField("gRPC 服务名", key: "serviceName")
                Toggle("跳过 TLS 证书验证", isOn: insecureBinding)
            }

            if draft.subscriptionID != nil {
                Section("订阅节点") {
                    Text("本地修改会在下次刷新该订阅时被覆盖。")
                        .font(.footnote).foregroundColor(.secondary)
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
                Button("保存") { save() }
            }
        }
        .errorAlert($error)
    }

    private func parameterField(_ title: String, key: String, placeholder: String? = nil) -> some View {
        TextField(title, text: parameterBinding(key), prompt: placeholder.map { Text($0) })
            .textInputAutocapitalization(.never).autocorrectionDisabled()
    }

    private func parameterBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { draft.params[key] ?? "" },
            set: { value in
                var updated = draft
                if value.isEmpty {
                    updated.params.removeValue(forKey: key)
                } else {
                    updated.params[key] = value
                }
                draft = updated
            }
        )
    }

    private var insecureBinding: Binding<Bool> {
        Binding(
            get: { draft.p("allowInsecure") == "1" || draft.p("insecure") == "1" },
            set: { enabled in
                var updated = draft
                updated.params.removeValue(forKey: "insecure")
                if enabled {
                    updated.params["allowInsecure"] = "1"
                } else {
                    updated.params.removeValue(forKey: "allowInsecure")
                }
                draft = updated
            }
        )
    }

    private func save() {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = draft.server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "请填写节点名称"; return }
        guard !server.isEmpty else { error = "请填写服务器地址或 IP"; return }
        guard let port = Int(portText), (1...65535).contains(port) else {
            error = "端口必须是 1 到 65535 之间的整数"
            return
        }
        var updated = draft
        updated.name = name
        updated.server = server
        updated.port = port
        if updated != originalNode { updated.raw = "" }
        onSave(updated)
        dismiss()
    }
}

struct ProxySubscriptionsView: View {
    @ObservedObject private var store = ProxyStore.shared
    @State private var refreshingID: UUID?
    @State private var subscriptionToDelete: ProxySubscription?
    @State private var showingDeleteChoices = false
    @State private var error: String?

    var body: some View {
        List {
            if store.subscriptions.isEmpty {
                EmptyHint(text: "还没有订阅。通过“导入链接 / 订阅”添加订阅地址后，可在这里刷新或删除。")
            }
            ForEach(store.subscriptions) { subscription in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(subscription.name).font(.headline)
                        Text(subscription.url).font(.caption).foregroundColor(.secondary)
                            .lineLimit(2).truncationMode(.middle)
                        Text("\(store.nodes.filter { $0.subscriptionID == subscription.id }.count) 个节点")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button {
                        Task { await refresh(subscription) }
                    } label: {
                        if refreshingID == subscription.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(refreshingID != nil)
                    .accessibilityLabel("刷新\(subscription.name)")
                }
                .swipeActions {
                    Button("删除", role: .destructive) {
                        subscriptionToDelete = subscription
                        showingDeleteChoices = true
                    }
                }
            }
        }
        .navigationTitle("代理订阅")
        .confirmationDialog("删除订阅", isPresented: $showingDeleteChoices, titleVisibility: .visible) {
            if let subscription = subscriptionToDelete {
                let count = store.nodes.filter { $0.subscriptionID == subscription.id }.count
                Button("删除订阅和 \(count) 个节点", role: .destructive) {
                    store.deleteSubscription(subscription.id, removeNodes: true)
                }
                Button("仅删除订阅，保留节点") {
                    store.deleteSubscription(subscription.id, removeNodes: false)
                }
            }
            Button("取消", role: .cancel) { subscriptionToDelete = nil }
        } message: {
            Text("删除订阅后，可选择是否同时移除它导入的节点。")
        }
        .errorAlert($error)
    }

    @MainActor
    private func refresh(_ subscription: ProxySubscription) async {
        guard refreshingID == nil else { return }
        refreshingID = subscription.id
        defer { refreshingID = nil }
        do {
            let nodes = try await LinkParser.fetchSubscription(subscription.url)
            store.importSubscription(url: subscription.url, nodes: nodes)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ProxyRoutingRulesView: View {
    @ObservedObject private var store = ProxyStore.shared

    var body: some View {
        List {
            if store.routingRules.isEmpty {
                EmptyHint(text: "添加域名后缀或 IP/CIDR 规则，指定流量走代理或直连。规则按列表顺序优先匹配。")
            }
            ForEach(store.routingRules) { rule in
                VStack(alignment: .leading, spacing: 4) {
                    Text(rule.value).font(.body.monospaced())
                    Text("\(rule.kind.title) · \(rule.target.title)")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .onDelete { store.routingRules.remove(atOffsets: $0) }
        }
        .navigationTitle("分流规则")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    ProxyRoutingRuleEditor { rule in store.routingRules.append(rule) }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加分流规则")
            }
        }
    }
}

struct ProxyRoutingRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ProxyRoutingRuleKind = .domainSuffix
    @State private var value = ""
    @State private var target: ProxyRoutingTarget = .proxy
    let onSave: (ProxyRoutingRule) -> Void

    var body: some View {
        Form {
            Section(footer: Text("规则按顺序匹配；自定义规则优先于大陆常见域名直连。")) {
                Picker("匹配类型", selection: $kind) {
                    ForEach(ProxyRoutingRuleKind.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                TextField(kind.placeholder, text: $value)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("流量去向", selection: $target) {
                    ForEach(ProxyRoutingTarget.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
            }
            Section {
                Button("保存规则", action: save)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("添加分流规则")
    }

    private func save() {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .domainSuffix {
            normalized = normalized.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        guard !normalized.isEmpty else { return }
        onSave(ProxyRoutingRule(kind: kind, value: normalized, target: target))
        dismiss()
    }
}

// MARK: - 部署节点（Cloudflare Worker, VLESS + WS）

struct NodeDeployView: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var store = ProxyStore.shared
    @State private var name = "node-" + String(UUID().uuidString.prefix(6)).lowercased()
    @State private var uuid = UUID().uuidString.lowercased()
    @State private var address = ""
    @State private var busy = false
    @State private var result: String?
    @State private var error: String?

    var body: some View {
        Form {
            Section(footer: Text("部署一个 VLESS + WebSocket 的 Worker，成功后节点自动加入列表并选中。")) {
                TextField("Worker 名称", text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("UUID", text: $uuid)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.system(size: 14, design: .monospaced))
            }
            Section(footer: Text("留空则直接连 workers.dev 域名。国内常被干扰，可填优选 IP 或你自己绑定到 Worker 的域名；TLS 的 SNI 和 Host 仍用 workers.dev 域名。")) {
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
        .navigationTitle("部署节点")
        .errorAlert($error)
    }

    private func deploy() async {
        busy = true
        defer { busy = false }
        let ctx = session.ctx
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        let id = uuid.trimmingCharacters(in: .whitespaces).lowercased()
        do {
            let meta = try JSONSerialization.data(withJSONObject: ["main_module": "worker.js",
                                                                   "compatibility_date": "2024-11-01"])
            let parts = [
                MultipartPart(name: "metadata", filename: nil, contentType: "application/json", data: meta),
                MultipartPart(name: "worker.js", filename: "worker.js",
                              contentType: "application/javascript+module",
                              data: Data(NodeWorker.script(uuid: id).utf8))
            ]
            let (body, ct) = buildMultipart(parts)
            let _: JSONValue = try await ctx.c.request("PUT", "accounts/\(ctx.acc)/workers/scripts/\(n)",
                                                       body: body, contentType: ct)
            _ = try? await ctx.c.send("POST", "accounts/\(ctx.acc)/workers/scripts/\(n)/subdomain",
                                      json: ["enabled": true])
            guard let sub: WorkerSubdomain = try? await ctx.c.get("accounts/\(ctx.acc)/workers/subdomain"),
                  let s = sub.subdomain else {
                throw CFClientError.message("Worker 已部署，但没取到 workers.dev 子域名，请先在 Workers 里开启后再手动添加节点")
            }
            let host = "\(n).\(s).workers.dev"
            let addr = address.trimmingCharacters(in: .whitespaces)
            let node = NodeWorker.node(name: n, host: host, address: addr.isEmpty ? host : addr, uuid: id)
            store.add(node, select: true)
            result = "已部署并添加节点\n\(host)\n回到上一页即可打开 VPN。"
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 导入

struct ImportNodesView: View {
    @ObservedObject private var store = ProxyStore.shared
    @State private var text = ""
    @State private var busy = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(6)
            Text("粘贴节点链接（vless / vmess / trojan / ss / hysteria2），或订阅地址 https://…")
                .font(.caption).foregroundColor(.secondary).padding(8)
        }
        .navigationTitle("导入节点")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(busy ? "导入中…" : "导入") { Task { await run() } }
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button("粘贴") { text = UIPasteboard.general.string ?? text }
            }
        }
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { _ in })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
        .errorAlert($error)
    }

    private func run() async {
        busy = true
        defer { busy = false }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://") {
                let nodes = try await LinkParser.fetchSubscription(t)
                let subscription = store.importSubscription(url: t, nodes: nodes)
                message = "已添加订阅「\(subscription.name)」，导入 \(nodes.count) 个节点"
            } else {
                let nodes = LinkParser.parseMany(t)
                if nodes.isEmpty { throw CFClientError.message("没有解析到可用节点") }
                store.add(nodes)
                message = "已导入 \(nodes.count) 个节点"
            }
            text = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}
