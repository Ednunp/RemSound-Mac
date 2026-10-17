import Foundation
import XCTest
import RemSoundRuntime
import RemSoundCore
@testable import RemSoundApp

final class BootstrapProductPackTests: XCTestCase {
    func testLatencyProductCLIExposesExecutedPartialChecksAndStillFailsAcceptance() throws {
        for name in ["Latency estimate counts every stage (no silently-missing term)",
            "CAPTURE DELAY PER LANE: each lane's format says its own capture, and the far end's readout counts the right one per output",
            "PEER LATENCY: each connected peer's total latency beside its ping in the status, from its own stream, in all three configurations"] {
            let result=try XCTUnwrap(BootstrapSelfCheck.output(for:LaunchOptions.parse([
                "--selftest","--pack","feature","--only",name])))
            let report=try JSONDecoder().decode(ProductTestPack.Report.self,from:Data(result.text.utf8))
            XCTAssertEqual(report.steps.count,1);XCTAssertEqual(report.steps.first?.status,"UNVERIFIED")
            XCTAssertGreaterThan(report.steps.first?.assertions ?? 0,10)
            XCTAssertEqual(result.exitCode,1)
        }
    }
    func testActualPCMAndRingCLISelectionsPassWithoutClaimingFullPack() throws {
        for (name,status,exit) in [(ProductTestPack.pcm24,"PASS",0),
            (ProductTestPack.ringIntegrity,"PASS",0)] {
            let result=try XCTUnwrap(BootstrapSelfCheck.output(for:LaunchOptions.parse([
                "--selftest","--pack","feature","--only",name])))
            let report=try JSONDecoder().decode(ProductTestPack.Report.self,from:Data(result.text.utf8))
            XCTAssertEqual(report.steps.count,1);XCTAssertEqual(report.steps.first?.name,name)
            XCTAssertEqual(report.steps.first?.status,status)
            XCTAssertGreaterThan(report.steps.first?.assertions ?? 0,15)
            XCTAssertEqual(result.exitCode,exit)
        }
    }
    func testActualNamedPackCLIProducesStructuredKnownAnswerPassWithRealAssertions() throws {
        let options=try LaunchOptions.parse(["--selftest","--pack","feature","--only",ProductTestPack.knownAnswers])
        let result=try XCTUnwrap(BootstrapSelfCheck.output(for:options))
        let report=try JSONDecoder().decode(ProductTestPack.Report.self,from:Data(result.text.utf8))
        XCTAssertEqual(report.steps.count,1);XCTAssertEqual(report.steps.first?.status,"PASS")
        XCTAssertGreaterThan(report.steps.first?.assertions ?? 0,14)
        XCTAssertEqual(result.exitCode,0)
    }
    func testAllStepsRemainVisibleThroughFullPackAndHelpDoesNotRun() throws {
        let result=try XCTUnwrap(BootstrapSelfCheck.output(for:LaunchOptions.parse(["--selftest","--pack","full","--seconds","8"])))
        let report=try JSONDecoder().decode(ProductTestPack.Report.self,from:Data(result.text.utf8))
        XCTAssertEqual(report.catalogSteps,545)
        XCTAssertFalse(report.steps.isEmpty)
        XCTAssertEqual(report.steps.map(\.name),Array(ProductTestPack.names.prefix(report.steps.count)))
        XCTAssertTrue(["completed","deadline"].contains(report.termination))
        XCTAssertEqual(result.exitCode,1)
        XCTAssertNil(try BootstrapSelfCheck.output(for:LaunchOptions.parse(["--selftest","--pack","feature","--help"])))
        XCTAssertTrue(BootstrapReports.helpText.contains("--pack full|feature"))
    }
    func testMutatedPackAndUnsafeScopeRefuseWithoutLegacyProviderFallback() throws {
        var options=try LaunchOptions.parse(["--selftest","--pack","full"])
        options.selfTestPack="unsupported"
        XCTAssertThrowsError(try BootstrapSelfCheck.output(for:options,run:{ _ in XCTFail("legacy fallback");return ProductSelfCheck.run(budget:1) }))
        options.selfTestPack="full";options.configurationDirectory=URL(fileURLWithPath:"/")
        XCTAssertThrowsError(try BootstrapSelfCheck.output(for:options,run:{ _ in XCTFail("legacy fallback");return ProductSelfCheck.run(budget:1) }))
    }
}
