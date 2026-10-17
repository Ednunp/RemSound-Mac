import Foundation
import XCTest
@testable import RemSoundRuntime

final class CueMigrationTests: XCTestCase {
    private func store() throws -> SettingsStore {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("cue-migration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try SettingsStore(file: root.appendingPathComponent("settings.plist"))
    }

    func testExactlySixGlobalEventsAndAllOtherEventsFollowTheProfile() {
        XCTAssertEqual(Set(CueEvent.allCases.filter { !$0.isProfileSetting }),
            [.save, .profileSwitch, .profileMenuOpen, .update, .helpOpen, .helpClose])
        XCTAssertEqual(CueEvent.allCases.filter(\.isProfileSetting).count, 20)
        XCTAssertTrue(CueEvent.serverConnect.isProfileSetting)
        XCTAssertTrue(CueEvent.serverDisconnect.isProfileSetting)
    }

    func testBuiltInChoicesFollowEachProfileAndGlobalEditsLeaveProfileUntouched() throws {
        let cues = CuePreferences(settings: try store())
        cues.loadProfile([:])
        cues.chooseBuiltIn("connect 2.wav", for: .connect)
        cues.chooseCustomFile("/private/profile-startup.wav", for: .startup)
        let first = cues.profileConfigurations
        cues.chooseCustomFile("/private/global-save.wav", for: .save)
        XCTAssertEqual(cues.profileConfigurations, first)
        cues.loadProfile([:])
        cues.chooseBuiltIn("connect 3.wav", for: .connect)
        let second = cues.profileConfigurations
        cues.loadProfile(first)
        XCTAssertEqual(cues.builtInSelection(for: .connect,
            variants: ["connect 1.wav", "connect 2.wav", "connect 3.wav"]), "connect 2.wav")
        XCTAssertEqual(cues.configuration(for: .startup).customPath, "/private/profile-startup.wav")
        cues.loadProfile(second)
        XCTAssertEqual(cues.builtInSelection(for: .connect,
            variants: ["connect 1.wav", "connect 2.wav", "connect 3.wav"]), "connect 3.wav")
        XCTAssertNil(cues.configuration(for: .startup).customPath)
        XCTAssertEqual(cues.configuration(for: .save).customPath, "/private/global-save.wav")
    }

    func testUnopenedLegacyProfileRetainsOriginalMachineChoiceAfterOtherProfileEdits() throws {
        let settings = try store()
        settings.set("connect 2.wav", forKey: "cueSound.connect")
        settings.set("Off", forKey: "cueSound.startup")
        let cues = CuePreferences(settings: settings)
        cues.chooseBuiltIn("connect 3.wav", for: .connect)
        cues.chooseBuiltIn("start up 1.wav", for: .startup)
        // A later legacy-domain rewrite must not change the frozen upgrade-time choices.
        settings.set("connect 1.wav", forKey: "cueSound.connect")
        settings.set("start up 1.wav", forKey: "cueSound.startup")
        let reopened = CuePreferences(settings: settings)
        reopened.loadProfile(nil)
        XCTAssertEqual(reopened.builtInSelection(for: .connect,
            variants: ["connect 1.wav", "connect 2.wav", "connect 3.wav"]), "connect 2.wav")
        XCTAssertFalse(reopened.configuration(for: .startup).enabled)
    }

    func testFirstOldProfileSeedsGlobalsOnceAndAllOldProfileValuesRemainDistinct() throws {
        let settings = try store()
        settings.set("connect 2.wav", forKey: "cueSound.connect")
        settings.set("save 2.wav", forKey: "cueSound.save")
        settings.set(try JSONEncoder().encode(CueConfiguration(enabled: false, customPath: "/private/old-start.wav")),
            forKey: "audioCue.startup")
        let cues = CuePreferences(settings: settings)
        cues.loadProfile(["connect": CueConfiguration(enabled: false, customPath: "/private/old-a.wav"),
            "save": CueConfiguration(enabled: false, customPath: "/private/old-save.wav")], schemaVersion: 0)
        XCTAssertEqual(cues.configuration(for: .connect),
            CueConfiguration(enabled: false, customPath: "/private/old-a.wav", builtInName: "connect 2.wav"))
        XCTAssertEqual(cues.configuration(for: .startup).customPath, "/private/old-start.wav")
        XCTAssertFalse(cues.configuration(for: .startup).enabled)
        let first = cues.profileConfigurations
        let globals = cues.globalConfigurations
        XCTAssertEqual(globals["save"], CueConfiguration(enabled: false,
            customPath: "/private/old-save.wav", builtInName: "save 2.wav"))
        cues.chooseBuiltIn("connect 3.wav", for: .connect)
        cues.loadProfile(["connect": CueConfiguration(customPath: "/private/old-b.wav"),
            "save": CueConfiguration(customPath: "/private/ignored-save.wav")], schemaVersion: 0)
        XCTAssertEqual(cues.configuration(for: .connect).customPath, "/private/old-b.wav")
        XCTAssertEqual(cues.configuration(for: .connect).builtInName, "connect 2.wav")
        XCTAssertEqual(cues.globalConfigurations, globals)
        XCTAssertFalse(cues.profileConfigurations.keys.contains("save"))
        XCTAssertEqual(CuePreferences(settings: settings).globalConfigurations, globals)
        cues.loadProfile(first)
        XCTAssertFalse(cues.configuration(for: .connect).enabled)
        XCTAssertFalse(settings.persistenceFailed)
    }

    func testMachineMutePersistsImmediatelyWithoutTouchingEitherCueCollection() throws {
        let settings = try store()
        let cues = CuePreferences(settings: settings)
        cues.loadProfile([:])
        let profile = cues.profileConfigurations, globals = cues.globalConfigurations
        XCTAssertFalse(cues.muteAllCues)
        cues.setMuteAllCues(true)
        XCTAssertTrue(CuePreferences(settings: settings).muteAllCues)
        cues.loadProfile(["connect": CueConfiguration(enabled: false)])
        XCTAssertTrue(cues.muteAllCues)
        cues.loadProfile(profile)
        cues.setMuteAllCues(false)
        XCTAssertEqual(cues.profileConfigurations, profile)
        XCTAssertEqual(cues.globalConfigurations, globals)
    }

    func testGlobalHelpMirrorsRemainConsistentForNativePluginReaders() throws {
        let settings = try store()
        let cues = CuePreferences(settings: settings)
        cues.loadProfile([:])
        let profile = cues.profileConfigurations
        cues.chooseBuiltIn("help open 3.wav", for: .helpOpen)
        cues.chooseCustomFile("/private/help.wav", for: .helpOpen)
        cues.setEnabled(false, for: .helpOpen)
        let mirrored = try JSONDecoder().decode(CueConfiguration.self,
            from: XCTUnwrap(settings.data(forKey: "audioCue.helpOpen")))
        XCTAssertEqual(mirrored, cues.configuration(for: .helpOpen))
        XCTAssertEqual(settings.string(forKey: "cueSound.helpOpen"), "help open 3.wav")
        XCTAssertEqual(cues.profileConfigurations, profile)
    }

    func testNewProfileCanInheritAllChoicesWithoutCarryingGlobalsOrMute() throws {
        let cues = CuePreferences(settings: try store())
        cues.loadProfile([:])
        for event in CueEvent.profileEvents {
            cues.chooseBuiltIn(event.filenameBase + " 2.wav", for: event)
            cues.chooseCustomFile("/private/\(event.rawValue).wav", for: event)
            cues.setEnabled(false, for: event)
        }
        cues.chooseBuiltIn("save 2.wav", for: .save)
        cues.setMuteAllCues(true)
        let inherited = cues.profileConfigurations, globals = cues.globalConfigurations
        cues.loadProfile(inherited)
        XCTAssertEqual(cues.profileConfigurations, inherited)
        XCTAssertEqual(cues.profileConfigurations.count, 20)
        XCTAssertTrue(Set(cues.profileConfigurations.keys).isDisjoint(with: globals.keys))
        XCTAssertEqual(cues.globalConfigurations, globals)
        XCTAssertTrue(cues.muteAllCues)
    }
}
