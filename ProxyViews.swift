import SwiftUI

struct ProxyHomeView: View {
    @ObservedObject private var store = ProxyStore.shared
    @ObservedObject private var vpn = VPNManager.shared
    @State private var error: String?

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
            }
            Section("节点") {
                Button("刷新延迟") {
                    Task { await store.refreshLatency(vpnConnected: vpn.isConnected) }
                }
                ForEach(store.nodes) { n in
                    Button {
                        store.selectedID = n.id
                        Task { await vpn.restartIfActive(store: store) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(n.name)
                                Text(n.detail).font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            if store.selectedID == n.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets.sorted(by: >) {
                        store.remove(store.nodes[i])
                    }
                }
            }
            Section {
                NavigationLink("导入节点") { ImportNodesView() }
            }
        }
        .navigationTitle("VPN 与节点")
        .task {
            await vpn.load()
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
    let node: ProxyNode
    var body: some View {
        Text(node.name)
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
        .task { text = await vpn.fetchLog() }
    }
}

struct NodeDeployView: View {
    var body: some View { Text("部署").padding() }
}
