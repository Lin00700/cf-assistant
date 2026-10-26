import Foundation
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
    private var service: LibboxBoxService?
    private var platform: TunnelPlatform?

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
        setup.isTVOS = false
        var setupErr: NSError?
        LibboxSetup(setup, &setupErr)
        if let setupErr {
            TunnelLog.shared.add("[ext] LibboxSetup 失败: \(setupErr.localizedDescription)")
            throw setupErr
        }

        let platform = TunnelPlatform(self)
        self.platform = platform

        var err: NSError?
        let svc = LibboxNewService(config, platform, &err)
        if let err {
            TunnelLog.shared.add("[ext] LibboxNewService 失败: \(err.localizedDescription)")
            throw err
        }
        guard let svc else {
            throw NSError(domain: "CFTunnel", code: 2, userInfo: [NSLocalizedDescriptionKey: "sing-box 服务创建失败"])
        }
        do {
            try svc.start()
        } catch {
            TunnelLog.shared.add("[ext] svc.start 失败: \(error.localizedDescription)")
            throw error
        }
        service = svc
        TunnelLog.shared.add("[ext] sing-box 已启动")
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        completionHandler?(Data(TunnelLog.shared.text().utf8))
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        TunnelLog.shared.add("[ext] stopTunnel reason=\(reason.rawValue)")
        try? service?.close()
        service = nil
        platform?.stopMonitor()
        platform = nil
    }
}

final class TunnelPlatform: NSObject, LibboxPlatformInterfaceProtocol {
    private unowned let tunnel: NEPacketTunnelProvider
    private var monitor: NWPathMonitor?
    private var lastIfaceName: String = ""
    private var lastIfaceIndex: Int32 = -1

    init(_ tunnel: NEPacketTunnelProvider) {
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

        // 让系统解析器使用 sing-box 提供的 DNS 地址，由 TUN 内的 DNS 劫持规则处理，
        // 不把系统查询强制旁路到公共解析器（这在受限网络上可能无法直连）。
        var dnsServers: [String] = []
        if let dnsMode = options.getDNSMode(), dnsMode.value != LibboxDNSModeDisabled {
            let dnsServerIterator = try options.getDNSServerAddress()
            while dnsServerIterator.hasNext() {
                dnsServers.append(dnsServerIterator.next())
            }
        }
        if !dnsServers.isEmpty {
            let dnsSettings = NEDNSSettings(servers: dnsServers)
            dnsSettings.matchDomains = [""]
            dnsSettings.matchDomainsNoSearch = true
            settings.dnsSettings = dnsSettings
            TunnelLog.shared.add("[ext] DNS servers from Libbox: \(dnsServers.joined(separator: ","))")
        } else {
            TunnelLog.shared.add("[ext] Libbox DNS disabled or no DNS servers")
        }

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
        v4.includedRoutes = ipv4Routes

        var ipv4Exclude: [NEIPv4Route] = []
        if let it = options.getInet4RouteExcludeAddress() {
            while it.hasNext() {
                if let p = it.next() {
                    ipv4Exclude.append(NEIPv4Route(destinationAddress: p.address(), subnetMask: p.mask()))
                }
            }
        }
        v4.excludedRoutes = ipv4Exclude
        settings.ipv4Settings = v4
        TunnelLog.shared.add("[ext] IPv4 routes included=\(ipv4Routes.count) excluded=\(ipv4Exclude.count)")

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

    func usePlatformAutoDetectControl() -> Bool { false }
    func autoDetectControl(_ fd: Int32) throws {}

    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32,
                             destinationAddress: String?, destinationPort: Int32,
                             ret0_: UnsafeMutablePointer<Int32>?) throws {
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
                self.lastIfaceName = ""
                self.lastIfaceIndex = -1
                listener?.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
                return
            }
            guard let iface = Self.pickInterface(from: path) else { return }
            let name = iface.name
            let index = Int32(iface.index)
            if name == self.lastIfaceName && index == self.lastIfaceIndex { return }
            self.lastIfaceName = name
            self.lastIfaceIndex = index
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
}
