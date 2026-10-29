import Foundation
import Darwin
import Network
import NetworkExtension
import Libbox

final class TunnelLog {
    static let shared = TunnelLog()
    private var lines: [String] = []
    private let lock = NSLock()
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func add(_ s: String) {
        let ts = iso.string(from: Date())
        let line = "[\(ts)] \(s)"
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
        if lines.count > 600 { lines.removeFirst(lines.count - 600) }
        NSLog("CFTunnel: %@", s)
    }

    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        if lines.isEmpty {
            return "（扩展日志为空：可能尚未启动、启动失败，或进程刚被系统杀掉）"
        }
        return lines.joined(separator: "\n")
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        lines.removeAll()
    }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
    fileprivate var service: LibboxCommandServer?
    private var platform: TunnelPlatform?
    fileprivate var activeConfig: String?

    override func startTunnel(options: [String: NSObject]?) async throws {
        TunnelLog.shared.clear()
        TunnelLog.shared.add("[ext] startTunnel begin")

        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let config = proto.providerConfiguration?["config"] as? String, !config.isEmpty else {
            TunnelLog.shared.add("[ext] 缺少 sing-box 配置")
            throw NSError(domain: "CFTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少 sing-box 配置"])
        }

        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let work = base.appendingPathComponent("work", isDirectory: true)
        let temp = base.appendingPathComponent("tmp", isDirectory: true)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        try? fm.createDirectory(at: temp, withIntermediateDirectories: true)

        TunnelLog.shared.add("[ext] 配置 \(config.count) 字节")

        let setup = LibboxSetupOptions()
        setup.basePath = base.path
        setup.workingPath = work.path
        setup.tempPath = temp.path
        var setupErr: NSError?
        LibboxSetup(setup, &setupErr)
        if let setupErr {
            TunnelLog.shared.add("[ext] LibboxSetup 失败: \(setupErr.localizedDescription)")
            throw setupErr
        }

        let platform = TunnelPlatform(self)
        self.platform = platform

        var err: NSError?
        let svc = LibboxNewCommandServer(platform, platform, &err)
        if let err {
            TunnelLog.shared.add("[ext] LibboxNewCommandServer 失败: \(err.localizedDescription)")
            throw err
        }
        guard let svc else {
            throw NSError(domain: "CFTunnel", code: 2, userInfo: [NSLocalizedDescriptionKey: "sing-box 命令服务创建失败"])
        }
        service = svc
        activeConfig = config
        do {
            try svc.start()
            try svc.startOrReloadService(config, options: LibboxOverrideOptions())
        } catch {
            TunnelLog.shared.add("[ext] 启动 sing-box 服务失败: \(error.localizedDescription)")
            service = nil
            activeConfig = nil
            svc.close()
            throw error
        }
        TunnelLog.shared.add("[ext] sing-box 已启动")
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        let command = String(data: messageData, encoding: .utf8) ?? ""
        if command == "dns" {
            Task {
                let text = await Self.lookupCloudflareViaSingBox()
                completionHandler?(Data(text.utf8))
            }
            return
        }
        completionHandler?(Data(TunnelLog.shared.text().utf8))
    }

    /// Ask the in-process sing-box DNS router. This does not use the system resolver,
    /// so a success here with a system DNS timeout means hijack failed, not the upstream.
    private static func lookupCloudflareViaSingBox() async -> String {
        let started = Date()
        guard var components = URLComponents(string: "http://127.0.0.1:9090/dns/query") else {
            return "FAIL 无法构造 sing-box DNS 请求"
        }
        components.queryItems = [
            URLQueryItem(name: "name", value: "cloudflare.com"),
            URLQueryItem(name: "type", value: "A")
        ]
        guard let url = components.url else { return "FAIL 无法构造 sing-box DNS 请求" }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let body = String(data: data.prefix(180), encoding: .utf8) ?? ""
                return "FAIL \(ms) ms HTTP \(code) \(body)"
            }
            let status = obj["Status"] as? Int ?? -1
            let answers = (obj["Answer"] as? [[String: Any]]) ?? []
            let ips = answers.compactMap { ($0["data"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if ips.isEmpty {
                return "FAIL \(ms) ms sing-box DNS 无 A 记录 Status=\(status)"
            }
            return "OK \(ms) ms \(ips.joined(separator: " "))"
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return "FAIL \(ms) ms \(error.localizedDescription)"
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        TunnelLog.shared.add("[ext] stopTunnel reason=\(reason.rawValue)")
        if let service {
            try? service.closeService()
            try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
            service.close()
        }
        service = nil
        activeConfig = nil
        platform?.stopMonitor()
        platform = nil
    }
}

final class TunnelPlatform: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private unowned let tunnel: PacketTunnelProvider
    private var monitor: NWPathMonitor?
    private let ifaceLock = NSLock()
    private var lastIfaceName: String = ""
    private var lastIfaceIndex: Int32 = -1
    private var loggedBindFailure = false

    init(_ tunnel: PacketTunnelProvider) {
        self.tunnel = tunnel
    }

    func stopMonitor() {
        monitor?.cancel()
        monitor = nil
    }

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options, let ret0_ else {
            throw NSError(domain: "CFTunnel", code: 3, userInfo: [NSLocalizedDescriptionKey: "TUN 参数为空"])
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: options.getMTU())

        // Libbox 1.11 returns the next address after 172.19.0.1/30, which is 172.19.0.2.
        // iOS sends every system lookup there; sing-box hijacks port 53 on that address.
        var dnsServers: [String] = []
        if let it = try? options.getDNSServerAddress() {
            while it.hasNext() {
                let address = it.next()
                if !address.isEmpty { dnsServers.append(address) }
            }
        }
        if dnsServers.isEmpty {
            dnsServers = ["172.19.0.2"]
            TunnelLog.shared.add("[ext] Libbox DNS address unavailable, fallback 172.19.0.2")
        } else {
            TunnelLog.shared.add("[ext] DNS servers from Libbox: \(dnsServers.joined(separator: ","))")
        }
        let dnsSettings = NEDNSSettings(servers: dnsServers)
        dnsSettings.matchDomains = [""]
        dnsSettings.matchDomainsNoSearch = true
        settings.dnsSettings = dnsSettings

        var v4Addr: [String] = []
        var v4Mask: [String] = []
        if let it = options.getInet4Address() {
            while it.hasNext() {
                if let p = it.next() {
                    v4Addr.append(p.address())
                    v4Mask.append(p.mask())
                }
            }
        }
        if v4Addr.isEmpty {
            v4Addr = ["172.19.0.1"]
            v4Mask = ["255.255.255.252"]
        }
        let v4 = NEIPv4Settings(addresses: v4Addr, subnetMasks: v4Mask)

        var ipv4Routes: [NEIPv4Route] = []
        if let it = options.getInet4RouteAddress() {
            while it.hasNext() {
                if let p = it.next() {
                    ipv4Routes.append(NEIPv4Route(destinationAddress: p.address(), subnetMask: p.mask()))
                }
            }
        }
        if ipv4Routes.isEmpty {
            ipv4Routes = [NEIPv4Route.default()]
        }
        for server in dnsServers {
            Self.appendHostRoute(server, to: &ipv4Routes)
        }
        Self.appendHostRoute("172.19.0.2", to: &ipv4Routes)
        v4.includedRoutes = ipv4Routes

        var ipv4Exclude: [NEIPv4Route] = []
        if let it = options.getInet4RouteExcludeAddress() {
            while it.hasNext() {
                if let p = it.next() {
                    ipv4Exclude.append(NEIPv4Route(destinationAddress: p.address(), subnetMask: p.mask()))
                }
            }
        }
        ipv4Exclude.removeAll { $0.destinationAddress == "172.19.0.2" }
        v4.excludedRoutes = ipv4Exclude
        settings.ipv4Settings = v4
        TunnelLog.shared.add("[ext] IPv4 routes included=\(ipv4Routes.count) excluded=\(ipv4Exclude.count) dns=\(dnsServers.joined(separator: ","))")

        var v6Addr: [String] = []
        var v6Prefixes: [NSNumber] = []
        if let it = options.getInet6Address() {
            while it.hasNext() {
                if let p = it.next() {
                    v6Addr.append(p.address())
                    v6Prefixes.append(NSNumber(value: p.prefix()))
                }
            }
        }
        let v6 = NEIPv6Settings(addresses: v6Addr, networkPrefixLengths: v6Prefixes)
        var ipv6Routes: [NEIPv6Route] = []
        if let it = options.getInet6RouteAddress() {
            while it.hasNext() {
                if let p = it.next() {
                    ipv6Routes.append(NEIPv6Route(destinationAddress: p.address(), networkPrefixLength: NSNumber(value: p.prefix())))
                }
            }
        }
        if ipv6Routes.isEmpty {
            ipv6Routes = [NEIPv6Route.default()]
        }
        v6.includedRoutes = ipv6Routes
        var ipv6Exclude: [NEIPv6Route] = []
        if let it = options.getInet6RouteExcludeAddress() {
            while it.hasNext() {
                if let p = it.next() {
                    ipv6Exclude.append(NEIPv6Route(destinationAddress: p.address(), networkPrefixLength: NSNumber(value: p.prefix())))
                }
            }
        }
        v6.excludedRoutes = ipv6Exclude
        settings.ipv6Settings = v6
        TunnelLog.shared.add("[ext] IPv6 routes included=\(ipv6Routes.count) excluded=\(ipv6Exclude.count)")

        let sem = DispatchSemaphore(value: 0)
        var setErr: Error?
        tunnel.setTunnelNetworkSettings(settings) { e in
            setErr = e
            sem.signal()
        }
        if sem.wait(timeout: .now() + 8) == .timedOut {
            throw NSError(domain: "CFTunnel", code: 8, userInfo: [NSLocalizedDescriptionKey: "设置网络超时"])
        }
        if let setErr { throw setErr }
        TunnelLog.shared.add("[ext] 网络设置已应用")

        if let fd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32, fd >= 0 {
            ret0_.pointee = fd
            TunnelLog.shared.add("[ext] tun fd=\(fd)")
            return
        }
        let fd = LibboxGetTunnelFileDescriptor()
        if fd >= 0 {
            ret0_.pointee = fd
            TunnelLog.shared.add("[ext] tun fd=\(fd) (libbox)")
        } else {
            throw NSError(domain: "CFTunnel", code: 4, userInfo: [NSLocalizedDescriptionKey: "找不到 TUN fd"])
        }
    }

    func usePlatformAutoDetectControl() -> Bool { true }

    /// Bind direct sockets (dns-local 1.1.1.1 DoH, node dial) to the physical interface.
    /// auto_detect_interface alone does not bind while a platform interface is present.
    func autoDetectControl(_ fd: Int32) throws {
        ifaceLock.lock()
        let index = lastIfaceIndex
        ifaceLock.unlock()
        guard index > 0 else { return }
        var value = UInt32(index)
        let len = socklen_t(MemoryLayout.size(ofValue: value))
        let v4 = setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &value, len)
        let v6 = setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &value, len)
        if v4 != 0 && v6 != 0 {
            ifaceLock.lock()
            let shouldLog = !loggedBindFailure
            loggedBindFailure = true
            ifaceLock.unlock()
            if shouldLog {
                TunnelLog.shared.add("[ext] 绑定物理网卡 index=\(index) 失败 errno=\(errno)")
            }
        }
    }

    private static func appendHostRoute(_ address: String, to routes: inout [NEIPv4Route]) {
        let parts = address.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else { return }
        if routes.contains(where: { $0.destinationAddress == address }) { return }
        routes.append(NEIPv4Route(destinationAddress: address, subnetMask: "255.255.255.255"))
    }

    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32,
                             destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
        throw NSError(domain: "CFTunnel", code: 5, userInfo: [NSLocalizedDescriptionKey: "unsupported"])
    }

    func packageName(byUid uid: Int32, error: NSErrorPointer) -> String { "" }

    func uid(byPackageName packageName: String?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw NSError(domain: "CFTunnel", code: 6, userInfo: [NSLocalizedDescriptionKey: "unsupported"])
    }

    func useProcFS() -> Bool { false }

    func writeLog(_ message: String?) {
        TunnelLog.shared.add(message ?? "")
    }

    func usePlatformDefaultInterfaceMonitor() -> Bool { true }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        stopMonitor()
        let m = NWPathMonitor()
        monitor = m
        TunnelLog.shared.add("[ext] 启动默认网卡监听")
        m.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            if path.status == .unsatisfied {
                self.ifaceLock.lock()
                self.lastIfaceName = ""
                self.lastIfaceIndex = -1
                self.ifaceLock.unlock()
                listener?.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
                return
            }
            guard let iface = Self.pickInterface(from: path) else { return }
            let name = iface.name
            let index = Int32(iface.index)
            self.ifaceLock.lock()
            let unchanged = name == self.lastIfaceName && index == self.lastIfaceIndex
            if !unchanged {
                self.lastIfaceName = name
                self.lastIfaceIndex = index
            }
            self.ifaceLock.unlock()
            if unchanged { return }
            TunnelLog.shared.add("[ext] 默认网卡 \(name) index=\(index)")
            listener?.updateDefaultInterface(name, interfaceIndex: index,
                                             isExpensive: path.isExpensive, isConstrained: path.isConstrained)
        }
        m.start(queue: DispatchQueue(label: "cf.tunnel.monitor", qos: .userInitiated))
    }

    private static func pickInterface(from path: Network.NWPath) -> Network.NWInterface? {
        let ifaces = path.availableInterfaces.filter { iface in
            let n = iface.name.lowercased()
            if n.hasPrefix("utun") || n.hasPrefix("ipsec") || n.hasPrefix("ppp") { return false }
            if iface.type == Network.NWInterface.InterfaceType.loopback { return false }
            return true
        }
        if ifaces.isEmpty { return nil }
        func rank(_ i: Network.NWInterface) -> Int {
            switch i.type {
            case .wifi: return 0
            case .cellular: return 1
            case .wiredEthernet: return 2
            default: return 5
            }
        }
        var preferred: [Network.NWInterface] = []
        if path.usesInterfaceType(.wifi) {
            preferred = ifaces.filter { $0.type == .wifi }
        } else if path.usesInterfaceType(.cellular) {
            preferred = ifaces.filter { $0.type == .cellular }
        }
        let pool = preferred.isEmpty ? ifaces : preferred
        return pool.sorted { rank($0) < rank($1) }.first
    }

    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        stopMonitor()
    }

    func usePlatformInterfaceGetter() -> Bool { false }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        throw NSError(domain: "CFTunnel", code: 7, userInfo: [NSLocalizedDescriptionKey: "unsupported"])
    }

    func underNetworkExtension() -> Bool { true }
    func includeAllNetworks() -> Bool { false }
    func clearDNSCache() {}
    func readWIFIState() -> LibboxWIFIState? { nil }
    func send(_ notification: LibboxNotification?) throws {}
    func cancelNotification(_ identifier: String?, typeID: Int32) throws {}
    func startNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {}
    func closeNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {}
    func registerMyInterface(_ name: String?) {}

    func usePlatformShell() -> Bool { false }

    func checkPlatformShell() throws {
        throw unsupportedPlatformFeature("Platform shell")
    }

    func openShellSession(_ user: LibboxPlatformUser?, command: String?,
                          environ: (any LibboxStringIteratorProtocol)?, term: String?,
                          rows: Int32, cols: Int32) throws -> any LibboxShellSessionProtocol {
        throw unsupportedPlatformFeature("Platform shell")
    }

    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
        error?.pointee = unsupportedPlatformFeature("SSH host key") as NSError
        return ""
    }

    func lookupSFTPServer(_ error: NSErrorPointer) -> String {
        error?.pointee = unsupportedPlatformFeature("SFTP server") as NSError
        return ""
    }

    func tailscaleHostname() -> String { "" }

    func usePlatformBridge() -> Bool { false }

    func createBridge(_ options: LibboxBridgeOptions?) throws -> any LibboxBridgeSessionProtocol {
        throw unsupportedPlatformFeature("Platform bridge")
    }

    func lookupUser(_ username: String?) throws -> LibboxPlatformUser {
        throw unsupportedPlatformFeature("Platform user lookup")
    }

    func systemCertificates() -> (any LibboxStringIteratorProtocol)? { nil }

    // This provider's DNS config uses explicit remote transports, not the
    // platform-local DNS transport. Returning nil keeps libbox's normal local
    // transport registration in place.
    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }

    func serviceStop() throws {
        try tunnel.service?.closeService()
        stopMonitor()
    }

    func serviceReload() throws {
        guard let config = tunnel.activeConfig, let server = tunnel.service else {
            throw NSError(domain: "CFTunnel", code: 9, userInfo: [NSLocalizedDescriptionKey: "sing-box 服务尚未启动，无法重载"])
        }
        try server.startOrReloadService(config, options: LibboxOverrideOptions())
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        LibboxSystemProxyStatus()
    }

    func setSystemProxyEnabled(_ isEnabled: Bool) throws {}

    func triggerNativeCrash() throws {
        throw NSError(domain: "CFTunnel", code: 10, userInfo: [NSLocalizedDescriptionKey: "不支持触发原生崩溃"])
    }

    func writeDebugMessage(_ message: String?) {
        TunnelLog.shared.add(message ?? "")
    }

    func connectSSHAgent(_ ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw NSError(domain: "CFTunnel", code: 11, userInfo: [NSLocalizedDescriptionKey: "不支持 SSH agent 转发"])
    }

    private func unsupportedPlatformFeature(_ feature: String) -> NSError {
        NSError(domain: "CFTunnel", code: 12, userInfo: [NSLocalizedDescriptionKey: "不支持\(feature)"])
    }
}
