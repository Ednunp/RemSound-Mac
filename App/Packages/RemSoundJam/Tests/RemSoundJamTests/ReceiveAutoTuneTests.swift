import XCTest
@testable import RemSoundJam

/// The auto-tune loop the app and the simulator share: Windows' evidence, a reading a second, and its decisions.
final class ReceiveAutoTuneTests: XCTestCase {
    /// A second of packets every 5 ms with one late by `lateMs`, mixes every 5 ms, `bufferMs` left in the buffer.
    private func second(_ t: inout ReceiveAutoTune, at start: Double, lateMs: Double = 0, bufferMs: Double = 20) {
        for i in 0..<200 {
            let at = start + Double(i) * 0.005 + (i == 100 ? lateMs / 1000 : 0)
            t.noteArrival(stream: "s", now: at)
            t.noteMix(now: start + Double(i) * 0.005)
            t.noteBuffer(ms: bufferMs)
        }
        t.endSecond()
    }

    func testTheFirstTickOnlyReadsTheCounter() {
        var t = ReceiveAutoTune()
        second(&t, at: 0)
        let first = t.tick(currentMs: 20, underruns: 40, hasAudio: true, frameMs: 5)
        XCTAssertNil(first.change)
        XCTAssertEqual(first.log, "continuous auto-tune: baseline taken (40 underruns already on the counter before it started tuning - ignored, not acted on)")
    }

    func testRunningShortRaisesToTheMeasuredNeedAtOnce() {
        var t = ReceiveAutoTune()
        _ = t.tick(currentMs: 5, underruns: 0, hasAudio: true, frameMs: 5)
        for s in 0..<5 { second(&t, at: Double(s), lateMs: 30) }
        let raise = t.tick(currentMs: 5, underruns: 12, hasAudio: true, frameMs: 5).change
        XCTAssertEqual(raise?.targetMs, 35 + 5 + 5, "gap 35 + mix 5 + safety 5")
        XCTAssertTrue(raise?.log.hasPrefix("continuous auto-tune: RAISING 5ms -> 45ms (12 new underruns)") == true)
    }

    func testACleanNetworkComesDownOnEvidenceAndASilentSecondCountsForNothing() {
        var t = ReceiveAutoTune()
        _ = t.tick(currentMs: 80, underruns: 0, hasAudio: true, frameMs: 5)
        for s in 0..<12 { second(&t, at: Double(s), bufferMs: 75) }
        t.endSecond()   // a second with no packets adds no reading
        XCTAssertEqual(t.arrivalGaps.count, 12)
        var current = 80
        for _ in 0..<4 {
            if let change = t.tick(currentMs: current, underruns: 0, hasAudio: true, frameMs: 5).change { current = change.targetMs }
        }
        XCTAssertLessThan(current, 80)
        XCTAssertGreaterThanOrEqual(current, 5 + 5 + 5, "never below the measured need")
    }

    func testANewStreamStartsTheReadingsAgain() {
        var t = ReceiveAutoTune()
        second(&t, at: 0, lateMs: 200)
        t.newStream()
        XCTAssertTrue(t.arrivalGaps.isEmpty)
        XCTAssertNil(t.tick(currentMs: 20, underruns: 5, hasAudio: true, frameMs: 5).change, "baseline again")
    }

    func testTheLowestDelayTuneCountsGapsAndWaitsAfterYou() {
        var t = ReceiveAutoTune()
        XCTAssertNil(t.lowestDelaySecond(audibleGapsTotal: 10, currentMs: 10, floorMs: 5, on: true, now: 100), "the first reading is the baseline")
        XCTAssertEqual(t.lowestDelaySecond(audibleGapsTotal: 13, currentMs: 10, floorMs: 5, on: true, now: 101)?.targetMs, 12)
        t.youSetIt(now: 102)
        XCTAssertNil(t.lowestDelaySecond(audibleGapsTotal: 20, currentMs: 30, floorMs: 5, on: true, now: 104), "your value stands 5 s")
        XCTAssertNil(t.lowestDelaySecond(audibleGapsTotal: 20, currentMs: 30, floorMs: 5, on: false, now: 110))
    }
}
