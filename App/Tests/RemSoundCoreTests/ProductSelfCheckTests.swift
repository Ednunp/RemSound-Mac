import Foundation
import XCTest
import RemSoundCore

final class ProductSelfCheckTests: XCTestCase {
    private func report(_ steps: [SelfCheckReport.Step], _ termination: SelfCheckReport.Termination = .completed) -> SelfCheckReport { .init(steps:steps,termination:termination) }
    private var passed: [SelfCheckReport.Step] { SelfCheckReport.ID.allCases.map { .init(id:$0,status:.passed,assertions:1) } }
    func testOrdinaryCoreImportRunsActualChecksAndRemainsPartial() {
        let result=ProductSelfCheck.run(budget:3)
        XCTAssertTrue(result.isValid);XCTAssertEqual(result.termination,.completed)
        XCTAssertTrue(result.steps.allSatisfy { $0.status == .passed && $0.assertions > 0 })
        XCTAssertEqual(result.exitCode,3);XCTAssertFalse(result.fullAcceptance)
        XCTAssertEqual(result.unverified,SelfCheckReport.Unverified.allCases)
    }
    func testValidPassedReceiptsStillCannotClaimFullAcceptance() {
        let value=report(passed)
        XCTAssertTrue(value.isValid);XCTAssertEqual(value.exitCode,3);XCTAssertFalse(value.fullAcceptance)
    }
    func testMissingDuplicatedReorderedOrOversizedCatalogFailsClosed() {
        for steps in [Array(passed.dropLast()),Array(passed.reversed()),passed+[passed[0]],Array(repeating:passed[0],count:5)] {
            XCTAssertFalse(report(steps).isValid);XCTAssertEqual(report(steps).exitCode,1)
        }
    }
    func testInvalidAssertionReceiptsAndIncompleteCompletionFailClosed() {
        for (status,count) in [(SelfCheckReport.Status.passed,0),(.passed,-1),(.passed,10_001),(.notRun,1),(.failed,-1),(.notRun,0)] {
            var values=passed;values[0] = .init(id:.wire,status:status,assertions:count)
            XCTAssertFalse(report(values).isValid);XCTAssertEqual(report(values).exitCode,1)
        }
    }
    func testFailureAndControlTerminationRetainTruthfulExitCodes() {
        var values=passed;values[0] = .init(id:.wire,status:.failed,assertions:0)
        XCTAssertTrue(report(values).isValid);XCTAssertEqual(report(values).exitCode,1)
        let absent=SelfCheckReport.ID.allCases.map { SelfCheckReport.Step(id:$0,status:.notRun,assertions:0) }
        for termination in [SelfCheckReport.Termination.cancelled,.invalidBudget,.invalidClock,.deadline] {
            let value=report(absent,termination);XCTAssertTrue(value.isValid)
            XCTAssertEqual(value.exitCode,termination == .cancelled ? 3 : 1)
        }
    }
    func testInvalidNativeBudgetReturnsOnlyUnrunSteps() {
        for budget in [-1,0,9,Double.nan,Double.infinity] {
            let value=ProductSelfCheck.run(budget:budget)
            XCTAssertEqual(value.termination,.invalidBudget);XCTAssertEqual(value.exitCode,1)
            XCTAssertTrue(value.steps.allSatisfy { $0.status == .notRun && $0.assertions == 0 })
        }
    }
}
