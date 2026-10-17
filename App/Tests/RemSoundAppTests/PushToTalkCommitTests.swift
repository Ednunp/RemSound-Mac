import Foundation
import Carbon
import RemSoundCore
import RemSoundRuntime
import XCTest
@testable import RemSoundApp

final class PushToTalkCommitTests: XCTestCase {
    private let key = HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_A), modifiers: [])
    private func fixture() throws -> (URL, SettingsStore) {
        let base = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let root = base.appendingPathComponent(UUID().uuidString)
        let config = try RuntimeConfiguration(options: LaunchOptions.parse(["--config-dir", root.path]))
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (root, config.settings)
    }
    private func choices() -> PushToTalkSettings {
        var result = PushToTalkSettings(); result.enabled = true; result.levelDb = -55; result.bypassForRecording = true
        return result
    }
    func testSettingsAndExplicitMachineKeyReopenAsOneCommit() throws {
        let (root, store) = try fixture(); store.set("sentinel", forKey: "other")
        try PushToTalkPreferences.save(choices(), to: store,
            additionalValues: [PushToTalkKeyPreferences.settingsKey: try PushToTalkKeyPreferences.encoded(key)])
        let reopened = try SettingsStore(file: root.appendingPathComponent("settings.plist"))
        XCTAssertEqual(try PushToTalkPreferences.load(from: reopened), choices())
        XCTAssertEqual(try PushToTalkKeyPreferences.load(from: reopened), key)
        XCTAssertEqual(reopened.string(forKey: "other"), "sentinel")
    }
    func testUneditedUnreadableKeyIsPreservedByteForByte() throws {
        let (_, store) = try fixture(); let malformed = Data("unreadable".utf8)
        store.set(malformed, forKey: PushToTalkKeyPreferences.settingsKey)
        try PushToTalkPreferences.save(choices(), to: store, additionalValues: [:])
        XCTAssertEqual(store.data(forKey: PushToTalkKeyPreferences.settingsKey), malformed)
        XCTAssertThrowsError(try PushToTalkKeyPreferences.load(from: store))
    }
    func testExplicitUnsetReplacesUnreadableBookWithoutChoosingDefault() throws {
        let (_, store) = try fixture(); store.set("bad", forKey: PushToTalkKeyPreferences.settingsKey)
        try PushToTalkPreferences.save(choices(), to: store,
            additionalValues: [PushToTalkKeyPreferences.settingsKey: try PushToTalkKeyPreferences.encoded(nil)])
        XCTAssertNil(try PushToTalkKeyPreferences.load(from: store))
        XCTAssertNotNil(store.data(forKey: PushToTalkKeyPreferences.settingsKey))
    }
    func testInvalidKeyPreparationNeverWritesEitherChoice() throws {
        let (root, store) = try fixture(); try PushToTalkPreferences.save(.init(), to: store)
        let file = root.appendingPathComponent("settings.plist"), before = try Data(contentsOf: file)
        XCTAssertThrowsError(try PushToTalkPreferences.save(choices(), to: store,
            additionalValues: [PushToTalkKeyPreferences.settingsKey: try PushToTalkKeyPreferences.encoded(.init(keyCode: UInt32(kVK_Return), modifiers: []))]))
        XCTAssertEqual(try Data(contentsOf: file), before); XCTAssertEqual(try PushToTalkPreferences.load(from: store), .init())
    }
    func testFailedWritePreservesBothCacheAndExactPriorFile() throws {
        let (root, store) = try fixture(); try PushToTalkKeyPreferences.save(key, to: store)
        try PushToTalkPreferences.save(.init(), to: store)
        let file = root.appendingPathComponent("settings.plist"), before = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        XCTAssertThrowsError(try PushToTalkPreferences.save(choices(), to: store,
            additionalValues: [PushToTalkKeyPreferences.settingsKey: try PushToTalkKeyPreferences.encoded(nil)]))
        XCTAssertEqual(try PushToTalkPreferences.load(from: store), .init())
        XCTAssertEqual(try PushToTalkKeyPreferences.load(from: store), key); XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testInvalidCompanionValueDoesNotPartiallySaveProfileSettings() throws {
        let (root, store) = try fixture(); try PushToTalkPreferences.save(.init(), to: store)
        let file = root.appendingPathComponent("settings.plist"), before = try Data(contentsOf: file)
        XCTAssertThrowsError(try PushToTalkPreferences.save(choices(), to: store, additionalValues: ["bad": NSObject()]))
        XCTAssertEqual(try Data(contentsOf: file), before); XCTAssertEqual(try PushToTalkPreferences.load(from: store), .init())
    }
}
