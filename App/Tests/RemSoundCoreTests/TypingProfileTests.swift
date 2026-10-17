import Foundation
import RemSoundRuntime
import XCTest
@testable import RemSoundCore

final class TypingProfileTests: XCTestCase {
    private func profile() -> ConnectionProfile {
        ConnectionProfile(title: "Typing test", displayName: "Test", manualPeerAddress: "",
            selectedPeerAddresses: [], sendInput: false, receiveAudio: false,
            allowPlugins: false, reconnectOnOpen: false)
    }

    func testNewProfileEnablesTypingAndSavedChoicesRoundTrip() throws {
        var value = profile()
        XCTAssertEqual(value.keyboardClicks, true)
        for enabled in [false, true] {
            value.keyboardClicks = enabled
            let restored = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(value))
            XCTAssertEqual(restored.keyboardClicks, enabled)
            XCTAssertEqual(restored, value)
        }
    }

    func testMissingAndNullTypingRemainLegacyWithoutLosingExistingCueSelections() throws {
        var value = profile()
        value.audioCues = ["connect": CueConfiguration(enabled: false)]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        for absent in [true, false] {
            if absent { object.removeValue(forKey: "keyboardClicks") }
            else { object["keyboardClicks"] = NSNull() }
            let restored = try JSONDecoder().decode(ConnectionProfile.self,
                from: JSONSerialization.data(withJSONObject: object))
            XCTAssertNil(restored.keyboardClicks)
            XCTAssertEqual(restored.audioCues, value.audioCues)
        }
        object["keyboardClicks"] = "false"
        XCTAssertThrowsError(try JSONDecoder().decode(ConnectionProfile.self,
            from: JSONSerialization.data(withJSONObject: object)))
    }

    func testTypingChoiceMakesProfileDirtyButMuteRemainsOutsideProfileJSON() throws {
        var value = profile()
        var changed = value
        changed.keyboardClicks = false
        XCTAssertNotEqual(changed, value)
        value.keyboardClicks = false
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        XCTAssertEqual(object["keyboardClicks"] as? Bool, false)
        XCTAssertNil(object["muteAllCues"])
    }

    func testSavedProfileTypingDoesNotChangeUntilExplicitSaveAndCopyKeepsChoice() throws {
        let directory = try IsolatedTestDirectory.root().appendingPathComponent("typing-profile-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        var value = profile()
        value.keyboardClicks = true
        try store.save(value)
        value.keyboardClicks = false
        XCTAssertEqual(try store.load(id: value.id).keyboardClicks, true)
        try store.save(value)
        XCTAssertEqual(try store.load(id: value.id).keyboardClicks, false)
        value.title = "Copy"
        let copied = ConnectionProfile(id: UUID(), title: value.title, displayName: value.displayName,
            manualPeerAddress: value.manualPeerAddress, selectedPeerAddresses: [], sendInput: false,
            receiveAudio: false, allowPlugins: false, reconnectOnOpen: false)
        var withChoice = copied
        withChoice.keyboardClicks = value.keyboardClicks
        try store.save(withChoice)
        XCTAssertEqual(try store.load(id: withChoice.id).keyboardClicks, false)
    }

    func testLegacyProfileUsesFrozenTypingDefaultEvenAfterOtherProfilesAreEdited() throws {
        let directory = try IsolatedTestDirectory.root().appendingPathComponent("typing-migration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try SettingsStore(file: directory.appendingPathComponent("settings.plist"))
        settings.set(false, forKey: "enableKeyboardClicks")
        let cues = CuePreferences(settings: settings)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile())) as? [String: Any])
        object.removeValue(forKey: "keyboardClicks")
        let legacy = try JSONDecoder().decode(ConnectionProfile.self,
            from: JSONSerialization.data(withJSONObject: object))
        cues.loadProfile(legacy.audioCues, schemaVersion: legacy.audioCueSchemaVersion,
            keyboardClicks: legacy.keyboardClicks)
        XCTAssertFalse(cues.keyboardClicksEnabled)
        cues.setKeyboardClicksEnabled(true)
        settings.set(true, forKey: "enableKeyboardClicks")
        let restarted = CuePreferences(settings: settings)
        XCTAssertTrue(restarted.keyboardClicksEnabled, "Last unsaved choice survives a restart")
        restarted.loadProfile(legacy.audioCues, schemaVersion: legacy.audioCueSchemaVersion,
            keyboardClicks: legacy.keyboardClicks)
        XCTAssertFalse(restarted.keyboardClicksEnabled, "Every older profile uses the same upgrade-time choice")
        var migrated = legacy
        migrated.keyboardClicks = restarted.keyboardClicksEnabled
        XCTAssertEqual(try JSONDecoder().decode(ConnectionProfile.self,
            from: JSONEncoder().encode(migrated)).keyboardClicks, false)
    }

    func testNewProfileConstructorAcceptsInheritedTypingChoice() throws {
        for enabled in [false, true] {
            let value = ConnectionProfile(title: "Inherited", displayName: "Test", manualPeerAddress: "",
                selectedPeerAddresses: [], sendInput: false, receiveAudio: false,
                allowPlugins: false, reconnectOnOpen: false, keyboardClicks: enabled)
            XCTAssertEqual(value.keyboardClicks, enabled)
            XCTAssertEqual(try JSONDecoder().decode(ConnectionProfile.self,
                from: JSONEncoder().encode(value)), value)
        }
    }
}
