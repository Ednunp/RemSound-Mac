import Foundation
import XCTest

@testable import RemSoundJam

/// The output card's clock keeper, on a model of a card: it takes `card` frames at a time by a clock of its own.
final class OutputClockTests: XCTestCase {
    final class Queue: OutputQueue {
        private var samples: [Float] = []
        private var head = 0
        private(set) var writtenFrames = 0
        var pullTotals: (frames: UInt64, count: UInt64)? = (0, 0)
        var available: Int { (samples.count - head) / 2 }
        @discardableResult func discard(_ frames: Int) -> Int {
            let n = min(frames, available)
            head += n * 2
            return n
        }
        func write(_ new: [Float]) {
            let accepted = new.count / 2 <= OutputClock.maximumQueueFrames - available ? new.count / 2 : 0
            samples += new.prefix(accepted * 2)
            writtenFrames += accepted
        }
        /// The card's callback: what there is, up to `frames`.
        func take(_ frames: Int) -> [Float] {
            if frames > 0, pullTotals != nil {
                pullTotals!.frames += UInt64(frames)
                pullTotals!.count += 1
            }
            let n = min(frames, available)
            let out = Array(samples[head..<(head + n * 2)])
            head += n * 2
            if head > 200_000 {
                samples.removeFirst(head)
                head = 0
            }
            return out
        }
    }

    struct Run {
        var shortTakes = 0
        var lastShortAt = -1.0
        var depthsMs: [Double] = []
        var heard: [Float] = []
        var clock = OutputClock()
    }

    /// A card `ppm` fast taking `card` frames at a time, a mix of `block` frames made up to `lateMs` late, for `seconds`.
    /// `cardStartsAt`: the card takes nothing before then. `says`: what the app was told the card takes. `kept`: with
    /// the clock keeper, or written straight in as it used to be.
    func run(card: Int, block: Int, ppm: Double, seconds: Double, lateMs: Double = 1, cardStartsAt: Double = 0,
             says: Int? = nil, kept: Bool = true, recordFrom: Double = 40, mixStalls: ClosedRange<Double>? = nil) -> Run {
        let queue = Queue()
        var result = Run()
        result.clock.cardFrames = says ?? card
        var dice = SystemRandomNumberGeneratorSeeded(seed: 3)
        let cardPeriod = Double(card) / (48_000 * (1 + ppm / 1_000_000))
        let blockPeriod = Double(block) / 48_000
        var cards = 0, blocks = 0, made = 0
        var nextCard = cardStartsAt, nextBlock = 0.0
        var firstWrite = Double.infinity
        while min(nextCard, nextBlock) < seconds {
            if nextCard <= nextBlock {
                let now = nextCard
                cards += 1
                nextCard = cardStartsAt + Double(cards) * cardPeriod
                let got = queue.take(card)
                if now > firstWrite + 0.05, got.count / 2 < card {
                    result.shortTakes += 1
                    result.lastShortAt = now
                }
                if now >= recordFrom { result.heard += got }
            } else {
                let now = nextBlock + Double(dice.next() % 1000) / 1000 * lateMs / 1000
                blocks += 1
                let due = nextBlock
                nextBlock = Double(blocks) * blockPeriod
                if let mixStalls, mixStalls.contains(due) { continue }   // the timer stalled: these blocks are never made
                var samples = [Float](repeating: 0, count: block * 2)
                for i in 0..<block {
                    let x = Float(0.5 * sin(2 * Double.pi * 1000 * Double(made + i) / 48_000))
                    samples[2 * i] = x
                    samples[2 * i + 1] = x
                }
                made += block
                if now >= recordFrom { result.depthsMs.append(Double(queue.available) / 48) }
                if kept { result.clock.write(samples, to: queue, now: now) } else { queue.write(samples) }
                firstWrite = min(firstWrite, now)
            }
        }
        return result
    }

    func testEveryCardAndMixBlockIsHeldAtItsCushionAndNeverRunsDry() {
        for (card, block) in [(512, 240), (512, 96), (64, 96), (128, 96), (256, 240), (1024, 240)] {
            for ppm in [200.0, -200.0] {
                let r = run(card: card, block: block, ppm: ppm, seconds: 120)
                let cushionMs = Double(OutputClock.cushion(cardFrames: card, blockFrames: block)) / 48
                let mean = r.depthsMs.reduce(0, +) / Double(r.depthsMs.count)
                let what = "card \(card), block \(block), \(ppm) ppm"
                XCTAssertLessThan(r.lastShortAt, 12, "after measuring the actual pull, steady playback stays fed (\(what))")
                XCTAssertEqual(r.clock.cushionFrames, Int(cushionMs * 48), what)
                XCTAssertEqual(r.clock.cutFrames, 0, "no cut at a target transition or in steady playback (\(what))")
                XCTAssertEqual(mean, cushionMs, accuracy: 2.5, "the queue is held at its cushion (\(what))")
                XCTAssertEqual(r.clock.ppm ?? .nan, -ppm, accuracy: 30, "the card's clock, measured against the mix's (\(what))")
            }
        }
    }

    func testLeftAloneTheSameQueueWalksAway() {
        // As it was: written straight in. The card 200 ppm slow takes 9.6 frames a second fewer than the mix makes.
        let r = run(card: 512, block: 240, ppm: -200, seconds: 120, cardStartsAt: 0.03, kept: false, recordFrom: 1)
        XCTAssertGreaterThan(r.depthsMs.last! - r.depthsMs.first!, 15, "two minutes puts 23 ms more in the queue, and it never comes back")
        // And a card a little fast that starts level with the mix keeps finding the queue short: nothing ever laid a
        // cushion, and each time is a gap in the sound.
        let dry = run(card: 512, block: 240, ppm: 200, seconds: 20, kept: false)
        XCTAssertGreaterThan(dry.shortTakes, 5, "with no cushion the card runs dry again and again")
        XCTAssertEqual(run(card: 512, block: 240, ppm: 200, seconds: 20).shortTakes, 0, "and kept, not once")
    }

    func testACardThatStartsLateIsBoundedByCapacityAndConvergesWithoutACut() {
        let r = run(card: 512, block: 240, ppm: 0, seconds: 120, cardStartsAt: 0.3, recordFrom: 110)
        let cushionMs = Double(OutputClock.cushion(cardFrames: 512, blockFrames: 240)) / 48
        XCTAssertEqual(r.clock.cutFrames, 0, "only overflow may drop incoming samples")
        XCTAssertLessThanOrEqual(r.depthsMs.max()!, 100)
        XCTAssertEqual(r.depthsMs.reduce(0, +) / Double(r.depthsMs.count), cushionMs, accuracy: 3)
        XCTAssertEqual(r.shortTakes, 0)
        let alone = run(card: 512, block: 240, ppm: 0, seconds: 20, cardStartsAt: 0.3, kept: false, recordFrom: 1)
        XCTAssertGreaterThan(alone.depthsMs.min()!, 70, "without correction, the capacity backlog stays deep")
    }

    func testActualPullSizesTheCushionDespiteAnIncorrectAdvertisedBuffer() {
        let r = run(card: 1_024, block: 96, ppm: 0, seconds: 120, says: 64)
        XCTAssertEqual(r.clock.cutFrames, 0, "measurement does not cut a queue to its new target")
        XCTAssertEqual(r.clock.cushionFrames, 26 * 48)
        XCTAssertLessThan(r.lastShortAt, 12, "the first ten-second measurement supplies the actual target")
    }

    func testAMixThatComesLateDoesNotHaveItsCushionRaised() {
        // The app's timer stalls for 150 ms, twenty seconds in: the card runs dry, through no fault of the cushion.
        let r = run(card: 256, block: 96, ppm: 0, seconds: 40, recordFrom: 30, mixStalls: 20.0...20.15)
        XCTAssertGreaterThan(r.clock.ranDry, 0, "it ran dry while the mix was stalled")
        XCTAssertEqual(r.clock.cushionFrames, OutputClock.cushion(cardFrames: 256, blockFrames: 96),
                       "and the cushion is as it was: raising it would add delay for good, for a stall no cushion covers")
        XCTAssertLessThan(r.lastShortAt, 20.3, "once the mix is back the card finds what it wants again")
        let mean = r.depthsMs.reduce(0, +) / Double(r.depthsMs.count)
        XCTAssertEqual(mean, Double(OutputClock.cushion(cardFrames: 256, blockFrames: 96)) / 48, accuracy: 2.5,
                       "and the queue is back at its cushion")
        XCTAssertEqual(r.clock.ppm ?? .nan, 0, accuracy: 30,
                       "with the card's clock still read as it is: the window after the stall did not start inside it")
    }

    func testWhatTheCardPlaysHasNoClickInIt() {
        let r = run(card: 256, block: 96, ppm: 150, seconds: 60, recordFrom: 30)
        XCTAssertEqual(r.shortTakes, 0)
        XCTAssertGreaterThan(r.heard.count / 2, 29 * 48_000)
        var biggest: Float = 0
        for i in 1..<(r.heard.count / 2) { biggest = max(biggest, abs(r.heard[2 * i] - r.heard[2 * i - 2])) }
        XCTAssertLessThan(biggest, Float(0.5 * 2 * Double.pi * 1000 / 48_000 * 1.06),
                          "half a minute of tone through a card 150 ppm out, and not one jump")
    }

    func testAQueueEmptiedAndStartedAgainIsGivenItsCushionAgain() {
        let queue = Queue()
        var clock = OutputClock()
        clock.cardFrames = 128
        let block = [Float](repeating: 0.1, count: 192)
        clock.write(block, to: queue, now: 0)
        let cushion = 12 * 48 // unmeasured startup and a replacement queue both start at 12 ms
        XCTAssertEqual(clock.laidFrames, cushion, "the first block lays the cushion down in silence")
        XCTAssertEqual(queue.available, cushion + 94, "and the block goes in after it, less the two frames the resampler holds")
        _ = queue.take(128)
        clock.write(block, to: queue, now: 0.002)
        XCTAssertEqual(clock.laidFrames, cushion, "and only once")
        // The app stops the output and starts it again: a new queue.
        let fresh = Queue()
        clock.write(block, to: fresh, now: 0.004)
        XCTAssertEqual(clock.laidFrames, 2 * cushion, "a queue that has started again is given its cushion again")
    }
}
