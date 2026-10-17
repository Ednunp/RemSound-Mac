import Foundation

/// Jamulus-style Opus: 64-sample (1.33 ms) CELT frames, as the Windows RemSound's latency lab sends them
/// (src/RemSound.Core/OpusCustomCodec.cs and SenderLane.ProcessCustomOpus, the reference).
///
/// - Its own stream, announced by a Format packet with codec 3 and the frame size, and the lab flag set.
/// - Each audio packet is the ordinary header (type 2, that stream, its own sequence) and the frame sealed with the password,
///   exactly as ordinary Opus.
/// - A RemSound says it can play it with the lab flag (byte 33 of every Format packet it sends, and the heartbeat's 10th
///   byte) while its switch is on. Only then may it be sent one; those targets get ONLY this stream from that source.
/// - Through a server, only while EVERYONE the server passes the stream to has said so (it passes one stream to all) and no
///   phone or older app is paired there.
public enum JamulusStyle {
    public static let codec = 3
    public static let labFlagCanDecode: UInt8 = 1
    public static let formatLabFlagsOffset = 33
    public static let frames = 64
    /// The encoder's settings, as Windows has them.
    public static func bitrate(frames: Int) -> Int { frames <= 64 ? 320_000 : 256_000 }
    public static func maxBytes(frames: Int) -> Int { min(max(bitrate(frames: frames) * frames / (8 * 48_000), 16), 1275) }
    public static let complexity = 10
    public static let packetLossPercent = 35

    /// Who of `targets` gets the Jamulus-style stream: a direct peer that has said it can play it; through a server, the
    /// server itself (or anyone on it) only while everyone it passes our sound to has said so, and no phone is paired there.
    public static func targets(_ targets: [JamEndpoint], group: RelayGroupClient?, canDecode: (String) -> Bool) -> Set<JamEndpoint> {
        var chosen = Set<JamEndpoint>()
        for target in targets {
            if let group, group.routes(target) {
                guard let relay = group.connectedRelay, !group.isV1Paired(relay),
                    group.everyReceiver(on: relay, { canDecode($0.address) }) else { continue }
                chosen.insert(target)
            } else if canDecode(target.address) {
                chosen.insert(target)
            }
        }
        return chosen
    }
}

/// Who has said, in the last few seconds, that they can play Jamulus-style frames - by the address they are known at here
/// (a member's own address through a server).
public struct CanDecodeRegistry {
    public static let forgetAfter: TimeInterval = 3
    private var seen: [String: TimeInterval] = [:]
    public init() {}

    public mutating func note(_ address: String, now: TimeInterval) { seen[address] = now }

    public func canDecode(_ address: String, now: TimeInterval) -> Bool {
        guard let at = seen[address] else { return false }
        return now - at < Self.forgetAfter
    }

    public func count(now: TimeInterval) -> Int { seen.values.filter { now - $0 < Self.forgetAfter }.count }
}
