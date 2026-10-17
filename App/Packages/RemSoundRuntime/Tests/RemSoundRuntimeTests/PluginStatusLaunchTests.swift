import XCTest
@testable import RemSoundRuntime

final class PluginStatusLaunchTests: XCTestCase {
    func testPluginStatusIsAnExplicitReadOnlyReport() throws {
        for flag in ["--plugin-status","--PLUGIN-STATUS"] {
            let options=try LaunchOptions.parse([flag,"--config-dir","/owned/plugin-fixture"])
            XCTAssertNotNil(options.report)
            XCTAssertNil(options.controlRequest)
        }
    }
    func testPluginStatusRefusesMixedMutationRuntimeAndOtherReportOptions() {
        for other in [["--version"],["--list-profiles"],["--headless"],["--control","stop"],["--profile","Studio"],["--log","on"],["--seconds","1"],["--pack","full"],["--plugin-status"]] {
            XCTAssertThrowsError(try LaunchOptions.parse(["--plugin-status","--config-dir","/owned/plugin-fixture"]+other))
        }
    }
}
