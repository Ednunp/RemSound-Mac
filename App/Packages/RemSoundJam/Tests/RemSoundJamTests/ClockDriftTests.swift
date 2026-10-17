import Foundation
import XCTest

@testable import RemSoundJam

/// Keeping in time: the clock meter and the resampler, on a model of a queue between two clocks that differ.
final class ClockDriftTests: XCTestCase {
    /// A queue between a producer whose clock runs `ppm` fast and a consumer that takes `block` frames at a time by
    /// the clock time is told in. The producer makes `lump` frames at a time, each up to `jitterMs` late. Frames only:
    /// the consumer takes `block * ratio` of them, as the resampler would.
    struct Model {
        var meter = DriftMeter()
        var depth = 0.0
        var target: Double
        var started = false
        var underruns = 0
        var corrected = true
        let ppm: Double, lump: Int, block: Int, jitterMs: Double
        var dice = SystemRandomNumberGeneratorSeeded(seed: 7)
        var nextProducer = 0.0, nextConsumer = 0.0
        var producerLumps = 0, consumerBlocks = 0
        var now = 0.0
        /// A stall: between these seconds the producer makes nothing, then carries on (what it would have made is lost).
        var stall: ClosedRange<Double>?
        /// The depth each consumer block found, from `recordFrom` on (ms).
        var recordFrom = Double.infinity
        var depths: [Double] = []
        var biggestPull = 0.0

        init(ppm: Double, targetMs: Double, lump: Int = 120, block: Int = 96, jitterMs: Double = 0) {
            self.ppm = ppm
            self.lump = lump
            self.block = block
            self.jitterMs = jitterMs
            target = targetMs * 48
        }

        mutating func run(until end: Double) {
            let producerPeriod = Double(lump) / (48_000 * (1 + ppm / 1_000_000))
            let consumerPeriod = Double(block) / 48_000
            while min(nextProducer, nextConsumer) < end {
                if nextProducer <= nextConsumer {
                    let due = nextProducer
                    producerLumps += 1
                    nextProducer = Double(producerLumps) * producerPeriod
                    if let stall, stall.contains(due) { continue }
                    now = due + Double(dice.next() % 1000) / 1000 * jitterMs / 1000
                    depth += Double(lump)
                    meter.produced(lump, now: now)
                } else {
                    now = nextConsumer
                    consumerBlocks += 1
                    nextConsumer = Double(consumerBlocks) * consumerPeriod
                    meter.consumed(block, now: now)
                    let ratio = corrected ? meter.update(depthFrames: depth, targetFrames: target, now: now) : 1
                    biggestPull = max(biggestPull, abs(ratio - meter.clockRatio))
                    if !started {
                        if depth >= target { started = true } else { continue }
                    }
                    let need = Double(block) * ratio
                    if depth < need {
                        underruns += 1
                        started = false
                        continue
                    }
                    // The depth as the consumer finds it, before it takes its block: what the meter is told and steers.
                    if now >= recordFrom { depths.append(depth / 48) }
                    depth -= need
                }
            }
        }
        var meanDepthMs: Double { depths.isEmpty ? .nan : depths.reduce(0, +) / Double(depths.count) }
    }

    // MARK: the meter

    func testNothingIsResampledUntilAWholeWindowHasBeenMeasured() {
        var model = Model(ppm: 300, targetMs: 20)
        model.run(until: 9.9)
        XCTAssertFalse(model.meter.tracking, "no reading before ten seconds are up")
        XCTAssertEqual(model.meter.ratio, 1, "and until one, sound is played exactly as it came")
        model.run(until: 10.2)
        XCTAssertTrue(model.meter.tracking, "the first window's reading is taken as it is")
        XCTAssertEqual(model.meter.accepted, 1)
    }

    func testAFastSenderIsMeasuredAndTheQueueHeldAtItsTarget() {
        for ppm in [300.0, -300.0, 40.0] {
            var model = Model(ppm: ppm, targetMs: 20)
            model.recordFrom = 60
            model.run(until: 300)
            XCTAssertEqual(model.meter.ppm, ppm, accuracy: 15, "the clocks' difference, measured (\(ppm) ppm)")
            XCTAssertEqual(model.underruns, 0, "the queue must never run dry (\(ppm) ppm)")
            XCTAssertEqual(model.meanDepthMs, 20, accuracy: 1.5, "and its depth is held at the target (\(ppm) ppm)")
            XCTAssertLessThan(model.depths.max()! - model.depths.min()!, 6, "without wandering (\(ppm) ppm)")

            // The same, left alone: the test must be able to fail.
            var alone = Model(ppm: ppm, targetMs: 20)
            alone.corrected = false
            alone.recordFrom = 60
            alone.run(until: 300)
            let wandered = abs((alone.depths.last ?? 0) - 20) > 3 || alone.underruns > 0
            if abs(ppm) >= 300 { XCTAssertTrue(wandered, "left alone, \(ppm) ppm must walk the queue away or run it dry") }
        }
    }

    func testPacketsThatComeInBunchesAndLateStillGiveATrueReading() {
        // 10 ms bunches, each up to 4 ms late: whole lumps at a window's edge would put a reading 1,000 ppm out.
        var model = Model(ppm: 120, targetMs: 30, lump: 480, block: 96, jitterMs: 4)
        model.run(until: 10.2)
        XCTAssertEqual(model.meter.lastReading ?? 0, 1.00012, accuracy: 0.00012,
                       "the first reading, read off the line through the bunches, is within 120 ppm of the truth")
        model.recordFrom = 60
        model.run(until: 240)
        XCTAssertEqual(model.meter.ppm, 120, accuracy: 40)
        XCTAssertEqual(model.underruns, 0)
    }

    func testASoundCardThatTakesWholeBuffersIsMeasuredAsTruly() {
        // The other way about: the mixer makes 96 frames at a time, the card takes 512.
        var model = Model(ppm: -150, targetMs: 25, lump: 96, block: 512)
        model.recordFrom = 60
        model.run(until: 240)
        XCTAssertEqual(model.meter.ppm, -150, accuracy: 25)
        XCTAssertEqual(model.underruns, 0)
        XCTAssertEqual(model.meanDepthMs, 25, accuracy: 6)
    }

    func testAWindowTheStreamStalledInIsThrownAway() {
        var model = Model(ppm: 200, targetMs: 40)
        model.run(until: 20.5)
        let before = model.meter.clockRatio
        let accepted = model.meter.accepted
        model.stall = 24.0...24.15   // 150 ms of nothing, in the third window
        model.run(until: 30.5)
        XCTAssertEqual(model.meter.rejected, 1, "the window the stall fell in is not a clock reading")
        XCTAssertEqual(model.meter.accepted, accepted)
        XCTAssertEqual(model.meter.clockRatio, before, "and what was known is kept")
        XCTAssertNotNil(model.meter.lastReading)
        XCTAssertLessThan(model.meter.lastReading!, 0.9999, "though it read like a slow clock: 150 ms short in ten seconds")
        model.stall = nil
        model.run(until: 50.5)
        XCTAssertEqual(model.meter.accepted, accepted + 2, "the windows after it are believed again")
    }

    func testTheWindowAfterAStallDoesNotStartInsideIt() {
        // A stall that loses 150 ms of sound and ends just as a window is due. The window it fell in is thrown away -
        // and the next must not start on a count still read off the line from before the stall: that made a window
        // with nothing wrong in it read hundreds of parts per million slow.
        for stallStart in [19.80, 19.88, 19.95, 20.0] {
            var model = Model(ppm: 150, targetMs: 40)
            model.run(until: 19.5)
            model.stall = stallStart...(stallStart + 0.15)
            model.run(until: 21)
            model.stall = nil
            model.run(until: 45)
            XCTAssertEqual(model.meter.rejected, 1, "the window the stall fell in (stall at \(stallStart))")
            XCTAssertEqual(model.meter.lastReading ?? 0, 1.00015, accuracy: 0.00003,
                           "the window after it reads the clocks as they are (stall at \(stallStart))")
            XCTAssertEqual(model.meter.ppm, 150, accuracy: 25, "and what is believed is true (stall at \(stallStart))")
        }
    }

    func testAReadingNoClockCouldGiveIsThrownAway() {
        var meter = DriftMeter()
        // The producer makes twice what the consumer takes.
        var t = 0.0
        while t < 10.5 {
            meter.produced(192, now: t)
            meter.consumed(96, now: t)
            _ = meter.update(depthFrames: 960, targetFrames: 960, now: t)
            t += 0.002
        }
        XCTAssertEqual(meter.rejected, 1)
        XCTAssertFalse(meter.tracking)
        XCTAssertEqual(meter.ratio, 1)
    }

    func testALaterReadingCountsForThirtyPercent() {
        // The producer's clock steps to 1,000 ppm fast.
        var meter = DriftMeter()
        var t = 0.0
        var producerFrames = 0.0
        func feed(_ seconds: Double, ppm: Double) {
            let end = t + seconds
            while t < end {
                producerFrames += 96 * (1 + ppm / 1_000_000)
                let whole = Int(producerFrames)
                producerFrames -= Double(whole)
                meter.produced(whole, now: t)
                meter.consumed(96, now: t)
                _ = meter.update(depthFrames: 1920, targetFrames: 1920, now: t)
                t += 0.002
            }
        }
        feed(10.3, ppm: 0)
        XCTAssertEqual(meter.ppm, 0, accuracy: 5)
        feed(10, ppm: 1000)
        XCTAssertEqual(meter.ppm, 300, accuracy: 25, "one window at 1,000 ppm moves it 30 % of the way")
        feed(10, ppm: 1000)
        XCTAssertEqual(meter.ppm, 510, accuracy: 30, "and the next, 30 % of what is left")
    }

    func testAQueueLeftStandingDeepIsWalkedBackNeverFasterThanThreeTenthsOfAPercent() {
        var model = Model(ppm: 0, targetMs: 20)
        model.run(until: 10.5)
        model.depth += 60 * 48   // a stall-then-burst leaves 60 ms more standing
        model.recordFrom = 10.5
        model.run(until: 120)
        XCTAssertLessThanOrEqual(model.biggestPull, DriftMeter.maxDepthBias + 1e-9, "the pull is never more than 0.3 %")
        XCTAssertGreaterThan(model.biggestPull, 0.0025, "and against 60 ms it is all of that")
        XCTAssertEqual(model.depths.last ?? 0, 20, accuracy: 2.5, "two minutes on the queue is back at its target")
        XCTAssertEqual(model.underruns, 0, "without overshooting into a gap")
        XCTAssertEqual(model.meter.ppm, 0, accuracy: 10, "and the clocks' own reading was not disturbed by it")
    }

    // MARK: the count read off its line

    func testACountInLumpsIsReadAsTheLineThroughThem() {
        var count = SteadyCount(rate: 48_000)
        var worstRaw = 0.0, worstLine = 0.0
        var t = 0.0
        var made = 0
        // 480 frames every 10 ms; looked at every millisecond in between.
        for step in 0..<3000 {
            t = Double(step) * 0.001
            if step % 10 == 0 {
                count.add(480, now: t)
                made += 480
            }
            guard t > 0.5 else { continue }
            let truth = t * 48_000 + 240   // the steady line through the lumps' middles
            worstRaw = max(worstRaw, abs(Double(made) - truth))
            worstLine = max(worstLine, abs(count.value(at: t) - truth - 240))
        }
        XCTAssertGreaterThan(worstRaw, 200, "the count as it stands is up to half a lump out")
        XCTAssertLessThan(worstLine, 1, "read off the line it is steady to a frame")
    }

    func testALongWaitBreaksTheLine() {
        var count = SteadyCount(rate: 48_000)
        var t = 0.0
        while t < 1.0 {
            count.add(480, now: t)
            t += 0.01
        }
        XCTAssertTrue(count.settled(at: 1.0))
        let before = count.total
        // 150 ms of nothing, its sound lost; then the stream carries on. The lumps from before the stall are still
        // within the fifth of a second the line is read through, but they are on the other side of a break.
        count.add(480, now: 1.14)
        XCTAssertFalse(count.settled(at: 1.14), "one lump after a break is not a line")
        XCTAssertEqual(count.value(at: 1.14), Double(before + 480), accuracy: 0.5,
                       "and the count is as it stands, not the line from before the stall carried on through it")
        t = 1.15
        while t < 1.29 {
            count.add(480, now: t)
            t += 0.01
        }
        XCTAssertTrue(count.settled(at: 1.29), "a tenth of a second of lumps after the break is a line again")
    }

    func testLumpsWithinHalfAMillisecondAreOneLumpAndGapsAreTimed() {
        var count = SteadyCount(rate: 48_000)
        count.add(120, now: 1.0)
        count.add(120, now: 1.0002)
        count.add(120, now: 1.0004)
        XCTAssertEqual(count.takeLumps(), 1, "three packets read from the socket together are one arrival")
        XCTAssertEqual(count.total, 360)
        count.add(120, now: 1.0104)
        count.add(120, now: 1.2)
        XCTAssertEqual(count.takeLongestGap(now: 1.21), 0.1896, accuracy: 1e-9)
        XCTAssertEqual(count.takeLongestGap(now: 1.5), 0.3, accuracy: 1e-9, "a wait still open counts")
    }

    // MARK: the resampler

    func testAtRatioOneTheSoundComesOutAsItWentIn() {
        var resampler = StereoResampler()
        let input = (0..<800).map { Float($0) }   // 400 frames: left 0, 2, 4...; right 1, 3, 5...
        var out: [Float] = []
        var taken = 0
        for block in 0..<4 {
            let need = resampler.inputFrames(forOutput: 50, ratio: 1)
            XCTAssertEqual(need, block == 0 ? 52 : 50, "it holds two frames of its own, taken with the first block")
            out += resampler.pull(Array(input[(taken * 2)..<((taken + need) * 2)]), outFrames: 50, ratio: 1)
            taken += need
        }
        XCTAssertEqual(out, Array(input[..<400]), "sample for sample, and not a frame late")
    }

    func testBroughtInPartWayThroughItCarriesStraightOn() {
        // 100 frames played as they came, then the resampler brought in at a ratio a little off 1: no jump at the join.
        var resampler = StereoResampler()
        var played: [Float] = []
        var phase = 0
        func tone(_ frames: Int) -> [Float] {
            var block = [Float](repeating: 0, count: frames * 2)
            for i in 0..<frames {
                block[2 * i] = Float(0.5 * sin(2 * Double.pi * 1000 * Double(phase + i) / 48_000))
                block[2 * i + 1] = block[2 * i]
            }
            phase += frames
            return block
        }
        played += tone(100)
        for _ in 0..<5 {
            let need = resampler.inputFrames(forOutput: 96, ratio: 1.0003)
            played += resampler.pull(tone(need), outFrames: 96, ratio: 1.0003)
        }
        var biggest: Float = 0
        for i in 1..<(played.count / 2) { biggest = max(biggest, abs(played[2 * i] - played[2 * i - 2])) }
        XCTAssertLessThan(biggest, Float(0.5 * 2 * Double.pi * 1000 / 48_000 * 1.05))
    }

    func testPulledFastItTakesMoreInputAndTheToneRisesByExactlyThatMuch() {
        for ratio in [1.0005, 0.9995, 1.003] {
            var resampler = StereoResampler()
            var phase = 0
            var out: [Float] = []
            var taken = 0
            for _ in 0..<1000 {   // 1000 blocks of 96 = 2 s
                let need = resampler.inputFrames(forOutput: 96, ratio: ratio)
                var input = [Float](repeating: 0, count: need * 2)
                for i in 0..<need {
                    let x = Float(0.5 * sin(2 * Double.pi * 1000 * Double(phase + i) / 48_000))
                    input[2 * i] = x
                    input[2 * i + 1] = -x
                }
                phase += need
                taken += need
                out += resampler.pull(input, outFrames: 96, ratio: ratio)
            }
            XCTAssertEqual(Double(taken), 96_000 * ratio + 2, accuracy: 1.5, "it takes ratio times what it gives, and the two frames it holds")
            XCTAssertEqual(out.count, 192_000)
            // The tone's pitch, from its upward zero crossings over the last second.
            var first = -1.0, last = -1.0, crossings = 0
            var biggest: Float = 0
            for i in 48_001..<96_000 {
                let a = out[2 * i - 2], b = out[2 * i]
                biggest = max(biggest, abs(b - a))
                XCTAssertEqual(out[2 * i + 1], -b, "the right channel is resampled exactly as the left")
                if a < 0 && b >= 0 {
                    let at = Double(i - 1) + Double(a / (a - b))
                    if first < 0 { first = at }
                    last = at
                    crossings += 1
                }
            }
            let hz = Double(crossings - 1) / ((last - first) / 48_000)
            XCTAssertEqual(hz, 1000 * ratio, accuracy: 0.02, "the tone comes out at ratio times its pitch")
            XCTAssertLessThan(biggest, Float(0.5 * 2 * Double.pi * 1000 * ratio / 48_000 * 1.05), "with no jump a sine could not make")
        }
    }

    func testPushedItGivesFewerFramesWhenTheProducerIsFastAndLosesNothing() {
        for ratio in [1.0002, 0.9998] {
            var resampler = StereoResampler()
            var made = 0
            var out: [Float] = []
            for _ in 0..<5000 {   // 5000 blocks of 96 = 10 s
                var input = [Float](repeating: 0, count: 192)
                for i in 0..<96 {
                    input[2 * i] = Float(0.5 * sin(2 * Double.pi * 440 * Double(made + i) / 48_000))
                    input[2 * i + 1] = input[2 * i]
                }
                made += 96
                out += resampler.push(input, ratio: ratio)
            }
            XCTAssertEqual(Double(out.count / 2), 480_000 / ratio, accuracy: 1.5, "what goes in comes out, one ratio-th as many")
            var biggest: Float = 0
            for i in 1000..<(out.count / 2) { biggest = max(biggest, abs(out[2 * i] - out[2 * i - 2])) }
            XCTAssertLessThan(biggest, Float(0.5 * 2 * Double.pi * 440 / 48_000 * 1.05), "and no block's edge is a jump")
        }
    }

    // MARK: what the log says

    func testTheLogSaysEachClockOrThatItIsStillBeingMeasured() {
        let measured = JamLogLines.Stream(peer: "ED_DT", stream: 7, codec: "Opus", frames: 120, packets: 400, maxGapMs: 3.2,
            concealed: 0, underruns: 0, queuedMs: 10, targetMs: 10, clock: JamLogLines.Clock(ppm: 212.4))
        var waiting = measured
        waiting.clock = JamLogLines.Clock(ppm: nil)
        var off = measured
        off.clock = nil
        XCTAssertTrue(JamLogLines.streams([measured], sending: "not sending").hasSuffix("queued=10ms target=10ms clock=+212ppm"))
        XCTAssertTrue(JamLogLines.streams([waiting], sending: "not sending").hasSuffix("target=10ms clock=measuring"))
        XCTAssertTrue(JamLogLines.streams([off], sending: "not sending").hasSuffix("target=10ms"), "and nothing while clocks are not kept")
        XCTAssertEqual(JamLogLines.Clock(ppm: -38.6).text, "clock=-39ppm")
        XCTAssertEqual(JamLogLines.outputCard(ppm: -150, cushionFrames: 848, laidFrames: 848, cutFrames: 14_400, ranDry: 0),
                       "clock=-150ppm cushion=17.7ms laid=17.7ms cut=300.0ms ran-dry=0")
        XCTAssertEqual(JamLogLines.outputCard(ppm: nil, cushionFrames: 256, laidFrames: 256, cutFrames: 0, ranDry: 2),
                       "clock=measuring cushion=5.3ms laid=5.3ms cut=0.0ms ran-dry=2")
    }

    // MARK: the two together, on real frames

    func testThroughTheResamplerTheQueueIsHeldAndTheToneStaysWhole() {
        // A sender 250 ppm fast, 2.5 ms packets, a 10 ms buffer, the mixer taking 96 frames: a minute.
        var meter = DriftMeter()
        var resampler = StereoResampler()
        var queue: [Float] = []
        var head = 0
        let target = 480
        var started = false
        var underruns = 0
        var made = 0
        var out: [Float] = []
        let producerPeriod = 120.0 / (48_000 * 1.00025)
        var lumps = 0, blocks = 0
        var nextProducer = 0.0, nextConsumer = 0.0
        var depthsMs: [Double] = []
        while min(nextProducer, nextConsumer) < 60 {
            if nextProducer <= nextConsumer {
                let now = nextProducer
                lumps += 1
                nextProducer = Double(lumps) * producerPeriod
                for i in 0..<120 {
                    let x = Float(0.5 * sin(2 * Double.pi * 1000 * Double(made + i) / 48_000))
                    queue.append(x)
                    queue.append(x)
                }
                made += 120
                meter.produced(120, now: now)
            } else {
                let now = nextConsumer
                blocks += 1
                nextConsumer = Double(blocks) * 0.002
                meter.consumed(96, now: now)
                let depth = (queue.count - head) / 2
                let ratio = meter.update(depthFrames: Double(depth), targetFrames: Double(target), now: now)
                if !started {
                    if depth >= target { started = true } else { continue }
                }
                let need = resampler.inputFrames(forOutput: 96, ratio: ratio)
                if depth < need {
                    underruns += 1
                    started = false
                    resampler.reset()
                    continue
                }
                let block = resampler.pull(Array(queue[head..<(head + need * 2)]), outFrames: 96, ratio: ratio)
                head += need * 2
                if head > 96_000 {
                    queue.removeFirst(head)
                    head = 0
                }
                if now > 30 {
                    out += block
                    depthsMs.append(Double(depth) / 48)
                }
            }
        }
        XCTAssertEqual(underruns, 0)
        XCTAssertEqual(meter.ppm, 250, accuracy: 20)
        XCTAssertEqual(depthsMs.reduce(0, +) / Double(depthsMs.count), 10, accuracy: 2)
        XCTAssertLessThan(depthsMs.max()! - depthsMs.min()!, 5, "the queue holds still")
        var biggest: Float = 0
        for i in 1..<(out.count / 2) { biggest = max(biggest, abs(out[2 * i] - out[2 * i - 2])) }
        XCTAssertLessThan(biggest, Float(0.5 * 2 * Double.pi * 1000 / 48_000 * 1.06), "and half a minute of tone has not one click in it")
    }
}

/// Dice that give the same run every time.
struct SystemRandomNumberGeneratorSeeded {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
