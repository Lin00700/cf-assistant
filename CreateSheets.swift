import SwiftUI

struct CreateRouter: View {
    @EnvironmentObject var session: Session
    let source: RemoteSource
    var onCreated: () -> Void

    var body: some View {
        switch source.createKind {
        case .none:
            EmptyView()
        case .name:
            NameCreateSheet(title: "新建\(source.title)", placeholder: "名称", action: { name in
                try await source.createNamed(session.ctx, name)
            }, onDone: onCreated)
        case .vectorize:
            VectorizeCreateSheet(onCreated: onCreated)
        case .hyperdrive:
            HyperdriveCreateSheet(onCreated: onCreated)
        case .turnstile:
            TurnstileCreateSheet(onCreated: onCreated)
        case .accessApp:
            AccessAppCreateSheet(onCreated: onCreated)
        case .originCA:
            OriginCACreateSheet(zoneID: source.zoneID ?? "", onCreated: onCreated)
        }
    }
}

struct VectorizeCreateSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    var onCreated: () -> Void
    @State private var name = ""
    @State private var dimensions = 768
    @State private var metric = "cosine"
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("索引名称", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                Stepper("维度 \(dimensions)", value: $dimensions, in: 1...1536)
                Picker("度量", selection: $metric) {
                    Text("cosine").tag("cosine")
                    Text("euclidean").tag("euclidean")
                    Text("dot-product").tag("dot-product")
                }
                if let error { Text(error).font(.footnote).foregroundColor(.red) }
            }
            .navigationTitle("新建 Vectorize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { Task { await go() } }.disabled(busy || name.isEmpty)
                }
            }
        }
    }

    private func go() async {
        busy = true
        defer { busy = false }
        let ctx = session.ctx
        let body: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "config": ["dimensions": dimensions, "metric": metric]
        ]
        do {
            _ = try await ctx.c.resultValue("POST", "accounts/\(ctx.acc)/vectorize/v2/indexes", body: try jsonBody(body))
            onCreated(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct HyperdriveCreateSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    var onCreated: () -> Void
    @State private var name = ""
    @State private var host = ""
    @State private var port = "5432"
    @State private var database = ""
    @State private var user = ""
    @State private var password = ""
    @State private var scheme = "postgres"
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("配置名称", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("类型", selection: $scheme) {
                    Text("PostgreSQL").tag("postgres")
                    Text("MySQL").tag("mysql")
                }
                TextField("主机", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("端口", text: $port).keyboardType(.numberPad)
                TextField("数据库", text: $database).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("用户", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("密码", text: $password)
                if let error { Text(error).font(.footnote).foregroundColor(.red) }
            }
            .navigationTitle("新建 Hyperdrive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { Task { await go() } }
                        .disabled(busy || name.isEmpty || host.isEmpty || database.isEmpty)
                }
            }
        }
    }

    private func go() async {
        busy = true
        defer { busy = false }
        let ctx = session.ctx
        let origin: [String: Any] = [
            "database": database.trimmingCharacters(in: .whitespacesAndNewlines),
            "host": host.trimmingCharacters(in: .whitespacesAndNewlines),
            "port": Int(port) ?? 5432,
            "scheme": scheme,
            "user": user,
            "password": password
        ]
        let body: [String: Any] = ["name": name.trimmingCharacters(in: .whitespacesAndNewlines), "origin": origin]
        do {
            _ = try await ctx.c.resultValue("POST", "accounts/\(ctx.acc)/hyperdrive/configs", body: try jsonBody(body))
            onCreated(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct TurnstileCreateSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    var onCreated: () -> Void
    @State private var name = ""
    @State private var domains = ""
    @State private var mode = "managed"
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("站点名称", text: $name)
                TextField("域名，逗号分隔", text: $domains)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("模式", selection: $mode) {
                    Text("托管").tag("managed")
                    Text("非交互").tag("non-interactive")
                    Text("隐形").tag("invisible")
                }
                if let error { Text(error).font(.footnote).foregroundColor(.red) }
            }
            .navigationTitle("新建 Turnstile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { Task { await go() } }.disabled(busy || name.isEmpty || domains.isEmpty)
                }
            }
        }
    }

    private func go() async {
        busy = true
        defer { busy = false }
        let list = domains.split { $0 == "," || $0 == " " || $0 == "\n" }
            .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let body: [String: Any] = ["name": name, "domains": list, "mode": mode]
        do {
            _ = try await session.ctx.c.resultValue(
                "POST", "accounts/\(session.ctx.acc)/challenges/widgets", body: try jsonBody(body))
            onCreated(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct AccessAppCreateSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    var onCreated: () -> Void
    @State private var name = ""
    @State private var domain = ""
    @State private var sessionHours = "24h"
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("应用名称", text: $name)
                TextField("域名，例如 app.example.com", text: $domain)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("会话时长", text: $sessionHours).textInputAutocapitalization(.never)
                Text("自托管应用。更复杂的策略请在创建后于详情中核对，或到 Zero Trust 控制台补充。")
                    .font(.footnote).foregroundColor(.secondary)
                if let error { Text(error).font(.footnote).foregroundColor(.red) }
            }
            .navigationTitle("新建 Access 应用")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { Task { await go() } }.disabled(busy || name.isEmpty || domain.isEmpty)
                }
            }
        }
    }

    private func go() async {
        busy = true
        defer { busy = false }
        let body: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "domain": domain.trimmingCharacters(in: .whitespacesAndNewlines),
            "type": "self_hosted",
            "session_duration": sessionHours.trimmingCharacters(in: .whitespacesAndNewlines),
            "auto_redirect_to_identity": false
        ]
        do {
            _ = try await session.ctx.c.resultValue(
                "POST", "accounts/\(session.ctx.acc)/access/apps", body: try jsonBody(body))
            onCreated(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct OriginCACreateSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let zoneID: String
    var onCreated: () -> Void
    @State private var hosts = ""
    @State private var csr = ""
    @State private var days = 365
    @State private var busy = false
    @State private var error: String?
    @State private var certificate: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("主机名，逗号分隔", text: $hosts)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("有效期", selection: $days) {
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                    Text("365 天").tag(365)
                    Text("5475 天").tag(5475)
                }
                TextEditor(text: $csr)
                    .frame(minHeight: 140)
                    .font(.system(.footnote, design: .monospaced))
                Text("把 CSR PEM 粘贴到上面。证书签发后只在这里完整显示一次。")
                    .font(.footnote).foregroundColor(.secondary)
                if let error { Text(error).font(.footnote).foregroundColor(.red) }
            }
            .navigationTitle("签发 Origin CA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("签发") { Task { await go() } }.disabled(busy || hosts.isEmpty || csr.isEmpty)
                }
            }
            .alert("证书 PEM", isPresented: Binding(get: { certificate != nil }, set: { if !$0 { certificate = nil; dismiss() } })) {
                Button("复制") { UIPasteboard.general.string = certificate }
                Button("好") { certificate = nil; onCreated(); dismiss() }
            } message: {
                Text(certificate ?? "")
            }
        }
    }

    private func go() async {
        busy = true
        defer { busy = false }
        let list = hosts.split { $0 == "," || $0 == " " || $0 == "\n" }
            .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let body: [String: Any] = [
            "hostnames": list,
            "requested_validity": days,
            "request_type": "origin-rsa",
            "csr": csr.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        do {
            let v = try await session.ctx.c.resultValue("POST", "certificates", body: try jsonBody(body))
            certificate = v["certificate"]?.string ?? jsonPretty(v)
            onCreated()
        } catch { self.error = error.localizedDescription }
    }
}
