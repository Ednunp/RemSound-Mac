import Foundation
import XCTest
@testable import RemSoundCore

final class SessionDirectedDiscoveryTests: XCTestCase {
    private final class Fixture {
        private let lock = NSLock()
        private var replies: [(String?) -> Void] = []
        private var names: [String] = []
        private var packets: [(Data, Endpoint)] = []
        private var cancellations = 0
        var hosts: [String] { lock.lock(); defer { lock.unlock() }; return names }
        var sent: [(Data, Endpoint)] { lock.lock(); defer { lock.unlock() }; return packets }
        var cancelled: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
        func lookup(_ name: String, reply: @escaping (String?) -> Void) -> () -> Void {
            lock.lock(); names.append(name); replies.append(reply); lock.unlock()
            return { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.cancellations += 1; self.lock.unlock()
            }
        }
        func complete(_ index: Int, _ address: String?) {
            lock.lock(); let reply = replies.indices.contains(index) ? replies[index] : nil; lock.unlock()
            guard let reply else { XCTFail("Expected recorded lookup at index \(index)"); return }
            reply(address)
        }
        func send(_ data: Data, to endpoint: Endpoint) {
            lock.lock(); packets.append((data, endpoint)); lock.unlock()
        }
        func clearPackets() { lock.lock(); packets.removeAll(); lock.unlock() }
        func resetLookupsAfterStoppedSetup() {
            lock.lock(); names.removeAll(); replies.removeAll(); packets.removeAll(); cancellations = 0; lock.unlock()
        }
    }
    private func start(_ session: Session) {
        let ready = expectation(description: "isolated directed session starts")
        session.onChange = { view in
            guard view.running else { return }
            session.onChange = nil; ready.fulfill()
        }
        session.start(password: "isolated directed test", peerAddress: "", send: false, receive: false, plugins: false, name: "Private discovery test")
        wait(for: [ready], timeout: 3)
    }
    func testManualPeerReceivesUnicastAnnouncementAtSparePortWithActualAudioPort() throws {
        let listener = try UDP(port: 0, loopback: true), audio = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: 0, testDiscoveryDestinationPort: listener.boundPort)
        defer { session.shutdown() }; start(session)
        session.testSelectResolvedDirectPeer(name: "127.0.0.1", endpoint: Endpoint("127.0.0.1", audio.boundPort))
        session.testAnnounceDiscovery()
        XCTAssertEqual(session.testDirectedTargets(), ["127.0.0.1"])
        var packet: (Data, Endpoint)?
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if let received = listener.receive() { packet = received; break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertNotNil(packet, "Actual Session should send directed discovery to the isolated spare listener")
        if let packet {
            let info = try JSONDecoder().decode(Announcement.self, from: packet.0)
            XCTAssertEqual(info.AudioPort, session.testPorts.audio)
            XCTAssertNotEqual(info.AudioPort, Wire.audioPort)
            XCTAssertEqual(info.Name, "Private discovery test")
            XCTAssertFalse(info.CanSend); XCTAssertFalse(info.CanReceive)
        }
    }
    func testRememberedHostnameSurvivesRestartResolvesOffOwnerAndNeverSelectsPeer() throws {
        let listener = try UDP(port: 0, loopback: true), fixture = Fixture()
        let session = Session(testPeerPort: 0, discoveryLookup: fixture.lookup,
                              testDiscoveryDestinationPort: listener.boundPort, announcementSender: fixture.send)
        defer { session.shutdown() }; start(session)
        session.testSelectResolvedDirectPeer(name: "Studio.invalid:54321", endpoint: Endpoint("127.0.0.1", listener.boundPort))
        session.stop(); _ = session.testPorts; fixture.resetLookupsAfterStoppedSetup(); start(session)
        session.testAnnounceDiscovery()
        XCTAssertEqual(fixture.hosts, ["Studio.invalid"])
        fixture.complete(0, "127.0.0.2"); _ = session.testPorts
        fixture.clearPackets(); session.testAnnounceDiscovery()
        XCTAssertEqual(Set(fixture.sent.map { $0.1 }), [Endpoint("127.0.0.2", listener.boundPort)])
        XCTAssertTrue(session.testDirectPeerViews().isEmpty, "Discovery hints must not reconnect a saved person")
        XCTAssertEqual(session.testRememberedPeers().all, ["Studio.invalid:54321"])
    }
    func testDefaultOrProtocolPortFixturesCannotEmitOrResolveRememberedDiscoveryHints() throws {
        let audio = try UDP(port: 0, loopback: true)
        for port in [nil, UInt16(0), Wire.discoveryPort, Wire.audioPort, Wire.bridgePort] {
            let fixture = Fixture()
            let session = Session(testPeerPort: 0, discoveryLookup: fixture.lookup,
                                  testDiscoveryDestinationPort: port, announcementSender: fixture.send)
            defer { session.shutdown() }; start(session)
            session.testSelectResolvedDirectPeer(name: "Studio.invalid", endpoint: Endpoint("127.0.0.1", audio.boundPort))
            session.testAnnounceDiscovery()
            XCTAssertTrue(fixture.sent.isEmpty)
            XCTAssertTrue(fixture.hosts.isEmpty)
            XCTAssertTrue(session.testDirectedTargets().isEmpty)
        }
    }
    func testReceivedSourceGetsReplyButMalformedAndOwnPacketsDoNot() throws {
        let listener = try UDP(port: 0, loopback: true), fixture = Fixture()
        let session = Session(testPeerPort: 0, testDiscoveryDestinationPort: listener.boundPort, announcementSender: fixture.send)
        defer { session.shutdown() }; start(session)
        let peer = Announcement(id: UUID(), name: "Other", port: listener.boundPort, send: false, receive: false)
        session.testDiscoveryPacket(Data("malformed".utf8), from: Endpoint("127.0.0.1", listener.boundPort))
        session.testAnnounceDiscovery(); XCTAssertTrue(fixture.sent.isEmpty)
        session.testDiscoveryPacket(try JSONEncoder().encode(peer), from: Endpoint("127.0.0.2", listener.boundPort))
        session.testAnnounceDiscovery()
        XCTAssertEqual(Set(fixture.sent.map { $0.1 }), [Endpoint("127.0.0.2", listener.boundPort)])
        let own = try XCTUnwrap(fixture.sent.first?.0)
        session.testDiscoveryPacket(own, from: Endpoint("127.0.0.3", listener.boundPort))
        XCTAssertEqual(session.testDirectedTargets(), ["127.0.0.2"])
        XCTAssertTrue(session.testVerifiedPeerIdentities().isEmpty)
        XCTAssertTrue(session.testRememberedPeers().all.isEmpty)
    }
    func testClearedAndStoppedLookupsCannotReappearAndNonLoopbackAnswersNeverEmit() throws {
        let listener = try UDP(port: 0, loopback: true), fixture = Fixture()
        let session = Session(testPeerPort: 0, peerLookup: { _, reply in reply("127.0.0.1"); return {} }, discoveryLookup: fixture.lookup,
                              testDiscoveryDestinationPort: listener.boundPort, announcementSender: fixture.send)
        defer { session.shutdown() }; start(session)
        session.testSelectResolvedDirectPeer(name: "Studio.invalid", endpoint: Endpoint("127.0.0.1", listener.boundPort))
        session.stop(); _ = session.testPorts; fixture.resetLookupsAfterStoppedSetup(); start(session); session.testAnnounceDiscovery()
        session.clearRememberedPeers(); _ = session.testPorts; session.testAnnounceDiscovery()
        XCTAssertEqual(fixture.cancelled, 1)
        fixture.complete(0, "127.0.0.2"); _ = session.testPorts
        session.testAnnounceDiscovery(); XCTAssertTrue(fixture.sent.isEmpty)
        let added = expectation(description: "genuinely new Add after clear")
        session.addPeer("New.invalid:\(listener.boundPort)") { result in
            XCTAssertEqual(result, .added(address: "127.0.0.1", remembered: true)); added.fulfill()
        }
        wait(for: [added], timeout: 3)
        session.stop(); _ = session.testPorts; fixture.resetLookupsAfterStoppedSetup(); start(session); session.testAnnounceDiscovery()
        fixture.complete(0, "192.0.2.1"); _ = session.testPorts
        fixture.clearPackets(); session.testAnnounceDiscovery()
        XCTAssertTrue(fixture.sent.isEmpty, "An opted-in isolated fixture still must not emit outside loopback")
        session.stop(); _ = session.testPorts
        session.testAnnounceDiscovery(); XCTAssertTrue(fixture.sent.isEmpty)
    }
    func testKnownServerClassificationRemovesAlreadyHeardSourceAndTypedHints() throws {
        let listener = try UDP(port: 0, loopback: true), fixture = Fixture()
        let session = Session(testPeerPort: 0, testDiscoveryDestinationPort: listener.boundPort, announcementSender: fixture.send)
        defer { session.shutdown() }; start(session)
        session.testSelectResolvedDirectPeer(name: "127.0.0.1", endpoint: Endpoint("127.0.0.1", listener.boundPort))
        let peer = Announcement(id: UUID(), name: "Server", port: listener.boundPort, send: false, receive: false)
        session.testDiscoveryPacket(try JSONEncoder().encode(peer), from: Endpoint("127.0.0.1", listener.boundPort))
        let known = expectation(description: "server classified")
        session.onJamChange = { view in
            guard view.serverStatus.hasPrefix("Join request sent") else { return }
            session.onJamChange = nil; known.fulfill()
        }
        session.connectServer("127.0.0.1:\(listener.boundPort)"); wait(for: [known], timeout: 3)
        fixture.clearPackets(); session.testAnnounceDiscovery()
        XCTAssertTrue(fixture.sent.isEmpty)
        XCTAssertEqual(session.testRememberedPeers().all, ["127.0.0.1"])
    }
}
