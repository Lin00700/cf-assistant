import XCTest
@testable import CFAssistant

/// VLESS+WS+TLS 出站、大陆直连后缀、dns.final=dns-local，以及系统 DNS 必须在
/// ip_is_private 之前被劫持。不引用本地 geo 文件。
final class SingBoxConfigParityTests: XCTestCase {
    func testVLESSWebSocketTLSWithBypassCNMatchesMainShape() throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        var node = ProxyNode(
            name: "sample",
            proto: "vless",
            server: "104.17.51.244",
            port: 2087,
            secret: "11111111-1111-1111-1111-111111111111",
            params: [
                "type": "ws",
                "security": "tls",
                "sni": "example.com",
                "host": "example.com",
                "path": "/ws",
                "fp": "chrome"
            ]
        )
        node.id = id

        let text = SingBoxConfig.build(
            nodes: [node],
            selectedID: id,
            mode: .manual,
            bypassCN: true,
            rules: [],
            categoryPolicies: [:]
        )
        let data = Data(text.utf8)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let vless = try XCTUnwrap(outbounds.first { $0["type"] as? String == "vless" })
        XCTAssertEqual(vless["server"] as? String, "104.17.51.244")
        XCTAssertEqual(vless["server_port"] as? Int, 2087)
        XCTAssertEqual(vless["uuid"] as? String, "11111111-1111-1111-1111-111111111111")
        let tls = try XCTUnwrap(vless["tls"] as? [String: Any])
        XCTAssertEqual(tls["enabled"] as? Bool, true)
        XCTAssertEqual(tls["server_name"] as? String, "example.com")
        let transport = try XCTUnwrap(vless["transport"] as? [String: Any])
        XCTAssertEqual(transport["type"] as? String, "ws")
        XCTAssertEqual(transport["path"] as? String, "/ws")
        let headers = try XCTUnwrap(transport["headers"] as? [String: Any])
        XCTAssertEqual(headers["Host"] as? String, "example.com")

        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        XCTAssertEqual(dns["final"] as? String, "dns-local")
        let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        XCTAssertTrue(servers.contains { $0["type"] as? String == "https" && $0["server"] as? String == "1.1.1.1" && $0["path"] as? String == "/dns-query" && $0["detour"] as? String == "direct" })
        XCTAssertTrue(servers.contains { $0["type"] as? String == "tls" && $0["server"] as? String == "8.8.8.8" && $0["detour"] as? String == "proxy" })

        let route = try XCTUnwrap(root["route"] as? [String: Any])
        XCTAssertEqual(route["final"] as? String, "proxy")
        XCTAssertEqual(route["auto_detect_interface"] as? Bool, true)
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        let cn = try XCTUnwrap(rules.first { ($0["domain_suffix"] as? [String])?.contains("baidu.com") == true })
        XCTAssertEqual(cn["outbound"] as? String, "direct")
        let sniff = try XCTUnwrap(rules.first { $0["action"] as? String == "sniff" })
        let sniffers = try XCTUnwrap(sniff["sniffer"] as? [String])
        XCTAssertTrue(sniffers.contains("dns"))
        let hijackIndex = try XCTUnwrap(rules.firstIndex { $0["action"] as? String == "hijack-dns" && $0["port"] as? Int == 53 })
        let privateIndex = try XCTUnwrap(rules.firstIndex { $0["ip_is_private"] as? Bool == true })
        XCTAssertLessThan(hijackIndex, privateIndex)
        let tunDNS = try XCTUnwrap(rules.first { ($0["ip_cidr"] as? [String])?.contains("172.19.0.2/32") == true })
        XCTAssertEqual(tunDNS["action"] as? String, "hijack-dns")
        let upstream = try XCTUnwrap(rules.first { ($0["ip_cidr"] as? [String])?.contains("223.5.5.5/32") == true && $0["outbound"] as? String == "direct" })
        XCTAssertEqual(upstream["outbound"] as? String, "direct")
        XCTAssertFalse(rules.contains { ($0["ip_cidr"] as? [String])?.contains("1.1.1.1/32") == true && $0["outbound"] as? String == "direct" })

        let tun = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first)
        let exclude = try XCTUnwrap(tun["route_exclude_address"] as? [String])
        XCTAssertTrue(exclude.contains("104.17.51.244/32"))
        XCTAssertTrue(exclude.contains("223.5.5.5/32"))
        XCTAssertTrue(exclude.contains("8.8.8.8/32"))
        XCTAssertFalse(exclude.contains("1.1.1.1/32"))

        XCTAssertFalse(text.contains("rule_set"))
        XCTAssertFalse(text.contains("geosite"))
        XCTAssertFalse(text.contains("geoip"))
    }

    func testShortAccountNameStripsCloudflareDefault() {
        XCTAssertEqual(OverviewView.shortAccountName("Hual95000@gmail.com's Account"), "Hual95000")
        XCTAssertEqual(OverviewView.shortAccountName("Hual95000@gmail.com’s Account"), "Hual95000")
        XCTAssertEqual(OverviewView.shortAccountName("示例的账户"), "示例")
    }
}
