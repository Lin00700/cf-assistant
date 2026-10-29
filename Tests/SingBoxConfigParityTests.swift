import XCTest
@testable import CFAssistant

/// 同一组输入下，生成的 sing-box JSON 必须和 main（ace3242）的生成器一致：
/// VLESS+WS+TLS 出站字段、大陆直连后缀、DNS/路由 final、以及不引用本地 geo 文件。
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
        XCTAssertTrue(servers.contains { $0["address"] as? String == "udp://223.5.5.5" && $0["detour"] as? String == "direct" })
        XCTAssertTrue(servers.contains { $0["address"] as? String == "tls://8.8.8.8" && $0["detour"] as? String == "proxy" })

        let route = try XCTUnwrap(root["route"] as? [String: Any])
        XCTAssertEqual(route["final"] as? String, "proxy")
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        let cn = try XCTUnwrap(rules.first { ($0["domain_suffix"] as? [String])?.contains("baidu.com") == true })
        XCTAssertEqual(cn["outbound"] as? String, "direct")

        let tun = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first)
        let exclude = try XCTUnwrap(tun["inet4_route_exclude_address"] as? [String])
        XCTAssertTrue(exclude.contains("104.17.51.244/32"))
        XCTAssertTrue(exclude.contains("223.5.5.5/32"))
        XCTAssertTrue(exclude.contains("8.8.8.8/32"))

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
