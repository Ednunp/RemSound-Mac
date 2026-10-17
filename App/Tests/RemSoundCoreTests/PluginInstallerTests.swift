import Foundation
import XCTest
@testable import RemSoundCore

/// Installing and removing the DAW plugins from the app (Windows' DAW plugin menu), in a test folder.
final class PluginInstallerTests: XCTestCase {
    private func installFixture(_ source: URL, _ target: URL, checkpoint: () throws -> Void = {}) -> PluginInstaller.Outcome {
        PluginInstaller.install(from: source, to: target, verifyOwnership: { url in
            _ = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        }, checkpoint: checkpoint)
    }
    private func removeFixture(_ target: URL, checkpoint: () throws -> Void = {}) -> PluginInstaller.Outcome {
        PluginInstaller.remove(from: target, verifyOwnership: { url in
            _ = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        }, checkpoint: checkpoint)
    }

    func testIncompletePayloadCannotPartiallyReplaceInstalledPlugins() throws {
        let f = try folders(); defer { f.cleanup() }
        for (name, folder) in PluginInstaller.bundles {
            let old = f.target.appendingPathComponent(folder + "/" + name + "/Contents/Info.plist")
            try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("old".utf8).write(to: old)
        }
        try FileManager.default.removeItem(at: f.source.appendingPathComponent("RemSound.clap"))
        if case .failed = PluginInstaller.install(from: f.source, to: f.target) {} else { XCTFail("Incomplete payload must refuse") }
        for (name, folder) in PluginInstaller.bundles {
            XCTAssertEqual(try Data(contentsOf: f.target.appendingPathComponent(folder + "/" + name + "/Contents/Info.plist")), Data("old".utf8))
        }
    }

    func testRemoveDoesNotDeleteForeignBundlesWithRemSoundFilenames() throws {
        let f = try folders(); defer { f.cleanup() }
        let foreign = f.target.appendingPathComponent("Components/RemSound.component/Contents/Info.plist")
        try FileManager.default.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not owned by RemSound".utf8).write(to: foreign)
        if case .failed = PluginInstaller.remove(from: f.target) {} else { XCTFail("Removal must verify ownership") }
        XCTAssertEqual(try? Data(contentsOf: foreign), Data("not owned by RemSound".utf8))
    }

    private func folders() throws -> (source: URL, target: URL, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-installer-\(UUID().uuidString)")
        let source = root.appendingPathComponent("RemSound.app/Contents/PlugIns"), target = root.appendingPathComponent("Library/Audio/Plug-Ins")
        for (name, _) in PluginInstaller.bundles {
            let contents = source.appendingPathComponent(name).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try Data("new \(name)".utf8).write(to: contents.appendingPathComponent("Info.plist"))
        }
        return (source, target, { try? FileManager.default.removeItem(at: root) })
    }

    func testInstallPutsEachPluginInItsFolderAndReplacesAnOldOne() throws {
        let f = try folders()
        defer { f.cleanup() }
        let old = f.target.appendingPathComponent("VST3/RemSound.vst3/Contents")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("Info.plist"))
        XCTAssertEqual(installFixture(f.source, f.target), .installed(3))
        XCTAssertEqual(PluginInstaller.installed(in: f.target), ["RemSound.component", "RemSound.vst3", "RemSound.clap"])
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("Info.plist"), encoding: .utf8), "new RemSound.vst3")
        XCTAssertTrue(PluginInstaller.Outcome.installed(3).message.hasPrefix("The AU, VST3 and CLAP plugins are installed"))
    }

    func testRemoveTakesThemOutAndSaysSoWhenThereWereNone() throws {
        let f = try folders()
        defer { f.cleanup() }
        XCTAssertEqual(PluginInstaller.remove(from: f.target), .nothingInstalled)
        _ = installFixture(f.source, f.target)
        XCTAssertEqual(removeFixture(f.target), .removed(3))
        XCTAssertTrue(PluginInstaller.installed(in: f.target).isEmpty)
        XCTAssertEqual(PluginInstaller.install(from: f.target, to: f.target), .nothingBundled)
    }

    func testFinalInstallFailureRestoresOldBundlesAndOriginalAbsence() throws {
        let f = try folders(); defer { f.cleanup() }
        let old = f.target.appendingPathComponent("VST3/RemSound.vst3/Contents/Info.plist")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old)
        var checkpoints = 0
        let result = installFixture(f.source, f.target) {
            checkpoints += 1; throw NSError(domain: "Final plugin verification", code: 1)
        }
        if case .failed = result {} else { XCTFail("Final verification fault must fail") }
        XCTAssertEqual(checkpoints, 1)
        XCTAssertEqual(try Data(contentsOf: old), Data("old".utf8))
        XCTAssertEqual(PluginInstaller.installed(in: f.target), ["RemSound.vst3"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: old.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path), ["RemSound.vst3"])
    }

    func testLateCopyFailureCannotLeaveEarlierFormatsReplaced() throws {
        let f = try folders(); defer { f.cleanup() }
        let old = f.target.appendingPathComponent("VST3/RemSound.vst3/Contents/Info.plist")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old)
        let blocked = f.target.appendingPathComponent("CLAP")
        try Data("bystander".utf8).write(to: blocked)
        if case .failed = installFixture(f.source, f.target) {} else { XCTFail("Blocked final staging must fail") }
        XCTAssertEqual(try Data(contentsOf: old), Data("old".utf8))
        XCTAssertEqual(PluginInstaller.installed(in: f.target), ["RemSound.vst3"])
        XCTAssertEqual(try Data(contentsOf: blocked), Data("bystander".utf8))
    }

    func testRemovalFaultRestoresEveryBundleAndBystander() throws {
        let f = try folders(); defer { f.cleanup() }
        XCTAssertEqual(installFixture(f.source, f.target), .installed(3))
        let bystander = f.target.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: bystander)
        var checkpoints = 0
        let result = removeFixture(f.target) { checkpoints += 1; throw NSError(domain: "Removal verification", code: 1) }
        if case .failed = result {} else { XCTFail("Removal fault must fail") }
        XCTAssertEqual(checkpoints, 1)
        XCTAssertEqual(PluginInstaller.installed(in: f.target).count, 3)
        XCTAssertEqual(try Data(contentsOf: bystander), Data("keep".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.target.path).contains { $0.hasPrefix(".plugin-remove-") || $0.hasSuffix(".lock") })
    }

    func testRedirectedDestinationLeavesTheExternalFolderUntouched() throws {
        let f = try folders(); defer { f.cleanup() }
        let external = f.source.deletingLastPathComponent().appendingPathComponent("bystander")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: f.target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.target.appendingPathComponent("Components"), withDestinationURL: external)
        if case .failed = installFixture(f.source, f.target) {} else { XCTFail("Redirected destination must fail") }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
    }
}
