import XCTest
@testable import RemSoundRuntime

final class PluginToolLaunchTests: XCTestCase {
    func testFixedCommandsAndRemovalAliasAreParsedWithoutRuntimeConstruction() throws {
        XCTAssertEqual(try LaunchOptions.parse(["--install-plugin"]).pluginAction,.install)
        XCTAssertEqual(try LaunchOptions.parse(["--uninstall-plugin"]).pluginAction,.remove)
        XCTAssertEqual(try LaunchOptions.parse(["--remove-plugin","--config-dir","/owned-fixture"]).pluginAction,.remove)
    }
    func testPluginCommandsRejectMixedActionsAndCustomDestinations() {
        for args in [["--install-plugin","--remove-plugin"],["--install-plugin","/custom"],
            ["--install-plugin","--plugin-status"],["--remove-plugin","--selftest"],
            ["--install-plugin","--log","on"],["--install-plugin","--headless","--config-dir","/owned"],
            ["--install-plugin","--simulate","replay","--recording","/test"]] {
            XCTAssertThrowsError(try LaunchOptions.parse(args),"\(args)")
        }
    }
}
