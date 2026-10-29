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

let oldSavedNode = ProxyNode(name: "x.io", proto: "vless", server: "x.io",
                            port: 443, secret: uuid, params: [:], raw: link)
let migrated = LinkParser.normalized(oldSavedNode)
precondition(migrated.name == encodedAuthority && migrated.name.count == 64 && migrated.p("type") == "xhttp")

let legacyWS = LinkParser.parse("vless://\(uuid)@legacy.example.com:443?security=tls&type=ws&host=legacy.example.com&path=%2Fws#Existing")!
precondition(legacyWS.name == "Existing" && legacyWS.p("type") == "ws")

let ssNode = ProxyNode(name: "config-check", proto: "ss", server: "192.0.2.1", port: 443,
                       secret: "test-only", params: ["method": "aes-128-gcm"])
let text = SingBoxConfig.build(nodes: [ssNode, imported, legacyWS], selectedID: imported.id, mode: .manual,
                               bypassCN: true, rules: [])
let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
let dns = root["dns"] as! [String: Any]
let servers = dns["servers"] as! [[String: Any]]
precondition(dns["final"] as? String == "dns-local")
precondition(servers.contains { $0["tag"] as? String == "dns-local" && $0["type"] as? String == "https" && $0["server"] as? String == "1.1.1.1" && $0["path"] as? String == "/dns-query" && $0["detour"] as? String == "direct" })
precondition(servers.contains { $0["tag"] as? String == "dns-remote" && $0["detour"] as? String == "proxy" })
let route = root["route"] as! [String: Any]
let rules = route["rules"] as! [[String: Any]]
precondition(route["final"] as? String == "proxy")
precondition(route["default_domain_resolver"] as? String == "dns-local")
let hijack = rules.firstIndex { $0["action"] as? String == "hijack-dns" && $0["port"] as? Int == 53 }!
let privateRoute = rules.firstIndex { $0["ip_is_private"] as? Bool == true }!
precondition(hijack < privateRoute)
precondition(!rules.contains { ($0["ip_cidr"] as? [String])?.contains("1.1.1.1/32") == true && $0["outbound"] as? String == "direct" })
let tun = (root["inbounds"] as! [[String: Any]])[0]
let excludes = tun["route_exclude_address"] as! [String]
precondition(excludes.contains("192.0.2.1/32") && !excludes.contains("1.1.1.1/32"))
let outbounds = root["outbounds"] as! [[String: Any]]
precondition(outbounds.contains { $0["type"] as? String == "shadowsocks" && $0["server"] as? String == ssNode.server && $0["server_port"] as? Int == ssNode.port && $0["password"] as? String == ssNode.secret })
let xhttp = outbounds.first { $0["server"] as? String == "x.io" }!
let tls = xhttp["tls"] as! [String: Any]
precondition(tls["enabled"] as? Bool == true && tls["server_name"] as? String == "x.io")
let transport = xhttp["transport"] as! [String: Any]
precondition(transport["type"] as? String == "xhttp" && transport["mode"] as? String == "stream-one")
precondition(transport["path"] as? String == "/product?ed=2560" && transport["host"] as? String == "x.io")
precondition(transport["x_padding_bytes"] as? String == "100-1000")
precondition(transport["x_padding_obfs_mode"] as? Bool == true)
precondition(transport["x_padding_key"] as? String == "_pad_test" && transport["x_padding_header"] as? String == "x-pad-test")
precondition(transport["x_padding_method"] as? String == "tokenish")
FileHandle.standardOutput.write(Data(text.utf8))
