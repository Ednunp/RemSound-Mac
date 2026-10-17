import XCTest
@testable import RemSoundCore

final class CaptureRateMeterTests: XCTestCase {
    func testEachSourceUsesActualElapsedTimeAndDetectsExcessFrames() {
        let first = UUID(), second = UUID()
        var meter = CaptureRateMeter()
        XCTAssertTrue(meter.take([
            .init(id: first, name: "First", frames: 0),
            .init(id: second, name: "Second", frames: 0)
        ], now: 10).isEmpty)
        let rates = meter.take([
            .init(id: first, name: "First", frames: 96_000),
            .init(id: second, name: "Second", frames: 144_000)
        ], now: 12)
        XCTAssertEqual(rates.map(\.framesPerSecond), [48_000, 72_000])
        XCTAssertEqual(rates.map(\.frames), [96_000, 144_000])
        XCTAssertEqual(rates.map(\.seconds), [2, 2])
        XCTAssertEqual(rates.map(\.wholeRunFramesPerSecond), [48_000, 72_000])
        let later = meter.take([
            .init(id: first, name: "First", frames: 144_000),
            .init(id: second, name: "Second", frames: 168_000)
        ], now: 13)
        XCTAssertEqual(later.map(\.framesPerSecond), [48_000, 24_000])
        XCTAssertEqual(later.map(\.wholeRunFramesPerSecond), [48_000, 56_000])
    }

    func testRestartRemovalAndCounterResetDoNotCreateRateSpikes() {
        let original = UUID(), restarted = UUID()
        var meter = CaptureRateMeter()
        _ = meter.take([.init(id: original, name: "Input", frames: 100_000)], now: 1)
        XCTAssertTrue(meter.take([.init(id: restarted, name: "Input", frames: 0)], now: 2).isEmpty)
        XCTAssertEqual(meter.take([.init(id: restarted, name: "Input", frames: 48_000)], now: 3).first?.framesPerSecond, 48_000)
        XCTAssertTrue(meter.take([.init(id: restarted, name: "Input", frames: 0)], now: 4).isEmpty)
        XCTAssertEqual(meter.take([.init(id: restarted, name: "Input", frames: 48_000)], now: 5).first?.framesPerSecond, 48_000)
        XCTAssertTrue(meter.take([], now: 6).isEmpty)
        XCTAssertTrue(meter.take([.init(id: restarted, name: "Input", frames: 96_000)], now: 7).isEmpty)
    }

    func testRepeatedTimestampDoesNotDiscardUnmeasuredFrames() {
        let id = UUID()
        var meter = CaptureRateMeter()
        _ = meter.take([.init(id: id, name: "Input", frames: 0)], now: 1)
        XCTAssertTrue(meter.take([.init(id: id, name: "Input", frames: 100)], now: 1).isEmpty)
        XCTAssertEqual(meter.take([.init(id: id, name: "Input", frames: 48_000)], now: 2).first?.framesPerSecond, 48_000)
    }

    func testCaptureDriftIsMeasuredOverLongWindowWithoutApplyingCorrection() {
        let id = UUID()
        var meter = CaptureSourceDriftDiagnostics()
        for tick in 0...12_000 {
            let captured = Int(Double(tick) * 48.024)
            meter.observe([.init(id: id, name: "Input", frames: captured, queuedFrames: 480)],
                          consumedFrames: tick == 0 ? 0 : 48, now: Double(tick) / 1_000)
        }
        let source = meter.snapshots.first!
        XCTAssertEqual(source.queuedFrames, 480)
        XCTAssertEqual(source.ppm ?? 0, 500, accuracy: 50)
        meter.observe([], consumedFrames: 0, now: 13)
        XCTAssertTrue(meter.snapshots.isEmpty)
    }
}
