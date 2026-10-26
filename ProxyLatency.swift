import Foundation

/// 节点测量结果：真实代理延迟或未开启 VPN 时的 TCP 端口延迟。
enum ProxyProbeResult: Equatable, Sendable {
    case latency(Int)
    case tcpLatency(Int)
    case unreachable
    case requiresVPN

    var label: String {
        switch self {
        case .latency(let milliseconds): return "\(milliseconds) ms"
        case .tcpLatency(let milliseconds): return "TCP \(milliseconds) ms"
        case .unreachable: return "不可用"
        case .requiresVPN: return "需 VPN"
        }
    }

    var isReachable: Bool {
        switch self {
        case .latency, .tcpLatency: return true
        case .unreachable, .requiresVPN: return false
        }
    }

    var countsAsTested: Bool { self != .requiresVPN }

    static func from(milliseconds: Int?) -> ProxyProbeResult {
        guard let milliseconds, milliseconds >= 0 else { return .unreachable }
        return .latency(milliseconds)
    }
}

enum ProxyLatencyTester {
    private static let maxConcurrentProbes = 48
    private static let tcpTimeout: TimeInterval = 3

    /// 未连接内置 VPN 时只测 TCP 端口建连；Hysteria2 使用 UDP，需 VPN 才能准确探测。
    static func measureDirectTCP(nodes: [ProxyNode]) async -> [UUID: ProxyProbeResult] {
        guard !nodes.isEmpty else { return [:] }

        return await withTaskGroup(of: (UUID, ProxyProbeResult).self) { group in
            var nextIndex = 0
            for node in nodes.prefix(maxConcurrentProbes) {
                group.addTask { await Self.probeTCP(node) }
                nextIndex += 1
            }

            var results: [UUID: ProxyProbeResult] = [:]
            while let (id, result) = await group.next() {
                results[id] = result
                if nextIndex < nodes.count {
                    let node = nodes[nextIndex]
                    nextIndex += 1
                    group.addTask { await Self.probeTCP(node) }
                }
            }
            return results
        }
    }

    private static func probeTCP(_ node: ProxyNode) async -> (UUID, ProxyProbeResult) {
        let proto = node.proto.lowercased()
        guard proto != "hysteria2" && proto != "hy2" else {
            return (node.id, .requiresVPN)
        }
        guard (1...65535).contains(node.port),
              let port = UInt16(exactly: node.port),
              let milliseconds = await BestCFNet.tcpPing(
                host: node.server,
                port: port,
                timeout: tcpTimeout
              ) else {
            return (node.id, .unreachable)
        }
        return (node.id, .tcpLatency(max(1, Int(milliseconds.rounded()))))
    }
}
