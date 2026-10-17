import Foundation

/// An IPv4 address and port, as text: the Mac app's `Endpoint` converts to and from it.
public struct JamEndpoint: Hashable, CustomStringConvertible, Sendable {
    public var address: String
    public var port: UInt16
    public init(_ address: String, _ port: UInt16 = JamWire.defaultPort) {
        self.address = address
        self.port = port
    }
    public var description: String { "\(address):\(port)" }
}

/// The parts of RemSound's wire this package needs, exactly as the Windows RemSound and the relay have them.
///
/// Every packet starts with the ordinary 12-byte header: "RMND", version 1, type, stream (u16), sequence (u32), all
/// little-endian. A relay group packet is the same header with version 2, then the sender's 16-byte client id (a UUID in
/// its usual byte order), then the payload untouched: 28 bytes before the payload.
public enum JamWire {
    public static let defaultPort: UInt16 = 47830
    public static let magic: [UInt8] = Array("RMND".utf8)
    public static let headerSize = 12
    public static let version: UInt8 = 1
    public static let groupVersion: UInt8 = 2
    public static let clientIdSize = 16
    public static let groupHeaderSize = headerSize + clientIdSize
    public static let fingerprintSize = 8

    /// The packet types (byte 5 of the header).
    public enum Kind: UInt8 {
        case format = 1, audio = 2, keepAlive = 3, heartbeat = 4, control = 5
        case hello = 6, roster = 7, full = 8, bye = 9, addressCheck = 10, tickProof = 11
        case metronome = 12, timing = 13, serverInfo = 14, serverPing = 15
    }

    /// The ordinary header, with version 1 (or 2 for the relay's group framing).
    public static func header(_ kind: UInt8, stream: UInt16 = 0, sequence: UInt32 = 0, version: UInt8 = version) -> [UInt8] {
        var h = magic
        h.append(version)
        h.append(kind)
        h.appendLE(stream)
        h.appendLE(sequence)
        return h
    }

    /// True when the bytes start with RemSound's header: the magic and at least the 12 bytes.
    public static func hasHeader(_ packet: [UInt8]) -> Bool {
        packet.count >= headerSize && packet[0] == magic[0] && packet[1] == magic[1] && packet[2] == magic[2] && packet[3] == magic[3]
    }

    /// A relay's address check: the relay sends one to prove it can reach the address a client claims, and the client
    /// sends it straight back, exactly as it came - not group-framed. Until it has, a relay that enforces the check passes
    /// that client nothing at all. (The Mac app before 0.1.48 ignored these, so it could never have joined a group.)
    public static func isAddressCheck(_ packet: [UInt8]) -> Bool {
        hasHeader(packet) && packet[4] == version && packet[5] == Kind.addressCheck.rawValue
    }

    /// True for an address in 240.0.0.0/5, the reserved block a relay group member's address here is drawn from. Such an
    /// address never reaches the wire.
    public static func isMemberAddress(_ address: String) -> Bool {
        guard let first = address.split(separator: ".").first, let octet = Int(first) else { return false }
        return octet >= 240 && octet <= 247
    }

    /// A UUID's 16 bytes in their usual (big-endian) order, as the relay and the Windows app write a client id.
    public static func bytes(of id: UUID) -> [UInt8] {
        withUnsafeBytes(of: id.uuid) { Array($0) }
    }

    public static func uuid(from bytes: ArraySlice<UInt8>) -> UUID {
        let b = [UInt8](bytes)
        precondition(b.count == 16)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

extension Array where Element == UInt8 {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size { value |= T(truncatingIfNeeded: self[offset + i]) << (8 * i) }
        return value
    }
}

/// The same machine reached twice, on your network and through the server (Windows MainForm, the duplicate-route note):
/// rows grouped by name, ignoring case and the server's " (on the server)", and each told about the other.
public enum SameMachineTwice {
    public static let serverSuffix = " (on the server)"
    public static let onServerNote = "same machine twice, also connected on your network"
    public static let onNetworkNote = "same machine twice, also connected through the server"

    /// The note for each row's address that has a twin on the other route.
    public static func notes(_ rows: [(address: String, name: String, onServer: Bool)]) -> [String: String] {
        func base(_ name: String) -> String {
            (name.hasSuffix(serverSuffix) ? String(name.dropLast(serverSuffix.count)) : name).lowercased()
        }
        let groups = Dictionary(grouping: rows) { base($0.name) }
        var result: [String: String] = [:]
        for (_, group) in groups where group.contains(where: \.onServer) && group.contains(where: { !$0.onServer }) {
            for row in group { result[row.address] = row.onServer ? onServerNote : onNetworkNote }
        }
        return result
    }
}
