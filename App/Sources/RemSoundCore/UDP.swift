import Darwin
import Foundation
import SystemConfiguration

// Route selection is read on a utility worker, not the session or audio callback. Connecting
// a spare UDP socket selects a source address without emitting a network packet.
struct NetworkRoute: Equatable {
    let sourceAddress: String, interface: String, interfaceType: String

    static func read(to endpoint: Endpoint) -> NetworkRoute? {
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = endpoint.port.bigEndian
        guard inet_pton(AF_INET, endpoint.address, &remote.sin_addr) == 1 else { return nil }
        let probe = socket(AF_INET, SOCK_DGRAM, 0)
        guard probe >= 0 else { return nil }
        defer { Darwin.close(probe) }
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in(), size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(probe, $0, &size) }
        }
        guard result == 0 else { return nil }
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var current = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
                    == local.sin_addr.s_addr else { continue }
            let name = String(cString: item.pointee.ifa_name)
            var chars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &local.sin_addr, &chars, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
            let type = interfaces.first { (SCNetworkInterfaceGetBSDName($0) as String?) == name }
                .flatMap { SCNetworkInterfaceGetInterfaceType($0) as String? }
            let fallback = item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) != 0 ? "Loopback"
                : item.pointee.ifa_flags & UInt32(IFF_POINTOPOINT) != 0 ? "Point-to-point (type unavailable)"
                : "type unavailable"
            return NetworkRoute(sourceAddress: String(cString: chars), interface: name,
                interfaceType: type ?? fallback)
        }
        return nil
    }

    var description: String { "\(interface) (\(interfaceType)), source \(sourceAddress)" }
}

struct Endpoint: Hashable {
    var address: String
    var port: UInt16
    var bytes: Data {
        var ip = in_addr()
        inet_pton(AF_INET, address, &ip)
        return withUnsafeBytes(of: &ip.s_addr) { Data($0) }
    }
    init(_ address: String, _ port: UInt16 = Wire.audioPort) {
        self.address = address
        self.port = port
    }
    static func resolve(_ host: String, port: UInt16 = Wire.audioPort) throws -> Endpoint {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let entry = list else {
            throw ProtocolError.invalid("Cannot resolve the peer address.")
        }
        defer { freeaddrinfo(list) }
        let addr = UnsafeRawPointer(entry.pointee.ai_addr).assumingMemoryBound(to: sockaddr_in.self).pointee
        var ip = addr.sin_addr
        var chars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &ip, &chars, socklen_t(INET_ADDRSTRLEN))
        return Endpoint(String(cString: chars), port)
    }
    func isOnDirectSubnet() -> Bool {
        var remote = in_addr()
        guard inet_pton(AF_INET, address, &remote) == 1 else { return false }
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return false }
        defer { freeifaddrs(first) }
        var current = first
        while let item = current {
            let interface = item.pointee
            if interface.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                let address = interface.ifa_addr, let mask = interface.ifa_netmask,
                address.pointee.sa_family == sa_family_t(AF_INET),
                mask.pointee.sa_family == sa_family_t(AF_INET) {
                let local = UnsafeRawPointer(address)
                    .assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
                let subnet = UnsafeRawPointer(mask)
                    .assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
                if (remote.s_addr & subnet) == (local & subnet) { return true }
            }
            current = interface.ifa_next
        }
        return false
    }
}

final class UDP {
    let fd: Int32
    private var scratch = [UInt8](repeating: 0, count: 65536)
    var boundPort: UInt16 {
        var addr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return UInt16(bigEndian: addr.sin_port)
    }
    var boundAddress: String? {
        var addr = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard status == 0 else { return nil }
        var chars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr.sin_addr, &chars, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: chars)
    }
    /// Whether outgoing packets are marked as voice (see init).
    let voicePriority: Bool
    /// What has gone out and come in through this socket, for the Connection status box's traffic lines.
    private(set) var bytesSent: Int64 = 0
    private(set) var bytesReceived: Int64 = 0
    init(port: UInt16, loopback: Bool = false, broadcast: Bool = false, localAddress: String? = nil) throws {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if let localAddress {
            guard (!loopback || localAddress == "127.0.0.1"), inet_pton(AF_INET, localAddress, &addr.sin_addr) == 1 else {
                throw ProtocolError.invalid("Invalid or conflicting local UDP address.")
            }
        } else { addr.sin_addr.s_addr = loopback ? inet_addr("127.0.0.1") : INADDR_ANY }
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw ProtocolError.invalid("Could not open a UDP socket.") }
        if broadcast {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout.size(ofValue: on)))
        }
        // Voice priority for what goes out (Windows NetworkPriority: the send socket in qWAVE's Voice flow, always on, no
        // setting). Apple's way is the socket's network service type: Interactive Voice, which marks it DSCP 46 (EF) and
        // Wi-Fi's voice queue. A refusal changes nothing else.
        if !loopback {
            var service = NET_SERVICE_TYPE_VO
            voicePriority = setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &service,
                socklen_t(MemoryLayout.size(ofValue: service))) == 0
        } else { voicePriority = false }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw ProtocolError.invalid("UDP port \(port) is unavailable: \(message)")
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    }
    deinit { Darwin.close(fd) }
    @discardableResult func send(_ data: Data, to endpoint: Endpoint) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = endpoint.port.bigEndian
        inet_pton(AF_INET, endpoint.address, &addr.sin_addr)
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent > 0 { bytesSent += Int64(sent) }
        return sent == data.count
    }
    func receive() -> (Data, Endpoint)? {
        var addr = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, &scratch, 65536, 0, $0, &size)
            }
        }
        guard n > 0 else { return nil }
        bytesReceived += Int64(n)
        var ip = addr.sin_addr
        var chars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &ip, &chars, socklen_t(INET_ADDRSTRLEN))
        return (Data(scratch.prefix(n)), Endpoint(String(cString: chars), UInt16(bigEndian: addr.sin_port)))
    }
}
