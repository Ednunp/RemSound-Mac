import Foundation
import XCTest
import RemSoundRuntime
import RemSoundCore
@testable import RemSoundApp

final class BootstrapControlSpecificationsTests: XCTestCase {
    private let stepName = "Every control is specified (no control escapes the suite)"
    func testOnlyExactNamedSelectionConsumesItsNativeProvider() throws {
        var calls = 0
        let options = try LaunchOptions.parse(["--selftest", "--pack", "feature", "--only", stepName])
        let output = try XCTUnwrap(BootstrapSelfCheck.output(for: options, nativeControlSpecifications: { calls += 1; return nil }))
        let report = try JSONDecoder().decode(ProductTestPack.Report.self, from: Data(output.text.utf8))
        XCTAssertEqual(calls, 1); XCTAssertEqual(report.selection, stepName)
        XCTAssertEqual(report.steps.first?.assertions, 0); XCTAssertEqual(report.steps.first?.status, "UNVERIFIED")
        XCTAssertEqual(output.exitCode, 1)
        let other = try LaunchOptions.parse(["--selftest", "--pack", "feature", "--only", ProductTestPack.knownAnswers])
        _ = try BootstrapSelfCheck.output(for: other, nativeControlSpecifications: { XCTFail("foreign fixture invoked"); return nil })
    }
    func testHelpAndUnsafeRootNeverInvokeNativeFactory() throws {
        let help = try LaunchOptions.parse(["--selftest", "--pack", "feature", "--help"])
        XCTAssertNil(try BootstrapSelfCheck.output(for: help, nativeControlSpecifications: { XCTFail("help invoked fixture"); return nil }))
        var options = try LaunchOptions.parse(["--selftest", "--pack", "feature", "--only", stepName])
        options.configurationDirectory = URL(fileURLWithPath: "/")
        XCTAssertThrowsError(try BootstrapSelfCheck.output(for: options, nativeControlSpecifications: { XCTFail("unsafe root invoked fixture"); return nil }))
    }
    func testLoggingPermissionCannotAuthorizeControlWindowConstruction() throws {
        let base = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])).appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("native")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        defer { try? FileManager.default.removeItem(at: base) }
        let old = ["REMSOUND_TEST_ROOT": base.path, "REMSOUND_TEST_NATIVE_PROFILE_LOGGING": "1"]
        XCTAssertFalse(BootstrapControlSpecifications.accepts(root: root, environment: old))
        let permitted = ["REMSOUND_TEST_ROOT": base.path, BootstrapControlSpecifications.permission: "1"]
        XCTAssertTrue(BootstrapControlSpecifications.accepts(root: root, environment: permitted))
        XCTAssertFalse(BootstrapControlSpecifications.accepts(root: base, environment: permitted))
        try Data([1]).write(to: root.appendingPathComponent("existing"))
        XCTAssertFalse(BootstrapControlSpecifications.accepts(root: root, environment: permitted))
    }
}
