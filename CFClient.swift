import Foundation
import Security

// MARK: - JSON helper

enum JSONValue: Codable, CustomStringConvertible {
    case null, bool(Bool), int(Int), double(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var description: String {
        switch self {
        case .null: return "NULL"
        case .bool(let v): return String(v)
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .string(let v): return v
        case .array(let v): return "[" + v.map(\.description).joined(separator: ", ") + "]"
        case .object(let v): return "{" + v.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "}"
        }
    }
}

// MARK: - Credentials

struct Credentials: Codable {
    enum Mode: String, Codable { case token, globalKey }
    var mode: Mode
    var token: String = ""
    var email: String = ""
    var globalKey: String = ""

    private static let keychainKey = "cf.credentials"

    static func load() -> Credentials? {
        guard let data = Keychain.get(keychainKey) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { Keychain.set(data, key: Self.keychainKey) }
    }
    static func clear() { Keychain.delete(keychainKey) }
}

enum Keychain {
    static func set(_ data: Data, key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        var a = q
        a[kSecValueData as String] = data
        if SecItemAdd(a as CFDictionary, nil) != errSecSuccess {
            UserDefaults.standard.set(data, forKey: key)   // 侧载环境 Keychain 不可用时兜底
        }
    }
    static func get(_ key: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data { return d }
        return UserDefaults.standard.data(forKey: key)
    }
    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Client

struct CFError: Decodable { let code: Int?; let message: String }
struct CFEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let errors: [CFError]?
    let result: T?
}

enum CFClientError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

final class CFClient {
    let creds: Credentials
    private let base = URL(string: "https://api.cloudflare.com/client/v4/")!
    private let session: URLSession

    init(_ creds: Credentials) {
        self.creds = creds
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg)
    }

    private func makeRequest(_ method: String, _ path: String, query: [String: String],
                             body: Data?, contentType: String?) -> URLRequest {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        switch creds.mode {
        case .token:
            req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        case .globalKey:
            req.setValue(creds.email, forHTTPHeaderField: "X-Auth-Email")
            req.setValue(creds.globalKey, forHTTPHeaderField: "X-Auth-Key")
        }
        if let body {
            req.httpBody = body
            req.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    /// 返回原始响应体（脚本内容、KV 值等非 JSON 响应）
    func raw(_ method: String = "GET", _ path: String, query: [String: String] = [:],
             body: Data? = nil, contentType: String? = nil) async throws -> Data {
        let req = makeRequest(method, path, query: query, body: body, contentType: contentType)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if let env = try? JSONDecoder().decode(CFEnvelope<JSONValue>.self, from: data),
               let msg = env.errors?.first?.message {
                throw CFClientError.message(msg)
            }
            throw CFClientError.message("HTTP \(http.statusCode)")
        }
        return data
    }

    func request<T: Decodable>(_ method: String = "GET", _ path: String, query: [String: String] = [:],
                               body: Data? = nil, contentType: String? = nil) async throws -> T {
        let data = try await raw(method, path, query: query, body: body, contentType: contentType)
        let env = try JSONDecoder().decode(CFEnvelope<T>.self, from: data)
        if !env.success {
            throw CFClientError.message(env.errors?.first?.message ?? "请求失败")
        }
        if let r = env.result { return r }
        if let empty = JSONValue.null as? T { return empty }
        throw CFClientError.message("响应为空")
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await request("GET", path, query: query)
    }

    @discardableResult
    func send<B: Encodable>(_ method: String, _ path: String, json: B,
                            query: [String: String] = [:]) async throws -> JSONValue {
        let body = try JSONEncoder().encode(json)
        return try await request(method, path, query: query, body: body)
    }

    func delete(_ path: String, query: [String: String] = [:]) async throws {
        let _: JSONValue = try await request("DELETE", path, query: query)
    }
}

// MARK: - Multipart

struct MultipartPart {
    var name: String
    var filename: String?
    var contentType: String
    var data: Data
}

func buildMultipart(_ parts: [MultipartPart]) -> (body: Data, contentType: String) {
    let boundary = "Boundary-\(UUID().uuidString)"
    var body = Data()
    for p in parts {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        var disp = "Content-Disposition: form-data; name=\"\(p.name)\""
        if let f = p.filename { disp += "; filename=\"\(f)\"" }
        body.append("\(disp)\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(p.contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(p.data)
        body.append("\r\n".data(using: .utf8)!)
    }
    body.append("--\(boundary)--\r\n".data(using: .utf8)!)
    return (body, "multipart/form-data; boundary=\(boundary)")
}

// MARK: - Session

struct Account: Codable, Identifiable, Hashable { let id: String; let name: String }

@MainActor
final class Session: ObservableObject {
    @Published var client: CFClient?
    @Published var accounts: [Account] = []
    @Published var accountId: String = ""

    init() {
        if let c = Credentials.load() {
            let cl = CFClient(c)
            client = cl
            Task { await refreshAccounts(cl) }
        }
    }

    private func refreshAccounts(_ cl: CFClient) async {
        if let accs: [Account] = try? await cl.get("accounts"), let first = accs.first {
            accounts = accs
            if accountId.isEmpty || !accs.contains(where: { $0.id == accountId }) { accountId = first.id }
        }
    }

    func login(_ creds: Credentials) async throws {
        let cl = CFClient(creds)
        let accs: [Account] = try await cl.get("accounts")
        guard let first = accs.first else { throw CFClientError.message("该凭据下没有可访问的账户") }
        creds.save()
        accounts = accs
        accountId = first.id
        client = cl
    }

    func logout() {
        Credentials.clear()
        client = nil
        accounts = []
        accountId = ""
    }
}
