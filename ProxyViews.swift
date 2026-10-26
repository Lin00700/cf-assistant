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

    // MARK: 分区

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
        Section(
            header: HStack {
                Text("节点")
                Spacer()
                if !store.results.isEmpty {
                    Text("连通 \(reachableCount)/\(testedCount)").font(.caption)
                }
                if store.isRefreshing {
                    ProgressView()
                } else {
                    Button("刷新延迟") { Task { await store.refreshLatency(vpnConnected: vpn.isConnected) } }
                        .font(.caption)
                        .textCase(nil)
                }
            },
            footer: Text(vpn.isConnected
                         ? "开启 VPN 时会逐个节点通过 HTTPS（Cloudflare）探测真实代理延迟；“探测失败”不等于节点失效。左滑节点可编辑地址、端口等设置。"
                         : "未连接内置 VPN 时也可刷新：测试节点 TCP 端口是否可连及建连延迟，不代表代理握手或实际出站速度；Hysteria2 使用 UDP，需连接 VPN 才能准确测试。左滑节点可编辑地址、端口等设置。")
        ) {
            Picker("节点分类", selection: $category) {
                Text("全部").tag("全部")
                ForEach(protocols, id: \.self) { Text(title($0)).tag(title($0)) }
            }
            if let e = store.refreshError {
                Text(e).font(.caption).foregroundColor(.orange)
            }
            if store.nodes.isEmpty {
                EmptyHint(text: "还没有节点，下面可以部署或导入")
            }
        }
    }

    private var addSection: some View {
        Section("添加节点") {
            NavigationLink { NodeDeployView() } label: {
                Label("部署新节点到 Cloudflare", systemImage: "icloud.and.arrow.up")
            }
            NavigationLink { ImportNodesView() } label: {
                Label("导入链接 / 订阅", systemImage: "square.and.arrow.down")
            }
        }
    }

    private var exportSection: some View {
        Section("导出到其他客户端") {
            let count = ClashConfig.exportableNodeCount(nodes: store.nodes)
            Button("复制 Clash.Meta 配置（\(count) 个节点）") {
                let text = ClashConfig.build(nodes: store.nodes, selectedID: store.selectedID,
                                             selectionMode: store.selectionMode, bypassCN: store.bypassCN,
                                             routingRules: store.routingRules)
                if text.isEmpty {
                    toast = "没有可导出的节点"
                } else {
                    UIPasteboard.general.string = text
                    toast = "已复制 Clash.Meta 配置"
                }
            }
            .disabled(count == 0)
            if let n = store.selected, !LinkParser.shareLink(n).isEmpty {
                Button("复制选中节点的分享链接") { UIPasteboard.general.string = LinkParser.shareLink(n) }
                Button("用 Shadowrocket 打开选中节点") { openShadowrocket(n) }
            }
        }
    }

    // MARK: 节点行

    private func row(_ n: ProxyNode) -> some View {
        Button { choose(n) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(n.name).foregroundColor(.primary)
                    Text(n.detail).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if let r = store.results[n.id] {
                        Text(r.label).font(.caption).foregroundColor(color(r))
                    }
                    if n.id == store.selected?.id {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.orange)
                    }
                }
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { store.remove(n) } label: { Label("删除", systemImage: "trash") }
            Button { editing = n } label: { Label("编辑", systemImage: "pencil") }.tint(.orange)
        }
        .contextMenu {
            Button("复制分享链接") { UIPasteboard.general.string = LinkParser.shareLink(n) }
        }
    }

    private func color(_ r: ProxyProbeResult) -> Color {
        switch r {
        case .latency(let ms), .tcpLatency(let ms): return ms < 200 ? .green : .orange
        default: return .orange
        }
    }

    private func choose(_ n: ProxyNode) {
        store.selectedID = n.id
        Task { await vpn.restartIfActive(store: store) }
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
                }
                Section(footer: Text("改了地址或端口后，分享链接会按新值重新生成（导入时的原始链接不再使用）。")) {
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
                if store.routingRules.isEmpty { EmptyHint(text: "还没有自定义规则") }
                ForEach(store.routingRules) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.value)
                            Text(r.kind == .domainSuffix ? "域名后缀" : "IP 段").font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(r.target == .direct ? "直连" : "代理")
                            .font(.caption)
                            .foregroundColor(r.target == .direct ? .green : .orange)
                    }
                }
                .onDelete { store.routingRules.remove(atOffsets: $0) }
            }
            Section("添加规则") {
                Picker("类型", selection: $kind) {
                    Text("域名后缀").tag(ProxyRoutingRule.Kind.domainSuffix)
                    Text("IP 段（CIDR）").tag(ProxyRoutingRule.Kind.ipCIDR)
                }
                TextField(kind == .domainSuffix ? "例如 example.com" : "例如 10.0.0.0/8", text: $value)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("走向", selection: $target) {
                    Text("直连").tag(ProxyRoutingRule.Target.direct)
                    Text("代理").tag(ProxyRoutingRule.Target.proxy)
                }
                Button("添加") {
                    let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if v.isEmpty { return }
                    store.routingRules.append(ProxyRoutingRule(kind: kind, value: v, target: target))
                    value = ""
                }
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("自定义分流规则")
        .toolbar { EditButton() }
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
            let nodes: [ProxyNode]
            if t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://") {
                nodes = try await LinkParser.fetchSubscription(t)
            } else {
                nodes = LinkParser.parseMany(t)
            }
            if nodes.isEmpty { throw CFClientError.message("没有解析到可用节点") }
            store.add(nodes)
            message = "已导入 \(nodes.count) 个节点"
            text = ""
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
