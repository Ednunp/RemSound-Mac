import Foundation

/// A DAW's pulls kept in time with the app's mix.
///
/// The Mac serves a plugin's peers from the mix's history: the mix writes it by this Mac's clock, a block at a time, and
/// the DAW asks for its next block by its own audio card's. Until 30 September 2026 the DAW's read position simply
/// moved on by what it asked for, so it wandered against the mix - slowly, by the two clocks' difference - until it had
/// wandered 90 ms and was put back with a jump. In between, the peers on the DAW's track slid against its timeline by up
/// to that much. The Windows RemSound has no such gap: there the DAW pulls each claimed peer straight from its own
/// playout, whose drift loop keeps it in time with whoever reads it.
///
/// This keeps the read position a set distance behind the mix's newest frame (`lagFrames`, where it always started) by
/// measuring the two clocks and resampling every peer's block by the ratio, exactly as `DriftMeter` and
/// `StereoResampler` keep a stream in time. One ratio a round, so every peer on every plugin in the DAW gets its block
/// made alike and they stay sample for sample together; each peer asked for twice in a round gets the same block.
public struct HostTimeKeeper {
    /// Where the DAW reads: this far behind the mix's newest frame (10 ms), as before.
    public static let lagFrames = 480
    /// Further behind than this (the DAW stalled), or ahead of the mix: start again at the lag, as before.
    public static let slackFrames = 4_800

    /// One round: the history frames every peer's block is made from, and how.
    public struct Round: Equatable {
        public let from: Int64
        public let count: Int
        public let frames: Int
        public let ratio: Double
    }

    private var meter = DriftMeter()
    private var position = 2.0                         // shared by every peer's resampler (see block)
    private var resamplers: [String: StereoResampler] = [:]
    private var blocks: [String: [Float]] = [:]        // this round's, per peer
    private var lastClock: Int64?
    public private(set) var round: Round?
    /// The next history frame to be read.
    public private(set) var cursor: Int64 = 0
    /// Times the read position was put back at the lag: a stalled DAW, or one ahead of the mix.
    public private(set) var restarts = 0

    public init() {}

    /// The DAW's clock against the mix's, in parts per million (nil until measured): positive, the mix runs fast.
    public var ppm: Double? { meter.tracking ? meter.ppm : nil }

    /// A new round: the DAW asks for `frames`; the mix has made its history up to, not including, frame `clock`. The last
    /// round, if any, is finished first.
    @discardableResult
    public mutating func startRound(frames: Int, clock: Int64, now: Double) -> Round {
        if let last = round {
            position = position + Double(last.frames) * last.ratio - Double(last.count)
            cursor = last.from + Int64(last.count)
            // Peers not asked for last round start afresh if they come back.
            resamplers = resamplers.filter { blocks[$0.key] != nil }
        }
        blocks = [:]
        if round == nil || cursor < clock - Int64(Self.slackFrames) || cursor > clock {
            if round != nil { restarts += 1 }
            cursor = max(0, clock - Int64(Self.lagFrames))
            position = 2.0
            resamplers = [:]
            meter.reset()
            lastClock = nil
        }
        if let lastClock, clock > lastClock { meter.produced(Int(clock - lastClock), now: now) }
        lastClock = clock
        meter.consumed(frames, now: now)
        let ratio = meter.update(depthFrames: Double(clock - cursor), targetFrames: Double(Self.lagFrames), now: now)
        let next = Round(from: cursor, count: Int(position + Double(frames) * ratio), frames: frames, ratio: ratio)
        round = next
        return next
    }

    /// One peer's block for the round in progress. `history` is its history from two frames before `round.from`, for
    /// `round.count + 2` frames: the two in front seed a peer that joins part-way, so it starts in step with the others.
    /// Asked for twice in a round, the same block.
    public mutating func block(peer: String, history: [Float]) -> [Float] {
        guard let round, history.count >= (round.count + 2) * 2 else { return [] }
        if let made = blocks[peer] { return made }
        var resampler = resamplers[peer] ?? StereoResampler(position: position, held: Array(history[0..<4]))
        let made = resampler.pull(Array(history[4...]), outFrames: round.frames, ratio: round.ratio)
        resamplers[peer] = resampler
        blocks[peer] = made
        return made
    }
}
