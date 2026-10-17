import Foundation
import XCTest
import RemSoundRuntime
import RemSoundCore
@testable import RemSoundApp

final class BootstrapDialogAuditTests: XCTestCase {
    private let stepName = "Every window is reachable by the audits (no unaudited dialog)"
    func testOnlySelectedNamedDialogCallsProviderAndDoesNotPromoteControlSuite() throws {
        for (name, controls) in [(stepName, false), ("Dialog control suite (every dialog: names, mnemonics, tab order, theme, driven)", true)] {
            var calls = 0
            let options = try LaunchOptions.parse(["--selftest", "--pack", "feature", "--only", name])
            let output = try XCTUnwrap(BootstrapSelfCheck.output(for: options, nativeDialogs: { selected in
                calls += 1; XCTAssertEqual(selected, controls); return (40, [])
            }))
            let report = try JSONDecoder().decode(ProductTestPack.Report.self, from: Data(output.text.utf8))
            XCTAssertEqual(calls, 1); XCTAssertEqual(report.selection, name); XCTAssertEqual(report.steps.count, 1)
            XCTAssertEqual(report.steps[0].status, controls ? "UNVERIFIED" : "PASS")
            XCTAssertEqual(output.exitCode, controls ? 1 : 0)
        }
        let other = try LaunchOptions.parse(["--selftest", "--pack", "feature", "--only", ProductTestPack.knownAnswers])
        _ = try BootstrapSelfCheck.output(for: other, nativeDialogs: { _ in XCTFail("foreign fixture called"); return nil })
    }
    func testAbsentMalformedAndPrivateSourceRefusalsAreTruthful() throws {
        let options = try LaunchOptions.parse(["--selftest", "--pack", "feature", "--only", stepName])
        let receipts: [(assertions: Int, failures: [String])?] = [nil, (0, []), (1, ["/private/path"]), (1, ["dialogs.native.refused"])]
        for result in receipts {
            let output = try XCTUnwrap(BootstrapSelfCheck.output(for: options, nativeDialogs: { _ in result }))
            XCTAssertEqual(output.exitCode, 1)
            XCTAssertFalse(output.text.contains("/private/path"))
        }
        XCTAssertThrowsError(try BootstrapDialogAudit.sources(environment: [:]))
    }
    func testExistingLoggingPermissionCannotAuthorizeDialogOrExistingConfiguration() throws {
        let base = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])).appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("native")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertFalse(BootstrapDialogAudit.accepts(root: root, environment: ["REMSOUND_TEST_ROOT": base.path, "REMSOUND_TEST_NATIVE_PROFILE_LOGGING": "1"]))
        let permitted = ["REMSOUND_TEST_ROOT": base.path, BootstrapDialogAudit.permission: "1"]
        XCTAssertTrue(BootstrapDialogAudit.accepts(root: root, environment: permitted))
        XCTAssertFalse(BootstrapDialogAudit.accepts(root: base, environment: permitted))
        try Data([1]).write(to: root.appendingPathComponent("existing"))
        XCTAssertFalse(BootstrapDialogAudit.accepts(root: root, environment: permitted))
    }
    func testPrivateSourceSnapshotRejectsSymlinksAndPublicRoot() throws {
        let base = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])).appendingPathComponent(UUID().uuidString)
        let snapshot = base.appendingPathComponent("dialog-audit-source")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let env = ["REMSOUND_TEST_ROOT": base.path]
        let source = snapshot.appendingPathComponent("Current.swift")
        try Data("func build() { NSWindow() }".utf8).write(to: source)
        XCTAssertEqual(try BootstrapDialogAudit.sources(environment: env).count, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: snapshot.path)
        XCTAssertThrowsError(try BootstrapDialogAudit.sources(environment: env))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: snapshot.path)
        try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent("link.swift"), withDestinationURL: source)
        XCTAssertThrowsError(try BootstrapDialogAudit.sources(environment: env))
    }
}
