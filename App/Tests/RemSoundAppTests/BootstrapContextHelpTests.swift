import Foundation
import XCTest
import RemSoundCore
import RemSoundRuntime
@testable import RemSoundApp

final class BootstrapContextHelpTests: XCTestCase {
    private let stepName = "GATE GUARD: every control, menu item and tab has context help, each in the manual once"
    func testOnlyExactNamedSelectionCallsHelpAndRetainsPendingCoverage() throws {
        let options = try LaunchOptions.parse(["--selftest", "--pack", "feature", "--only", stepName])
        var calls = 0
        let output = try XCTUnwrap(BootstrapSelfCheck.output(for: options, nativeContextHelp: { calls += 1; return (20, []) }))
        let report = try JSONDecoder().decode(ProductTestPack.Report.self, from: Data(output.text.utf8))
        XCTAssertEqual(calls, 1); XCTAssertEqual(report.selection, stepName)
        XCTAssertEqual(report.steps.first?.assertions, 20); XCTAssertEqual(report.steps.first?.status, "UNVERIFIED")
        XCTAssertEqual(output.exitCode, 1)
        let other = try LaunchOptions.parse(["--selftest", "--pack", "feature", "--only", ProductTestPack.knownAnswers])
        _ = try BootstrapSelfCheck.output(for: other, nativeContextHelp: { XCTFail("Unselected native help"); return nil })
    }
    func testHelpAndUnsafeRootRefuseBeforeNativeManualOrWindowFactories() throws {
        let help = try LaunchOptions.parse(["--selftest", "--pack", "feature", "--help"])
        XCTAssertNil(try BootstrapSelfCheck.output(for: help, nativeContextHelp: { XCTFail("Help invoked a factory"); return nil }))
        var options = try LaunchOptions.parse(["--selftest", "--pack", "feature", "--only", stepName])
        options.configurationDirectory = URL(fileURLWithPath: "/")
        XCTAssertThrowsError(try BootstrapSelfCheck.output(for: options, nativeContextHelp: { XCTFail("Unsafe scope"); return nil }))
    }
    func testOtherNativePermissionCannotAdmitContextHelp() throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let options = try LaunchOptions.parse(["--selftest", "--pack", "feature", "--only", stepName, "--config-dir", root.path])
        XCTAssertNil(BootstrapContextHelp.run(for: options))
        XCTAssertNil(AppRuntime.configuration)
    }
}
