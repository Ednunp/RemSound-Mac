import XCTest
@testable import RemSoundCore

final class AudioDiagnosticsTests: XCTestCase {
    func testRecentMedianAndTailPercentilesShareTheBoundedWindow() {
        var values = AudioIntervalDistribution(capacity: 100)
        values.note(1_000)
        for value in 1...100 { values.note(Double(value)) }
        let report = values.take()
        XCTAssertEqual(report?.recentP50, 50)
        XCTAssertEqual(report?.recentP95, 95)
        XCTAssertEqual(report?.recentP99, 99)
        XCTAssertEqual(report?.maximum, 1_000)
        XCTAssertEqual(report?.percentileSamples, 100)
    }

    func testSentStatisticsStaySeparateAndBoundedAcrossStreamRotation() {
        var streams = SentAudioDiagnostics()
        streams.note(stream: 1, frames: 480, copies: 3, failures: 0, now: 0)
        streams.note(stream: 2, frames: 64, copies: 1, failures: 1, now: 0)
        streams.note(stream: 1, frames: 0, copies: 3, failures: 0, now: 0.001)
        let report = streams.take()
        XCTAssertEqual(report.map(\.stream), [1, 2])
        XCTAssertEqual(report.map { $0.statistics.frames }, [480, 64])
        XCTAssertEqual(report.map { $0.statistics.packets }, [2, 1])
        XCTAssertEqual(report.map { $0.statistics.copies }, [6, 1])
        XCTAssertTrue(streams.take().isEmpty)
        for stream in 3...300 {
            streams.note(stream: UInt16(stream), frames: 64, copies: 1, failures: 0, now: 1)
        }
        let rotated = streams.take()
        XCTAssertEqual(rotated.count, 128)
        XCTAssertEqual(rotated.last?.stream, 300)
    }

    func testDistributionRetainsFullIntervalExtremesAndBoundedRecentPercentile() {
        var values = AudioIntervalDistribution(capacity: 4)
        for value in [100.0, 1, 2, 3, 4, 5] { values.note(value) }
        let first = values.take()
        XCTAssertEqual(first?.count, 6)
        XCTAssertEqual(first?.minimum, 1)
        XCTAssertEqual(first?.maximum, 100, "Eviction must not hide a severe gap")
        XCTAssertEqual(first?.mean, 115.0 / 6)
        XCTAssertEqual(first?.recentP95, 5)
        XCTAssertEqual(first?.percentileSamples, 4)
        XCTAssertNil(values.take(), "Intervals reset after reporting")
    }

    func testTwentyMillisecondQueueDelayChangesQueueButNotPacketArrivalGap() {
        var ordinary = StreamIntervalDiagnostics(), delayed = StreamIntervalDiagnostics()
        for index in 0..<4 {
            let arrival = Double(index) * 0.01
            ordinary.notePacket(now: arrival)
            delayed.notePacket(now: arrival)
            ordinary.noteQueue(milliseconds: Double(index) + 5)
            delayed.noteQueue(milliseconds: Double(index) + 25)
        }
        let baseline = ordinary.take(), shifted = delayed.take()
        XCTAssertEqual(baseline.packets, 4)
        XCTAssertEqual(shifted.queue!.mean - baseline.queue!.mean, 20, accuracy: 0.0001)
        XCTAssertEqual(shifted.queue!.minimum - baseline.queue!.minimum, 20)
        XCTAssertEqual(shifted.queue!.maximum - baseline.queue!.maximum, 20)
        XCTAssertEqual(shifted.gaps!.maximum, baseline.gaps!.maximum, accuracy: 0.0001)
        XCTAssertEqual(ordinary.take().packets, 0)
        ordinary.notePacket(now: 0.05)
        XCTAssertEqual(ordinary.take().gaps?.maximum ?? 0, 20, accuracy: 0.0001,
                       "The first gap after reporting uses the previous packet")
    }

    func testPacketGapRecordsAnInjectedNetworkPauseAndSendCountsDoNotMultiplyFrames() {
        var stats = StreamIntervalDiagnostics()
        stats.notePacket(now: 0)
        stats.notePacket(now: 0.01)
        stats.notePacket(now: 0.04)
        stats.noteSend(frames: 480, copies: 2, failures: 1)
        let report = stats.take()
        XCTAssertEqual(report.gaps!.maximum, 30, accuracy: 0.0001)
        XCTAssertEqual(report.frames, 480)
        XCTAssertEqual(report.copies, 2)
        XCTAssertEqual(report.failures, 1)
    }
}
