import XCTest
@testable import RemSoundJam

/// The Windows auto-tunes' own checks (SelfTest.AutoTuneDescentPolicy and its neighbours, SelfTest.LowestDelayTune),
/// run against the Swift port.
final class WindowsAutoTuneTests: XCTestCase {
    typealias D = AutoTuneDescent

    func testTheFloorIsTheMeasurementAndNothingArguesItDown() {
        XCTAssertGreaterThanOrEqual(D.nextTarget(currentMs: 500, recommendedMs: 40, lowWaterMs: 460, sampleCount: 15, consecutiveCleanTicks: 10), 40)
        XCTAssertGreaterThanOrEqual(D.nextTarget(currentMs: 60, recommendedMs: 55, lowWaterMs: 500, sampleCount: 60, consecutiveCleanTicks: 99), 55)
        XCTAssertEqual(D.nextTarget(currentMs: 40, recommendedMs: 40, lowWaterMs: 30, sampleCount: 15, consecutiveCleanTicks: 9), 40)
        XCTAssertEqual(D.nextTarget(currentMs: 30, recommendedMs: 90, lowWaterMs: 5, sampleCount: 15, consecutiveCleanTicks: 9), 30,
                       "a raise is not this function's job")
    }

    func testASillySettingSnapsToTheNeedAndItsHeadroom() {
        XCTAssertEqual(D.nextTarget(currentMs: 500, recommendedMs: 20, lowWaterMs: -1, sampleCount: 0, consecutiveCleanTicks: 0),
                       20 + D.default.headroomMs)
    }

    func testConfidentEvidenceMovesFurtherButThinEvidenceStillProgresses() {
        let noHistory = D.nextTarget(currentMs: 110, recommendedMs: 20, lowWaterMs: 90, sampleCount: 2, consecutiveCleanTicks: 9)
        let dirtyRun = D.nextTarget(currentMs: 110, recommendedMs: 20, lowWaterMs: 90, sampleCount: 15, consecutiveCleanTicks: 0)
        let confident = D.nextTarget(currentMs: 110, recommendedMs: 20, lowWaterMs: 90, sampleCount: 15, consecutiveCleanTicks: 9)
        XCTAssertLessThan(confident, dirtyRun)
        XCTAssertLessThan(confident, noHistory)
        XCTAssertLessThan(dirtyRun, 110)
        XCTAssertLessThan(noHistory, 110)
        XCTAssertLessThan(D.nextTarget(currentMs: 110, recommendedMs: 20, lowWaterMs: -1, sampleCount: 15, consecutiveCleanTicks: 9), 110)
    }

    func testFiveHundredConvergesInAHandfulOfTicks() {
        var current = 500, ticks = 0
        while current > 25 && ticks < 200 {
            let next = D.nextTarget(currentMs: current, recommendedMs: 20, lowWaterMs: max(0, current - 20), sampleCount: 15, consecutiveCleanTicks: 10)
            if abs(next - current) < 5 { break }
            current = next; ticks += 1
        }
        XCTAssertLessThanOrEqual(ticks, 12)
        XCTAssertGreaterThanOrEqual(current, 20)
    }

    func testTheCreepShavesSlowlyToTheNeedAndALearnedFloorSticks() {
        let creep = D.CreepState()
        var cur = 60, creepTicks = 0
        while cur > 30 && creepTicks < 200 {
            let n = D.nextTarget(currentMs: cur, recommendedMs: 30, lowWaterMs: max(0, cur - 30), sampleCount: 15,
                                 consecutiveCleanTicks: 20, creep: creep)
            creepTicks += 1
            if n == cur { continue }
            cur = n
        }
        XCTAssertLessThanOrEqual(cur, 32)
        XCTAssertGreaterThan(creepTicks, 10, "the creep must be slow")

        let learned = D.CreepState()
        learned.noteShortfallAt(35, justifiedMs: 35)
        XCTAssertGreaterThan(learned.discoveredFloorMs, 35)
        let held = D.nextTarget(currentMs: 60, recommendedMs: 20, lowWaterMs: 40, sampleCount: 15, consecutiveCleanTicks: 30, creep: learned)
        XCTAssertGreaterThanOrEqual(held, learned.discoveredFloorMs)
        XCTAssertEqual(D.nextTarget(currentMs: learned.discoveredFloorMs, recommendedMs: 20, lowWaterMs: 30, sampleCount: 15,
                                    consecutiveCleanTicks: 30, creep: learned), learned.discoveredFloorMs)
        learned.reset()
        XCTAssertEqual(learned.discoveredFloorMs, 0)
    }

    func testTheWayUpIsAsDecisiveAsTheWayDown() {
        let silly = D.nextRaiseTarget(currentMs: 5, recommendedMs: 47, learnedFloorMs: 8)
        XCTAssertEqual(silly, 47, "one step on the measurement")
        XCTAssertEqual(D.nextRaiseTarget(currentMs: silly, recommendedMs: 47, learnedFloorMs: 8), 47, "and then hold")
        XCTAssertEqual(D.nextRaiseTarget(currentMs: 20, recommendedMs: 26, learnedFloorMs: 40), 40, "the learned floor wins when higher")
    }

    /// Ed, 2026-08-22: set to 20 ms with auto-tune on, it sat at 20 underrunning. A shortfall must raise at once, to the
    /// measured need.
    func testUnderrunsRaiseToTheMeasuredNeedInOneTick() {
        var clean = 0
        let creep = D.CreepState()
        let d = ContinuousAutoTune.decide(currentMs: 20, sliderMinMs: 2, sliderMaxMs: 200, underrunDelta: 140,
            arrivalGaps: [12, 30, 28, 31, 29], renderCbGaps: [3, 3, 3, 3, 3], minBuffers: [0, 0, 0, 0, 0],
            codecFloorMs: ContinuousAutoTune.codecFloorMs(frameMs: 10), cleanTicks: &clean, creep: creep)
        XCTAssertEqual(d.verdict, .raise)
        XCTAssertEqual(d.gapUsedMs, 30, "the second-highest second, a lone spike ignored")
        XCTAssertEqual(d.target, 30 + 3 + 5, "gap + render period + safety")
        XCTAssertEqual(clean, 0)
    }

    func testALoneSpikeDoesNotDriveTheRecommendation() {
        var clean = 0
        let d = ContinuousAutoTune.decide(currentMs: 40, sliderMinMs: 2, sliderMaxMs: 200, underrunDelta: 0,
            arrivalGaps: [5, 6, 1046, 5, 6, 5], renderCbGaps: [3], minBuffers: [30, 30, 30],
            codecFloorMs: 15, cleanTicks: &clean, creep: D.CreepState())
        XCTAssertEqual(d.gapPeakMs, 1046)
        XCTAssertEqual(d.gapUsedMs, 6)
        XCTAssertNotEqual(d.verdict, .raise)
        XCTAssertLessThanOrEqual(d.target, 40)
    }

    func testTheCodecFloorAndTheCap() {
        XCTAssertEqual(ContinuousAutoTune.codecFloorMs(frameMs: 5), 8)
        XCTAssertEqual(ContinuousAutoTune.codecFloorMs(frameMs: 10), 15)
        var clean = 0
        let d = ContinuousAutoTune.decide(currentMs: 50, sliderMinMs: 2, sliderMaxMs: 300, underrunDelta: 5,
            arrivalGaps: [400, 400, 400], renderCbGaps: [10], minBuffers: [], codecFloorMs: 15, cleanTicks: &clean, creep: D.CreepState())
        XCTAssertEqual(d.cappedMs, 200)
        XCTAssertEqual(d.target, 200, "never past the recommendation cap on its own")
    }

    // The lowest-delay auto-tune (SelfTest.LowestDelayTune).
    func testThreeGapsInASecondRaiseTwoAndAStillTroubledRaiseDoubles() {
        let t = DropoutTuner()
        XCTAssertEqual(t.tick(gapsThisSecond: 3, currentMs: 10, floorMs: 5, ceilingMs: 200), 12)
        XCTAssertEqual(t.tick(gapsThisSecond: 3, currentMs: 12, floorMs: 5, ceilingMs: 200), 16, "still in trouble: up 4")
        XCTAssertEqual(t.lastReason, "3 gaps in one second - up 4 ms")
    }

    func testFourGapsInTwentySecondsRaiseAndARareGapHolds() {
        let t = DropoutTuner()
        XCTAssertEqual(t.tick(gapsThisSecond: 1, currentMs: 10, floorMs: 5, ceilingMs: 200), 10)
        XCTAssertEqual(t.lastReason, "a gap, still rare - holding")
        XCTAssertEqual(t.tick(gapsThisSecond: 1, currentMs: 10, floorMs: 5, ceilingMs: 200), 10)
        XCTAssertEqual(t.tick(gapsThisSecond: 2, currentMs: 10, floorMs: 5, ceilingMs: 200), 12)
    }

    func testFarAboveItHalvesTowardTheFloorThenGoesDownAMillisecondAtATime() {
        let t = DropoutTuner()
        XCTAssertEqual(t.tick(gapsThisSecond: 0, currentMs: 85, floorMs: 5, ceilingMs: 200), 85)
        XCTAssertEqual(t.tick(gapsThisSecond: 0, currentMs: 85, floorMs: 5, ceilingMs: 200), 45, "two quiet seconds: half the way")
        _ = t.tick(gapsThisSecond: 1, currentMs: 45, floorMs: 5, ceilingMs: 200)   // a gap met
        var current = 45
        for _ in 0..<4 { current = t.tick(gapsThisSecond: 0, currentMs: current, floorMs: 5, ceilingMs: 200) }
        XCTAssertEqual(current, 45)
        XCTAssertEqual(t.tick(gapsThisSecond: 0, currentMs: current, floorMs: 5, ceilingMs: 200), 44, "five quiet seconds: down 1")
    }
}
