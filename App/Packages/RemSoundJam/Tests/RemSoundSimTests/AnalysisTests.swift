import Foundation
import XCTest

@testable import RemSoundSim

/// The simulator's ears, checked first: a listening that misses faults would pass everything (Windows' "the analyser
/// finds planted faults").
final class AnalysisTests: XCTestCase {
    /// `seconds` of the test signal as heard `delayMs` late: the tone on the left, a click every half second on the right.
    func heard(seconds: Double, delayMs: Double, cents: Double = 0, change: (inout [Float]) -> Void = { _ in }) -> ([Float], [(frame: Int, time: Double)]) {
        let rate = 48_000.0
        let frames = Int(seconds * rate)
        let lag = Int(delayMs / 1000 * rate)
        let hz = SimAnalysis.toneHz * pow(2, cents / 1200)
        var s = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            let n = f - lag
            guard n >= 0 else { continue }
            s[2 * f] = SimAnalysis.toneLevel * Float(sin(2 * Double.pi * hz * Double(n) / rate))
            s[2 * f + 1] = n % 24_000 == 0 ? SimAnalysis.clickLevel : 0
        }
        change(&s)
        let blocks = stride(from: 0, to: frames, by: 480).map { (frame: $0, time: Double($0) / rate) }
        return (s, blocks)
    }

    func testACleanSignalIsCleanAndItsDelayIsMeasuredToTheSample() {
        let (s, t) = heard(seconds: 4, delayMs: 37.5)
        let f = SimAnalysis.analyse(s, t, sendRate: 48_000)
        XCTAssertTrue(f.clean, f.describe)
        XCTAssertEqual(f.delayMedianMs, 37.5, accuracy: 0.03)
        XCTAssertEqual(f.clicksHeard, 8)
        XCTAssertGreaterThan(f.worstSnrDb, 60)
        XCTAssertLessThan(f.worstPitchCents, 0.5)
    }

    func testAMissingMillisecondIsHeard() {
        let (s, t) = heard(seconds: 3, delayMs: 20) { s in
            for f in 72_000..<72_048 { s[2 * f] = 0 }
        }
        let f = SimAnalysis.analyse(s, t, sendRate: 48_000)
        XCTAssertEqual(f.glitches, 1, f.describe)
        XCTAssertEqual(f.firstGlitchAt ?? 0, 1.5, accuracy: 0.002)
        XCTAssertFalse(f.clean)
    }

    func testAQuarterMillisecondGapAtAZeroCrossingIsHeardToo() {
        let (s, t) = heard(seconds: 3, delayMs: 0) { s in
            // A gap that starts and ends near zero: no step, and too short to empty a whole millisecond.
            for f in 72_000..<72_012 { s[2 * f] = 0 }
        }
        XCTAssertEqual(SimAnalysis.analyse(s, t, sendRate: 48_000).glitches, 1)
    }

    func testAJumpInTheToneIsAClickAndANoiseBurstIsNotTakenForADelayClick() {
        let (s, t) = heard(seconds: 3, delayMs: 10) { s in s[2 * 60_000] += 0.4 }
        let f = SimAnalysis.analyse(s, t, sendRate: 48_000)
        XCTAssertEqual(f.stepClicks, 2, "up and back")
        XCTAssertEqual(f.glitches, 1)
        // Noise on both channels (an underrun's cover) is not a delay click: it swings both ways.
        var noisy = s
        var x: UInt64 = 7
        for f in 100_000..<100_240 {
            x = x &* 6364136223846793005 &+ 1442695040888963407
            let v = Float(Int64(bitPattern: x >> 11) % 2000 - 1000) / 1000 * 0.7
            noisy[2 * f] = v
            noisy[2 * f + 1] = v
        }
        let clicks = SimAnalysis.clicks(noisy, t, sendRate: 48_000)
        XCTAssertTrue(clicks.allSatisfy { abs($0.delayMs - 10) < 0.1 }, "every click found is a real one: \(clicks.map(\.delayMs))")
    }

    func testPitchIsMeasuredInCents() {
        let (s, t) = heard(seconds: 3, delayMs: 5, cents: 12)
        let f = SimAnalysis.analyse(s, t, sendRate: 48_000)
        XCTAssertEqual(f.pitchMedianCents, 12, accuracy: 0.5)
        let (s2, t2) = heard(seconds: 3, delayMs: 5, cents: 12)
        XCTAssertLessThan(SimAnalysis.analyse(s2, t2, sendRate: 48_000, expectedToneRatio: pow(2, 12.0 / 1200)).pitchMedianCents, 0.5,
                          "measured against the pitch expected")
    }

    func testNothingHeardIsNotClean() {
        let silence = [Float](repeating: 0, count: 96_000)
        let f = SimAnalysis.analyse(silence, [(0, 0)], sendRate: 48_000)
        XCTAssertEqual(f.clicksHeard, 0)
        XCTAssertFalse(f.clean)
        XCTAssertEqual(f.describe, "NOTHING HEARD")
    }

    func testTheMusicListeningFindsADipInALoudPassageAndNothingInAClean() {
        let rate = 48_000.0
        func music(_ change: (inout [Float]) -> Void = { _ in }) -> ([Float], [(frame: Int, time: Double)]) {
            let frames = Int(9 * rate)
            var s = [Float](repeating: 0, count: frames * 2)
            for f in 0..<frames {
                s[2 * f] = SimMusic.sample(Double(f) / rate)
                s[2 * f + 1] = f % 24_000 == 0 ? SimAnalysis.clickLevel : 0
            }
            change(&s)
            return (s, stride(from: 0, to: frames, by: 480).map { (frame: $0, time: Double($0) / rate) })
        }
        let (clean, t) = music()
        XCTAssertTrue(SimMusic.analyse(clean, t, sendRate: rate).clean, SimMusic.analyse(clean, t, sendRate: rate).describe)
        // 5 ms gone from the held 880 Hz note (1.6 to 2.5 s into the second bar).
        let (gap, t2) = music { s in for f in Int(6.0 * rate)..<Int(6.005 * rate) { s[2 * f] = 0 } }
        let found = SimMusic.analyse(gap, t2, sendRate: rate)
        XCTAssertEqual(found.faults.first?.kind, .dip, found.describe)
        XCTAssertEqual(found.faults.first?.passage, SimMusic.loudPassage)
        XCTAssertEqual(found.plain, 1)
        // The same gap in the rest (3.3 to 4.1 s into the bar) is nothing to hear.
        let (rest, t3) = music { s in for f in Int(7.5 * rate)..<Int(7.505 * rate) { s[2 * f] = 0 } }
        XCTAssertTrue(SimMusic.analyse(rest, t3, sendRate: rate).clean)
    }
}
