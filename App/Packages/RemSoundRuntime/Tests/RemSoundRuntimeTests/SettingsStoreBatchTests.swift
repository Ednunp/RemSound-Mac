import Foundation
import XCTest
@testable import RemSoundRuntime

final class SettingsStoreBatchTests: XCTestCase {
    private func fixture() throws -> (URL, SettingsStore) {
        let base = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let root = base.appendingPathComponent(UUID().uuidString)
        let configuration = try RuntimeConfiguration(options: LaunchOptions.parse(["--config-dir", root.path]))
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (root, configuration.settings)
    }
    func testBatchReopensTogetherAndPreservesUnmentionedValues() throws {
        let (root, store) = try fixture()
        store.set("untouched", forKey: "other")
        XCTAssertTrue(store.setValues(["profile": Data([1, 2]), "key": Data([3, 4])]))
        let reopened = try SettingsStore(file: root.appendingPathComponent("settings.plist"))
        XCTAssertEqual(reopened.data(forKey: "profile"), Data([1, 2]))
        XCTAssertEqual(reopened.data(forKey: "key"), Data([3, 4]))
        XCTAssertEqual(reopened.string(forKey: "other"), "untouched")
        XCTAssertFalse(store.persistenceFailed)
    }
    func testBatchURLTypedValuesAndExplicitRemovalRetainSingleSetContract() throws {
        let (root, store) = try fixture(); store.set("remove", forKey: "old")
        let url = root.appendingPathComponent("Recordings")
        XCTAssertTrue(store.setValues(["old": nil, "bool": true, "int": 19, "string": "hello",
            "list": ["a", "b"], "dictionary": ["x": [1, 2]], "url": url]))
        let reopened = try SettingsStore(file: root.appendingPathComponent("settings.plist"))
        XCTAssertNil(reopened.object(forKey: "old")); XCTAssertTrue(reopened.bool(forKey: "bool"))
        XCTAssertEqual(reopened.integer(forKey: "int"), 19); XCTAssertEqual(reopened.string(forKey: "string"), "hello")
        XCTAssertEqual(reopened.stringArray(forKey: "list"), ["a", "b"])
        XCTAssertEqual(reopened.dictionary(forKey: "dictionary")?["x"] as? [Int], [1, 2])
        XCTAssertEqual(reopened.url(forKey: "url"), url)
        reopened.removeObject(forKey: "bool"); XCTAssertNil(try SettingsStore(file: root.appendingPathComponent("settings.plist")).object(forKey: "bool"))
    }
    func testInvalidMemberRejectsEntireBatchAndPreservesExactBytes() throws {
        let (root, store) = try fixture(); store.set("old", forKey: "first")
        let file = root.appendingPathComponent("settings.plist"), before = try Data(contentsOf: file)
        XCTAssertFalse(store.setValues(["first": "new", "invalid": NSObject()]))
        XCTAssertTrue(store.persistenceFailed); XCTAssertEqual(store.string(forKey: "first"), "old")
        XCTAssertNil(store.object(forKey: "invalid")); XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertTrue(store.setValues(["first": "recovered", "second": 2])); XCTAssertFalse(store.persistenceFailed)
    }
    func testUnsafeParentDoesNotPublishAnyOfTheBatchOrLeaveStaging() throws {
        let (root, store) = try fixture(); XCTAssertTrue(store.setValues(["first": "old", "second": 1]))
        let file = root.appendingPathComponent("settings.plist"), before = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        XCTAssertFalse(store.setValues(["first": "new", "second": 2]))
        XCTAssertEqual(store.string(forKey: "first"), "old"); XCTAssertEqual(store.integer(forKey: "second"), 1)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set(["Logs", "Profiles", "Recordings", "settings.plist"]))
    }
    func testSymlinkDestinationRefusesWholeBatchAndPreservesForeignBytes() throws {
        let (root, store) = try fixture(); XCTAssertTrue(store.setValues(["first": "old", "second": 1]))
        let file = root.appendingPathComponent("settings.plist"), outside = root.appendingPathComponent("foreign")
        try Data("sentinel".utf8).write(to: outside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertFalse(store.setValues(["first": "new", "second": 2]))
        XCTAssertEqual(store.string(forKey: "first"), "old"); XCTAssertEqual(store.integer(forKey: "second"), 1)
        XCTAssertEqual(try Data(contentsOf: outside), Data("sentinel".utf8))
    }
    func testPublishedFileAlwaysOwnerOnlyAndNoTemporaryFileRemains() throws {
        let (root, store) = try fixture()
        for i in 0..<12 {
            XCTAssertTrue(store.setValues(["first": i, "second": i]))
            let file = root.appendingPathComponent("settings.plist")
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let reopened = try SettingsStore(file: file)
            XCTAssertEqual(reopened.integer(forKey: "first"), i); XCTAssertEqual(reopened.integer(forKey: "second"), i)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".settings-") })
    }
    func testEmptyBatchDoesNotCreateSettingsOrTouchRegisteredDefaults() throws {
        let (root, store) = try fixture(); XCTAssertTrue(store.setValues([:]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("settings.plist").path))
    }
    private final class RecordingDefaults: UserDefaults {
        var writes = 0
        override func set(_ value: Any?, forKey key: String) { writes += 1 }
    }
    func testNormalInvalidBatchIsValidatedBeforeAnyApplePreferenceWrite() {
        let defaults = RecordingDefaults(), store = SettingsStore(defaults: RecordingDefaults())
        let measured = SettingsStore(defaults: defaults)
        XCTAssertFalse(measured.setValues(["valid": "unexpected", "bad": NSObject()]))
        XCTAssertEqual(defaults.writes, 0)
        XCTAssertTrue(store.setValues([:]))
    }
}
