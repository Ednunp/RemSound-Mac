import Foundation
import XCTest
@testable import RemSoundRuntime

final class RememberedPeerPreferencesTests: XCTestCase {
    private func file() throws -> URL {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("remembered-peers-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("settings.plist")
    }

    func testTrimCaseInsensitiveDeduplicationAndOriginalSpellingSurviveRestart() throws {
        let path = try file()
        let book = RememberedPeerPreferences(settings: try SettingsStore(file: path))
        book.replace(with: ["  Studio.local \n", "studio.LOCAL", "", " \t", "192.0.2.4", "STUDIO.local"])
        XCTAssertEqual(book.entries, ["Studio.local", "192.0.2.4"])
        book.remember("  stage.local ")
        book.remember("STAGE.LOCAL")
        XCTAssertEqual(RememberedPeerPreferences(settings: try SettingsStore(file: path)).entries,
            ["Studio.local", "192.0.2.4", "stage.local"])
    }

    func testIndependentOwnersShareMachineListRatherThanCachingAProfileCopy() throws {
        let settings = try SettingsStore(file: file())
        let firstProfile = RememberedPeerPreferences(settings: settings)
        let secondProfile = RememberedPeerPreferences(settings: settings)
        firstProfile.remember("first.local")
        XCTAssertEqual(secondProfile.entries, ["first.local"])
        secondProfile.remember("second.local")
        XCTAssertEqual(firstProfile.entries, ["first.local", "second.local"])
        firstProfile.forget(" FIRST.LOCAL ")
        XCTAssertEqual(secondProfile.entries, ["second.local"])
    }

    func testEmptyLegacyListDoesNotPreventFirstNonemptyMigration() throws {
        let settings = try SettingsStore(file: file())
        let book = RememberedPeerPreferences(settings: settings)
        book.migrateLegacy([])
        book.migrateLegacy([" \t"])
        book.migrateLegacy([" Old.local ", "old.LOCAL", "192.0.2.5"])
        XCTAssertEqual(book.entries, ["Old.local", "192.0.2.5"])
        book.migrateLegacy(["unopened-stale.local"])
        XCTAssertEqual(book.entries, ["Old.local", "192.0.2.5"])
    }

    func testMigrationUnionsExistingGlobalEntriesOnceWithoutRewritingOnRead() throws {
        let path = try file()
        let settings = try SettingsStore(file: path)
        settings.set(["entries": ["Current.local"], "migrated": false], forKey: "rememberedPeerBook")
        let before = try Data(contentsOf: path)
        let book = RememberedPeerPreferences(settings: settings)
        XCTAssertEqual(book.entries, ["Current.local"])
        XCTAssertEqual(try Data(contentsOf: path), before)
        book.migrateLegacy(["current.LOCAL", "Legacy.local"])
        XCTAssertEqual(book.entries, ["Current.local", "Legacy.local"])
        let after = try Data(contentsOf: path)
        book.migrateLegacy(["stale.local"])
        XCTAssertEqual(try Data(contentsOf: path), after)
    }

    func testExplicitClearCannotResurrectEntriesAfterRestartOrLaterLegacyLoad() throws {
        let path = try file()
        let book = RememberedPeerPreferences(settings: try SettingsStore(file: path))
        book.migrateLegacy(["old.local"])
        book.replace(with: [])
        let restarted = RememberedPeerPreferences(settings: try SettingsStore(file: path))
        restarted.migrateLegacy(["old.local", "another-profile.local"])
        XCTAssertEqual(restarted.entries, [])
        XCTAssertEqual(RememberedPeerPreferences(settings: try SettingsStore(file: path)).entries, [])
    }

    func testExplicitClearBeforeMigrationAlsoPreventsResurrection() throws {
        let path = try file()
        let book = RememberedPeerPreferences(settings: try SettingsStore(file: path))
        book.replace(with: [])
        let restarted = RememberedPeerPreferences(settings: try SettingsStore(file: path))
        restarted.migrateLegacy(["unopened-old-profile.local"])
        XCTAssertTrue(restarted.entries.isEmpty)
    }

    func testForgetLastEntryAndBlankInputLeaveExplicitEmptyList() throws {
        let path = try file()
        let book = RememberedPeerPreferences(settings: try SettingsStore(file: path))
        book.remember("Peer.local")
        book.forget("PEER.local")
        book.remember(" \n")
        let restarted = RememberedPeerPreferences(settings: try SettingsStore(file: path))
        restarted.migrateLegacy(["Peer.local"])
        XCTAssertTrue(restarted.entries.isEmpty)
    }

    func testFailedWriteDoesNotPublishUnsavedEntriesOrFallbackToUserPreferences() throws {
        let path = try file()
        let settings = try SettingsStore(file: path)
        let book = RememberedPeerPreferences(settings: settings)
        book.remember("Saved.local")
        let original = try Data(contentsOf: path)
        let directory = path.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        book.replace(with: ["Unsaved.local"])
        XCTAssertTrue(settings.persistenceFailed)
        XCTAssertEqual(book.entries, ["Saved.local"])
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testEntryUsesAdvertisedNameRatherThanUserAliasAndFallsBackForNameCollision() {
        let first = RememberedPeerIdentity(instanceID: UUID(), advertisedName: "Studio", address: "192.0.2.1")
        let sameDevice = RememberedPeerIdentity(instanceID: first.instanceID, advertisedName: "STUDIO", address: "192.0.2.9")
        let second = RememberedPeerIdentity(instanceID: UUID(), advertisedName: "studio", address: "192.0.2.2")
        XCTAssertEqual(RememberedPeerPreferences.entry(for: first, among: [first, sameDevice]), "Studio")
        XCTAssertEqual(RememberedPeerPreferences.entry(for: first, among: [first, second]), "192.0.2.1")
        XCTAssertEqual(RememberedPeerPreferences.entry(for: second, among: [first, second]), "192.0.2.2")
    }

    func testBlankOrAddressNameFallsBackAndKnownServerIsExcluded() {
        let blank = RememberedPeerIdentity(instanceID: UUID(), advertisedName: " \n", address: "192.0.2.7")
        let address = RememberedPeerIdentity(instanceID: UUID(), advertisedName: "192.0.2.8", address: "192.0.2.8")
        XCTAssertEqual(RememberedPeerPreferences.entry(for: blank, among: []), "192.0.2.7")
        XCTAssertEqual(RememberedPeerPreferences.entry(for: address, among: []), "192.0.2.8")
        XCTAssertNil(RememberedPeerPreferences.entry(for: blank, among: [], isKnownServer: true))
    }
}
