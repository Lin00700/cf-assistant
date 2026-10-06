import SwiftUI

// MARK: - 入口

struct StorageView: View {
    var body: some View {
        List {
            NavigationLink { KVNamespacesView() } label: { Label("KV 命名空间", systemImage: "key") }
            NavigationLink { D1DatabasesView() } label: { Label("D1 数据库", systemImage: "cylinder") }
            NavigationLink { R2BucketsView() } label: { Label("R2 存储桶", systemImage: "shippingbox") }
        }
        .navigationTitle("存储")
    }
}

// MARK: - KV

struct KVNamespace: Decodable, Identifiable, Hashable { let id: String; let title: String }
struct KVKey: Decodable, Identifiable { let name: String; var id: String { name } }

struct KVNamespacesView: View {
    @EnvironmentObject var session: Session

    var body: some View {
        let ctx = session.ctx
        LoadView(load: { () async throws -> [KVNamespace] in
            try await ctx.c.get("accounts/\(ctx.acc)/storage/kv/namespaces", query: ["per_page": "100"])
        }) { items, reload in
            List(items) { ns in
                NavigationLink(ns.title) { KVKeysView(ns: ns) }
            }
            .overlay { if items.isEmpty { EmptyHint(text: "没有 KV 命名空间") } }
            .refreshable { await reload() }
        }
        .navigationTitle("KV")
    }
}

struct KVKeysView: View {
    @EnvironmentObject var session: Session
    let ns: KVNamespace
    @State private var editing: KVEditTarget?
    @State private var error: String?

    var body: some View {
        let ctx = session.ctx
        let nid = ns.id
        LoadView(load: { () async throws -> [KVKey] in
            try await ctx.c.get("accounts/\(ctx.acc)/storage/kv/namespaces/\(nid)/keys",
                                query: ["limit": "1000"])
        }) { keys, reload in
            List {
                ForEach(keys) { k in
                    Button(k.name) { editing = KVEditTarget(key: k.name) }
                        .foregroundColor(.primary)
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                Task {
                                    do {
                                        try await ctx.c.delete(
                                            "accounts/\(ctx.acc)/storage/kv/namespaces/\(nid)/values/\(Self.enc(k.name))")
                                        await reload()
                                    } catch { self.error = error.localizedDescription }
                                }
                            }
                        }
                }
            }
            .overlay { if keys.isEmpty { EmptyHint(text: "没有键") } }
            .refreshable { await reload() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { editing = KVEditTarget(key: nil) } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { t in
                KVEditView(nsId: nid, key: t.key) { Task { await reload() } }
            }
        }
        .navigationTitle(ns.title)
        .errorAlert($error)
    }

    static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}

struct KVEditTarget: Identifiable { let id = UUID(); let key: String? }

struct KVEditView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let nsId: String
    let key: String?
    let onSaved: () -> Void

    @State private var keyName = ""
    @State private var value = ""
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if key == nil {
                    TextField("键名", text: $keyName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(10).background(Color(.secondarySystemBackground))
                }
                if key != nil && !loaded {
                    ProgressView().frame(maxHeight: .infinity)
                } else {
                    TextEditor(text: $value)
                        .font(.system(size: 13, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            .navigationTitle(key ?? "新建键")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled((key ?? keyName).isEmpty)
                }
            }
            .errorAlert($error)
        }
        .task { await load() }
    }

    private func load() async {
        guard let key, !loaded else { return }
        let ctx = session.ctx
        do {
            let data = try await ctx.c.raw(
                "GET", "accounts/\(ctx.acc)/storage/kv/namespaces/\(nsId)/values/\(KVKeysView.enc(key))")
            value = String(decoding: data, as: UTF8.self)
            loaded = true
        } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        let ctx = session.ctx
        let k = key ?? keyName
        do {
            let _: JSONValue = try await ctx.c.request(
                "PUT", "accounts/\(ctx.acc)/storage/kv/namespaces/\(nsId)/values/\(KVKeysView.enc(k))",
                body: Data(value.utf8), contentType: "text/plain")
            onSaved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - D1

struct D1Database: Decodable, Identifiable, Hashable {
    let uuid: String
    let name: String
    var id: String { uuid }
}

struct D1Result: Decodable {
    let results: [[String: JSONValue]]?
}

struct D1QueryBody: Encodable { let sql: String }

struct D1DatabasesView: View {
    @EnvironmentObject var session: Session

    var body: some View {
        let ctx = session.ctx
        LoadView(load: { () async throws -> [D1Database] in
            try await ctx.c.get("accounts/\(ctx.acc)/d1/database", query: ["per_page": "100"])
        }) { items, reload in
            List(items) { db in
                NavigationLink(db.name) { D1QueryView(db: db) }
            }
            .overlay { if items.isEmpty { EmptyHint(text: "没有 D1 数据库") } }
            .refreshable { await reload() }
        }
        .navigationTitle("D1")
    }
}

struct D1QueryView: View {
    @EnvironmentObject var session: Session
    let db: D1Database
    @State private var sql = "SELECT name FROM sqlite_master WHERE type='table';"
    @State private var rows: [[String: JSONValue]] = []
    @State private var running = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $sql)
                .font(.system(size: 14, design: .monospaced))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                .padding()
            Button {
                Task { await run() }
            } label: {
                if running { ProgressView() } else { Label("执行", systemImage: "play.fill") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(running || sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            List {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(row.keys.sorted(), id: \.self) { k in
                            HStack(alignment: .top) {
                                Text(k).font(.caption.bold()).foregroundColor(.secondary)
                                Text(row[k]?.description ?? "").font(.system(size: 13, design: .monospaced))
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle(db.name)
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert($error)
    }

    private func run() async {
        running = true
        defer { running = false }
        let ctx = session.ctx
        do {
            let result: [D1Result] = try await ctx.c.request(
                "POST", "accounts/\(ctx.acc)/d1/database/\(db.uuid)/query",
                body: try JSONEncoder().encode(D1QueryBody(sql: sql)))
            rows = result.first?.results ?? []
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - R2

struct R2Bucket: Decodable, Identifiable {
    let name: String
    let creation_date: String?
    var id: String { name }
}
struct R2BucketList: Decodable { let buckets: [R2Bucket] }

struct R2BucketsView: View {
    @EnvironmentObject var session: Session
    @State private var error: String?

    var body: some View {
        let ctx = session.ctx
        LoadView(load: { () async throws -> [R2Bucket] in
            let list: R2BucketList = try await ctx.c.get("accounts/\(ctx.acc)/r2/buckets")
            return list.buckets
        }) { items, reload in
            List(items) { b in
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.name).font(.headline)
                    if let d = b.creation_date {
                        Text("创建于 \(d.prefix(10))").font(.caption).foregroundColor(.secondary)
                    }
                }
                .swipeActions {
                    Button("删除", role: .destructive) {
                        Task {
                            do {
                                try await ctx.c.delete("accounts/\(ctx.acc)/r2/buckets/\(b.name)")
                                await reload()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
            .overlay { if items.isEmpty { EmptyHint(text: "没有 R2 存储桶") } }
            .refreshable { await reload() }
        }
        .navigationTitle("R2")
        .errorAlert($error)
    }
}
