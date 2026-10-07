import Foundation
import Network

// MARK: - 配置与数据模型

struct BestCFSource: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var tag: String
    var url: String
    var enabled: Bool = true
    var inlineText: String? = nil

    static let defaults: [BestCFSource] = [
        BestCFSource(name: "cm", tag: "移动", url: "https://ip.ehb.cc.cd/cm"),
        BestCFSource(name: "ct", tag: "电信", url: "https://ip.ehb.cc.cd/ct"),
        BestCFSource(name: "cu", tag: "联通", url: "https://ip.ehb.cc.cd/cu"),
        BestCFSource(name: "all", tag: "综合", url: "https://ip.ehb.cc.cd/all"),
        BestCFSource(name: "bestcf", tag: "BestCF域名",
                     url: "https://raw.githubusercontent.com/cmliu/CF-Pages-BestCF/main/cf_domains.txt")
    ]
}

struct BestCFConfig: Codable, Equatable, Sendable {
    var ghProxy = ""
    var timeoutMs = 1000
    var threads = 16
    var tries = 2
    var port = 0                    // 0 = 无端口的目标随机取常用端口
    var ipv6 = false
    var probeHost = "cloudflare.com"
    var cidrSample = 8
    var maxTargets = 3000

    var minPurity = 60
    var allowCountry: [String] = []
    var allowColo: [String] = []
    var maxLoss = 50

    var retestTop = 40
    var retestTries = 8
    var speedtestTop = 0
    var speedHost = "speed.cloudflare.com"
    var speedBytes = 5_000_000
    var speedSecs = 4

    var sortBy = "score"            // score | latency | speed
    var perColo = 0
    var top = 0
    var txtFormat = "{address}#{tag}-{country}-{colo}-{latency}ms"
    var loopMinutes = 0
}

struct BestCFTarget: Sendable {
    var isDomain: Bool
    var host: String
    var port: Int
    var tags: [String]
    var names: [String]
}

struct IPResult: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var address = ""
    var kind = "ip"
    var host = ""
    var ip = ""
    var port = 443
    var country = ""
    var colo = ""
    var latency: Double?
    var latencyMin: Double?
    var jitter = 0.0
    var loss = 0.0
    var httpMs: Double?
    var speed: Double?
    var purity = 0
    var score: Double?
    var status = 0
    var tag = ""
    var names = ""
    var retested = false

    /// 综合分，越低越好 = 平均延迟 + 0.5*抖动 + 5*丢包%
    mutating func calcScore() {
        guard let l = latency else { score = nil; return }
        score = ((l + 0.5 * jitter + 5 * loss) * 10).rounded() / 10
    }
}

let bestCFPorts = [443, 2053, 2083, 2087, 2096, 8443]
let bestCFUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) BestCFLocal/2.0"

// MARK: - IP / 网段工具

func bestCFIPBytes(_ s: String) -> [UInt8]? {
    if let a = IPv4Address(s) { return [UInt8](a.rawValue) }
    if let a = IPv6Address(s) { return [UInt8](a.rawValue) }
    return nil
}

func bestCFIPString(_ b: [UInt8]) -> String {
    if b.count == 4 { return b.map { String($0) }.joined(separator: ".") }
    if b.count == 16, let a = IPv6Address(Data(b)) {
        var s = a.debugDescription
        if let i = s.firstIndex(of: "%") { s = String(s[..<i]) }
        return s
    }
    return ""
}

func bestCFFmtAddr(_ host: String, _ port: Int) -> String {
    host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
}

struct CIDRNet: Sendable {
    let bytes: [UInt8]
    let prefix: Int
    var isV6: Bool { bytes.count == 16 }

    init(bytes: [UInt8], prefix: Int) {
        self.bytes = bytes
        self.prefix = prefix
    }

    init?(_ text: String) {
        let parts = text.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let p = Int(parts[1]), let b = bestCFIPBytes(parts[0]),
              p >= 0, p <= b.count * 8 else { return nil }
        self.bytes = b
        self.prefix = p
    }

    func contains(_ other: [UInt8]) -> Bool {
        guard other.count == bytes.count else { return false }
        var remaining = prefix
        for i in 0..<bytes.count {
            if remaining <= 0 { break }
            let bits = min(8, remaining)
            let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
            if (bytes[i] & mask) != (other[i] & mask) { return false }
            remaining -= bits
        }
        return true
    }

    /// 从网段里随机抽 n 个 IP（小网段会全部枚举）
    func sample(_ n: Int) -> [String] {
        let totalBits = bytes.count * 8
        let hostBits = totalBits - prefix
        if hostBits <= 0 { return [bestCFIPString(bytes)] }
        var out: [String] = []
        if !isV6 {
            let total = UInt64(1) << UInt64(hostBits)
            if total <= UInt64(max(n, 2)) {
                let base = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                for i in 0..<total {
                    let v = base &+ UInt32(truncatingIfNeeded: i)
                    out.append(bestCFIPString([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                                               UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]))
                }
                return out
            }
        }
        var seen = Set<[UInt8]>()
        var attempts = 0
        while seen.count < n && attempts < n * 6 {
            attempts += 1
            var b = bytes
            var bit = prefix
            while bit < totalBits {
                let idx = bit / 8
                let inByte = bit % 8
                if inByte == 0 && bit + 8 <= totalBits {
                    b[idx] = UInt8.random(in: 0...255)
                    bit += 8
                } else {
                    let m = UInt8(1 << (7 - inByte))
                    if Bool.random() { b[idx] |= m } else { b[idx] &= ~m }
                    bit += 1
                }
            }
            if !isV6 && hostBits > 1, let last = b.last, last == 0 || last == 255 { continue }
            seen.insert(b)
        }
        return seen.sorted { $0.lexicographicallyPrecedes($1) }.map { bestCFIPString($0) }
    }
}

let bestCFCFNets: [CIDRNet] = """
173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18
108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17
162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22
2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32
2a06:98c0::/29 2c0f:f248::/32
""".split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { CIDRNet(String($0)) }

let bestCFPrivateNets: [CIDRNet] = [
    "0.0.0.0/8", "10.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
    "192.168.0.0/16", "224.0.0.0/3", "::/128", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8"
].compactMap { CIDRNet($0) }

func bestCFIsCF(_ ip: String) -> Bool {
    guard let b = bestCFIPBytes(ip) else { return false }
    return bestCFCFNets.contains { $0.contains(b) }
}

private let bestCFColoText = """
LAX:US SJC:US SEA:US SFO:US ORD:US DFW:US IAD:US EWR:US ATL:US MIA:US DEN:US
PHX:US LAS:US BOS:US MSP:US SLC:US PDX:US CLT:US IAH:US MCI:US BNA:US
YYZ:CA YVR:CA YUL:CA
HKG:HK MFM:MO TPE:TW KHH:TW NRT:JP KIX:JP FUK:JP OKA:JP ICN:KR PUS:KR
SIN:SG KUL:MY BKK:TH CGK:ID MNL:PH SGN:VN HAN:VN
BOM:IN DEL:IN MAA:IN BLR:IN HYD:IN CCU:IN COK:IN
FRA:DE DUS:DE HAM:DE MUC:DE TXL:DE LHR:GB MAN:GB EDI:GB
AMS:NL CDG:FR MRS:FR MAD:ES BCN:ES MXP:IT FCO:IT ZRH:CH VIE:AT
ARN:SE CPH:DK OSL:NO HEL:FI WAW:PL PRG:CZ BUD:HU OTP:RO SOF:BG ATH:GR
DUB:IE LIS:PT BRU:BE KBP:UA LED:RU SVO:RU DME:RU IST:TR
DXB:AE DOH:QA TLV:IL AMM:JO KWI:KW RUH:SA
SYD:AU MEL:AU PER:AU BNE:AU AKL:NZ
GRU:BR GIG:BR EZE:AR SCL:CL BOG:CO LIM:PE MEX:MX PTY:PA
JNB:ZA CPT:ZA LOS:NG NBO:KE CAI:EG CMN:MA
"""

let bestCFColoCountry: [String: String] = {
    var d: [String: String] = [:]
    for pair in bestCFColoText.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
        let p = pair.split(separator: ":")
        if p.count == 2 { d[String(p[0])] = String(p[1]) }
    }
    return d
}()

// MARK: - 源解析

enum BestCFParsed {
    case ip(String, Int)
    case domain(String, Int)
    case cidr(CIDRNet)
}

enum BestCFParser {
    static func parseToken(_ raw: String, ipv6: Bool, allowDomain: Bool) -> [BestCFParsed] {
        var tok = raw.trimmingCharacters(in: CharacterSet(charactersIn: ",;|\"' \t\r\n"))
        if tok.isEmpty { return [] }
        if let r = tok.range(of: "://") { tok = String(tok[r.upperBound...]) }

        if let slash = tok.firstIndex(of: "/") {
            let left = String(tok[..<slash])
            let right = String(tok[tok.index(after: slash)...])
            if let p = Int(right), let b = bestCFIPBytes(left) {
                guard p >= 0, p <= b.count * 8 else { return [] }
                if b.count == 16 && !ipv6 { return [] }
                return [.cidr(CIDRNet(bytes: b, prefix: p))]
            }
            tok = left   // 去掉 URL 路径
        }

        var host = tok
        var port = 0
        if tok.hasPrefix("["), let close = tok.firstIndex(of: "]") {
            host = String(tok[tok.index(after: tok.startIndex)..<close])
            let rest = tok[tok.index(after: close)...]
            if rest.hasPrefix(":") {
                guard let p = Int(rest.dropFirst()), (1...65535).contains(p) else { return [] }
                port = p
            }
        } else if tok.filter({ $0 == ":" }).count == 1 {
            let comps = tok.split(separator: ":", omittingEmptySubsequences: false)
            guard comps.count == 2, let p = Int(comps[1]), (1...65535).contains(p) else { return [] }
            host = String(comps[0])
            port = p
        }

        if let b = bestCFIPBytes(host) {
            if b.count == 16 && !ipv6 { return [] }
            if bestCFPrivateNets.contains(where: { $0.contains(b) }) { return [] }
            return [.ip(bestCFIPString(b), port)]
        }
        if allowDomain && isDomain(host) { return [.domain(host.lowercased(), port)] }
        return []
    }

    static func isDomain(_ h: String) -> Bool {
        guard h.contains("."), h.count <= 253, !h.hasPrefix("."), !h.hasSuffix("."), !h.hasPrefix("-") else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard h.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        guard let tld = h.split(separator: ".").last, tld.count >= 2, tld.allSatisfy({ $0.isLetter }) else {
            return false
        }
        return true
    }

    static func flatten(_ obj: Any, _ out: inout [String]) {
        if let d = obj as? [String: Any] {
            let ipAny: Any? = d["ip"] ?? d["address"] ?? d["host"]
            if let ip = ipAny as? String, let port = d["port"], !(port is NSNull), "\(port)" != "" {
                out.append(ip.contains(":") ? "[\(ip)]:\(port)" : "\(ip):\(port)")
            } else {
                for v in d.values { flatten(v, &out) }
            }
        } else if let a = obj as? [Any] {
            for v in a { flatten(v, &out) }
        } else if let s = obj as? String {
            out.append(s)
        }
    }

    static func parseText(_ text: String, ipv6: Bool) -> [BestCFParsed] {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = s.prefix(20).lowercased()
        let isHTML = head.hasPrefix("<!doctype") || head.hasPrefix("<html")
        var lines: [String] = []
        if let f = s.first, f == "[" || f == "{" {
            if let data = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) {
                flatten(obj, &lines)
            } else {
                lines = text.components(separatedBy: .newlines)
            }
        } else {
            lines = text.components(separatedBy: .newlines)
        }
        var out: [BestCFParsed] = []
        let seps = CharacterSet(charactersIn: " \t,;|")
        for raw in lines {
            let line = (raw.components(separatedBy: "#").first ?? "").trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") { continue }
            for tok in line.components(separatedBy: seps) where !tok.isEmpty {
                out.append(contentsOf: parseToken(tok, ipv6: ipv6, allowDomain: !isHTML))
            }
        }
        return out
    }
}
