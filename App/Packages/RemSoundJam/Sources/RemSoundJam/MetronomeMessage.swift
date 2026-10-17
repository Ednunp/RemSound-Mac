import Foundation

/// The metronome's own messages (packet type 12) between RemSounds - asking to lead, answering, letting go - a copy of the
/// Windows RemSound's MetronomeWire (src/RemSound.Core/MetronomeMessage.cs, the reference). On the wire: the 12-byte header
/// with type 12 and stream 0xFFFF, then the plaintext below SEALED with the same AES-256-GCM key the audio uses (the Mac's
/// `Credentials.seal`/`open`). Only timing ever travels, never sound. Little-endian throughout.
public enum MetronomeKind: UInt8, Sendable {
    /// Master to everyone: "may I be the master metronome?", with the master's name.
    case offer = 1
    case accept = 2
    case decline = 3
    /// Master to followers: I am no longer the master.
    case release = 4
    /// Master to followers: the timeline (direct connections only; through a server the server's grid carries it).
    case state = 5
    case syncRequest = 6
    case syncReply = 7
    /// Follower to master: I have stopped following.
    case leave = 8
}

public struct MetronomeMessage: Equatable, Sendable {
    public var kind: MetronomeKind
    public var sessionId: UInt64
    public var masterName = ""
    public var state: MetronomeTimeline?
    public var seq: UInt32 = 0
    public var t0: Int64 = 0, t1: Int64 = 0, t2: Int64 = 0

    public init(_ kind: MetronomeKind, sessionId: UInt64, masterName: String = "") {
        self.kind = kind
        self.sessionId = sessionId
        self.masterName = masterName
    }

    public static let formatVersion: UInt8 = 1
    public static let maxNameBytes = 64
    static let commonBytes = 1 + 1 + 8
    public static let streamId: UInt16 = 0xFFFF

    /// A new master's session id: 8 random bytes.
    public static func newSessionId() -> UInt64 { UInt64.random(in: 1...UInt64.max) }

    /// The plaintext, before sealing.
    public func plaintext() -> [UInt8] {
        var plain: [UInt8] = [Self.formatVersion, kind.rawValue]
        plain.appendLE(sessionId)
        switch kind {
        case .offer:
            var name = Array(masterName.utf8)
            if name.count > Self.maxNameBytes {
                var cut = Self.maxNameBytes
                while cut > 0 && (name[cut] & 0xC0) == 0x80 { cut -= 1 }
                name = Array(name[0..<cut])
            }
            plain.append(UInt8(name.count))
            plain.append(contentsOf: name)
        case .state:
            let s = state ?? .stopped()
            plain.appendLE(s.version)
            plain.append(s.running ? 1 : 0)
            plain.appendLE(s.milliBpm)
            plain.append(s.beatsPerBar)
            plain.append(s.beatUnit)
            plain.appendLE(s.anchorBeat)
            plain.appendLE(s.anchorTimeUs)
        case .syncRequest:
            plain.appendLE(seq)
            plain.appendLE(t0)
        case .syncReply:
            plain.appendLE(seq)
            plain.appendLE(t0)
            plain.appendLE(t1)
            plain.appendLE(t2)
        case .accept, .decline, .release, .leave:
            break
        }
        return plain
    }

    /// Read an opened plaintext: nil for another version, an unknown kind, or too few bytes.
    public static func parse(_ plain: [UInt8]) -> MetronomeMessage? {
        guard plain.count >= commonBytes, plain[0] == formatVersion, let kind = MetronomeKind(rawValue: plain[1]) else { return nil }
        var m = MetronomeMessage(kind, sessionId: plain.readLE(UInt64.self, at: 2))
        let p = commonBytes
        switch kind {
        case .offer:
            guard plain.count > p, Int(plain[p]) <= maxNameBytes, plain.count >= p + 1 + Int(plain[p]) else { return nil }
            m.masterName = String(decoding: plain[(p + 1)..<(p + 1 + Int(plain[p]))], as: UTF8.self)
        case .accept, .decline, .release, .leave:
            break
        case .state:
            guard plain.count >= p + 27, plain[p + 4] <= 1 else { return nil }
            m.state = MetronomeTimeline(version: plain.readLE(UInt32.self, at: p), running: plain[p + 4] == 1,
                                        milliBpm: plain.readLE(UInt32.self, at: p + 5), beatsPerBar: plain[p + 9], beatUnit: plain[p + 10],
                                        anchorBeat: plain.readLE(Int64.self, at: p + 11), anchorTimeUs: plain.readLE(Int64.self, at: p + 19))
        case .syncRequest:
            guard plain.count >= p + 12 else { return nil }
            m.seq = plain.readLE(UInt32.self, at: p)
            m.t0 = plain.readLE(Int64.self, at: p + 4)
        case .syncReply:
            guard plain.count >= p + 28 else { return nil }
            m.seq = plain.readLE(UInt32.self, at: p)
            m.t0 = plain.readLE(Int64.self, at: p + 4)
            m.t1 = plain.readLE(Int64.self, at: p + 12)
            m.t2 = plain.readLE(Int64.self, at: p + 20)
        }
        return m
    }
}

/// Never accept the same seal twice: a captured Offer replayed later does nothing. Keyed by the seal's first 8 bytes (its
/// random nonce).
public struct MetronomeReplayGuard {
    private var seen = Set<UInt64>()
    private var order: [UInt64] = []
    private let capacity: Int
    public init(capacity: Int = 16384) { self.capacity = capacity }

    public mutating func firstTime(sealedPayload: [UInt8]) -> Bool {
        guard sealedPayload.count >= 8 else { return false }
        let id = sealedPayload.readLE(UInt64.self, at: 0)
        guard seen.insert(id).inserted else { return false }
        order.append(id)
        if order.count > capacity { seen.remove(order.removeFirst()) }
        return true
    }
}
