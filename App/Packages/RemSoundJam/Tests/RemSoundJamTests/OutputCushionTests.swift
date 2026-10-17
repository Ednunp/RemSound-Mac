import XCTest
@testable import RemSoundJam

final class OutputCushionTests: XCTestCase {
    private let block = [Float](repeating: 0.1, count: 192)

    func testAQueueBelowCapacityIsNeverCutTowardItsTarget() {
        let queue = OutputClockTests.Queue()
        var clock = OutputClock()
        clock.write(block, to: queue, now: 0)
        queue.write([Float](repeating: 0.2, count: 3_000 * 2))
        clock.write(block, to: queue, now: 0.002)
        XCTAssertEqual(clock.cutFrames, 0)
        XCTAssertGreaterThan(queue.available, 3_000)
    }

    func testUnmeasuredCardStartsAtTwelveMilliseconds() {
        for card in [32, 512, 2_048] {
            let queue = OutputClockTests.Queue()
            var clock = OutputClock()
            clock.cardFrames = card
            clock.write(block, to: queue, now: 0)
            XCTAssertEqual(clock.cushionFrames, 576)
        }
    }

    func testEmptyReadsNeverRaiseTheTarget() {
        let queue = OutputClockTests.Queue()
        var clock = OutputClock()
        clock.write(block, to: queue, now: 0)
        for i in 1...100 {
            _ = queue.take(4_096)
            clock.write(block, to: queue, now: Double(i) * 0.002)
            XCTAssertEqual(clock.cushionFrames, 576)
        }
        XCTAssertEqual(clock.ranDry, 100)
    }

    func testAdvertisedBufferChangesDoNotInventMeasuredPulls() {
        let queue = OutputClockTests.Queue()
        var clock = OutputClock()
        clock.write(block, to: queue, now: 0)
        clock.cardFrames = 2_048
        clock.write(block, to: queue, now: 11)
        XCTAssertEqual(clock.cushionFrames, 576)
    }

    func testProducerStallDoesNotChangeTheTarget() {
        let queue = OutputClockTests.Queue()
        var clock = OutputClock()
        clock.write(block, to: queue, now: 0)
        _ = queue.take(512)
        _ = queue.take(512) // Same actual pull, after the producer stops; no invented larger pull.
        clock.write(block, to: queue, now: 30)
        XCTAssertEqual(clock.cushionFrames, 576)
        XCTAssertEqual(clock.ranDry, 1)
    }

    func testMeasuredTargetRuleIncludingBankersRoundingAndHysteresis() {
        for (current, average, expected) in [(12, 0.0, 12), (12, 480.0, 12),
            (12, 512.0, 12), (12, 640.0, 16), (16, 480.0, 12),
            (12, 32.0, 8), (12, 10_000.0, 50), (12, 580.0, 14), (12, 500.0, 12)] {
            XCTAssertEqual(OutputCushion.next(current: current, averageFrames: average), expected)
        }
        XCTAssertEqual(OutputCushion.next(current: 12, averageFrames: .nan), 12)
        XCTAssertEqual(OutputCushion.next(current: 12, averageFrames: .infinity), 12)
    }

    func testTenSecondWindowsFollowActualPullUpAndDown() {
        var target = OutputCushion()
        _ = target.update((0, 0), now: 0)
        _ = target.update((102_400, 100), now: 9.999)
        XCTAssertEqual(target.frames, 576)
        _ = target.update((103_424, 101), now: 10)
        XCTAssertEqual(target.frames, 26 * 48)
        _ = target.update((109_824, 201), now: 20)
        XCTAssertEqual(target.frames, 8 * 48)
        _ = target.update((109_824, 201), now: 30)
        XCTAssertEqual(target.frames, 8 * 48, "no pulls is not a new card measurement")
    }

    func testUnavailableSnapshotDefersTheWindowAndCounterRestartResetsIt() {
        var target = OutputCushion()
        _ = target.update((0, 0), now: 0)
        _ = target.update((102_400, 100), now: 9)
        _ = target.update(nil, now: 10)
        XCTAssertEqual(target.frames, 576)
        _ = target.update((204_800, 200), now: 11)
        XCTAssertEqual(target.frames, 26 * 48)
        XCTAssertTrue(target.update((0, 0), now: 12))
        XCTAssertEqual(target.frames, 576)
    }

    func testTenThousandJitterWindowsAndAnOccasionalDoublePullCannotCreep() {
        var target = OutputCushion()
        var frames: UInt64 = 0, count: UInt64 = 0
        _ = target.update((frames, count), now: 0)
        for window in 1...10_000 {
            // 1000 normal 480-frame pulls, one coalesced double-pull and bounded averaging wobble.
            frames += UInt64(480_480 + (window % 3 - 1) * 1_000)
            count += 1_000
            _ = target.update((frames, count), now: Double(window * 10))
            XCTAssertEqual(target.frames, 576)
        }
    }

    func testClockUsesActualRequestedFramesIncludingShortReads() {
        let queue = OutputClockTests.Queue()
        var clock = OutputClock()
        clock.cardFrames = 32
        clock.write(block, to: queue, now: 0)
        for i in 1...1_000 {
            _ = queue.take(1_024) // almost all is silence, but the requested pull is still 1024.
            clock.write(block, to: queue, now: Double(i) / 100)
        }
        XCTAssertEqual(clock.cushionFrames, 26 * 48)
        XCTAssertGreaterThan(clock.ranDry, 0)
    }
}
