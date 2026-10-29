import XCTest
@testable import CFAssistant

final class TunnelStartupFailureTests: XCTestCase {
    func testRedactsNodeLinkCredentialsAndEndpoints() {
        let uuid = "11111111-2222-3333-4444-555555555555"
        let raw = "connect vless://\(uuid)@node.example.test:443?uuid=\(uuid)&token=private-token " +
            "password=private-password api_key=private-api-key to 203.0.113.9:443; " +
            "dial tcp edge-proxy:3128; connection refused"

        let safe = TunnelStartupFailureStore.sanitize(raw)

        for forbidden in ["vless://", uuid, "node.example.test", "private-token", "private-password", "private-api-key", "203.0.113.9", "edge-proxy", "3128"] {
            XCTAssertFalse(safe.contains(forbidden), "Leaked sensitive value: \(forbidden)")
        }
        XCTAssertTrue(safe.contains("connection refused"))
    }

    func testRedactsStructuredCredentialsAndEndpointValues() {
        let raw = #"{"uuid":"11111111-2222-3333-4444-555555555555","password":"secret-value","server":"proxy.example.test","server_port":443,"message":"TLS handshake failed"}"#

        let safe = TunnelStartupFailureStore.sanitize(raw)

        for forbidden in ["11111111-2222-3333-4444-555555555555", "secret-value", "proxy.example.test", "443"] {
            XCTAssertFalse(safe.contains(forbidden), "Leaked structured value: \(forbidden)")
        }
        XCTAssertTrue(safe.contains("TLS handshake failed"))
    }

    func testRedactsIPv6ButKeepsClockAndBoundsOutput() {
        let safeEndpoint = TunnelStartupFailureStore.sanitize("endpoint [2001:db8::1]:8443 failed at 04:29:37")
        XCTAssertFalse(safeEndpoint.contains("2001:db8::1"))
        XCTAssertFalse(safeEndpoint.contains("8443"))
        XCTAssertTrue(safeEndpoint.contains("04:29:37"))

        let long = TunnelStartupFailureStore.sanitize(String(repeating: "x", count: 900))
        XCTAssertLessThanOrEqual(long.count, 600)
    }
}
