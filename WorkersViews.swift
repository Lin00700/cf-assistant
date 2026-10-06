import SwiftUI

struct WorkerScript: Decodable, Identifiable, Hashable {
    let id: String
    let modified_on: String?
    let created_on: String?
}

struct WorkersView: View {
    @EnvironmentObject var session: Session
    @State private var error: String?
    @State private var creating = false

    var body: some View {
        let ctx = session.ctx
        LoadView(load: { () async throws -> [WorkerScript] in
            try await ctx.c.get("accounts/\(ctx.acc)/workers/scripts")
        }) { scripts, reload in
            List {
                ForEach(scripts) { s in
                    NavigationLink {
                        WorkerEditorView(name: s.id, isNew: false) { Task { await reload() } }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.id).font(.headline)
                            if let m = s.modified_on {
                                Text("修改于 \(m.prefix(19).replacingOccurrences(of: "T", with: " "))")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            Task {
                                do {
                                    try await ctx.c.delete("accounts/\(ctx.acc)/workers/scripts/\(s.id)",
                                                           query: ["force": "true"])
                                    await reload()
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
            }
            .overlay { if scripts.isEmpty { EmptyHint(text: "没有 Worker") } }
            .refreshable { await reload() }
            .sheet(isPresented: $creating) {
                NavigationStack {
                    WorkerEditorView(name: "", isNew: true) {
                        creating = false
                        Task { await reload() }
                    }
                }
            }
        }
        .navigationTitle("Workers")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }
            }
        }
        .errorAlert($error)
    }
}

struct WorkerEditorView: View {
    @EnvironmentObject var session: Session
    @State var name: String
    let isNew: Bool
    let onSaved: () -> Void

    @State private var code = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var message: String?
    @State private var error: String?

    private var isModule: Bool { code.contains("export default") || code.contains("export {") }

    var body: some View {
        VStack(spacing: 0) {
            if isNew {
                TextField("Worker 名称", text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(10).background(Color(.secondarySystemBackground))
            }
            if !loaded && !isNew {
                ProgressView().frame(maxHeight: .infinity)
            } else {
                TextEditor(text: $code)
                    .font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            HStack {
                Text(isModule ? "ES Module" : "Service Worker")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Text("\(code.count) 字符").font(.caption).foregroundColor(.secondary)
            }
            .padding(8)
        }
        .navigationTitle(isNew ? "新建 Worker" : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "上传中…" : "保存并部署") { Task { await save() } }
                    .disabled(saving || name.isEmpty || code.isEmpty)
            }
        }
        .task { await load() }
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
        .errorAlert($error)
    }

    private func load() async {
        guard !isNew, !loaded else { return }
        let ctx = session.ctx
        do {
            let data = try await ctx.c.raw("GET", "accounts/\(ctx.acc)/workers/scripts/\(name)/content/v2")
            code = String(decoding: data, as: UTF8.self)
            loaded = true
        } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let ctx = session.ctx
        let module = isModule
        let fileName = module ? "worker.js" : "script.js"
        let metadata: [String: String] = module ? ["main_module": fileName] : ["body_part": "script"]
        guard let metaData = try? JSONSerialization.data(withJSONObject: metadata) else { return }
        let scriptType = module ? "application/javascript+module" : "application/javascript"
        let parts = [
            MultipartPart(name: "metadata", filename: nil, contentType: "application/json", data: metaData),
            MultipartPart(name: module ? fileName : "script", filename: fileName,
                          contentType: scriptType, data: Data(code.utf8))
        ]
        let (body, ct) = buildMultipart(parts)
        do {
            // 新建用 scripts/{name}，已有脚本只更新代码用 /content，保留绑定与设置
            let path = isNew ? "accounts/\(ctx.acc)/workers/scripts/\(name)"
                             : "accounts/\(ctx.acc)/workers/scripts/\(name)/content"
            let _: JSONValue = try await ctx.c.request("PUT", path, body: body, contentType: ct)
            message = "已部署"
            onSaved()
        } catch { self.error = error.localizedDescription }
    }
}
