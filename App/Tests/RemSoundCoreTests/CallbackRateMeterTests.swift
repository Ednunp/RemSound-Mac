import AudioSupport
import XCTest
@testable import RemSoundCore

final class CallbackRateMeterTests: XCTestCase {
    func testDeliveryRateUsesElapsedTimeAndKeepsSourcesAndFormatRateSeparate() {
        var meter = CallbackRateMeter()
        let input = UUID(), tap = UUID()
        func counters(_ inputFrames: UInt64, _ inputCalls: UInt64, _ tapFrames: UInt64, _ tapCalls: UInt64) -> [CallbackRateMeter.Counter] {
            [.init(id: input, name: "input", frames: inputFrames, callbacks: inputCalls, formatRate: 96_000),
             .init(id: tap, name: "tap", frames: tapFrames, callbacks: tapCalls, formatRate: 48_000)]
        }
        XCTAssertTrue(meter.take(counters(0, 0, 0, 0), now: 10).isEmpty)
        let first = meter.take(counters(192_000, 200, 144_000, 300), now: 12)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first[0].framesPerSecond, 96_000)
        XCTAssertEqual(first[0].callbacksPerSecond, 100)
        XCTAssertEqual(first[1].framesPerSecond, 72_000)
        XCTAssertEqual(first[1].callbacksPerSecond, 150)
        XCTAssertTrue(first[1].logDescription.contains("format rate 48000"))
        XCTAssertTrue(first[1].logDescription.contains("not a physical ADC clock measurement"))
        let next = meter.take(counters(240_000, 250, 216_000, 450), now: 13)
        XCTAssertEqual(next[0].framesPerSecond, 48_000)
        XCTAssertEqual(next[0].wholeRunFramesPerSecond, 80_000)
        XCTAssertEqual(next[0].wholeRunCallbacksPerSecond, 250.0 / 3, accuracy: 0.001)
    }

    func testRepeatedTimeCounterResetRemovalAndFormatChangeStartFreshIntervals() {
        var meter = CallbackRateMeter()
        let id = UUID()
        func counter(_ frames: UInt64, _ calls: UInt64, rate: Double = 48_000) -> [CallbackRateMeter.Counter] {
            [.init(id: id, name: "input", frames: frames, callbacks: calls, formatRate: rate)]
        }
        _ = meter.take(counter(0, 0), now: 5)
        XCTAssertTrue(meter.take(counter(48_000, 100), now: 5).isEmpty)
        XCTAssertEqual(meter.take(counter(96_000, 200), now: 7).first?.framesPerSecond, 48_000)
        XCTAssertTrue(meter.take(counter(97_000, 1), now: 8).isEmpty)
        XCTAssertEqual(meter.take(counter(145_000, 101), now: 9).first?.callbacksPerSecond, 100)
        XCTAssertTrue(meter.take(counter(145_000, 101, rate: 96_000), now: 10).isEmpty)
        XCTAssertEqual(meter.take(counter(241_000, 201, rate: 96_000), now: 11).first?.wholeRunFramesPerSecond, 96_000)
        _ = meter.take([], now: 12)
        XCTAssertTrue(meter.take(counter(300_000, 300), now: 13).isEmpty)
        XCTAssertTrue(meter.take(counter(300_000, 300), now: .nan).isEmpty)
        XCTAssertTrue(meter.take(counter(300_000, 300), now: 12).isEmpty)
    }

    func testActualRingFiguresCountDeliveredFramesEvenWhenTheRingIsFull() throws {
        let ring = StereoRing(capacity: 4)
        let id = UUID()
        var meter = CallbackRateMeter()
        let initial = try XCTUnwrap(CallbackRateMeter.counter(ring: ring, id: id, name: "input", formatRate: 48_000))
        _ = meter.take([initial], now: 1)
        ring.write([Float](repeating: 0.25, count: 20))
        rs_ring_note_callback_elapsed(ring.raw, 1_000, 10, 48_000)
        let full = try XCTUnwrap(CallbackRateMeter.counter(ring: ring, id: id, name: "input", formatRate: 48_000))
        XCTAssertLessThan(ring.writtenFrames, 10)
        XCTAssertEqual(full.frames, 10)
        XCTAssertEqual(full.callbacks, 1)
        let rate = try XCTUnwrap(meter.take([full], now: 1.5).first)
        XCTAssertEqual(rate.framesPerSecond, 20)
        XCTAssertEqual(rate.callbacksPerSecond, 2)
    }
}
