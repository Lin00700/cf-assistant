import Foundation
import Darwin

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let uuid = "11111111-2222-3333-4444-555555555555"
let raw = "dial failed: vless://\(uuid)@node.example.test:443?uuid=\(uuid)&token=link-token " +
    "password=plain-secret server=proxy.example.test server_port=9443 " +
    "remote 203.0.113.44:443 [2001:db8::1]:8443; dial tcp edge-proxy:3128; " +
    "api_key=private-key; connection refused at 04:29:37"
let sanitized = TunnelStartupFailureStore.sanitize(raw)

for forbidden in [
    "vless://", uuid, "node.example.test", "proxy.example.test", "link-token",
    "plain-secret", "203.0.113.44", "2001:db8::1", "9443", "8443",
    "edge-proxy", "3128", "private-key"
] {
    require(!sanitized.contains(forbidden), "sensitive value leaked: \(forbidden)")
}
require(sanitized.contains("connection refused"), "useful failure reason was lost")
require(sanitized.contains("04:29:37"), "clock-like diagnostic was mistaken for an endpoint")
require(sanitized.count <= 600, "sanitized message was not bounded")

let jsonLike = #"{"uuid":"11111111-2222-3333-4444-555555555555","password":"secret-json","server":"private.example.test","server_port":443,"error":"connection refused"}"#
let safeJSONLike = TunnelStartupFailureStore.sanitize(jsonLike)
for forbidden in ["11111111-2222-3333-4444-555555555555", "secret-json", "private.example.test", "443"] {
    require(!safeJSONLike.contains(forbidden), "structured sensitive value leaked: \(forbidden)")
}
require(safeJSONLike.contains("connection refused"), "structured failure reason was lost")

print("Tunnel startup failure redaction checks passed")
