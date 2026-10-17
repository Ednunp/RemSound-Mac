import Foundation
import XCTest
@testable import RemSoundRuntime

final class DiagnosticLaunchTests: XCTestCase {
    func testAliasesSelectDiagnosticsAndOptionalAbsoluteDestination() throws {
        for flag in ["--diagnostics","--diag","--DIAG"] {
            let options=try LaunchOptions.parse([flag,"--config-dir","/private/diagnostic-fixture"])
            XCTAssertEqual(options.report,.diagnostics);XCTAssertNil(options.diagnosticOutput)
            XCTAssertEqual(try LaunchOptions.parse([flag,"/private/report.txt"]).diagnosticOutput?.path,"/private/report.txt")
        }
    }
    func testInvalidDestinationsAndMixedModesAreRefusedBeforeAnyFactory() {
        for args in [["--diag","relative"],["--diag","/"],["--diag","/private/folder/"],["--diag","/private/null\0name"]] {
            XCTAssertThrowsError(try LaunchOptions.parse(args))
        }
        for mode in [["--version"],["--devices"],["--profiles"],["--diag"],["--log","off"],["--close"],["--control","status"],["--headless"],["--check-accessibility"],["--profile","Studio"],["--connect","127.0.0.1:47831"],["--tray"]] {
            for args in [["--diag"]+mode,mode+["--diag"]] { XCTAssertThrowsError(try LaunchOptions.parse(args+["--config-dir","/private/diagnostic-fixture"],environment:["REMSOUND_ALLOW_VISIBLE_UI_TESTS":"1"])) }
        }
    }
    func testHelpAndExistingReportsRemainPure() throws {
        XCTAssertTrue(try LaunchOptions.parse(["--diag","--help"]).help)
        XCTAssertNil(try LaunchOptions.parse(["--version"]).diagnosticOutput)
        XCTAssertEqual(try LaunchOptions.parse(["--diag","--silent"]).report,.diagnostics)
    }
}
