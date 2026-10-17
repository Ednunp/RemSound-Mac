import Foundation
import XCTest

@testable import RemSoundJam

/// The DAW's pulls kept in time with the mix: a model of the Mac's history and a DAW on a clock of its own.
final class HostTimeTests: XCTestCase {
    /// The mix's history: a 1 kHz tone by frame number, written up to `clock` and silent after it.
    static func history(from: Int64, frames: Int, clock: Int64, peer: Int = 0) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let n = from + Int64(i)
            guard n >= 0, n < clock else { continue }
            let x = Float(0.5 * sin(2 * Double.pi * 1000 * Double(n) / 48_000 + Double(peer)))
            out[2 * i] = x
            out[2 * i + 1] = x
        }
        return out
    }

    struct Run {
        var lags: [Int64] = []
        var heard: [Float] = []
        var keeper = HostTimeKeeper()
        var naiveRestarts = 0
    }

    /// A DAW asking `frames` at a time, its clock `ppm` against the mix's, for `seconds`. `kept`: with the keeper, or the
    /// read position moved on by what was asked, as it was.
    func run(ppm: Double, seconds: Double, frames: Int = 128, stall: ClosedRange<Double>? = nil, recordFrom: Double = 0) -> Run {
        var r = Run()
        let roundPeriod = Double(frames) / (48_000 * (1 + ppm / 1_000_000))
        var t = 0.0, naiveCursor: Int64 = -1
        while t < seconds {
            t += roundPeriod
            if let stall, stall.contains(t) { continue }
            let clock = Int64(t * 48_000)   // the mix: 48,000 frames a second of this Mac's clock
            let round = r.keeper.startRound(frames: frames, clock: clock, now: t)
            let block = r.keeper.block(peer: "a", history: Self.history(from: round.from - 2, frames: round.count + 2, clock: clock))
            if t >= recordFrom {
                r.lags.append(clock - round.from)
                r.heard += block
            }
            // As it was: move on by what was asked, put back when 90 ms out.
            naiveCursor = naiveCursor < 0 ? clock - 480 : naiveCursor + Int64(frames)
            if naiveCursor < clock - 4_800 || naiveCursor > clock {
                naiveCursor = clock - 480
                r.naiveRestarts += 1
            }
        }
        return r
    }

    func testTheDawReadsASetDistanceBehindTheMixAllSessionLong() {
        for ppm in [100.0, -100.0, 30.0] {
            let r = run(ppm: ppm, seconds: 1_800, recordFrom: 60)   // half an hour
            XCTAssertEqual(r.keeper.restarts, 0, "never put back (\(ppm) ppm)")
            XCTAssertLessThan(r.lags.map { abs($0 - 480) }.max()!, 160, "within a few milliseconds of 10 ms behind, all the time (\(ppm) ppm)")
            XCTAssertEqual(r.keeper.ppm ?? .nan, -ppm, accuracy: 15, "the two clocks, measured: a DAW \(ppm) ppm fast is the mix that much slow")
            if abs(ppm) >= 100 { XCTAssertGreaterThan(r.naiveRestarts, 0, "as it was, \(ppm) ppm walked 90 ms off and jumped within the half hour") }
        }
    }

    func testTheToneThroughItHasNoJumpAndIsInTune() {
        let r = run(ppm: 120, seconds: 60, recordFrom: 30)
        var biggest: Float = 0
        for i in 1..<(r.heard.count / 2) { biggest = max(biggest, abs(r.heard[2 * i] - r.heard[2 * i - 2])) }
        XCTAssertLessThan(biggest, Float(0.5 * 2 * Double.pi * 1000 / 48_000 * 1.05), "half a minute through the DAW, and not one jump")
        // In tune by the DAW's own clock: 1 kHz of the mix's time is 1 kHz * (1 + 120 ppm) of the DAW's samples.
        var first = -1.0, last = -1.0, crossings = 0
        for i in 1..<(r.heard.count / 2) {
            let a = r.heard[2 * i - 2], b = r.heard[2 * i]
            if a < 0 && b >= 0 {
                let at = Double(i - 1) + Double(a / (a - b))
                if first < 0 { first = at }
                last = at
                crossings += 1
            }
        }
        let cycles = Double(crossings - 1) / (last - first)   // per DAW sample
        XCTAssertEqual(cycles * 48_000 * (1 + 120e-6), 1000, accuracy: 0.05, "the tone at 1 kHz as the DAW's card plays it")
    }

    func testEveryPeerGetsItsBlockMadeAlikeAndOnceARound() {
        var keeper = HostTimeKeeper()
        var t = 0.0
        var joinedLate: [Float] = [], early: [Float] = []
        for k in 0..<4000 {
            t += 128.0 / 48_000 * 1.0001
            let clock = Int64(t * 48_000)
            let round = keeper.startRound(frames: 128, clock: clock, now: t)
            let history = Self.history(from: round.from - 2, frames: round.count + 2, clock: clock)
            let a = keeper.block(peer: "a", history: history)
            XCTAssertEqual(keeper.block(peer: "a", history: Self.history(from: round.from - 2, frames: round.count + 2, clock: clock, peer: 9)), a,
                           "a peer asked for twice in a round gets the same block")
            if k >= 2000 {
                // A second peer, same sound, joining part-way: its blocks are the first peer's, sample for sample.
                let b = keeper.block(peer: "b", history: history)
                early += a
                joinedLate += b
            }
        }
        XCTAssertEqual(joinedLate.count, early.count)
        XCTAssertEqual(zip(joinedLate, early).map { abs($0 - $1) }.max() ?? 1, 0, accuracy: 1e-6, "a peer that joins part-way is in step with the rest")
    }

    func testADawThatStallsIsPutBackOnceAndCarriesOn() {
        let r = run(ppm: 50, seconds: 40, stall: 20.0...20.3, recordFrom: 22)
        XCTAssertEqual(r.keeper.restarts, 1, "300 ms of nothing from the DAW: put back at the lag, once")
        XCTAssertLessThan(r.lags.map { abs($0 - 480) }.max()!, 160, "and after it, 10 ms behind again")
    }

    func testTheFirstRoundStartsTenMillisecondsBehind() {
        var keeper = HostTimeKeeper()
        let round = keeper.startRound(frames: 256, clock: 96_000, now: 2)
        XCTAssertEqual(round.from, 96_000 - 480)
        XCTAssertEqual(round.count, 258, "at a ratio of 1 a round reads what it gives, and the first two more: the frames the resampler holds")
        XCTAssertEqual(keeper.restarts, 0)
    }
}
