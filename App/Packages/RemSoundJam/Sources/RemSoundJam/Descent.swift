import Foundation

// COMING DOWN FROM A LOWERED BUFFER, AND GOING UP TO A RAISED ONE (the Mac's copy of the Windows RemSound's
// SessionPlayout.cs and AudioRingBuffer.SkipWithCrossfade, 2026-08-14 and 2026-09-28).
//
// Moved by hand, the buffer follows at once: lowered, the excess is skipped with a crossfade (never a click); either
// way the drift loop's pull toward the target goes up to 5 % for a while (an audible, deliberate glide - the person
// asked for it and hears it arrive - never a gap), recomputed five times a second until within 15 ms.
// Lowered by anything else (the auto-tune), the descent: the pull goes up to 0.4 % (about 4 ms a second, ~7 cents)
// until within 2 ms; and while the buffer is more than 100 ms over the target, everything above that is skipped with a
// crossfade, at a quiet moment if one comes within 2 s. Meanwhile the click-trim's ceiling glides down after the target
// no faster than the buffer does, so a lowered target never trips it.

/// Skipping part of a queue of interleaved stereo without a click (Windows' AudioRingBuffer.SkipWithCrossfade).
public enum CrossfadeSkip {
    public static let fadeFrames = 720      // 15 ms
    public static let alignFrames = 240     // the landing point may move 5 ms either way to line up

    /// The loudest sample in the next `frames` frames from `offset` (a sample index): is the sound about to play quiet?
    public static func peakAhead(_ queue: [Float], from offset: Int, frames: Int) -> Float {
        let end = min(queue.count, offset + frames * 2)
        var peak: Float = 0
        var i = offset
        while i < end {
            peak = max(peak, abs(queue[i]))
            i += 1
        }
        return peak
    }

    /// Skip about `skipFrames` of the queue from `offset` (a sample index): the sound about to play is crossfaded into
    /// the sound the skip lands on, over `fade` frames, the landing point moved up to `align` frames either way to where
    /// the two line up best. The blend is written over the landing point. Returns the frames skipped (the new offset is
    /// `offset + 2 * skipped`); with too little queued to blend, it drops them plainly.
    @discardableResult
    public static func skip(_ queue: inout [Float], from offset: Int, frames skipFrames: Int,
                            fade: Int = fadeFrames, align: Int = alignFrames) -> Int {
        let available = (queue.count - offset) / 2
        var skipping = min(skipFrames, available)
        guard skipping > 0 else { return 0 }
        let align = max(0, min(align, skipping - 1))
        let fade = min(fade, available - skipping - align)
        guard fade >= 16 else { return skipping }
        func sample(_ frame: Int, _ channel: Int) -> Float { queue[offset + frame * 2 + channel] }

        // Where to land: the offset whose next few milliseconds look most like the next few here.
        let probe = min(fade, 240)
        var best = skipping, bestScore = -Double.infinity
        for shift in -align...align {
            let land = skipping + shift
            var dot = 0.0, here = 0.0, there = 0.0
            for f in 0..<probe {
                let a = Double(sample(f, 0) + sample(f, 1)), b = Double(sample(land + f, 0) + sample(land + f, 1))
                dot += a * b
                here += a * a
                there += b * b
            }
            let score = dot / (here * there + 1e-12).squareRoot()
            if score > bestScore {
                bestScore = score
                best = land
            }
        }
        skipping = best
        // Alike (a held note): straight-line gains, which keep its level. Not alike (most skips in music): equal-power.
        let alike = bestScore >= 0.5
        let from = (0..<fade * 2).map { queue[offset + $0] }
        let into = (0..<fade * 2).map { queue[offset + skipping * 2 + $0] }
        for f in 0..<fade {
            let t = (Double(f) + 0.5) / Double(fade)
            let out = Float(alike ? 1 - t : cos(t * Double.pi / 2)), inn = Float(alike ? t : sin(t * Double.pi / 2))
            for c in 0..<2 { queue[offset + (skipping + f) * 2 + c] = from[f * 2 + c] * out + into[f * 2 + c] * inn }
        }
        return skipping
    }
}

/// The click-trim's ceiling (Windows' trimGlideTargetMs): up to a raised target at once, down after a lowered one no
/// faster than 1.5 ms a second - and never below where the buffer still is, so it follows the buffer down.
public struct TrimCeiling {
    public static let glideMsPerSec = 1.5
    public private(set) var ms: Double = 0
    private var last: Double?
    public init() {}

    public mutating func update(targetMs: Double, bufferedMs: Double, now: Double) -> Double {
        if ms <= 0 || targetMs >= ms {
            ms = targetMs
        } else if let last {
            let glided = ms - Self.glideMsPerSec * max(0, now - last)
            ms = max(targetMs, max(glided, min(ms, bufferedMs)))
        }
        last = now
        return ms
    }
}

/// Which way the depth is being steered, and when to snap (Windows' fastApproachUntilOnTarget, descentUntilOnTarget and
/// SnapDownIfFarAbove). One per stream, used on the mixing queue.
public struct DepthSteering {
    public static let applyEverySec = 0.2
    public static let fastDoneMs = 15.0
    public static let descentDoneMs = 2.0
    public static let snapAboveMs = 100
    public static let snapMinSkipMs = 20
    public static let snapWaitSec = 2.0
    public static let snapQuietPeak: Float = 0.0056   // -45 dBFS

    public private(set) var fast = false, descent = false
    private var lastTargetMs: Int?
    private var lastApply = -Double.infinity
    private var snapArmedAt: Double?
    public private(set) var snaps = 0, snapsInQuiet = 0, snappedFrames = 0
    public init() {}

    /// The target changed, by anything: lowered, the descent starts.
    public mutating func target(_ ms: Int) {
        if let lastTargetMs, ms < lastTargetMs { descent = true }
        lastTargetMs = ms
    }

    /// The person moved it: the fast approach, whichever way.
    public mutating func movedByHand() { fast = true }

    /// Before each read, while descending: how many frames to skip now (nil: none) - everything over the target plus
    /// 100 ms, once that is at least 20 ms, at the first quiet moment or after 2 s.
    public mutating func snap(queuedFrames: Int, targetMs: Int, now: Double, rate: Int = 48_000,
                              quietAhead: () -> Bool) -> Int? {
        guard descent else { return nil }
        let excess = queuedFrames - (targetMs + Self.snapAboveMs) * rate / 1000
        guard excess >= Self.snapMinSkipMs * rate / 1000 else {
            snapArmedAt = nil
            return nil
        }
        if snapArmedAt == nil { snapArmedAt = now }
        let quiet = quietAhead()
        guard quiet || now - snapArmedAt! >= Self.snapWaitSec else { return nil }
        snapArmedAt = nil
        snaps += 1
        if quiet { snapsInQuiet += 1 }
        return excess
    }

    /// Note a snap's frames (what the skip really took, after lining up).
    public mutating func snapped(_ frames: Int) { snappedFrames += frames }

    /// Each read: is it time to re-work the pull (five times a second while approaching or descending, once tracking)?
    public mutating func due(now: Double, tracking: Bool) -> Bool {
        guard (fast || descent), tracking, now - lastApply >= Self.applyEverySec else { return false }
        lastApply = now
        return true
    }

    /// Which pull, the modes ending once on target; and the depth to steer: the depth now while approaching fast (a
    /// lagging mean would overshoot at 50 ms a second), else the mean.
    public mutating func pull(depthFrames: Double, meanDepthFrames: Double, targetFrames: Double,
                              rate: Double = 48_000) -> (pull: DriftMeter.Pull, depth: Double) {
        if fast, abs(depthFrames - targetFrames) <= Self.fastDoneMs * rate / 1000 { fast = false }
        if !fast, descent, meanDepthFrames - targetFrames <= Self.descentDoneMs * rate / 1000 { descent = false }
        return fast ? (.fast, depthFrames) : descent ? (.descent, meanDepthFrames) : (.steady, meanDepthFrames)
    }
}
