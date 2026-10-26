import Foundation
import Network
import NetworkExtension
import Libbox

// VPN 扩展：用 sing-box 的 Libbox 在 NEPacketTunnelProvider 里跑全局代理。

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

        TunnelLog.shared.add("[ext] 配置 \(config.count) 字节, base=\(base.path)")
        if config.count > 200 {
            TunnelLog.shared.add("[ext] config head: \(String(config.prefix(120)))…")
        }

        let excludeIPs = Self.collectExcludeIPv4(from: config)
        TunnelLog.shared.add("[ext] 排除直连 IP: \(excludeIPs.joined(separator: ", "))")

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
        TunnelLog.shared.add("[ext] LibboxSetup OK")

        let platform = TunnelPlatform(self, excludeIPv4: excludeIPs)
        self.platform = platform

        var err: NSError?
        let svc = LibboxNewService(config, platform, &err)
        if let err {
            TunnelLog.shared.add("[ext] LibboxNewService 失败: \(err.localizedDescription)")
            throw err
        }
        guard let svc else {
            TunnelLog.shared.add("[ext] sing-box 服务创建失败 (nil)")
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

    private static func collectExcludeIPv4(from config: String) -> [String] {
        var ips: Set<String> = ["223.5.5.5", "8.8.8.8", "1.1.1.1", "8.8.4.4"]
        guard let data = config.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Array(ips).sorted()
        }
        if let outbounds = root["outbounds"] as? [[String: Any]] {
            for o in outbounds {
                if let server = o["server"] as? String, isIPv4(server) {
                    ips.insert(server)
                }
            }
        }
        return Array(ips).sorted()
    }

    private static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return false }
        for p in parts {
            guard let n = Int(p), (0...255).contains(n) else { return false }
        }
        return true
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        let body = TunnelLog.shared.text()
        completionHandler?(Data(body.utf8))
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
    private let excludeIPv4: [String]

    init(_ tunnel: NEPacketTunnelProvider, excludeIPv4: [String] = []) {
        self.tunnel = tunnel
        self.excludeIPv4 = excludeIPv4
    }

    func stopMonitor() {
        monitor?.cancel()
        monitor = nil
    }

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options, let ret0_ else {
            TunnelLog.shared.add("[ext] openTun 参数为空")
            throw NSError(domain: "CFTunnel", code: 3, userInfo: [NSLocalizedDescriptionKey: "TUN 参数为空"])
        }
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: options.getMTU())

        // 系统 DNS 走公共解析器（IP 已在 excludedRoutes），不依赖隧道内 sing-box DNS
        let dnsSettings = NEDNSSettings(servers: ["223.5.5.5", "8.8.8.8"])
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings
        TunnelLog.shared.add("[ext] openTun mtu=\(options.getMTU()) dns=223.5.5.5,8.8.8.8 (system direct)")

        var v4Addr: [String] = []
        var v4Mask: [String] = []
        if let it = options.getInet4Address() {
            while it.hasNext() {
                if let prefix = it.next() {
                    v4Addr.append(prefix.address())
                    v4Mask.append(prefix.mask())
                }
            }
        }
        if v4Addr.isEmpty {
            v4Addr = ["172.19.0.1"]
            v4Mask = ["255.255.255.252"]
        }
        let v4 = NEIPv4Settings(addresses: v4Addr, subnetMasks: v4Mask)
        v4.includedRoutes = [NEIPv4Route.default()]
        if !excludeIPv4.isEmpty {
            v4.excludedRoutes = excludeIPv4.map { NEIPv4Route(destinationAddress: $0, subnetMask: "255.255.255.255") }
            TunnelLog.shared.add("[ext] excludedRoutes=\(excludeIPv4.joined(separator: ","))")
        }
        settings.ipv4Settings = v4

        let sem = DispatchSemaphore(value: 0)
        var setErr: Error?
        tunnel.setTunnelNetworkSettings(settings) { e in
            setErr = e
            sem.signal()
        }
        let waitResult = sem.wait(timeout: .now() + 8)
        if waitResult == .timedOut {
            TunnelLog.shared.add("[ext] setTunnelNetworkSettings 超时")
            throw NSError(domain: "CFTunnel", code: 8, userInfo: [NSLocalizedDescriptionKey: "设置网络超时"])
        }
        if let setErr {
            TunnelLog.shared.add("[ext] setTunnelNetworkSettings 失败：\(setErr.localizedDescription)")
            throw setErr
        }
        TunnelLog.shared.add("[ext] 网络设置已应用 addr=\(v4Addr.joined(separator: ","))")

        if let fd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32, fd >= 0 {
            ret0_.pointee = fd
            TunnelLog.shared.add("[ext] tun fd=\(fd)（packetFlow）")
            return
        }
        let fd = LibboxGetTunnelFileDescriptor()
        if fd >= 0 {
            ret0_.pointee = fd
            TunnelLog.shared.add("[ext] tun fd=\(fd)（LibboxGetTunnelFileDescriptor）")
        } else {
            TunnelLog.shared.add("[ext] 找不到 TUN 文件描述符")
            throw NSError(domain: "CFTunnel", code: 4, userInfo: [NSLocalizedDescriptionKey: "找不到 TUN 文件描述符"])
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
                if self.lastIfaceIndex != -1 || !self.lastIfaceName.isEmpty {
                    TunnelLog.shared.add("[ext] 默认网卡不可用 (unsatisfied)")
                    self.lastIfaceName = ""
                    self.lastIfaceIndex = -1
                }
                listener?.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
                return
            }

            let preferred = Self.pickInterface(from: path)
            guard let iface = preferred else {
                TunnelLog.shared.add("[ext] path 有状态但无可用网卡 status=\(String(describing: path.status))")
                return
            }

            let name = iface.name
            let index = Int32(iface.index)
            if name == self.lastIfaceName && index == self.lastIfaceIndex { return }
            self.lastIfaceName = name
            self.lastIfaceIndex = index

            let typeDesc: String
            switch iface.type {
            case Network.NWInterface.InterfaceType.wifi: typeDesc = "wifi"
            case Network.NWInterface.InterfaceType.cellular: typeDesc = "cellular"
            case Network.NWInterface.InterfaceType.wiredEthernet: typeDesc = "ethernet"
            case Network.NWInterface.InterfaceType.loopback: typeDesc = "loopback"
            case Network.NWInterface.InterfaceType.other: typeDesc = "other"
            @unknown default: typeDesc = "unknown"
            }
            TunnelLog.shared.add("[ext] 默认网卡 \(name) index=\(index) type=\(typeDesc) expensive=\(path.isExpensive) constrained=\(path.isConstrained)")
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

        func rank(_ iface: Network.NWInterface) -> Int {
            switch iface.type {
            case Network.NWInterface.InterfaceType.wifi: return 0
            case Network.NWInterface.InterfaceType.cellular: return 1
            case Network.NWInterface.InterfaceType.wiredEthernet: return 2
            default: return 5
            }
        }

        var preferred: [Network.NWInterface] = []
        if path.usesInterfaceType(Network.NWInterface.InterfaceType.wifi) {
            preferred = ifaces.filter { $0.type == Network.NWInterface.InterfaceType.wifi }
        } else if path.usesInterfaceType(Network.NWInterface.InterfaceType.cellular) {
            preferred = ifaces.filter { $0.type == Network.NWInterface.InterfaceType.cellular }
        } else if path.usesInterfaceType(Network.NWInterface.InterfaceType.wiredEthernet) {
            preferred = ifaces.filter { $0.type == Network.NWInterface.InterfaceType.wiredEthernet }
        }
        let pool = preferred.isEmpty ? ifaces : preferred
        return pool.sorted { rank($0) < rank($1) }.first
    }

    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        TunnelLog.shared.add("[ext] 关闭默认网卡监听")
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
