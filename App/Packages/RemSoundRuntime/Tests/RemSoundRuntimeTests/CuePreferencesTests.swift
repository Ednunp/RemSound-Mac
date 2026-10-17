import Foundation
import XCTest
@testable import RemSoundRuntime

final class CuePreferencesTests: XCTestCase {
    private func isolatedStore() throws -> (SettingsStore, URL) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]
            ?? FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("cues-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (try SettingsStore(file: root.appendingPathComponent("settings.plist")), root)
    }

    func testNewScopeAndLegacyOffSurviveVariantChangesAndRestart() throws {
        XCTAssertEqual(Set(CueEvent.allCases.filter(\.isProfileSetting)),
            Set(CueEvent.allCases).subtracting([.save, .profileSwitch, .profileMenuOpen, .update, .helpOpen, .helpClose]))
        let (store, root) = try isolatedStore()
        store.set("Off", forKey: "cueSound.connect")
        store.set("Off", forKey: "cueSound.dawOn")
        let cues = CuePreferences(settings: store)
        XCTAssertFalse(cues.configuration(for: .connect).enabled)
        XCTAssertFalse(cues.configuration(for: .dawOn).enabled)
        cues.chooseBuiltIn("connect 2.wav", for: .connect)
        XCTAssertTrue(cues.configuration(for: .connect).enabled)
        cues.loadProfile(nil) // A pre-cue-profile file retains its old Off setting.
        XCTAssertFalse(cues.configuration(for: .connect).enabled)
        cues.loadProfile([:]) // A new profile has Windows' enabled defaults.
        XCTAssertTrue(cues.configuration(for: .connect).enabled)
        let restarted = CuePreferences(settings: try SettingsStore(file: root.appendingPathComponent("settings.plist")))
        restarted.loadProfile(nil)
        XCTAssertFalse(restarted.configuration(for: .connect).enabled)
        XCTAssertFalse(restarted.configuration(for: .dawOn).enabled)
        XCTAssertEqual(restarted.builtInSelection(for: .connect, variants: ["connect 1.wav", "connect 2.wav"]), "connect 1.wav")
    }

    func testEnabledCustomFilesAndBuiltInChoicesFollowTheProfile() throws {
        let (store, _) = try isolatedStore()
        let cues = CuePreferences(settings: store)
        cues.loadProfile([:])
        cues.chooseCustomFile("/private/example-a.wav", for: .connect)
        cues.chooseCustomFile("/private/machine.wav", for: .startup)
        cues.setEnabled(false, for: .disconnect)
        let first = cues.profileConfigurations
        XCTAssertEqual(first.count, 20)
        XCTAssertNotNil(first[CueEvent.startup.rawValue])
        cues.loadProfile([:])
        XCTAssertNil(cues.configuration(for: .connect).customPath)
        XCTAssertTrue(cues.configuration(for: .disconnect).enabled)
        XCTAssertNil(cues.configuration(for: .startup).customPath)
        cues.chooseBuiltIn("connect 2.wav", for: .connect)
        cues.loadProfile(first)
        XCTAssertEqual(cues.configuration(for: .connect).customPath, "/private/example-a.wav")
        XCTAssertFalse(cues.configuration(for: .disconnect).enabled)
        XCTAssertEqual(cues.builtInSelection(for: .connect, variants: ["connect 1.wav", "connect 2.wav"]), "connect 1.wav")
        let restarted = CuePreferences(settings: store)
        XCTAssertEqual(restarted.profileConfigurations, first)
        XCTAssertEqual(restarted.configuration(for: .startup).customPath, "/private/machine.wav")
    }

    func testOffRetainsCustomFileAndBuiltInReplacesItWithoutChangingAnotherProfile() throws {
        let (store, _) = try isolatedStore()
        let cues = CuePreferences(settings: store)
        cues.chooseCustomFile("/private/custom.wav", for: .recordStart)
        let saved = cues.profileConfigurations
        cues.setEnabled(false, for: .recordStart)
        XCTAssertEqual(cues.configuration(for: .recordStart).customPath, "/private/custom.wav")
        XCTAssertTrue(cues.playbackCandidates(for: .recordStart, variants: ["record start 1.wav"],
            directory: URL(fileURLWithPath: "/private/bundled")).isEmpty)
        cues.chooseCustomFile("/private/custom.wav", for: .recordStart)
        XCTAssertTrue(cues.configuration(for: .recordStart).enabled)
        cues.chooseBuiltIn("record start 2.wav", for: .recordStart)
        XCTAssertNil(cues.configuration(for: .recordStart).customPath)
        cues.loadProfile(saved)
        XCTAssertEqual(cues.configuration(for: .recordStart).customPath, "/private/custom.wav")
    }

    func testPlaybackUsesCustomThenSharedDefaultAndNeverRemoteOrRelativePaths() throws {
        let (store, _) = try isolatedStore()
        let cues = CuePreferences(settings: store)
        let directory = URL(fileURLWithPath: "/private/bundled")
        cues.chooseBuiltIn("CONNECT 2.WAV", for: .connect)
        cues.chooseCustomFile("/private/missing.wav", for: .connect)
        XCTAssertEqual(cues.playbackCandidates(for: .connect, variants: ["connect 1.wav", "connect 2.wav"],
            directory: directory).map(\.path), ["/private/missing.wav", "/private/bundled/connect 2.wav"])
        for unsafe in ["relative.wav", "https://example.invalid/a.wav", "", "  "] {
            cues.chooseCustomFile(unsafe, for: .connect)
            XCTAssertEqual(cues.playbackCandidates(for: .connect, variants: ["connect 1.wav"],
                directory: directory).map(\.path), ["/private/bundled/connect 1.wav"])
        }
        XCTAssertEqual(cues.playbackCandidates(for: .connect, variants: [], directory: nil), [])
    }

    func testProfileRejectsMachineAndUnknownKeysAndCurrentStatePersistsWithoutProfileWrite() throws {
        let (store, _) = try isolatedStore()
        let cues = CuePreferences(settings: store)
        cues.loadProfile(["startup": CueConfiguration(enabled: false),
            "unknown": CueConfiguration(enabled: false),
            "save": CueConfiguration(enabled: false, customPath: "/private/save.wav")])
        XCTAssertFalse(cues.configuration(for: .startup).enabled)
        XCTAssertEqual(cues.profileConfigurations.count, 20)
        XCTAssertTrue(cues.configuration(for: .save).enabled)
        XCTAssertNil(cues.profileConfigurations["save"])
        XCTAssertNil(cues.profileConfigurations["unknown"])
        let copy = try JSONDecoder().decode([String: CueConfiguration].self,
            from: JSONEncoder().encode(cues.profileConfigurations))
        XCTAssertEqual(copy, cues.profileConfigurations)
        XCTAssertFalse(store.persistenceFailed)
    }
    func testPushToTalkEventsBelongToProfilesAndUseTheirOwnAssets() throws {
        let on = try XCTUnwrap(CueEvent(rawValue: "pushToTalkOn")), off = try XCTUnwrap(CueEvent(rawValue: "pushToTalkOff"))
        XCTAssertTrue(on.isProfileSetting); XCTAssertTrue(off.isProfileSetting)
        XCTAssertEqual(on.filenameBase, "push talk on"); XCTAssertEqual(off.filenameBase, "push talk off")
        XCTAssertTrue(CueEvent.profileEvents.contains(on)); XCTAssertFalse(CueEvent.globalEvents.contains(off))
    }
    func testPushToTalkProfileOffVariantAndCustomChoicesReopenIndependently() throws {
        let on = try XCTUnwrap(CueEvent(rawValue: "pushToTalkOn")), off = try XCTUnwrap(CueEvent(rawValue: "pushToTalkOff"))
        let (store, root) = try isolatedStore(); let cues = CuePreferences(settings: store)
        cues.chooseBuiltIn("push talk on 3.wav", for: on); cues.chooseCustomFile("/private/test-off.wav", for: off)
        cues.setEnabled(false, for: off); let saved = cues.profileConfigurations
        cues.loadProfile([:]); XCTAssertTrue(cues.configuration(for: off).enabled)
        cues.loadProfile(saved)
        XCTAssertEqual(cues.configuration(for: on).builtInName, "push talk on 3.wav")
        XCTAssertFalse(cues.configuration(for: off).enabled); XCTAssertEqual(cues.configuration(for: off).customPath, "/private/test-off.wav")
        let reopened = CuePreferences(settings: try SettingsStore(file: root.appendingPathComponent("settings.plist")))
        XCTAssertEqual(reopened.profileConfigurations, saved); XCTAssertNil(reopened.globalConfigurations[on.rawValue])
    }
    func testOlderCueProfilesDefaultNewPTTCuesWithoutChangingMachineMute() throws {
        let on = try XCTUnwrap(CueEvent(rawValue: "pushToTalkOn")), off = try XCTUnwrap(CueEvent(rawValue: "pushToTalkOff"))
        let (store, _) = try isolatedStore(); let cues = CuePreferences(settings: store)
        cues.setMuteAllCues(true); cues.setEnabled(false, for: .connect)
        cues.loadProfile(["connect": .init(enabled: false)], schemaVersion: CuePreferences.schemaVersion)
        XCTAssertEqual(cues.configuration(for: on), .init()); XCTAssertEqual(cues.configuration(for: off), .init())
        XCTAssertTrue(cues.muteAllCues); XCTAssertFalse(cues.configuration(for: .connect).enabled)
    }

}
