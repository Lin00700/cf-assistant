import Foundation

/// 节点测量结果：真实代理延迟、TCP 端口延迟或探测请求失败。
enum ProxyProbeResult: Equatable, Sendable {
    case latency(Int)
    case tcpLatency(Int)
    case unreachable
    case probeFailed
    case requiresVPN

    var label: String {
        switch self {
        case .latency(let milliseconds): return "\(milliseconds) ms"
        case .tcpLatency(let milliseconds): return "TCP \(milliseconds) ms"
        case .unreachable: return "不可用"
        case .probeFailed: return "探测失败"
        case .requiresVPN: return "需 VPN"
        }
    }

    var isReachable: Bool {
        switch self {
        case .latency, .tcpLatency: return true
        case .unreachable, .probeFailed, .requiresVPN: return false
        }
    }

    var countsAsTested: Bool { self != .requiresVPN }

    static func from(milliseconds: Int?) -> ProxyProbeResult {
        guard let milliseconds, milliseconds >= 0 else { return .probeFailed }
        return .latency(milliseconds)
    }
}

enum ProxyLatencyTester {
    private static let maxConcurrentProbes = 48
    private static let tcpTimeout: TimeInterval = 3
    private static let singBoxProbeTimeoutMilliseconds = 8_000

    private enum SingBoxProbeOutcome: Sendable {
        case latency(Int)
        case probeFailed
        case apiError(String)
    }

    private struct SingBoxDelayResponse: Decodable {
        let delay: Int
    }

    /// VPN 未连接时测 TCP 端口；Hysteria2 使用 UDP，需连接 VPN 才能准确探测。
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

    /// VPN 已连接时逐个调用 sing-box 的代理 delay API，避免整组探测的固定总超时截断大订阅。
    static func measureViaSingBox(nodes: [ProxyNode], controlURL: URL) async throws -> [UUID: ProxyProbeResult] {
        guard !nodes.isEmpty else { return [:] }

        let outcomes = await withTaskGroup(of: (UUID, SingBoxProbeOutcome).self) { group in
            var nextIndex = 0
            for node in nodes.prefix(maxConcurrentProbes) {
                group.addTask { (node.id, await Self.probeViaSingBox(node, controlURL: controlURL)) }
                nextIndex += 1
            }

            var values: [UUID: SingBoxProbeOutcome] = [:]
            while let (id, outcome) = await group.next() {
                values[id] = outcome
                if nextIndex < nodes.count {
                    let node = nodes[nextIndex]
                    nextIndex += 1
                    group.addTask { (node.id, await Self.probeViaSingBox(node, controlURL: controlURL)) }
                }
            }
            return values
        }

        let apiErrors = outcomes.values.compactMap { outcome -> String? in
            if case .apiError(let message) = outcome { return message }
            return nil
        }
        if apiErrors.count == nodes.count {
            throw CFClientError.message(apiErrors.first ?? "无法访问 sing-box 节点探测接口")
        }

        return Dictionary(uniqueKeysWithValues: nodes.map { node in
            let result: ProxyProbeResult
            switch outcomes[node.id] {
            case .some(.latency(let milliseconds)): result = .latency(milliseconds)
            case .some(.probeFailed), .some(.apiError(_)), .none: result = .probeFailed
            }
            return (node.id, result)
        })
    }

    private static func probeViaSingBox(_ node: ProxyNode, controlURL: URL) async -> SingBoxProbeOutcome {
        let delayURL = controlURL.appendingPathComponent("proxies")
            .appendingPathComponent(SingBoxConfig.nodeTag(node))
            .appendingPathComponent("delay")
        guard var components = URLComponents(url: delayURL, resolvingAgainstBaseURL: false) else {
            return .apiError("无法构造 sing-box 节点探测请求")
        }
        components.queryItems = [
            URLQueryItem(name: "url", value: SingBoxConfig.nodeProbeURL),
            URLQueryItem(name: "timeout", value: String(singBoxProbeTimeoutMilliseconds))
        ]
        guard let url = components.url else { return .apiError("无法构造 sing-box 节点探测请求") }

        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(singBoxProbeTimeoutMilliseconds) / 1_000 + 2
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .apiError("sing-box 节点探测接口未返回 HTTP 响应")
            }
            if http.statusCode == 503 || http.statusCode == 504 {
                // sing-box omits failed nodes from group results; a failed probe does not prove the node itself is unusable.
                return .probeFailed
            }
            guard (200..<300).contains(http.statusCode) else {
                return .apiError("sing-box 节点探测接口返回 HTTP \(http.statusCode)")
            }
            guard let value = try? JSONDecoder().decode(SingBoxDelayResponse.self, from: data), value.delay >= 0 else {
                return .apiError("sing-box 节点探测响应格式无效")
            }
            return .latency(value.delay)
        } catch {
            return .apiError("无法访问 sing-box 节点探测接口：\(error.localizedDescription)")
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
