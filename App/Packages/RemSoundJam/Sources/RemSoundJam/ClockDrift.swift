import Foundation

// KEEPING IN TIME: TWO CLOCKS THAT DIFFER.
//
// No two sound cards run at quite the same rate. The Windows machine's card makes 48,000 frames in what this Mac's
// clock calls a second plus or minus a few hundredths of a percent; this Mac's own output card differs again from the
// clock the app mixes by. Left alone, a queue between two such clocks slowly fills (until something is cut out: a
// click) or slowly empties (until it runs dry: a gap) - every few minutes at a jamming buffer, all session long.
//
// The Windows RemSound's answer, ported here (SessionPlayout.cs, its "fixed-ratio resampler" and "depth feedback"):
//   1. MEASURE the two clocks against each other over a long window - frames made against frames taken, ten seconds
//      at a time - and believe a window only if nothing stalled in it and what it reads is a possible clock.
//   2. SMOOTH that reading (the first as it is, then 70 % old and 30 % new) and RESAMPLE by it: play the queue out a
//      few hundredths of a percent fast or slow, which nobody can hear, so it neither fills nor empties.
//   3. STEER THE DEPTH: a rate-matcher holds a queue wherever it happens to stand, so at each window's end a small
//      extra pull (at most 0.3 %, spread over 15 s) walks the queue's mean depth back to the target.
// What was tried on Windows and thrown out is not repeated here: changing the rate block by block from the queue's
// level of the moment (audible wobble), and dropping or repeating single frames (a train of tiny pops).
//
// Plain Swift, no Core Audio: its tests run on Windows as on a Mac.

/// A count that arrives in lumps, read as the steady line through them.
///
/// A sender's frames come a packet or a bunch of packets at a time; a sound card takes a whole buffer at once. The
/// count at any one moment is whole lumps - whether the lump due about now has landed is a coin toss, and one 10 ms
/// lump in a ten-second window is a reading 1,000 parts in a million out (Windows measured exactly that, 2026-09-28).
/// So each lump is noted as where the count sits against a steady clock at the nominal rate, and the count at a moment
/// is the mean of the last fifth of a second of notes, carried forward to that moment.
public struct SteadyCount {
    static let lineSec = 0.2
    static let sameLumpSec = 0.0005
    /// A wait this long between two lumps breaks the line: what came before it is no guide to the count after it (the
    /// frames of a stall may be lost for good, and a line through both sides would sit between the two).
    static let breakSec = 0.1
    static let capacity = 256
    public let rate: Double
    public private(set) var total: Int64 = 0
    private var offsets = [Double](repeating: 0, count: SteadyCount.capacity)
    private var times = [Double](repeating: 0, count: SteadyCount.capacity)
    private var count = 0, next = 0
    private var origin: Double?
    /// When the last lump came, and the longest wait between two lumps since `takeLongestGap` was last called.
    public private(set) var lastAt: Double?
    private var longestGap = 0.0
    public private(set) var lumps = 0

    public init(rate: Double) { self.rate = rate }

    public mutating func add(_ frames: Int, now: Double) {
        total += Int64(frames)
        if origin == nil { origin = now }
        let offset = Double(total) - (now - origin!) * rate
        let last = (next + Self.capacity - 1) % Self.capacity
        if count > 0, now - times[last] <= Self.sameLumpSec {
            offsets[last] = offset   // the same lump: its note is where the count sits once all of it is in
            times[last] = now
        } else {
            offsets[next] = offset
            times[next] = now
            next = (next + 1) % Self.capacity
            if count < Self.capacity { count += 1 }
            if let lastAt { longestGap = max(longestGap, now - lastAt) }
            lumps += 1
        }
        lastAt = now
    }

    /// The count as of `now`, read off the line through the last fifth of a second of lumps - or through those since the
    /// line last broke, if that is more recent. With no such note, the count as it stands.
    public func value(at now: Double) -> Double {
        guard count > 0, let origin else { return Double(total) }
        var sum = 0.0, notes = 0
        var newer = now
        for i in 0..<count {
            let k = (next + Self.capacity - 1 - i) % Self.capacity
            if times[k] < now - Self.lineSec || newer - times[k] > Self.breakSec { break }
            sum += offsets[k]
            notes += 1
            newer = times[k]
        }
        guard notes > 0 else { return Double(total) }
        return sum / Double(notes) + (now - origin) * rate
    }

    /// Is there a line to read at `now`: lumps reaching back a tenth of a second with no break in them, the last of
    /// them recent? A measuring window is not started on a count that has none.
    public func settled(at now: Double) -> Bool {
        var newer = now
        for i in 0..<count {
            let k = (next + Self.capacity - 1 - i) % Self.capacity
            if newer - times[k] > Self.breakSec { return false }
            if times[k] <= now - Self.lineSec / 2 { return true }
            newer = times[k]
        }
        return false
    }

    /// The longest wait between two lumps since this was last asked, counting the one still open at `now`.
    public mutating func takeLongestGap(now: Double) -> Double {
        let open = lastAt.map { now - $0 } ?? 0
        defer { longestGap = 0 }
        return max(longestGap, open)
    }

    /// The lumps since this was last asked.
    public mutating func takeLumps() -> Int {
        defer { lumps = 0 }
        return lumps
    }
}

/// Measures one clock against another across a queue, and says what to resample by.
///
/// The PRODUCER fills the queue (a sender, counted by its packets' sequence numbers so that a lost packet is not
/// mistaken for a slow clock; or the app's mixer). The CONSUMER empties it (the mixer; or a sound card). `update` is
/// called once a block with the queue's depth, and returns the ratio to resample at: producer frames per consumer frame.
public struct DriftMeter {
    // The Windows figures (SessionPlayout.cs).
    public static let windowSec = 10.0          // long enough that jitter does not bias it, short enough to follow a card warming up
    public static let smoothingNew = 0.30       // a later reading counts for 30 %
    public static let ratioMin = 0.95           // real cards are under 0.1 % apart: anything past 5 % is no clock
    public static let ratioMax = 1.05
    public static let producerStallSec = 0.100  // a window the stream stalled in is not a clock reading
    public static let consumerStallMinSec = 0.020
    public static let consumerStallFactor = 4.0 // nor one the output stopped in: a wait over four times its usual
    public static let depthCorrectionSec = 15.0 // the depth's error is walked back over this long...
    public static let maxDepthBias = 0.003      // ...and never faster than 0.3 %: about 5 cents, and 3 ms a second
    public static let depthMeanSec = 0.1        // the depth steered is its mean over a tenth of a second, not one sample of a sawtooth

    public let rate: Double
    private var producer: SteadyCount
    private var consumer: SteadyCount
    private var windowStart: Double?
    private var startProduced = 0.0, startConsumed = 0.0
    private var depthMean = -1.0
    private var depthMeanAt: Double?

    /// The clocks' ratio as measured and smoothed: producer frames per consumer frame (1 until the first reading).
    public private(set) var clockRatio = 1.0
    /// What to resample at: the clocks' ratio plus the pull toward the target depth.
    public private(set) var ratio = 1.0
    /// A reading has been taken: the resampling is live.
    public private(set) var tracking = false
    /// Windows believed, and windows thrown away (a stall, or a reading no clock could give).
    public private(set) var accepted = 0, rejected = 0
    /// The last window's own reading, believed or not.
    public private(set) var lastReading: Double?

    public init(rate: Double = 48_000) {
        self.rate = rate
        producer = SteadyCount(rate: rate)
        consumer = SteadyCount(rate: rate)
    }

    /// The clocks' difference in parts per million: positive, the producer's runs fast.
    public var ppm: Double { (clockRatio - 1) * 1_000_000 }
    /// The mean depth being steered, in frames (-1 before the first update).
    public var meanDepthFrames: Double { depthMean }

    public mutating func produced(_ frames: Int, now: Double) { producer.add(frames, now: now) }
    public mutating func consumed(_ frames: Int, now: Double) { consumer.add(frames, now: now) }

    /// Start again: the producer restarted, and what was learned was about the stream before.
    public mutating func reset() { self = DriftMeter(rate: rate) }

    /// How hard the depth is pulled toward its target (Windows' three sets of numbers): steadily, 0.3 % at most spread
    /// over 15 s; after the person moves the buffer, 5 % over 3 s; coming down from a lowered target, 0.4 % over 3 s.
    public enum Pull: Sendable {
        case steady, fast, descent
        public var spreadSec: Double { self == .steady ? DriftMeter.depthCorrectionSec : 3 }
        public var maxBias: Double { self == .steady ? DriftMeter.maxDepthBias : self == .fast ? 0.05 : 0.004 }
    }
    public var pull = Pull.steady

    /// Work the pull out afresh from the depth given (at every window's end; five times a second while approaching or
    /// descending). Nothing until the first reading: before it the ratio means nothing.
    public mutating func repull(depthFrames: Double, targetFrames: Double) {
        guard tracking else { return }
        let error = depthFrames - targetFrames
        ratio = clockRatio + max(-pull.maxBias, min(pull.maxBias, error / (pull.spreadSec * rate)))
    }

    public mutating func update(depthFrames: Double, targetFrames: Double, now: Double) -> Double {
        if depthMean < 0 || depthMeanAt == nil {
            depthMean = depthFrames
        } else {
            let dt = max(0, now - depthMeanAt!)
            depthMean += dt / (Self.depthMeanSec + dt) * (depthFrames - depthMean)
        }
        depthMeanAt = now

        guard let start = windowStart else {
            // A window starts only on counts that each have a line to be read off: not in a stream's first moments, and
            // not at the end of a stall (the window it fell in was thrown away; the next must not start inside it).
            if producer.settled(at: now), consumer.settled(at: now) { anchor(now) }
            return ratio
        }
        guard now - start >= Self.windowSec else { return ratio }

        let producedNow = producer.value(at: now), consumedNow = consumer.value(at: now)
        let made = producedNow - startProduced, taken = consumedNow - startConsumed
        var stalled = producer.takeLongestGap(now: now) > Self.producerStallSec
        let lumps = consumer.takeLumps()
        let usual = lumps > 0 ? (now - start) / Double(lumps) : 0
        if consumer.takeLongestGap(now: now) > max(Self.consumerStallMinSec, Self.consumerStallFactor * usual) { stalled = true }
        _ = producer.takeLumps()

        if made > 0, taken > 0 {
            let reading = made / taken
            lastReading = reading
            if !stalled, reading >= Self.ratioMin, reading <= Self.ratioMax {
                clockRatio = tracking ? (1 - Self.smoothingNew) * clockRatio + Self.smoothingNew * reading : reading
                tracking = true
                accepted += 1
            } else {
                rejected += 1
            }
        } else {
            rejected += 1
        }
        // The pull toward the target, worked out afresh at every window's end, believed or not - so a queue left
        // standing deep by a stall still drains. Nothing until the first reading: before it the ratio means nothing.
        repull(depthFrames: pull == .fast ? depthFrames : depthMean, targetFrames: targetFrames)
        if stalled { windowStart = nil } else { anchor(now) }
        return ratio
    }

    private mutating func anchor(_ now: Double) {
        windowStart = now
        startProduced = producer.value(at: now)
        startConsumed = consumer.value(at: now)
        _ = producer.takeLongestGap(now: now)
        _ = consumer.takeLongestGap(now: now)
        _ = producer.takeLumps()
        _ = consumer.takeLumps()
    }
}

/// Plays stereo sound out a little fast or slow: straight-line interpolation between neighbouring frames, which at the
/// few hundredths of a percent a clock differs by is what the Windows RemSound uses too. Interleaved left, right.
///
/// PULL when the output's size is fixed (the mixer wants 96 frames): ask `inputFrames(forOutput:ratio:)`, hand exactly
/// that many over. PUSH when the input's is (the mixer made 96 frames for a sound card): hand them over and write out
/// however many come back. `ratio` is input frames per output frame.
public struct StereoResampler {
    // The two frames held from the input so far, and where the next output lies, counted from the first of them (in
    // input frames). It starts at 2 - on the first frame still to come - so the sound carries straight on from
    // whatever was played before the resampler was brought in, and at a ratio of exactly 1 what comes out is what went
    // in, sample for sample.
    private var a: (Float, Float) = (0, 0), b: (Float, Float) = (0, 0)
    private var position = 2.0

    public init() {}

    /// Starting where another resampler stands, so that two fed alike stay sample for sample in step (the DAW's peers):
    /// `held` is the two frames just before the input still to come, interleaved.
    public init(position: Double, held: [Float]) {
        self.position = position
        if held.count >= 4 {
            a = (held[0], held[1])
            b = (held[2], held[3])
        }
    }

    /// Where the next output lies, counted from the first of the two frames held (in input frames).
    public var nextPosition: Double { position }

    /// Forget the sound held: after a gap, what comes next is a new start.
    public mutating func reset() { self = StereoResampler() }

    public func inputFrames(forOutput outFrames: Int, ratio: Double) -> Int {
        Int(position + Double(outFrames) * ratio)
    }

    /// `input` must hold `inputFrames(forOutput:ratio:)` frames; all of them are used.
    public mutating func pull(_ input: [Float], outFrames: Int, ratio: Double) -> [Float] {
        render(input, outFrames: outFrames, ratio: ratio)
    }

    /// Everything `input` gives at `ratio`; all of `input` is used.
    public mutating func push(_ input: [Float], ratio: Double) -> [Float] {
        let frames = Double(input.count / 2)
        let outFrames = position >= frames ? 0 : Int(((frames - position) / ratio).rounded(.up))
        return render(input, outFrames: outFrames, ratio: ratio)
    }

    private mutating func render(_ input: [Float], outFrames: Int, ratio: Double) -> [Float] {
        let frames = input.count / 2
        // v[0] = a, v[1] = b, v[2...] = the input.
        func left(_ i: Int) -> Float { i == 0 ? a.0 : i == 1 ? b.0 : input[(i - 2) * 2] }
        func right(_ i: Int) -> Float { i == 0 ? a.1 : i == 1 ? b.1 : input[(i - 2) * 2 + 1] }
        var output = [Float](repeating: 0, count: outFrames * 2)
        for k in 0..<outFrames {
            let at = position + Double(k) * ratio
            let index = min(Int(at), frames)   // never past what was handed over
            let part = Float(at - Double(Int(at)))
            let l = left(index), r = right(index)
            output[2 * k] = l + (left(index + 1) - l) * part
            output[2 * k + 1] = r + (right(index + 1) - r) * part
        }
        let end = position + Double(outFrames) * ratio
        let used = min(frames, max(0, Int(end)))
        let newA = (left(used), right(used)), newB = (left(used + 1), right(used + 1))
        a = newA
        b = newB
        position = end - Double(used)
        return output
    }
}

/// What an output card's queue lets its clock keeper see and do: the app's mix goes in at one end, the card's own
/// callback takes from the other.
public protocol OutputQueue: AnyObject {
    /// Frames waiting to be played.
    var available: Int { get }
    /// Frames ever written.
    var writtenFrames: Int { get }
    /// Lifetime requested frames and positive pulls, including zero-filled short reads. Nil if unavailable.
    var pullTotals: (frames: UInt64, count: UInt64)? { get }
    @discardableResult func discard(_ frames: Int) -> Int
    func write(_ samples: [Float])
}

public extension OutputQueue {
    var pullTotals: (frames: UInt64, count: UInt64)? { nil }
}

/// Sizes the output cushion from actual average pulls, independently of underruns and producer timing.
/// Windows AdaptiveCushionTarget: 12 ms initially; ten-second means, 1.2 margin, 8...50 ms, 2 ms hysteresis.
struct OutputCushion {
    static let framesPerMillisecond = 48
    static let windowSeconds = 10.0
    static let initialMilliseconds = 12
    static let minimumMilliseconds = 8
    static let maximumMilliseconds = 50
    static let hysteresisMilliseconds = 2
    static let pullMultiple = 1.2
    private(set) var milliseconds = Self.initialMilliseconds
    private var since: Double?
    private var first: (frames: UInt64, count: UInt64)?
    private var latest: (frames: UInt64, count: UInt64)?
    var frames: Int { milliseconds * Self.framesPerMillisecond }

    static func next(current: Int, averageFrames: Double) -> Int {
        guard averageFrames.isFinite, averageFrames > 0 else { return current }
        let candidate = Int(min(Double(maximumMilliseconds), max(Double(minimumMilliseconds),
            averageFrames / Double(framesPerMillisecond) * pullMultiple)).rounded(.toNearestOrEven))
        return abs(candidate - current) >= hysteresisMilliseconds ? candidate : current
    }

    mutating func update(_ totals: (frames: UInt64, count: UInt64)?, now: Double) -> Bool {
        guard let totals else { return false } // A bounded native snapshot may be unavailable during a pull.
        if let latest, totals.frames < latest.frames || totals.count < latest.count {
            self = OutputCushion()
            first = totals
            self.latest = totals
            since = now
            return true
        }
        latest = totals
        guard let since, let first else {
            self.since = now
            self.first = totals
            return false
        }
        guard now - since >= Self.windowSeconds else { return false }
        let count = totals.count - first.count
        if count > 0 {
            milliseconds = Self.next(current: milliseconds,
                averageFrames: Double(totals.frames - first.frames) / Double(count))
        }
        self.first = totals
        self.since = now
        return false
    }
}

/// One output card kept in time with the app's mix. Cushion sizing reads the card, never the load.
/// Mac retains producer-side resampling and startup/recovery silence; queue capacity is the only loss boundary.
/// Pull-side resampling and device-clock acquisition remain separate parity work.
public struct OutputClock {
    /// The output stage's 100 ms capacity at 48 kHz, shared by native and modeled output rings.
    public static let maximumQueueFrames = 4_800
    /// A producer late by more than four mix periods skips the missed time rather than filling a stale backlog.
    public static let maximumCatchupBlocks = 4
    private var cushionTarget = OutputCushion()
    private var meter = DriftMeter()
    private var resampler = StereoResampler()
    private var lastTaken: Int?
    private var laid = false
    /// What the card takes at once, in frames (its Core Audio buffer). The app says; 512 until it does.
    public var cardFrames = 512
    /// Frames of silence laid down as cushion, frames cut from a queue standing too deep, and times the card ran dry.
    public private(set) var laidFrames = 0, cutFrames = 0, ranDry = 0
    /// The cushion being held, in frames (0 before the first block).
    public private(set) var cushionFrames = 0

    public init() {}

    /// The card's clock against the mix's, in parts per million (nil until measured): positive, the mix runs fast.
    public var ppm: Double? { meter.tracking ? meter.ppm : nil }
    public var ratio: Double { meter.ratio }

    /// The measured target for a constant pull size. Mix-block size does not size the cushion.
    public static func cushion(cardFrames: Int, blockFrames: Int) -> Int {
        OutputCushion.next(current: OutputCushion.initialMilliseconds, averageFrames: Double(cardFrames))
            * OutputCushion.framesPerMillisecond
    }

    /// One mix block, on its way to the card.
    public mutating func write<Q: OutputQueue>(_ samples: [Float], to queue: Q, now: Double) {
        let block = samples.count / 2
        var depth = queue.available
        let taken = queue.writtenFrames - depth
        if let last = lastTaken, taken < last {
            // The queue was emptied and started again under us.
            cushionTarget = OutputCushion()
            meter.reset()
            resampler.reset()
            laid = false
        } else if let last = lastTaken, taken > last {
            meter.consumed(taken - last, now: now)
        }
        if cushionTarget.update(queue.pullTotals, now: now) {
            meter.reset()
            resampler.reset()
            laid = false
        }
        if laid, depth == 0 {
            ranDry += 1
            laid = false
            resampler.reset()
        }
        let cushion = cushionTarget.frames
        cushionFrames = cushion
        lastTaken = taken
        if !laid {
            if depth < cushion {
                queue.write([Float](repeating: 0, count: (cushion - depth) * 2))
                laidFrames += cushion - depth
                depth = cushion
            }
            laid = true
        }
        meter.produced(block, now: now)
        let ratio = meter.update(depthFrames: Double(depth), targetFrames: Double(cushion), now: now)
        queue.write(resampler.push(samples, ratio: ratio))
    }
}
