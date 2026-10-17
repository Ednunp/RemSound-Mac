import Foundation

// REMOTE VOLUME AND MUTE (the Mac's copy of the Windows RemSound's Control packets, type 5 - RemPacket.cs, ControlSealing.cs,
// MainForm.SendRemoteControl / HandleRemoteControlPacket).
//
// A peer nudges this machine's listening volume, mutes or unmutes what it receives, or moves the computer's own output
// volume and mute - only if this machine has "Accept remote volume commands from peers" ticked, only from a ticked peer,
// and only sealed with the shared password. The packet is the ordinary 12-byte header (type 5, stream 0xFFFE, a sequence
// counter nobody reads) and 38 sealed bytes: the audio key's AES-256-GCM, nonce(12) then tag(16) then ciphertext(10) -
// RemSound's order, not CryptoKit's - around a 10-byte plaintext: the kind, a signed step, and the Unix time it was sent.
// The receiver refuses anything not exactly 38 bytes, any kind it does not know, anything sent more than ten minutes
// from its own clock, and any nonce it has already accepted. The sender is never told.
//
// The sealing itself is CryptoKit's, on the Mac (Credentials.seal/open); this is the part that is the same everywhere.

public enum RemoteControl {
    /// What a control packet asks for (the plaintext's first byte).
    public enum Kind: UInt8, CaseIterable, Sendable {
        case volumeUp = 0, volumeDown = 1, muteToggle = 2
        case systemVolumeUp = 3, systemVolumeDown = 4, systemMuteToggle = 5
    }

    /// The header's stream id for control packets, and the packet type.
    public static let streamID: UInt16 = 0xFFFE
    public static let packetType: UInt8 = 5
    /// The plaintext: kind, step, time. Sealed, 28 bytes more.
    public static let plainBytes = 10
    public static let sealedBytes = 38
    /// What the Windows hotkeys send: the listening volume moves 5 points a press; the others carry no step.
    public static let volumeStep: Int8 = 5
    /// How far from this machine's clock a command may have been sent, either way.
    public static let maxSkew: TimeInterval = 600

    public static func plaintext(_ kind: Kind, delta: Int8, unixSeconds: Int64) -> [UInt8] {
        var p = [kind.rawValue, UInt8(bitPattern: delta)]
        var t = UInt64(bitPattern: unixSeconds)
        for _ in 0..<8 {
            p.append(UInt8(t & 0xFF))
            t >>= 8
        }
        return p
    }

    /// The command in a plaintext, or nil if it is not one (a wrong size, or a kind nobody sends).
    public static func parse(_ plain: [UInt8]) -> (kind: Kind, delta: Int8, unixSeconds: Int64)? {
        guard plain.count == plainBytes, let kind = Kind(rawValue: plain[0]) else { return nil }
        var t: UInt64 = 0
        for i in (0..<8).reversed() { t = (t << 8) | UInt64(plain[2 + i]) }
        return (kind, Int8(bitPattern: plain[1]), Int64(bitPattern: t))
    }

    /// The listening volume after a volume command: the kind sets the direction, the step's size is its absolute value,
    /// clamped to 0...100 (as Windows: the sign of the step is ignored).
    public static func nudged(volume: Int, kind: Kind, delta: Int8) -> Int {
        let step = abs(Int(delta))
        switch kind {
        case .volumeUp: return min(100, max(0, volume + step))
        case .volumeDown: return min(100, max(0, volume - step))
        default: return volume
        }
    }

    /// The step a command carries: the listening volume's five points up or down; nothing for the rest.
    public static func delta(for kind: Kind) -> Int8 {
        switch kind {
        case .volumeUp: volumeStep
        case .volumeDown: -volumeStep
        default: 0
        }
    }

    /// What the received sound is multiplied by: the listening volume as a fraction, or nothing while muted.
    public static func listeningGain(volume: Int, muted: Bool) -> Float {
        muted ? 0 : Float(min(100, max(0, volume))) / 100
    }

    /// The computer's own volume after one step, as the Mac's volume keys move it: a sixteenth, kept within 0...1.
    public static let systemStep: Float = 1.0 / 16
    public static func steppedSystemVolume(_ scalar: Float, up: Bool) -> Float {
        min(1, max(0, scalar + (up ? systemStep : -systemStep)))
    }

    /// The log's reading of the computer's volume, as Windows writes it: whole percent (truncated), " MUTED" if muted,
    /// "?" if it could not be read.
    public static func describeSystem(_ state: (scalar: Float, muted: Bool)?) -> String {
        guard let state else { return "?" }
        return "\(Int(state.scalar * 100))%" + (state.muted ? " MUTED" : "")
    }

    /// What the log says of a command, as Windows names the kinds.
    public static func name(_ kind: Kind) -> String {
        switch kind {
        case .volumeUp: "VolumeUp"
        case .volumeDown: "VolumeDown"
        case .muteToggle: "MuteToggle"
        case .systemVolumeUp: "SystemVolumeUp"
        case .systemVolumeDown: "SystemVolumeDown"
        case .systemMuteToggle: "SystemMuteToggle"
        }
    }
}

/// Refuses stale and replayed commands (Windows' ControlReceiveGuard). One per app, used on one queue.
public struct ControlReceiveGuard {
    public enum Verdict: Equatable {
        case accepted(RemoteControl.Kind, Int8)
        case notSealed
        case stale(minutes: Double)
        case replay

        /// The log's reason, as Windows words it.
        public var reason: String {
            switch self {
            case .accepted: "accepted"
            case .notSealed: "not-sealed (wrong password, tampered, or a pre-5.6 peer)"
            case let .stale(minutes): "stale (sent " + String(format: "%.1f", minutes) + " min from now, window 10 min)"
            case .replay: "replay (nonce already accepted)"
            }
        }
    }

    private var seen: [UInt64: TimeInterval] = [:]
    public init() {}
    public var remembered: Int { seen.count }

    /// `sealed` is the 38 bytes as they came; `plain` what opening them gave (nil: they would not open - a wrong password,
    /// or tampered). `now` is this machine's Unix time.
    public mutating func check(sealed: [UInt8], plain: [UInt8]?, now: TimeInterval) -> Verdict {
        guard sealed.count == RemoteControl.sealedBytes, let plain, let command = RemoteControl.parse(plain) else { return .notSealed }
        let age = now - TimeInterval(command.unixSeconds)
        if age > RemoteControl.maxSkew || age < -RemoteControl.maxSkew { return .stale(minutes: abs(age) / 60) }
        // The nonce's first eight bytes, little-endian, name the command.
        var id: UInt64 = 0
        for i in (0..<8).reversed() { id = (id << 8) | UInt64(sealed[i]) }
        if seen[id] != nil { return .replay }
        if seen.count >= 256 { seen = seen.filter { now - $0.value <= 2 * RemoteControl.maxSkew } }
        seen[id] = now
        return .accepted(command.kind, command.delta)
    }
}

/// Refusals said at most once a minute (Windows' NoteControlRefused): a flood of control packets from senders nobody
/// ticked costs a count, not a log line each.
public struct RefusalCounter {
    public static let sayEvery: TimeInterval = 60
    public private(set) var count = 0
    private var saidAt: TimeInterval?
    public init() {}

    /// One more refused at `now`: the count so far if it is time to say so, else nil.
    public mutating func note(now: TimeInterval) -> Int? {
        count += 1
        if let saidAt, now - saidAt < Self.sayEvery { return nil }
        saidAt = now
        return count
    }
}
