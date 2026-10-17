import XCTest
@testable import RemSoundCore

final class UpdateTransactionTests: XCTestCase {
    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try content.write(to: url.appendingPathComponent("version"), atomically: true,
            encoding: .utf8)
    }

    private func version(_ url: URL) throws -> String {
        try String(contentsOf: url.appendingPathComponent("version"))
    }

    func testInstallsAppAndPluginsTogether() throws {
        let root = try IsolatedTestDirectory.make("update-transaction")
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["RemSound.app", "RemSound.component", "RemSound.vst3", "RemSound.clap"]
        let items = names.map { UpdateInstallItem(source: root.appendingPathComponent("new/\($0)"),
            target: root.appendingPathComponent("installed/\($0)")) }
        for item in items {
            try write("old", to: item.target)
            try write("new", to: item.source)
        }
        try UpdateTransaction.install(items, copy: FileManager.default.copyItem,
            verify: { url in XCTAssertEqual(try self.version(url), "new") })
        for item in items { XCTAssertEqual(try version(item.target), "new") }
        let namesAfter = try FileManager.default.contentsOfDirectory(atPath:
            root.appendingPathComponent("installed").path)
        XCTAssertEqual(Set(namesAfter), Set(names))
    }

    func testRestoresAllOldBundlesIfFinalVerificationFails() throws {
        let root = try IsolatedTestDirectory.make("update-transaction")
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["RemSound.app", "RemSound.component", "RemSound.vst3", "RemSound.clap"]
        let items = names.map { UpdateInstallItem(source: root.appendingPathComponent("new/\($0)"),
            target: root.appendingPathComponent("installed/\($0)")) }
        for item in items {
            try write("old", to: item.target)
            try write("new", to: item.source)
        }
        let finalTarget = items[2].target
        XCTAssertThrowsError(try UpdateTransaction.install(items,
            copy: FileManager.default.copyItem,
            verify: { url in
                if url == finalTarget { throw NSError(domain: "Test", code: 1) }
            }))
        for item in items { XCTAssertEqual(try version(item.target), "old") }
        let namesAfter = try FileManager.default.contentsOfDirectory(atPath:
            root.appendingPathComponent("installed").path)
        XCTAssertEqual(Set(namesAfter), Set(names))
    }

    func testRollbackRestoresPluginThatWasNotPreviouslyInstalledToAbsence() throws {
        let root = try IsolatedTestDirectory.make("update-transaction")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = UpdateInstallItem(source: root.appendingPathComponent("new/RemSound.app"),
            target: root.appendingPathComponent("installed/RemSound.app"))
        let plugin = UpdateInstallItem(source: root.appendingPathComponent("new/RemSound.clap"),
            target: root.appendingPathComponent("installed/RemSound.clap"))
        try write("old", to: app.target)
        try write("new", to: app.source)
        try write("new", to: plugin.source)
        XCTAssertThrowsError(try UpdateTransaction.install([app, plugin],
            copy: FileManager.default.copyItem,
            verify: { url in
                if url == plugin.target { throw NSError(domain: "Test", code: 2) }
            }))
        XCTAssertEqual(try version(app.target), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plugin.target.path))
    }

    func testPartialStagingFailureLeavesInstallationAndUserDataUntouched() throws {
        let root = try IsolatedTestDirectory.make("update-transaction")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = ["RemSound.app", "RemSound.component"].map {
            UpdateInstallItem(source: root.appendingPathComponent("new/\($0)"),
                target: root.appendingPathComponent("installed/\($0)"))
        }
        for item in items { try write("old", to: item.target); try write("new", to: item.source) }
        let profile = root.appendingPathComponent("user-data/profile.json")
        try FileManager.default.createDirectory(at: profile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = Data("{\"name\":\"Synthetic profile\",\"readOnly\":true}".utf8)
        try data.write(to: profile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profile.path)
        XCTAssertThrowsError(try UpdateTransaction.install(items, copy: { source, target in
            try FileManager.default.copyItem(at: source, to: target)
            if source == items[1].source { throw NSError(domain: "PartialCopy", code: 1) }
        }, verify: { _ in }))
        for item in items { XCTAssertEqual(try version(item.target), "old") }
        XCTAssertEqual(try Data(contentsOf: profile), data)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: profile.path)[.posixPermissions]
            as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:
            root.appendingPathComponent("installed").path)), Set(["RemSound.app", "RemSound.component"]))
    }

    func testSuccessfulUpdatePreservesExternalSettingsProfilesAndRecordings() throws {
        let root = try IsolatedTestDirectory.make("update-transaction")
        defer { try? FileManager.default.removeItem(at: root) }
        let item = UpdateInstallItem(source: root.appendingPathComponent("new/RemSound.app"),
            target: root.appendingPathComponent("installed/RemSound.app"))
        try write("old", to: item.target); try write("new", to: item.source)
        let files = ["settings.plist", "Profiles/profile.json", "Recordings/example.wav"].map {
            root.appendingPathComponent("user-data/\($0)")
        }
        for file in files {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data("synthetic \(file.lastPathComponent)".utf8).write(to: file)
        }
        let snapshots = try files.map { try Data(contentsOf: $0) }
        try UpdateTransaction.install([item], copy: FileManager.default.copyItem,
            verify: { url in XCTAssertEqual(try self.version(url), "new") })
        for (file, snapshot) in zip(files, snapshots) {
            XCTAssertEqual(try Data(contentsOf: file), snapshot)
        }
    }
}
