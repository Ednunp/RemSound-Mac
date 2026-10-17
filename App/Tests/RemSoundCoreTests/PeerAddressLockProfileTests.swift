import Foundation
import XCTest
@testable import RemSoundCore

final class PeerAddressLockProfileTests: XCTestCase {
    private func profile(_ title: String = "Connectivity") -> ConnectionProfile {
        ConnectionProfile(title: title, displayName: "Test", manualPeerAddress: "192.0.2.1",
            selectedPeerAddresses: ["192.0.2.1"], sendInput: false, receiveAudio: true,
            allowPlugins: true, reconnectOnOpen: false)
    }

    private func encoded(_ profile: ConnectionProfile) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
    }

    private func decoding(_ values: [String: Any]) throws -> ConnectionProfile {
        try JSONDecoder().decode(ConnectionProfile.self,
            from: JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]))
    }

    func testNewAndLegacyProfilesDefaultToUnlockedAddresses() throws {
        XCTAssertEqual(try encoded(profile())["lockPeerAddresses"] as? Bool, false)
        var values = try encoded(profile())
        values.removeValue(forKey: "lockPeerAddresses")
        XCTAssertEqual(try encoded(decoding(values))["lockPeerAddresses"] as? Bool, false)
        values["lockPeerAddresses"] = NSNull()
        XCTAssertEqual(try encoded(decoding(values))["lockPeerAddresses"] as? Bool, false)
    }

    func testExplicitLockRoundTripsAndOpeningDoesNotRewriteLegacyBytes() throws {
        let directory = try IsolatedTestDirectory.make("address-lock-profile")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = profile()
        var values = try encoded(original)
        values["lockPeerAddresses"] = true
        let raw = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        let file = directory.appendingPathComponent("\(original.id.uuidString).json")
        try raw.write(to: file)
        let store = ProfileStore(directory: directory)
        let loaded = try store.load(id: original.id)
        XCTAssertEqual(try encoded(loaded)["lockPeerAddresses"] as? Bool, true)
        XCTAssertEqual(try store.list(), [loaded])
        XCTAssertEqual(try Data(contentsOf: file), raw)
        try store.save(loaded)
        XCTAssertEqual(try encoded(store.load(id: original.id))["lockPeerAddresses"] as? Bool, true)
    }

    func testLockContributesToDirtyEqualityWithoutChangingPeerSelections() throws {
        let original = profile()
        var values = try encoded(original)
        values["lockPeerAddresses"] = true
        let locked = try decoding(values)
        XCTAssertNotEqual(locked, original)
        XCTAssertEqual(locked.selectedPeerAddresses, original.selectedPeerAddresses)
        XCTAssertEqual(locked.manualPeerAddress, original.manualPeerAddress)
    }

    func testAddressLockIsIndependentOfReadOnlyProfileLock() throws {
        var values = try encoded(profile())
        values["lockPeerAddresses"] = true
        values["readOnly"] = false
        let addressLocked = try decoding(values)
        XCTAssertFalse(addressLocked.readOnly)
        XCTAssertEqual(try encoded(addressLocked)["lockPeerAddresses"] as? Bool, true)
        values["lockPeerAddresses"] = false
        values["readOnly"] = true
        let readOnly = try decoding(values)
        XCTAssertTrue(readOnly.readOnly)
        XCTAssertEqual(try encoded(readOnly)["lockPeerAddresses"] as? Bool, false)
    }

    func testDifferentProfilesRetainTheirOwnAddressLock() throws {
        let directory = try IsolatedTestDirectory.make("address-lock-two-profiles")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        var values = try encoded(profile("Locked addresses"))
        values["lockPeerAddresses"] = true
        let locked = try decoding(values)
        let unlocked = profile("Follow names")
        try store.save(locked)
        try store.save(unlocked)
        XCTAssertEqual(try encoded(store.load(id: locked.id))["lockPeerAddresses"] as? Bool, true)
        XCTAssertEqual(try encoded(store.load(id: unlocked.id))["lockPeerAddresses"] as? Bool, false)
    }

    func testMalformedLockIsRejectedRatherThanSilentlyUnlocked() throws {
        var values = try encoded(profile())
        values["lockPeerAddresses"] = "true"
        XCTAssertThrowsError(try decoding(values))
        values["lockPeerAddresses"] = [true]
        XCTAssertThrowsError(try decoding(values))
    }
}
