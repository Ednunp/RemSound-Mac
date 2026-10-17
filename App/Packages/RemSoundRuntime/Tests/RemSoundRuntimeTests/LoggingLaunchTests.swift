import Foundation
import XCTest
@testable import RemSoundRuntime

final class LoggingLaunchTests: XCTestCase {
    func testLoggingAliasesHaveOnePureChoiceAndNoStartupOrClient() throws {
        for word in ["on", "true", "1", "enable", "enabled", "yes", "ON"] {
            let options = try LaunchOptions.parse(["--log", word])
            XCTAssertEqual(options.diagnosticLoggingEnabled, true)
            XCTAssertNil(options.controlRequest);XCTAssertNil(options.report)
        }
        for word in ["off", "false", "0", "disable", "disabled", "no", "OFF"] {
            XCTAssertEqual(try LaunchOptions.parse(["--LOG", word]).diagnosticLoggingEnabled, false)
        }
    }
    func testLoggingRejectsMissingInvalidDuplicateAndMixedModes() {
        for args in [["--log"], ["--log", "maybe"], ["--log", " on"], ["--log", "off", "--log", "on"]] {
            XCTAssertThrowsError(try LaunchOptions.parse(args))
        }
        for mode in [["--version"], ["--devices"], ["--profiles"], ["--close"], ["--control", "status"], ["--headless"], ["--check-accessibility"], ["--profile", "Studio"], ["--connect", "127.0.0.1:47831"], ["--tray"], ["--value", "off"]] {
            for args in [["--log", "off"] + mode, mode + ["--log", "off"]] {
                XCTAssertThrowsError(try LaunchOptions.parse(args + ["--config-dir", "/private/log-fixture"], environment: ["REMSOUND_ALLOW_VISIBLE_UI_TESTS":"1"]))
            }
        }
    }
    func testLoggingKeepsHelpAndExplicitPrivateRoot() throws {
        let options = try LaunchOptions.parse(["--log", "off", "--silent", "--config-dir", "/private/log-fixture"])
        XCTAssertEqual(options.diagnosticLoggingEnabled, false)
        XCTAssertEqual(options.configurationDirectory?.path, "/private/log-fixture")
        XCTAssertTrue(options.silent)
        XCTAssertTrue(try LaunchOptions.parse(["--log", "off", "--help"]).help)
        XCTAssertNil(try LaunchOptions.parse(["--version"]).diagnosticLoggingEnabled)
    }
}

final class DiagnosticLoggingPreferencesTests: XCTestCase {
    private func root() throws -> URL {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let root = URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return root
    }
    func testDefaultAndMalformedValuesAreNotMigratedOrCoerced() throws {
        let root = try root(), file = root.appendingPathComponent("settings.plist"), store = try SettingsStore(file:file)
        XCTAssertTrue(DiagnosticLoggingPreferences.enabled(in:store))
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
        for value in ["false", 0, 1, Data([1]), ["other"]] as [Any] {
            XCTAssertTrue(store.setValues(["RemSoundDiagnosticLoggingEnabled":value]))
            let before = try Data(contentsOf:file)
            XCTAssertTrue(DiagnosticLoggingPreferences.enabled(in:store))
            XCTAssertEqual(try Data(contentsOf:file),before)
        }
    }
    func testExplicitWritesRoundTripOnlyMachineChoiceAndPreserveOtherValues() throws {
        let file = try root().appendingPathComponent("settings.plist"), store = try SettingsStore(file:file)
        XCTAssertTrue(store.setValues(["other":"preserved", "profileMarker":Data([3,4])]))
        XCTAssertTrue(DiagnosticLoggingPreferences.setEnabled(false,in:store))
        let reopened = try SettingsStore(file:file)
        XCTAssertFalse(DiagnosticLoggingPreferences.enabled(in:reopened))
        XCTAssertEqual(reopened.string(forKey:"other"),"preserved")
        XCTAssertEqual(reopened.data(forKey:"profileMarker"),Data([3,4]))
        XCTAssertTrue(DiagnosticLoggingPreferences.setEnabled(true,in:reopened))
        XCTAssertTrue(DiagnosticLoggingPreferences.enabled(in:try SettingsStore(file:file)))
    }
    func testFailedSaveRetainsPriorChoiceWithoutFallback() throws {
        let file = try root().appendingPathComponent("settings.plist"), store = try SettingsStore(file:file)
        XCTAssertTrue(DiagnosticLoggingPreferences.setEnabled(false,in:store))
        try FileManager.default.removeItem(at:file)
        try FileManager.default.createDirectory(at:file,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        XCTAssertFalse(DiagnosticLoggingPreferences.setEnabled(true,in:store))
        XCTAssertFalse(DiagnosticLoggingPreferences.enabled(in:store))
        XCTAssertTrue(store.persistenceFailed)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:file.path).isEmpty)
    }
}
