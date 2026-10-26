import Foundation
import Network
import NetworkExtension
import UserNotifications
import Compression
import Libbox

// VPN 扩展：用 sing-box 的 Libbox 在 NEPacketTunnelProvider 里跑全局代理。
// 按 sing-box 1.11 系列的 Libbox 接口编写；如果 Actions 里升级了版本，下面的接口签名可能需要跟着改。

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var service: LibboxBoxService?
    private var platform: TunnelPlatform?

    override func startTunnel(options: [String: NSObject]?) async throws {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol else {
            throw NSError(domain: "CFTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少 sing-box 配置"])
        }
        let providerConfiguration = proto.providerConfiguration ?? [:]
        let config: String
        if let compressedConfig = providerConfiguration["configCompressed"] as? Data {
            guard let decodedConfig = Self.decompressConfig(compressedConfig) else {
                throw NSError(domain: "CFTunnel", code: 8, userInfo: [NSLocalizedDescriptionKey: "VPN 配置解压失败"])
            }
            config = decodedConfig
        } else if let legacyConfig = providerConfiguration["config"] as? String, !legacyConfig.isEmpty {
            config = legacyConfig
        } else {
            throw NSError(domain: "CFTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少 sing-box 配置"])
        }

        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let work = base.appendingPathComponent("work", isDirectory: true)
        let temp = base.appendingPathComponent("tmp", isDirectory: true)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        try? fm.createDirectory(at: temp, withIntermediateDirectories: true)

        let setupOptions = LibboxSetupOptions()
        setupOptions.basePath = base.path
        setupOptions.workingPath = work.path
        setupOptions.tempPath = temp.path
        var setupError: NSError?
        LibboxSetup(setupOptions, &setupError)
        if let setupError { throw setupError }

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
    }

    private static func decompressConfig(_ payload: Data) -> String? {
        let headerSize = MemoryLayout<UInt64>.size
        guard payload.count > headerSize else { return nil }
        let uncompressedSize = payload.prefix(headerSize).reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
        guard uncompressedSize > 0, uncompressedSize <= 16 * 1024 * 1024 else { return nil }

        let compressed = Data(payload.dropFirst(headerSize))
        var output = Data(count: Int(uncompressedSize))
        let scratchSize = compression_decode_scratch_buffer_size(COMPRESSION_ZLIB)
        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: max(1, scratchSize), alignment: MemoryLayout<UInt8>.alignment
        )
        defer { scratch.deallocate() }

        let decodedSize = compressed.withUnsafeBytes { sourceBuffer -> Int in
            guard let sourceBytes = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return output.withUnsafeMutableBytes { destinationBuffer -> Int in
                guard let destinationBytes = destinationBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBytes, destinationBuffer.count,
                    sourceBytes, sourceBuffer.count, scratch, COMPRESSION_ZLIB
                )
            }
        }
        guard decodedSize == Int(uncompressedSize) else { return nil }
        return String(data: output, encoding: .utf8)
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
        settings.dnsSettings = NEDNSSettings(servers: [dns.value])

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
        var v4Routes: [NEIPv4Route] = []
        if let it = options.getInet4RouteAddress() {
            while it.hasNext() {
                if let prefix = it.next() {
                    v4Routes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
                }
            }
        }
        if v4Routes.isEmpty { v4Routes = [NEIPv4Route.default()] }
        v4.includedRoutes = v4Routes
        var v4ExcludedRoutes: [NEIPv4Route] = []
        if let it = options.getInet4RouteExcludeAddress() {
            while it.hasNext() {
                if let prefix = it.next() {
                    v4ExcludedRoutes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
                }
            }
        }
        v4.excludedRoutes = v4ExcludedRoutes
        settings.ipv4Settings = v4

        var v6Addr: [String] = []
        var v6Prefixes: [NSNumber] = []
        if let it = options.getInet6Address() {
            while it.hasNext() {
                if let prefix = it.next() {
                    v6Addr.append(prefix.address())
                    v6Prefixes.append(NSNumber(value: prefix.prefix()))
                }
            }
        }
        if !v6Addr.isEmpty {
            let v6 = NEIPv6Settings(addresses: v6Addr, networkPrefixLengths: v6Prefixes)
            var v6Routes: [NEIPv6Route] = []
            if let it = options.getInet6RouteAddress() {
                while it.hasNext() {
                    if let prefix = it.next() {
                        v6Routes.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix())))
                    }
                }
            }
            if v6Routes.isEmpty { v6Routes = [NEIPv6Route.default()] }
            v6.includedRoutes = v6Routes
            var v6ExcludedRoutes: [NEIPv6Route] = []
            if let it = options.getInet6RouteExcludeAddress() {
                while it.hasNext() {
                    if let prefix = it.next() {
                        v6ExcludedRoutes.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix())))
                    }
                }
            }
            v6.excludedRoutes = v6ExcludedRoutes
            settings.ipv6Settings = v6
        }

        let sem = DispatchSemaphore(value: 0)
        var setErr: Error?
        tunnel.setTunnelNetworkSettings(settings) { e in
            setErr = e
            sem.signal()
        }
        sem.wait()
        if let setErr { throw setErr }

        if let fd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = fd
            return
        }
        let fd = LibboxGetTunnelFileDescriptor()
        if fd >= 0 {
            ret0_.pointee = fd
        } else {
            throw NSError(domain: "CFTunnel", code: 4, userInfo: [NSLocalizedDescriptionKey: "找不到 TUN 文件描述符"])
        }
    }

    // MARK: 平台能力

    // Let sing-box bind sockets via the interface monitor; claiming platform
    // control while autoDetectControl is a no-op can leave node traffic unbound.
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
    }

    func usePlatformDefaultInterfaceMonitor() -> Bool { true }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        let m = NWPathMonitor()
        monitor = m
        let initialPathUpdate = DispatchSemaphore(value: 0)
        m.pathUpdateHandler = { path in
            defer { initialPathUpdate.signal() }
            if path.status == .unsatisfied {
                listener?.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
                return
            }
            guard let iface = path.availableInterfaces.first else {
                listener?.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
                return
            }
            listener?.updateDefaultInterface(iface.name, interfaceIndex: Int32(iface.index),
                                             isExpensive: path.isExpensive, isConstrained: path.isConstrained)
        }
        m.start(queue: DispatchQueue(label: "cf.tunnel.monitor"))
        initialPathUpdate.wait()
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

    func send(_ notification: LibboxNotification?) throws {
        guard let notification else { return }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        if !notification.openURL.isEmpty {
            content.userInfo["OPEN_URL"] = notification.openURL
            content.categoryIdentifier = "OPEN_URL"
        }
        content.interruptionLevel = .active

        let request = UNNotificationRequest(
            identifier: notification.identifier,
            content: content,
            trigger: nil
        )
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                NSLog("sing-box notification permission failed: %@", error.localizedDescription)
                return
            }
            guard granted else { return }
            center.add(request) { addError in
                if let addError {
                    NSLog("sing-box notification failed: %@", addError.localizedDescription)
                }
            }
        }
    }
}
