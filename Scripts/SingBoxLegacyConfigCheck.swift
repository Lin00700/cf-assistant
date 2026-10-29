import Foundation

let uuid = "11111111-1111-1111-1111-111111111111"
let authority = ":\(uuid)@x.io:443"
let encodedAuthority = Data(authority.utf8).base64EncodedString()
precondition(encodedAuthority.count == 64)
let obfsJSON = #"{"":{"xPaddingMethod":"tokenish","xPaddingHeader":"x-pad-test","xPaddingObfsMode":true,"xPaddingKey":"_pad_test"},"Host":"x.io"}"#
let querySafe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
let encodedObfs = obfsJSON.addingPercentEncoding(withAllowedCharacters: querySafe)!
let link = "vless://\(encodedAuthority)?path=%2Fproduct%3Fed%3D2560&remarks=cloudflare&obfsParam=\(encodedObfs)&Host=x.io&obfs=xhttp&tls=1&peer=x.io&udp=1&mode=stream-one"
guard let imported = LinkParser.parse(link) else { fatalError("Synthetic VLESS XHTTP link did not parse") }
precondition(imported.name == encodedAuthority && imported.name.count == 64)
precondition(LinkParser.serverLooksLikeBlob(imported.name))
precondition(imported.server == "x.io" && imported.port == 443 && imported.secret == uuid)
precondition(imported.p("type") == "xhttp" && imported.p("security") == "tls")
precondition(imported.p("sni") == "x.io" && imported.p("host") == "x.io")
precondition(imported.p("mode") == "stream-one" && imported.p("path") == "/product?ed=2560")
precondition(imported.p("x_padding_obfs_mode") == "true")
precondition(imported.p("x_padding_key") == "_pad_test" && imported.p("x_padding_header") == "x-pad-test")
precondition(imported.p("x_padding_method") == "tokenish")
precondition(!SingBoxConfig.isSupported(imported), "The 1.11 test core must reject XHTTP, not silently emit a TCP outbound")

let oldSavedNode = ProxyNode(name: "x.io", proto: "vless", server: "x.io",
                            port: 443, secret: uuid, params: [:], raw: link)
let migrated = LinkParser.normalized(oldSavedNode)
precondition(migrated.name == encodedAuthority && migrated.name.count == 64 && migrated.p("type") == "xhttp")
precondition(!SingBoxConfig.isSupported(migrated))

let legacyWS = LinkParser.parse("vless://\(uuid)@legacy.example.com:443?security=tls&type=ws&host=legacy.example.com&path=%2Fws#Existing")!
precondition(legacyWS.name == "Existing" && legacyWS.p("type") == "ws")
precondition(SingBoxConfig.isSupported(legacyWS))

let ssNode = ProxyNode(name: "config-check", proto: "ss", server: "192.0.2.1", port: 443,
                       secret: "test-only", params: ["method": "aes-128-gcm"])
let text = SingBoxConfig.build(nodes: [ssNode, imported, legacyWS], selectedID: legacyWS.id, mode: .manual,
                               bypassCN: true, rules: [])
let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
let dns = root["dns"] as! [String: Any]
let servers = dns["servers"] as! [[String: Any]]
precondition(dns["final"] as? String == "dns-remote")
precondition(dns["independent_cache"] as? Bool == true)
precondition(servers.contains { $0["tag"] as? String == "dns-local" && $0["address"] as? String == "udp://223.5.5.5" && $0["detour"] as? String == "direct" })
precondition(servers.contains { $0["tag"] as? String == "dns-backup" && $0["address"] as? String == "udp://8.8.8.8" && $0["detour"] as? String == "direct" })
precondition(servers.contains { $0["tag"] as? String == "dns-remote" && $0["address"] as? String == "tls://8.8.8.8" && $0["detour"] as? String == "proxy" })

let route = root["route"] as! [String: Any]
let rules = route["rules"] as! [[String: Any]]
precondition(route["final"] as? String == "proxy")
precondition(route["auto_detect_interface"] as? Bool == false)
precondition(route["default_domain_resolver"] == nil)
let hijack = rules.firstIndex { $0["action"] as? String == "hijack-dns" && $0["protocol"] as? String == "dns" }!
let privateRoute = rules.firstIndex { $0["ip_is_private"] as? Bool == true }!
precondition(hijack < privateRoute)
precondition(!rules.contains { ($0["ip_cidr"] as? [String])?.contains("1.1.1.1/32") == true })

let tun = (root["inbounds"] as! [[String: Any]])[0]
precondition(tun["type"] as? String == "tun")
let excludes = tun["inet4_route_exclude_address"] as! [String]
precondition(["192.0.2.1/32", "223.5.5.5/32", "8.8.8.8/32"].allSatisfy { excludes.contains($0) })
precondition(!excludes.contains("1.1.1.1/32"))
precondition(tun["route_exclude_address"] == nil)

let outbounds = root["outbounds"] as! [[String: Any]]
precondition(outbounds.contains { $0["type"] as? String == "shadowsocks" && $0["server"] as? String == ssNode.server && $0["server_port"] as? Int == ssNode.port && $0["password"] as? String == ssNode.secret })
precondition(outbounds.contains { $0["tag"] as? String == SingBoxConfig.nodeTag(legacyWS) && $0["type"] as? String == "vless" })
precondition(!outbounds.contains { $0["tag"] as? String == SingBoxConfig.nodeTag(imported) })
precondition(!text.contains("1.1.1.1"))

FileHandle.standardOutput.write(Data(text.utf8))
