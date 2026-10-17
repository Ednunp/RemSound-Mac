import Foundation

/// The receive buffer's auto-tune as the Mac runs it - the app's Session and the simulator alike, so the simulator runs
/// the very decision the app does. It gathers Windows' evidence a second at a time (the worst gap between packets, the
/// worst gap between mixes, the least sound left in the buffer) and hands it to Windows' decisions (WindowsAutoTune.swift):
/// the usual auto-tune at the chosen interval, or, with "lowest delay" on, the dropout tuner once a second.
public struct ReceiveAutoTune {
    /// Seconds of readings kept (Windows RecentMaxGapWindowSeconds; the decision looks at the last 15).
    public static let keptSeconds = 30
    /// After you set the buffer yourself the lowest-delay tune leaves it alone this long (Windows: 5 s).
    public static let lowestDelayPauseAfterYou: TimeInterval = 5

    public private(set) var arrivalGaps: [Int] = []
    public private(set) var mixGaps: [Int] = []
    public private(set) var minBuffers: [Int] = []
    private var secondArrivalGapMs = 0.0, secondMixGapMs = 0.0, secondMinBufferMs: Double?
    private var packetsThisSecond = 0
    private var lastArrival: [String: TimeInterval] = [:]
    private var lastMix: TimeInterval?
    private var cleanTicks = 0
    private let creep = AutoTuneDescent.CreepState()
    private var needsBaseline = true
    private let dropout = DropoutTuner()
    private var lastAudibleGaps: Int?
    private var youMovedAt: TimeInterval = -.infinity

    public init() {}

    // MARK: evidence

    /// An audio packet from `stream`, at `now` seconds.
    public mutating func noteArrival(stream: String, now: TimeInterval) {
        if let last = lastArrival[stream], now >= last { secondArrivalGapMs = max(secondArrivalGapMs, (now - last) * 1000) }
        if lastArrival.count >= 256 { lastArrival.removeAll() }
        lastArrival[stream] = now
        packetsThisSecond += 1
    }

    /// A mix, at `now` seconds: the gap since the last is this Mac's render period (and its stalls).
    public mutating func noteMix(now: TimeInterval) {
        if let last = lastMix, now >= last { secondMixGapMs = max(secondMixGapMs, (now - last) * 1000) }
        lastMix = now
    }

    /// How much sound a receiving buffer holds, after a read.
    public mutating func noteBuffer(ms: Double) { secondMinBufferMs = min(secondMinBufferMs ?? ms, ms) }

    /// A new stream is new conditions: the readings so far describe another one (Windows OnNewStreamSessions).
    public mutating func newStream() {
        arrivalGaps.removeAll(); mixGaps.removeAll(); minBuffers.removeAll()
        lastArrival.removeAll(); packetsThisSecond = 0; secondArrivalGapMs = 0
        creep.reset(); cleanTicks = 0; needsBaseline = true
    }

    /// The end of a second: its readings join the windows, when any packet came (Windows counts no other second).
    public mutating func endSecond() {
        if packetsThisSecond > 0 {
            Self.keep(&arrivalGaps, Int(secondArrivalGapMs.rounded()))   // to the nearest ms: timer noise is not a gap
            Self.keep(&mixGaps, max(1, Int(secondMixGapMs.rounded())))
            if let low = secondMinBufferMs { Self.keep(&minBuffers, max(0, Int(low.rounded(.down)))) }
        }
        secondArrivalGapMs = 0; secondMixGapMs = 0; secondMinBufferMs = nil; packetsThisSecond = 0
    }

    private static func keep(_ window: inout [Int], _ value: Int) {
        window.append(value)
        if window.count > keptSeconds { window.removeFirst(window.count - keptSeconds) }
    }

    // MARK: decisions

    /// Turned on, off, or the receiving started again: what it learned no longer applies, and the first tick only reads
    /// the underrun counter (Windows' baseline).
    public mutating func restart() {
        creep.reset(); cleanTicks = 0; needsBaseline = true; dropout.reset(); lastAudibleGaps = nil
    }

    /// You set the buffer yourself: the lowest-delay tune waits, and starts over from your value.
    public mutating func youSetIt(now: TimeInterval) { youMovedAt = now; dropout.reset() }

    public struct Change: Equatable { public var targetMs: Int; public var log: String }

    /// The usual auto-tune's tick, at the chosen interval. `underruns` are those since the last tick; `frameMs` the
    /// arriving stream's packet length.
    public mutating func tick(currentMs: Int, underruns: Int, hasAudio: Bool, frameMs: Int) -> (change: Change?, log: String?) {
        if needsBaseline {
            needsBaseline = false
            return (nil, underruns > 0 ? "continuous auto-tune: baseline taken (\(underruns) underruns already on the counter "
                + "before it started tuning - ignored, not acted on)" : nil)
        }
        guard hasAudio else { return (nil, nil) }
        let d = ContinuousAutoTune.decide(currentMs: currentMs, sliderMinMs: ReceiveTuning.minimumMs,
            sliderMaxMs: ReceiveTuning.maximumMs, underrunDelta: underruns, arrivalGaps: arrivalGaps,
            renderCbGaps: mixGaps, minBuffers: minBuffers, codecFloorMs: ContinuousAutoTune.codecFloorMs(frameMs: frameMs),
            cleanTicks: &cleanTicks, creep: creep)
        switch d.verdict {
        case .raise:
            let why = d.cappedMs >= d.cappedFloorMs ? "the measured need" : "the floor it has learned by experiment"
            return (.init(targetMs: d.target, log: "continuous auto-tune: RAISING \(d.currentMs)ms -> \(d.target)ms "
                + "(\(underruns) new underruns) - the buffer ran short; measured=\(d.cappedMs)ms learnedFloor=\(d.cappedFloorMs)ms, "
                + "aiming at \(why)"), nil)
        case .holdAfterShortfall:
            return (nil, "continuous auto-tune: holding at \(d.currentMs)ms (\(underruns) new underruns) - already at or above "
                + "measured=\(d.cappedMs)ms and learnedFloor=\(d.learnedFloorMs)ms")
        case .move:
            return (.init(targetMs: d.target, log: "continuous auto-tune: \(d.currentMs)ms -> \(d.target)ms (gap peak "
                + "\(d.gapPeakMs)ms, used \(d.gapUsedMs)ms; mix gap \(d.renderCbUsedMs)ms; low water \(d.lowWaterMs)ms; "
                + "measured \(d.cappedMs)ms; learnedFloor \(d.learnedFloorMs)ms; \(d.sampleCount) s of readings)"), nil)
        case .stay:
            return (nil, nil)
        }
    }

    /// The lowest-delay auto-tune's second (Windows TickLowestDelayRoute). `audibleGapsTotal` is the running count of
    /// audible gaps; `floorMs` the least the output takes at a time. Nothing moves within 5 s of your own setting.
    public mutating func lowestDelaySecond(audibleGapsTotal: Int, currentMs: Int, floorMs: Int, on: Bool, now: TimeInterval) -> Change? {
        let newGaps = lastAudibleGaps.map { max(0, audibleGapsTotal - $0) } ?? 0
        lastAudibleGaps = audibleGapsTotal
        guard on else { dropout.reset(); return nil }
        guard now - youMovedAt >= Self.lowestDelayPauseAfterYou else { dropout.reset(); return nil }
        let floor = min(max(floorMs, ReceiveTuning.minimumMs), ReceiveTuning.maximumMs)
        let next = dropout.tick(gapsThisSecond: newGaps, currentMs: currentMs, floorMs: floor, ceilingMs: ReceiveTuning.maximumMs)
        guard next != currentMs else { return nil }
        return .init(targetMs: next, log: "lowest-delay auto-tune: \(currentMs) ms -> \(next) ms (\(dropout.lastReason))")
    }
}
