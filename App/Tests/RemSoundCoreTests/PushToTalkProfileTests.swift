import Foundation
import XCTest
import RemSoundJam
import RemSoundRuntime
@testable import RemSoundCore

final class PushToTalkProfileTests: XCTestCase {
    private func profile(_ ptt: PushToTalkSettings = .init(), title: String = "PTT") -> ConnectionProfile {
        ConnectionProfile(title: title, displayName: "Test", manualPeerAddress: "",
            selectedPeerAddresses: [], sendInput: false, receiveAudio: false,
            allowPlugins: false, reconnectOnOpen: false, pushToTalk: ptt)
    }
    private func customized() -> PushToTalkSettings {
        var result = PushToTalkSettings()
        result.enabled = true; result.capturePath = .systemAudio; result.trigger = .level
        result.holdToSpeak = false; result.doubleTapToHold = false; result.doubleTapSpeed = .fast
        result.levelDb = -55; result.bypassForRecording = true; result.bypassForPlugin = true
        return result
    }
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
    private func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
    private func store(_ directory: URL) throws -> SettingsStore {
        try SettingsStore(file: directory.appendingPathComponent("settings.plist"))
    }

    func testNewSettingsAndNewProfilesHaveSafeWindowsDefaults() {
        let value = PushToTalkSettings()
        XCTAssertFalse(value.enabled); XCTAssertEqual(value.capturePath, .both); XCTAssertEqual(value.trigger, .key)
        XCTAssertTrue(value.holdToSpeak); XCTAssertTrue(value.doubleTapToHold); XCTAssertEqual(value.doubleTapSpeed, .medium)
        XCTAssertEqual(value.levelDb, -40); XCTAssertFalse(value.bypassForRecording); XCTAssertFalse(value.bypassForPlugin)
        XCTAssertEqual(profile().pushToTalk, value)
    }
    func testProfileInitializerRetainsAllExplicitChoices() {
        XCTAssertEqual(profile(customized()).pushToTalk, customized())
    }
    func testMissingNullAndEmptyLegacySettingsDefaultWithoutEnabling() throws {
        let original = try object(profile())
        for missing: Any? in [nil, NSNull(), [String: Any]()] {
            var raw = original; raw["pushToTalk"] = missing
            XCTAssertEqual(try decode(ConnectionProfile.self, raw).pushToTalk, .init())
        }
        XCTAssertEqual(try decode(PushToTalkSettings.self, [:]), .init())
    }
    func testPartialSettingsUseExplicitChoiceAndDefaultsForAbsentFields() throws {
        let value = try decode(PushToTalkSettings.self, ["enabled": true, "levelDb": -30])
        XCTAssertTrue(value.enabled); XCTAssertEqual(value.levelDb, -30)
        XCTAssertTrue(value.holdToSpeak); XCTAssertTrue(value.doubleTapToHold)
        XCTAssertEqual(value.capturePath, .both); XCTAssertEqual(value.doubleTapSpeed, .medium)
    }
    func testSettingsAndProfileRoundTripAllPathTriggerAndSpeedChoices() throws {
        for path in PushToTalkCapturePath.allCases {
            for trigger in PushToTalkTrigger.allCases {
                for speed in PushToTalkDoubleTapSpeed.allCases {
                    var value = customized(); value.capturePath = path; value.trigger = trigger; value.doubleTapSpeed = speed
                    XCTAssertEqual(try decode(PushToTalkSettings.self, object(value)), value)
                    XCTAssertEqual(try decode(ConnectionProfile.self, object(profile(value))).pushToTalk, value)
                }
            }
        }
    }
    func testEveryChoiceContributesToProfileDirtyEquality() {
        let original = profile()
        let edits: [(inout PushToTalkSettings) -> Void] = [
            { $0.enabled = true }, { $0.capturePath = .input }, { $0.trigger = .level },
            { $0.holdToSpeak = false }, { $0.doubleTapToHold = false }, { $0.doubleTapSpeed = .slow },
            { $0.levelDb = -41 }, { $0.bypassForRecording = true }, { $0.bypassForPlugin = true }
        ]
        for edit in edits {
            var changed = original; edit(&changed.pushToTalk)
            XCTAssertNotEqual(changed, original)
            XCTAssertEqual(changed.selectedPeerAddresses, original.selectedPeerAddresses)
            changed.pushToTalk = .init(); XCTAssertEqual(changed, original)
        }
    }
    func testLevelAssignmentAndDecodeClampBothIntegerExtremes() throws {
        for (db, expected) in [(Int.min, -70), (-71, -70), (-70, -70), (-40, -40), (-10, -10), (-9, -10), (Int.max, -10)] {
            var value = customized(); value.levelDb = db
            XCTAssertEqual(value.levelDb, expected)
            XCTAssertEqual(try decode(PushToTalkSettings.self, ["levelDb": db]).levelDb, expected)
            XCTAssertEqual(try object(value)["levelDb"] as? Int, expected)
        }
    }
    func testMalformedKnownFieldsAndUnknownChoicesAreRejected() throws {
        let invalid: [(String, Any)] = [("enabled", "true"), ("capturePath", "ASIO"), ("trigger", "unknown"),
            ("holdToSpeak", 1), ("doubleTapToHold", "false"), ("doubleTapSpeed", 3), ("doubleTapSpeed", "medium"),
            ("levelDb", -40.5), ("levelDb", "-40"), ("bypassForRecording", []), ("bypassForPlugin", [:])]
        for (key, value) in invalid {
            XCTAssertThrowsError(try decode(PushToTalkSettings.self, [key: value]))
            var raw = try object(profile()); raw["pushToTalk"] = [key: value]
            XCTAssertThrowsError(try decode(ConnectionProfile.self, raw))
        }
    }
    func testGateSnapshotCarriesAllAudioChoicesAndIsIndependent() {
        var value = customized(); let gate = value.gateConfiguration
        XCTAssertTrue(gate.enabled); XCTAssertEqual(gate.capturePath, .systemAudio); XCTAssertEqual(gate.trigger, .level)
        XCTAssertEqual(gate.levelDb, -55); XCTAssertTrue(gate.bypassForRecording); XCTAssertTrue(gate.bypassForPlugin)
        value.enabled = false; value.levelDb = -10
        XCTAssertTrue(gate.enabled); XCTAssertEqual(gate.levelDb, -55)
    }
    func testSettingsBookReopensWithoutSavingMachineKeyOrRuntimeIntoProfile() throws {
        let directory = try IsolatedTestDirectory.make("ptt-preferences")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try store(directory)
        settings.set("machine-key", forKey: "pushToTalkHotkey")
        settings.set(["retained-name"], forKey: "rememberedPeers")
        try PushToTalkPreferences.save(customized(), to: settings)
        let reopened = try store(directory)
        XCTAssertEqual(try PushToTalkPreferences.load(from: reopened), customized())
        XCTAssertEqual(reopened.string(forKey: "pushToTalkHotkey"), "machine-key")
        XCTAssertEqual(reopened.stringArray(forKey: "rememberedPeers"), ["retained-name"])
        let raw = try object(profile(customized()))
        XCTAssertNil(raw["pushToTalkHotkey"]); XCTAssertNil(raw["rememberedPeers"])
        let nested = try XCTUnwrap(raw["pushToTalk"] as? [String: Any])
        XCTAssertEqual(Set(nested.keys), Set(["enabled", "capturePath", "trigger", "holdToSpeak", "doubleTapToHold",
            "doubleTapSpeed", "levelDb", "bypassForRecording", "bypassForPlugin"]))
    }
    func testMissingPreferencesReturnDefaultsWithoutCreatingAFile() throws {
        let directory = try IsolatedTestDirectory.make("ptt-absent")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try store(directory)
        XCTAssertEqual(try PushToTalkPreferences.load(from: settings), .init())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("settings.plist").path))
    }
    func testUnreadablePreferencesAreNotSilentlyOverwritten() throws {
        let directory = try IsolatedTestDirectory.make("ptt-invalid")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try store(directory)
        for invalid: Any in ["wrong-type", Data("malformed".utf8), Data(repeating: 0, count: 4_097)] {
            settings.set(invalid, forKey: "pushToTalk")
            let file = directory.appendingPathComponent("settings.plist"), before = try Data(contentsOf: file)
            XCTAssertThrowsError(try PushToTalkPreferences.load(from: settings))
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
    }
    func testFailedIsolatedWriteReportsFailureWithoutChangingCachedChoices() throws {
        let directory = try IsolatedTestDirectory.make("ptt-write-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try store(directory); try PushToTalkPreferences.save(.init(), to: settings)
        let file = directory.appendingPathComponent("settings.plist")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try PushToTalkPreferences.save(customized(), to: settings))
        XCTAssertTrue(settings.persistenceFailed)
        XCTAssertEqual(try PushToTalkPreferences.load(from: settings), .init())
    }
    func testLegacyOpeningDoesNotRewriteProfileAndSavingRetainsExplicitChoices() throws {
        let directory = try IsolatedTestDirectory.make("ptt-profile-file")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = profile(), store = ProfileStore(directory: directory)
        var raw = try object(original); raw.removeValue(forKey: "pushToTalk")
        let file = directory.appendingPathComponent(original.id.uuidString + ".json")
        let bytes = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted])
        try bytes.write(to: file)
        var loaded = try store.load(id: original.id)
        XCTAssertEqual(loaded.pushToTalk, .init()); XCTAssertEqual(try Data(contentsOf: file), bytes)
        loaded.pushToTalk = customized(); try store.save(loaded)
        XCTAssertEqual(try store.load(id: original.id), loaded)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testMalformedProfileStaysUnreadableAndItsBytesSurviveListing() throws {
        let directory = try IsolatedTestDirectory.make("ptt-bad-profile")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = profile(), store = ProfileStore(directory: directory)
        var raw = try object(original); raw["pushToTalk"] = ["enabled": "true"]
        let file = directory.appendingPathComponent(original.id.uuidString + ".json")
        let bytes = try JSONSerialization.data(withJSONObject: raw); try bytes.write(to: file)
        XCTAssertThrowsError(try store.load(id: original.id))
        XCTAssertTrue(try store.list().isEmpty); XCTAssertEqual(store.unreadable(), [file])
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testProfileSwitchAndDefaultResetLeaveKeyBookIndependent() throws {
        let directory = try IsolatedTestDirectory.make("ptt-profile-switch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try store(directory), profiles = ProfileStore(directory: directory.appendingPathComponent("profiles"))
        settings.set("machine-key", forKey: "pushToTalkHotkey")
        let enabled = profile(customized(), title: "Enabled"), disabled = profile(title: "Disabled")
        try profiles.save(enabled); try profiles.save(disabled)
        for saved in [enabled, disabled, enabled] {
            let loaded = try profiles.load(id: saved.id)
            try PushToTalkPreferences.save(loaded.pushToTalk, to: settings)
            XCTAssertEqual(try PushToTalkPreferences.load(from: settings), saved.pushToTalk)
            XCTAssertEqual(settings.string(forKey: "pushToTalkHotkey"), "machine-key")
        }
        try PushToTalkPreferences.save(.init(), to: settings)
        XCTAssertEqual(try profiles.load(id: enabled.id).pushToTalk, customized())
    }
}
