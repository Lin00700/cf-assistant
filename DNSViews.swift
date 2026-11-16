import SwiftUI

struct ZonePlan: Decodable, Hashable { let name: String? }

struct Zone: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let status: String?
    let plan: ZonePlan?
}

struct DNSRecord: Decodable, Identifiable {
    let id: String
    var type: String
    var name: String
    var content: String
    var ttl: Int
    var proxied: Bool?
}

struct DNSBody: Encodable {
    let type: String
    let name: String
    let content: String
    let ttl: Int
    let proxied: Bool
}

struct ZonesView: View {
    @EnvironmentObject var session: Session
    @State private var query = ""
    @State private var creating = false

    var body: some View {
        let ctx = session.ctx
        LoadView(load: { () async throws -> [Zone] in
            try await ctx.c.get("zones", query: ["per_page": "50"])
        }) { zones, reload in
            let shown = zones.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            List(shown) { z in
                NavigationLink(value: z) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(z.name).font(.headline)
                        Text(z.status ?? "").font(.caption).foregroundColor(.secondary)
                    }
                }
                .contextMenu {
                    Button("复制域名") { UIPasteboard.general.string = z.name }
                    Button("复制 Zone ID") { UIPasteboard.general.string = z.id }
                }
            }
            .scrollContentBackground(.hidden)
            .searchable(text: $query, prompt: "搜索域名")
            .overlay { if shown.isEmpty { EmptyHint(text: zones.isEmpty ? "没有域名" : "没有匹配的域名") } }
            .refreshable { await reload() }
            .navigationDestination(for: Zone.self) { ZoneDetailView(zone: $0) }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $creating) { ZoneCreateSheet { Task { await reload() } } }
        }
        .navigationTitle("域名")
    }
}

struct ZoneCreateSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    var onCreated: () -> Void
    @State private var name = ""
    @State private var kind = "full"
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("example.com", text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("接入方式", selection: $kind) {
                    Text("完整（Cloudflare DNS）").tag("full")
                    Text("CNAME 设置").tag("partial")
                }
                if let error { Text(error).font(.footnote).foregroundColor(.red) }
            }
            .navigationTitle("添加站点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { Task { await go() } }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func go() async {
        let body: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "account": ["id": session.accountId],
            "type": kind
        ]
        do {
            _ = try await session.ctx.c.resultValue("POST", "zones", body: try jsonBody(body))
            onCreated(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct DNSRecordsView: View {
    @EnvironmentObject var session: Session
    let zone: Zone
    @State private var editing: DNSRecord?
    @State private var creating = false
    @State private var error: String?
    @State private var refreshToken = UUID()

    var body: some View {
        let ctx = session.ctx
        let zid = zone.id
        LoadView(load: { () async throws -> [DNSRecord] in
            try await ctx.c.get("zones/\(zid)/dns_records", query: ["per_page": "200"])
        }) { records, reload in
            List {
                ForEach(records) { r in
                    Button { editing = r } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(r.type).font(.caption.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.15)).cornerRadius(4)
                                Text(r.name).font(.subheadline.bold()).lineLimit(1)
                                Spacer()
                                if r.proxied == true { Image(systemName: "cloud.fill").foregroundColor(.orange) }
                            }
                            Text(r.content).font(.caption).foregroundColor(.secondary).lineLimit(2)
                        }
                    }
                    .foregroundColor(.primary)
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            Task {
                                do {
                                    try await ctx.c.delete("zones/\(zid)/dns_records/\(r.id)")
                                    await reload()
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
            }
            .overlay { if records.isEmpty { EmptyHint(text: "没有 DNS 记录") } }
            .refreshable { await reload() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    DNSToolsMenu(zone: zone, records: records) { Task { await reload() } }
                }
            }
            .sheet(item: $editing) { r in
                DNSEditView(zoneId: zid, record: r) { Task { await reload() } }
            }
            .sheet(isPresented: $creating) {
                DNSEditView(zoneId: zid, record: nil) { Task { await reload() } }
            }
        }
        .id(refreshToken)
        .navigationTitle(zone.name)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }
            }
        }
        .errorAlert($error)
    }
}

struct DNSEditView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let zoneId: String
    let record: DNSRecord?
    let onSaved: () -> Void

    @State private var type = "A"
    @State private var name = ""
    @State private var content = ""
    @State private var ttl = 1
    @State private var proxied = false
    @State private var saving = false
    @State private var error: String?

    private let types = ["A", "AAAA", "CNAME", "TXT", "MX", "NS", "SRV", "CAA"]
    private var canProxy: Bool { ["A", "AAAA", "CNAME"].contains(type) }

    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $type) { ForEach(types, id: \.self) { Text($0) } }
                TextField("名称", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("内容", text: $content).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("TTL", selection: $ttl) {
                    Text("自动").tag(1)
                    Text("1 分钟").tag(60)
                    Text("5 分钟").tag(300)
                    Text("1 小时").tag(3600)
                    Text("1 天").tag(86400)
                }
                if canProxy { Toggle("通过 Cloudflare 代理", isOn: $proxied) }
            }
            .navigationTitle(record == nil ? "添加记录" : "编辑记录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") { Task { await save() } }
                        .disabled(saving || name.isEmpty || content.isEmpty)
                }
            }
            .errorAlert($error)
        }
        .onAppear {
            if let r = record {
                type = r.type; name = r.name; content = r.content
                ttl = r.ttl; proxied = r.proxied ?? false
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let ctx = session.ctx
        let body = DNSBody(type: type, name: name, content: content, ttl: ttl, proxied: canProxy && proxied)
        do {
            if let r = record {
                try await ctx.c.send("PUT", "zones/\(zoneId)/dns_records/\(r.id)", json: body)
            } else {
                try await ctx.c.send("POST", "zones/\(zoneId)/dns_records", json: body)
            }
            onSaved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
