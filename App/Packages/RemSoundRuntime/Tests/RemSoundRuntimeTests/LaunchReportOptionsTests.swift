import Foundation
import XCTest
@testable import RemSoundRuntime

final class LaunchReportOptionsTests: XCTestCase {
    func testVersionAndProfileAliasesAreCaseInsensitive() throws {
        for flag in ["--version", "-v", "--ver", "--VERSION"] { XCTAssertEqual(try LaunchOptions.parse([flag]).report, .version) }
        for flag in ["--list-profiles", "--profiles", "--LIST-PROFILES"] { XCTAssertEqual(try LaunchOptions.parse([flag]).report, .profiles) }
    }
    func testReportDoesNotNeedOrCreateConfiguration() throws {
        let options = try LaunchOptions.parse(["--list-profiles", "--config-dir", "/private/missing-report-root", "--silent"])
        XCTAssertEqual(options.report, .profiles); XCTAssertEqual(options.configurationDirectory?.path, "/private/missing-report-root")
    }
    func testConflictingReportsAndControlOrInteractiveChecksFailClosed() {
        for flags in [["--version", "--list-profiles"], ["--version", "--version"], ["--profiles", "--headless"],
            ["--version", "--control", "status", "--config-dir", "/private/test"], ["--profiles", "--check-accessibility", "--config-dir", "/private/test"],
            ["--version", "--value", "password"], ["--version", "--unknown"]] {
            XCTAssertThrowsError(try LaunchOptions.parse(flags, environment: ["REMSOUND_ALLOW_VISIBLE_UI_TESTS":"1"]))
        }
    }
    func testHelpAndExistingIsolationRemainCompatible() throws {
        XCTAssertTrue(try LaunchOptions.parse(["--help"]).help)
        XCTAssertTrue(try LaunchOptions.parse(["--version", "--help"]).help)
        XCTAssertThrowsError(try LaunchOptions.parse(["--headless"]))
        XCTAssertThrowsError(try LaunchOptions.parse(["--control", "status"]))
        XCTAssertNil(try LaunchOptions.parse(["-psn_0_123"]).report)
        XCTAssertNil(try LaunchOptions.parse(["--silent"]).report)
    }
}
