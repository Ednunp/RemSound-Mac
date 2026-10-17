import Foundation
import XCTest
@testable import RemSoundCore

final class SessionDirectPeerSelectionTests: XCTestCase {
    func testLiveAddressLockCanChangeWithoutRestartOrLosingSelectedIntent() throws {
        let session = started(lockAddresses: true)
        defer { session.shutdown() }
        let old = try endpoint(), fresh = try endpoint("127.0.0.2")
        session.testSelectResolvedDirectPeer(name: "Studio", endpoint: old)
        try announce(session, id: UUID(), at: fresh)
        XCTAssertEqual(session.testDirectPeerViews().filter(\.selected).map(\.address), [old.address])
        session.setLockPeerAddresses(false)
        XCTAssertEqual(session.testDirectPeerViews().filter(\.selected).map(\.address), [fresh.address])
        XCTAssertEqual(session.testRememberedPeers().all, ["Studio"])
        XCTAssertTrue(session.testVerifiedPeerIdentities().isEmpty)
    }
    func testForgetAndClearReportConfirmedStorageResultOnMainWithoutDisconnectingPeer() throws {
        let session = started()
        defer { session.shutdown() }
        let target = try endpoint()
        session.testSelectResolvedDirectPeer(name: "Studio", endpoint: target)
        let forgotten = expectation(description: "main-thread forget result")
        session.forgetRememberedPeer("Studio") { saved in
            XCTAssertTrue(Thread.isMainThread); XCTAssertTrue(saved); forgotten.fulfill()
        }
        wait(for: [forgotten], timeout: 3)
        XCTAssertTrue(session.testRememberedPeers().all.isEmpty)
        XCTAssertEqual(session.testDirectPeerViews().filter(\.selected).map(\.address), [target.address])
        session.setSelected(address: target.address, selected: true)
        _ = session.testPorts
        let cleared = expectation(description: "main-thread clear result")
        session.clearRememberedPeers { saved in
            XCTAssertTrue(Thread.isMainThread); XCTAssertTrue(saved); cleared.fulfill()
        }
        wait(for: [cleared], timeout: 3)
        XCTAssertTrue(session.testRememberedPeers().all.isEmpty)
        XCTAssertEqual(session.testDirectPeerViews().filter(\.selected).map(\.address), [target.address])
    }

    func testSelectedDiscoveryRemembersAdvertisedNameAndUntickingReturnsAvailableEntry() throws {
        let session = started(aliases: ["127.0.0.1": "Friendly alias"])
        defer { session.shutdown() }
        let pin = try endpoint()
        try announce(session, id: UUID(), at: pin)
        session.setSelected(address: pin.address, selected: true)
        XCTAssertEqual(session.testRememberedPeers().all, ["Studio"])
        XCTAssertEqual(session.testRememberedPeers().available, [])
        session.setSelected(address: pin.address, selected: false)
        XCTAssertEqual(session.testRememberedPeers().available, ["Studio"])
    }

    func testTwoSameNamedInstancesAreRememberedByTheirAddresses() throws {
        let session = started()
        defer { session.shutdown() }
        let first = try endpoint(), second = try endpoint("127.0.0.2")
        try announce(session, id: UUID(), at: first)
        try announce(session, id: UUID(), name: "STUDIO", at: second)
        session.setSelected(address: first.address, selected: true)
        session.setSelected(address: second.address, selected: true)
        XCTAssertEqual(session.testRememberedPeers().all, [first.address, second.address])
        XCTAssertTrue(session.testRememberedPeers().available.isEmpty)
    }

    func testClearSurvivesAnnouncementsAndOldResolvedCallbacksUntilExplicitRetick() throws {
        let session = started()
        defer { session.shutdown() }
        let first = try endpoint(), second = try endpoint("127.0.0.2")
        session.testSelectResolvedDirectPeer(name: "Studio", endpoint: first)
        XCTAssertEqual(session.testRememberedPeers().all, ["Studio"])
        session.clearRememberedPeers()
        XCTAssertEqual(session.testRememberedPeers().all, [])
        try announce(session, id: UUID(), at: second)
        session.testSelectResolvedDirectPeer(name: "Old pending name", endpoint: first)
        XCTAssertEqual(session.testRememberedPeers().all, [])
        session.setSelected(address: second.address, selected: true)
        XCTAssertEqual(session.testRememberedPeers().all, ["Studio"])
    }

    func testRememberedMappingFollowsActualManualDiscoveryMergeAndForgetDoesNotUntick() throws {
        let session = started()
        defer { session.shutdown() }
        let first = try endpoint(), second = try endpoint("127.0.0.2")
        session.testSelectResolvedDirectPeer(name: "Studio", endpoint: first)
        try announce(session, id: UUID(), at: second)
        XCTAssertEqual(session.testRememberedPeers().all, ["Studio"])
        XCTAssertTrue(session.testRememberedPeers().available.isEmpty)
        session.forgetRememberedPeer("STUDIO")
        XCTAssertEqual(session.testRememberedPeers().all, [])
        XCTAssertEqual(session.testDirectPeerViews().filter(\.selected).map(\.address), [second.address])
    }

    func testKnownServerIsExcludedFromRememberedAvailableRowsWithoutDestroyingStoredEntry() throws {
        let server = try UDP(port: 0, loopback: true)
        let session = started()
        defer { session.shutdown() }
        session.testSelectResolvedDirectPeer(name: "127.0.0.1", endpoint: Endpoint("127.0.0.1", server.boundPort))
        XCTAssertEqual(session.testRememberedPeers().all, ["127.0.0.1"])
        session.connectServer("127.0.0.1:\(server.boundPort)")
        let classified = expectation(description: "server classification reaches snapshot")
        session.onJamChange = { view in
            if view.serverStatus.contains("Join request sent") {
                session.onJamChange = nil
                classified.fulfill()
            }
        }
        wait(for: [classified], timeout: 3)
        session.setSelected(address: "127.0.0.1", selected: false)
        XCTAssertEqual(session.testRememberedPeers().all, ["127.0.0.1"])
        XCTAssertEqual(session.testRememberedPeers().available, [])
        session.shutdown()
        XCTAssertEqual(session.testRememberedPeers().available, [])
    }

    func testWhitespaceDiscoveryNameFollowsTypedName() throws {
        let session = started()
        defer { session.shutdown() }
        session.testSelectResolvedDirectPeer(name: "Studio", endpoint: try endpoint())
        try announce(session, id: UUID(), name: "  Studio \n", at: endpoint("127.0.0.2"))
        XCTAssertEqual(session.testDirectPeerViews().filter(\.selected).map(\.address), ["127.0.0.2"])
        XCTAssertEqual(session.testDirectPeerViews().first(where: { $0.address == "127.0.0.2" })?.name, "Studio")
    }

    func testBlankDiscoveryNameFallsBackToAddress() throws {
        let session = started()
        defer { session.shutdown() }
        let first = try endpoint(), second = try endpoint("127.0.0.2")
        try announce(session, id: UUID(), name: "", at: first)
        try announce(session, id: UUID(), name: " \t\n", at: second)
        XCTAssertEqual(session.testDirectPeerViews().first(where: { $0.address == first.address })?.name, first.address)
        XCTAssertEqual(session.testDirectPeerViews().first(where: { $0.address == second.address })?.name, second.address)
    }

    func testDiscoveryNameRetainsOneHundredTwentyEightCharacters() throws {
        let session = started()
        defer { session.shutdown() }
        let pin = try endpoint()
        try announce(session, id: UUID(), name: String(repeating: "x", count: 160), at: pin)
        XCTAssertEqual(session.testDirectPeerViews().first?.name, String(repeating: "x", count: 128))
    }

    private var listeners: [UDP] = []
    private func endpoint(_ address: String = "127.0.0.1") throws -> Endpoint {
        let listener = try UDP(port: 0, loopback: true)
        listeners.append(listener)
        return Endpoint(address, listener.boundPort)
    }
    private func announce(_ session: Session, id: UUID, name: String = "Studio", at endpoint: Endpoint) throws {
        let announcement = Announcement(id: id, name: name, port: endpoint.port, send: false, receive: false)
        session.testDiscoveryPacket(try JSONEncoder().encode(announcement), from: endpoint)
    }
    private func started(lockAddresses: Bool = false, mixes: [String: PeerMix] = [:], aliases: [String: String] = [:]) -> Session {
        let session = Session(testPeerPort: 0)
        let ready = expectation(description: "isolated stopped-audio session ready")
        session.onChange = { view in
            guard view.running else { return }
            session.onChange = nil
            ready.fulfill()
        }
        session.start(password: "isolated identity selection", peerAddress: "", lockPeerAddresses: lockAddresses,
            send: false, receive: false, plugins: false, name: "Private identity test",
            peerMixes: mixes, peerAliases: aliases)
        wait(for: [ready], timeout: 3)
        return session
    }

    func testUnansweredTypedNameFollowsUniqueDiscoveredInstanceWithoutVerifyingIt() throws {
        let session = started()
        defer { session.shutdown() }
        session.testSelectResolvedDirectPeer(name: "Studio", endpoint: try endpoint())
        try announce(session, id: UUID(), at: endpoint("127.0.0.2"))
        XCTAssertEqual(session.testDirectPeerViews().filter(\.selected).map(\.address), ["127.0.0.2"])
        XCTAssertTrue(session.testVerifiedPeerIdentities().isEmpty,
            "An unsigned discovery identity must never become a password-verified audio identity")
    }

    func testAddressLockKeepsTypedEndpointEvenWhenDiscoveryReportsSameName() throws {
        let session = started(lockAddresses: true)
        defer { session.shutdown() }
        let pin = try endpoint()
        session.testSelectResolvedDirectPeer(name: "Studio", endpoint: pin)
        try announce(session, id: UUID(), at: endpoint("127.0.0.2"))
        XCTAssertEqual(session.testDirectPeerViews().filter(\.selected).map(\.address), [pin.address])
    }

    func testAlreadyDiscoveredDuplicateNamesDoNotSelectEitherByName() throws {
        let session = started()
        defer { session.shutdown() }
        try announce(session, id: UUID(), name: "Studio", at: endpoint("127.0.0.2"))
        try announce(session, id: UUID(), name: "STUDIO", at: endpoint("127.0.0.3"))
        let pin = try endpoint()
        session.testSelectResolvedDirectPeer(name: "Studio", endpoint: pin)
        XCTAssertEqual(session.testDirectPeerViews().filter(\.selected).map(\.address), [pin.address])
    }

    func testKnownDiscoveryIdentityCannotMergeIntoOtherSameNamedDevice() throws {
        let session = started()
        defer { session.shutdown() }
        let pin = try endpoint()
        let first = UUID()
        try announce(session, id: first, at: pin)
        session.setSelected(address: pin.address, selected: true)
        _ = session.testDirectPeerViews()
        try announce(session, id: UUID(), at: endpoint("127.0.0.2"))
        XCTAssertEqual(session.testDirectPeerViews().filter(\.selected).map(\.address), [pin.address])
    }

    func testMalformedOrEmptyInstanceAnnouncementsCannotEnterSelectionBook() throws {
        let session = started()
        defer { session.shutdown() }
        try announce(session, id: DirectPeerSelectionPolicy.emptyInstanceID, at: endpoint())
        session.testDiscoveryPacket(Data("not JSON".utf8), from: try endpoint())
        XCTAssertTrue(session.testDirectPeerViews().isEmpty)
    }

    func testMoveCopiesMixAndAliasWithoutOverwritingExplicitDestinationChoices() throws {
        let old = try endpoint(), new = try endpoint("127.0.0.2")
        let mix = PeerMix(volume: 42, pan: -20)
        let session = started(mixes: [old.address: mix], aliases: [old.address: "Friendly"])
        defer { session.shutdown() }
        let moved = expectation(description: "main-thread owner receives move")
        session.onDirectPeerMove = { from, to in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(from, old.address)
            XCTAssertEqual(to, new.address)
            moved.fulfill()
        }
        session.testSelectResolvedDirectPeer(name: "Studio", endpoint: old)
        try announce(session, id: UUID(), at: new)
        wait(for: [moved], timeout: 2)
        XCTAssertEqual(session.testDirectPeerSettings().mixes[new.address], mix)
        XCTAssertEqual(session.testDirectPeerSettings().aliases[new.address], "Friendly")
        XCTAssertEqual(session.testDirectPeerViews().first(where: { $0.address == new.address })?.name, "Friendly")
        XCTAssertEqual(session.testDirectPeerSettings().mixes[old.address], mix)
    }

    func testDuplicateMergePreservesAlreadyVerifiedDestinationAndItsExplicitMix() throws {
        let old = try endpoint(), new = try endpoint("127.0.0.2")
        let identity = UUID(), explicit = PeerMix(volume: 17)
        let session = started(mixes: [old.address: PeerMix(volume: 42), new.address: explicit])
        defer { session.shutdown() }
        try announce(session, id: identity, at: new)
        session.setSelected(address: new.address, selected: true)
        _ = session.testDirectPeerViews()
        let key = try Credentials(password: "isolated identity selection")
        session.testPeerPacket(try key.tick(id: identity, now: Int64(Date().timeIntervalSince1970), sequence: 1), from: new)
        XCTAssertEqual(session.testVerifiedPeerIdentities()[new.address], identity)
        session.testSelectResolvedDirectPeer(name: "Studio", endpoint: old)
        XCTAssertEqual(session.testDirectPeerViews().filter(\.selected).map(\.address), [new.address])
        XCTAssertEqual(session.testVerifiedPeerIdentities()[new.address], identity)
        XCTAssertEqual(session.testDirectPeerSettings().mixes[new.address], explicit)
    }

    func testStoppedGenerationDropsQueuedOwnerMove() throws {
        let session = started()
        let delivered = expectation(description: "obsolete owner move is not delivered")
        delivered.isInverted = true
        session.onDirectPeerMove = { _, _ in delivered.fulfill() }
        session.testSelectResolvedDirectPeer(name: "Studio", endpoint: try endpoint())
        try announce(session, id: UUID(), at: endpoint("127.0.0.2"))
        session.shutdown()
        wait(for: [delivered], timeout: 0.15)
        XCTAssertTrue(session.testDirectPeerViews().isEmpty)
    }
}
