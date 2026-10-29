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
        XCTAssertEqual(dns["final"] as? String, "dns-remote")
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

    func testBase64VLESSShareDecodesHostAndTLS() throws {
        let inner = "11111111-1111-1111-1111-111111111111@104.18.33.45:443?encryption=none&security=tls&type=ws&path=%2Fws&host=example.com&sni=example.com&fp=chrome"
        let encoded = Data(inner.utf8).base64EncodedString()
        let node = try XCTUnwrap(LinkParser.parse("vless://\(encoded)#blob"))
        XCTAssertEqual(node.server, "104.18.33.45")
        XCTAssertEqual(node.port, 443)
        XCTAssertEqual(node.secret, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(node.p("security"), "tls")
        XCTAssertEqual(node.p("type"), "ws")
        XCTAssertEqual(node.p("path"), "/ws")
        XCTAssertEqual(node.p("sni"), "example.com")
        let outbound = SingBoxConfig.outbound(node, tag: "n")
        XCTAssertNil(outbound["encryption"])
        XCTAssertEqual(outbound["packet_encoding"] as? String, "xudp")
        let tls = try XCTUnwrap(outbound["tls"] as? [String: Any])
        XCTAssertEqual(tls["server_name"] as? String, "example.com")
        let transport = try XCTUnwrap(outbound["transport"] as? [String: Any])
        XCTAssertEqual(transport["type"] as? String, "ws")
        XCTAssertEqual(transport["path"] as? String, "/ws")
        let saved = ProxyNode(name: encoded, proto: "vless", server: encoded, port: 443, secret: "", raw: "vless://\(encoded)#blob")
        let fixed = LinkParser.normalized(saved)
        XCTAssertEqual(fixed.server, "104.18.33.45")
        XCTAssertEqual(fixed.id, saved.id)
    }

    func testShadowsocksChaChaUserinfoMatchesPlainMethod() throws {
        let userinfo = Data("chacha20-ietf-poly1305:secret".utf8).base64EncodedString()
        let node = try XCTUnwrap(LinkParser.parse("ss://\(userinfo)@60.249.39.171:2377#台湾 31"))
        XCTAssertEqual(node.server, "60.249.39.171")
        XCTAssertEqual(node.port, 2377)
        XCTAssertEqual(node.p("method"), "chacha20-ietf-poly1305")
        XCTAssertEqual(node.secret, "secret")
        let outbound = SingBoxConfig.outbound(node, tag: "ss")
        XCTAssertEqual(outbound["type"] as? String, "shadowsocks")
        XCTAssertEqual(outbound["method"] as? String, "chacha20-ietf-poly1305")
        XCTAssertEqual(outbound["password"] as? String, "secret")
        XCTAssertNil(outbound["tls"])
    }

    func testShortAccountNameStripsCloudflareDefault() {
        XCTAssertEqual(OverviewView.shortAccountName("Hual95000@gmail.com's Account"), "Hual95000")
        XCTAssertEqual(OverviewView.shortAccountName("Hual95000@gmail.com’s Account"), "Hual95000")
        XCTAssertEqual(OverviewView.shortAccountName("示例的账户"), "示例")
    }
}
