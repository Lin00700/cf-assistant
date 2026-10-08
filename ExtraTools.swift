import SwiftUI
import UniformTypeIdentifiers

// MARK: - DNS 导入 / 导出

struct DNSToolsMenu: View {
    @EnvironmentObject var session: Session
    let zone: Zone
    let records: [DNSRecord]
    let onImported: () -> Void

    @State private var share: ShareItems?
    @State private var picking = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        Menu {
            Button { Task { await exportBIND() } } label: {
                Label("导出 BIND 文件", systemImage: "square.and.arrow.up")
            }
            Button { exportCSV() } label: {
                Label("导出 CSV", systemImage: "tablecells")
            }
            Button { picking = true } label: {
                Label("导入 BIND 文件", systemImage: "square.and.arrow.down")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.plainText, .data],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let u = urls.first { Task { await importFile(u) } }
            case .failure(let e):
                error = e.localizedDescription
            }
        }
        .sheet(item: $share) { ShareSheet(items: $0.urls) }
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { _ in })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
        .errorAlert($error)
    }

    private func writeTemp(_ name: String, _ text: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func exportBIND() async {
        let ctx = session.ctx
        do {
            let data = try await ctx.c.raw("GET", "zones/\(zone.id)/dns_records/export")
            if let url = writeTemp("\(zone.name).bind.txt", String(decoding: data, as: UTF8.self)) {
                share = ShareItems(urls: [url])
            }
        } catch { self.error = error.localizedDescription }
    }

    private func exportCSV() {
        func esc(_ s: String) -> String {
            s.contains(",") || s.contains("\"") || s.contains("\n")
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var out = "type,name,content,ttl,proxied\n"
        for r in records {
            out += [r.type, esc(r.name), esc(r.content), String(r.ttl), (r.proxied ?? false) ? "true" : "false"]
                .joined(separator: ",") + "\n"
        }
        if let url = writeTemp("\(zone.name).dns.csv", out) { share = ShareItems(urls: [url]) }
    }

    private func importFile(_ url: URL) async {
        let ctx = session.ctx
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            error = "读取文件失败"
            return
        }
        let (body, ct) = buildMultipart([
            MultipartPart(name: "file", filename: "records.txt", contentType: "text/plain", data: data),
            MultipartPart(name: "proxied", filename: nil, contentType: "", data: Data("false".utf8))
        ])
        do {
            let r: JSONValue = try await ctx.c.request("POST", "zones/\(zone.id)/dns_records/import",
                                                       body: body, contentType: ct)
            let added = r["recs_added"]?.description ?? "?"
            let total = r["total_records_parsed"]?.description ?? "?"
            message = "解析 \(total) 条，新增 \(added) 条"
            onImported()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - KV 批量导入

struct KVBulkImportSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let nsId: String
    let onDone: () -> Void

    @State private var text = ""
    @State private var running = false
    @State private var message: String?
    @State private var error: String?

    /// 支持 JSON 数组 [{"key":"a","value":"b"}]，或每行 key=value
    private var pairs: [[String: String]] {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("["), let data = s.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return arr.compactMap { o -> [String: String]? in
                guard let k = o["key"] as? String else { return nil }
                let v = (o["value"] as? String) ?? "\(o["value"] ?? "")"
                return ["key": k, "value": v]
            }
        }
        return s.components(separatedBy: .newlines).compactMap { line -> [String: String]? in
            guard let i = line.firstIndex(of: "=") else { return nil }
            let k = String(line[..<i]).trimmingCharacters(in: .whitespaces)
            if k.isEmpty { return nil }
            return ["key": k, "value": String(line[line.index(after: i)...])]
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(8)
                Text("格式：每行 key=value，或 JSON 数组 [{\"key\":\"a\",\"value\":\"b\"}]。已识别 \(pairs.count) 条，同名键会被覆盖。")
                    .font(.caption).foregroundColor(.secondary).padding(8)
            }
            .navigationTitle("批量导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(running ? "导入中…" : "导入") { Task { await run() } }
                        .disabled(running || pairs.isEmpty)
                }
            }
            .alert("完成", isPresented: Binding(get: { message != nil }, set: { _ in })) {
                Button("好") { message = nil; onDone(); dismiss() }
            } message: { Text(message ?? "") }
            .errorAlert($error)
        }
    }

    private func run() async {
        running = true
        defer { running = false }
        let ctx = session.ctx
        let all = pairs
        var done = 0
        do {
            var i = 0
            while i < all.count {
                let chunk = Array(all[i..<min(i + 500, all.count)])
                let body = try JSONSerialization.data(withJSONObject: chunk)
                let _: JSONValue = try await ctx.c.request(
                    "PUT", "accounts/\(ctx.acc)/storage/kv/namespaces/\(nsId)/bulk", body: body)
                done += chunk.count
                i += 500
            }
            message = "已写入 \(done) 条"
        } catch {
            self.error = "已写入 \(done) 条后出错：\(error.localizedDescription)"
        }
    }
}

// MARK: - 优选 IP → Worker / Pages 变量

struct BestCFVarPushView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let results: [IPResult]

    @State private var target = 0          // 0 Worker, 1 Pages
    @State private var workers: [String] = []
    @State private var projects: [String] = []
    @State private var selected = ""
    @State private var varName = "BEST_IPS"
    @State private var format = 0          // 0 仅 IP, 1 IP:端口, 2 每行一个 IP:端口
    @State private var count = 10
    @State private var confirm = false
    @State private var running = false
    @State private var message: String?
    @State private var error: String?

    private var options: [String] { target == 0 ? workers : projects }

    private var value: String {
        var seen = Set<String>()
        var items: [String] = []
        for r in results where !r.ip.isEmpty {
            let s = format == 0 ? r.ip : bestCFFmtAddr(r.ip, r.port)
            if seen.insert(s).inserted { items.append(s) }
            if items.count >= count { break }
        }
        return items.joined(separator: format == 2 ? "\n" : ",")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("目标") {
                    Picker("类型", selection: $target) {
                        Text("Worker").tag(0)
                        Text("Pages 生产环境").tag(1)
                    }
                    .pickerStyle(.segmented)
                    if options.isEmpty {
                        Text("没有可用的目标").foregroundColor(.secondary)
                    } else {
                        Picker(target == 0 ? "Worker" : "项目", selection: $selected) {
                            ForEach(options, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    TextField("变量名", text: $varName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("内容") {
                    Stepper("取前 \(count) 个", value: $count, in: 1...50)
                    Picker("格式", selection: $format) {
                        Text("仅 IP，逗号分隔").tag(0)
                        Text("IP:端口，逗号分隔").tag(1)
                        Text("IP:端口，每行一个").tag(2)
                    }
                    Text(value).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                }
                Section(footer: Text(target == 0 ? "会更新 Worker 的文本变量，其他绑定保持不变。" : "写入后需要重新部署才会生效。")) {
                    Button {
                        confirm = true
                    } label: {
                        HStack {
                            Spacer()
                            if running { ProgressView() } else { Text("写入").bold() }
                            Spacer()
                        }
                    }
                    .disabled(running || selected.isEmpty || varName.trimmingCharacters(in: .whitespaces).isEmpty || value.isEmpty)
                }
            }
            .navigationTitle("写入变量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task { await load() }
            .onChange(of: target) { _ in selected = options.first ?? "" }
            .confirmationDialog("把 \(varName) 写入 \(selected)？同名变量会被覆盖。",
                                isPresented: $confirm, titleVisibility: .visible) {
                Button("写入", role: .destructive) { Task { await push() } }
                Button("取消", role: .cancel) {}
            }
            .alert("完成", isPresented: Binding(get: { message != nil }, set: { _ in })) {
                Button("好") { message = nil; dismiss() }
            } message: { Text(message ?? "") }
            .errorAlert($error)
        }
    }

    private func load() async {
        let ctx = session.ctx
        let w: [WorkerScript]? = try? await ctx.c.get("accounts/\(ctx.acc)/workers/scripts")
        let p: [PagesProject]? = try? await ctx.c.get("accounts/\(ctx.acc)/pages/projects")
        workers = (w ?? []).map { $0.id }
        projects = (p ?? []).map { $0.name }
        selected = options.first ?? ""
    }

    private func push() async {
        running = true
        defer { running = false }
        let ctx = session.ctx
        let name = varName.trimmingCharacters(in: .whitespaces)
        let v = value
        do {
            if target == 0 {
                let r: JSONValue = try await ctx.c.get("accounts/\(ctx.acc)/workers/scripts/\(selected)/settings")
                var next = WorkerVariablesView.normalized(r["bindings"]?.array ?? [])
                    .filter { $0["name"]?.description != name }
                next.append(.object(["type": .string("plain_text"), "name": .string(name), "text": .string(v)]))
                try await WorkerVariablesView.patchBindings(ctx, selected, next)
            } else {
                try await pagesPatchEnv(ctx, selected, "production", "env_vars",
                                        [name: .object(["type": .string("plain_text"), "value": .string(v)])])
            }
            message = "已写入 \(name)"
        } catch { self.error = error.localizedDescription }
    }
}
