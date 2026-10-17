import Foundation
import XCTest
@testable import RemSoundRuntime

final class RememberedPeerConnectionsTests: XCTestCase {
    func testKnownServerQueryUsesOriginalNameOrResolvedAddressAndSurvivesRuntimeReset() throws {
        let (settings, _) = try settings()
        let owner = RememberedPeerConnections(settings: settings)
        owner.noteServer(entry: " Relay.invalid:54321 ", address: "192.0.2.1")
        XCTAssertTrue(owner.isKnownServer(entry: "relay.INVALID:12345"))
        XCTAssertTrue(owner.isKnownServer(entry: "new.invalid", address: "192.0.2.1"))
        XCTAssertFalse(owner.isKnownServer(entry: "new.invalid", address: "192.0.2.2"))
        owner.resetRuntime()
        XCTAssertTrue(owner.isKnownServer(entry: "192.0.2.1:23456"))
        XCTAssertTrue(owner.entries.isEmpty, "Server classification must not write a remembered person")
    }

    private func settings() throws -> (SettingsStore, URL) {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("remembered-owner-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.plist")
        return (try SettingsStore(file: file), file)
    }
    private func peer(_ name: String = "Studio", address: String = "192.0.2.1", id: UUID = UUID()) -> RememberedPeerIdentity {
        .init(instanceID: id, advertisedName: name, address: address)
    }
    private func row(_ peer: RememberedPeerIdentity, selected: Bool = true, server: Bool = false) -> RememberedPeerConnection {
        .init(identity: peer, selected: selected, isKnownServer: server)
    }

    func testPassiveProfileSnapshotDoesNotRememberSelectionsOrWriteSettings() throws {
        let (settings, path) = try settings(), identity = peer()
        let owner = RememberedPeerConnections(settings: settings)
        owner.update([row(identity)])
        XCTAssertEqual(owner.entries, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testExplicitSelectionRemembersAdvertisedNameAndConnectedEntryIsHidden() throws {
        let (settings, _) = try settings(), identity = peer()
        let owner = RememberedPeerConnections(settings: settings)
        XCTAssertTrue(owner.rememberDiscovered(identity, among: [identity]))
        owner.update([row(identity)])
        XCTAssertEqual(owner.entries, ["Studio"])
        XCTAssertEqual(owner.availableEntries, [])
        owner.update([row(identity, selected: false)])
        XCTAssertEqual(owner.availableEntries, ["Studio"])
    }

    func testCollisionUsesDistinctAddressesAndDualAddressesOfOneIDDoNotCollide() throws {
        let (settings, _) = try settings(), first = peer(), second = peer("STUDIO", address: "192.0.2.2")
        let owner = RememberedPeerConnections(settings: settings)
        owner.rememberDiscovered(first, among: [first, second])
        owner.rememberDiscovered(second, among: [first, second])
        XCTAssertEqual(owner.entries, [first.address, second.address])
        let duplicateRoute = peer(address: "192.0.2.3", id: first.instanceID)
        owner.rememberDiscovered(first, among: [first, duplicateRoute])
        XCTAssertEqual(owner.entries.last, "Studio")
    }

    func testManualOriginalTextRedirectsToDiscoveredIdentityWithoutDuplicateEntry() throws {
        let (settings, _) = try settings(), manual = peer("192.0.2.1"), found = peer(address: "192.0.2.2")
        let owner = RememberedPeerConnections(settings: settings)
        owner.rememberManual("  Studio:54321  ", peer: manual)
        owner.redirect(address: manual.address, to: found)
        owner.update([row(found)])
        XCTAssertEqual(owner.entries, ["Studio:54321"])
        XCTAssertTrue(owner.availableEntries.isEmpty)
        owner.update([row(found, selected: false)])
        XCTAssertEqual(owner.availableEntries, ["Studio:54321"])
    }

    func testRestartBindsUniqueNameWithoutRewritingSettingsAndNeverBindsAmbiguousName() throws {
        let (settings, path) = try settings(), identity = peer()
        RememberedPeerPreferences(settings: settings).remember("Studio")
        let bytes = try Data(contentsOf: path)
        let owner = RememberedPeerConnections(settings: try SettingsStore(file: path))
        owner.update([row(identity), row(peer("STUDIO", address: "192.0.2.2"))])
        XCTAssertEqual(owner.availableEntries, ["Studio"])
        owner.update([row(identity)])
        XCTAssertTrue(owner.availableEntries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }

    func testExistingIdentityMappingDoesNotFollowOtherSameNamedInstance() throws {
        let (settings, _) = try settings(), old = peer(), other = peer(address: "192.0.2.2")
        let owner = RememberedPeerConnections(settings: settings)
        owner.rememberDiscovered(old, among: [old])
        owner.update([row(other)])
        XCTAssertEqual(owner.availableEntries, ["Studio"])
    }

    func testResetShowsRememberedEntriesAndKeepsMachineBookAcrossProfiles() throws {
        let (settings, path) = try settings(), identity = peer()
        let owner = RememberedPeerConnections(settings: settings)
        owner.rememberDiscovered(identity, among: [identity])
        owner.update([row(identity)])
        owner.resetRuntime()
        XCTAssertEqual(owner.availableEntries, ["Studio"])
        XCTAssertEqual(RememberedPeerConnections(settings: try SettingsStore(file: path)).entries, ["Studio"])
    }

    func testClearDoesNotResurrectFromSelectedSnapshotsOrLateOldLookup() throws {
        let (settings, path) = try settings(), identity = peer()
        let owner = RememberedPeerConnections(settings: settings), generation = UUID()
        owner.rememberDiscovered(identity, among: [identity])
        let request = owner.generation
        XCTAssertTrue(owner.clear())
        owner.update([row(identity)])
        XCTAssertFalse(owner.rememberManual("Studio", peer: identity, generation: request))
        XCTAssertFalse(owner.rememberManual("Studio", peer: identity, generation: generation))
        XCTAssertEqual(owner.entries, [])
        XCTAssertEqual(RememberedPeerConnections(settings: try SettingsStore(file: path)).entries, [])
        XCTAssertTrue(owner.rememberDiscovered(identity, among: [identity]), "A fresh explicit selection may remember again")
    }

    func testForgetIsCaseInsensitiveAndDoesNotReturnThroughRefresh() throws {
        let (settings, _) = try settings(), identity = peer()
        let owner = RememberedPeerConnections(settings: settings)
        owner.rememberDiscovered(identity, among: [identity])
        XCTAssertTrue(owner.forget("  STUDIO  "))
        owner.update([row(identity, selected: false)])
        XCTAssertEqual(owner.availableEntries, [])
    }

    func testKnownServerEntryAndAddressAreExcludedEvenAfterRuntimeReset() throws {
        let (settings, _) = try settings(), server = peer("Relay", address: "192.0.2.9")
        let owner = RememberedPeerConnections(settings: settings)
        RememberedPeerPreferences(settings: settings).replace(with: ["Relay.local:47830", server.address, "Person"])
        owner.noteServer(entry: " relay.LOCAL:47830 ", address: server.address)
        owner.update([row(server, selected: false, server: true)])
        XCTAssertFalse(owner.rememberManual("relay.local", peer: server))
        XCTAssertFalse(owner.rememberDiscovered(server, among: [server], isKnownServer: true))
        XCTAssertEqual(owner.availableEntries, ["Person"])
        owner.resetRuntime()
        XCTAssertEqual(owner.availableEntries, ["Person"])
    }

    func testFailedRememberOrClearRetainsSavedEntriesAndNeverCreatesPhantomMapping() throws {
        let (settings, path) = try settings(), identity = peer()
        let owner = RememberedPeerConnections(settings: settings)
        owner.rememberManual("Existing", peer: identity)
        let root = path.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        XCTAssertFalse(owner.rememberManual("Unsaved", peer: identity))
        XCTAssertFalse(owner.clear())
        XCTAssertEqual(owner.entries, ["Existing"])
        XCTAssertTrue(settings.persistenceFailed)
    }
}
