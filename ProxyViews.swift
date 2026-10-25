import SwiftUI

// MARK: - VPN 主页

struct ProxyHomeView: View {
    @ObservedObject private var store = ProxyStore.shared
    @ObservedObject private var vpn = VPNManager.shared
    @State private var error: String?
    @State private var latencyByNode: [UUID: ProxyProbeResult] = [:]
    @State private var isRefreshingLatency = false

    var body: some View {
        List {
            Section(footer: Text(vpn.extensionBundleID == nil
                                 ? "当前安装包不含 VPN 扩展：节点管理可用，开关需要「VPN 版」IPA。"
                                 : "使用选中的节点建立全局 VPN。")) {
                Toggle(isOn: Binding(
                    get: { vpn.isActive },
                    set: { on in Task { await vpn.set(on: on, node: store.selected, bypassCN: store.bypassCN) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VPN").font(.headline)
                        Text(vpn.statusText).font(.caption).foregroundColor(.secondary)
                    }
                }
                Toggle("大陆常见域名直连", isOn: $store.bypassCN)
            }

            Section {
                if store.nodes.isEmpty {
                    EmptyHint(text: "还没有节点，下面可以部署或导入")
                }
                ForEach(store.nodes) { n in
                    Button { choose(n) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(n.name).foregroundColor(.primary)
                                Text(n.detail).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(latencyByNode[n.id]?.label ?? "未测")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(latencyColor(for: latencyByNode[n.id]))
                                if n.id == store.selected?.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.orange)
                                }
                            }
                        }
                    }
                    .contextMenu {
                        Button("复制分享链接") { UIPasteboard.general.string = LinkParser.shareLink(n) }
                    }
                }
                .onDelete { store.remove(at: $0) }
            } header: {
                HStack {
                    Text("节点")
                    Spacer()
                    if testedLatencyCount > 0 {
                        Text("连通 \(reachableLatencyCount)/\(testedLatencyCount)")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Button {
                        Task { await refreshLatency() }
                    } label: {
                        if isRefreshingLatency {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("刷新延迟", systemImage: "arrow.clockwise")
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .disabled(isRefreshingLatency || store.nodes.isEmpty || vpn.isActive)
                }
            } footer: {
                Text("请先断开 VPN 再刷新，避免测速流量回到当前代理。延迟为 TCP 端口建连时间，只表示地址可达，不代表代理吞吐；Hysteria2 使用 UDP，不参与此项测速。")
            }

            Section("添加节点") {
                NavigationLink { NodeDeployView() } label: {
                    Label("部署新节点到 Cloudflare", systemImage: "icloud.and.arrow.up")
                }
                NavigationLink { ImportNodesView() } label: {
                    Label("导入链接 / 订阅", systemImage: "square.and.arrow.down")
                }
            }

            if let n = store.selected, !LinkParser.shareLink(n).isEmpty {
                Section("用其他客户端打开选中节点") {
                    Button("复制分享链接") { UIPasteboard.general.string = LinkParser.shareLink(n) }
                    Button("用 Shadowrocket 打开") { openShadowrocket(n) }
                }
            }
        }
        .navigationTitle("VPN 与节点")
        .task { await vpn.load() }
        .onChange(of: vpn.error) { e in if let e { error = e } }
        .errorAlert($error)
    }

    private func choose(_ n: ProxyNode) {
        store.selectedID = n.id
        if vpn.isActive {
            Task {
                await vpn.set(on: false, node: nil, bypassCN: store.bypassCN)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await vpn.set(on: true, node: n, bypassCN: store.bypassCN)
            }
        }
    }

    private var testedLatencyCount: Int {
        store.nodes.compactMap { latencyByNode[$0.id] }.filter { $0.countsAsTested }.count
    }

    private var reachableLatencyCount: Int {
        store.nodes.compactMap { latencyByNode[$0.id] }.filter { $0.isReachable }.count
    }

    private func latencyColor(for result: ProxyProbeResult?) -> Color {
        guard let result else { return .secondary }
        switch result {
        case .latency(let milliseconds):
            if milliseconds < 150 { return .green }
            if milliseconds < 400 { return .orange }
            return .red
        case .unreachable:
            return .red
        case .unsupported:
            return .secondary
        }
    }

    @MainActor
    private func refreshLatency() async {
        guard !isRefreshingLatency, !store.nodes.isEmpty else { return }
        isRefreshingLatency = true
        latencyByNode = [:]
        defer { isRefreshingLatency = false }

        let nodes = store.nodes
        let results = await withTaskGroup(of: (UUID, ProxyProbeResult).self) { group in
            var nextIndex = 0
            var collected: [UUID: ProxyProbeResult] = [:]
            for _ in 0..<min(8, nodes.count) {
                let node = nodes[nextIndex]
                nextIndex += 1
                group.addTask { (node.id, await ProxyLatencyProbe.measure(node)) }
            }
            while let (id, result) = await group.next() {
                collected[id] = result
                if nextIndex < nodes.count {
                    let node = nodes[nextIndex]
                    nextIndex += 1
                    group.addTask { (node.id, await ProxyLatencyProbe.measure(node)) }
                }
            }
            return collected
        }
        latencyByNode = results
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
