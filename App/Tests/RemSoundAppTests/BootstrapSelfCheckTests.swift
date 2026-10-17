import Foundation
import RemSoundCore
import RemSoundRuntime
import XCTest
@testable import RemSoundApp

final class BootstrapSelfCheckTests: XCTestCase {
    private func passed() -> SelfCheckReport { .init(steps:SelfCheckReport.ID.allCases.map { .init(id:$0,status:.passed,assertions:1) },termination:.completed) }
    private func options() throws -> LaunchOptions { try LaunchOptions.parse(["--selftest","--silent"]) }
    func testUnrelatedModesAndHelpNeverConstructTheProvider() throws {
        for args in [[],["--version"],["--diag"],["--selftest","--help"]] {
            XCTAssertNil(try BootstrapSelfCheck.output(for:LaunchOptions.parse(args),run:{ _ in XCTFail("Constructed provider");return self.passed() }))
        }
    }
    func testPositiveReceiptsPrintNamedChecksAndExplicitPartialGaps() throws {
        var received:Double?
        let result=try XCTUnwrap(BootstrapSelfCheck.output(for:options(),run:{ received=$0;return self.passed() }))
        XCTAssertEqual(received,3);XCTAssertEqual(result.exitCode,3)
        XCTAssertTrue(result.text.contains("PARTIAL"));XCTAssertTrue(result.text.contains("5 passed, 0 failed, 0 not run"))
        for gap in SelfCheckReport.Unverified.allCases { XCTAssertTrue(result.text.contains("UNVERIFIED: "+gap.rawValue)) }
        XCTAssertEqual(result.text.components(separatedBy:"PASS: ").count-1,5)
        XCTAssertLessThan(result.text.utf8.count,16*1024)
    }
    func testFailedCheckAndUnrunDeadlineRemainFailures() throws {
        var steps=passed().steps;steps[0] = .init(id:.wire,status:.failed,assertions:0)
        let failed=try XCTUnwrap(BootstrapSelfCheck.output(for:options(),run:{ _ in .init(steps:steps,termination:.completed) }))
        XCTAssertEqual(failed.exitCode,1);XCTAssertTrue(failed.text.contains("FAIL: Packet framing and rejection"));XCTAssertTrue(failed.text.contains("RESULT: FAIL"))
        let absent=SelfCheckReport.ID.allCases.map { SelfCheckReport.Step(id:$0,status:.notRun,assertions:0) }
        let deadline=try XCTUnwrap(BootstrapSelfCheck.output(for:options(),run:{ _ in .init(steps:absent,termination:.deadline) }))
        XCTAssertEqual(deadline.exitCode,1);XCTAssertTrue(deadline.text.contains("deadline"));XCTAssertTrue(deadline.text.contains("0 passed, 0 failed, 5 not run"))
    }
    func testInvalidPublicReceiptsAreRefusedBeforeFormattingASuccess() throws {
        XCTAssertThrowsError(try BootstrapSelfCheck.output(for:options(),run:{ _ in .init(steps:[],termination:.completed) }))
        var steps=passed().steps;steps[0] = .init(id:.wire,status:.passed,assertions:0)
        XCTAssertThrowsError(try BootstrapSelfCheck.output(for:options(),run:{ _ in .init(steps:steps,termination:.completed) }))
    }
    func testUnsafePrivateScopeRefusesBeforeProviderAndNeverCreatesMissingRoot() throws {
        let base=URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.posixPermissions:0o755])
        defer { try? FileManager.default.removeItem(at:base) }
        let options=try LaunchOptions.parse(["--selftest","--config-dir",base.path])
        XCTAssertThrowsError(try BootstrapSelfCheck.output(for:options,run:{ _ in XCTFail("Constructed provider");return self.passed() }))
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:base.path)
        let missing=base.appendingPathComponent("missing")
        let result=try BootstrapSelfCheck.output(for:LaunchOptions.parse(["--selftest","--config-dir",missing.path]),run:{ _ in self.passed() })
        XCTAssertEqual(result?.exitCode,3);XCTAssertFalse(FileManager.default.fileExists(atPath:missing.path))
    }
    func testMutationOfBudgetCannotBypassTheNativeAdmissionBoundary() throws {
        var value=try options();value.selfCheckSeconds=9
        XCTAssertThrowsError(try BootstrapSelfCheck.output(for:value,run:{ _ in XCTFail("Constructed provider");return self.passed() }))
        value=try LaunchOptions.parse(["--selftest","--seconds","1"])
        var budget:Double?
        _=try BootstrapSelfCheck.output(for:value,run:{ budget=$0;return self.passed() })
        XCTAssertEqual(budget,1)
    }
    func testHelpNamesEachAcceptedCheckOptionOnceAndStatesPartialScope() {
        let text=BootstrapReports.helpText
        XCTAssertEqual(text.components(separatedBy:"--selftest (").count-1,1)
        XCTAssertEqual(text.components(separatedBy:"--seconds ").count-1,1)
        XCTAssertTrue(text.contains("PARTIAL exit 3"));XCTAssertTrue(text.contains("default 3"))
        XCTAssertTrue(text.contains("--perftest (--perf-test)"))
    }
}
