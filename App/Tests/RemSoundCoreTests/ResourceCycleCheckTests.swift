import Foundation
import XCTest
@testable import RemSoundCore

final class ResourceCycleCheckTests: XCTestCase {
    private func snapshot(_ n:Int=0) -> ResourceCycleCheck.Snapshot { .init(residentBytes:UInt64(100+n),threads:2+n,descriptors:3+n,cpuSeconds:Double(n)) }
    private func successful(read: (() throws -> ResourceCycleCheck.Snapshot?)? = nil, seconds:Int=6) -> ResourceCycleCheck.Report {
        var now=0.0,n=0
        return ResourceCycleCheck.run(seconds:seconds,clock:{now},read:{ n += 1;if let read { return try read() };return self.snapshot(n) },work:{ budget in now += budget;return .init(passed:true,quiescent:true,items:1) })
    }
    func testThreeQuiescentCyclesReceiveRemainingBudgetsAndFourMeasurements() {
        var now=0.0,n=0,budgets:[Double]=[]
        let report=ResourceCycleCheck.run(seconds:6,clock:{now},read:{ n += 1;return self.snapshot(n) },work:{ budget in budgets.append(budget);now += budget;return .init(passed:true,quiescent:true,items:2) })
        XCTAssertEqual(budgets,[2,2,2]);XCTAssertEqual(report.completed.map(\.index),[1,2,3])
        XCTAssertEqual(report.completed.map(\.items),[2,2,2]);XCTAssertEqual(report.observations.map(\.cycle),[0,1,2,3])
        XCTAssertEqual(report.termination,.completed);XCTAssertEqual(report.exitCode,3);XCTAssertFalse(report.fullAcceptance)
        XCTAssertTrue(report.completeMetrics);XCTAssertEqual(report.growth.residentBytes,3);XCTAssertEqual(report.growth.cpuSeconds,3)
    }
    func testResourceReductionIsSignedAndDoesNotBecomeALeakVerdict() {
        var n=0
        let report=successful(read:{ n += 1;return .init(residentBytes:UInt64(200-n),threads:20-n,descriptors:30-n,cpuSeconds:Double(n)) })
        XCTAssertEqual(report.growth.residentBytes,-3);XCTAssertEqual(report.growth.threads,-3);XCTAssertEqual(report.growth.descriptors,-3)
        XCTAssertEqual(report.exitCode,3)
    }
    func testMissingMiddleMeasurementCannotInventACompleteMetricOrZero() {
        var now=0.0,n=0
        let report=ResourceCycleCheck.run(seconds:6,clock:{now},read:{ n += 1;return n == 2 ? nil : self.snapshot(n) },work:{ budget in now += budget;return .init(passed:true,quiescent:true,items:1) })
        XCTAssertEqual(report.observations.count,4)
        if report.observations.count > 1 {
            XCTAssertTrue(report.observations[1].collectionFailed)
            XCTAssertNil(report.observations[1].snapshot.residentBytes)
        } else { XCTFail("Missing intermediate receipt") }
        XCTAssertFalse(report.completeMetrics)
        XCTAssertNil(report.growth.residentBytes);XCTAssertNil(report.growth.cpuSeconds);XCTAssertEqual(report.exitCode,3)
    }
    func testThrownMetricsAreExplicitlyUnavailableWithoutPrivateErrors() {
        var now=0.0
        let report=ResourceCycleCheck.run(seconds:6,clock:{now},read:{ throw NSError(domain:"private path secret",code:1) },work:{ budget in now += budget;return .init(passed:true,quiescent:true,items:1) })
        XCTAssertEqual(report.observations.count,4);XCTAssertTrue(report.observations.allSatisfy(\.collectionFailed))
        XCTAssertFalse(report.completeMetrics);XCTAssertNil(report.growth.threads);XCTAssertEqual(report.exitCode,3)
    }
    func testInvalidFieldsAreMarkedAndNeverCoercedToZero() {
        let report=successful(read:{ .init(residentBytes:0,threads:-1,descriptors:Int.max,cpuSeconds:Double.nan) })
        XCTAssertEqual(report.observations.first?.invalid,Set([.threads,.descriptors,.cpuSeconds]))
        XCTAssertEqual(report.observations.first?.snapshot.residentBytes,0)
        XCTAssertNil(report.observations.first?.snapshot.threads);XCTAssertNil(report.growth.cpuSeconds)
        XCTAssertFalse(report.completeMetrics)
    }
    func testCPUCounterRetirementOrRegressionMakesItsGrowthUnavailable() {
        var n=0;let values=[1.0,2.0,1.0,3.0]
        let report=successful(read:{ defer { n += 1 };return .init(residentBytes:100,threads:2,descriptors:3,cpuSeconds:values[n]) })
        XCTAssertNil(report.growth.cpuSeconds);XCTAssertFalse(report.completeMetrics)
        XCTAssertEqual(report.growth.residentBytes,0)
    }
    func testUnsignedGrowthOverflowNeverTruncates() {
        var n=0
        let report=successful(read:{ n += 1;return .init(residentBytes:n == 1 ? 0 : UInt64.max,threads:2,descriptors:3,cpuSeconds:Double(n)) })
        XCTAssertNil(report.growth.residentBytes);XCTAssertFalse(report.completeMetrics)
    }
    func testInvalidBudgetOrInitialClockRefusesAllFactories() {
        for seconds in [0,5,121,Int.max] {
            let result=ResourceCycleCheck.run(seconds:seconds,clock:{0},read:{ XCTFail("Read metrics");return nil },work:{ _ in XCTFail("Constructed work");return .init(passed:true,quiescent:true,items:1) })
            XCTAssertEqual(result.termination,.invalidBudget);XCTAssertEqual(result.exitCode,1)
        }
        for now in [-1,Double.nan,Double.infinity] {
            let result=ResourceCycleCheck.run(clock:{now},read:{ XCTFail("Read metrics");return nil },work:{ _ in XCTFail("Constructed work");return .init(passed:true,quiescent:true,items:1) })
            XCTAssertEqual(result.termination,.invalidClock);XCTAssertEqual(result.exitCode,1)
        }
    }
    func testCancellationBeforeBaselineConstructsNothing() {
        let result=ResourceCycleCheck.run(clock:{0},cancelled:{true},read:{ XCTFail("Read metrics");return nil },work:{ _ in XCTFail("Constructed work");return .init(passed:true,quiescent:true,items:1) })
        XCTAssertEqual(result.termination,.cancelled);XCTAssertEqual(result.exitCode,3)
    }
    func testCancellationDuringBaselinePreventsWork() {
        var stop=false,visits=0
        let result=ResourceCycleCheck.run(clock:{0},cancelled:{stop},read:{ stop=true;return self.snapshot() },work:{ _ in visits += 1;return .init(passed:true,quiescent:true,items:1) })
        XCTAssertEqual(visits,0);XCTAssertEqual(result.termination,.cancelled)
    }
    func testCancellationDuringWorkStopsAfterItsQuiescentReceipt() {
        var now=0.0,stop=false,visits=0,reads=0
        let result=ResourceCycleCheck.run(seconds:6,clock:{now},cancelled:{stop},read:{ reads += 1;return self.snapshot() },work:{ budget in visits += 1;now += budget;stop=true;return .init(passed:true,quiescent:true,items:1) })
        XCTAssertEqual(visits,1);XCTAssertEqual(reads,2);XCTAssertEqual(result.termination,.cancelled)
        XCTAssertTrue(result.completed.isEmpty);XCTAssertEqual(result.exitCode,3)
    }
    func testNonQuiescentOrThrownWorkNeverStartsMeasurementOrAnotherCycle() {
        for throwing in [false,true] {
            var visits=0,reads=0
            let result=ResourceCycleCheck.run(seconds:6,clock:{0},read:{ reads += 1;return self.snapshot() },work:{ _ in
                visits += 1;if throwing { throw NSError(domain:"private side effect",code:1) }
                return .init(passed:true,quiescent:false,items:1)
            })
            XCTAssertEqual(visits,1);XCTAssertEqual(reads,1);XCTAssertEqual(result.termination,.cleanupUnresolved);XCTAssertEqual(result.exitCode,1)
        }
    }
    func testFailedQuiescentWorkIsMeasuredButCannotReopen() {
        var now=0.0,visits=0,reads=0
        let result=ResourceCycleCheck.run(seconds:6,clock:{now},read:{ reads += 1;return self.snapshot() },work:{ budget in visits += 1;now += budget;return .init(passed:false,quiescent:true,items:1) })
        XCTAssertEqual(visits,1);XCTAssertEqual(reads,2);XCTAssertEqual(result.termination,.workFailed);XCTAssertEqual(result.exitCode,1)
    }
    func testEmptyNegativeOrUnboundedWorkReceiptsFailBeforeAnotherCycle() {
        for items in [0,-1,4097] {
            var now=0.0,visits=0
            let result=ResourceCycleCheck.run(seconds:6,clock:{now},read:{self.snapshot()},work:{ budget in visits += 1;now += budget;return .init(passed:true,quiescent:true,items:items) })
            XCTAssertEqual(visits,1);XCTAssertEqual(result.termination,.invalidReceipt);XCTAssertEqual(result.exitCode,1)
        }
    }
    func testEarlyWorkReturnIsIncompleteNotACompletedPerformanceCycle() {
        var now=0.0,visits=0
        let result=ResourceCycleCheck.run(seconds:6,clock:{now},read:{self.snapshot()},work:{ _ in visits += 1;now += 0.5;return .init(passed:true,quiescent:true,items:1) })
        XCTAssertEqual(visits,1);XCTAssertTrue(result.completed.isEmpty)
        XCTAssertEqual(result.termination,.incompleteCycle);XCTAssertEqual(result.exitCode,3)
    }
    func testBaselineThatConsumesFirstBudgetDoesNotStartWork() {
        var now=0.0,visits=0
        let result=ResourceCycleCheck.run(seconds:6,clock:{now},read:{ now=2;return self.snapshot() },work:{ _ in visits += 1;return .init(passed:true,quiescent:true,items:1) })
        XCTAssertEqual(visits,0);XCTAssertEqual(result.termination,.deadline);XCTAssertEqual(result.exitCode,1)
    }
    func testBackwardAndNonfiniteClockAfterWorkCannotPublishCycle() {
        for bad in [-1.0,Double.nan,Double.infinity] {
            var now=0.0,visits=0
            let result=ResourceCycleCheck.run(seconds:6,clock:{now},read:{self.snapshot()},work:{ _ in visits += 1;now=bad;return .init(passed:true,quiescent:true,items:1) })
            XCTAssertEqual(visits,1);XCTAssertEqual(result.termination,.invalidClock);XCTAssertTrue(result.completed.isEmpty)
        }
    }
    func testSlowPriorMeasurementReducesNextBudgetWithoutRestartingDeadline() {
        var now=0.0,n=0,budgets:[Double]=[]
        let result=ResourceCycleCheck.run(seconds:6,clock:{now},read:{ n += 1;if n == 2 { now += 0.5 };return self.snapshot(n) },work:{ budget in budgets.append(budget);now += budget;return .init(passed:true,quiescent:true,items:1) })
        XCTAssertEqual(budgets,[2,1.5,2]);XCTAssertEqual(result.termination,.completed)
    }
    func testActualMemoryChecksUseMockMetricsWithoutClaimingNativeResourceProof() {
        var now=0.0,n=0
        let result=ResourceCycleCheck.run(seconds:6,clock:{now},read:{ n += 1;return self.snapshot(n) },work:{ budget in
            let check=ProductSelfCheck.run(budget:budget);now += budget
            return .init(passed:check.termination == .completed && check.steps.allSatisfy { $0.status == .passed },quiescent:true,items:1)
        })
        XCTAssertEqual(result.completed.count,3);XCTAssertEqual(result.exitCode,3);XCTAssertFalse(result.fullAcceptance)
    }
    func testBoundedRepeatedRunsRetainOnlyFourSnapshotsAndThreeCycles() {
        for _ in 0..<200 {
            let report=successful()
            guard report.observations.count == 4, report.completed.count == 3 else { XCTFail("Missing bounded receipt");break }
            XCTAssertEqual(report.observations.count,4);XCTAssertEqual(report.completed.count,3)
        }
    }
    func testUnrepresentableFiniteDeadlinesRefuseBeforeMetricsOrWork() {
        let report=ResourceCycleCheck.run(seconds:6,clock:{Double.greatestFiniteMagnitude},read:{ XCTFail("Read metrics");return nil },work:{ _ in XCTFail("Constructed work");return .init(passed:true,quiescent:true,items:1) })
        XCTAssertEqual(report.termination,.invalidClock);XCTAssertEqual(report.exitCode,1)
    }
    func testFailedWorkWinsOverCancellationAfterItsReceipt() {
        var now=0.0,stop=false
        let report=ResourceCycleCheck.run(seconds:6,clock:{now},cancelled:{stop},read:{self.snapshot()},work:{ budget in now += budget;stop=true;return .init(passed:false,quiescent:true,items:1) })
        XCTAssertEqual(report.termination,.workFailed);XCTAssertEqual(report.exitCode,1)
    }
    func testCancellationInAfterMeasurementCannotPublishACompletedCycle() {
        var now=0.0,n=0,stop=false,visits=0
        let report=ResourceCycleCheck.run(seconds:6,clock:{now},cancelled:{stop},read:{ n += 1;if n == 2 { stop=true };return self.snapshot(n) },work:{ budget in visits += 1;now += budget;return .init(passed:true,quiescent:true,items:1) })
        XCTAssertEqual(visits,1);XCTAssertEqual(report.termination,.cancelled);XCTAssertTrue(report.completed.isEmpty)
    }
    func testLateWorkThatConsumesLaterCyclesDoesNotRestartTheVisitBudget() {
        var now=0.0,visits=0
        let report=ResourceCycleCheck.run(seconds:6,clock:{now},read:{self.snapshot()},work:{ _ in visits += 1;now=10;return .init(passed:true,quiescent:true,items:1) })
        XCTAssertEqual(visits,1);XCTAssertEqual(report.termination,.deadline);XCTAssertEqual(report.exitCode,1)
    }
}
