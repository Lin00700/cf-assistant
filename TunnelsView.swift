import SwiftUI

struct CFTunnel: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let status: String?
    let created_at: String?
}

struct TunnelConnection: Decodable {
    let id: String?
    let colo_name: String?
    let origin_ip: String?
    let opened_at: String?
    var identity: String { (id ?? "") + (colo_name ?? "") + (opened_at ?? "") }
}

struct TunnelConnectionGroup: Decodable {
    let conns: [TunnelConnection]?
}

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
                        Circle().fill(color(t.status)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).font(.headline)
                            Text(t.status ?? "").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button("删除", role: .destructive) {
                        Task {
                            do {
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

    private func color(_ s: String?) -> Color {
        switch s {
        case "healthy": return .green
        case "degraded": return .orange
        case "down": return .red
        default: return .gray
        }
    }
}

struct TunnelDetailView: View {
    @EnvironmentObject var session: Session
    let tunnel: CFTunnel
    @State private var token: String?
    @State private var error: String?

    var body: some View {
        let ctx = session.ctx
        let tid = tunnel.id
        LoadView(load: { () async throws -> [TunnelConnectionGroup] in
            try await ctx.c.get("accounts/\(ctx.acc)/cfd_tunnel/\(tid)/connections")
        }) { groups, reload in
            let conns = groups.flatMap { $0.conns ?? [] }
            List {
                Section("信息") {
                    LabeledContent("ID", value: tunnel.id)
                    LabeledContent("状态", value: tunnel.status ?? "-")
                    if let c = tunnel.created_at { LabeledContent("创建于", value: String(c.prefix(19))) }
                }
                Section("连接 (\(conns.count))") {
                    ForEach(conns, id: \.identity) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.colo_name ?? "-").font(.subheadline.bold())
                            Text(c.origin_ip ?? "").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                Section("运行令牌") {
                    if let token {
                        Text(token).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        Button("复制") { UIPasteboard.general.string = token }
                    } else {
                        Button("获取 Token") {
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
        }
        .navigationTitle(tunnel.name)
        .errorAlert($error)
    }
}
