import Foundation
import XCTest
@testable import RemSoundCore

final class BundledPluginSourceTests: XCTestCase {
    private func fixture(_ name: String = "sealed-source-fixture") throws -> URL {
        let base = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]))
        let root = base.appendingPathComponent("sealed-command-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("plugin-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: base.appendingPathComponent(name + "/RemSound.app"), to: source.appendingPathComponent("RemSound.app"))
        return root
    }
    private func target(_ root: URL) -> URL {
        root.appendingPathComponent("Library/Audio/Plug-Ins/VST3/RemSound.vst3/Contents/Resources/help.txt")
    }
    func testMovedSealedAppInstallsReinstallsAndRemovesOnlyOwnedFiles() throws {
        let root = try fixture(), settings = root.appendingPathComponent("settings.plist")
        try Data("private settings stay exact".utf8).write(to: settings)
        let result = PluginInstallationCommand.run(action: .install, isolatedRoot: root)
        XCTAssertEqual(result.status, "installed")
        XCTAssertFalse(result.nativeActivationVerified)
        guard result.status == "installed" else { return }
        XCTAssertGreaterThanOrEqual(result.files, 15)
        XCTAssertEqual(try Data(contentsOf: target(root)), Data("synthetic package fixture, not a real DAW wrapper\n".utf8))
        let bystander = root.appendingPathComponent("Library/Audio/Plug-Ins/VST3/Other.vst3")
        try Data("not ours".utf8).write(to: bystander)
        XCTAssertEqual(PluginInstallationCommand.run(action: .install, isolatedRoot: root).status, "installed")
        XCTAssertEqual(PluginInstallationCommand.run(action: .remove, isolatedRoot: root).status, "removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target(root).path))
        XCTAssertEqual(try Data(contentsOf: bystander), Data("not ours".utf8))
        XCTAssertEqual(try Data(contentsOf: settings), Data("private settings stay exact".utf8))
        XCTAssertEqual(PluginInstallationCommand.run(action: .remove, isolatedRoot: root).status, "notInstalled")
    }
    func testSealedSourceFailedInstallAndRemoveRestorePriorBytesAndManifest() throws {
        let root = try fixture()
        XCTAssertEqual(PluginInstallationCommand.run(action: .install, isolatedRoot: root).status, "installed")
        let manifest = root.appendingPathComponent("plugin-installation.json")
        let before = try Data(contentsOf: manifest), bytes = try Data(contentsOf: target(root))
        XCTAssertEqual(PluginInstallationCommand.run(action: .install, isolatedRoot: root, checkpoint: { throw CocoaError(.fileWriteUnknown) }).status, "failed")
        XCTAssertEqual(try Data(contentsOf: manifest), before)
        XCTAssertEqual(try Data(contentsOf: target(root)), bytes)
        XCTAssertEqual(PluginInstallationCommand.run(action: .remove, isolatedRoot: root, checkpoint: { throw CocoaError(.fileWriteUnknown) }).status, "failed")
        XCTAssertEqual(try Data(contentsOf: manifest), before)
        XCTAssertEqual(try Data(contentsOf: target(root)), bytes)
    }
    private func refuses(_ name: String) throws {
        let root = try fixture(name)
        XCTAssertEqual(PluginInstallationCommand.run(action: .install, isolatedRoot: root).status, "refused")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("plugin-installation.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".plugin-command.lock").path))
    }
    func testTamperedAppExecutableRefusesBeforeDestinationMutation() throws { try refuses("sealed-tampered") }
    func testResignedChangedPayloadStillRefusesStaleSealedInventory() throws { try refuses("sealed-stale-inventory") }
    func testResignedWrongAppVersionRefuses() throws { try refuses("sealed-wrong-version") }
    func testResignedForeignPluginIdentifierRefuses() throws { try refuses("sealed-foreign-plugin") }
    func testResignedThinRuntimeRefuses() throws { try refuses("sealed-thin-runtime") }
    func testMissingSealedManifestDoesNotFallBackToRawPayload() throws { try refuses("sealed-missing-manifest") }
}
