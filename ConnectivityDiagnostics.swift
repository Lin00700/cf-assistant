import SwiftUI
import Foundation
import Darwin
import NetworkExtension
import Network

struct ConnectivityProbeResult: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case dnsA
        case dnsAAAA
        case singBoxDNS
        case lanTCP
        case nodeTCP
        case proxyHTTPS
        case tunnelIPTCP
        case ipv4
        case ipv6
        case http

        var title: String {
            switch self {
            case .dnsA: return "DNS · A 记录"
            case .dnsAAAA: return "DNS · AAAA 记录"
            case .singBoxDNS: return "sing-box DNS · cloudflare.com"
            case .lanTCP: return "局域网 TCP · 手动目标"
            case .nodeTCP: return "节点 TCP · 地址/端口"
            case .proxyHTTPS: return "代理 HTTPS · 指定节点"
            case .tunnelIPTCP: return "Network.framework TCP · 1.1.1.1:443"
            case .ipv4: return "IPv4 HTTPS"
            case .ipv6: return "IPv6 HTTPS"
            case .http: return "HTTP · Cloudflare"
            }
        }

        var displayOrder: Int {
            switch self {
            case .dnsA: return 0
            case .dnsAAAA: return 1
            case .singBoxDNS: return 2
            case .lanTCP: return 3
            case .nodeTCP: return 4
            case .proxyHTTPS: return 5
            case .tunnelIPTCP: return 6
            case .ipv4: return 7
            case .ipv6: return 8
            case .http: return 9
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
            "说明：DNS A/AAAA 使用 iOS 系统解析器。sing-box DNS 由扩展进程直接问 sing-box 的 DNS 模块解析 cloudflare.com，不经过系统解析器：它成功而系统 DNS 失败说明劫持没接住；它也失败说明上游或直连不通。节点 TCP、局域网 TCP 和 1.1.1.1:443 使用 Network.framework；IPv4/IPv6 HTTPS 与 Cloudflare HTTP 使用 URLSession，但这些 API 的具体路由可能不同，不能据此断定普通应用流量是否经 TUN。它们不等同于“代理 HTTPS · 指定节点”：后者由 sing-box delay API 指定该节点访问 Cloudflare 探测 URL。该项成功只证明这一节点本次代理 HTTPS 出站成功，不保证系统 DNS、其他应用或局域网可用。若填写了内网目标，局域网 TCP 只测试该 RFC1918 地址和端口；未填写表示未测试，失败也只说明该目标/端口未连通。当前 sing-box 将 RFC1918 私有地址分流为 direct，但实际可达仍取决于本地网络路由、iOS 本地网络权限以及目标服务是否监听。分享前请检查是否要公开内网或节点 IP；公网出口 IP 可能包含在结果中。"
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

    func run(vpnStatus: String, nodeProtocol: String, node: ProxyNode?, lanIPv4: String, lanPort: String) async {
        guard !isRunning else { return }
        isRunning = true
        vpnInterrupted = false
        defer { isRunning = false }

        let startedAt = Date()
        let singBoxDNSTask = Task<ConnectivityProbeResult, Never> { @MainActor in
            let started = DispatchTime.now().uptimeNanoseconds
            guard VPNManager.shared.isConnected else {
                return ConnectivityProbeResult(kind: .singBoxDNS, success: false, elapsedMilliseconds: 0,
                                               detail: "VPN 未连接，未向扩展内的 sing-box DNS 查询 cloudflare.com")
            }
            let text = await VPNManager.shared.querySingBoxDNS()
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            if text.hasPrefix("OK ") {
                let rest = String(text.dropFirst(3))
                return ConnectivityProbeResult(
                    kind: .singBoxDNS,
                    success: true,
                    elapsedMilliseconds: elapsed,
                    detail: "扩展内 sing-box 直接解析 cloudflare.com 成功 · \(rest)。这条不经过系统 DNS"
                )
            }
            let rest = text.hasPrefix("FAIL ") ? String(text.dropFirst(5)) : text
            return ConnectivityProbeResult(
                kind: .singBoxDNS,
                success: false,
                elapsedMilliseconds: elapsed,
                detail: "扩展内 sing-box 直接解析 cloudflare.com 失败 · \(rest)。这条不经过系统 DNS，失败说明上游或直连不通"
            )
        }
        let proxyProbeTask = Task<ConnectivityProbeResult, Never> { @MainActor in
            let probeStartedAt = DispatchTime.now().uptimeNanoseconds
            guard let node else {
                return ConnectivityProbeResult(kind: .proxyHTTPS, success: false, elapsedMilliseconds: 0,
                                               detail: "没有可用的指定节点，未进行 sing-box HTTPS 代理探测")
            }
            guard VPNManager.shared.isConnected else {
                return ConnectivityProbeResult(kind: .proxyHTTPS, success: false, elapsedMilliseconds: 0,
                                               detail: "VPN 未连接，未进行 sing-box HTTPS 代理探测")
            }
            do {
                let measurement = try await VPNManager.shared.measureProxyEgress(node: node)
                let wallTime = Int((DispatchTime.now().uptimeNanoseconds - probeStartedAt) / 1_000_000)
                switch measurement {
                case .latency(let milliseconds):
                    return ConnectivityProbeResult(
                        kind: .proxyHTTPS,
                        success: true,
                        elapsedMilliseconds: milliseconds,
                        detail: "sing-box 经指定节点 \(node.server):\(node.port) 成功访问 Cloudflare HTTPS 探测 URL；只证明该节点本次代理出站成功"
                    )
                case .probeFailed:
                    return ConnectivityProbeResult(kind: .proxyHTTPS, success: false, elapsedMilliseconds: wallTime,
                                                   detail: "sing-box 未成功完成此节点的 Cloudflare HTTPS 探测；不能据此断言节点原始 TCP 端口不通")
                case .tcpLatency(let milliseconds):
                    return ConnectivityProbeResult(kind: .proxyHTTPS, success: false, elapsedMilliseconds: wallTime,
                                                   detail: "探测期间 VPN 状态变化，得到的是节点 TCP 端口延迟 \(milliseconds) ms，而非代理 HTTPS 结果")
                case .unreachable:
                    return ConnectivityProbeResult(kind: .proxyHTTPS, success: false, elapsedMilliseconds: wallTime,
                                                   detail: "指定节点 HTTPS 探测未成功；这不是节点原始 TCP 端口测试")
                case .requiresVPN:
                    return ConnectivityProbeResult(kind: .proxyHTTPS, success: false, elapsedMilliseconds: wallTime,
                                                   detail: "该节点协议需要 VPN 才能进行 HTTPS 代理探测")
                }
            } catch {
                let elapsed = Int((DispatchTime.now().uptimeNanoseconds - probeStartedAt) / 1_000_000)
                return ConnectivityProbeResult(kind: .proxyHTTPS, success: false, elapsedMilliseconds: elapsed,
                                               detail: "无法访问 sing-box 节点探测接口：\(error.localizedDescription)")
            }
        }
        let results = await withTaskGroup(of: ConnectivityProbeResult.self) { group in
            group.addTask { await ConnectivityDiagnosticsModel.resolve(kind: .dnsA, family: AF_INET) }
            group.addTask { await ConnectivityDiagnosticsModel.resolve(kind: .dnsAAAA, family: AF_INET6) }
            if !lanIPv4.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                group.addTask { await ConnectivityDiagnosticsModel.probeLANIPv4TCP(address: lanIPv4, portText: lanPort) }
            }
            group.addTask { await ConnectivityDiagnosticsModel.probeNodeTCP(node: node) }
            group.addTask { await ConnectivityDiagnosticsModel.probeTunnelIPTCP() }
            group.addTask { await ConnectivityDiagnosticsModel.fetch(kind: .ipv4, url: "https://ipv4.icanhazip.com/") }
            group.addTask { await ConnectivityDiagnosticsModel.fetch(kind: .ipv6, url: "https://ipv6.icanhazip.com/") }
            group.addTask { await ConnectivityDiagnosticsModel.fetch(kind: .http, url: "https://www.cloudflare.com/cdn-cgi/trace") }

            var completed: [ConnectivityProbeResult] = []
            for await result in group { completed.append(result) }
            completed.append(await singBoxDNSTask.value)
            completed.append(await proxyProbeTask.value)
            return completed.sorted { $0.kind.displayOrder < $1.kind.displayOrder }
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

    private nonisolated static func probeNodeTCP(node: ProxyNode?) async -> ConnectivityProbeResult {
        let start = DispatchTime.now().uptimeNanoseconds
        guard let node else {
            return ConnectivityProbeResult(kind: .nodeTCP, success: false, elapsedMilliseconds: 0,
                                            detail: "没有可用的当前节点，未测试节点端口")
        }
        guard (1...65535).contains(node.port) else {
            return ConnectivityProbeResult(kind: .nodeTCP, success: false, elapsedMilliseconds: 0,
                                            detail: "节点端口无效：\(node.port)")
        }

        let addresses: [String]
        if isValidIPAddress(node.server, family: AF_INET) || isValidIPAddress(node.server, family: AF_INET6) {
            addresses = [node.server]
        } else {
            addresses = await Task.detached(priority: .utility) {
                Self.resolveAddresses(host: node.server, family: AF_UNSPEC)
            }.value
        }
        let elapsed = { Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
        guard !addresses.isEmpty else {
            return ConnectivityProbeResult(kind: .nodeTCP, success: false, elapsedMilliseconds: elapsed(),
                                            detail: "节点域名 \(node.server) 未解析出 IP；节点端口未测到，请结合 DNS 结果判断")
        }

        var lastFailure = "连接失败"
        for address in addresses.prefix(2) {
            let outcome = await openTCP(host: address, port: node.port, timeout: 4)
            if outcome.success {
                return ConnectivityProbeResult(kind: .nodeTCP, success: true, elapsedMilliseconds: elapsed(),
                                                detail: "Network.framework 原始 TCP 连接成功 · \(address):\(node.port)")
            }
            lastFailure = "\(address):\(node.port) · \(outcome.detail)"
        }
        return ConnectivityProbeResult(kind: .nodeTCP, success: false, elapsedMilliseconds: elapsed(),
                                        detail: "Network.framework · 节点 TCP 连接失败 · \(lastFailure)")
    }

    private nonisolated static func probeLANIPv4TCP(address: String, portText: String) async -> ConnectivityProbeResult {
        let start = DispatchTime.now().uptimeNanoseconds
        let ip = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPrivateIPv4Address(ip) else {
            return ConnectivityProbeResult(kind: .lanTCP, success: false, elapsedMilliseconds: 0,
                                            detail: "请输入 RFC1918 私有 IPv4（10.x、172.16–31.x 或 192.168.x）；未连接目标")
        }
        guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) else {
            return ConnectivityProbeResult(kind: .lanTCP, success: false, elapsedMilliseconds: 0,
                                            detail: "内网 TCP 端口无效：请输入 1–65535")
        }
        let outcome = await openTCP(host: ip, port: port, timeout: 4)
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        return ConnectivityProbeResult(
            kind: .lanTCP,
            success: outcome.success,
            elapsedMilliseconds: elapsed,
            detail: outcome.success
                ? "Network.framework 原始 TCP 连接成功 · \(ip):\(port)"
                : "Network.framework · \(ip):\(port) TCP 连接失败 · \(outcome.detail)"
        )
    }

    private nonisolated static func probeTunnelIPTCP() async -> ConnectivityProbeResult {
        let start = DispatchTime.now().uptimeNanoseconds
        let outcome = await openTCP(host: "1.1.1.1", port: 443, timeout: 7)
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        return ConnectivityProbeResult(
            kind: .tunnelIPTCP,
            success: outcome.success,
            elapsedMilliseconds: elapsed,
            detail: outcome.success
                ? "Network.framework 原始 TCP 连接成功 · 1.1.1.1:443"
                : "Network.framework · 1.1.1.1:443 TCP 连接失败 · \(outcome.detail)"
        )
    }

    private nonisolated static func openTCP(host: String, port: Int, timeout: TimeInterval) async -> TCPConnectionOutcome {
        guard let rawPort = UInt16(exactly: port), let nwPort = NWEndpoint.Port(rawValue: rawPort) else {
            return TCPConnectionOutcome(success: false, detail: "端口无效")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await TCPProbeOperation(connection: connection).run(timeout: timeout)
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
            var success = (200..<300).contains(http.statusCode)
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
                let family = kind == .ipv4 ? AF_INET : AF_INET6
                let isExpectedAddress = Self.isValidIPAddress(observedIP, family: family)
                success = success && isExpectedAddress
                detail = isExpectedAddress
                    ? "HTTP \(http.statusCode) · 出口 IP \(observedIP)"
                    : "HTTP \(http.statusCode) · 未返回有效的\(kind == .ipv4 ? "IPv4" : "IPv6") 地址"
            }
            return ConnectivityProbeResult(
                kind: kind,
                success: success,
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

    private nonisolated static func isValidIPAddress(_ value: String, family: Int32) -> Bool {
        value.withCString { addressString in
            if family == AF_INET {
                var address = in_addr()
                return inet_pton(AF_INET, addressString, &address) == 1
            }
            var address = in6_addr()
            return inet_pton(AF_INET6, addressString, &address) == 1
        }
    }

    private nonisolated static func isPrivateIPv4Address(_ value: String) -> Bool {
        var address = in_addr()
        guard value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return false }
        let octets = value.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }
}

struct ConnectivityDiagnosticsView: View {
    @ObservedObject private var vpn = VPNManager.shared
    @StateObject private var model = ConnectivityDiagnosticsModel()
    @State private var showingClearConfirmation = false
    @State private var lanIPv4 = ""
    @State private var lanPort = "80"

    var body: some View {
        List {
            Section {
                HStack {
                    Label("内置 VPN", systemImage: vpn.isConnected ? "checkmark.shield.fill" : "xmark.shield")
                    Spacer()
                    Text(vpn.statusText).foregroundColor(vpn.isConnected ? .green : .secondary)
                }
                Button {
                    Task {
                        let node = ProxyStore.shared.selected
                        await model.run(vpnStatus: vpn.statusText,
                                        nodeProtocol: node?.proto.uppercased() ?? "未知",
                                        node: node,
                                        lanIPv4: lanIPv4,
                                        lanPort: lanPort)
                    }
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
                     ? "同时测试系统 DNS、Network.framework 原始 TCP、URLSession HTTPS；另用 sing-box 指定节点直接测试 Cloudflare HTTPS 代理出站。Network.framework 探测不保证与 URLSession 或其他应用走同一路径。节点为域名时，解析节点 IP 仍依赖系统 DNS。"
                     : "请先在“VPN 与节点”页连接内置 VPN，再运行诊断。")
            }

            Section("局域网（可选）") {
                TextField("内网 IPv4，例如 192.168.1.10", text: $lanIPv4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                HStack {
                    Text("TCP 端口")
                    Spacer()
                    TextField("80", text: $lanPort)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
                Text("填写一个已知有服务监听的内网设备 IPv4 和端口；留空地址则跳过。只接受 10.x、172.16–31.x、192.168.x。目标端口未开放也会失败，不能据此单独断定整个局域网都不可达。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                Text("报告保存在本机，最多保留最近 10 次。分享内容可能包含节点 IP、填写的内网 IP/端口和观测到的公网出口 IP；请先预览再发送。iOS 可能要求授予本地网络权限；系统不提供通用方式自动发现网关，因此需要手动填写内网目标。")
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

private struct TCPConnectionOutcome: Sendable {
    let success: Bool
    let detail: String
}

private final class TCPProbeOperation: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TCPConnectionOutcome, Never>?
    private var finished = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func run(timeout: TimeInterval) async -> TCPConnectionOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.finish(TCPConnectionOutcome(success: true, detail: "TCP 握手成功"))
                case .failed(let error):
                    self?.finish(TCPConnectionOutcome(success: false, detail: error.localizedDescription))
                case .cancelled:
                    self?.finish(TCPConnectionOutcome(success: false, detail: "连接已取消"))
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(TCPConnectionOutcome(success: false, detail: "连接超时（\(Int(timeout)) 秒）"))
            }
        }
    }

    private func finish(_ outcome: TCPConnectionOutcome) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(returning: outcome)
    }
}
