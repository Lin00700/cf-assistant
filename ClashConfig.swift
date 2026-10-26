import Foundation

/// Exports the stored profiles as a portable Mihomo / Clash.Meta YAML configuration.
enum ClashConfig {
    static func exportableNodeCount(nodes: [ProxyNode]) -> Int {
        nodes.filter(isSupported).count
    }

    static func build(nodes: [ProxyNode], selectedID: UUID?, selectionMode: ProxySelectionMode,
                      bypassCN: Bool, routingRules: [ProxyRoutingRule],
                      categoryPolicies: [ProxyTrafficCategory: ProxyGroupPolicy] = [:]) -> String {
        let supportedNodes = nodes.filter(isSupported)
        guard !supportedNodes.isEmpty else { return "" }

        var usedNames = Set<String>()
        let names = supportedNodes.map { node -> String in
            let base = node.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? node.server : node.name
            if usedNames.insert(base).inserted { return base }
            let unique = "\(base) (\(node.id.uuidString.prefix(4)))"
            usedNames.insert(unique)
            return unique
        }
        let selectedIndex = supportedNodes.firstIndex(where: { $0.id == selectedID }) ?? 0
        let selectedName = names[selectedIndex]
        let quotedNames = names.map(quote)
        var lines = [
            "# Clash.Meta / Mihomo profile",
            "mixed-port: 7890",
            "allow-lan: false",
            "mode: rule",
            "log-level: info",
            "ipv6: false",
            "proxies:"
        ]

        for (index, node) in supportedNodes.enumerated() {
            appendProxy(node, name: names[index], to: &lines)
        }

        lines += [
            "proxy-groups:",
            "  - name: \(quote("手动选择"))",
            "    type: select",
            "    proxies:"
        ]
        for name in quotedNames { lines.append("      - \(name)") }
        lines += [
            "    default-selected: \(quote(selectedName))",
            "  - name: \(quote("自动选择"))",
            "    type: url-test",
            "    proxies:"
        ]
        for name in quotedNames { lines.append("      - \(name)") }
        lines += [
            "    url: \(quote("https://www.gstatic.com/generate_204"))",
            "    interval: 600",
            "    tolerance: 50",
            "    lazy: true",
            "  - name: \(quote("PROXY"))",
            "    type: select",
            "    proxies:",
            "      - \(quote(selectionMode == .automatic ? "自动选择" : "手动选择"))",
            "      - \(quote(selectionMode == .automatic ? "手动选择" : "自动选择"))"
        ]
        for category in ProxyTrafficCategory.allCases {
            let policy = categoryPolicies[category] ?? .follow
            let defaultName: String
            switch policy {
            case .direct: defaultName = "DIRECT"
            case .auto: defaultName = "自动选择"
            case .proxy, .follow: defaultName = "PROXY"
            }
            lines += [
                "  - name: \(quote(category.clashName))",
                "    type: select",
                "    proxies:",
                "      - \(quote("PROXY"))",
                "      - \(quote("自动选择"))",
                "      - DIRECT"
            ]
            for name in quotedNames { lines.append("      - \(name)") }
            lines.append("    default-selected: \(quote(defaultName))")
        }
        lines.append("rules:")

        for rule in routingRules where !rule.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let target = rule.target == .direct ? "DIRECT" : "PROXY"
            switch rule.kind {
            case .domainSuffix:
                lines.append("  - \(quote("DOMAIN-SUFFIX,\(rule.value),\(target)"))")
            case .ipCIDR:
                let type = rule.value.contains(":") ? "IP-CIDR6" : "IP-CIDR"
                lines.append("  - \(quote("\(type),\(rule.value),\(target),no-resolve"))")
            }
        }
        if bypassCN {
            for suffix in SingBoxConfig.cnSuffixes {
                lines.append("  - \(quote("DOMAIN-SUFFIX,\(suffix),DIRECT"))")
            }
        }
        for category in ProxyTrafficCategory.allCases {
            for suffix in category.suffixes {
                lines.append("  - \(quote("DOMAIN-SUFFIX,\(suffix),\(category.clashName)"))")
            }
        }
        lines.append("  - \(quote("MATCH,PROXY"))")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func isSupported(_ node: ProxyNode) -> Bool {
        let proto = node.proto.lowercased()
        let supportedProto = ["vless", "vmess", "trojan", "ss", "shadowsocks", "hysteria2", "hy2"]
            .contains(proto)
        let network = node.p("type") ?? node.p("net") ?? "tcp"
        guard supportedProto,
              !node.server.isEmpty,
              !node.secret.isEmpty,
              (1...65535).contains(node.port),
              ["", "tcp", "ws", "grpc"].contains(network.lowercased()) else { return false }
        if proto == "vless", node.p("security") == "reality", node.p("pbk") == nil { return false }
        return true
    }

    private static func appendProxy(_ node: ProxyNode, name: String, to lines: inout [String]) {
        let proto = node.proto.lowercased()
        let type = proto == "shadowsocks" ? "ss" : (proto == "hy2" ? "hysteria2" : proto)
        lines += [
            "  - name: \(quote(name))",
            "    type: \(type)",
            "    server: \(quote(node.server))",
            "    port: \(node.port)",
            "    udp: true"
        ]

        switch proto {
        case "vless":
            append("uuid", node.secret, to: &lines)
            appendIfPresent("flow", node.p("flow"), to: &lines)
            append("encryption", "none", to: &lines)
            append("packet-encoding", "xudp", to: &lines)
            appendTLS(node, to: &lines)
            appendTransport(node, to: &lines)
        case "vmess":
            append("uuid", node.secret, to: &lines)
            lines.append("    alterId: \(Int(node.p("aid") ?? "0") ?? 0)")
            append("cipher", node.p("scy") ?? "auto", to: &lines)
            append("packet-encoding", "xudp", to: &lines)
            appendTLS(node, to: &lines)
            appendTransport(node, to: &lines)
        case "trojan":
            lines.append("    tls: true")
            append("password", node.secret, to: &lines)
            appendIfPresent("sni", serverName(node), to: &lines)
            appendSkipCertVerify(node, to: &lines)
            appendALPN(node, to: &lines)
            appendTransport(node, to: &lines)
        case "ss", "shadowsocks":
            append("cipher", node.p("method") ?? "aes-128-gcm", to: &lines)
            append("password", node.secret, to: &lines)
        case "hysteria2", "hy2":
            append("password", node.secret, to: &lines)
            appendIfPresent("sni", serverName(node), to: &lines)
            appendSkipCertVerify(node, to: &lines)
            appendIfPresent("obfs", node.p("obfs"), to: &lines)
            appendIfPresent("obfs-password", node.p("obfs-password"), to: &lines)
            appendALPN(node, to: &lines)
        default:
            break
        }
    }

    private static func appendTLS(_ node: ProxyNode, to lines: inout [String]) {
        let security = node.p("security") ?? "none"
        let enabled = security == "tls" || security == "reality"
        lines.append("    tls: \(enabled)")
        if enabled { appendIfPresent("servername", serverName(node), to: &lines) }
        appendIfPresent("client-fingerprint", node.p("fp"), to: &lines)
        if security == "reality" {
            lines.append("    reality-opts:")
            append("public-key", node.p("pbk") ?? "", indent: 6, to: &lines)
            appendIfPresent("short-id", node.p("sid"), indent: 6, to: &lines)
        }
        appendSkipCertVerify(node, to: &lines)
        appendALPN(node, to: &lines)
    }

    private static func appendTransport(_ node: ProxyNode, to lines: inout [String]) {
        let network = node.p("type") ?? node.p("net") ?? "tcp"
        guard ["ws", "grpc"].contains(network) else { return }
        lines.append("    network: \(network)")
        if network == "ws" {
            lines.append("    ws-opts:")
            append("path", node.p("path") ?? "/", indent: 6, to: &lines)
            if let host = node.p("host") {
                lines.append("      headers:")
                append("Host", host, indent: 8, to: &lines)
            }
        } else if network == "grpc" {
            lines.append("    grpc-opts:")
            append("grpc-service-name", node.p("serviceName") ?? node.p("path") ?? "", indent: 6, to: &lines)
        }
    }

    private static func appendALPN(_ node: ProxyNode, to lines: inout [String]) {
        guard let value = node.p("alpn") else { return }
        let values = value.split(separator: ",").map { String($0) }
        guard !values.isEmpty else { return }
        lines.append("    alpn:")
        for item in values { lines.append("      - \(quote(item))") }
    }

    private static func serverName(_ node: ProxyNode) -> String? {
        node.p("sni") ?? node.p("peer") ?? node.p("host") ?? node.server
    }

    private static func insecure(_ node: ProxyNode) -> Bool {
        node.p("allowInsecure") == "1" || node.p("insecure") == "1"
    }

    private static func appendIfPresent(_ key: String, _ value: String?, indent: Int = 4, to lines: inout [String]) {
        guard let value, !value.isEmpty else { return }
        append(key, value, indent: indent, to: &lines)
    }

    private static func appendSkipCertVerify(_ node: ProxyNode, to lines: inout [String]) {
        if insecure(node) { lines.append("    skip-cert-verify: true") }
    }

    private static func append(_ key: String, _ value: String, indent: Int = 4, to lines: inout [String]) {
        let spaces = String(repeating: " ", count: indent)
        lines.append("\(spaces)\(key): \(quote(value))")
    }

    private static func quote(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
            return "\"\""
        }
        return String(decoding: data, as: UTF8.self)
    }
}
