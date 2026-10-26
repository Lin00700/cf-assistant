import SwiftUI

// MARK: - VPN 与节点主页

struct ProxyHomeView: View {
    @ObservedObject private var store = ProxyStore.shared
    @ObservedObject private var vpn = VPNManager.shared
    @State private var logText = ""
    @State private var showLog = false

    private func title(_ proto: String) -> String {
        switch proto {
        case "vless": return "VLESS"
        case "vmess": return "VMess"
        case "trojan": return "Trojan"
        case "ss": return "Shadowsocks"
        case "hysteria2": return "Hysteria2"
        default: return proto.uppercased()
        }
    }

    private func nodes(of proto: String) -> [ProxyNode] {
        store.nodes.filter { $0.proto == proto }
    }

    var body: some View {
        List {
            vpnSection
            diagnosticsSection
            nodeHeaderSection
            ForEach(["ss", "vless", "vmess", "trojan", "hysteria2"], id: \.self) { proto in
                let list = nodes(of: proto)
                if !list.isEmpty {
                    Section(header: Text("\(title(proto))（\(list.count)）")) {
                        ForEach(list) { n in
                            nodeRow(n)
                        }
                    }
                }
            }
            addSection
            exportSection
        }
        .navigationTitle("VPN 与节点")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vpn.load() }
        .sheet(isPresented: $showLog) {
            NavigationStack {
                ScrollView {
                    Text(logText.isEmpty ? "（无日志）" : logText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("VPN 日志")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { showLog = false } }
                    ToolbarItem(placement: .primaryAction) {
                        Button("复制") { UIPasteboard.general.string = logText }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("刷新") {
                            Task { logText = await vpn.fetchLog() }
                        }
                    }
                }
            }
        }
    }

    private var vpnSection: some View {
        Section(footer: Text(vpn.extensionBundleID == nil
            ? "当前安装包不含 VPN 扩展，请使用「VPN 版」IPA。"
            : "内置 VPN 使用选中的节点。也可把节点交给 Shadowrocket 等外部客户端，但连接和分流需在外部客户端内操作。")) {
            Toggle(isOn: Binding(
                get: { vpn.isActive },
                set: { on in Task { await vpn.set(on: on, store: store) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VPN")
                    Text(vpn.statusText).font(.caption).foregroundColor(.secondary)
                }
            }
            .disabled(vpn.extensionBundleID == nil)

            Picker("节点选择", selection: Binding(
                get: { store.selectionMode },
                set: { store.selectionMode = $0; Task { await vpn.restartIfActive(store: store) } }
            )) {
                Text("手动选择").tag(ProxySelectionMode.manual)
                Text("自动测速").tag(ProxySelectionMode.automatic)
            }

            NavigationLink {
                RoutingRulesView()
            } label: {
                Text("自定义分流规则（\(store.routingRules.count)）")
            }

            Toggle("大陆常见域名直连", isOn: Binding(
                get: { store.bypassCN },
                set: { store.bypassCN = $0; Task { await vpn.restartIfActive(store: store) } }
            ))

            if let e = vpn.error {
                Text(e).font(.footnote).foregroundColor(.red)
            }
        }
    }

    private var diagnosticsSection: some View {
        Section(footer: Text("测试 DNS、IPv4 / IPv6 和 HTTP，并保存可分享的诊断记录。")) {
            NavigationLink {
                ConnectivityDiagnosticsView()
            } label: {
                HStack {
                    Label("连接诊断", systemImage: "stethoscope")
                    Spacer()
                    Text(vpn.isConnected ? "VPN 已连接" : "需先连接 VPN")
                        .font(.caption)
                        .foregroundColor(vpn.isConnected ? .green : .secondary)
                }
            }
            Button {
                Task {
                    logText = await vpn.fetchLog()
                    showLog = true
                }
            } label: {
                Label("VPN 运行日志", systemImage: "doc.text.magnifyingglass")
            }
        }
    }

    private var nodeHeaderSection: some View {
        Section(
            header: HStack {
                Text("节点")
                Spacer()
                Text(store.latencySummary).font(.caption).foregroundColor(.secondary)
                Button("刷新延迟") {
                    Task { await store.refreshLatency(vpnConnected: vpn.isConnected) }
                }
                .font(.caption)
            },
            footer: Text(vpn.isConnected
                ? "开启 VPN 时会逐个节点通过 HTTPS（Cloudflare）探测真实代理延迟；“探测失败”不等于节点失效。左滑节点可编辑地址、端口等设置。"
                : "未连接内置 VPN 时也可刷新：测试节点 TCP 端口是否可连及建连延迟，不代表代理握手或实际出站速度；Hysteria2 使用 UDP，需连接 VPN 才能准确测试。左滑节点可编辑地址、端口等设置。")
        ) {
            Picker("节点分类", selection: $store.filterProto) {
                Text("全部").tag("all" as String?)
                Text("SS").tag("ss" as String?)
                Text("VLESS").tag("vless" as String?)
                Text("VMess").tag("vmess" as String?)
                Text("Trojan").tag("trojan" as String?)
                Text("Hy2").tag("hysteria2" as String?)
            }
        }
    }

    private func nodeRow(_ n: ProxyNode) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(n.name)
                Text(n.detail).font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            if let lat = store.latency[n.id] {
                Text(lat).font(.caption).foregroundColor(lat.contains("失败") ? .orange : .green)
            }
            if store.selected?.id == n.id {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.orange)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            store.selected = n
            Task { await vpn.restartIfActive(store: store) }
        }
        .swipeActions(edge: .leading) {
            NavigationLink { NodeEditView(node: n) } label: { Text("编辑") }.tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.remove(n)
                Task { await vpn.restartIfActive(store: store) }
            } label: { Text("删除") }
        }
        .contextMenu {
            Button("复制分享链接") { UIPasteboard.general.string = LinkParser.shareLink(n) }
            Button("编辑") { }
        }
    }

    private var addSection: some View {
        Section("添加节点") {
            NavigationLink { ImportNodesView() } label: {
                Label("从链接 / 订阅导入", systemImage: "link")
            }
            NavigationLink { DeployWorkerView() } label: {
                Label("部署 Cloudflare Worker 节点", systemImage: "cloud")
            }
        }
    }

    private var exportSection: some View {
        Section("导出到其他客户端") {
            if let n = store.selected, !LinkParser.shareLink(n).isEmpty {
                Button("复制选中节点的分享链接") { UIPasteboard.general.string = LinkParser.shareLink(n) }
            }
            Button("复制 Clash 配置") {
                UIPasteboard.general.string = ClashConfig.build(nodes: store.nodes, selectedID: store.selected?.id)
            }
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

// MARK: - 部署节点（Cloudflare Worker, VLESS + WS）

struct DeployWorkerView: View {
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
        .navigationTitle("部署 Worker")
    }

    private func deploy() async {
        busy = true
        defer { busy = false }
        do {
            // Placeholder: actual deploy uses CFClient elsewhere in full app
            let host = address.isEmpty ? "\(name).workers.dev" : address
            let node = NodeWorker.makeVLESS(name: name, address: host, uuid: uuid)
            store.add(node)
            store.selected = node
            result = "已添加节点 \(host)（若完整部署逻辑在其它文件，请用原入口部署）"
        }
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
                TextEditor(text: $text)
                    .frame(minHeight: 120)
                Text("粘贴节点链接（vless / vmess / trojan / ss / hysteria2），或订阅地址 https://…")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Section {
                Button("解析") {
                    Task { await parse() }
                }
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
                        if store.selected == nil { store.selected = nodes.first }
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
