import Foundation
import XCTest
@testable import RemSoundCore

final class ResourceCycleReportTests:XCTestCase {
    private func complete(snapshots:[ResourceCycleReport.Snapshot]?=nil)->ResourceCycleReport {
        let values=snapshots ?? (0...3).map {_ in .init(residentBytes:100,threads:2,descriptors:5,cpuSeconds:1)}
        return .init(requestedSeconds:6,provenance:.injected,
            observations:values.enumerated().map {.init(cycle:$0.offset,elapsed:Double($0.offset)*2,snapshot:$0.element)},
            completed:(1...3).map {.init(index:$0,elapsed:2,items:10)},termination:.completed)
    }
    func testCompleteValuesStayPartialAndSendable() {
        func sendable<T:Sendable>(_ value:T) { }
        let report=complete();sendable(report)
        XCTAssertTrue(report.isValid);XCTAssertEqual(report.exitCode,3);XCTAssertFalse(report.fullAcceptance)
        XCTAssertEqual(report.growth.descriptors,0);XCTAssertEqual(report.growth.cpuSeconds,0)
    }
    func testIncompleteAndUnavailableMetricsNeverBecomeZero() {
        let report=complete(snapshots:[.init(residentBytes:200,threads:2,descriptors:5,cpuSeconds:1),.init(),.init(),.init(residentBytes:100,threads:1,descriptors:4,cpuSeconds:2)])
        XCTAssertTrue(report.isValid);XCTAssertNil(report.growth.residentBytes);XCTAssertNil(report.growth.threads)
        XCTAssertNil(report.growth.descriptors);XCTAssertNil(report.growth.cpuSeconds);XCTAssertEqual(report.exitCode,3)
    }
    func testSignedAndOverflowGrowthReuseConservativeMath() {
        let report=complete(snapshots:(0...3).map {.init(residentBytes:UInt64(100-$0),threads:4-$0,descriptors:5-$0,cpuSeconds:Double($0))})
        XCTAssertEqual(report.growth.residentBytes,-3);XCTAssertEqual(report.growth.threads,-3)
        XCTAssertEqual(report.growth.descriptors,-3);XCTAssertEqual(report.growth.cpuSeconds,3)
        let overflow=complete(snapshots:[.init(residentBytes:0),.init(residentBytes:1),.init(residentBytes:2),.init(residentBytes:UInt64.max)])
        XCTAssertNil(overflow.growth.residentBytes)
    }
    func testBrokenCataloguesCannotPublishCompletion() {
        let empty=ResourceCycleReport(requestedSeconds:6,provenance:.notCollected,observations:[],completed:[],termination:.completed)
        XCTAssertFalse(empty.isValid);XCTAssertEqual(empty.exitCode,1)
        let good=complete()
        let excessive=ResourceCycleReport(requestedSeconds:6,provenance:.injected,observations:good.observations+good.observations,completed:good.completed,termination:.completed)
        XCTAssertFalse(excessive.isValid);XCTAssertNil(excessive.growth.descriptors)
        let zero=ResourceCycleReport(requestedSeconds:6,provenance:.injected,observations:good.observations,completed:(1...3).map {.init(index:$0,elapsed:2,items:0)},termination:.completed)
        XCTAssertFalse(zero.isValid);XCTAssertEqual(zero.exitCode,1)
    }
    func testBadChronologyMetricsAndProvenanceFailClosed() {
        let good=complete()
        for snapshot:ResourceCycleReport.Snapshot in [.init(threads:0),.init(descriptors:-1),.init(cpuSeconds:.nan)] {
            XCTAssertFalse(complete(snapshots:[snapshot,snapshot,snapshot,snapshot]).isValid)
        }
        let backwards=ResourceCycleReport(requestedSeconds:6,provenance:.injected,
            observations:good.observations.reversed(),completed:good.completed,termination:.completed)
        XCTAssertFalse(backwards.isValid)
        let falseProvenance=ResourceCycleReport(requestedSeconds:6,provenance:.notCollected,observations:good.observations,completed:good.completed,termination:.completed)
        XCTAssertFalse(falseProvenance.isValid)
    }
    func testControlAndCleanupFailuresStayFailure() {
        for reason:ResourceCycleReport.Termination in [.invalidBudget,.invalidClock,.deadline,.workFailed,.cleanupUnresolved,.invalidReceipt] {
            let report=ResourceCycleReport(requestedSeconds:6,provenance:.notCollected,observations:[],completed:[],termination:reason)
            XCTAssertTrue(report.isValid);XCTAssertEqual(report.exitCode,1)
        }
        for reason:ResourceCycleReport.Termination in [.cancelled,.incompleteCycle] {
            let report=ResourceCycleReport(requestedSeconds:6,provenance:.notCollected,observations:[],completed:[],termination:reason)
            XCTAssertTrue(report.isValid);XCTAssertEqual(report.exitCode,3);XCTAssertNil(report.growth.residentBytes)
        }
    }
    func testNativeFacadeExecutesActualScopedWork() {
        let report=ProductResourceCycle.run(seconds:6)
        XCTAssertTrue(report.isValid);XCTAssertEqual(report.termination,.completed);XCTAssertEqual(report.exitCode,3)
        XCTAssertEqual(report.provenance,.nativeCurrentProcess);XCTAssertEqual(report.observations.count,4)
        XCTAssertTrue(report.completed.allSatisfy {$0.items>0})
    }
    func testInvalidBudgetHasNoCollectedProvenance() {
        let report=ProductResourceCycle.run(seconds:0)
        XCTAssertEqual(report.provenance,.notCollected);XCTAssertTrue(report.observations.isEmpty)
        XCTAssertTrue(report.isValid);XCTAssertEqual(report.exitCode,1)
    }
    func testCompletionCannotRestartOrInventElapsedBudget() {
        let good=complete()
        let early=ResourceCycleReport(requestedSeconds:6,provenance:.injected,
            observations:(0...3).map {.init(cycle:$0,elapsed:0,snapshot:.init())},completed:good.completed,termination:.completed)
        XCTAssertFalse(early.isValid);XCTAssertEqual(early.exitCode,1)
        let zero=ResourceCycleReport(requestedSeconds:6,provenance:.injected,observations:good.observations,
            completed:(1...3).map {.init(index:$0,elapsed:0,items:1)},termination:.completed)
        XCTAssertFalse(zero.isValid)
    }
    func testFailedCollectionCannotRetainInventedCounters() {
        let good=complete()
        let bad=ResourceCycleReport(requestedSeconds:6,provenance:.injected,
            observations:[.init(cycle:0,elapsed:0,snapshot:.init(descriptors:1),collectionFailed:true)],completed:[],termination:.cancelled)
        XCTAssertFalse(bad.isValid)
        let valid=ResourceCycleReport(requestedSeconds:6,provenance:.injected,
            observations:good.observations.map {.init(cycle:$0.cycle,elapsed:$0.elapsed,snapshot:.init(),collectionFailed:true)},completed:good.completed,termination:.completed)
        XCTAssertTrue(valid.isValid);XCTAssertNil(valid.growth.cpuSeconds);XCTAssertEqual(valid.exitCode,3)
    }
    func testIntermediateCPURegressionRemainsUnavailable() {
        let report=complete(snapshots:[.init(cpuSeconds:1),.init(cpuSeconds:3),.init(cpuSeconds:2),.init(cpuSeconds:4)])
        XCTAssertTrue(report.isValid);XCTAssertNil(report.growth.cpuSeconds)
    }
}
