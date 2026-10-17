import AudioSupport
import CryptoKit
import Foundation

public enum Wire {
    public static let audioPort: UInt16 = 47830
    public static let discoveryPort: UInt16 = 47821
    public static let bridgePort: UInt16 = 47831
    public static let sampleRate = 48000
    public static let headerSize = 12
    public static let maxAudioPayload = 1454
    public static let discoveryInterval = 1.5
    public static let discoveryExpiry = 8.0
    public static let maximumDiscoveryNameCharacters = 128
    public static let pcmFrames = 233
    public static let fingerprintSize = 8
    public static let heartbeatPayloadSize = 9
    public enum Kind: UInt8 {
        case format = 1, audio, keepAlive, heartbeat, control, addressCheck = 10, tickProof, metronome
    }
    public struct Packet {
        public let kind: Kind
        public let stream: UInt16
        public let sequence: UInt32
        public let payload: Data
    }
    public static func packet(_ kind: Kind, stream: UInt16 = 1, sequence: UInt32 = 0, payload: Data) -> Data {
        var d = Data([0x52, 0x4d, 0x4e, 0x44, 1, kind.rawValue])
        d.put(stream == 0 ? UInt16(1) : stream)
        d.put(sequence)
        d.append(payload)
        return d
    }
    public static func parse(_ d: Data) -> Packet? {
        guard d.count >= headerSize, Array(d.prefix(5)) == [0x52, 0x4d, 0x4e, 0x44, 1],
            let kind = Kind(rawValue: d[5])
        else { return nil }
        return Packet(
            kind: kind, stream: max(1, d.u16(6)), sequence: d.u32(8), payload: Data(d.dropFirst(headerSize)))
    }
}

extension Data {
    public mutating func put<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    public func u16(_ o: Int) -> UInt16 { UInt16(self[o]) | UInt16(self[o + 1]) << 8 }
    public func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
    public func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | UInt64(u32(o + 4)) << 32 }
}

public struct Credentials {
    public let key: SymmetricKey
    public let fingerprint: Data
    public init(password: String) throws {
        guard !password.isEmpty else {
            throw ProtocolError.invalid("Enter a shared password before connecting.")
        }
        func derive(_ salt: String, _ count: Int) throws -> Data {
            var output = [UInt8](repeating: 0, count: count)
            let status = password.withCString { p in
                salt.withCString { s in rs_derive(p, password.utf8.count, s, &output, count) }
            }
            guard status == 0 else { throw ProtocolError.invalid("Password derivation failed.") }
            return Data(output)
        }
        key = SymmetricKey(data: try derive("RemSound.v1.audio-key", 32))
        fingerprint = try derive("RemSound.v1.fingerprint", 8)
    }
    public func seal(_ plain: Data) throws -> Data {
        let box = try AES.GCM.seal(plain, using: key)
        // CryptoKit's combined layout differs from RemSound: nonce, tag, ciphertext.
        return box.nonce.withUnsafeBytes { Data($0) } + box.tag + box.ciphertext
    }
    public func open(_ wire: Data) throws -> Data {
        guard wire.count >= 28 else { throw ProtocolError.invalid("Truncated encrypted packet") }
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: wire.prefix(12)), ciphertext: wire.dropFirst(28), tag: wire[12..<28])
        return try AES.GCM.open(box, using: key)
    }
    public func tick(id: UUID, now: Int64, sequence: UInt32) throws -> Data {
        let plain=TickProofPayload.encode(id:id,unixSeconds:now)
        return Wire.packet(.tickProof, stream: 0xffff, sequence: sequence, payload: try seal(plain))
    }
}
public enum ProtocolError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        if case .invalid(let s) = self { return s }
        return nil
    }
}

public struct StreamFormat: Equatable {
    public enum Lane: UInt8 {
        case mixed = 0
        case wasapi = 1
        case asio = 2
    }
    public enum Codec: Int {
        case pcm = 1
        case opus = 2
        /// Jamulus-style Opus: custom-mode 64- or 128-sample frames (see RemSoundJam's JamulusStyle).
        case opusCustom = 3
    }
    public var channels: Int
    public var bits: Int
    public var encoding: Int
    public var codec: Int
    public var frames: Int
    public var fingerprint: Data
    /// Byte 33: bit 0 says the sender can play Jamulus-style frames (the Windows latency lab's flag).
    public var labFlags: UInt8 = 0
    public var lane: Lane = .mixed
    /// Zero means not stated; the optional wire field uses tenths of a millisecond.
    public var captureLatencyMs: Double = 0
    public func capturing(milliseconds: Double) -> StreamFormat {
        var copy=self;copy.captureLatencyMs=milliseconds;return copy
    }
    func sameDecodingConfiguration(as other: StreamFormat) -> Bool {
        var left=self,right=other
        left.captureLatencyMs=0;right.captureLatencyMs=0;left.lane = .mixed;right.lane = .mixed
        return left == right
    }
    public func flagged(_ flags: UInt8) -> StreamFormat {
        var f = self
        f.labFlags = flags
        return f
    }
    public static func opusCustom(_ fingerprint: Data, frames: Int) -> StreamFormat {
        StreamFormat(channels: 2, bits: 16, encoding: 1, codec: Codec.opusCustom.rawValue, frames: frames,
            fingerprint: fingerprint, labFlags: 1)
    }
    public static func pcm(_ fingerprint: Data, frames: Int = Wire.pcmFrames) -> StreamFormat {
        StreamFormat(
            channels: 2, bits: 24, encoding: 1, codec: Codec.pcm.rawValue, frames: frames,
            fingerprint: fingerprint)
    }
    public static func opus(_ fingerprint: Data, frames: Int) -> StreamFormat {
        StreamFormat(channels: 2, bits: 16, encoding: 1, codec: Codec.opus.rawValue,
            frames: frames, fingerprint: fingerprint)
    }
    public func encode() -> Data { encode(lane:lane) }
    public func encode(lane: Lane) -> Data {
        var d = Data()
        for value in [
            48000, channels, bits, encoding, channels * bits / 8, 48000 * channels * bits / 8, codec, frames,
        ] { d.put(Int32(value)) }
        d.append(contentsOf: [lane.rawValue, labFlags, 0, 0])
        guard fingerprint.count == Wire.fingerprintSize else { return d }
        d.append(fingerprint)
        let ticks=captureLatencyMs.isFinite ? max(0,captureLatencyMs)*Self.captureTicksPerMs : 0
        let bounded=min(Double(UInt16.max),ticks)
        d.put(UInt16(bounded.rounded(.toNearestOrEven)))
        return d
    }
    private static let legacyPayloadSize=32, extendedPayloadSize=36
    private static let fingerprintPayloadSize=44, capturePayloadSize=46
    private static let captureTicksPerMs = 10.0
    public static func parse(_ payload: Data) -> StreamFormat? {
        guard payload.count >= legacyPayloadSize else { return nil }
        let d=Data(payload.prefix(capturePayloadSize))
        guard d.u32(0) == 48000 else { return nil }
        let channels = Int(d.u32(4))
        let bits = Int(d.u32(8))
        let encoding = Int(d.u32(12))
        let codec = Int(d.u32(24))
        let frames = Int(d.u32(28))
        guard (1...2).contains(channels), (1...2880).contains(frames), Codec(rawValue: codec) != nil else {
            return nil
        }
        // The custom decoder always produces stereo and supports these frame sizes.
        guard codec != Codec.opusCustom.rawValue || (channels == 2 && [64, 128].contains(frames)) else { return nil }
        guard
            codec == Codec.opus.rawValue || codec == Codec.opusCustom.rawValue
                || (encoding == 1 && [16, 24, 32].contains(bits))
                || (encoding == 3 && bits == 32)
        else { return nil }
        return StreamFormat(
            channels: channels, bits: bits, encoding: encoding, codec: codec, frames: frames,
            fingerprint: d.count >= fingerprintPayloadSize ? Data(d[extendedPayloadSize..<fingerprintPayloadSize]) : Data(),
            labFlags: d.count >= extendedPayloadSize ? d[33] : 0,
            lane: d.count >= extendedPayloadSize ? (Lane(rawValue:d[32]) ?? .mixed) : .mixed,
            captureLatencyMs: d.count >= capturePayloadSize ? Double(d.u16(fingerprintPayloadSize))/captureTicksPerMs : 0)
    }
}

// Shared with Session's real dispatchers; these decode values, never grant peer admission.
enum HeartbeatPayload {
    enum Kind: UInt8 { case ping, pong }
    static func encode(_ kind: Kind, tickMs: UInt64, flags: UInt8 = 0) -> Data {
        var bytes=Data([kind.rawValue]);bytes.put(tickMs)
        if flags != 0 { bytes.append(flags) }
        return bytes
    }
    static func parse(_ payload: Data) -> (kind: Kind, tickMs: UInt64, flags: UInt8)? {
        guard payload.count >= Wire.heartbeatPayloadSize else { return nil }
        let bytes=Data(payload.prefix(Wire.heartbeatPayloadSize+1))
        guard let kind=Kind(rawValue:bytes[0]) else { return nil }
        return (kind,bytes.u64(1),bytes.count > Wire.heartbeatPayloadSize ? bytes[Wire.heartbeatPayloadSize] : 0)
    }
}
enum TickProofPayload {
    static let plaintextBytes=25, sealedBytes=53
    static func encode(id: UUID, unixSeconds: Int64) -> Data {
        var bytes=Data([1]);bytes.put(unixSeconds);var uuid=id.uuid
        Swift.withUnsafeBytes(of:&uuid) { bytes.append(contentsOf:$0) }
        return bytes
    }
    static func parse(_ payload: Data) -> (id: UUID, unixSeconds: Int64)? {
        guard payload.count == plaintextBytes else { return nil }
        let bytes=Data(payload);guard bytes[0] == 1 else { return nil }
        var uuid=UUID().uuid
        withUnsafeMutableBytes(of:&uuid) { $0.copyBytes(from:bytes[9..<25]) }
        return (UUID(uuid:uuid),Int64(bitPattern:bytes.u64(1)))
    }
}

public struct Announcement: Codable, Equatable {
    public let InstanceId: UUID
    public let Name: String
    public let AudioPort: UInt16
    public let CanSend: Bool
    public let CanReceive: Bool
    public init(id: UUID, name: String, port: UInt16 = Wire.audioPort, send: Bool, receive: Bool) {
        InstanceId = id
        Name = name
        AudioPort = port
        CanSend = send
        CanReceive = receive
    }
}

public enum Bridge {
    public static let headerSize = 16, maxAudioBytes = 32768, maxFrames = 16384, channels = 2,
        sampleRate = 48000, maxPeers = 32, roundHeaderSize = 20
    public enum Kind: UInt8 {
        case hello = 1, releasePeer = 3, trackAudio = 4, goodbye = 6, peerList = 7, claimPeers = 8,
            peerAudioRound = 9, hostCallback = 10
    }
    public struct Packet {
        public let kind: Kind
        public let instance: UInt32
        public let peer: Data
        public let payload: Data
    }
    public static func encode(
        _ kind: Kind, instance: UInt32, peer: Data = Data(repeating: 0, count: 4), payload: Data = Data()
    ) -> Data {
        precondition(payload.count <= maxAudioBytes && peer.count == 4)
        var d = Data([82, 83, 66, 82, 1, kind.rawValue])
        d.put(UInt16(payload.count))
        d.put(instance)
        d.append(peer)
        d.append(payload)
        return d
    }
    public static func parse(_ d: Data) -> Packet? {
        guard d.count >= 16, Array(d.prefix(5)) == [82, 83, 66, 82, 1], let kind = Kind(rawValue: d[5]) else {
            return nil
        }
        let n = Int(d.u16(6))
        guard n <= maxAudioBytes, d.count == 16 + n else { return nil }
        return Packet(kind: kind, instance: d.u32(8), peer: Data(d[12..<16]), payload: Data(d.dropFirst(16)))
    }
    public static func claim(_ d: Data) -> (frames: Int, peers: [Data], ask: UInt32)? {
        guard d.count >= 9 else { return nil }
        let n = Int(d[4])
        let f = Int(d.u32(0))
        guard n <= maxPeers, d.count == 9 + n * 4, (1...maxFrames).contains(f) else { return nil }
        return (f, (0..<n).map { Data(d[(5 + $0 * 4)..<(9 + $0 * 4)]) }, d.u32(5 + n * 4))
    }
}

// Internal audio path only: the same fresh random nonce initializer as automatic CryptoKit sealing.
extension Credentials {
    func sealAudio(_ plain: Data, diagnostics: inout SendWorkDiagnostics) throws -> Data {
        guard diagnostics.enabled else { return try seal(plain) }
        let nonceBegan = diagnostics.begin()
        let nonce = AES.GCM.Nonce()
        diagnostics.note(.nonce, began: nonceBegan)
        let sealBegan = diagnostics.begin()
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce)
        diagnostics.note(.seal, began: sealBegan)
        let layoutBegan = diagnostics.begin()
        let wire = box.nonce.withUnsafeBytes { Data($0) } + box.tag + box.ciphertext
        diagnostics.note(.encryptedLayout, began: layoutBegan)
        return wire
    }
}
