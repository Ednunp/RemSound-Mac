import XCTest
@testable import RemSoundRuntime
final class ResourceCycleLaunchTests:XCTestCase {
    func testAliasesAndDefaultBudget() throws {
        for flag in ["--perftest","--perf-test"] {
            let value=try LaunchOptions.parse([flag]);XCTAssertEqual(value.report,.resourceCycle)
            XCTAssertEqual(value.resourceCycleSeconds,15)
        }
    }
    func testBudgetBeforeOrAfterModeIsApplied() throws {
        for args in [["--seconds","6","--perftest"],["--perf-test","--seconds","120"]] {
            let value=try LaunchOptions.parse(args);XCTAssertEqual(value.resourceCycleSeconds,Int(args.first=="--seconds" ? args[1]:args[2]))
        }
    }
    func testBadOrDuplicateBudgetAndMixedScopesRefuse() {
        for args in [["--perftest","--seconds","5"],["--perftest","--seconds","121"],["--perftest","--seconds","nan"],["--perftest","--seconds","6","--seconds","6"],["--perftest","--selftest"],["--selftest","--perftest"],["--perftest","--diag"],["--perftest","--profile","x"],["--perftest","--tray"],["--perftest","--log","off"],["--perftest","--headless"],["--perftest","--close"],["--perftest","--pack","audio"],["--seconds","6"]] {
            XCTAssertThrowsError(try LaunchOptions.parse(args),"\(args)")
        }
    }
    func testSelfCheckBudgetAndOldReportsStaySeparate() throws {
        XCTAssertEqual(try LaunchOptions.parse(["--selftest","--seconds","8"]).selfCheckSeconds,8)
        XCTAssertThrowsError(try LaunchOptions.parse(["--selftest","--seconds","9"]))
        XCTAssertEqual(try LaunchOptions.parse(["--version"]).report,.version)
        XCTAssertEqual(try LaunchOptions.parse(["--perftest","--silent"]).report,.resourceCycle)
    }
}
