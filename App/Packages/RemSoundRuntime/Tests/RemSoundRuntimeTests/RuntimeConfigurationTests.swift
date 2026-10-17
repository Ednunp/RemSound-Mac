import XCTest
@testable import RemSoundRuntime

final class RuntimeConfigurationTests: XCTestCase {
    func testAccessibilityCheckRequiresVisibleTestOptInBeforeConfigurationAccess() throws {
        XCTAssertThrowsError(try LaunchOptions.parse([
            "--check-accessibility", "--config-dir", "/private/unused-visible-test-root"
        ], environment: [:]), "Native accessibility tests must not initialize GUI without explicit opt-in") { error in
            guard case RuntimeConfigurationError.accessibilityRequiresVisibleTestOptIn = error else {
                return XCTFail("Expected the visible UI test opt-in error")
            }
        }
        for value in ["", "0", "true", "01", "1 ", "1\n"] {
            XCTAssertThrowsError(try LaunchOptions.parse([
                "--check-accessibility", "--config-dir", "/private/unused-visible-test-root"
            ], environment: ["REMSOUND_ALLOW_VISIBLE_UI_TESTS": value]))
        }
        XCTAssertTrue(try LaunchOptions.parse(["--check-accessibility", "--help"], environment: [:]).help)
    }

    private func temporaryRoot() throws -> URL {
        // SwiftPM may give XCTest a different TMPDIR. Keep an explicit test root when supplied.
        let base = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let root = base.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func isolated(_ root: URL) throws -> RuntimeConfiguration {
        try RuntimeConfiguration(options: LaunchOptions.parse(["--config-dir", root.path]))
    }

    func testParseAndFailClosedBeforeConfigurationAccess() throws {
        let parsed = try LaunchOptions.parse(["--silent", "--config-dir", "/private/test run", "--check-accessibility"],
            environment: ["REMSOUND_ALLOW_VISIBLE_UI_TESTS": "1"])
        XCTAssertEqual(parsed.configurationDirectory?.path, "/private/test run")
        XCTAssertTrue(parsed.silent)
        XCTAssertTrue(parsed.checkAccessibility)
        for arguments in [["--config-dir"], ["--config-dir", "relative"], ["--config-dir", "/"],
            ["--config-dir", "--silent"], ["--config-dir", "/one", "--config-dir", "/two"],
            ["--check-accessibility"], ["--headless"], ["--control", "help"], ["--unknown"]] {
            XCTAssertThrowsError(try LaunchOptions.parse(arguments), "Accepted invalid launch arguments")
        }
        XCTAssertTrue(try LaunchOptions.parse(["--help"]).help)
        XCTAssertNil(try LaunchOptions.parse(["-psn_0_123"]).configurationDirectory)
    }

    func testIsolatedSettingsNeverFallBackAndRoundTripAllUsedTypes() throws {
        let root = try temporaryRoot()
        let context = try isolated(root)
        let store = context.settings
        XCTAssertNil(store.object(forKey: "displayName"))
        XCTAssertFalse(store.bool(forKey: "sendInput"))
        store.set("Isolated", forKey: "displayName")
        store.set(true, forKey: "sendInput")
        store.set(10, forKey: "receiveJitterMs")
        store.set(["one", "two"], forKey: "inputDeviceUIDs")
        store.set(["one": [0, 2]], forKey: "inputChannelPairs")
        store.set(Data([1, 2, 3]), forKey: "globalHotkeys")
        store.set(root.appendingPathComponent("Logs"), forKey: "logFolder")
        XCTAssertFalse(store.persistenceFailed)
        let reopened = try isolated(root).settings
        XCTAssertEqual(reopened.string(forKey: "displayName"), "Isolated")
        XCTAssertTrue(reopened.bool(forKey: "sendInput"))
        XCTAssertEqual(reopened.integer(forKey: "receiveJitterMs"), 10)
        XCTAssertEqual(reopened.stringArray(forKey: "inputDeviceUIDs"), ["one", "two"])
        XCTAssertEqual(reopened.dictionary(forKey: "inputChannelPairs")?["one"] as? [Int], [0, 2])
        XCTAssertEqual(reopened.data(forKey: "globalHotkeys"), Data([1, 2, 3]))
        XCTAssertEqual(reopened.url(forKey: "logFolder"), root.appendingPathComponent("Logs"))
        reopened.removeObject(forKey: "sendInput")
        XCTAssertNil(try isolated(root).settings.object(forKey: "sendInput"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("settings.plist").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testIsolatedStoreCannotReadAmbientRegistrationDefaults() throws {
        // Registration is process-local and nonpersistent; no installed-app preference is read or written.
        let key = "runtime-isolation-probe.\(UUID().uuidString)"
        UserDefaults.standard.register(defaults: [key: "ambient"])
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "ambient")
        let context = try isolated(temporaryRoot())
        XCTAssertNil(context.settings.string(forKey: key))
        context.settings.set("isolated", forKey: key)
        XCTAssertEqual(context.settings.string(forKey: key), "isolated")
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "ambient")
    }

    func testDifferentRootsHaveSeparateIdentityAndNoAmbientServices() throws {
        let first = try isolated(temporaryRoot())
        let second = try isolated(temporaryRoot())
        let id = first.serverClientID
        XCTAssertNotEqual(id, second.serverClientID)
        XCTAssertEqual(try isolated(first.root!).serverClientID, id)
        for context in [first, second] {
            XCTAssertTrue(context.isIsolated)
            XCTAssertFalse(context.allowsKeychain)
            XCTAssertFalse(context.allowsUpdates)
            XCTAssertFalse(context.allowsLoginItem)
            XCTAssertFalse(context.allowsGlobalHotkeys)
            for path in [context.logsDirectory, context.profilesDirectory, context.recordingsDirectory] {
                XCTAssertEqual(path.deletingLastPathComponent(), context.root)
            }
        }
        let normal = try RuntimeConfiguration(options: LaunchOptions.parse([]))
        XCTAssertFalse(normal.isIsolated)
        XCTAssertTrue(normal.allowsKeychain)
        XCTAssertTrue(normal.allowsUpdates)
        XCTAssertTrue(normal.allowsLoginItem)
        XCTAssertTrue(normal.allowsGlobalHotkeys)
    }

    func testRejectsPublicRootSymbolicLinksAndCorruptedSettings() throws {
        let root = try temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        XCTAssertThrowsError(try isolated(root))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let target = try temporaryRoot()
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: root)
        XCTAssertThrowsError(try isolated(target))
        let settings = root.appendingPathComponent("settings.plist")
        try Data("damaged".utf8).write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        XCTAssertThrowsError(try isolated(root))
        try FileManager.default.removeItem(at: settings)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try isolated(root))
    }

    func testFailedWritePreservesLastGoodStateAndCannotWriteThroughSymlink() throws {
        let root = try temporaryRoot()
        let store = try isolated(root).settings
        store.set("old", forKey: "displayName")
        let foreign = try temporaryRoot()
        try Data("sentinel".utf8).write(to: foreign)
        let file = root.appendingPathComponent("settings.plist")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: foreign)
        store.set("new", forKey: "displayName")
        XCTAssertTrue(store.persistenceFailed)
        XCTAssertEqual(store.string(forKey: "displayName"), "old")
        XCTAssertEqual(try String(contentsOf: foreign), "sentinel")
    }

    func testRejectsSymbolicLinkAncestorBeforeCreatingAnythingBeyondIt() throws {
        let parent = try temporaryRoot()
        let outside = try temporaryRoot()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try isolated(link.appendingPathComponent("configuration")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("configuration").path))
    }
}
