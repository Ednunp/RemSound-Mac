import Foundation

struct RouterMappingReply: Equatable {
    let resultCode: UInt16, internalPort: UInt16, externalPort: UInt16
    let lifetime: UInt32, epoch: UInt32
    let externalAddress: String?
}

/// Pure IPv4 UDP mapping codec; transport owns gateway selection, deadlines and request generations.
enum RouterMappingPackets {
    static let gatewayPort: UInt16 = 5351
    static let pcpNonceSize = 12
    static let maximumPcpBytes = 1100
    private static let natVersion: UInt8 = 0
    private static let pcpVersion: UInt8 = 2
    private static let udpOpcode: UInt8 = 1
    private static let responseOpcode: UInt8 = 0x81
    private static let udpProtocol: UInt8 = 17
    private static let pcpMapSize = 60

    static func pcpAnnounceRequest(clientAddress: String) -> Data? {
        guard let client = ipv4(clientAddress) else { return nil }
        return Data([pcpVersion, 0, 0, 0, 0, 0, 0, 0] + mappedIPv4(client))
    }
    static func pcpAnnounceReply(_ data: Data, from: Endpoint, gateway: Endpoint) -> RouterMappingReply? {
        let headerSize = 24
        guard matches(from, gateway), data.count >= headerSize, data.count <= maximumPcpBytes, data.count % 4 == 0 else { return nil }
        let b = [UInt8](data)
        guard b[0] == pcpVersion, b[1] == 0x80, validOptions(b, start: headerSize) else { return nil }
        return .init(resultCode: UInt16(b[3]), internalPort: 0, externalPort: 0, lifetime: 0, epoch: read32(b, 8), externalAddress: nil)
    }
    static func natAddressRequest() -> Data { Data([natVersion, 0]) }
    static func natMapRequest(internalPort: UInt16, suggestedPort: UInt16, lifetime: UInt32) -> Data? {
        guard internalPort > 0 else { return nil }
        var b: [UInt8] = [natVersion, udpOpcode, 0, 0]
        append16(internalPort, to: &b)
        // NAT-PMP lifetime-zero deletion requires a zero suggestion, never port zero internally.
        append16(lifetime == 0 ? 0 : suggestedPort, to: &b)
        append32(lifetime, to: &b)
        return Data(b)
    }
    static func natAddressReply(_ data: Data, from: Endpoint, gateway: Endpoint) -> RouterMappingReply? {
        guard matches(from, gateway), data.count == 12 || data.count == 8 else { return nil }
        let b = [UInt8](data)
        guard b[0] == natVersion, b[1] == 0x80 else { return nil }
        let code = read16(b, 2), epoch = read32(b, 4)
        if b.count == 8 { return code == 1 ? .init(resultCode: code, internalPort: 0, externalPort: 0, lifetime: 0, epoch: epoch, externalAddress: nil) : nil }
        let ip = usableIPv4(Array(b[8..<12]))
        guard code != 0 || ip != nil else { return nil }
        return .init(resultCode: code, internalPort: 0, externalPort: 0, lifetime: 0, epoch: epoch, externalAddress: code == 0 ? ip : nil)
    }
    static func natMapReply(_ data: Data, from: Endpoint, gateway: Endpoint, internalPort: UInt16, deleting: Bool = false) -> RouterMappingReply? {
        guard internalPort > 0, matches(from, gateway), data.count == 16 || data.count == 8 else { return nil }
        let b = [UInt8](data)
        guard b[0] == natVersion, b[1] == responseOpcode else { return nil }
        let code = read16(b, 2), epoch = read32(b, 4)
        // The unsupported-version reply has only the common header, including after a PCP attempt.
        if b.count == 8 { return code == 1 ? .init(resultCode: code, internalPort: internalPort, externalPort: 0, lifetime: 0, epoch: epoch, externalAddress: nil) : nil }
        guard read16(b, 8) == internalPort else { return nil }
        let external = read16(b, 10), lifetime = read32(b, 12)
        guard code != 0 || (deleting ? lifetime == 0 && external == 0 : lifetime > 0 && external > 0) else { return nil }
        return .init(resultCode: code, internalPort: internalPort, externalPort: code == 0 ? external : 0, lifetime: lifetime, epoch: epoch, externalAddress: nil)
    }
    static func pcpMapRequest(clientAddress: String, nonce: Data, internalPort: UInt16, suggestedPort: UInt16,
                              lifetime: UInt32, suggestedAddress: String? = nil) -> Data? {
        guard internalPort > 0, nonce.count == pcpNonceSize, let client = ipv4(clientAddress) else { return nil }
        var b: [UInt8] = [pcpVersion, udpOpcode, 0, 0]
        append32(lifetime, to: &b); b += mappedIPv4(client)
        b += nonce; b += [udpProtocol, 0, 0, 0]
        append16(internalPort, to: &b); append16(suggestedPort, to: &b)
        if let suggestedAddress {
            guard let address = ipv4(suggestedAddress) else { return nil }
            b += mappedIPv4(address)
        } else { b += [UInt8](repeating: 0, count: 16) }
        return Data(b)
    }
    static func pcpMapReply(_ data: Data, from: Endpoint, gateway: Endpoint, nonce: Data,
                            internalPort: UInt16, deleting: Bool = false) -> RouterMappingReply? {
        guard internalPort > 0, nonce.count == pcpNonceSize, matches(from, gateway),
              data.count >= pcpMapSize, data.count <= maximumPcpBytes, data.count % 4 == 0 else { return nil }
        let b = [UInt8](data)
        guard b[0] == pcpVersion, b[1] == responseOpcode,
              Array(b[24..<36]) == [UInt8](nonce), b[36] == udpProtocol, read16(b, 40) == internalPort,
              validOptions(b) else { return nil }
        let code = UInt16(b[3]), lifetime = read32(b, 4), epoch = read32(b, 8), external = read16(b, 42)
        if code != 0 {
            return .init(resultCode: code, internalPort: internalPort, externalPort: 0, lifetime: lifetime, epoch: epoch, externalAddress: nil)
        }
        if deleting, lifetime == 0 { return .init(resultCode: 0, internalPort: internalPort, externalPort: 0, lifetime: 0, epoch: epoch, externalAddress: nil) }
        // A delete may retain the remaining outbound-traffic lifetime (RFC6887 section15).
        // Preserve its actual endpoint/lifetime so the caller cannot claim removal.
        guard lifetime > 0, external > 0 else { return nil }
        // The current audio engine routes IPv4 only; no IPv6-only endpoint is advertised as usable.
        guard Array(b[44..<56]) == [UInt8](repeating: 0, count: 10) + [255, 255],
              let ip = usableIPv4(Array(b[56..<60])) else { return nil }
        return .init(resultCode: 0, internalPort: internalPort, externalPort: external, lifetime: lifetime, epoch: epoch, externalAddress: ip)
    }
    private static func matches(_ source: Endpoint, _ gateway: Endpoint) -> Bool {
        gateway.port == gatewayPort && source == gateway
    }
    private static func validOptions(_ b: [UInt8], start: Int = pcpMapSize) -> Bool {
        var offset = start
        while offset < b.count {
            guard b.count - offset >= 4 else { return false }
            let length = Int(read16(b, offset + 2)), padded = (length + 3) / 4 * 4
            guard padded <= b.count - offset - 4 else { return false }
            // Clients ignore unknown response options in both mandatory and optional ranges.
            offset += 4 + padded
        }
        return true
    }
    static func ipv4(_ value: String) -> [UInt8]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard let byte = UInt8(part), String(byte) == part else { return nil }
            bytes.append(byte)
        }
        return usableIPv4(bytes) != nil ? bytes : nil
    }
    private static func usableIPv4(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 4, bytes[0] > 0, bytes[0] != 127, bytes[0] < 224 else { return nil }
        return bytes.map(String.init).joined(separator: ".")
    }
    private static func mappedIPv4(_ bytes: [UInt8]) -> [UInt8] { [UInt8](repeating: 0, count: 10) + [255, 255] + bytes }
    private static func append16(_ value: UInt16, to b: inout [UInt8]) { b += [UInt8(value >> 8), UInt8(value & 255)] }
    private static func append32(_ value: UInt32, to b: inout [UInt8]) { b += [UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)] }
    private static func read16(_ b: [UInt8], _ offset: Int) -> UInt16 { UInt16(b[offset]) << 8 | UInt16(b[offset + 1]) }
    private static func read32(_ b: [UInt8], _ offset: Int) -> UInt32 { UInt32(read16(b, offset)) << 16 | UInt32(read16(b, offset + 2)) }
}
