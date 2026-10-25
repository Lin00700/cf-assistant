import Foundation

/// sing-box 通过各节点发起 HTTPS 探测后返回的真实代理延迟。
enum ProxyProbeResult: Equatable, Sendable {
    case latency(Int)
    case unreachable

    var label: String {
        switch self {
        case .latency(let milliseconds): return "\(milliseconds) ms"
        case .unreachable: return "不可用"
        }
    }

    var isReachable: Bool {
        if case .latency = self { return true }
        return false
    }

    var countsAsTested: Bool { true }

    static func from(milliseconds: Int?) -> ProxyProbeResult {
        guard let milliseconds, milliseconds >= 0 else { return .unreachable }
        return .latency(milliseconds)
    }
}
