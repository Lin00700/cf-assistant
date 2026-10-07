import SwiftUI

// MARK: - 模型

struct CFTunnel: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let status: String?
    let created_at: String?
    let remote_config: Bool?
    let tun_type: String?
}

struct TunnelConn: Decodable {
    let id: String?
    let colo_name: String?
    let origin_ip: String?
    let opened_at: String?
    let is_pending_reconnect: Bool?
}

struct TunnelClient: Decodable {
    let id: String?
    let version: String?
    let arch: String?
    let run_at: String?
    let conns: [TunnelConn]?
}

func tunnelStatusText(_ s: String?) -> String {
    switch s {
    case "healthy": return "正常"
    case "degraded": return "降级"
    case "down": return "离线"
    case "inactive": return "未激活"
    default: return s ?? "未知"
    }
}

func tunnelStatusColor(_ s: String?) -> Color {
    switch s {
    case "healthy": return .green
    case "degraded": return .orange
    case "down": return .red
    default: return .gray
    }
}

// MARK: - 列表

struct TunnelsView: View {
    @EnvironmentObject var session: Session
    @State private var error: String?

    var body: some View {
        let ctx = session.ctx
        LoadView(load: { () async throws -> [CFTunnel] in
            try await ctx.c.get("accounts/\(ctx.acc)/cfd_tunnel", query: ["is_deleted": "false"])
        }) { tunnels, reload in
            List(tunnels) { t in
                NavigationLink {
                    TunnelDetailView(tunnel: t)
                } label: {
                    HStack {
                        Circle().fill(tunnelStatusColor(t.status)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).font(.headline)
                            Text(tunnelStatusText(t.status)).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button("删除", role: .destructive) {
                        Task {
                            do {
                                // 先清理失效连接，否则有残留连接时 API 会拒绝删除
                                _ = try? await ctx.c.raw("DELETE", "accounts/\(ctx.acc)/cfd_tunnel/\(t.id)/connections")
                                try await ctx.c.delete("accounts/\(ctx.acc)/cfd_tunnel/\(t.id)")
                                await reload()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
            .overlay { if tunnels.isEmpty { EmptyHint(text: "没有隧道") } }
            .refreshable { await reload() }
        }
        .navigationTitle("Tunnels")
        .errorAlert($error)
    }
}

// MARK: - 详情

struct TunnelDetailView: View {
    @EnvironmentObject var session: Session
    let tunnel: CFTunnel
    @State private var token: String?
    @State private var adding = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        let ctx = session.ctx
        let tid = tunnel.id
        LoadView(load: { () async throws -> TunnelDetailData in
            let clients: [TunnelClient] = (try? await ctx.c.get("accounts/\(ctx.acc)/cfd_tunnel/\(tid)/connections")) ?? []
            let cfg: JSONValue? = try? await ctx.c.get("accounts/\(ctx.acc)/cfd_tunnel/\(tid)/configurations")
            return TunnelDetailData(clients: clients, config: cfg)
        }) { data, reload in
            let conns = data.clients.flatMap { $0.conns ?? [] }
            let ingress = (data.config?["config"]?["ingress"]?.array ?? []).filter { $0["hostname"] != nil }
            List {
                Section("信息") {
                    LabeledContent("状态", value: tunnelStatusText(tunnel.status))
                    LabeledContent("配置方式", value: tunnel.remote_config == false ? "本地配置文件" : "远程（控制台管理）")
                    if let c = pagesDate(tunnel.created_at) {
                        LabeledContent("创建时间", value: c.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("ID", value: String(tunnel.id.prefix(8)))
                }

                Section("连接器（\(data.clients.count)）· 连接 \(conns.count) 条") {
                    if data.clients.isEmpty {
                        Text("当前没有 cloudflared 连接到这条隧道。请确认 cloudflared 正在运行，并使用下面的运行令牌。")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                    ForEach(Array(data.clients.enumerated()), id: \.offset) { _, c in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("cloudflared \(c.version ?? "?")").font(.subheadline.bold())
                                Spacer()
                                Text(c.arch ?? "").font(.caption).foregroundColor(.secondary)
                            }
                            if let r = pagesDate(c.run_at) {
                                Text("启动于 \(r.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            ForEach(Array((c.conns ?? []).enumerated()), id: \.offset) { _, k in
                                HStack(spacing: 8) {
                                    Text(k.colo_name ?? "-").font(.caption.bold())
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.15)).cornerRadius(4)
                                    Text(k.origin_ip ?? "").font(.caption2).foregroundColor(.secondary)
                                    if k.is_pending_reconnect == true {
                                        Text("重连中").font(.caption2).foregroundColor(.orange)
                                    }
                                }
                            }
                        }
                    }
                    if !data.clients.isEmpty {
                        Button("清理失效连接") {
                            Task {
                                do {
                                    _ = try await ctx.c.raw("DELETE", "accounts/\(ctx.acc)/cfd_tunnel/\(tid)/connections")
                                    message = "已发送清理请求"
                                    await reload()
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }

                Section(header: Text("公共主机名（\(ingress.count)）"),
                        footer: Text(data.config?["config"] == nil
                                     ? "没有读取到远程配置：本地配置文件管理的隧道请在 cloudflared 的 config.yml 里修改。"
                                     : "添加时会自动在对应域名下创建指向此隧道的 CNAME（需要该域名在当前账户下）。")) {
                    ForEach(Array(ingress.enumerated()), id: \.offset) { _, item in
                        let host = item["hostname"]?.description ?? ""
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host).font(.subheadline.bold())
                            Text(item["service"]?.description ?? "").font(.caption).foregroundColor(.secondary)
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                Task {
                                    do {
                                        try await Self.putIngress(ctx, tid, data.config, remove: host, add: nil)
                                        await reload()
                                    } catch { self.error = error.localizedDescription }
                                }
                            }
                        }
                    }
                    if tunnel.remote_config != false {
                        Button { adding = true } label: { Label("添加公共主机名", systemImage: "plus") }
                    }
                }

                Section("运行") {
                    if let token {
                        Text(token).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        Button("复制令牌") { UIPasteboard.general.string = token }
                        Button("复制安装命令") {
                            UIPasteboard.general.string = "cloudflared service install \(token)"
                        }
                        Button("复制 Docker 命令") {
                            UIPasteboard.general.string = "docker run -d --restart unless-stopped cloudflare/cloudflared:latest tunnel --no-autoupdate run --token \(token)"
                        }
                    } else {
                        Button("获取运行令牌") {
                            Task {
                                do {
                                    token = try await ctx.c.get("accounts/\(ctx.acc)/cfd_tunnel/\(tid)/token")
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
            }
            .refreshable { await reload() }
            .sheet(isPresented: $adding) {
                TunnelHostSheet { host, service in
                    try await Self.putIngress(ctx, tid, data.config, remove: nil, add: (host, service))
                    let note = await Self.createCNAME(ctx, tid, host)
                    message = note
                    await reload()
                }
            }
        }
        .navigationTitle(tunnel.name)
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { _ in })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
        .errorAlert($error)
    }

    /// 修改远程 ingress：remove 删除某主机名，add 追加（保证最后一条仍是 catch-all）
    static func putIngress(_ ctx: Ctx, _ tid: String, _ current: JSONValue?,
                           remove: String?, add: (String, String)?) async throws {
        var cfg = current?["config"]?.object ?? [:]
        var ingress = cfg["ingress"]?.array ?? []
        if let r = remove { ingress.removeAll { $0["hostname"]?.description == r } }
        if let (host, service) = add {
            ingress.removeAll { $0["hostname"]?.description == host }
            let entry = JSONValue.object(["hostname": .string(host), "service": .string(service)])
            if let last = ingress.last, last["hostname"] == nil {
                ingress.insert(entry, at: ingress.count - 1)
            } else {
                ingress.append(entry)
                ingress.append(.object(["service": .string("http_status:404")]))
            }
        }
        if ingress.isEmpty || ingress.last?["hostname"] != nil {
            ingress.append(.object(["service": .string("http_status:404")]))
        }
        cfg["ingress"] = .array(ingress)
        try await ctx.c.send("PUT", "accounts/\(ctx.acc)/cfd_tunnel/\(tid)/configurations",
                             json: JSONValue.object(["config": .object(cfg)]))
    }

    /// 在主机名所属 Zone 里创建指向隧道的 CNAME（失败只返回提示，不抛错）
    static func createCNAME(_ ctx: Ctx, _ tid: String, _ host: String) async -> String {
        guard let zones: [Zone] = try? await ctx.c.get("zones", query: ["per_page": "50"]) else {
            return "主机名已添加，但读取域名列表失败，请手动添加 CNAME 到 \(tid).cfargotunnel.com"
        }
        let match = zones.filter { host == $0.name || host.hasSuffix("." + $0.name) }
            .max { $0.name.count < $1.name.count }
        guard let z = match else {
            return "主机名已添加。\(host) 不在当前账户的域名下，请手动添加 CNAME 到 \(tid).cfargotunnel.com"
        }
        do {
            try await ctx.c.send("POST", "zones/\(z.id)/dns_records",
                                 json: DNSBody(type: "CNAME", name: host, content: "\(tid).cfargotunnel.com",
                                               ttl: 1, proxied: true))
            return "已添加主机名，并创建了 CNAME 记录"
        } catch {
            return "主机名已添加，CNAME 创建失败：\(error.localizedDescription)"
        }
    }
}

struct TunnelDetailData {
    var clients: [TunnelClient]
    var config: JSONValue?
}

// MARK: - 添加主机名

struct TunnelHostSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSubmit: (String, String) async throws -> Void

    @State private var host = ""
    @State private var service = "http://localhost:80"
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("服务地址是 cloudflared 所在机器能访问到的源站，例如 http://localhost:8080、https://127.0.0.1:443、ssh://localhost:22。")) {
                    TextField("主机名，例如 app.example.com", text: $host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("服务地址", text: $service)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
            }
            .navigationTitle("添加公共主机名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") { Task { await submit() } }
                        .disabled(saving || host.trimmingCharacters(in: .whitespaces).isEmpty
                                  || service.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .errorAlert($error)
        }
        .presentationDetents([.medium])
    }

    private func submit() async {
        saving = true
        defer { saving = false }
        do {
            try await onSubmit(host.trimmingCharacters(in: .whitespaces).lowercased(),
                               service.trimmingCharacters(in: .whitespaces))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
