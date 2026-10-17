import XCTest

@testable import RemSoundJam

/// The server connection, against a stand-in relay: the packets are the Windows RemSound's and the relay's
/// (server/remsound-relay.py), byte for byte. The real relay is exercised by LiveRelayTests.
final class RelayGroupClientTests: XCTestCase {
    let relay = JamEndpoint("192.168.1.82", 47830)
    let ed = UUID(uuidString: "2799B404-2F06-4323-B9A2-D30D27664C3C")!
    let andre = UUID(uuidString: "0033A815-0B74-4F47-9EF6-88E4C064FC20")!
    let fingerprint: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
    var sent: [([UInt8], JamEndpoint)] = []

    func client() -> RelayGroupClient {
        let c = RelayGroupClient(clientId: andre)
        c.send = { [unowned self] bytes, to in sent.append((bytes, to)) }
        c.setIdentity(name: "Andre's Mac", fingerprint: fingerprint)
        return c
    }

    /// A member list as the relay sends it: 28-byte group header (from the server's own id, all zeros), a count, each entry
    /// (id, 32-byte name, flags: bit 0 ticks us), then the list's flags byte.
    func roster(_ entries: [(UUID, String, Bool)], v1Paired: Bool = false) -> [UInt8] {
        var p = JamWire.header(7, version: 2)
        p.append(contentsOf: [UInt8](repeating: 0, count: 16))
        p.append(UInt8(entries.count))
        for (id, name, ticks) in entries {
            p.append(contentsOf: JamWire.bytes(of: id))
            p.append(contentsOf: RelayGroupClient.encodeName(name))
            p.append(ticks ? 1 : 0)
        }
        p.append(v1Paired ? 1 : 0)
        return p
    }

    func testHelloIsTheRelaysLayoutWithTheTickedFirst() {
        let c = client()
        c.connect(relay)
        let carol = UUID()
        c.setTicked([ed, carol])
        _ = c.handleInbound(roster([(ed, "ED_DT", true)]), from: relay, now: 0)
        sent = []
        c.tick(now: 10)
        XCTAssertEqual(sent.count, 1, "a hello at once")
        let (hello, to) = sent[0]
        XCTAssertEqual(to, relay)
        XCTAssertEqual(Array(hello[0..<4]), Array("RMND".utf8))
        XCTAssertEqual(hello[4], 2, "group framing")
        XCTAssertEqual(hello[5], 6, "hello")
        XCTAssertEqual(Array(hello[12..<28]), JamWire.bytes(of: andre), "our client id")
        XCTAssertEqual(RelayGroupClient.decodeName(hello[28..<60]), "Andre's Mac")
        XCTAssertEqual(Array(hello[60..<68]), fingerprint, "the group tag is the password fingerprint")
        XCTAssertEqual(hello[68], 2, "two ticked")
        XCTAssertEqual(Array(hello[69..<85]), JamWire.bytes(of: ed), "the one on the server now goes first")
        XCTAssertEqual(hello.count, 69 + 32)
        sent = []
        c.tick(now: 11)
        XCTAssertTrue(sent.isEmpty, "not again within 2 s")
        c.tick(now: 12)
        XCTAssertEqual(sent.count, 1, "and again after 2 s")
    }

    func testNoPasswordNoHello() {
        let c = RelayGroupClient(clientId: andre)
        c.send = { [unowned self] b, t in sent.append((b, t)) }
        c.setIdentity(name: "Mac", fingerprint: nil)
        c.connect(relay)
        c.tick(now: 5)
        XCTAssertTrue(sent.isEmpty, "no fingerprint, no group to join")
    }

    func testTheMemberListMakesEachPersonAPeerOfTheirOwn() {
        let c = client()
        var changes = 0
        c.changed = { changes += 1 }
        c.connect(relay)
        XCTAssertFalse(c.isInGroup(relay))
        XCTAssertEqual(c.handleInbound(roster([(ed, "ED_DT", true), (andre, "me", false)]), from: relay, now: 1), .consumed)
        XCTAssertTrue(c.isInGroup(relay))
        XCTAssertEqual(c.members.count, 1, "ourselves left out")
        let m = c.members[0]
        XCTAssertEqual(m.name, "ED_DT")
        XCTAssertTrue(m.ticksUs)
        XCTAssertEqual(m.relay, relay)
        XCTAssertTrue(JamWire.isMemberAddress(m.address.address), "an address in 240.0.0.0/5 (\(m.address))")
        XCTAssertEqual(m.address.port, 47830)
        XCTAssertEqual(c.relayOf(m.address), relay)
        XCTAssertGreaterThan(changes, 0)
        // The same person always gets the same address: their volume and pan come back with them.
        let again = client()
        again.connect(relay)
        _ = again.handleInbound(roster([(ed, "ED_DT", true)]), from: relay, now: 1)
        XCTAssertEqual(again.members[0].address, m.address)
        // Known answer, from the Windows RemSound: this id hashes to 240.70.132.194 (Andre as Ed's copy saw him on 09-29).
        let edsView = RelayGroupClient(clientId: ed)
        edsView.connect(relay)
        _ = edsView.handleInbound(roster([(andre, "MERJILLE", true)]), from: relay, now: 1)
        XCTAssertEqual(edsView.members[0].address.address, "240.70.132.194", "the same address the Windows app gives this id")
    }

    func testAMembersPacketArrivesInOrdinaryFormFromTheirAddress() {
        let c = client()
        c.connect(relay)
        _ = c.handleInbound(roster([(ed, "ED_DT", true)]), from: relay, now: 1)
        var framed = JamWire.header(2, stream: 59828, sequence: 77, version: 2)
        framed.append(contentsOf: JamWire.bytes(of: ed))
        framed.append(contentsOf: [9, 9, 9])
        guard case let .delivered(packet, from) = c.handleInbound(framed, from: relay, now: 1.1) else { return XCTFail("not delivered") }
        XCTAssertEqual(from, c.members[0].address)
        XCTAssertEqual(packet, JamWire.header(2, stream: 59828, sequence: 77) + [9, 9, 9], "version 1, the id taken out")
        // Not from a relay we are on: not ours to unwrap.
        XCTAssertEqual(c.handleInbound(framed, from: JamEndpoint("10.0.0.9", 47830), now: 1.1), .notGroup)
        // An ordinary packet: left alone.
        XCTAssertEqual(c.handleInbound(JamWire.header(2), from: relay, now: 1.1), .notGroup)
    }

    /// Windows' RELAY GROUPS: "our own packet must never be played back to us"; two people never share an address; a
    /// server whose lists start again is a group again, with everyone where they were.
    func testOurOwnPacketIsNeverPlayedBackAndNoTwoPeopleShareAnAddress() {
        let c = client()
        c.connect(relay)
        _ = c.handleInbound(roster([(ed, "ED_DT", true)]), from: relay, now: 1)
        var own = JamWire.header(2, stream: 1, sequence: 5, version: 2)
        own.append(contentsOf: JamWire.bytes(of: andre))
        own.append(contentsOf: [1, 2, 3])
        XCTAssertEqual(c.handleInbound(own, from: relay, now: 1.1), .consumed, "our own sound, echoed by the server: never played")
        var people: [UUID] = [ed]
        for _ in 0..<200 { people.append(UUID()) }
        let big = client()
        big.connect(relay)
        for chunk in stride(from: 0, to: people.count, by: 50) {
            var framed = JamWire.header(2, stream: 1, sequence: 1, version: 2)
            framed.append(contentsOf: JamWire.bytes(of: people[chunk]))
            _ = big.handleInbound(framed, from: relay, now: 1)
        }
        _ = big.handleInbound(roster(people.prefix(50).map { ($0, "p", false) }), from: relay, now: 1)
        let addresses = big.members.map(\.address)
        XCTAssertEqual(Set(addresses).count, addresses.count, "every person their own address")
    }

    func testAServerWhoseListsStartAgainIsAGroupAgainWithEveryoneWhereTheyWere() {
        let c = client()
        c.connect(relay)
        _ = c.handleInbound(roster([(ed, "ED_DT", true)]), from: relay, now: 1)
        let before = c.members[0].address
        c.tick(now: 40)   // quiet for 39 s: the server's people are gone
        XCTAssertTrue(c.members.isEmpty || !c.isInGroup(relay))
        _ = c.handleInbound(roster([(ed, "ED_DT", true)]), from: relay, now: 41)
        XCTAssertTrue(c.isInGroup(relay), "the lists came back: a group again")
        XCTAssertEqual(c.members.first?.address, before, "the same person at the same address, their settings with them")
    }

    func testSoundForSomebodyOnTheServerGoesToTheServerGroupFramed() {
        let c = client()
        c.connect(relay)
        _ = c.handleInbound(roster([(ed, "ED_DT", true)]), from: relay, now: 1)
        let member = c.members[0].address
        XCTAssertEqual(c.sendTargets(for: [member]), [relay], "one copy, to the server")
        sent = []
        let audio = JamWire.header(2, stream: 5, sequence: 6) + [1, 2, 3]
        XCTAssertTrue(c.route(audio, to: member))
        XCTAssertTrue(c.route(audio, to: relay))
        XCTAssertEqual(sent.count, 2)
        for (bytes, to) in sent {
            XCTAssertEqual(to, relay)
            XCTAssertEqual(bytes[4], 2)
            XCTAssertEqual(Array(bytes[12..<28]), JamWire.bytes(of: andre))
            XCTAssertEqual(Array(bytes[28...]), [1, 2, 3])
        }
        // A heartbeat also goes in ordinary form (it claims a pair slot beside a waiting phone).
        sent = []
        XCTAssertTrue(c.route(JamWire.header(4) + [0, 1, 2, 3, 4, 5, 6, 7, 8], to: relay))
        XCTAssertEqual(sent.map { $0.0[4] }, [2, 1])
        // The address check goes back exactly as it came.
        let check = JamWire.header(10) + [UInt8](repeating: 7, count: 16)
        XCTAssertTrue(JamWire.isAddressCheck(check))
        XCTAssertFalse(c.route(check, to: relay), "sent as it is, by the caller")
        // A member we no longer know: never onto the wire.
        sent = []
        XCTAssertTrue(c.route(audio, to: JamEndpoint("241.1.2.3", 47830)))
        XCTAssertTrue(sent.isEmpty)
        // Somebody not on a server: not ours.
        XCTAssertFalse(c.route(audio, to: JamEndpoint("192.168.1.95", 47830)))
    }

    func testJamulusStyleGoesOnlyWhenEveryoneTheServerPassesItToCanPlayIt() {
        let c = client()
        let carol = UUID()
        c.connect(relay)
        _ = c.handleInbound(roster([(ed, "ED_DT", true), (carol, "Carol", false)]), from: relay, now: 1)
        let edAt = c.members.first { $0.name == "ED_DT" }!.address
        XCTAssertFalse(c.everyReceiver(on: relay) { _ in true }, "nobody ticked: nobody hears us")
        c.setTicked([ed, carol])
        XCTAssertTrue(c.everyReceiver(on: relay) { $0 == edAt }, "Carol has not ticked us back, so she is passed nothing")
        _ = c.handleInbound(roster([(ed, "ED_DT", true), (carol, "Carol", true)]), from: relay, now: 2)
        XCTAssertFalse(c.everyReceiver(on: relay) { $0 == edAt }, "now she hears us, and cannot play it")
    }

    func testTheServersOwnMessagesGoToTheMetronome() {
        let c = client()
        c.connect(relay)
        _ = c.handleInbound(roster([]), from: relay, now: 1)
        var got: [UInt8] = []
        c.timingReceived = { body, _ in got = body }
        let grid = JamWire.header(13, version: 2) + [UInt8](repeating: 0, count: 16) + [20, 3]
        XCTAssertEqual(c.handleInbound(grid, from: relay, now: 1), .consumed)
        XCTAssertEqual(got, [20, 3])
        sent = []
        XCTAssertTrue(c.sendTiming([2]))
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(Array(sent[0].0[4...5]), [2, 13])
        XCTAssertEqual(Array(sent[0].0[12..<28]), JamWire.bytes(of: andre))
        XCTAssertEqual(Array(sent[0].0[28...]), [2])
    }

    func testAServerThatGoesQuietTakesItsPeopleWithIt() {
        let c = client()
        c.connect(relay)
        _ = c.handleInbound(roster([(ed, "ED_DT", true)]), from: relay, now: 10)
        c.tick(now: 14)
        XCTAssertEqual(c.members.count, 1, "4 s: still there")
        c.tick(now: 15.5)
        XCTAssertFalse(c.isInGroup(relay))
        XCTAssertTrue(c.members.isEmpty, "5 s without a member list: nobody is listed")
    }

    func testLeavingSaysGoodbye() {
        let c = client()
        c.connect(relay)
        _ = c.handleInbound(roster([(ed, "ED_DT", true)]), from: relay, now: 1)
        sent = []
        c.disconnect()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(Array(sent[0].0[4...5]), [2, 9], "a bye")
        XCTAssertNil(c.connectedRelay)
        XCTAssertTrue(c.members.isEmpty)
    }

    func testANameIsCutOnACharacterBoundary() {
        let name = String(repeating: "é", count: 20)   // 40 bytes of UTF-8
        let field = RelayGroupClient.encodeName(name)
        XCTAssertEqual(field.count, 32)
        XCTAssertEqual(RelayGroupClient.decodeName(field[0...]), String(repeating: "é", count: 16))
    }
}
