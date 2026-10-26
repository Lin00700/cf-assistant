import SwiftUI
import Foundation
import Darwin
import NetworkExtension

struct ConnectivityProbeResult: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case dnsA
        case dnsAAAA
        case ipv4
        case ipv6
        case http

        var title: String {
            switch self {
            case .dnsA: return "DNS · A 记录"
            case .dnsAAAA: return "DNS · AAAA 记录"
            case .ipv4: return "IPv4 HTTPS"
            case .ipv6: return "IPv6 HTTPS"
            case .http: return "HTTP · Cloudflare"
            }
        }
    }

    let id: UUID
    let kind: Kind
    let success: Bool
    let elapsedMilliseconds: Int
    let detail: String

    init(kind: Kind, success: Bool, elapsedMilliseconds: Int, detail: String) {
        self.id = UUID()
        self.kind = kind
        self.success = success
        self.elapsedMilliseconds = elapsedMilliseconds
        self.detail = detail
    }
}

struct ConnectivityDiagnosticRun: Codable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    let vpnStatus: String
    let vpnInterrupted: Bool
    let nodeProtocol: String
    let results: [ConnectivityProbeResult]

    init(startedAt: Date, vpnStatus: String, vpnInterrupted: Bool, nodeProtocol: String, results: [ConnectivityProbeResult]) {
        self.id = UUID()
        self.startedAt = startedAt
        self.vpnStatus = vpnStatus
        self.vpnInterrupted = vpnInterrupted
        self.nodeProtocol = nodeProtocol
        self.results = results
    }

    var passedCount: Int { results.filter(\.success).count }

    var shareText: String {
        let date = startedAt.formatted(date: .numeric, time: .standard)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知"
        let lines = results.map { result in
            let mark = result.success ? "通过" : "失败"
            return "\(mark) | \(result.kind.title) | \(result.elapsedMilliseconds) ms | \(result.detail)"
        }
        return ([
            "CF 助手连接诊断报告",
            "时间：\(date)",
            "VPN：\(vpnStatus)",
            vpnInterrupted ? "警告：诊断期间检测到 VPN 状态变化，部分请求可能未通过 VPN。" : nil,
            "节点协议：\(nodeProtocol)",
            "App 版本：\(version) (\(build))",
            "结果：\(passedCount)/\(results.count) 项通过",
            "",
            "\(lines.joined(separator: "\n"))",
            "",
            "说明：测试通过当前系统网络路径及分流规则发起；NAT64 或代理可能转换地址族，公网出口 IP 可能包含在结果中。"
        ].compactMap { $0 }).joined(separator: "\n")
    }
}

@MainActor
final class ConnectivityDiagnosticsModel: ObservableObject {
    @Published private(set) var runs: [ConnectivityDiagnosticRun]
    @Published private(set) var isRunning = false
    private var vpnInterrupted = false

    private let storageKey = "connectivityDiagnostics.runs.v1"
    private let maxSavedRuns = 10

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([ConnectivityDiagnosticRun].self, from: data) {
            runs = saved
        } else {
            runs = []
        }
    }

    func run(vpnStatus: String, nodeProtocol: String) async {
        guard !isRunning else { return }
        isRunning = true
        vpnInterrupted = false
        defer { isRunning = false }

        let startedAt = Date()
        let results = await withTaskGroup(of: ConnectivityProbeResult.self) { group in
            group.addTask { await ConnectivityDiagnosticsModel.resolve(kind: .dnsA, family: AF_INET) }
            group.addTask { await ConnectivityDiagnosticsModel.resolve(kind: .dnsAAAA, family: AF_INET6) }
            group.addTask { await ConnectivityDiagnosticsModel.fetch(kind: .ipv4, url: "https://ipv4.icanhazip.com/") }
            group.addTask { await ConnectivityDiagnosticsModel.fetch(kind: .ipv6, url: "https://ipv6.icanhazip.com/") }
            group.addTask { await ConnectivityDiagnosticsModel.fetch(kind: .http, url: "https://www.cloudflare.com/cdn-cgi/trace") }

            var completed: [ConnectivityProbeResult] = []
            for await result in group { completed.append(result) }
            return completed.sorted { $0.kind.rawValue < $1.kind.rawValue }
        }

        let run = ConnectivityDiagnosticRun(
            startedAt: startedAt,
            vpnStatus: vpnStatus,
            vpnInterrupted: vpnInterrupted,
            nodeProtocol: nodeProtocol,
            results: results
        )
        runs.insert(run, at: 0)
        if runs.count > maxSavedRuns { runs = Array(runs.prefix(maxSavedRuns)) }
        save()
    }

    func clearHistory() {
        runs = []
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    func noteVPNInterruption() {
        if isRunning { vpnInterrupted = true }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(runs) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private nonisolated static func resolve(kind: ConnectivityProbeResult.Kind, family: Int32) async -> ConnectivityProbeResult {
        let start = DispatchTime.now().uptimeNanoseconds
        let addresses = await Task.detached(priority: .utility) {
            Self.resolveAddresses(host: "cloudflare.com", family: family)
        }.value
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        guard !addresses.isEmpty else {
            let familyName = kind == .dnsA ? "IPv4 A" : "IPv6 AAAA"
            return ConnectivityProbeResult(
                kind: kind,
                success: false,
                elapsedMilliseconds: elapsed,
                detail: "cloudflare.com 未返回 \(familyName) 地址；可能是 DNS 解析失败或该地址族不可用"
            )
        }
        return ConnectivityProbeResult(
            kind: kind,
            success: true,
            elapsedMilliseconds: elapsed,
            detail: "cloudflare.com 解析到 \(addresses.count) 个地址（示例：\(addresses.prefix(2).joined(separator: ", ")))"
        )
    }

    private nonisolated static func resolveAddresses(host: String, family: Int32) -> [String] {
        var hints = addrinfo()
        hints.ai_family = family
        hints.ai_socktype = Int32(SOCK_STREAM)
        var resolved: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(host, nil, &hints, &resolved)
        guard code == 0, let first = resolved else { return [] }
        defer { freeaddrinfo(resolved) }

        var addresses: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let item = current {
            var buffer = [CChar](repeating: 0, count: 128)
            if getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen,
                           &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let address = String(cString: buffer)
                if !addresses.contains(address) { addresses.append(address) }
            }
            current = item.pointee.ai_next
        }
        return addresses
    }

    private nonisolated static func fetch(kind: ConnectivityProbeResult.Kind, url urlText: String) async -> ConnectivityProbeResult {
        let start = DispatchTime.now().uptimeNanoseconds
        guard let url = URL(string: urlText) else {
            return ConnectivityProbeResult(kind: kind, success: false, elapsedMilliseconds: 0, detail: "测试地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("CF-Assistant-Connectivity-Diagnostic/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 15
            configuration.waitsForConnectivity = false
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            guard let http = response as? HTTPURLResponse else {
                return ConnectivityProbeResult(kind: kind, success: false, elapsedMilliseconds: elapsed, detail: "未收到有效 HTTP 响应")
            }
            let body = String(data: data.prefix(4096), encoding: .utf8) ?? ""
            let detail: String
            if kind == .http {
                let fields = body.components(separatedBy: .newlines)
                let colo = fields.first(where: { $0.hasPrefix("colo=") })?.dropFirst(5)
                let egressIP = fields.first(where: { $0.hasPrefix("ip=") })?.dropFirst(3)
                var parts = ["HTTP \(http.statusCode)"]
                if let colo, !colo.isEmpty { parts.append("Colo \(colo)") }
                if let egressIP, !egressIP.isEmpty { parts.append("出口 IP \(egressIP)") }
                detail = parts.joined(separator: " · ")
            } else {
                let observedIP = body.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .newlines).first ?? ""
                detail = observedIP.isEmpty
                    ? "HTTP \(http.statusCode) · \(url.host ?? "")"
                    : "HTTP \(http.statusCode) · 出口 IP \(observedIP)"
            }
            return ConnectivityProbeResult(
                kind: kind,
                success: (200..<300).contains(http.statusCode),
                elapsedMilliseconds: elapsed,
                detail: detail
            )
        } catch {
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            return ConnectivityProbeResult(
                kind: kind,
                success: false,
                elapsedMilliseconds: elapsed,
                detail: "\(url.host ?? "") · \(error.localizedDescription)"
            )
        }
    }
}

struct ConnectivityDiagnosticsView: View {
    @ObservedObject private var vpn = VPNManager.shared
    @StateObject private var model = ConnectivityDiagnosticsModel()
    @State private var showingClearConfirmation = false

    var body: some View {
        List {
            Section {
                HStack {
                    Label("内置 VPN", systemImage: vpn.isConnected ? "checkmark.shield.fill" : "xmark.shield")
                    Spacer()
                    Text(vpn.statusText).foregroundColor(vpn.isConnected ? .green : .secondary)
                }
                Button {
                    Task { await model.run(vpnStatus: vpn.statusText, nodeProtocol: ProxyStore.shared.selected?.proto.uppercased() ?? "未知") }
                } label: {
                    HStack {
                        Spacer()
                        if model.isRunning {
                            ProgressView("诊断中…")
                        } else {
                            Label("开始连接诊断", systemImage: "stethoscope")
                        }
                        Spacer()
                    }
                }
                .disabled(!vpn.isConnected || model.isRunning)
            } footer: {
                Text(vpn.isConnected
                     ? "按当前系统网络路径和分流规则测试 DNS A/AAAA、IPv4/IPv6 HTTPS 和 Cloudflare HTTP。"
                     : "请先在“VPN 与节点”页连接内置 VPN，再运行诊断。")
            }

            if !model.runs.isEmpty {
                Section {
                    Button("清空诊断历史", role: .destructive) { showingClearConfirmation = true }
                }
            }

            ForEach(model.runs) { run in
                Section {
                    ForEach(run.results) { result in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.success ? .green : .red)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(result.kind.title).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("\(result.elapsedMilliseconds) ms")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text(result.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    ShareLink(item: run.shareText, subject: Text("CF 助手连接诊断报告")) {
                        Label("分享此报告", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    HStack {
                        Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                        Spacer()
                        Text("\(run.passedCount)/\(run.results.count) 项通过")
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("VPN：\(run.vpnStatus) · 节点协议：\(run.nodeProtocol)")
                        if run.vpnInterrupted {
                            Label("诊断期间检测到 VPN 状态变化，结果可能混合直连流量", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        }
                    }
                }
            }

            Section {
                Text("报告保存在本机，最多保留最近 10 次。分享内容包括测试结果和观测到的公网出口 IP；请先预览并确认后再发送。分流规则可能令个别探测直连，NAT64 或代理节点也可能转换地址族。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("连接诊断")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vpn.load() }
        .onChange(of: vpn.status) { status in
            if status != .connected { model.noteVPNInterruption() }
        }
        .confirmationDialog("清空诊断历史？", isPresented: $showingClearConfirmation, titleVisibility: .visible) {
            Button("清空", role: .destructive) { model.clearHistory() }
            Button("取消", role: .cancel) {}
        }
    }
}
