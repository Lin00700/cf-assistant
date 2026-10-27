import Foundation

/// VPN 流量统计：实时上下行、本次会话、累计总量，可归零。
@MainActor
final class VPNTraffic: ObservableObject {
    static let shared = VPNTraffic()

    @Published private(set) var uploadRate: Int64 = 0
    @Published private(set) var downloadRate: Int64 = 0
    @Published private(set) var sessionUp: Int64 = 0
    @Published private(set) var sessionDown: Int64 = 0
    @Published private(set) var totalUp: Int64 = 0
    @Published private(set) var totalDown: Int64 = 0

    private let defaults = UserDefaults.standard
    private let kTotalUp = "vpn.traffic.totalUp"
    private let kTotalDown = "vpn.traffic.totalDown"

    private var pollTask: Task<Void, Never>?
    private var lastSampleAt: Date?

    private init() {
        totalUp = defaults.object(forKey: kTotalUp) as? Int64 ?? 0
        totalDown = defaults.object(forKey: kTotalDown) as? Int64 ?? 0
    }

    func startMonitoring() {
        stopMonitoring()
        sessionUp = 0
        sessionDown = 0
        uploadRate = 0
        downloadRate = 0
        lastSampleAt = Date()
        pollTask = Task { await pollLoop() }
    }

    func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
        uploadRate = 0
        downloadRate = 0
        lastSampleAt = nil
        persistTotals()
    }

    /// 仅清零本次会话（累计保留）
    func resetSession() {
        sessionUp = 0
        sessionDown = 0
    }

    /// 会话 + 累计全部归零
    func resetAll() {
        sessionUp = 0
        sessionDown = 0
        totalUp = 0
        totalDown = 0
        persistTotals()
    }

    private func persistTotals() {
        defaults.set(totalUp, forKey: kTotalUp)
        defaults.set(totalDown, forKey: kTotalDown)
    }

    private func pollLoop() async {
        // sing-box clash_api /traffic 为持续流：每行 JSON {"up":速率,"down":速率}
        while !Task.isCancelled {
            do {
                try await streamTrafficOnce()
            } catch {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func streamTrafficOnce() async throws {
        let url = SingBoxConfig.controlURL.appendingPathComponent("traffic")
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        for try await line in bytes.lines {
            if Task.isCancelled { break }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let up = int64(obj["up"])
            let down = int64(obj["down"])
            applySample(upRate: up, downRate: down)
        }
    }

    private func applySample(upRate: Int64, downRate: Int64) {
        let now = Date()
        let dt: Double
        if let last = lastSampleAt {
            dt = max(0.2, min(3.0, now.timeIntervalSince(last)))
        } else {
            dt = 1.0
        }
        lastSampleAt = now
        uploadRate = upRate
        downloadRate = downRate
        // clash /traffic 的 up/down 是「每秒字节」瞬时速率
        let addUp = Int64(Double(upRate) * dt)
        let addDown = Int64(Double(downRate) * dt)
        if addUp > 0 || addDown > 0 {
            sessionUp &+= addUp
            sessionDown &+= addDown
            totalUp &+= addUp
            totalDown &+= addDown
            persistTotals()
        }
    }

    private func int64(_ v: Any?) -> Int64 {
        if let i = v as? Int64 { return i }
        if let i = v as? Int { return Int64(i) }
        if let n = v as? NSNumber { return n.int64Value }
        return 0
    }

    static func formatBytes(_ n: Int64) -> String {
        let abs = Double(Swift.abs(n))
        if abs < 1024 { return "\(n) B" }
        if abs < 1024 * 1024 { return String(format: "%.1f KB", abs / 1024) }
        if abs < 1024 * 1024 * 1024 { return String(format: "%.2f MB", abs / (1024 * 1024)) }
        return String(format: "%.2f GB", abs / (1024 * 1024 * 1024))
    }

    static func formatRate(_ n: Int64) -> String {
        formatBytes(n) + "/s"
    }
}
