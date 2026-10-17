import Foundation
import XCTest
@testable import RemSoundCore

final class CoreSelfCheckTests: XCTestCase {
    func testActualSyntheticProductionChecksPassWithoutClaimingFullAcceptance() {
        let report=CoreSelfCheck.run()
        XCTAssertEqual(report.termination,.completed)
        XCTAssertEqual(report.steps.map(\.id),CoreSelfCheck.ID.allCases)
        XCTAssertTrue(report.steps.allSatisfy { $0.status == .passed && $0.assertions > 0 })
        XCTAssertEqual(report.exitCode,3)
        XCTAssertFalse(report.fullAcceptance)
        XCTAssertEqual(report.unverified.count,4)
    }
    func testEveryCheckRunsOnceAndOnlyExplicitAssertionsCanPass() {
        var ids:[CoreSelfCheck.ID]=[]
        let report=CoreSelfCheck.run(clock:{0},execute:{ ids.append($0);return 1 })
        XCTAssertEqual(ids,CoreSelfCheck.ID.allCases)
        XCTAssertTrue(report.steps.allSatisfy { $0.status == .passed && $0.assertions == 1 })
        XCTAssertEqual(report.exitCode,3)
    }
    func testZeroNegativeAndUnboundedAssertionReceiptsFail() {
        for count in [0,-1,10_001] {
            let report=CoreSelfCheck.run(clock:{0},execute:{ _ in count })
            XCTAssertTrue(report.steps.allSatisfy { $0.status == .failed })
            XCTAssertEqual(report.exitCode,1)
        }
    }
    func testThrownCheckFailsAndLaterIndependentChecksStillRun() {
        var visits=0
        let report=CoreSelfCheck.run(clock:{0},execute:{ id in
            visits += 1
            if id == .wire { throw NSError(domain:"private fixture secret path",code:1) }
            return 1
        })
        XCTAssertEqual(visits,5);XCTAssertEqual(report.steps.first?.status,.failed)
        XCTAssertTrue(report.steps.dropFirst().allSatisfy { $0.status == .passed })
        XCTAssertEqual(report.exitCode,1)
    }
    func testCancellationBeforeStartConstructsNoCheck() {
        var visits=0
        let report=CoreSelfCheck.run(cancelled:{true},execute:{ _ in visits += 1;return 1 })
        XCTAssertEqual(visits,0);XCTAssertEqual(report.termination,.cancelled)
        XCTAssertTrue(report.steps.allSatisfy { $0.status == .notRun });XCTAssertEqual(report.exitCode,3)
    }
    func testCancellationDuringCheckRetiresBeforeStartingNext() {
        var stop=false,visits=0
        let report=CoreSelfCheck.run(clock:{0},cancelled:{stop},execute:{ _ in visits += 1;stop=true;return 1 })
        XCTAssertEqual(visits,1);XCTAssertEqual(report.termination,.cancelled)
        XCTAssertFalse(report.steps.contains { $0.status == .passed });XCTAssertEqual(report.exitCode,3)
    }
    func testInvalidBudgetOrInitialClockRefusesBeforeExecution() {
        for budget in [0,-1,9,Double.nan,Double.infinity] {
            let report=CoreSelfCheck.run(budget:budget,clock:{0},execute:{ _ in XCTFail("Constructed check");return 1 })
            XCTAssertEqual(report.termination,.invalidBudget);XCTAssertEqual(report.exitCode,1)
        }
        for clock in [Double.nan,Double.infinity,-Double.infinity,-1] {
            let report=CoreSelfCheck.run(clock:{clock},execute:{ _ in XCTFail("Constructed check");return 1 })
            XCTAssertEqual(report.termination,.invalidClock);XCTAssertEqual(report.exitCode,1)
        }
    }
    func testBackwardClockRefusesBeforeNextCheck() {
        var values=[10.0,9.0],visits=0
        let report=CoreSelfCheck.run(clock:{values.isEmpty ? 9 : values.removeFirst()},execute:{ _ in visits += 1;return 1 })
        XCTAssertEqual(visits,0);XCTAssertEqual(report.termination,.invalidClock);XCTAssertEqual(report.exitCode,1)
    }
    func testDeadlineAfterNativeCheckCannotBecomeSuccessfulCompletion() {
        var values=[0.0,0.0,8.0],visits=0
        let report=CoreSelfCheck.run(clock:{values.isEmpty ? 8 : values.removeFirst()},execute:{ _ in visits += 1;return 1 })
        XCTAssertEqual(visits,1);XCTAssertEqual(report.termination,.deadline)
        XCTAssertFalse(report.steps.contains { $0.status == .passed });XCTAssertEqual(report.exitCode,1)
    }
    func testDeadlineBeforeNativeCheckConstructsNothing() {
        var values=[0.0,8.0],visits=0
        let report=CoreSelfCheck.run(clock:{values.isEmpty ? 8 : values.removeFirst()},execute:{ _ in visits += 1;return 1 })
        XCTAssertEqual(visits,0);XCTAssertEqual(report.termination,.deadline);XCTAssertEqual(report.exitCode,1)
    }
    func testNonfiniteClockAfterCheckCannotPublishAPass() {
        var values=[0.0,0.0,Double.nan],visits=0
        let report=CoreSelfCheck.run(clock:{values.isEmpty ? Double.nan : values.removeFirst()},execute:{ _ in visits += 1;return 1 })
        XCTAssertEqual(visits,1);XCTAssertEqual(report.termination,.invalidClock)
        XCTAssertFalse(report.steps.contains { $0.status == .passed });XCTAssertEqual(report.exitCode,1)
    }
    func testEarlierFailureRemainsFailureWhenALaterCheckIsCancelled() {
        var stop=false,visits=0
        let report=CoreSelfCheck.run(clock:{0},cancelled:{stop},execute:{ id in
            visits += 1
            if id == .wire { throw NSError(domain:"private error",code:1) }
            stop=true;return 1
        })
        XCTAssertEqual(visits,2);XCTAssertEqual(report.termination,.cancelled)
        XCTAssertEqual(report.steps.first?.status,.failed);XCTAssertEqual(report.exitCode,1)
    }
}
