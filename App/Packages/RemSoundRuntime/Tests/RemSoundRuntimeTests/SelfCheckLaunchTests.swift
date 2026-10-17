import XCTest
@testable import RemSoundRuntime

final class SelfCheckLaunchTests: XCTestCase {
    func testAliasesSelectSelfCheckWithDefaultAndExplicitBudgets() throws {
        for flag in ["--selftest","--self-test","--smoke-test","--smoketest","--SELFTEST"] {
            XCTAssertEqual(try LaunchOptions.parse([flag]).report,.selfCheck)
            XCTAssertEqual(try LaunchOptions.parse([flag]).selfCheckSeconds,3)
            XCTAssertEqual(try LaunchOptions.parse(["--seconds","1",flag]).selfCheckSeconds,1)
            XCTAssertEqual(try LaunchOptions.parse([flag,"--seconds","8"]).selfCheckSeconds,8)
        }
    }
    func testInvalidDuplicateAndUnattachedDurationsOrUnsupportedFiltersRefuse() {
        for value in ["0","-1","9","30","NaN","1.5","99999999999999999999"] { XCTAssertThrowsError(try LaunchOptions.parse(["--selftest","--seconds",value])) }
        for args in [["--selftest","--seconds"],["--seconds","3"],["--selftest","--seconds","1","--seconds","2"],["--selftest","--self-test"],["--selftest","--pack","unsupported"],["--selftest","--only","wire"],["--selftest","--perftest"]] { XCTAssertThrowsError(try LaunchOptions.parse(args)) }
    }
    func testMixedModesAreRefusedInEitherOrder() {
        for mode in [["--version"],["--devices"],["--profiles"],["--diag"],["--log","off"],["--quit"],["--control","status"],["--headless"],["--check-accessibility"],["--profile","Studio"],["--connect","127.0.0.1:48000"],["--tray"]] {
            for args in [["--selftest"]+mode,mode+["--selftest"]] { XCTAssertThrowsError(try LaunchOptions.parse(args+["--config-dir","/private/selfcheck-fixture"],environment:["REMSOUND_ALLOW_VISIBLE_UI_TESTS":"1"])) }
        }
        XCTAssertThrowsError(try LaunchOptions.parse(["--version","--seconds","3"]))
    }
    func testHelpSilentAndPrivateScopeRemainPureLaunchValues() throws {
        let options=try LaunchOptions.parse(["--selftest","--seconds","2","--silent","--help","--config-dir","/private/selfcheck-fixture"])
        XCTAssertTrue(options.help);XCTAssertTrue(options.silent);XCTAssertEqual(options.selfCheckSeconds,2)
        XCTAssertEqual(options.configurationDirectory?.path,"/private/selfcheck-fixture")
        XCTAssertNil(try LaunchOptions.parse(["--version"]).diagnosticOutput)
    }
}
