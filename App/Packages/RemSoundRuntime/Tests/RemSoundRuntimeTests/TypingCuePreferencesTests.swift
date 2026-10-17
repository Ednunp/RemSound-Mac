import Foundation
import XCTest
@testable import RemSoundRuntime

final class TypingCuePreferencesTests: XCTestCase {
    private func store() throws -> SettingsStore {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("typing-policy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try SettingsStore(file: root.appendingPathComponent("settings.plist"))
    }

    func testDefaultEnabledAndTypingIsOutsideBothCueLists() throws {
        let cues = CuePreferences(settings: try store())
        XCTAssertTrue(cues.keyboardClicksEnabled)
        XCTAssertTrue(cues.automaticKeyboardClicksEnabled)
        XCTAssertFalse(CueEvent.allCases.contains { $0.rawValue.lowercased().contains("key") })
    }

    func testExplicitProfilesSwitchImmediatelyWithoutChangingGlobals() throws {
        let cues = CuePreferences(settings: try store())
        let globals = cues.globalConfigurations
        cues.loadProfile([:], keyboardClicks: false)
        XCTAssertFalse(cues.keyboardClicksEnabled)
        cues.loadProfile([:], keyboardClicks: true)
        XCTAssertTrue(cues.keyboardClicksEnabled)
        cues.loadProfile([:], keyboardClicks: false)
        XCTAssertFalse(cues.keyboardClicksEnabled)
        XCTAssertEqual(cues.globalConfigurations, globals)
    }

    func testUnsavedTypingChoiceSurvivesPreferencesRestartAndDoesNotTouchLegacy() throws {
        let settings = try store()
        let cues = CuePreferences(settings: settings)
        cues.setKeyboardClicksEnabled(false)
        XCTAssertFalse(CuePreferences(settings: settings).keyboardClicksEnabled)
        XCTAssertNil(settings.object(forKey: "enableKeyboardClicks"))
        let data = try XCTUnwrap(settings.data(forKey: "activeProfileAudioCuesV2"))
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(snapshot["keyboardClicks"] as? Bool, false)
        XCTAssertEqual(snapshot["version"] as? Int, 2)
    }

    func testMuteSilencesTypingWithoutOverwritingTheProfileAndHasNoPreviewException() throws {
        let cues = CuePreferences(settings: try store())
        cues.setMuteAllCues(true)
        XCTAssertTrue(cues.keyboardClicksEnabled)
        XCTAssertFalse(cues.automaticKeyboardClicksEnabled)
        cues.setMuteAllCues(false)
        XCTAssertTrue(cues.automaticKeyboardClicksEnabled)
        cues.setKeyboardClicksEnabled(false)
        cues.setMuteAllCues(true); cues.setMuteAllCues(false)
        XCTAssertFalse(cues.automaticKeyboardClicksEnabled)
    }

    func testFrozenLegacyOffIsTheSameForEveryOlderProfileAfterOtherEdits() throws {
        let settings = try store()
        settings.set(false, forKey: "enableKeyboardClicks")
        let cues = CuePreferences(settings: settings)
        cues.loadProfile(nil)
        XCTAssertFalse(cues.keyboardClicksEnabled)
        cues.setKeyboardClicksEnabled(true)
        settings.set(true, forKey: "enableKeyboardClicks")
        let reopened = CuePreferences(settings: settings)
        reopened.loadProfile(nil)
        XCTAssertFalse(reopened.keyboardClicksEnabled)
        reopened.loadProfile([:], schemaVersion: 2)
        XCTAssertFalse(reopened.keyboardClicksEnabled, "Pre-typing Mac profiles also inherit the frozen legacy default")
    }

    func testOldCachedProfileWithoutTypingFieldKeepsItsOtherCues() throws {
        let settings = try store()
        let legacy: [String: Any] = ["version": 2, "configurations": ["connect": ["enabled": false]]]
        settings.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "activeProfileAudioCuesV2")
        let cues = CuePreferences(settings: settings)
        XCTAssertTrue(cues.keyboardClicksEnabled)
        XCTAssertFalse(cues.configuration(for: .connect).enabled)
        cues.setKeyboardClicksEnabled(false)
        let reopened = CuePreferences(settings: settings)
        XCTAssertFalse(reopened.keyboardClicksEnabled)
        XCTAssertFalse(reopened.configuration(for: .connect).enabled)
    }

    func testMissingOrInvalidLegacyDefaultRemainsEnabled() throws {
        let settings = try store()
        settings.set("damaged", forKey: "enableKeyboardClicks")
        let cues = CuePreferences(settings: settings)
        cues.loadProfile(nil)
        XCTAssertTrue(cues.keyboardClicksEnabled)
        XCTAssertEqual(settings.object(forKey: "legacyKeyboardClicksV1") as? Bool, true)
    }
}
