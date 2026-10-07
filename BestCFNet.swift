import Foundation
import Network
import Security

struct BestCFFetch: Sendable {
    var head: Data          // 响应前 headLimit 字节
    var total: Int          // 共读取字节
    var handshakeMs: Double // 建立 TLS 耗时
    var seconds: Double     // 从发出请求到结束的耗时
}

enum BestCFNet {
    /// TCP 建连耗时（毫秒），失败返回 nil
    static func tcpPing(host: String, port: UInt16, timeout: TimeInterval) async -> Double? {
        await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            guard let p = NWEndpoint.Port(rawValue: port) else {
                cont.resume(returning: nil)
                return
            }
            let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let queue = DispatchQueue(label: "bestcf.tcp")
            let start = DispatchTime.now()
            var finished = false

            func finish(_ v: Double?) {
                if finished { return }
                finished = true
                conn.cancel()
                cont.resume(returning: v)
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ns = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                    finish(Double(ns) / 1_000_000)
                case .failed, .cancelled, .waiting:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// 连接指定 IP:port，用 sni 作为 TLS 服务器名（不校验证书），发送 request 并读取响应
    static func fetch(ip: String, port: UInt16, sni: String, request: Data,
                      headLimit: Int, stopBytes: Int, timeout: TimeInterval,
                      readSeconds: TimeInterval? = nil) async -> BestCFFetch? {
        guard let f = TLSFetcher(ip: ip, port: port, sni: sni, request: request,
                                 headLimit: headLimit, stopBytes: stopBytes,
                                 timeout: timeout, readSeconds: readSeconds) else { return nil }
        return await f.run()
    }
}

private final class TLSFetcher {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "bestcf.tls")
    private var cont: CheckedContinuation<BestCFFetch?, Never>?
    private var finished = false
    private var head = Data()
    private var total = 0
    private let headLimit: Int
    private let stopBytes: Int
    private let timeout: TimeInterval
    private let readSeconds: TimeInterval?
    private let request: Data
    private let started = DispatchTime.now()
    private var readyTime: DispatchTime?
    private var handshakeMs = 0.0

    init?(ip: String, port: UInt16, sni: String, request: Data,
          headLimit: Int, stopBytes: Int, timeout: TimeInterval, readSeconds: TimeInterval?) {
        guard let p = NWEndpoint.Port(rawValue: port) else { return nil }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, sni)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, DispatchQueue.global())
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        self.conn = NWConnection(host: NWEndpoint.Host(ip), port: p, using: params)
        self.request = request
        self.headLimit = headLimit
        self.stopBytes = stopBytes
        self.timeout = timeout
        self.readSeconds = readSeconds
    }

    func run() async -> BestCFFetch? {
        await withCheckedContinuation { (c: CheckedContinuation<BestCFFetch?, Never>) in
            self.cont = c
            conn.stateUpdateHandler = { [weak self] state in self?.handle(state) }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish() }
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard readyTime == nil else { return }
            let now = DispatchTime.now()
            readyTime = now
            handshakeMs = Double(now.uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            conn.send(content: request, completion: .contentProcessed { [weak self] err in
                if err != nil { self?.finish() }
            })
            receiveLoop()
            if let rs = readSeconds {
                queue.asyncAfter(deadline: .now() + rs) { [weak self] in self?.finish() }
            }
        case .failed, .cancelled, .waiting:
            finish()
        default:
            break
        }
    }

    private func receiveLoop() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.finished else { return }
            if let data = data, !data.isEmpty {
                self.total += data.count
                if self.head.count < self.headLimit {
                    self.head.append(data.prefix(self.headLimit - self.head.count))
                }
                if self.total >= self.stopBytes {
                    self.finish()
                    return
                }
            }
            if isComplete || error != nil {
                self.finish()
                return
            }
            self.receiveLoop()
        }
    }

    private func finish() {
        if finished { return }
        finished = true
        conn.cancel()
        var result: BestCFFetch?
        if let rt = readyTime {
            let ns = DispatchTime.now().uptimeNanoseconds - rt.uptimeNanoseconds
            result = BestCFFetch(head: head, total: total, handshakeMs: handshakeMs,
                                 seconds: max(Double(ns) / 1_000_000_000, 0.001))
        }
        cont?.resume(returning: result)
        cont = nil
    }
}

/// 解析域名为 IP 列表（阻塞调用，需放到后台线程）
func bestCFResolve(_ host: String, ipv6: Bool) -> [String] {
    var hints = addrinfo()
    hints.ai_family = ipv6 ? AF_UNSPEC : AF_INET
    hints.ai_socktype = Int32(SOCK_STREAM)
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
    defer { freeaddrinfo(res) }
    var out: [String] = []
    var p: UnsafeMutablePointer<addrinfo>? = first
    while let cur = p {
        var buf = [CChar](repeating: 0, count: 1025)
        if getnameinfo(cur.pointee.ai_addr, cur.pointee.ai_addrlen, &buf, socklen_t(buf.count),
                       nil, 0, NI_NUMERICHOST) == 0 {
            let s = String(cString: buf)
            if !out.contains(s) { out.append(s) }
        }
        p = cur.pointee.ai_next
    }
    return out
}
