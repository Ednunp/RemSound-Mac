import Foundation
import CryptoKit
import Darwin
import XCTest
@testable import RemSoundCore

final class PluginInstallationCommandTests: XCTestCase {
    private func fixture() throws -> URL {
        let base = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]))
        let root = base.appendingPathComponent("plugin-tool-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (format, name) in [("AU", "RemSound.component"), ("VST3", "RemSound.vst3"), ("CLAP", "RemSound.clap")] {
            let folder = root.appendingPathComponent("plugin-payload/\(format)/\(name)/Contents/nested")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("synthetic never loaded".utf8).write(to: folder.appendingPathComponent("fixture.bin"))
        }
        return root
    }
    private func target(_ root: URL) -> URL { root.appendingPathComponent("Library/Audio/Plug-Ins/VST3/RemSound.vst3/Contents/nested/fixture.bin") }
    func testActualFixedInstallReinstallAndExactRemovalPreserveBystandersAndSettings() throws {
        let root = try fixture(), file = target(root), settings = root.appendingPathComponent("settings.plist")
        try Data("do not read or change settings".utf8).write(to: settings)
        XCTAssertEqual(PluginInstallationCommand.run(action: .install, isolatedRoot: root).status, "installed")
        XCTAssertEqual(try Data(contentsOf: file), Data("synthetic never loaded".utf8))
        let bystander = file.deletingLastPathComponent().appendingPathComponent("someone-else.bin")
        try Data("bystander".utf8).write(to: bystander)
        let source = root.appendingPathComponent("plugin-payload/VST3/RemSound.vst3/Contents/nested/fixture.bin")
        try Data("new synthetic version".utf8).write(to: source)
        XCTAssertEqual(PluginInstallationCommand.run(action: .install, isolatedRoot: root).status, "installed")
        XCTAssertEqual(try Data(contentsOf: file), Data("new synthetic version".utf8))
        XCTAssertEqual(PluginInstallationCommand.run(action: .remove, isolatedRoot: root).status, "removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: bystander), Data("bystander".utf8))
        XCTAssertEqual(try Data(contentsOf: settings), Data("do not read or change settings".utf8))
        XCTAssertEqual(PluginInstallationCommand.run(action: .remove, isolatedRoot: root).status, "notInstalled")
    }
    func testNormalCommandRefusesBeforeAnyCheckpointOrImplicitUserLocation() {
        var calls = 0
        let result = PluginInstallationCommand.run(action: .install, isolatedRoot: nil, checkpoint: { calls += 1 })
        XCTAssertEqual(result.status, "unsupported"); XCTAssertEqual(calls, 0)
        XCTAssertFalse(result.nativeActivationVerified)
    }
    func testMissingPayloadOrUnknownExistingBundleRefusesWithoutMutation() throws {
        let root = try fixture(), bundle = target(root).deletingLastPathComponent()
        try FileManager.default.removeItem(at: root.appendingPathComponent("plugin-payload/AU/RemSound.component"))
        XCTAssertEqual(PluginInstallationCommand.run(action: .install, isolatedRoot: root).status, "missingPayload")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library").path))
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("not ours".utf8).write(to: target(root))
        XCTAssertNotEqual(PluginInstallationCommand.run(action: .install, isolatedRoot: root).status, "installed")
        XCTAssertEqual(try Data(contentsOf: target(root)), Data("not ours".utf8))
    }
    func testFailedInstallAndRemoveRestoreExistingFilesAndManifest() throws {
        let root = try fixture()
        XCTAssertEqual(PluginInstallationCommand.run(action: .install, isolatedRoot: root).status, "installed")
        let manifest = root.appendingPathComponent("plugin-installation.json"), before = try Data(contentsOf: manifest)
        let old = try Data(contentsOf: target(root))
        try Data("replacement".utf8).write(to: root.appendingPathComponent("plugin-payload/VST3/RemSound.vst3/Contents/nested/fixture.bin"))
        XCTAssertEqual(PluginInstallationCommand.run(action: .install, isolatedRoot: root, checkpoint: { throw CocoaError(.fileWriteUnknown) }).status, "failed")
        XCTAssertEqual(try Data(contentsOf: target(root)), old); XCTAssertEqual(try Data(contentsOf: manifest), before)
        XCTAssertEqual(PluginInstallationCommand.run(action: .remove, isolatedRoot: root, checkpoint: { throw CocoaError(.fileWriteUnknown) }).status, "failed")
        XCTAssertEqual(try Data(contentsOf: target(root)), old); XCTAssertEqual(try Data(contentsOf: manifest), before)
    }
    func testTamperedOutsideManifestCannotRemoveNeighborAndChangedOwnedFileRefuses() throws {
        let root = try fixture()
        XCTAssertEqual(PluginInstallationCommand.run(action: .install, isolatedRoot: root).status, "installed")
        let manifest = root.appendingPathComponent("plugin-installation.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        var files = try XCTUnwrap(object["files"] as? [[String: String]])
        files.append(["path":"../neighbor.bin", "sha256":String(repeating:"0",count:64)])
        files.append(["path":"neighbor.bin", "sha256":SHA256.hash(data:Data([9])).map{String(format:"%02x",$0)}.joined()])
        object["files"] = files
        try JSONSerialization.data(withJSONObject: object).write(to: manifest)
        let neighbor = root.appendingPathComponent("neighbor.bin"); try Data([9]).write(to: neighbor)
        let result = PluginInstallationCommand.run(action: .remove, isolatedRoot: root)
        XCTAssertEqual(result.status,"removed"); XCTAssertEqual(result.ignoredManifestEntries,2)
        XCTAssertEqual(try Data(contentsOf: neighbor),Data([9]))
        XCTAssertEqual(PluginInstallationCommand.run(action:.install,isolatedRoot:root).status,"installed")
        try Data("foreign changed content".utf8).write(to:target(root))
        XCTAssertEqual(PluginInstallationCommand.run(action:.remove,isolatedRoot:root).status,"refused")
        XCTAssertEqual(try Data(contentsOf:target(root)),Data("foreign changed content".utf8))
    }
    func testSymlinkPayloadAndDestinationAreRefusedWithoutFollowingThem() throws {
        let root=try fixture(),source=root.appendingPathComponent("plugin-payload/AU/RemSound.component/Contents/nested/fixture.bin")
        try FileManager.default.removeItem(at:source)
        try FileManager.default.createSymbolicLink(at:source,withDestinationURL:URL(fileURLWithPath:"/dev/zero"))
        XCTAssertEqual(PluginInstallationCommand.run(action:.install,isolatedRoot:root).status,"refused")
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("Library").path))
    }
    func testCompletePayloadCannotAdoptAnUnownedExistingBundle() throws {
        let root=try fixture(),file=target(root)
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("unowned existing bundle".utf8).write(to:file)
        XCTAssertEqual(PluginInstallationCommand.run(action:.install,isolatedRoot:root).status,"refused")
        XCTAssertEqual(try Data(contentsOf:file),Data("unowned existing bundle".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("plugin-installation.json").path))
    }
    func testDestinationLinkAndBusyCommandDoNotChangeForeignData() throws {
        let root=try fixture(),foreign=root.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at:foreign,withIntermediateDirectories:false)
        try Data([7]).write(to:foreign.appendingPathComponent("sentinel"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("Library"),withDestinationURL:foreign)
        XCTAssertEqual(PluginInstallationCommand.run(action:.install,isolatedRoot:root).status,"refused")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:foreign.path),["sentinel"])
        try FileManager.default.removeItem(at:root.appendingPathComponent("Library"))
        let lock=root.appendingPathComponent(".plugin-command.lock");try Data("somebody else's operation".utf8).write(to:lock)
        XCTAssertEqual(PluginInstallationCommand.run(action:.install,isolatedRoot:root).status,"refused")
        XCTAssertEqual(try Data(contentsOf:lock),Data("somebody else's operation".utf8))
    }
    func testFailedFirstInstallRestoresAbsenceAndLeavesNoPartialManifestOrCandidates() throws {
        let root=try fixture()
        XCTAssertEqual(PluginInstallationCommand.run(action:.install,isolatedRoot:root,checkpoint:{throw CocoaError(.fileWriteUnknown)}).status,"failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("Library").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("plugin-installation.json").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),["plugin-payload"])
    }
    func testPublicOrMissingRootAndOversizedSourceRefuseWithoutFallback() throws {
        let root=try fixture()
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:root.path)
        XCTAssertEqual(PluginInstallationCommand.run(action:.install,isolatedRoot:root).status,"refused")
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path)
        let file=root.appendingPathComponent("plugin-payload/AU/RemSound.component/Contents/nested/fixture.bin")
        let handle=try FileHandle(forWritingTo:file);try handle.truncate(atOffset:32*1024*1024+1);try handle.close()
        XCTAssertEqual(PluginInstallationCommand.run(action:.install,isolatedRoot:root).status,"refused")
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("Library").path))
    }

    func testRepeatedSuccessAndRollbackKeepDescriptorUseBoundedAndLeaveNoTransactionScratch() throws {
        let root=try fixture()
        func descriptors() -> Int { (0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count }
        XCTAssertEqual(PluginInstallationCommand.run(action:.install,isolatedRoot:root).status,"installed")
        XCTAssertEqual(PluginInstallationCommand.run(action:.remove,isolatedRoot:root).status,"removed")
        let baseline=descriptors()
        for _ in 0..<12 {
            autoreleasepool {
                XCTAssertEqual(PluginInstallationCommand.run(action:.install,isolatedRoot:root).status,"installed")
                XCTAssertEqual(PluginInstallationCommand.run(action:.remove,isolatedRoot:root,checkpoint:{throw CocoaError(.fileWriteUnknown)}).status,"failed")
                XCTAssertEqual(PluginInstallationCommand.run(action:.remove,isolatedRoot:root).status,"removed")
            }
        }
        XCTAssertLessThanOrEqual(descriptors(),baseline+2)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(".plugin-command.lock").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("plugin-installation.json").path))
        let names=try FileManager.default.contentsOfDirectory(atPath:root.path)
        XCTAssertFalse(names.contains(where:{$0.hasPrefix(".plugin-")}))
    }

}
