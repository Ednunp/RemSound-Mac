import Foundation
import XCTest
@testable import RemSoundRuntime

final class LoggingCommandStoreTests: XCTestCase {
    private func root() throws -> URL {
        URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])).appendingPathComponent(UUID().uuidString)
    }
    func testStandaloneStoreCreatesOnlyPrivateRootAndExistingSettingsBook() throws {
        let root = try root();defer { try? FileManager.default.removeItem(at:root) }
        let store = try RuntimeConfiguration.settingsForStandaloneCommand(root:root)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
        XCTAssertTrue(DiagnosticLoggingPreferences.setEnabled(false,in:store))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),["settings.plist"])
        XCTAssertFalse(DiagnosticLoggingPreferences.enabled(in:try RuntimeConfiguration.settingsForStandaloneCommand(root:root)))
    }
    func testStandaloneStoreRefusesUnsafeAncestorNonFileURLAndLiveChannel() throws {
        let root = try root();defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o755])
        XCTAssertThrowsError(try RuntimeConfiguration.settingsForStandaloneCommand(root:root))
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path)
        let channel=root.appendingPathComponent("control.sock");try Data("occupied marker".utf8).write(to:channel)
        XCTAssertThrowsError(try RuntimeConfiguration.settingsForStandaloneCommand(root:root))
        XCTAssertEqual(try Data(contentsOf:channel),Data("occupied marker".utf8))
        try FileManager.default.removeItem(at:channel)
        let link=root.appendingPathComponent("link");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:root)
        XCTAssertThrowsError(try RuntimeConfiguration.settingsForStandaloneCommand(root:link.appendingPathComponent("new")))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("new").path))
        XCTAssertThrowsError(try RuntimeConfiguration.settingsForStandaloneCommand(root:URL(string:"https://invalid.test/logs")!))
    }
    func testUnreadableBookRemainsExactWithoutFallback() throws {
        let root = try root();defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file=root.appendingPathComponent("settings.plist");try Data("malformed preserved".utf8).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        XCTAssertThrowsError(try RuntimeConfiguration.settingsForStandaloneCommand(root:root))
        XCTAssertEqual(try Data(contentsOf:file),Data("malformed preserved".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),["settings.plist"])
    }
    func testRuntimeSnapshotChangesOnlyOnNewLaunchWithoutWritingDefault() throws {
        let root = try root();defer { try? FileManager.default.removeItem(at:root) }
        let options=try LaunchOptions.parse(["--config-dir",root.path]);let original=try RuntimeConfiguration(options:options)
        XCTAssertTrue(original.diagnosticLoggingEnabled)
        XCTAssertNil(original.settings.object(forKey:"RemSoundDiagnosticLoggingEnabled"))
        XCTAssertTrue(DiagnosticLoggingPreferences.setEnabled(false,in:original.settings))
        XCTAssertTrue(original.diagnosticLoggingEnabled)
        XCTAssertFalse(try RuntimeConfiguration(options:options).diagnosticLoggingEnabled)
    }
}
