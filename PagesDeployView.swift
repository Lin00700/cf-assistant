import SwiftUI
import CryptoKit
import UniformTypeIdentifiers

struct DeployFile: Sendable {
    let path: String      // 以 / 开头，例如 /index.html
    let data: Data
}

enum PagesTemplates {
    static let helloWorld = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Hello World!</title>
      <style>
        body { margin: 0; min-height: 100vh; display: flex; align-items: center;
               justify-content: center; font-family: -apple-system, system-ui, sans-serif;
               background: #fff7ed; color: #9a3412; }
        h1 { font-size: 2.6rem; }
      </style>
    </head>
    <body>
      <h1>Hello World! 👋</h1>
    </body>
    </html>
    """
}

// MARK: - 部署流程（对应 wrangler pages deploy 的直接上传流程）

struct PagesDeployer {
    let ctx: Ctx
    let log: (String) -> Void

    func deploy(project: String, files: [DeployFile]) async throws -> String {
        let acc = ctx.acc
        guard !files.isEmpty else { throw CFClientError.message("没有可部署的文件") }

        // 1. 项目不存在就创建
        do {
            let _: JSONValue = try await ctx.c.get("accounts/\(acc)/pages/projects/\(project)")
            log("使用已有项目 \(project)")
        } catch {
            log("创建项目 \(project)…")
            try await ctx.c.send("POST", "accounts/\(acc)/pages/projects",
                                 json: ["name": project, "production_branch": "main"])
        }

        // 2. 上传凭证
        struct Upload: Decodable { let jwt: String }
        let upload: Upload = try await ctx.c.get("accounts/\(acc)/pages/projects/\(project)/upload-token")
        let jwt = upload.jwt

        // 3. 计算哈希，询问哪些文件需要上传
        let items = files.map { (file: $0, hash: Self.hash($0)) }
        let allHashes = Array(Set(items.map { $0.hash }))
        log("共 \(files.count) 个文件，检查需要上传的内容…")
        let missingResult = try await post("pages/assets/check-missing", jwt: jwt, json: ["hashes": allHashes])
        let missing = Set((missingResult?.array ?? []).map { $0.description })

        // 4. 分批上传缺失文件
        var pending = items.filter { missing.contains($0.hash) }
        var seen = Set<String>()
        pending = pending.filter { seen.insert($0.hash).inserted }
        log("需要上传 \(pending.count) 个文件")

        var index = 0
        while index < pending.count {
            var batch: [[String: Any]] = []
            var size = 0
            while index < pending.count, batch.count < 20, size < 20_000_000 {
                let it = pending[index]
                batch.append([
                    "key": it.hash,
                    "value": it.file.data.base64EncodedString(),
                    "metadata": ["contentType": Self.mime(it.file.path)],
                    "base64": true
                ])
                size += it.file.data.count
                index += 1
            }
            _ = try await post("pages/assets/upload", jwt: jwt, json: batch)
            log("已上传 \(index)/\(pending.count)")
        }

        _ = try await post("pages/assets/upsert-hashes", jwt: jwt, json: ["hashes": allHashes])

        // 5. 提交部署
        var manifest: [String: String] = [:]
        for it in items { manifest[it.file.path] = it.hash }
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        let (body, contentType) = buildMultipart([
            MultipartPart(name: "manifest", filename: nil, contentType: "", data: manifestData),
            MultipartPart(name: "branch", filename: nil, contentType: "", data: Data("main".utf8))
        ])
        log("创建部署…")
        let dep: PagesDeployment = try await ctx.c.request(
            "POST", "accounts/\(acc)/pages/projects/\(project)/deployments",
            body: body, contentType: contentType)
        return dep.url ?? "https://\(project).pages.dev"
    }

    /// 使用上传 JWT 调用 pages/assets/*
    private func post(_ path: String, jwt: String, json: Any) async throws -> JSONValue? {
        let body = try JSONSerialization.data(withJSONObject: json)
        let data = try await ctx.c.raw("POST", path, body: body, contentType: "application/json", bearer: jwt)
        let env = try JSONDecoder().decode(CFEnvelope<JSONValue>.self, from: data)
        if !env.success { throw CFClientError.message(env.errors?.first?.message ?? "上传失败") }
        return env.result
    }

    /// 文件内容哈希（取 32 位十六进制）。
    /// 注意：wrangler 使用的是 BLAKE3；这里用 SHA-256，只作为内容寻址的键。
    /// 如果服务端校验哈希导致上传报错，需要改成 BLAKE3 实现。
    static func hash(_ f: DeployFile) -> String {
        let ext = (f.path as NSString).pathExtension
        let input = Data((f.data.base64EncodedString() + ext).utf8)
        let hex = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32))
    }

    static func mime(_ path: String) -> String {
        let ext = (path as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}

// MARK: - 界面

struct PagesDeployView: View {
    enum Source: String, CaseIterable, Identifiable {
        case helloWorld = "Start with Hello World!"
        case picked = "选择文件或文件夹"
        var id: String { rawValue }
    }

    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss

    @State var projectName: String
    let fixedProject: Bool
    let onDone: () -> Void

    @State private var source: Source = .helloWorld
    @State private var picked: [DeployFile] = []
    @State private var showPicker = false
    @State private var running = false
    @State private var logLines: [String] = []
    @State private var resultURL: String?
    @State private var error: String?

    private var cleanName: String {
        projectName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    private var canRun: Bool {
        !running && !cleanName.isEmpty && (source == .helloWorld || !picked.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text(fixedProject ? "" : "只能包含小写字母、数字和连字符。项目不存在时会自动创建。")) {
                    if fixedProject {
                        LabeledContent("项目", value: projectName)
                    } else {
                        TextField("项目名称，例如 my-site", text: $projectName)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }

                Section("部署内容") {
                    Picker("来源", selection: $source) {
                        ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if source == .picked {
                        Button { showPicker = true } label: {
                            Label(picked.isEmpty ? "选择…" : "已选 \(picked.count) 个文件，点此重选",
                                  systemImage: "folder")
                        }
                        if !picked.isEmpty {
                            let hasIndex = picked.contains { $0.path == "/index.html" }
                            if !hasIndex {
                                Text("没有找到根目录的 index.html，访问首页会是 404。")
                                    .font(.caption).foregroundColor(.orange)
                            }
                        }
                    } else {
                        Text("会部署一个只有 “Hello World!” 的 index.html，适合先测试流程。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }

                Section {
                    Button {
                        Task { await run() }
                    } label: {
                        HStack {
                            Spacer()
                            if running { ProgressView() } else { Text("开始部署").bold() }
                            Spacer()
                        }
                    }
                    .disabled(!canRun)
                }

                if !logLines.isEmpty {
                    Section("进度") {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { _, l in
                            Text(l).font(.caption)
                        }
                    }
                }

                if let url = resultURL, let link = URL(string: url) {
                    Section("部署成功") {
                        Link(url, destination: link)
                        Text("首次部署后域名可能需要几十秒才生效。").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("部署 Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(resultURL == nil ? "取消" : "完成") { dismiss() } }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder, .item],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task {
                        picked = await Task.detached { Self.collect(urls) }.value
                    }
                } else if case .failure(let e) = result {
                    error = e.localizedDescription
                }
            }
            .errorAlert($error)
        }
    }

    private func run() async {
        running = true
        logLines = []
        resultURL = nil
        defer { running = false }

        let files: [DeployFile] = source == .helloWorld
            ? [DeployFile(path: "/index.html", data: Data(PagesTemplates.helloWorld.utf8))]
            : picked
        let deployer = PagesDeployer(ctx: session.ctx) { msg in
            Task { @MainActor in logLines.append(msg) }
        }
        do {
            let url = try await deployer.deploy(project: cleanName, files: files)
            resultURL = url
            logLines.append("完成")
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 读取所选文件 / 文件夹（文件夹会递归，路径相对于所选文件夹）
    nonisolated static func collect(_ urls: [URL]) -> [DeployFile] {
        var out: [DeployFile] = []
        let fm = FileManager.default
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                let base = url.resolvingSymlinksInPath().path
                guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { continue }
                for case let f as URL in en {
                    guard (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                          let d = try? Data(contentsOf: f) else { continue }
                    var rel = f.resolvingSymlinksInPath().path
                    if rel.hasPrefix(base) { rel.removeFirst(base.count) }
                    if !rel.hasPrefix("/") { rel = "/" + rel }
                    out.append(DeployFile(path: rel, data: d))
                }
            } else if let d = try? Data(contentsOf: url) {
                out.append(DeployFile(path: "/" + url.lastPathComponent, data: d))
            }
        }
        return out
    }
}
