import SwiftUI

// MARK: - JSON

extension JSONValue {
    var string: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d):
            if d.rounded() == d, abs(d) < Double(Int.max) { return String(Int(d)) }
            return String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var object: [String: JSONValue] { if case .object(let o) = self { return o }; return [:] }
    var isNull: Bool { if case .null = self { return true }; return false }
}

func jsonToAny(_ v: JSONValue) -> Any {
    switch v {
    case .null: return NSNull()
    case .bool(let b): return b
    case .int(let i): return i
    case .double(let d): return d
    case .string(let s): return s
    case .array(let a): return a.map { jsonToAny($0) }
    case .object(let o):
        var d: [String: Any] = [:]
        for (k, val) in o { d[k] = jsonToAny(val) }
        return d
    }
}

func jsonObject(_ v: JSONValue) -> [String: Any] {
    (jsonToAny(v) as? [String: Any]) ?? [:]
}

func jsonBody(_ obj: Any) throws -> Data {
    guard JSONSerialization.isValidJSONObject(obj),
          let data = try? JSONSerialization.data(withJSONObject: obj) else {
        throw CFClientError.message("无法编码请求")
    }
    return data
}

func jsonPretty(_ v: JSONValue) -> String {
    let obj = jsonToAny(v)
    guard JSONSerialization.isValidJSONObject(obj) || obj is NSNull,
          let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
          let s = String(data: data, encoding: .utf8) else {
        return v.description
    }
    return s
}

func jsonItems(_ v: JSONValue) -> [JSONValue] {
    switch v {
    case .array(let a):
        return a
    case .object(let o):
        let preferred = ["images", "buckets", "queues", "result", "domains", "indexes", "configs",
                         "models", "widgets", "policies", "liveInputs", "apps", "objects", "videos",
                         "certificates", "lists", "rules"]
        for key in preferred {
            if let child = o[key], case .array(let a) = child { return a }
        }
        for (_, child) in o {
            if case .array(let a) = child, !a.isEmpty { return a }
        }
        if o.isEmpty { return [] }
        return [v]
    default:
        return []
    }
}

func jsonTitle(_ v: JSONValue) -> String {
    let keys = ["name", "title", "queue_name", "hostname", "domain", "email", "filename",
                "sitekey", "key", "uid", "id", "description"]
    for key in keys {
        if let s = v[key]?.string, !s.isEmpty { return s }
    }
    if let n = v["meta"]?["name"]?.string, !n.isEmpty { return n }
    if let host = v["hosts"]?.array.first?.string, !host.isEmpty { return host }
    return "条目"
}

func jsonSubtitle(_ v: JSONValue) -> String {
    var parts: [String] = []
    let keys = ["status", "state", "mode", "email", "phase", "type", "kind", "description",
                "hostname", "domain", "expires_at", "created_on", "uploaded", "action"]
    for key in keys {
        if let s = v[key]?.string, !s.isEmpty {
            parts.append(s)
        } else if let t = v[key]?.object["type"]?.string ?? v[key]?.object["name"]?.string, !t.isEmpty {
            parts.append(t)
        }
        if parts.count == 3 { break }
    }
    if let n = v["size"]?.number, n > 0 {
        parts.append(cfByteCount(Int64(n)))
    }
    return parts.joined(separator: " · ")
}

func cfEncode(_ s: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

func cfByteCount(_ n: Int64) -> String {
    let v = Double(n)
    if v < 1000 { return String(format: "%.0f B", v) }
    if v < 1_000_000 { return String(format: "%.1f kB", v / 1000) }
    if v < 1_000_000_000 { return String(format: "%.2f MB", v / 1_000_000) }
    return String(format: "%.2f GB", v / 1_000_000_000)
}

// MARK: - Client helpers

struct CFPage: Decodable {
    struct Err: Decodable { let message: String? }
    struct Info: Decodable {
        let cursor: String?
        let is_truncated: Bool?
        let total_count: Int?
    }
    let success: Bool
    let errors: [Err]?
    let result: JSONValue?
    let result_info: Info?
}

extension CFClient {
    func resultValue(_ method: String = "GET", _ path: String,
                     query: [String: String] = [:], body: Data? = nil) async throws -> JSONValue {
        let data = try await raw(method, path, query: query, body: body,
                                 contentType: body == nil ? nil : "application/json")
        if data.isEmpty { return .null }
        if let page = try? JSONDecoder().decode(CFPage.self, from: data) {
            if !page.success {
                throw CFClientError.message(page.errors?.compactMap(\.message).first ?? "请求失败")
            }
            return page.result ?? .null
        }
        if let v = try? JSONDecoder().decode(JSONValue.self, from: data) { return v }
        throw CFClientError.message("无法解析响应")
    }

    func deleteLoose(_ path: String) async throws {
        let data = try await raw("DELETE", path)
        if data.isEmpty { return }
        if let page = try? JSONDecoder().decode(CFPage.self, from: data), !page.success {
            throw CFClientError.message(page.errors?.compactMap(\.message).first ?? "删除失败")
        }
    }
}

struct JSONRow: Identifiable {
    let id: String
    let value: JSONValue
    let title: String
    let subtitle: String
}

// MARK: - Detail / share / name sheet

struct JSONDetailView: View {
    let title: String
    let value: JSONValue

    private var scalars: [(String, String)] {
        value.object.keys.sorted().compactMap { key in
            guard let text = value[key]?.string else { return nil }
            return (key, text)
        }
    }

    var body: some View {
        List {
            if !scalars.isEmpty {
                Section("字段") {
                    ForEach(scalars, id: \.0) { row in
                        LabeledContent(row.0) {
                            Text(row.1).font(.footnote).textSelection(.enabled).multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            Section("原始 JSON") {
                Text(jsonPretty(value))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("复制") { UIPasteboard.general.string = jsonPretty(value) }
            }
        }
    }
}

struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityShare: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {
        if let pop = vc.popoverPresentationController {
            pop.sourceView = vc.view
            let bounds = vc.view.bounds
            pop.sourceRect = CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
    }
}

struct NameCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var placeholder: String = "名称"
    var confirm: String = "创建"
    let action: (String) async throws -> Void
    var onDone: () -> Void = {}

    @State private var name = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField(placeholder, text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let error {
                    Text(error).font(.footnote).foregroundColor(.red)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirm) { Task { await go() } }
                        .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func go() async {
        busy = true
        defer { busy = false }
        do {
            try await action(name.trimmingCharacters(in: .whitespacesAndNewlines))
            onDone()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
