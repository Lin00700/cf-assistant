import Foundation

// MARK: - 节点模型

struct ProxyNode: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var proto: String            // vless / vmess / trojan / ss / hysteria2
    var server: String
    var port: Int
    var secret: String           // uuid / password
    var params: [String: String] = [:]
    var raw: String = ""         // 原始分享链接（导入时保留）

    var detail: String { "\(proto.uppercased()) · \(server):\(port)" }

    func p(_ k: String) -> String? {
        guard let v = params[k], !v.isEmpty else { return nil }
        return v
    }
}
