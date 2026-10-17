import Foundation
import XCTest
@testable import RemSoundCore

final class SessionAddPeerTests: XCTestCase {
    private final class LookupFixture {
        private let lock = NSLock()
        private var queries: [(String, (String?) -> Void)] = []
        private var cancellations = 0
        var hosts: [String] { lock.lock(); defer { lock.unlock() }; return queries.map { $0.0 } }
        var cancelled: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
        func lookup(_ host: String, reply: @escaping (String?) -> Void) -> () -> Void {
            lock.lock(); queries.append((host, reply)); lock.unlock()
            return { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.cancellations += 1; self.lock.unlock()
            }
        }
        func complete(_ index: Int, _ address: String?) {
            lock.lock(); let reply = queries[index].1; lock.unlock(); reply(address)
        }
    }
    private var listeners: [UDP] = []
    private func endpoint(_ address: String = "127.0.0.1") throws -> Endpoint {
        let listener = try UDP(port: 0, loopback: true)
        listeners.append(listener)
        return Endpoint(address, listener.boundPort)
    }
    private func start(_ session: Session, lockAddresses: Bool = false) {
        let ready = expectation(description: "isolated session ready")
        session.onChange = { view in
            guard view.running else { return }
            session.onChange = nil; ready.fulfill()
        }
        session.start(password: "isolated add test", peerAddress: "", lockPeerAddresses: lockAddresses,
                      send: false, receive: false, plugins: false, name: "Private Add test")
        wait(for: [ready], timeout: 3)
    }
    private func savedEntries(_ session: Session) -> [String] {
        let updated = expectation(description: "selection snapshot")
        var names: [String] = []
        session.onChange = { view in
            names = view.selectedPeerAddresses; session.onChange = nil; updated.fulfill()
        }
        // Same-selection actions force a snapshot without replacing the list's original typed names.
        let views = session.testDirectPeerViews()
        if let peer = views.first(where: \.selected) { session.setSelected(address: peer.address, selected: true) }
        wait(for: [updated], timeout: 3)
        return names
    }

    func testNumericAddPreservesTrimmedPortAndMainThreadResultWithoutDNS() throws {
        let target = try endpoint(), fixture = LookupFixture()
        let session = Session(testPeerPort: target.port, peerLookup: fixture.lookup)
        defer { session.shutdown() }
        start(session)
        let added = expectation(description: "numeric addition")
        session.addPeer("  \(target.address):\(target.port) \n") { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(result, .added(address: target.address, remembered: true)); added.fulfill()
        }
        wait(for: [added], timeout: 3)
        XCTAssertTrue(fixture.hosts.isEmpty)
        XCTAssertEqual(session.testRememberedPeers().all, ["\(target.address):\(target.port)"])
        XCTAssertEqual(savedEntries(session), ["\(target.address):\(target.port)"])
        XCTAssertEqual(session.testDirectPeerViews().filter(\.selected).count, 1)
        XCTAssertTrue(session.testVerifiedPeerIdentities().isEmpty)
    }

    func testHostnameAddIsAsyncPreservesNameAndOriginalPortWithoutChangingOtherSelections() throws {
        let first = try endpoint(), second = try endpoint("127.0.0.2"), fixture = LookupFixture()
        let session = Session(testPeerPort: first.port, peerLookup: fixture.lookup)
        defer { session.shutdown() }; start(session)
        session.testSelectResolvedDirectPeer(name: "127.0.0.1", endpoint: first)
        let added = expectation(description: "hostname addition")
        session.addPeer(" Studio.invalid:\(second.port) ") { result in
            XCTAssertEqual(result, .added(address: second.address, remembered: true)); added.fulfill()
        }
        _ = session.testPorts
        XCTAssertEqual(fixture.hosts, ["Studio.invalid"])
        XCTAssertEqual(session.testRememberedPeers().all, ["127.0.0.1"])
        fixture.complete(0, second.address)
        wait(for: [added], timeout: 3)
        XCTAssertEqual(Set(session.testDirectPeerViews().filter(\.selected).map(\.address)), [first.address, second.address])
        XCTAssertTrue(savedEntries(session).contains("Studio.invalid:\(second.port)"))
        XCTAssertTrue(session.testRememberedPeers().all.contains("Studio.invalid:\(second.port)"))
    }

    func testReplacementAndRepeatedLookupRepliesCannotAddOldPeer() throws {
        let first = try endpoint(), fixture = LookupFixture()
        let session = Session(testPeerPort: first.port, peerLookup: fixture.lookup)
        defer { session.shutdown() }; start(session)
        let obsolete = expectation(description: "replaced Add result suppressed"); obsolete.isInverted = true
        session.addPeer("old.invalid") { _ in obsolete.fulfill() }
        let current = expectation(description: "latest Add succeeds")
        session.addPeer("new.invalid") { result in
            XCTAssertEqual(result, .added(address: "127.0.0.2", remembered: true)); current.fulfill()
        }
        _ = session.testPorts
        XCTAssertEqual(fixture.cancelled, 1)
        fixture.complete(0, "127.0.0.1"); fixture.complete(1, "127.0.0.2"); fixture.complete(1, "127.0.0.3")
        wait(for: [current, obsolete], timeout: 0.2)
        XCTAssertEqual(session.testDirectPeerViews().filter(\.selected).map(\.address), ["127.0.0.2"])
        XCTAssertEqual(session.testRememberedPeers().all, ["new.invalid"])
    }

    func testClearDropsPendingAddButARealNewAddUsesCurrentGeneration() throws {
        let target = try endpoint(), fixture = LookupFixture()
        let session = Session(testPeerPort: target.port, peerLookup: fixture.lookup)
        defer { session.shutdown() }; start(session)
        let obsolete = expectation(description: "clear suppresses result"); obsolete.isInverted = true
        session.addPeer("old.invalid") { _ in obsolete.fulfill() }
        _ = session.testPorts
        session.clearRememberedPeers(); _ = session.testPorts
        XCTAssertEqual(fixture.cancelled, 1)
        fixture.complete(0, "127.0.0.1"); _ = session.testPorts
        XCTAssertTrue(session.testDirectPeerViews().isEmpty)
        XCTAssertTrue(session.testRememberedPeers().all.isEmpty)
        let added = expectation(description: "fresh Add after clear")
        session.addPeer("new.invalid") { result in
            XCTAssertEqual(result, .added(address: "127.0.0.2", remembered: true)); added.fulfill()
        }
        _ = session.testPorts; fixture.complete(1, "127.0.0.2")
        wait(for: [added, obsolete], timeout: 0.2)
        XCTAssertEqual(session.testRememberedPeers().all, ["new.invalid"])
    }

    func testStopRestartAndExplicitCancelSuppressDelayedAdds() throws {
        let target = try endpoint(), fixture = LookupFixture()
        let session = Session(testPeerPort: target.port, peerLookup: fixture.lookup)
        defer { session.shutdown() }; start(session)
        let obsolete = expectation(description: "cancelled results suppressed"); obsolete.isInverted = true
        session.addPeer("old.invalid") { _ in obsolete.fulfill() }
        _ = session.testPorts; session.stop(); _ = session.testPorts
        start(session); fixture.complete(0, "127.0.0.1"); _ = session.testPorts
        XCTAssertTrue(session.testDirectPeerViews().isEmpty)
        session.addPeer("cancel.invalid") { _ in obsolete.fulfill() }
        _ = session.testPorts; session.cancelAddingPeer(); _ = session.testPorts
        fixture.complete(1, "127.0.0.2"); _ = session.testPorts
        wait(for: [obsolete], timeout: 0.15)
        XCTAssertEqual(fixture.cancelled, 2)
        XCTAssertTrue(session.testRememberedPeers().all.isEmpty)
    }

    func testForgetAndQueuedMainThreadDeliveryCannotResurrectOrReportOldResult() throws {
        let target = try endpoint(), fixture = LookupFixture()
        let session = Session(testPeerPort: target.port, peerLookup: fixture.lookup)
        defer { session.shutdown() }; start(session)
        let obsolete = expectation(description: "forgotten queued result suppressed"); obsolete.isInverted = true
        session.addPeer("pending.invalid") { _ in obsolete.fulfill() }
        _ = session.testPorts
        session.forgetRememberedPeer("pending.invalid"); _ = session.testPorts
        fixture.complete(0, "127.0.0.1"); _ = session.testPorts
        session.addPeer("127.0.0.2") { _ in obsolete.fulfill() }
        _ = session.testPorts; _ = session.testPorts // Fence resolution before stopping, without servicing the main queue.
        session.stop(); _ = session.testPorts
        wait(for: [obsolete], timeout: 0.15)
        XCTAssertTrue(session.testDirectPeerViews().isEmpty)
    }

    func testUnresolvedOrInvalidRepliesLeaveStorageAndSelectionsAloneAndAllowRetry() throws {
        let target = try endpoint(), fixture = LookupFixture()
        let session = Session(testPeerPort: target.port, peerLookup: fixture.lookup)
        defer { session.shutdown() }; start(session)
        for answer in [nil, "not an IP"] {
            let failed = expectation(description: "lookup failure")
            session.addPeer("missing.invalid") { result in XCTAssertEqual(result, .unresolved); failed.fulfill() }
            _ = session.testPorts; fixture.complete(fixture.hosts.count - 1, answer)
            wait(for: [failed], timeout: 3)
            XCTAssertTrue(session.testDirectPeerViews().isEmpty)
            XCTAssertTrue(session.testRememberedPeers().all.isEmpty)
        }
        let retry = expectation(description: "retry succeeds")
        session.addPeer("missing.invalid") { result in
            XCTAssertEqual(result, .added(address: "127.0.0.1", remembered: true)); retry.fulfill()
        }
        _ = session.testPorts; fixture.complete(2, "127.0.0.1"); wait(for: [retry], timeout: 3)
    }

    func testNotRunningAndMalformedInputsNeverLaunchDNSOrWriteSettings() throws {
        let target = try endpoint(), fixture = LookupFixture()
        let session = Session(testPeerPort: target.port, peerLookup: fixture.lookup)
        defer { session.shutdown() }
        let stopped = expectation(description: "stopped Add")
        session.addPeer("good.invalid") { result in XCTAssertEqual(result, .notRunning); stopped.fulfill() }
        wait(for: [stopped], timeout: 3); start(session)
        for text in ["", " ", "127.0.0.1:0", "127.0.0.1:65536", "host:abc", "has space", "[::1]", "https://host", "bad\u{0}.invalid"] {
            let invalid = expectation(description: "invalid Add")
            session.addPeer(text) { result in XCTAssertEqual(result, .invalidEntry); invalid.fulfill() }
            wait(for: [invalid], timeout: 3)
        }
        XCTAssertTrue(fixture.hosts.isEmpty)
        XCTAssertTrue(session.testRememberedPeers().all.isEmpty)
    }

    func testKnownServerNameOrNewAliasResolvingToServerIsNeverAddedAsPeer() throws {
        let relay = try UDP(port: 0, loopback: true), target = try endpoint(), fixture = LookupFixture()
        let session = Session(testPeerPort: target.port, serverLookup: { _, reply in reply("127.0.0.1"); return {} }, peerLookup: fixture.lookup)
        defer { session.shutdown() }; start(session)
        let joined = expectation(description: "known server classified")
        session.onJamChange = { view in
            guard view.serverStatus.hasPrefix("Join request sent") else { return }
            session.onJamChange = nil; joined.fulfill()
        }
        session.connectServer("Relay.invalid:\(relay.boundPort)"); wait(for: [joined], timeout: 3)
        let named = expectation(description: "known name refused without DNS")
        session.addPeer("RELAY.invalid:12345") { result in XCTAssertEqual(result, .knownServer); named.fulfill() }
        wait(for: [named], timeout: 3); XCTAssertTrue(fixture.hosts.isEmpty)
        let alias = expectation(description: "resolved alias refused")
        session.addPeer("another.invalid") { result in XCTAssertEqual(result, .knownServer); alias.fulfill() }
        _ = session.testPorts; fixture.complete(0, "127.0.0.1"); wait(for: [alias], timeout: 3)
        XCTAssertTrue(session.testDirectPeerViews().filter(\.selected).isEmpty)
        XCTAssertTrue(session.testRememberedPeers().all.isEmpty)
        XCTAssertNotNil(relay.receive(), "Only the explicit server connection sent a join")
    }

    func testSavedNumericPortRestoresActualOutgoingRouteAndTypedSnapshot() throws {
        let target = try UDP(port: 0, loopback: true), wrongDefault = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: wrongDefault.boundPort)
        defer { session.shutdown() }
        let ready = expectation(description: "saved explicit route ready")
        let entry = "127.0.0.1:\(target.boundPort)"
        session.onChange = { view in
            guard view.running else { return }
            XCTAssertEqual(view.selectedPeerAddresses, [entry])
            session.onChange = nil; ready.fulfill()
        }
        session.start(password: "isolated add test", peerAddress: "", savedPeerAddresses: [entry],
                      lockPeerAddresses: true, send: false, receive: false, plugins: false, name: "Private port restore")
        wait(for: [ready], timeout: 3)
        var delivered = false
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if target.receive() != nil { delivered = true; break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertTrue(delivered, "The actual isolated heartbeat must reach the saved custom port")
        XCTAssertNil(wrongDefault.receive(), "The default port must not receive the saved peer's traffic")
    }

    func testExplicitPortChangeResetsAuthenticatedRouteWithAddressLock() throws {
        let old = try endpoint(), replacement = try endpoint()
        let session = Session(testPeerPort: old.port)
        defer { session.shutdown() }; start(session, lockAddresses: true)
        session.testSelectResolvedDirectPeer(name: "127.0.0.1", endpoint: old)
        let identity = UUID(), key = try Credentials(password: "isolated add test")
        session.testPeerPacket(try key.tick(id: identity, now: Int64(Date().timeIntervalSince1970), sequence: 1), from: old)
        XCTAssertEqual(session.testVerifiedPeerIdentities()[old.address], identity)
        let added = expectation(description: "new port selection")
        session.addPeer("\(replacement.address):\(replacement.port)") { result in
            XCTAssertEqual(result, .added(address: replacement.address, remembered: true)); added.fulfill()
        }
        wait(for: [added], timeout: 3)
        XCTAssertTrue(session.testVerifiedPeerIdentities().isEmpty, "Old-port proof cannot authenticate a new route")
        XCTAssertTrue(savedEntries(session).contains("\(replacement.address):\(replacement.port)"))
    }
}
