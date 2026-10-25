import Foundation
import Network

/// A TCP port-connect probe. It measures reachability to the node endpoint,
/// not proxy handshake time or end-to-end throughput.
enum ProxyProbeResult: Equatable, Sendable {
    case latency(Int)
    case unreachable
    case unsupported

    var label: String {
        switch self {
        case .latency(let milliseconds): return "\(milliseconds) ms"
        case .unreachable: return "不可达"
        case .unsupported: return "UDP 未测"
        }
    }

    var isReachable: Bool {
        if case .latency = self { return true }
        return false
    }

    var countsAsTested: Bool {
        if case .unsupported = self { return false }
        return true
    }
}

enum ProxyLatencyProbe {
    static func measure(_ node: ProxyNode) async -> ProxyProbeResult {
        // Hysteria2 uses UDP; a TCP connect probe would report a misleading result.
        guard node.proto.lowercased() != "hysteria2" else { return .unsupported }
        guard let rawPort = UInt16(exactly: node.port),
              let port = NWEndpoint.Port(rawValue: rawPort) else {
            return .unreachable
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(node.server),
            port: port,
            using: .tcp
        )
        let queue = DispatchQueue(label: "com.cfassistant.proxy-probe.\(UUID().uuidString)")
        let startedAt = DispatchTime.now().uptimeNanoseconds

        return await withCheckedContinuation { (continuation: CheckedContinuation<ProxyProbeResult, Never>) in
            var completed = false
            let finish: (ProxyProbeResult) -> Void = { result in
                guard !completed else { return }
                completed = true
                connection.cancel()
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
                    finish(.latency(Int(elapsed / 1_000_000)))
                case .failed(_), .cancelled:
                    finish(.unreachable)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .seconds(4)) {
                finish(.unreachable)
            }
        }
    }
}
