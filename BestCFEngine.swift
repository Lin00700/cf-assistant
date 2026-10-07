import SwiftUI

// MARK: - 并发限流 map

func bestCFPmap<T: Sendable, R: Sendable>(
    _ items: [T], limit: Int,
    onProgress: @escaping @Sendable (Int, Int) -> Void,
    work: @escaping @Sendable (T) async -> R?
) async -> [R] {
    let total = items.count
    if total == 0 { return [] }
    return await withTaskGroup(of: R?.self) { group -> [R] in
        var out: [R] = []
        var idx = 0
        var done = 0
        while idx < min(max(limit, 1), total) {
            let item = items[idx]
            idx += 1
            group.addTask { await work(item) }
        }
        while let r = await group.next() {
            done += 1
            if let r = r { out.append(r) }
            onProgress(done, total)
            if idx < total && !Task.isCancelled {
                let item = items[idx]
                idx += 1
                group.addTask { await work(item) }
            }
        }
        return out
    }
}

// MARK: - 探测

enum BestCF {
    private static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

    static func parseHTTP(_ data: Data) -> (Int, [String: String], [String: String]) {
        let raw = String(decoding: data, as: UTF8.self)
        let parts = raw.components(separatedBy: "\r\n\r\n")
        let headText = parts.first ?? ""
        let body = parts.count > 1 ? parts.dropFirst().joined(separator: "\r\n\r\n") : ""
        var lines = headText.components(separatedBy: "\r\n")
        var status = 0
        if let first = lines.first, first.hasPrefix("HTTP/") {
            let comps = first.split(separator: " ")
            if comps.count >= 2 { status = Int(comps[1]) ?? 0 }
            lines.removeFirst()
        }
        var hdr: [String: String] = [:]
        for l in lines {
            if let i = l.firstIndex(of: ":") {
                let k = String(l[..<i]).lowercased().trimmingCharacters(in: .whitespaces)
                hdr[k] = String(l[l.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        var kv: [String: String] = [:]
        for l in body.components(separatedBy: .newlines) {
            if let i = l.firstIndex(of: "=") {
                kv[String(l[..<i]).trimmingCharacters(in: .whitespaces)] =
                    String(l[l.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return (status, hdr, kv)
    }

    private static func stats(_ times: [Double]) -> (avg: Double, min: Double, jitter: Double) {
        let avg = times.reduce(0, +) / Double(times.count)
        let variance = times.reduce(0) { $0 + ($1 - avg) * ($1 - avg) } / Double(times.count)
        return (round1(avg), round1(times.min() ?? avg), times.count > 1 ? round1(variance.squareRoot()) : 0)
    }

    /// 第一轮：DNS(域名) + TCP 延迟 + TLS + /cdn-cgi/trace + 纯度
    static func probe(_ t: BestCFTarget, _ cfg: BestCFConfig) async -> IPResult? {
        let timeout = Double(cfg.timeoutMs) / 1000
        var r = IPResult()
        r.kind = t.isDomain ? "domain" : "ip"
        r.host = t.host
        r.port = t.port
        r.tag = t.tags.joined(separator: "/")
        r.names = t.names.joined(separator: ",")
        let sni = t.isDomain ? t.host : cfg.probeHost

        var ips: [String]
        if t.isDomain {
            let host = t.host
            let v6 = cfg.ipv6
            ips = await Task.detached { bestCFResolve(host, ipv6: v6) }.value
        } else {
            ips = [t.host]
        }
        guard let ip = ips.first else { return nil }
        r.ip = ip
        r.address = bestCFFmtAddr(t.host, t.port)
        let cfRatio = Double(ips.filter { bestCFIsCF($0) }.count) / Double(ips.count)

        var times: [Double] = []
        var fails = 0
        let tries = max(1, cfg.tries)
        for _ in 0..<tries {
            if Task.isCancelled { return nil }
            if let ms = await BestCFNet.tcpPing(host: ip, port: UInt16(t.port), timeout: timeout) {
                times.append(ms)
            } else {
                fails += 1
            }
        }
        guard !times.isEmpty else { return nil }
        let st = stats(times)
        r.latency = st.avg
        r.latencyMin = st.min
        r.jitter = st.jitter
        r.loss = round1(Double(fails) * 100 / Double(tries))

        let req = "GET /cdn-cgi/trace HTTP/1.1\r\nHost: \(sni)\r\nUser-Agent: \(bestCFUA)\r\nAccept: */*\r\nConnection: close\r\n\r\n"
        var status = 0
        var hdr: [String: String] = [:]
        var kv: [String: String] = [:]
        if let res = await BestCFNet.fetch(ip: ip, port: UInt16(t.port), sni: sni, request: Data(req.utf8),
                                           headLimit: 16384, stopBytes: 16384,
                                           timeout: max(timeout, 1.5) + 1) {
            r.httpMs = round1(res.handshakeMs + res.seconds * 1000)
            (status, hdr, kv) = parseHTTP(res.head)
        }
        r.status = status

        var colo = kv["colo"] ?? ""
        let ray = hdr["cf-ray"] ?? ""
        if colo.isEmpty, let dash = ray.lastIndex(of: "-") {
            colo = String(ray[ray.index(after: dash)...])
        }
        r.colo = colo.uppercased()
        r.country = colo.isEmpty ? "" : (bestCFColoCountry[r.colo] ?? "?")

        // 纯度(0-100): CF 网段占比 40 + server 头 20 + cf-ray 10 + Colo 有效 20 + HTTP 200 10
        var purity = Int((cfRatio * 40).rounded())
        if (hdr["server"] ?? "").lowercased().contains("cloudflare") { purity += 20 }
        if !ray.isEmpty { purity += 10 }
        if !r.colo.isEmpty && r.country != "" && r.country != "?" { purity += 20 }
        else if !r.colo.isEmpty { purity += 10 }
        if status == 200 { purity += 10 }
        r.purity = purity
        r.calcScore()
        return r
    }

    /// 第二轮：多次 TCP，统计平均 / 最小 / 抖动 / 丢包
    static func retest(_ old: IPResult, _ cfg: BestCFConfig) async -> IPResult {
        var r = old
        let timeout = Double(cfg.timeoutMs) / 1000
        let n = max(2, cfg.retestTries)
        var times: [Double] = []
        var fails = 0
        for _ in 0..<n {
            if Task.isCancelled { break }
            if let ms = await BestCFNet.tcpPing(host: r.ip, port: UInt16(r.port), timeout: timeout) {
                times.append(ms)
            } else {
                fails += 1
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        r.retested = true
        r.loss = round1(Double(fails) * 100 / Double(n))
        if times.isEmpty {
            r.latency = nil
        } else {
            let st = stats(times)
            r.latency = st.avg
            r.latencyMin = st.min
            r.jitter = st.jitter
        }
        r.calcScore()
        return r
    }

    /// 通过该 IP 向 speedHost 下载，返回 MB/s
    static func speed(_ r: IPResult, _ cfg: BestCFConfig) async -> Double {
        let req = "GET /__down?bytes=\(cfg.speedBytes) HTTP/1.1\r\nHost: \(cfg.speedHost)\r\nUser-Agent: \(bestCFUA)\r\nConnection: close\r\n\r\n"
        guard let res = await BestCFNet.fetch(ip: r.ip, port: UInt16(r.port), sni: cfg.speedHost,
                                              request: Data(req.utf8), headLimit: 2048,
                                              stopBytes: cfg.speedBytes + 4096,
                                              timeout: 5,
                                              readSeconds: Double(cfg.speedSecs)) else { return 0 }
        let head = String(decoding: res.head.prefix(64), as: UTF8.self)
        guard head.contains(" 200") else { return 0 }
        let mbps = Double(res.total) / 1_048_576 / res.seconds
        return (mbps * 100).rounded() / 100
    }
}

// MARK: - 引擎

@MainActor
final class PreferredIPEngine: ObservableObject {
    @Published var config: BestCFConfig {
        didSet { Self.save(config, "bestcf.config") }
    }
    @Published var sources: [BestCFSource] {
        didSet { Self.save(sources, "bestcf.sources") }
    }
    @Published var results: [IPResult]
    @Published var phase = "空闲"
    @Published var progress = 0.0
    @Published var running = false
    @Published var logs: [String] = []
    @Published var lastRun: Date?

    private var task: Task<Void, Never>?

    init() {
        config = Self.load("bestcf.config") ?? BestCFConfig()
        sources = Self.load("bestcf.sources") ?? BestCFSource.defaults
        results = Self.load("bestcf.results") ?? []
        if let t = UserDefaults.standard.object(forKey: "bestcf.lastRun") as? Date { lastRun = t }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    private static func save<T: Encodable>(_ v: T, _ key: String) {
        if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: key) }
    }

    func resetConfig() { config = BestCFConfig() }
    func resetSources() { sources = BestCFSource.defaults }

    func log(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        logs.append("\(f.string(from: Date())) \(s)")
        if logs.count > 300 { logs.removeFirst(100) }
    }

    // MARK: 控制

    func start() {
        guard !running else { return }
        running = true
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            repeat {
                await runOnce()
                if Task.isCancelled || config.loopMinutes <= 0 { break }
                phase = "\(config.loopMinutes) 分钟后自动再次运行（需保持 App 在前台）"
                try? await Task.sleep(nanoseconds: UInt64(config.loopMinutes) * 60 * 1_000_000_000)
            } while !Task.isCancelled
            running = false
            progress = 0
            UIApplication.shared.isIdleTimerDisabled = false
            if Task.isCancelled { phase = "已停止" }
        }
    }

    func stop() {
        task?.cancel()
        phase = "正在停止…"
    }

    private func progressHandler(base: Double, span: Double) -> @Sendable (Int, Int) -> Void {
        return { [weak self] done, total in
            let step = max(1, total / 20)
            guard done % step == 0 || done == total else { return }
            let value = base + span * Double(done) / Double(max(total, 1))
            Task { @MainActor in self?.progress = value }
        }
    }

    // MARK: 流程

    private func runOnce() async {
        let cfg = config
        let srcs = sources.filter { $0.enabled }
        guard !srcs.isEmpty else { phase = "没有启用的优选源"; return }
        let started = Date()
        progress = 0
        phase = "抓取优选源"
        log("开始扫描，使用 \(srcs.count) 个源")

        let targets = await loadTargets(cfg, srcs)
        if Task.isCancelled { phase = "已停止"; return }
        guard !targets.isEmpty else { phase = "没有可测目标"; log("没有可测目标"); return }

        phase = "快测 \(targets.count) 个目标"
        let first = await bestCFPmap(targets, limit: cfg.threads,
                                     onProgress: progressHandler(base: 0, span: 0.6)) { t in
            await BestCF.probe(t, cfg)
        }
        if Task.isCancelled { phase = "已停止"; return }
        log("快测连通 \(first.count)/\(targets.count)")

        var good = first.filter { Self.keep($0, cfg) }
        good.sort { ($0.score ?? 1e9) < ($1.score ?? 1e9) }
        log("纯度/地区过滤后 \(good.count) 个")

        if cfg.retestTop > 0, !good.isEmpty {
            phase = "复测前 \(min(cfg.retestTop, good.count)) 名"
            let head = Array(good.prefix(cfg.retestTop))
            let re = await bestCFPmap(head, limit: max(4, cfg.threads / 2),
                                      onProgress: progressHandler(base: 0.6, span: 0.25)) { r in
                await BestCF.retest(r, cfg)
            }
            var byID: [UUID: IPResult] = [:]
            for r in re { byID[r.id] = r }
            good = good.compactMap { r -> IPResult? in
                if let n = byID[r.id] {
                    return (n.latency == nil || n.loss > Double(cfg.maxLoss)) ? nil : n
                }
                return r
            }
        }
        good.sort { Self.less($0, $1, by: cfg.sortBy) }

        if cfg.speedtestTop > 0, !good.isEmpty {
            let n = min(cfg.speedtestTop, good.count)
            for i in 0..<n {
                if Task.isCancelled { break }
                phase = "下载测速 \(i + 1)/\(n)"
                progress = 0.85 + 0.15 * Double(i) / Double(n)
                let sp = await BestCF.speed(good[i], cfg)
                good[i].speed = sp
                log("测速 \(good[i].address) → \(sp) MB/s")
            }
            good.sort { Self.less($0, $1, by: cfg.sortBy) }
        }

        if cfg.perColo > 0 {
            var cnt: [String: Int] = [:]
            var kept: [IPResult] = []
            for r in good {
                let c = r.colo.isEmpty ? "?" : r.colo
                if cnt[c, default: 0] < cfg.perColo {
                    kept.append(r)
                    cnt[c, default: 0] += 1
                }
            }
            good = kept
        }
        if cfg.top > 0 { good = Array(good.prefix(cfg.top)) }

        results = good
        lastRun = Date()
        Self.save(Array(good.prefix(500)), "bestcf.results")
        UserDefaults.standard.set(lastRun, forKey: "bestcf.lastRun")
        progress = 1
        let secs = String(format: "%.1f", Date().timeIntervalSince(started))
        phase = "完成：保留 \(good.count) 个，用时 \(secs)s"
        log(phase)
    }

    private static func keep(_ r: IPResult, _ cfg: BestCFConfig) -> Bool {
        if r.purity < cfg.minPurity { return false }
        if !cfg.allowCountry.isEmpty && !cfg.allowCountry.contains(r.country) { return false }
        if !cfg.allowColo.isEmpty && !cfg.allowColo.contains(r.colo) { return false }
        return true
    }

    private static func less(_ a: IPResult, _ b: IPResult, by: String) -> Bool {
        if a.retested != b.retested { return a.retested }
        switch by {
        case "speed":
            let sa = a.speed ?? 0
            let sb = b.speed ?? 0
            if sa != sb { return sa > sb }
            return (a.score ?? 1e9) < (b.score ?? 1e9)
        case "latency":
            return (a.latency ?? 1e9) < (b.latency ?? 1e9)
        default:
            let x = a.score ?? 1e9
            let y = b.score ?? 1e9
            if x != y { return x < y }
            return a.purity > b.purity
        }
    }

    // MARK: 抓取源

    private func cacheURL(_ src: BestCFSource) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("bestcf_\(src.id.uuidString).txt")
    }

    private func fetchText(_ src: BestCFSource, _ cfg: BestCFConfig) async throws -> String {
        var s = src.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cfg.ghProxy.isEmpty && s.contains("githubusercontent.com") { s = cfg.ghProxy + s }
        guard let url = URL(string: s) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(bestCFUA, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        return String(decoding: data, as: UTF8.self)
    }

    private func loadTargets(_ cfg: BestCFConfig, _ srcs: [BestCFSource]) async -> [BestCFTarget] {
        var index: [String: Int] = [:]
        var list: [BestCFTarget] = []

        for src in srcs {
            if Task.isCancelled { break }
            var text: String?
            var how = ""
            if let inline = src.inlineText {
                text = inline
                how = "本地文本"
            } else {
                do {
                    let t = try await fetchText(src, cfg)
                    try? t.write(to: cacheURL(src), atomically: true, encoding: .utf8)
                    text = t
                    how = "在线"
                } catch {
                    if let c = try? String(contentsOf: cacheURL(src), encoding: .utf8) {
                        text = c
                        how = "缓存（在线失败）"
                    } else {
                        log("源 \(src.name) 失败：\(error.localizedDescription)")
                        continue
                    }
                }
            }
            guard let body = text else { continue }
            let items = BestCFParser.parseText(body, ipv6: cfg.ipv6)
            var added = 0
            for item in items {
                var hosts: [(Bool, String, Int)] = []
                switch item {
                case .ip(let h, let p): hosts = [(false, h, p)]
                case .domain(let h, let p): hosts = [(true, h, p)]
                case .cidr(let net): hosts = net.sample(cfg.cidrSample).map { (false, $0, 0) }
                }
                for (isDomain, h, p0) in hosts {
                    let p = p0 != 0 ? p0 : (cfg.port != 0 ? cfg.port : (bestCFPorts.randomElement() ?? 443))
                    let key = "\(h)|\(p)"
                    if let i = index[key] {
                        if !list[i].tags.contains(src.tag) {
                            list[i].tags.append(src.tag)
                            list[i].names.append(src.name)
                        }
                    } else {
                        index[key] = list.count
                        list.append(BestCFTarget(isDomain: isDomain, host: h, port: p,
                                                 tags: [src.tag], names: [src.name]))
                        added += 1
                    }
                }
            }
            log("源 \(src.name)（\(how)）解析 \(items.count) 条，新增 \(added)")
        }
        if list.count > cfg.maxTargets { list = Array(list.prefix(cfg.maxTargets)) }
        log("合并去重后共 \(list.count) 个目标")
        return list
    }

    // MARK: 导出

    static func formatLine(_ r: IPResult, _ fmt: String) -> String {
        let map: [String: String] = [
            "address": r.address, "tag": r.tag, "ip": r.ip, "port": String(r.port),
            "country": r.country.isEmpty ? "XX" : r.country,
            "colo": r.colo.isEmpty ? "XXX" : r.colo,
            "latency": String(Int(r.latency ?? 0)),
            "speed": r.speed.map { String($0) } ?? "0",
            "purity": String(r.purity)
        ]
        var s = fmt
        for (k, v) in map { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
        return s
    }

    func txtText(_ rows: [IPResult]) -> String {
        rows.map { Self.formatLine($0, config.txtFormat) }.joined(separator: "\n")
    }

    func csvText(_ rows: [IPResult]) -> String {
        func esc(_ s: String) -> String {
            s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        func num(_ d: Double?) -> String { d.map { String($0) } ?? "" }
        var out = "address,tag,kind,ip,port,country,colo,latency,latency_min,jitter,loss,speed,http_ms,purity,score,status\n"
        for r in rows {
            out += [esc(r.address), esc(r.tag), r.kind, r.ip, String(r.port), r.country, r.colo,
                    num(r.latency), num(r.latencyMin), String(r.jitter), String(r.loss), num(r.speed),
                    num(r.httpMs), String(r.purity), num(r.score), String(r.status)].joined(separator: ",") + "\n"
        }
        return out
    }

    /// 写入临时目录，返回可分享的文件
    func writeExportFiles() -> [URL] {
        let dir = FileManager.default.temporaryDirectory
        var urls: [URL] = []
        let txt = dir.appendingPathComponent("bestcf_latest.txt")
        let csv = dir.appendingPathComponent("bestcf_latest.csv")
        let json = dir.appendingPathComponent("bestcf_latest.json")
        try? txtText(results).write(to: txt, atomically: true, encoding: .utf8)
        try? csvText(results).write(to: csv, atomically: true, encoding: .utf8)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(results) { try? d.write(to: json) }
        for u in [txt, csv, json] where FileManager.default.fileExists(atPath: u.path) { urls.append(u) }
        return urls
    }
}
