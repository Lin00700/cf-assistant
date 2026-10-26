import Foundation
import Network
import NetworkExtension
import Libbox

// VPN 扩展：用 sing-box 的 Libbox 在 NEPacketTunnelProvider 里跑全局代理。
// 按 sing-box 1.11 系列的 Libbox 接口编写；如果 Actions 里升级了版本，下面的接口签名可能需要跟着改。

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

        let platform = TunnelPlatform(self)
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

    init(_ tunnel: NEPacketTunnelProvider) {
        self.tunnel = tunnel
    }

    func stopMonitor() {
        monitor?.cancel()
        monitor = nil
    }

    // MARK: TUN

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options, let ret0_ else {
            TunnelLog.shared.add("[ext] openTun 参数为空")
            throw NSError(domain: "CFTunnel", code: 3, userInfo: [NSLocalizedDescriptionKey: "TUN 参数为空"])
        }
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: options.getMTU())

        var dnsServer = "172.19.0.2"
        do {
            let dns = try options.getDNSServerAddress()
            if !dns.value.isEmpty { dnsServer = dns.value }
        } catch {
            TunnelLog.shared.add("[ext] getDNSServerAddress 失败，用兜底 \(dnsServer): \(error.localizedDescription)")
        }
        let dnsSettings = NEDNSSettings(servers: [dnsServer])
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings
        TunnelLog.shared.add("[ext] openTun mtu=\(options.getMTU()) dns=\(dnsServer)")

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

    // MARK: 平台能力

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
            case .wifi: typeDesc = "wifi"
            case .cellular: typeDesc = "cellular"
            case .wiredEthernet: typeDesc = "ethernet"
            case .loopback: typeDesc = "loopback"
            case .other: typeDesc = "other"
            @unknown default: typeDesc = "unknown"
            }
            TunnelLog.shared.add("[ext] 默认网卡 \(name) index=\(index) type=\(typeDesc) expensive=\(path.isExpensive) constrained=\(path.isConstrained)")
            listener?.updateDefaultInterface(name, interfaceIndex: index,
                                             isExpensive: path.isExpensive, isConstrained: path.isConstrained)
        }
        m.start(queue: DispatchQueue(label: "cf.tunnel.monitor", qos: .userInitiated))
    }

    private static func pickInterface(from path: NWPath) -> NWInterface? {
        let ifaces = path.availableInterfaces
        if ifaces.isEmpty { return nil }

        func rank(_ t: NWInterface.InterfaceType) -> Int {
            switch t {
            case .wifi: return 0
            case .cellular: return 1
            case .wiredEthernet: return 2
            case .other: return 3
            case .loopback: return 9
            @unknown default: return 5
            }
        }

        let filtered: [NWInterface]
        if path.usesInterfaceType(.wifi) {
            filtered = ifaces.filter { $0.type == .wifi }
        } else if path.usesInterfaceType(.cellular) {
            filtered = ifaces.filter { $0.type == .cellular }
        } else if path.usesInterfaceType(.wiredEthernet) {
            filtered = ifaces.filter { $0.type == .wiredEthernet }
        } else {
            filtered = ifaces
        }

        let pool = filtered.isEmpty ? ifaces : filtered
        return pool.sorted { rank($0.type) < rank($1.type) }.first
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
