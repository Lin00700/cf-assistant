import SwiftUI

enum GeoProvider: String, CaseIterable, Identifiable {
    case ipip, ipsb, ipwho, ipapi
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ipip: return "ipip.net"
        case .ipsb: return "ip.sb"
        case .ipwho: return "ipwho.is"
        case .ipapi: return "ipapi.co"
        }
    }
}

struct GeoFix: Equatable {
    var ip: String
    var place: String
    var isp: String
    var lat: Double?
    var lon: Double?
}

struct GlobeArc: Identifiable, Equatable {
    var id: String
    var city: String
    var lat: Double
    var lon: Double
    var proxied: Bool
    var count: Int
}

struct ScreenLabel: Identifiable, Equatable {
    var id: String
    var text: String
    var x: CGFloat
    var y: CGFloat
}

struct PingTarget: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL
    var samples: [Double] = []
}

@MainActor
final class VPNDashModel: ObservableObject {
    @Published var providerA: GeoProvider
    @Published var providerB: GeoProvider
    @Published var geoA: GeoFix?
    @Published var geoB: GeoFix?
    @Published var origin: GeoFix?
    @Published var geoNote: String?
    @Published var arcs: [GlobeArc] = []
    @Published var labels: [ScreenLabel] = []
    @Published var liveCount = 0
    @Published var countHistory: [Double] = Array(repeating: 0, count: 8)
    @Published var memory: Int64?
    @Published var upHistory: [Double] = Array(repeating: 0, count: 8)
    @Published var downHistory: [Double] = Array(repeating: 0, count: 8)
    @Published var targets: [PingTarget] = [
        PingTarget(id: "baidu", name: "Baidu", url: URL(string: "https://www.baidu.com/favicon.ico")!),
        PingTarget(id: "cf", name: "Cloudflare", url: URL(string: "https://1.1.1.1/cdn-cgi/trace")!),
        PingTarget(id: "gh", name: "GitHub", url: URL(string: "https://github.com/favicon.ico")!),
        PingTarget(id: "yt", name: "YouTube", url: URL(string: "https://www.youtube.com/favicon.ico")!)
    ]

    private struct GeoSlot { var fix: GeoFix? }
    private var cache: [String: GeoSlot] = [:]

    init() {
        providerA = GeoProvider(rawValue: UserDefaults.standard.string(forKey: "vpn.geo.a") ?? "") ?? .ipip
        providerB = GeoProvider(rawValue: UserDefaults.standard.string(forKey: "vpn.geo.b") ?? "") ?? .ipsb
    }

    func setProviderA(_ provider: GeoProvider) {
        providerA = provider
        UserDefaults.standard.set(provider.rawValue, forKey: "vpn.geo.a")
        Task { await refreshGeo() }
    }

    func setProviderB(_ provider: GeoProvider) {
        providerB = provider
        UserDefaults.standard.set(provider.rawValue, forKey: "vpn.geo.b")
        Task { await refreshGeo() }
    }

    func run() async {
        await refreshGeo()
        await pingOnce()
        async let traffic: Void = trafficLoop()
        async let conns: Void = connLoop()
        async let pings: Void = pingLoop()
        _ = await (traffic, conns, pings)
    }

    func refreshGeo() async {
        async let first = GeoClient.lookupSelf(providerA)
        async let second = GeoClient.lookupSelf(providerB)
        var a = await first
        var b = await second
        if a?.lat == nil, let ip = a?.ip, let extra = await GeoClient.lookup(ip, provider: .ipwho) {
            a?.lat = extra.lat
            a?.lon = extra.lon
        }
        if b?.lat == nil, let ip = b?.ip, let extra = await GeoClient.lookup(ip, provider: .ipwho) {
            b?.lat = extra.lat
            b?.lon = extra.lon
        }
        geoA = a
        geoB = b
        origin = (a?.lat != nil ? a : nil) ?? (b?.lat != nil ? b : nil) ?? a ?? b
        if a == nil && b == nil {
            geoNote = "暂时没有从 IP 服务拿到出口信息"
        } else {
            geoNote = nil
        }
        rebuildArcs()
    }

    private func trafficLoop() async {
        while !Task.isCancelled {
            let traffic = VPNTraffic.shared
            upHistory = appended(upHistory, Double(traffic.uploadRate))
            downHistory = appended(downHistory, Double(traffic.downloadRate))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func connLoop() async {
        while !Task.isCancelled {
            await pollConnections()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func pingLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { break }
            await pingOnce()
        }
    }

    func pingOnce() async {
        let urls = targets.map(\.url)
        guard urls.count >= 4 else { return }
        async let m0 = measure(urls[0])
        async let m1 = measure(urls[1])
        async let m2 = measure(urls[2])
        async let m3 = measure(urls[3])
        let results = await [m0, m1, m2, m3]
        for index in results.indices {
            var samples = targets[index].samples
            samples.append(results[index] ?? 0)
            if samples.count > 16 { samples.removeFirst(samples.count - 16) }
            targets[index].samples = samples
        }
    }

    private func measure(_ url: URL) async -> Double? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode >= 500 { return nil }
            return Date().timeIntervalSince(start) * 1000
        } catch {
            return nil
        }
    }

    private func pollConnections() async {
        let url = SingBoxConfig.controlURL.appendingPathComponent("connections")
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                liveCount = 0
                return
            }
            data = body
        } catch {
            liveCount = 0
            countHistory = appended(countHistory, 0)
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let rows = obj["connections"] as? [[String: Any]] ?? []
        liveCount = rows.count
        countHistory = appended(countHistory, Double(rows.count))
        let apiMemory = int64(obj["memory"])
        let ext = await VPNManager.shared.fetchMemory()
        if let ext, ext > 0 { memory = ext }
        else if apiMemory > 0 { memory = apiMemory }

        var fresh: [LiveConn] = []
        var needed: [String] = []
        for row in rows {
            let meta = row["metadata"] as? [String: Any] ?? [:]
            let ip = str(meta["destinationIP"])
            guard isPublic(ip) else { continue }
            let chains = strings(row["chains"])
            let proxied = chains.contains { name in
                let lower = name.lowercased()
                return !lower.isEmpty && lower != "direct"
            }
            fresh.append(LiveConn(ip: ip, host: str(meta["host"]), proxied: proxied))
            if cache[ip] == nil { needed.append(ip) }
        }
        var budget = 5
        var seen = Set<String>()
        for ip in needed where seen.insert(ip).inserted {
            if budget == 0 { break }
            budget -= 1
            var fix = await GeoClient.lookup(ip, provider: .ipwho)
            if fix == nil {
                fix = await GeoClient.lookup(ip, provider: .ipsb)
            }
            cache[ip] = GeoSlot(fix: fix)
        }
        conns = fresh
        rebuildArcs()
    }

    private var conns: [LiveConn] = []

    private func rebuildArcs() {
        var groups: [String: GlobeArc] = [:]
        for conn in conns {
            guard let fix = cache[conn.ip]?.fix, let lat = fix.lat, let lon = fix.lon else { continue }
            let city = fix.place.isEmpty ? (conn.host.isEmpty ? conn.ip : conn.host) : fix.place
            let id = "\(conn.proxied ? "p" : "d")-\(city)"
            if var arc = groups[id] {
                arc.count += 1
                groups[id] = arc
            } else {
                groups[id] = GlobeArc(id: id, city: city, lat: lat, lon: lon, proxied: conn.proxied, count: 1)
            }
        }
        arcs = groups.values.sorted { $0.count > $1.count }.prefix(12).map { $0 }
    }

    private func appended(_ values: [Double], _ value: Double) -> [Double] {
        var next = values
        next.append(value)
        if next.count > 40 { next.removeFirst(next.count - 40) }
        return next
    }
}

private struct LiveConn {
    var ip: String
    var host: String
    var proxied: Bool
}

enum GeoClient {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = ["User-Agent": "CFAssistant/1.2", "Accept": "application/json"]
        return URLSession(configuration: cfg)
    }()

    static func lookupSelf(_ provider: GeoProvider) async -> GeoFix? {
        guard let url = selfURL(provider) else { return nil }
        guard let data = try? await session.data(from: url).0 else { return nil }
        return parse(provider, data)
    }

    static func lookup(_ ip: String, provider: GeoProvider) async -> GeoFix? {
        guard let url = ipURL(provider, ip) else { return nil }
        guard let data = try? await session.data(from: url).0 else { return nil }
        return parse(provider, data)
    }

    private static func selfURL(_ provider: GeoProvider) -> URL? {
        switch provider {
        case .ipip: return URL(string: "https://myip.ipip.net/json")
        case .ipsb: return URL(string: "https://api.ip.sb/geoip")
        case .ipwho: return URL(string: "https://ipwho.is/")
        case .ipapi: return URL(string: "https://ipapi.co/json/")
        }
    }

    private static func ipURL(_ provider: GeoProvider, _ ip: String) -> URL? {
        let enc = ip.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ip
        switch provider {
        case .ipip: return nil
        case .ipsb: return URL(string: "https://api.ip.sb/geoip/\(enc)")
        case .ipwho: return URL(string: "https://ipwho.is/\(enc)")
        case .ipapi: return URL(string: "https://ipapi.co/\(enc)/json/")
        }
    }

    private static func parse(_ provider: GeoProvider, _ data: Data) -> GeoFix? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        switch provider {
        case .ipip:
            guard let root = obj as? [String: Any], str(root["ret"]) == "ok" || str(root["ret"]).isEmpty,
                  let dataObj = root["data"] as? [String: Any] else { return nil }
            let loc = (dataObj["location"] as? [Any] ?? []).map { str($0) }
            let place = uniqueJoin(Array(loc.prefix(3)))
            let isp = loc.last(where: { !$0.isEmpty }) ?? ""
            return GeoFix(ip: str(dataObj["ip"]), place: place, isp: isp, lat: nil, lon: nil)
        case .ipsb:
            guard let root = obj as? [String: Any] else { return nil }
            let ip = str(root["ip"])
            guard !ip.isEmpty else { return nil }
            return GeoFix(ip: ip,
                          place: uniqueJoin([str(root["city"]), str(root["region"]), str(root["country"])]),
                          isp: firstNonEmpty(str(root["isp"]), str(root["organization"]), str(root["asn_organization"])),
                          lat: num(root["latitude"]), lon: num(root["longitude"]))
        case .ipwho:
            guard let root = obj as? [String: Any], (root["success"] as? Bool) != false else { return nil }
            let ip = str(root["ip"])
            guard !ip.isEmpty else { return nil }
            let conn = root["connection"] as? [String: Any] ?? [:]
            return GeoFix(ip: ip,
                          place: uniqueJoin([str(root["city"]), str(root["region"]), str(root["country"])]),
                          isp: firstNonEmpty(str(conn["isp"]), str(conn["org"])),
                          lat: num(root["latitude"]), lon: num(root["longitude"]))
        case .ipapi:
            guard let root = obj as? [String: Any], (root["error"] as? Bool) != true else { return nil }
            let ip = str(root["ip"])
            guard !ip.isEmpty else { return nil }
            return GeoFix(ip: ip,
                          place: uniqueJoin([str(root["city"]), str(root["region"]), str(root["country_name"])]),
                          isp: str(root["org"]),
                          lat: num(root["latitude"]), lon: num(root["longitude"]))
        }
    }
}

private func uniqueJoin(_ parts: [String]) -> String {
    var out: [String] = []
    for part in parts {
        let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && !out.contains(text) { out.append(text) }
    }
    return out.joined(separator: " ")
}

private func firstNonEmpty(_ parts: String...) -> String {
    parts.first { !$0.isEmpty } ?? ""
}

private func str(_ value: Any?) -> String {
    if let s = value as? String { return s }
    if let n = value as? NSNumber { return n.stringValue }
    return ""
}

private func num(_ value: Any?) -> Double? {
    if let d = value as? Double { return d }
    if let i = value as? Int { return Double(i) }
    if let n = value as? NSNumber { return n.doubleValue }
    return nil
}

private func int64(_ value: Any?) -> Int64 {
    if let n = value as? NSNumber { return n.int64Value }
    if let i = value as? Int { return Int64(i) }
    return 0
}

private func strings(_ value: Any?) -> [String] {
    if let list = value as? [String] { return list }
    if let list = value as? [Any] { return list.compactMap { $0 as? String } }
    return []
}

private func isPublic(_ ip: String) -> Bool {
    if ip.isEmpty || ip == "0.0.0.0" { return false }
    if ip.contains(":") {
        let lower = ip.lowercased()
        if lower == "::1" || lower.hasPrefix("fe80") || lower.hasPrefix("fc") || lower.hasPrefix("fd") { return false }
        return true
    }
    let parts = ip.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4 else { return false }
    if parts[0] == 10 || parts[0] == 127 || parts[0] == 0 { return false }
    if parts[0] == 192 && parts[1] == 168 { return false }
    if parts[0] == 172 && (16...31).contains(parts[1]) { return false }
    if parts[0] == 100 && (64...127).contains(parts[1]) { return false }
    if parts[0] == 169 && parts[1] == 254 { return false }
    return true
}
