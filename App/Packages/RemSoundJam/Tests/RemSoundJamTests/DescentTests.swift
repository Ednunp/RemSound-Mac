import Foundation
import XCTest

@testable import RemSoundJam

/// Coming down from a lowered buffer and going up to a raised one: Windows' crossfaded skip, the trim's gliding ceiling,
/// the descent and snap, and the fast approach, on a model of a stream whose queue is steered as the Mac's is.
final class DescentTests: XCTestCase {
    // MARK: the crossfaded skip

    func tone(_ frames: Int, hz: Double = 440, amplitude: Float = 0.5) -> [Float] {
        (0..<frames).flatMap { n -> [Float] in
            let v = amplitude * Float(sin(2 * Double.pi * hz * Double(n) / 48_000))
            return [v, v]
        }
    }
    /// The biggest jump from one sample to the next on the left side.
    func biggestStep(_ s: [Float], from: Int = 0) -> Float {
        stride(from: from + 2, to: s.count, by: 2).reduce(0) { max($0, abs(s[$1] - s[$1 - 2])) }
    }

    func testASkipInAHeldNoteLandsInStepAndLeavesNoClick() {
        var queue = tone(6000)
        let natural = biggestStep(queue)
        let skipped = CrossfadeSkip.skip(&queue, from: 0, frames: 2000)
        XCTAssertLessThanOrEqual(abs(skipped - 2000), 240, "about what was asked, moved at most 5 ms to line up")
        let played = Array(queue[(skipped * 2)...])
        XCTAssertLessThan(biggestStep(played), natural * 1.05, "no bigger a step than the tone's own")
        // Lined up, the blend is the tone carried on at its own level: no dip anywhere through it.
        var lowest = Float.infinity
        for start in stride(from: 0, to: 720 - 110, by: 10) {
            let cycle = stride(from: start * 2, to: (start + 109) * 2, by: 2).map { played[$0] }
            lowest = min(lowest, (cycle.reduce(0) { $0 + $1 * $1 } / Float(cycle.count)).squareRoot())
        }
        XCTAssertEqual(lowest, Float(0.5 / 2.0.squareRoot()), accuracy: 0.01, "every cycle through the blend at the tone's own level")

        // The old way: 1000 frames played, then 2037 cut, wherever that lands.
        let full = tone(6000)
        let joined = Array(full[0..<2000]) + Array(full[((1000 + 2037) * 2)...])
        XCTAssertGreaterThan(biggestStep(joined), natural * 2, "a plain cut mid-note jumps (the click this replaces)")
    }

    func testTwoStretchesThatDoNotLineUpAreBlendedEqualPowerAndNothingBeyondTheQueueIsTouched() {
        var dice = SystemRandomNumberGeneratorSeeded(seed: 3)
        var queue = (0..<8000).flatMap { _ -> [Float] in
            let v = Float(Int(dice.next() % 2001) - 1000) / 4000
            return [v, v]
        }
        let before = queue
        let skipped = CrossfadeSkip.skip(&queue, from: 400, frames: 3000)
        XCTAssertEqual(Array(queue[0..<400]), Array(before[0..<400]), "nothing before the offset changes")
        let blend = queue[(400 + skipped * 2)..<(400 + skipped * 2 + 720 * 2)]
        func rms<C: Collection>(_ c: C) -> Double where C.Element == Float {
            (c.reduce(0) { $0 + Double($1 * $1) } / Double(c.count)).squareRoot()
        }
        XCTAssertEqual(rms(blend) / rms(before), 1, accuracy: 0.15, "noise through the blend keeps its level")
        let land = 400 + skipped * 2
        XCTAssertEqual(queue[land], before[400], accuracy: 0.002, "the blend begins as the sound that was about to play")
        XCTAssertEqual(queue[land + 719 * 2], before[land + 719 * 2], accuracy: 0.002, "and ends as the sound it lands on")
        XCTAssertEqual(Array(queue[(400 + (skipped + 720) * 2)...]), Array(before[(400 + (skipped + 720) * 2)...]),
                       "after the blend the queue is as it was")
    }

    func testTooLittleQueuedToBlendIsDroppedPlainlyAndAnOverlongSkipTakesWhatThereIs() {
        var short = tone(500)
        XCTAssertEqual(CrossfadeSkip.skip(&short, from: 0, frames: 490), 490, "ten frames left: no room to blend")
        XCTAssertEqual(short, tone(500), "a plain drop writes nothing")
        var some = tone(300)
        XCTAssertEqual(CrossfadeSkip.skip(&some, from: 0, frames: 1000), 300)
        var none: [Float] = []
        XCTAssertEqual(CrossfadeSkip.skip(&none, from: 0, frames: 10), 0)
        XCTAssertEqual(CrossfadeSkip.peakAhead(tone(2000), from: 0, frames: 720), 0.5, accuracy: 0.01)
        XCTAssertEqual(CrossfadeSkip.peakAhead([Float](repeating: 0.001, count: 100), from: 0, frames: 720), 0.001)
    }

    // MARK: the trim's ceiling

    func testTheTrimCeilingRisesAtOnceAndComesDownNoFasterThanTheBufferOrOneAndAHalfMsASecond() {
        var ceiling = TrimCeiling()
        XCTAssertEqual(ceiling.update(targetMs: 100, bufferedMs: 100, now: 0), 100)
        XCTAssertEqual(ceiling.update(targetMs: 20, bufferedMs: 104, now: 1), 100, "the buffer has not drained yet: held")
        XCTAssertEqual(ceiling.update(targetMs: 20, bufferedMs: 90, now: 2), 98.5, accuracy: 1e-9, "1.5 ms a second at most")
        XCTAssertEqual(ceiling.update(targetMs: 20, bufferedMs: 50, now: 3), 97, accuracy: 1e-9)
        XCTAssertEqual(ceiling.update(targetMs: 20, bufferedMs: 10, now: 100), 20, "never below the target")
        XCTAssertEqual(ceiling.update(targetMs: 60, bufferedMs: 10, now: 101), 60, "and straight up to a raised one")
    }

    // MARK: the steering

    func testLoweredTheDescentStartsAndASnapWaitsForQuietOrTwoSeconds() {
        var s = DepthSteering()
        s.target(500)
        XCTAssertFalse(s.descent)
        s.target(40)
        XCTAssertTrue(s.descent)
        // 500 ms queued against 40: 360 ms over the 140 kept.
        XCTAssertNil(s.snap(queuedFrames: 500 * 48, targetMs: 40, now: 0) { false }, "loud: wait for a pause")
        XCTAssertNil(s.snap(queuedFrames: 500 * 48, targetMs: 40, now: 1.9) { false })
        XCTAssertEqual(s.snap(queuedFrames: 500 * 48, targetMs: 40, now: 2.0) { false }, 360 * 48, "two seconds: now anyway")
        XCTAssertEqual(s.snap(queuedFrames: 300 * 48, targetMs: 40, now: 2.1) { true }, 160 * 48, "quiet: at once")
        XCTAssertEqual(s.snaps, 2)
        XCTAssertEqual(s.snapsInQuiet, 1)
        XCTAssertNil(s.snap(queuedFrames: 159 * 48, targetMs: 40, now: 3) { true }, "under 20 ms over the 140: the drain's job")
        var steady = DepthSteering()
        steady.target(40)
        steady.target(60)
        XCTAssertNil(steady.snap(queuedFrames: 500 * 48, targetMs: 60, now: 0) { true }, "raised, nothing snaps")
    }

    func testThePullIsReworkedFiveTimesASecondOnlyWhileSteeringAndEachModeEndsOnTarget() {
        var s = DepthSteering()
        XCTAssertFalse(s.due(now: 0, tracking: true), "steady: the drift windows do it")
        s.movedByHand()
        XCTAssertFalse(s.due(now: 0, tracking: false), "not before the clocks are measured")
        XCTAssertTrue(s.due(now: 0, tracking: true))
        XCTAssertFalse(s.due(now: 0.1, tracking: true))
        XCTAssertTrue(s.due(now: 0.2, tracking: true))
        XCTAssertEqual(s.pull(depthFrames: 20 * 48, meanDepthFrames: 30 * 48, targetFrames: 120 * 48).pull, .fast)
        XCTAssertEqual(s.pull(depthFrames: 20 * 48, meanDepthFrames: 30 * 48, targetFrames: 120 * 48).depth, 20 * 48,
                       "fast steers the depth now")
        XCTAssertEqual(s.pull(depthFrames: 106 * 48, meanDepthFrames: 100 * 48, targetFrames: 120 * 48).pull, .steady,
                       "within 15 ms: back to steady")
        s.target(120)
        s.target(40)
        XCTAssertEqual(s.pull(depthFrames: 100 * 48, meanDepthFrames: 101 * 48, targetFrames: 40 * 48).pull, .descent)
        XCTAssertEqual(s.pull(depthFrames: 100 * 48, meanDepthFrames: 101 * 48, targetFrames: 40 * 48).depth, 101 * 48,
                       "the descent steers the mean")
        XCTAssertEqual(s.pull(depthFrames: 42 * 48, meanDepthFrames: 41.9 * 48, targetFrames: 40 * 48).pull, .steady,
                       "within 2 ms: down")
        XCTAssertFalse(s.descent)
        XCTAssertEqual(DriftMeter.Pull.fast.maxBias, 0.05)
        XCTAssertEqual(DriftMeter.Pull.descent.maxBias, 0.004)
        XCTAssertEqual(DriftMeter.Pull.steady.maxBias, DriftMeter.maxDepthBias)
    }

    func testAtAWindowsEndTheSteadyPullSteersTheMeanDepthAndTheFastOneTheDepthNow() {
        // A depth that swings 0, 1920, 0, 1920... frames block by block: its mean is the 960 target, any one moment 960 off.
        func pullAfterFirstWindow(_ pull: DriftMeter.Pull) -> Double {
            var meter = DriftMeter()
            meter.pull = pull
            var t = 0.0, n = 0
            while !meter.tracking && t < 12 {
                meter.produced(96, now: t)
                meter.consumed(96, now: t)
                _ = meter.update(depthFrames: n % 2 == 0 ? 0 : 1920, targetFrames: 960, now: t)
                n += 1
                t += 0.002
            }
            XCTAssertTrue(meter.tracking)
            return meter.ratio - meter.clockRatio
        }
        XCTAssertLessThan(abs(pullAfterFirstWindow(.steady)), 1e-4, "the mean is on target: next to no pull")
        XCTAssertGreaterThan(abs(pullAfterFirstWindow(.fast)), 1e-3, "approaching fast it answers the depth now, as Windows")
    }

    // MARK: a stream steered as the Mac's is

    /// A sender and the mix on one clock, 5 ms packets and 2 ms mix blocks; the queue read through the steering as
    /// StreamDecoder.read does. `lower`/`raise` at `at` seconds: by hand, or (lower only) by the auto-tune.
    struct Stream {
        var meter = DriftMeter()
        var steering = DepthSteering()
        var depth = 0.0
        var targetMs: Int
        var started = false
        var underruns = 0
        var biggestPull = 0.0
        var snappedMs = 0.0
        var at: [(t: Double, depthMs: Double)] = []

        init(targetMs: Int) {
            self.targetMs = targetMs
            steering.target(targetMs)
        }

        mutating func setTarget(_ ms: Int, byHand: Bool) {
            steering.target(ms)
            let lowered = ms < targetMs
            targetMs = ms
            if byHand {
                steering.movedByHand()
                // Lowered by hand: the excess goes at once (crossfaded in the app).
                if lowered, depth > Double(ms * 48) { depth = Double(ms * 48) }
            }
        }

        mutating func run(from start: Double, until end: Double) {
            var nextPacket = start, nextBlock = start
            while min(nextPacket, nextBlock) < end {
                if nextPacket <= nextBlock {
                    meter.produced(240, now: nextPacket)
                    depth += 240
                    nextPacket += 0.005
                    continue
                }
                let now = nextBlock
                nextBlock += 0.002
                meter.consumed(96, now: now)
                if let snap = steering.snap(queuedFrames: Int(depth), targetMs: targetMs, now: now, quietAhead: { false }) {
                    depth -= Double(snap)
                    snappedMs += Double(snap) / 48
                }
                var ratio = meter.update(depthFrames: depth, targetFrames: Double(targetMs * 48), now: now)
                if steering.due(now: now, tracking: meter.tracking) {
                    let (pull, steer) = steering.pull(depthFrames: depth, meanDepthFrames: meter.meanDepthFrames,
                                                      targetFrames: Double(targetMs * 48))
                    meter.pull = pull
                    meter.repull(depthFrames: steer, targetFrames: Double(targetMs * 48))
                    ratio = meter.ratio
                }
                if meter.tracking { biggestPull = max(biggestPull, abs(ratio - meter.clockRatio)) }
                if !started {
                    if depth >= Double(targetMs * 48) { started = true } else { continue }
                }
                let need = 96 * ratio
                if depth < need {
                    underruns += 1
                    started = false
                    continue
                }
                // The depth as the mix finds it, before it takes its block: what is steered.
                at.append((now, depth / 48))
                depth -= need
            }
        }
        /// The mean depth over the tenth of a second up to `t` (the packets' 5 ms sawtooth averaged out).
        func depthMs(at t: Double) -> Double {
            let span = at.filter { $0.t <= t && $0.t > t - 0.1 }
            return span.isEmpty ? .nan : span.reduce(0) { $0 + $1.depthMs } / Double(span.count)
        }
    }

    func testTheAutoTuneComingDownFromHalfASecondSnapsThenDrainsInUnderHalfAMinuteWithoutAGap() {
        var s = Stream(targetMs: 500)
        s.run(from: 0, until: 12)          // tracking: the first window is in
        XCTAssertEqual(s.depthMs(at: 11.9), 500, accuracy: 6)
        s.setTarget(40, byHand: false)
        s.run(from: 12, until: 45)
        XCTAssertEqual(s.snappedMs, 360, accuracy: 10, "all but 100 ms over the target skipped two seconds in")
        XCTAssertLessThan(s.depthMs(at: 14.5), 145)
        XCTAssertEqual(s.depthMs(at: 44), 40, accuracy: 3, "and the rest drained within half a minute")
        XCTAssertLessThanOrEqual(s.biggestPull, 0.004 + 1e-9, "never faster than 0.4 %: about 7 cents")
        XCTAssertEqual(s.underruns, 0)
        XCTAssertFalse(s.steering.descent, "then back to steady")
    }

    func testRaisedByHandTheBufferGlidesUpInSecondsWithoutAGap() {
        var s = Stream(targetMs: 20)
        s.run(from: 0, until: 12)
        s.setTarget(120, byHand: true)
        s.run(from: 12, until: 20)
        XCTAssertGreaterThan(s.depthMs(at: 16), 85, "most of the 100 ms in four seconds (a third of what is left a second)")
        XCTAssertGreaterThan(s.depthMs(at: 19.9), 103, "within 15 ms, then the steady pull")
        XCTAssertLessThan(s.depthMs(at: 19.9), 125, "without overshooting")
        XCTAssertLessThanOrEqual(s.biggestPull, 0.05 + 1e-9, "5 % at most")
        XCTAssertGreaterThan(s.biggestPull, 0.03, "and it did pull hard")
        XCTAssertEqual(s.underruns, 0, "a glide, never a gap")
        XCTAssertFalse(s.steering.fast, "arrived: back to steady")
    }

    func testLoweredByHandItIsThereAtOnce() {
        var s = Stream(targetMs: 200)
        s.run(from: 0, until: 12)
        s.setTarget(20, byHand: true)
        s.run(from: 12, until: 13)
        XCTAssertEqual(s.depthMs(at: 12.5), 20, accuracy: 6)
        XCTAssertEqual(s.snappedMs, 0, "the hand's own skip, not the snap")
        XCTAssertEqual(s.underruns, 0)
    }
}
