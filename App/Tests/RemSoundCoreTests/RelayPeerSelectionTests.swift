import XCTest
import RemSoundJam
@testable import RemSoundCore

final class RelayPeerSelectionTests: XCTestCase {
    private let memberID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let memberAddress = "240.105.23.114"

    func testSavedMemberArrivingAfterJoinKeepsSelectionAcrossEmptyRoster() throws {
        try exerciseSelection(untick: false)
    }

    func testExplicitUntickSurvivesEmptyRosterAndMemberReturn() throws {
        try exerciseSelection(untick: true)
    }

    func testNewSessionWithoutSavedPeersDoesNotRestorePreviousRelayTicks() throws {
        try exerciseSelection(untick: false, restart: true)
    }

    private func exerciseSelection(untick: Bool, restart: Bool = false) throws {
        let relay = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: relay.boundPort)
        defer { session.shutdown() }
        observe(session, description: "saved virtual peer selected", matching: { view in
            view.running && view.peers.contains { $0.address == self.memberAddress }
        }) {
            session.start(password: "isolated relay selection fixture", peerAddress: memberAddress,
                send: false, receive: false, plugins: false, name: "Selection fixture")
        }
        session.connectServer("127.0.0.1:\(relay.boundPort)")
        let target = try receiveHello(relay).1
        observe(session, description: "initial empty roster hides peer", matching: { view in
            view.running && !view.peers.contains { JamWire.isMemberAddress($0.address) }
        }, check: { view in
            XCTAssertTrue(view.selectedPeerAddresses.contains(self.memberAddress),
                "An empty roster must not erase the saved selection")
        }) { sendRoster([], relay: relay, target: target) }
        observeMember(session, selected: true) { sendRoster([memberID], relay: relay, target: target) }
        XCTAssertTrue(try helloTicks(relay).contains(memberID), "The relay must receive the restored tick")
        if untick {
            observeMember(session, selected: false) {
                session.setSelected(address: memberAddress, selected: false)
            }
        }
        // Someone off the server's list who is not ticked stays a while as "(gone)" (Windows RelayGoneGrace).
        observe(session, description: "member temporarily absent", matching: { view in
            view.running && !view.peers.contains { JamWire.isMemberAddress($0.address) && !$0.name.hasSuffix(" (gone)") }
        }, check: { view in
            XCTAssertEqual(view.selectedPeerAddresses.contains(self.memberAddress), !untick)
        }) { sendRoster([], relay: relay, target: target) }
        XCTAssertEqual(try helloTicks(relay).contains(memberID), !untick,
            "A missing member must retain the tick, but an explicit untick must remove it")
        observeMember(session, selected: !untick) {
            sendRoster([memberID], relay: relay, target: target)
        }
        guard restart else { return }
        observe(session, description: "old session stopped", matching: { !$0.running && $0.status == "Stopped" }) {
            session.stop()
        }
        while relay.receive() != nil {}
        observe(session, description: "new session has no saved selections", matching: { $0.running }, check: { view in
            XCTAssertTrue(view.selectedPeerAddresses.isEmpty)
        }) {
            session.start(password: "different isolated relay fixture", peerAddress: "",
                send: false, receive: false, plugins: false, name: "New selection fixture")
        }
        session.connectServer("127.0.0.1:\(relay.boundPort)")
        let newTarget = try receiveHello(relay).1
        observeMember(session, selected: false) {
            sendRoster([memberID], relay: relay, target: newTarget)
        }
        XCTAssertFalse(try helloTicks(relay).contains(memberID), "Ticks must not leak into a different session")
    }

    private func observeMember(_ session: Session, selected: Bool, action: () -> Void) {
        observe(session, description: "member roster update", matching: { view in
            view.peers.contains { $0.address == self.memberAddress && $0.name == "Fixture (on the server)" }
        }, check: { view in
            XCTAssertEqual(view.peers.first { $0.address == self.memberAddress }?.selected, selected)
        }, action: action)
    }

    private func observe(_ session: Session, description: String,
        matching: @escaping (SessionView) -> Bool, check: @escaping (SessionView) -> Void = { _ in },
        action: () -> Void) {
        let ready = expectation(description: description)
        var completed = false
        session.onChange = { view in
            guard !completed, matching(view) else { return }
            completed = true
            session.onChange = nil
            check(view)
            ready.fulfill()
        }
        action()
        wait(for: [ready], timeout: 3)
    }

    private func sendRoster(_ ids: [UUID], relay: UDP, target: Endpoint) {
        var packet = JamWire.header(JamWire.Kind.roster.rawValue, version: JamWire.groupVersion)
            + [UInt8](repeating: 0, count: JamWire.clientIdSize) + [UInt8(ids.count)]
        for id in ids {
            let name = Array("Fixture".utf8)
            packet += JamWire.bytes(of: id) + name
                + [UInt8](repeating: 0, count: RelayGroupClient.nameBytes - name.count) + [0, 1]
        }
        XCTAssertTrue(relay.send(Data(packet), to: target))
    }

    private func receiveHello(_ relay: UDP) throws -> (Data, Endpoint) {
        let header = Data(JamWire.header(JamWire.Kind.hello.rawValue, version: JamWire.groupVersion))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let (packet, target) = relay.receive(), packet.starts(with: header) { return (packet, target) }
            Thread.sleep(forTimeInterval: 0.005)
        }
        throw NSError(domain: "RelayPeerSelectionTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Loopback relay did not receive a hello"])
    }

    private func helloTicks(_ relay: UDP) throws -> Set<UUID> {
        // Discard queued hellos from the prior roster before reading the next periodic update.
        while relay.receive() != nil {}
        let packet = [UInt8](try receiveHello(relay).0)
        let countOffset = JamWire.groupHeaderSize + RelayGroupClient.nameBytes + JamWire.fingerprintSize
        let count = Int(packet[countOffset])
        XCTAssertEqual(packet.count, countOffset + 1 + count * JamWire.clientIdSize)
        return Set((0..<count).map { index in
            let begin = countOffset + 1 + index * JamWire.clientIdSize
            return JamWire.uuid(from: packet[begin..<(begin + JamWire.clientIdSize)])
        })
    }
}
