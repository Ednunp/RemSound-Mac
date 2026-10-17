import Foundation
import XCTest
import RemSoundRuntime
import RemSoundCore
@testable import RemSoundApp

final class BootstrapEventClaimsTests: XCTestCase {
    private let stepName = "Every wired event is claimed (no handler escapes the suites)"
    func testOnlyExactSelectionConsumesTheNativeEventProvider() throws {
        var calls = 0
        let options = try LaunchOptions.parse(["--selftest", "--pack", "feature", "--only", stepName])
        let output = try XCTUnwrap(BootstrapSelfCheck.output(for: options, nativeEventClaims: { calls += 1; return nil }))
        let report = try JSONDecoder().decode(ProductTestPack.Report.self, from: Data(output.text.utf8))
        XCTAssertEqual(calls, 1); XCTAssertEqual(report.selection, stepName); XCTAssertEqual(report.steps[0].assertions, 0)
        XCTAssertEqual(report.steps[0].status, "UNVERIFIED"); XCTAssertEqual(output.exitCode, 1)
        let other = try LaunchOptions.parse(["--selftest", "--pack", "feature", "--only", ProductTestPack.knownAnswers])
        _ = try BootstrapSelfCheck.output(for: other, nativeEventClaims: { XCTFail("foreign fixture called"); return nil })
    }
    func testPendingDriverCannotHideARealFailureOrMalformedReceipt() throws {
        let options = try LaunchOptions.parse(["--selftest", "--pack", "feature", "--only", stepName])
        for (failures, status) in [(["events.native.unverified-driver-Window"], "UNVERIFIED"),
            (["events.native.unverified-driver-Window", "events.native.count-drift-Window"], "FAIL"), (["/private/path"], "FAIL")] {
            let output = try XCTUnwrap(BootstrapSelfCheck.output(for: options, nativeEventClaims: { (20, failures) }))
            let report = try JSONDecoder().decode(ProductTestPack.Report.self, from: Data(output.text.utf8))
            XCTAssertEqual(report.steps[0].status, status); XCTAssertEqual(output.exitCode, 1)
            XCTAssertFalse(output.text.contains("/private/path"))
        }
    }
    func testSourceGuardRequiresItsOwnPermissionAndEmptyPrivateRoot() throws {
        let base = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])).appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertFalse(BootstrapEventClaims.accepts(root: root, environment: ["REMSOUND_TEST_ROOT": base.path, "REMSOUND_TEST_NATIVE_DIALOGS": "1"]))
        let allowed = ["REMSOUND_TEST_ROOT": base.path, BootstrapEventClaims.permission: "1"]
        XCTAssertTrue(BootstrapEventClaims.accepts(root: root, environment: allowed))
        try Data([1]).write(to: root.appendingPathComponent("existing"))
        XCTAssertFalse(BootstrapEventClaims.accepts(root: root, environment: allowed))
    }
    func testNativeSourceSnapshotOptInDoesNotWidenTheDialogReader() throws {
        let base = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])).appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("dialog-audit-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("void begin() { help.onClick = [] {}; }".utf8).write(to: source.appendingPathComponent("Editor.cpp"))
        let environment = ["REMSOUND_TEST_ROOT": base.path]
        XCTAssertThrowsError(try BootstrapDialogAudit.sources(environment: environment))
        XCTAssertEqual(try BootstrapDialogAudit.sources(environment: environment, includeNativeSources: true).count, 1)
    }
}
