import AudioSupport
import Foundation
import RemSoundJam
import XCTest
@testable import RemSoundCore

final class OutputPullMetricsTests: XCTestCase {
    func testEachPhysicalOutputRingHasOnlyOneHundredMillisecondsCapacity() {
        let fanout = PlaybackFanout(primary: StereoRing(capacity: 4_800))
        let first = fanout.addOutput(), second = fanout.addOutput()
        fanout.write([Float](repeating: 0.25, count: 4_800 * 2))
        fanout.write([Float](repeating: 0.25, count: 1_200 * 2))
        XCTAssertEqual(first.available, 4_800)
        XCTAssertEqual(second.available, 4_800)
        XCTAssertEqual(first.droppedFrames, 1_200)
        XCTAssertEqual(second.droppedFrames, 1_200)
    }

    func testRingCountsRequestedShortReadsButNeitherZeroReadsNorDiscards() throws {
        let ring = StereoRing(capacity: 8)
        XCTAssertEqual(try XCTUnwrap(ring.pullTotals).frames, 0)
        ring.write([Float](repeating: 0.25, count: 8))
        XCTAssertEqual(ring.discard(2), 2)
        XCTAssertEqual(try XCTUnwrap(ring.pullTotals).count, 0)
        XCTAssertEqual(ring.read(5), [0.25, 0.25, 0.25, 0.25, 0, 0, 0, 0, 0, 0])
        _ = ring.read(0)
        _ = ring.read(3)
        let measured = try XCTUnwrap(ring.pullTotals)
        XCTAssertEqual(measured.frames, 8)
        XCTAssertEqual(measured.count, 2)
        XCTAssertEqual(ring.available, 0)
    }

    func testConcurrentNativeSnapshotsNeverPublishHalfOfAPull() throws {
        let ring = StereoRing(capacity: 8)
        let finished = DispatchGroup()
        finished.enter()
        DispatchQueue.global().async {
            for _ in 0..<50_000 { _ = ring.read(31) }
            finished.leave()
        }
        for _ in 0..<20_000 {
            if let measured = ring.pullTotals {
                XCTAssertEqual(measured.frames, measured.count * 31)
            }
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        let measured = try XCTUnwrap(ring.pullTotals)
        XCTAssertEqual(measured.frames, 50_000 * 31)
        XCTAssertEqual(measured.count, 50_000)
    }

    func testProductionRingSuppliesTheClockWithActualPulls() {
        let ring = StereoRing(capacity: 4_096)
        var clock = OutputClock()
        clock.cardFrames = 32
        let block = [Float](repeating: 0.25, count: 192)
        clock.write(block, to: ring, now: 0)
        for i in 1...1_000 {
            _ = ring.read(1_024)
            clock.write(block, to: ring, now: Double(i) / 100)
        }
        XCTAssertEqual(clock.cushionFrames, 26 * 48)
        XCTAssertGreaterThan(clock.ranDry, 0)
    }
}
