static func build(nodes: [ProxyNode], selectedID: UUID?, mode: ProxySelectionMode,
                  bypassCN: Bool, rules: [ProxyRoutingRule]) -> String {
    let usable = nodes.filter(isSupported)
    let tags = usable.map { nodeTag($0) }
    let selectedTag = usable.first(where: { $0.id == selectedID }).map { nodeTag($0) } ?? tags.first ?? "direct"

    let direct: [String: Any] = ["type": "direct", "tag": "direct"]
    var outbounds: [[String: Any]] = usable.map { outbound($0, tag: nodeTag($0)) }
    outbounds.append(direct)
    if tags.isEmpty {
        outbounds.append(["type": "selector", "tag": "proxy", "outbounds": ["direct"]])
    } else {
        let auto: [String: Any] = ["type": "urltest", "tag": "auto", "outbounds": tags,
                                   "url": nodeProbeURL, "interval": "5m"]
        let members = mode == .automatic ? ["auto"] + tags : [selectedTag] + tags.filter { $0 != selectedTag }
        let selector: [String: Any] = ["type": "selector", "tag": "proxy", "outbounds": members,
                                       "default": mode == .automatic ? "auto" : selectedTag]
        outbounds.append(auto)
        outbounds.append(selector)
    }

    var nodeIPs: [String] = []
    for n in usable {
        if let ip = literalIPv4(n.server) {
            nodeIPs.append("\(ip)/32")
        }
    }

    // ★ 修复 1：必须先 sniff，否则 protocol:"dns" 永不命中，hijack-dns 失效
    var routeRules: [[String: Any]] = [
        ["action": "sniff"],
        ["protocol": "dns", "action": "hijack-dns"],
        ["ip_is_private": true, "outbound": "direct"]
    ]
    if !nodeIPs.isEmpty {
        routeRules.append(["ip_cidr": nodeIPs, "outbound": "direct"])
    }

    var dnsRules: [[String: Any]] = []
    for r in rules {
        let v = r.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { continue }
        let out = r.target == .direct ? "direct" : "proxy"
        var rule: [String: Any] = ["outbound": out]
        switch r.kind {
        case .domainSuffix:
            rule["domain_suffix"] = [v]
            dnsRules.append(["domain_suffix": [v], "server": r.target == .direct ? "dns-local" : "dns-remote"])
        case .ipCIDR:
            rule["ip_cidr"] = [v]
        }
        routeRules.append(rule)
    }
    if bypassCN {
        routeRules.append(["domain_suffix": cnSuffixes, "outbound": "direct"])
        dnsRules.append(["domain_suffix": cnSuffixes, "server": "dns-local"])
    }

    let dnsServers: [[String: Any]] = [
        ["tag": "dns-local",  "address": "udp://223.5.5.5", "detour": "direct"],
        ["tag": "dns-backup", "address": "udp://8.8.8.8",   "detour": "direct"],
        ["tag": "dns-remote", "address": "tls://8.8.8.8",   "detour": "proxy"]
    ]
    // ★ 修复 2：默认走代理 DNS（干净、不会被污染），国内域名由 cnSuffixes 规则分流到本地 DNS
    let dns: [String: Any] = [
        "servers": dnsServers,
        "rules": dnsRules,
        "final": "dns-remote",
        "strategy": "prefer_ipv4",
        "independent_cache": true
    ]

    // ★ 修复 3：把 DNS 服务器 IP 也排除出 TUN 路由，避免 direct 发出的 DNS 包又被 TUN 抓回
    var tunExcludes: [String] = nodeIPs
    tunExcludes.append(contentsOf: ["223.5.5.5/32", "8.8.8.8/32"])
    var tun: [String: Any] = [
        "type": "tun", "tag": "tun-in",
        "address": ["172.19.0.1/30"],
        "mtu": 1500,
        "auto_route": true,
        "strict_route": false,
        "stack": "system"
    ]
    if !tunExcludes.isEmpty {
        tun["inet4_route_exclude_address"] = tunExcludes
    }
    let route: [String: Any] = [
        "rules": routeRules,
        "final": "proxy",
        "auto_detect_interface": false
    ]
    let log: [String: Any] = ["level": "info", "timestamp": true]
    let clash: [String: Any] = ["external_controller": "127.0.0.1:\(controlPort)"]
    let experimental: [String: Any] = ["clash_api": clash]
    let cfg: [String: Any] = [
        "log": log, "dns": dns, "inbounds": [tun], "outbounds": outbounds,
        "route": route, "experimental": experimental
    ]
    let data = (try? JSONSerialization.data(withJSONObject: cfg, options: [.sortedKeys])) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
}
