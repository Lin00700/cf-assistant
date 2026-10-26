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

    func add(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(s)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
    }

    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var service: LibboxBoxService?
    private var platform: TunnelPlatform?

    override func startTunnel(options: [String: NSObject]?) async throws {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let config = proto.providerConfiguration?["config"] as? String, !config.isEmpty else {
            throw NSError(domain: "CFTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少 sing-box 配置"])
        }

        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let work = base.appendingPathComponent("work", isDirectory: true)
        let temp = base.appendingPathComponent("tmp", isDirectory: true)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        try? fm.createDirectory(at: temp, withIntermediateDirectories: true)

        TunnelLog.shared.add("[ext] startTunnel, 配置 \(config.count) 字节")
        LibboxSetup(base.path, work.path, temp.path, false)

        let platform = TunnelPlatform(self)
        self.platform = platform

        var err: NSError?
        let svc = LibboxNewService(config, platform, &err)
        if let err { throw err }
        guard let svc else {
            throw NSError(domain: "CFTunnel", code: 2, userInfo: [NSLocalizedDescriptionKey: "sing-box 服务创建失败"])
        }
        try svc.start()
        service = svc
        TunnelLog.shared.add("[ext] sing-box 已启动")
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        completionHandler?(Data(TunnelLog.shared.text().utf8))
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        try? service?.close()
        service = nil
        platform?.stopMonitor()
        platform = nil
    }
}

final class TunnelPlatform: NSObject, LibboxPlatformInterfaceProtocol {
    private unowned let tunnel: NEPacketTunnelProvider
    private var monitor: NWPathMonitor?

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
            throw NSError(domain: "CFTunnel", code: 3, userInfo: [NSLocalizedDescriptionKey: "TUN 参数为空"])
        }
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: options.getMTU())

        let dns = try options.getDNSServerAddress()
        let dnsSettings = NEDNSSettings(servers: [dns.value])
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings
        TunnelLog.shared.add("[ext] openTun mtu=\(options.getMTU()) dns=\(dns.value)")

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
        if v4Addr.isEmpty { v4Addr = ["172.19.0.1"]; v4Mask = ["255.255.255.252"] }
        let v4 = NEIPv4Settings(addresses: v4Addr, subnetMasks: v4Mask)
        v4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = v4

        let sem = DispatchSemaphore(value: 0)
        var setErr: Error?
        tunnel.setTunnelNetworkSettings(settings) { e in
            setErr = e
            sem.signal()
        }
        sem.wait()
        if let setErr {
            TunnelLog.shared.add("[ext] setTunnelNetworkSettings 失败：\(setErr.localizedDescription)")
            throw setErr
        }
        TunnelLog.shared.add("[ext] 网络设置已应用 addr=\(v4Addr.joined(separator: ","))")

        if let fd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = fd
            TunnelLog.shared.add("[ext] tun fd=\(fd)（packetFlow）")
            return
        }
        let fd = LibboxGetTunnelFileDescriptor()
        if fd >= 0 {
            ret0_.pointee = fd
            TunnelLog.shared.add("[ext] tun fd=\(fd)（LibboxGetTunnelFileDescriptor）")
        } else {
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
        NSLog("sing-box: %@", message ?? "")
        TunnelLog.shared.add(message ?? "")
    }

    func usePlatformDefaultInterfaceMonitor() -> Bool { true }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        let m = NWPathMonitor()
        monitor = m
        m.pathUpdateHandler = { path in
            if path.status == .unsatisfied {
                listener?.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
                return
            }
            guard let iface = path.availableInterfaces.first else { return }
            TunnelLog.shared.add("[ext] 默认网卡 \(iface.name) index=\(iface.index)")
            listener?.updateDefaultInterface(iface.name, interfaceIndex: Int32(iface.index),
                                             isExpensive: path.isExpensive, isConstrained: path.isConstrained)
        }
        m.start(queue: DispatchQueue(label: "cf.tunnel.monitor"))
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
}
