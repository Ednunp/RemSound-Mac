#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

@testable import RemSoundJam

/// A UDP socket for the live tests, on the Mac and on Windows alike (the app has its own, `UDP`, on the Mac). Receives
/// with a 1 ms timeout, so a pump loop never blocks.
final class TestUDP {
    #if os(Windows)
    private let fd: SOCKET
    private static let started: Bool = {
        var data = WSADATA()
        return WSAStartup(0x0202, &data) == 0
    }()
    #else
    private let fd: Int32
    #endif
    private var buffer = [UInt8](repeating: 0, count: 65536)
    let port: UInt16

    init(port: UInt16 = 0) {
        #if os(Windows)
        _ = Self.started
        let fd = socket(AF_INET, SOCK_DGRAM, Int32(IPPROTO_UDP.rawValue))
        #else
        let fd = socket(AF_INET, Int32(SOCK_DGRAM), 0)
        #endif
        self.fd = fd
        var addr = sockaddr_in()
        #if os(Windows)
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        #else
        addr.sin_family = sa_family_t(AF_INET)
        #endif
        addr.sin_port = port.bigEndian
        _ = inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #if os(Windows)
        var timeout: DWORD = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, withUnsafeBytes(of: &timeout) { $0.baseAddress!.assumingMemoryBound(to: CChar.self) },
                       Int32(MemoryLayout<DWORD>.size))
        #else
        var timeout = timeval(tv_sec: 0, tv_usec: 1000)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #endif
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.port = UInt16(bigEndian: bound.sin_port)
    }

    func send(_ bytes: [UInt8], to endpoint: JamEndpoint) {
        var addr = sockaddr_in()
        #if os(Windows)
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        #else
        addr.sin_family = sa_family_t(AF_INET)
        #endif
        addr.sin_port = endpoint.port.bigEndian
        _ = inet_pton(AF_INET, endpoint.address, &addr.sin_addr)
        bytes.withUnsafeBytes { raw in
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { to in
                    #if os(Windows)
                    sendto(fd, raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(bytes.count), 0, to, Int32(MemoryLayout<sockaddr_in>.size))
                    #else
                    sendto(fd, raw.baseAddress!, bytes.count, 0, to, socklen_t(MemoryLayout<sockaddr_in>.size))
                    #endif
                }
            }
        }
    }

    func receive() -> ([UInt8], JamEndpoint)? {
        var from = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = buffer.withUnsafeMutableBytes { raw in
            withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { f in
                    #if os(Windows)
                    Int(recvfrom(fd, raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count), 0, f, &length))
                    #else
                    recvfrom(fd, raw.baseAddress!, raw.count, 0, f, &length)
                    #endif
                }
            }
        }
        guard count > 0 else { return nil }
        var text = [CChar](repeating: 0, count: 32)
        var ip = from.sin_addr
        _ = inet_ntop(AF_INET, &ip, &text, 32)
        return (Array(buffer[0..<count]), JamEndpoint(String(cString: text), UInt16(bigEndian: from.sin_port)))
    }

    func close() {
        #if os(Windows)
        closesocket(fd)
        #elseif canImport(Darwin)
        _ = Darwin.close(fd)
        #else
        _ = Glibc.close(fd)
        #endif
    }
}
