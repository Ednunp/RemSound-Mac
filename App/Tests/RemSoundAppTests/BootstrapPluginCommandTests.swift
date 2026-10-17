import Foundation
import XCTest
import RemSoundRuntime
@testable import RemSoundApp

final class BootstrapPluginCommandTests: XCTestCase {
    func testNormalInstallerRefusalIsStructuredAndCannotFallThroughToApp() throws {
        let options = try LaunchOptions.parse(["--install-plugin"])
        let output = try XCTUnwrap(BootstrapPluginCommand.output(for: options))
        XCTAssertEqual(output.exitCode,1)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.text.utf8)) as? [String:Any])
        XCTAssertEqual(value["status"] as? String,"unsupported")
        XCTAssertEqual(value["scope"] as? String,"user")
        XCTAssertEqual(value["nativeActivationVerified"] as? Bool,false)
        XCTAssertNotNil(value["generatedUTC"]); XCTAssertLessThan(output.text.utf8.count,16*1024)
        XCTAssertFalse(output.text.contains(NSHomeDirectory()))
    }
    func testOtherLaunchesDoNotInvokePluginCommand() throws {
        XCTAssertNil(try BootstrapPluginCommand.output(for: LaunchOptions.parse(["--version"])))
        XCTAssertNil(try BootstrapPluginCommand.output(for: LaunchOptions.parse([])))
    }
    func testIsolatedMissingRootIsRefusedAndNotCreatedOrReplacedByNormalLocation() throws {
        let base = URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]))
        let root = base.appendingPathComponent("plugin-missing-"+UUID().uuidString)
        let options = try LaunchOptions.parse(["--remove-plugin","--config-dir",root.path])
        let output = try XCTUnwrap(BootstrapPluginCommand.output(for:options))
        XCTAssertEqual(output.exitCode,1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.path))
        XCTAssertTrue(output.text.contains("refused")); XCTAssertTrue(output.text.contains("isolated"))
    }
}
