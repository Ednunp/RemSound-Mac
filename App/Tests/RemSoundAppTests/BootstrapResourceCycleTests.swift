import Foundation
import RemSoundCore
import RemSoundRuntime
import XCTest
@testable import RemSoundApp
final class BootstrapResourceCycleTests:XCTestCase {
    private func report(_ seconds:Int=6)->ResourceCycleReport {
        .init(requestedSeconds:seconds,provenance:.injected,
            observations:(0...3).map {.init(cycle:$0,elapsed:Double($0)*2,snapshot:.init(residentBytes:UInt64(100-$0),threads:4-$0,descriptors:5-$0,cpuSeconds:Double($0)))},
            completed:(1...3).map {.init(index:$0,elapsed:2,items:10)},termination:.completed)
    }
    private func options()->LaunchOptions {var value=try! LaunchOptions.parse([]);value.report = .resourceCycle;value.resourceCycleSeconds=6;return value}
    func testReadablePartialScopeAndSignedValues() throws {
        let value=try XCTUnwrap(BootstrapResourceCycle.output(for:options(),run:{self.report($0)}))
        XCTAssertEqual(value.exitCode,3);XCTAssertTrue(value.text.contains("RESULT: PARTIAL (exit 3)"))
        XCTAssertTrue(value.text.contains("Provenance: injected"));XCTAssertTrue(value.text.contains("minus 3"))
        XCTAssertTrue(value.text.contains("cooperative"));XCTAssertTrue(value.text.contains("UNVERIFIED"))
        XCTAssertTrue(value.text.contains("4096 retired work items"))
        XCTAssertFalse(value.text.contains("RESULT: PASS"));XCTAssertLessThan(value.text.utf8.count,16*1024)
    }
    func testNoProviderForHelpOrUnrelatedMode() throws {
        var calls=0,value=options();value.help=true
        XCTAssertNil(try BootstrapResourceCycle.output(for:value,run:{calls += 1;return self.report($0)}))
        value.help=false;value.report = .version
        XCTAssertNil(try BootstrapResourceCycle.output(for:value,run:{calls += 1;return self.report($0)}));XCTAssertEqual(calls,0)
    }
    func testInvalidBudgetOrNonFileRootRefusesBeforeProvider() {
        var calls=0,value=options();value.resourceCycleSeconds=5
        XCTAssertThrowsError(try BootstrapResourceCycle.output(for:value,run:{calls += 1;return self.report($0)}))
        value.resourceCycleSeconds=6;value.configurationDirectory=URL(string:"https://example.invalid/root")
        XCTAssertThrowsError(try BootstrapResourceCycle.output(for:value,run:{calls += 1;return self.report($0)}));XCTAssertEqual(calls,0)
    }
    func testUnavailableCancelledAndFailureReportsAreTruthful() throws {
        for reason:ResourceCycleReport.Termination in [.cancelled,.cleanupUnresolved] {
            let value=try XCTUnwrap(BootstrapResourceCycle.output(for:options(),run:{seconds in
                .init(requestedSeconds:seconds,provenance:.injected,observations:[.init(cycle:0,elapsed:0,snapshot:.init())],completed:[],termination:reason)
            }))
            XCTAssertTrue(value.text.contains("UNAVAILABLE"));XCTAssertEqual(value.exitCode,reason == .cancelled ? 3:1)
            XCTAssertTrue(value.text.contains(reason.rawValue))
        }
    }
    func testInvalidOrMismatchedReportCannotPrintPartial() {
        XCTAssertThrowsError(try BootstrapResourceCycle.output(for:options(),run:{_ in self.report(15)}))
        XCTAssertThrowsError(try BootstrapResourceCycle.output(for:options(),run:{seconds in .init(requestedSeconds:seconds,provenance:.notCollected,observations:[],completed:[],termination:.completed)}))
    }
    func testHelpDocumentsOnePerformanceModeAndBothBudgets() {
        let text=BootstrapReports.helpText
        XCTAssertEqual(text.components(separatedBy:"--perftest (").count-1,1)
        XCTAssertEqual(text.components(separatedBy:"--seconds ").count-1,1)
        XCTAssertTrue(text.contains("6..120"));XCTAssertTrue(text.contains("1..8"));XCTAssertTrue(text.contains("default 15"))
    }
    func testEarlierReportBoundaryDoesNotConstructUnrelatedProviders() throws {
        var calls=0
        XCTAssertNil(try BootstrapReports.output(for:options(),version:{calls += 1;return "unused"},profileTitles:{_ in calls += 1;return []},defaultProfiles:{calls += 1;return URL(fileURLWithPath:"/unused")},devices:{calls += 1;throw Failure.synthetic},nativeDevices:{calls += 1;throw Failure.synthetic}))
        XCTAssertEqual(calls,0)
    }
    private enum Failure:Error {case synthetic}
    func testPrivateScopePreservesMalformedSettingsWithoutReadingValues() throws {
        let base=URL(fileURLWithPath:ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]!).appendingPathComponent("perf-report-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(at:base)}
        let file=base.appendingPathComponent("settings.plist"),data=Data("private credential marker".utf8)
        try data.write(to:file);let before=try FileManager.default.attributesOfItem(atPath:file.path)
        var value=options();value.configurationDirectory=base
        let result=try XCTUnwrap(BootstrapResourceCycle.output(for:value,run:{self.report($0)}))
        XCTAssertFalse(result.text.contains("private credential marker"));XCTAssertFalse(result.text.contains(base.path))
        XCTAssertEqual(try Data(contentsOf:file),data)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:file.path)[.modificationDate] as? Date,before[.modificationDate] as? Date)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:base.path),["settings.plist"])
    }
}
