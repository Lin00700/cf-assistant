import SwiftUI
import Foundation
import Darwin

// MARK: - DNS 报文（最小实现：一个 A 查询 + 可选 EDNS0 padding）

enum DNSWire {
    static func query(name: String, type: UInt16 = 1, padding: Int = 0) -> Data {
        var bytes: [UInt8] = []
        bytes += [0x12, 0x34]          // id
        bytes += [0x01, 0x00]          // flags: recursion desired
        bytes += [0x00, 0x01]          // qdcount
        bytes += [0x00, 0x00]          // ancount
        bytes += [0x00, 0x00]          // nscount
        if padding > 0 { bytes += [0x00, 0x01] } else { bytes += [0x00, 0x00] }  // arcount
        for label in name.split(separator: ".") {
            let labelBytes = Array(label.utf8).prefix(63)
            bytes.append(UInt8(labelBytes.count))
            bytes += labelBytes
        }
        bytes.append(0x00)
        bytes.append(UInt8((type >> 8) & 0xff))
        bytes.append(UInt8(type & 0xff))
        bytes += [0x00, 0x01]          // class IN
        if padding > 0 {
            // OPT RR：name=0 type=41 class=4096 ttl=0，rdata 为 option code 12（padding）
            bytes += [0x00, 0x00, 0x29, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00]
            let optLength = 4 + padding
            bytes.append(UInt8((optLength >> 8) & 0xff))
            bytes.append(UInt8(optLength & 0xff))
            bytes += [0x00, 0x0c]
            bytes.append(UInt8((padding >> 8) & 0xff))
            bytes.append(UInt8(padding & 0xff))
            bytes += [UInt8](repeating: 0, count: padding)
        }
        return Data(bytes)
    }

    /// OPT 记录（15 字节）会额外占用报文长度
    static let paddingOverhead = 15

    static func rcode(_ data: Data) -> Int {
        guard data.count >= 4 else { return -1 }
        return (Int(data[2]) << 8 | Int(data[3])) & 0x000F
    }

    static func answerCount(_ data: Data) -> Int {
        guard data.count >= 8 else { return 0 }
        return Int(data[6]) << 8 | Int(data[7])
    }

    static func rcodeText(_ code: Int) -> String {
        switch code {
        case 0: return "NOERROR"
        case 1: return "FORMERR"
        case 2: return "SERVFAIL"
        case 3: return "NXDOMAIN"
        case 5: return "REFUSED"
        default: return "rcode \(code)"
        }
    }
}

// MARK: - 原始 UDP 探测

struct UDPProbeReply: Sendable {
    var data: Data?
    var error: String?
}

enum UDPProbe {
    /// 发一个 UDP 报文并等回应。`dontFragment` 会置 DF 位，用于 MTU 探测。
    static func send(host: String, port: UInt16, payload: Data,
                     timeoutMilliseconds: Int32, dontFragment: Bool) -> UDPProbeReply {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            return UDPProbeReply(data: nil, error: "地址不是 IPv4：\(host)")
        }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return UDPProbeReply(data: nil, error: "无法创建 UDP 套接字") }
        defer { close(fd) }

        if dontFragment {
            // Darwin 没有导出 IP_MTU_DISCOVER 宏，直接写常量：71 = IP_MTU_DISCOVER，2 = IP_PMTUDISC_DO
            var mode: Int32 = 2
            setsockopt(fd, IPPROTO_IP, 71, &mode, socklen_t(MemoryLayout<Int32>.size))
        }
        var timeout = timeval(tv_sec: Int(timeoutMilliseconds / 1000),
                              tv_usec: Int32((timeoutMilliseconds % 1000) * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var bytes = [UInt8](payload)
        let sent = withUnsafePointer(to: &address) { pointer -> Int in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                sendto(fd, bytes, bytes.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent > 0 else {
            let code = errno
            return UDPProbeReply(data: nil, error: code == 40 ? "报文超过本机 MTU（EMSGSIZE）" : "发送失败 errno=\(code)")
        }
        var buffer = [UInt8](repeating: 0, count: 8192)
        let received = recv(fd, &buffer, buffer.count, 0)
        guard received > 0 else { return UDPProbeReply(data: nil, error: "没有回应（超时）") }
        return UDPProbeReply(data: Data(buffer.prefix(received)), error: nil)
    }
}

// MARK: - MTU 探测

struct MTUProbeOutcome: Sendable {
    var mtu: Int?
    var attempts: Int
    var note: String
}

enum MTUProbe {
    static let headerOverhead = 28   // IPv4 20 + UDP 8

    /// 用带 DF 位的 DNS 报文二分探测路径 MTU。对端是公共 DNS（1.1.1.1 等），
    /// 只有完整到达并回应查询，才算这个尺寸能过去。
    static func probe(host: String, serverPort: UInt16, low: Int = 1200, high: Int = 1500) -> MTUProbeOutcome {
        let base = DNSWire.query(name: "example.com").count
        var lo = max(576, (low / 8) * 8)
        var hi = max(lo, (high / 8) * 8)
        var best: Int?
        var attempts = 0

        while lo <= hi && attempts < 24 {
            let mid = ((lo + hi) / 2 / 8) * 8
            if mid < lo { break }
            attempts += 1
            let payloadSize = mid - headerOverhead
            let padding = payloadSize - base - DNSWire.paddingOverhead
            let query = padding > 0 ? DNSWire.query(name: "example.com", padding: padding)
                                    : DNSWire.query(name: "example.com")
            let reply = UDPProbe.send(host: host, port: serverPort, payload: query,
                                      timeoutMilliseconds: 1200, dontFragment: true)
            if let data = reply.data, DNSWire.rcode(data) >= 0 {
                best = mid
                lo = mid + 8
            } else {
                hi = mid - 8
            }
        }

        if let best {
            return MTUProbeOutcome(mtu: best, attempts: attempts,
                                   note: "\(best) 字节（含 \(headerOverhead) 字节 IP/UDP 头）。再大 8 字节的报文没有回应。")
        }
        return MTUProbeOutcome(mtu: nil, attempts: attempts,
                               note: "在 \(low)–\(high) 字节范围内没有拿到回应：可能对端丢弃了带 EDNS0 padding 的查询，或这条路径整体不通。")
    }
}

// MARK: - DNS 解析器测速

struct DNSResolverTarget: Identifiable, Sendable {
    let id: UUID
    let label: String
    let host: String
    let port: UInt16
    let transport: String
    let dohURL: String?

    init(label: String, host: String, port: UInt16, transport: String, dohURL: String? = nil) {
        self.id = UUID()
        self.label = label
        self.host = host
        self.port = port
        self.transport = transport
        self.dohURL = dohURL
    }

    var address: String {
        if let dohURL { return dohURL }
        return "\(host):\(port)"
    }
}

struct DNSBenchmarkResult: Identifiable, Sendable {
    let id: UUID
    let label: String
    let transport: String
    let address: String
    let success: Bool
    let milliseconds: Int
    let detail: String

    init(target: DNSResolverTarget, success: Bool, milliseconds: Int, detail: String) {
        self.id = target.id
        self.label = target.label
        self.transport = target.transport
        self.address = target.address
        self.success = success
        self.milliseconds = milliseconds
        self.detail = detail
    }
}

enum DNSBenchmark {
    static let targets: [DNSResolverTarget] = [
        DNSResolverTarget(label: "Cloudflare", host: "1.1.1.1", port: 53, transport: "UDP"),
        DNSResolverTarget(label: "Google", host: "8.8.8.8", port: 53, transport: "UDP"),
        DNSResolverTarget(label: "AliDNS", host: "223.5.5.5", port: 53, transport: "UDP"),
        DNSResolverTarget(label: "DNSPod", host: "119.29.29.29", port: 53, transport: "UDP"),
        DNSResolverTarget(label: "Cloudflare", host: "1.1.1.1", port: 443, transport: "DoH",
                          dohURL: "https://1.1.1.1/dns-query"),
        DNSResolverTarget(label: "Google", host: "8.8.8.8", port: 443, transport: "DoH",
                          dohURL: "https://8.8.8.8/dns-query"),
        DNSResolverTarget(label: "AliDNS", host: "223.5.5.5", port: 443, transport: "DoH",
                          dohURL: "https://223.5.5.5/dns-query"),
        DNSResolverTarget(label: "DNSPod", host: "doh.pub", port: 443, transport: "DoH",
                          dohURL: "https://doh.pub/dns-query")
    ]

    static func run(domain: String) async -> [DNSBenchmarkResult] {
        let name = domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "www.apple.com" : domain
        return await withTaskGroup(of: DNSBenchmarkResult.self) { group in
            for target in targets {
                group.addTask { await measure(target, domain: name) }
            }
            var results: [DNSBenchmarkResult] = []
            for await result in group { results.append(result) }
            return results.sorted { left, right in
                if left.success != right.success { return left.success }
                return left.milliseconds < right.milliseconds
            }
        }
    }

    private static func measure(_ target: DNSResolverTarget, domain: String) async -> DNSBenchmarkResult {
        let started = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> Int { Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000) }

        if let urlText = target.dohURL {
            guard let url = URL(string: urlText) else {
                return DNSBenchmarkResult(target: target, success: false, milliseconds: 0, detail: "DoH 地址无效")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 6
            request.httpBody = DNSWire.query(name: domain)
            request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
            request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    return DNSBenchmarkResult(target: target, success: false, milliseconds: elapsed(), detail: "没有 HTTP 响应")
                }
                guard (200..<300).contains(http.statusCode) else {
                    return DNSBenchmarkResult(target: target, success: false, milliseconds: elapsed(),
                                              detail: "HTTP \(http.statusCode)")
                }
                let code = DNSWire.rcode(data)
                let answers = DNSWire.answerCount(data)
                let ok = code == 0 && answers > 0
                return DNSBenchmarkResult(target: target, success: ok, milliseconds: elapsed(),
                                          detail: "HTTP \(http.statusCode) · \(DNSWire.rcodeText(code)) · \(answers) 条答案")
            } catch {
                return DNSBenchmarkResult(target: target, success: false, milliseconds: elapsed(),
                                          detail: error.localizedDescription)
            }
        }

        let payload = DNSWire.query(name: domain)
        let reply = await Task.detached(priority: .userInitiated) {
            UDPProbe.send(host: target.host, port: target.port, payload: payload,
                          timeoutMilliseconds: 3000, dontFragment: false)
        }.value
        if let data = reply.data {
            let code = DNSWire.rcode(data)
            let answers = DNSWire.answerCount(data)
            let ok = code == 0 && answers > 0
            return DNSBenchmarkResult(target: target, success: ok, milliseconds: elapsed(),
                                      detail: "\(DNSWire.rcodeText(code)) · \(answers) 条答案")
        }
        return DNSBenchmarkResult(target: target, success: false, milliseconds: elapsed(),
                                  detail: reply.error ?? "没有回应")
    }
}

// MARK: - MTU 界面

struct MTUFinderView: View {
    @State private var host = "1.1.1.1"
    @State private var portText = "53"
    @State private var lowText = "1200"
    @State private var highText = "1500"
    @State private var isRunning = false
    @State private var outcome: MTUProbeOutcome?

    var body: some View {
        List {
            Section {
                TextField("目标 IPv4（公共 DNS）", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                HStack {
                    Text("UDP 端口")
                    Spacer()
                    TextField("53", text: $portText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
                HStack {
                    Text("最小 / 最大")
                    Spacer()
                    TextField("1200", text: $lowText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    TextField("1500", text: $highText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                }
            } footer: {
                Text("对公共 DNS 发带 DF 位、逐级加长的 DNS 查询，二分找到能收到回应的最大报文尺寸。VPN 连接时测到的是隧道这条路径的 MTU。")
            }
            Section {
                Button {
                    start()
                } label: {
                    if isRunning {
                        HStack { ProgressView(); Text("正在探测…") }
                    } else {
                        Label("开始 MTU 探测", systemImage: "ruler")
                    }
                }
                .disabled(isRunning)
            }
            if let outcome {
                Section("结果") {
                    if let mtu = outcome.mtu {
                        HStack {
                            Text("路径 MTU")
                            Spacer()
                            Text("\(mtu) 字节").font(.headline.monospacedDigit())
                        }
                    } else {
                        Text("未测出").font(.headline)
                    }
                    Text(outcome.note)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text("共发 \(outcome.attempts) 个探测报文")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Section {
                Text("这条路径的 MTU 决定单个 IP 报文能有多大。合并 MTU 偏小会让大包被丢弃、表现为「能打开网页但视频卡住」；隧道 MTU 固定 1500，若下层网络更小需要靠 TCP MSS 协商。探测结果依赖目标是否回应被填充的 DNS 查询，失败不代表路径一定不通。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("MTU 探测")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func start() {
        let targetHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetHost.isEmpty else { return }
        let port = UInt16(portText.trimmingCharacters(in: .whitespaces)) ?? 53
        let low = Int(lowText.trimmingCharacters(in: .whitespaces)) ?? 1200
        let high = Int(highText.trimmingCharacters(in: .whitespaces)) ?? 1500
        guard high > low else { return }
        isRunning = true
        outcome = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                MTUProbe.probe(host: targetHost, serverPort: port, low: low, high: high)
            }.value
            await MainActor.run {
                self.outcome = result
                self.isRunning = false
            }
        }
    }
}

// MARK: - DNS 解析器界面

struct DNSBenchmarkView: View {
    @State private var domain = "www.apple.com"
    @State private var isRunning = false
    @State private var results: [DNSBenchmarkResult] = []

    var body: some View {
        List {
            Section {
                TextField("测试域名", text: $domain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    start()
                } label: {
                    if isRunning {
                        HStack { ProgressView(); Text("正在测速…") }
                    } else {
                        Label("测试所有解析器", systemImage: "timer")
                    }
                }
                .disabled(isRunning)
            } footer: {
                Text("同时测 1.1.1.1、8.8.8.8、223.5.5.5、119.29.29.29（UDP 53）与它们的 DoH 版。UDP 走系统解析路径，DoH 走 HTTPS。")
            }
            if !results.isEmpty {
                Section("结果（按延迟排序）") {
                    ForEach(results) { result in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.success ? .green : .red)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("\(result.label) · \(result.transport)")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("\(result.milliseconds) ms")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text(result.address)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(result.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            Section {
                Text("延迟只代表这一次解析的往返时间，受当前网络、是否走代理影响。DoH 全失败而 UDP 正常，通常说明到该 DoH 地址的 443 不通或被拦；反过来则可能是系统 DNS 被劫持。结果不改变 sing-box 的 DNS 配置，仅用于判断哪个解析器可用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("DNS 解析器测速")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func start() {
        guard !isRunning else { return }
        isRunning = true
        let name = domain
        Task {
            let measured = await DNSBenchmark.run(domain: name)
            await MainActor.run {
                self.results = measured
                self.isRunning = false
            }
        }
    }
}
