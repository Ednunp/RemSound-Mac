import Foundation
import XCTest
@testable import RemSoundCore

final class PluginSourceClockTests: XCTestCase {
    private let generation = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let other = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private typealias Clock = PluginSourceClock<Int>
    private func feed(_ clock: Clock, _ key: Int, _ now: Double, frames: Int = 240) -> Clock.Receipt {
        clock.observe(key, generation: generation, frames: frames, now: now)
    }
    func testFirstActualSourceDrivesWithoutAFreeClock() {
        let clock = Clock(generation: generation)
        XCTAssertNil(clock.currentDriver); XCTAssertEqual(clock.count, 0)
        let result = feed(clock, 9, 10)
        XCTAssertEqual(result.role, .driver); XCTAssertTrue(result.singleSourceDirect)
        XCTAssertEqual(result.driver?.key, 9); XCTAssertTrue(result.driverChanged)
    }
    func testSecondaryDoesNotAdvanceDriverCadence() {
        let clock = Clock(generation: generation); _ = feed(clock, 1, 0)
        let result = feed(clock, 2, 0.1)
        XCTAssertEqual(result.role, .secondary); XCTAssertFalse(result.singleSourceDirect)
        XCTAssertEqual(result.driver?.key, 1); XCTAssertFalse(result.driverChanged)
        XCTAssertEqual(result.sourceCount, 2)
        XCTAssertFalse(feed(clock, 1, 0.2).singleSourceDirect)
    }
    func testExactQuarterSecondKeepsDriverAndLaterBlockTakesOver() {
        let clock = Clock(generation: generation); _ = feed(clock, 1, 0)
        XCTAssertEqual(feed(clock, 2, 0.25).role, .secondary)
        let result = feed(clock, 2, 0.251)
        XCTAssertEqual(result.role, .driver); XCTAssertEqual(result.driver?.key, 2)
        XCTAssertTrue(result.driverChanged); XCTAssertTrue(result.retired.isEmpty)
    }
    func testReturningDriverIsSecondaryUntilActualCurrentDriverStales() {
        let clock = Clock(generation: generation); _ = feed(clock, 1, 0); _ = feed(clock, 2, 0.251)
        XCTAssertEqual(feed(clock, 1, 0.3).role, .secondary)
        XCTAssertEqual(feed(clock, 1, 0.502).role, .driver)
    }
    func testExactTwoSecondExpiryProducesLocalRetirementReceipt() {
        let clock = Clock(generation: generation); let first = feed(clock, 1, 0).visit
        let result = feed(clock, 2, 2)
        XCTAssertEqual(result.retired, first.map { [$0] } ?? [])
        XCTAssertEqual(result.role, .driver); XCTAssertTrue(result.singleSourceDirect)
        XCTAssertEqual(result.sourceCount, 1)
    }
    func testExpiryOfReturningKeyCreatesFreshVisit() {
        let clock = Clock(generation: generation); let first = feed(clock, 1, 0).visit
        let next = feed(clock, 1, 2)
        XCTAssertNotEqual(first, next.visit); XCTAssertEqual(next.retired, first.map { [$0] } ?? [])
        XCTAssertTrue(next.driverChanged); XCTAssertEqual(next.visit?.generation, generation)
    }
    func testGoodbyeElectsEarliestSurvivorInArrivalOrder() {
        let clock = Clock(generation: generation)
        for key in [90, 30, 10] { _ = feed(clock, key, 0) }
        guard let previous = clock.currentDriver else { return XCTFail("driver receipt missing") }
        let result = clock.retire(previous)
        XCTAssertEqual(result.role, .retired); XCTAssertEqual(result.retired.map(\.key), [90])
        XCTAssertEqual(result.driver?.key, 30); XCTAssertTrue(result.driverChanged)
        XCTAssertEqual(clock.retire(previous).failure, .unknownSource)
    }
    func testStaleGenerationCannotFeedRetireOrStopCurrentPolicy() {
        let clock = Clock(generation: generation); _ = feed(clock, 1, 0)
        XCTAssertEqual(clock.observe(2, generation: other, frames: 240, now: .nan).failure, .staleGeneration)
        let stale = Clock(generation: other).observe(1, generation: other, frames: 240, now: 0).visit
        if let stale { XCTAssertEqual(clock.retire(stale).failure, .staleGeneration) }
        else { XCTFail("stale fixture missing") }
        XCTAssertEqual(clock.stop(generation: other).failure, .staleGeneration)
        XCTAssertEqual(clock.count, 1); XCTAssertFalse(clock.isClosed)
        XCTAssertEqual(feed(clock, 1, 0.1).role, .driver)
    }
    func testStopIsTerminalAndDoesNotReuseOldVisits() {
        let clock = Clock(generation: generation); _ = feed(clock, 2, 0); _ = feed(clock, 1, 0)
        let result = clock.stop(generation: generation)
        XCTAssertEqual(result.retired.map(\.key), [2, 1]); XCTAssertEqual(result.role, .closed)
        XCTAssertEqual(feed(clock, 1, 1).failure, .closed)
        XCTAssertTrue(clock.stop(generation: generation).retired.isEmpty)
        XCTAssertEqual(clock.count, 0); XCTAssertNil(clock.currentDriver)
    }
    func testCapacityBoundsNewSourcesButAllowsExistingSource() {
        let clock = Clock(generation: generation)
        for key in 0..<Clock.maximumSources { XCTAssertNotEqual(feed(clock, key, 0).role, .refused) }
        XCTAssertEqual(feed(clock, 999, 0).failure, .capacity)
        XCTAssertEqual(clock.count, 64); XCTAssertEqual(feed(clock, 0, 0).role, .driver)
    }
    func testExpiredSourcesReleaseCapacityBeforeNewAdmission() {
        let clock = Clock(generation: generation)
        for key in 0..<64 { _ = feed(clock, key, 0) }
        let next = feed(clock, 999, 2)
        XCTAssertEqual(next.retired.map(\.key), Array(0..<64)); XCTAssertEqual(next.role, .driver)
        XCTAssertEqual(clock.count, 1)
    }
    func testFrameBoundsRefuseBeforeClockOrInventoryMutation() {
        let clock = Clock(generation: generation); let first = feed(clock, 1, 0).visit
        for count in [0, -1, Clock.maximumFrames + 1, Int.max] {
            let result = feed(clock, 2, .nan, frames: count)
            XCTAssertEqual(result.failure, .invalidFrames); XCTAssertTrue(result.retired.isEmpty)
        }
        XCTAssertEqual(clock.currentDriver, first); XCTAssertFalse(clock.isClosed)
        XCTAssertEqual(feed(clock, 1, 0.1, frames: Clock.maximumFrames).role, .driver)
        XCTAssertEqual(Clock.maximumFrames, 4096)
    }
    func testInvalidBackwardNonfiniteOrUnrepresentableClockClosesOnce() {
        for bad in [-1.0, Double.nan, Double.infinity, Double.greatestFiniteMagnitude, 0.5] {
            let clock = Clock(generation: generation); _ = feed(clock, 1, 1)
            let result = feed(clock, 2, bad)
            XCTAssertEqual(result.role, .closed); XCTAssertEqual(result.failure, .invalidClock)
            XCTAssertEqual(result.retired.map(\.key), [1]); XCTAssertEqual(clock.count, 0)
            XCTAssertTrue(feed(clock, 1, 3).retired.isEmpty)
        }
    }
    func testCoincidentArrivalDoesNotMergeIndependentKeys() {
        struct Source: Hashable { let instance: UInt32, port: UInt16 }
        let clock = PluginSourceClock<Source>(generation: generation)
        let a = Source(instance: 77, port: 50001), b = Source(instance: 77, port: 50002)
        let one = clock.observe(a, generation: generation, frames: 240, now: 0)
        let two = clock.observe(b, generation: generation, frames: 240, now: 0)
        XCTAssertEqual(two.sourceCount, 2); XCTAssertEqual(two.role, .secondary)
        XCTAssertNotEqual(one.visit, two.visit)
    }
    func testEqualTimeIsAllowedAndFutureSourceCannotReviveClosedPolicy() {
        let clock = Clock(generation: generation)
        XCTAssertEqual(feed(clock, 1, 0).role, .driver); XCTAssertEqual(feed(clock, 1, 0).role, .driver)
        _ = feed(clock, 1, 10)
        XCTAssertEqual(feed(clock, 2, 9).failure, .invalidClock)
        XCTAssertEqual(feed(clock, 2, 11).failure, .closed)
    }
    func testOnlyActualInputChangesTimeNoImplicitSweep() {
        let clock = Clock(generation: generation); _ = feed(clock, 1, 0)
        for _ in 0..<100 { XCTAssertEqual(clock.count, 1); XCTAssertEqual(clock.currentDriver?.key, 1) }
        XCTAssertEqual(feed(clock, 2, 10).retired.map(\.key), [1])
    }
    func testExpiredVisitCannotRetireSameKeyReplacement() {
        let clock = Clock(generation: generation)
        guard let previous = feed(clock, 1, 0).visit, let current = feed(clock, 1, 2).visit else {
            return XCTFail("visit receipt missing")
        }
        let result = clock.retire(previous)
        XCTAssertEqual(result.failure, .staleVisit); XCTAssertTrue(result.retired.isEmpty)
        XCTAssertEqual(clock.currentDriver, current)
    }
    func testForeignOwnerCannotRetireMatchingGenerationKeyAndOrder() {
        let clock = Clock(generation: generation), foreign = Clock(generation: generation)
        guard let own = feed(clock, 1, 0).visit, let other = feed(foreign, 1, 0).visit else {
            return XCTFail("owner receipt missing")
        }
        XCTAssertNotEqual(own, other)
        XCTAssertEqual(clock.retire(other).failure, .staleVisit)
        XCTAssertEqual(clock.currentDriver, own)
    }
    func testReleasedPolicyVisitDoesNotRetainOrControlReplacement() {
        weak var released: Clock?
        var retiredVisit: Clock.Visit?
        do {
            let previous = Clock(generation: generation); released = previous
            retiredVisit = feed(previous, 1, 0).visit
        }
        XCTAssertNil(released)
        let next = Clock(generation: generation)
        guard let old = retiredVisit, let current = feed(next, 1, 0).visit else {
            return XCTFail("replacement receipt missing")
        }
        XCTAssertEqual(next.retire(old).failure, .staleVisit)
        XCTAssertEqual(next.currentDriver, current)
    }
    func testFiniteChurnKeepsInventoryBoundedAndVisitsUnique() {
        let clock = Clock(generation: generation); var previous: Clock.Visit?
        for i in 0..<200 {
            let result = feed(clock, i % 3, Double(i) * 2)
            XCTAssertTrue(result.singleSourceDirect); XCTAssertNotEqual(result.visit, previous)
            XCTAssertLessThanOrEqual(result.retired.count, Clock.maximumSources); previous = result.visit
        }
    }
}
