import Foundation
import XCTest

@testable import RemSoundJam

/// The Mac's receive buffer, moved out of StreamDecoder (2026-09-30): its rules one by one, and the order of packets, and
/// the auto-tune. (The Mac simulator runs it in whole sessions.)
final class PlayoutQueueTests: XCTestCase {
    func frames(_ n: Int, _ v: Float = 0.25) -> [Float] { [Float](repeating: v, count: n * 2) }

    func testInitialTargetIsRequiredButATransientRunDryStaysArmed() {
        let q = PlayoutQueue(jitterMs: 10, packetFrames: 233, now: 0)
        q.append(frames(233))
        XCTAssertTrue(q.read(96, now: 0.001, keepsInTime: true).allSatisfy { $0 == 0 }, "233 frames is under 10 ms: silence")
        XCTAssertFalse(q.playing)
        q.append(frames(466))
        XCTAssertEqual(q.read(96, now: 0.002, keepsInTime: true).first, 0.25, "699 frames is over 10 ms: it plays")
        XCTAssertTrue(q.playing)
        for _ in 0..<6 { _ = q.read(96, now: 0.003, keepsInTime: true) }
        XCTAssertEqual(q.underrunsTotal, 0, "672 of 699 taken")
        _ = q.read(96, now: 0.004, keepsInTime: true)
        XCTAssertEqual(q.underrunsTotal, 1, "96 wanted of 27 left: short")
        XCTAssertTrue(q.playing, "Windows keeps the stream armed after a transient run dry")
        XCTAssertEqual(q.takeUnderruns(), 1)
        XCTAssertEqual(q.takeUnderruns(), 0, "counted once")
    }

    func testTheClickTrimCutsASurgeBackToJustOverTheTarget() {
        let q = PlayoutQueue(jitterMs: 20, packetFrames: 233, now: 0)
        for _ in 0..<5 { q.append(frames(233)) }
        _ = q.read(240, now: 0.01, keepsInTime: true)
        // A burst after a stall: actual decoded packets, about 58 ms more.
        for _ in 0..<12 { q.append(frames(233)) }
        _ = q.read(240, now: 0.02, keepsInTime: true)
        XCTAssertEqual(q.trims, 1)
        // Trimmed to target + two 5 ms writes + 5 ms (35 ms = 1680 frames), then a block taken.
        XCTAssertEqual(q.queuedFrames, PlayoutQueue.trimDestinationFrames(targetMs: 20, packetFrames: 233) - 240)
        XCTAssertEqual(PlayoutQueue.excessLimitFrames(targetMs: 20, packetFrames: 233), (20 + 32) * 48, "four write durations plus 4 ms, then the default 8 ms margin")
        XCTAssertEqual(PlayoutQueue.excessLimitFrames(targetMs: 20, packetFrames: 16), (20 + 23) * 48, "at least 15 ms, then the default 8 ms margin")
    }

    func testSafetyCapRetainsNewestAudioAndBoundsCodecFillWithExactDropCounts() {
        let q = PlayoutQueue(jitterMs: 20, packetFrames: 240, now: 0)
        q.append(frames(19_000))
        q.appendConcealment(frames(2_000))
        XCTAssertEqual(q.queuedFrames, 19_200, "codec fill shares the fixed budget")
        XCTAssertEqual(q.overflowDroppedFrames, 1_800)
        q.append(frames(240))
        XCTAssertEqual(q.overflows, 2)
        XCTAssertEqual(q.overflowDroppedFrames, 2_040)
        XCTAssertEqual(q.queuedFrames, 19_200, "oldest frames are discarded and the stream re-primes")
        XCTAssertFalse(q.playing)
    }

    func testTheSendersClockIsMeasuredFromWhatItMadeAndPlayedOutByIt() {
        // A sender 1000 ppm fast: 480.48 frames each 10 ms, taken 480 at a time.
        let q = PlayoutQueue(jitterMs: 20, packetFrames: 480, now: 0)
        var made = 0.0, sent = 0
        var t = 0.0
        while t < 25 {
            made += 480.48
            let whole = Int(made) - sent
            q.append(frames(whole, 0.1))
            q.produced(whole, now: t)
            sent += whole
            _ = q.read(480, now: t + 0.005, keepsInTime: true)
            t += 0.01
        }
        XCTAssertTrue(q.clockTracking)
        XCTAssertEqual(q.clockPpm ?? 0, 1000, accuracy: 60)
        XCTAssertEqual(Double(q.queuedFrames) / 48, 20, accuracy: 12, "held near its target, not grown by 25 ms")
    }

    func testMovedByHandOrByTheAutoTuneOrWithoutKeepingInTime() {
        func filled(_ ms: Int) -> PlayoutQueue {
            let q = PlayoutQueue(jitterMs: ms, packetFrames: 240, now: 0)
            q.append(frames(ms * 48 + 480))
            _ = q.read(240, now: 0.01, keepsInTime: true)
            return q
        }
        let hand = filled(100)
        hand.setJitterMs(20, byHand: true, keepsInTime: true)
        XCTAssertLessThanOrEqual(abs(hand.queuedFrames - 20 * 48), 240, "lowered by hand: there at once")
        XCTAssertGreaterThan(hand.skippedFrames, 3000)
        XCTAssertTrue(hand.approaching)
        let auto = filled(100)
        let before = auto.queuedFrames
        auto.setJitterMs(20, byHand: false, keepsInTime: true)
        XCTAssertEqual(auto.queuedFrames, before, "lowered by the auto-tune: left for the descent")
        XCTAssertTrue(auto.descending)
        let plain = filled(100)
        plain.setJitterMs(20, byHand: false, keepsInTime: false)
        XCTAssertLessThanOrEqual(abs(plain.queuedFrames - 20 * 48), 240, "without keeping in time there is no pull: skipped to at once")
        plain.setJitterMs(60, byHand: true, keepsInTime: false)
        XCTAssertFalse(plain.playing, "and raised, it starts again at its depth")
        let kept = filled(20)
        kept.setJitterMs(60, byHand: true, keepsInTime: true)
        XCTAssertTrue(kept.playing, "raised while keeping in time: it plays on and the pull fills it")
    }

    func testTheOrderOfPackets() {
        var order = StreamOrder()
        XCTAssertEqual(order.admit(500), .next(missing: 0), "the first is next")
        order.took(500)
        XCTAssertEqual(order.admit(501), .next(missing: 0))
        XCTAssertEqual(order.admit(504), .next(missing: 3))
        XCTAssertEqual(order.admit(500), .late, "the same again: doubled")
        XCTAssertEqual(order.admit(499), .late, "behind: overtaken")
        XCTAssertEqual(order.admit(3), .restart, "back near the start, far behind: the sender started again")
        order.took(200)
        XCTAssertEqual(order.admit(100), .late, "back to 100 is not near the start")
        order.took(40)
        XCTAssertEqual(order.admit(3), .late, "only 37 back: not a restart")
        order.took(UInt32.max)
        XCTAssertEqual(order.admit(1), .next(missing: 1), "the counter wraps")
        XCTAssertEqual(order.packets(upTo: 1), 2)
    }

}
