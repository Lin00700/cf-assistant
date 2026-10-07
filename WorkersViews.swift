import SwiftUI

struct WorkerScript: Decodable, Identifiable, Hashable {
    let id: String
    let modified_on: String?
    let created_on: String?
}

struct WorkerSubdomain: Decodable { let subdomain: String? }

// MARK: - 模板

enum WorkerTemplate: String, CaseIterable, Identifiable {
    case helloWorld, json, redirect, blank
    var id: String { rawValue }

    var title: String {
        switch self {
        case .helloWorld: return "Start with Hello World!"
        case .json: return "返回 JSON"
        case .redirect: return "重定向"
        case .blank: return "空白"
        }
    }

    var defaultName: String {
        switch self {
        case .helloWorld: return "hello-world"
        case .json: return "json-api"
        case .redirect: return "redirect"
        case .blank: return "my-worker"
        }
    }

    var code: String {
        switch self {
        case .helloWorld:
            return """
            export default {
              async fetch(request, env, ctx) {
                return new Response("Hello World!");
              },
            };
            """
        case .json:
            return """
            export default {
              async fetch(request, env, ctx) {
                return Response.json({
                  message: "Hello from Cloudflare Workers",
                  time: new Date().toISOString(),
                });
              },
            };
            """
        case .redirect:
            return """
            export default {
              async fetch(request, env, ctx) {
                return Response.redirect("https://example.com", 302);
              },
            };
            """
        case .blank:
            return """
            export default {
              async fetch(request, env, ctx) {
                return new Response("");
              },
            };
            """
        }
    }
}

// MARK: - 列表

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
                        WorkerDetailView(name: s.id) { Task { await reload() } }
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
            .overlay {
                if scripts.isEmpty {
                    VStack(spacing: 12) {
                        EmptyHint(text: "还没有 Worker")
                        Button("Start with Hello World!") { creating = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
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

// MARK: - 编辑器

struct WorkerEditorView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State var name: String
    let isNew: Bool
    let onSaved: () -> Void

    @State private var code = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var savedOK = false
    @State private var message: String?
    @State private var error: String?

    private var isModule: Bool { code.contains("export default") || code.contains("export {") }
    private var cleanName: String { name.trimmingCharacters(in: .whitespaces).lowercased() }

    var body: some View {
        VStack(spacing: 0) {
            if isNew {
                TextField("Worker 名称（小写字母、数字、连字符）", text: $name)
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
        .navigationTitle(isNew ? "创建 Worker" : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                    Menu("模板") {
                        ForEach(WorkerTemplate.allCases) { t in
                            Button(t.title) { apply(t) }
                        }
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "部署中…" : (isNew ? "部署" : "保存并部署")) { Task { await save() } }
                    .disabled(saving || cleanName.isEmpty || code.isEmpty)
            }
        }
        .task { await load() }
        .onAppear {
            if isNew && code.isEmpty { apply(.helloWorld) }
        }
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { _ in })) {
            Button("好") {
                message = nil
                if savedOK { savedOK = false; onSaved() }
            }
        } message: { Text(message ?? "") }
        .errorAlert($error)
    }

    private func apply(_ t: WorkerTemplate) {
        code = t.code
        let known = WorkerTemplate.allCases.map(\.defaultName)
        if name.isEmpty || known.contains(name) { name = t.defaultName }
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
        let scriptName = isNew ? cleanName : name
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
            // 新建：PUT scripts/{name}；已有脚本只更新代码（/content），保留绑定与设置
            let path = isNew ? "accounts/\(ctx.acc)/workers/scripts/\(scriptName)"
                             : "accounts/\(ctx.acc)/workers/scripts/\(scriptName)/content"
            let _: JSONValue = try await ctx.c.request("PUT", path, body: body, contentType: ct)

            var text = "已部署"
            if isNew {
                // 尽力开启 workers.dev 访问并给出链接
                _ = try? await ctx.c.send("POST", "accounts/\(ctx.acc)/workers/scripts/\(scriptName)/subdomain",
                                          json: ["enabled": true])
                if let sub: WorkerSubdomain = try? await ctx.c.get("accounts/\(ctx.acc)/workers/subdomain"),
                   let s = sub.subdomain {
                    text += "\nhttps://\(scriptName).\(s).workers.dev"
                }
            }
            savedOK = true
            message = text
        } catch { self.error = error.localizedDescription }
    }
}
