import XCTest
@testable import RemSoundJam

final class RelayDepartureTests: XCTestCase {
    private let first = JamEndpoint("192.0.2.1", 47830)
    private let second = JamEndpoint("192.0.2.2", 47830)
    private var sent: [([UInt8], JamEndpoint)] = []

    private func client() -> RelayGroupClient {
        let client = RelayGroupClient(clientId: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)
        client.setIdentity(name: "Departure test", fingerprint: [1, 2, 3, 4, 5, 6, 7, 8])
        client.send = { [unowned self] packet, endpoint in self.sent.append((packet, endpoint)) }
        return client
    }

    private func join(_ client: RelayGroupClient, now: TimeInterval = 1) {
        client.connect(first)
        client.tick(now: now)
        var roster = JamWire.header(JamWire.Kind.roster.rawValue, version: JamWire.groupVersion)
        roster += [UInt8](repeating: 0, count: JamWire.clientIdSize)
        roster += [0, 0]
        XCTAssertEqual(client.handleInbound(roster, from: first, now: now), .consumed)
        sent.removeAll()
    }

    private var goodbyes: [([UInt8], JamEndpoint)] {
        sent.filter { $0.0.count >= JamWire.headerSize && $0.0[5] == JamWire.Kind.bye.rawValue }
    }

    func testHelloWithoutRosterStillReceivesThreeGoodbyes() {
        let client = client()
        client.connect(first)
        client.tick(now: 1)
        sent.removeAll()
        client.disconnect()
        XCTAssertEqual(goodbyes.count, 1, "A sent hello requires a goodbye before a roster arrives")
        client.tick(now: 1.101)
        client.tick(now: 1.202)
        XCTAssertEqual(goodbyes.count, 3, "Departure retries must survive missing membership confirmation")
        XCTAssertTrue(goodbyes.allSatisfy { $0.1 == first })
    }

    func testJoinedDepartureHasThreeSpacedCopiesAndThenStops() {
        let client = client()
        join(client)
        client.disconnect()
        XCTAssertEqual(goodbyes.count, 1)
        client.tick(now: 1.05)
        XCTAssertEqual(goodbyes.count, 1, "Do not send the retries in the initial burst")
        client.tick(now: 1.101)
        XCTAssertEqual(goodbyes.count, 2)
        client.tick(now: 1.202)
        XCTAssertEqual(goodbyes.count, 3)
        client.tick(now: 5)
        client.disconnect()
        XCTAssertEqual(goodbyes.count, 3, "Repeated leave must not restart a completed goodbye")
    }

    func testEveryOrdinaryPacketToDepartedRelayIsConsumedWithoutSending() {
        let client = client()
        join(client)
        client.disconnect()
        sent.removeAll()
        for kind in [JamWire.Kind.audio, .heartbeat, .control, .addressCheck] {
            XCTAssertTrue(client.route(JamWire.header(kind.rawValue), to: first), "Departed endpoint must not fall through to UDP")
        }
        XCTAssertTrue(sent.isEmpty)
        XCTAssertFalse(client.route(JamWire.header(JamWire.Kind.heartbeat.rawValue), to: second), "Unrelated direct peers remain reachable")
    }

    func testReconnectRemovesSuppressionAndCancelsOldRetries() {
        let client = client()
        join(client)
        client.disconnect()
        client.tick(now: 1.101)
        XCTAssertEqual(goodbyes.count, 2, "Prove a retry existed before exercising its cancellation")
        client.connect(first)
        client.tick(now: 1.15)
        let countAtHello = goodbyes.count
        client.tick(now: 1.202)
        client.tick(now: 2)
        XCTAssertEqual(goodbyes.count, countAtHello, "No old goodbye may follow the new hello")
        XCTAssertFalse(client.route(JamWire.header(JamWire.Kind.addressCheck.rawValue), to: first))
    }

    func testSwitchDropsOldEndpointButKeepsCurrentEndpointReachable() {
        let client = client()
        join(client)
        client.connect(second)
        client.tick(now: 1.05)
        XCTAssertTrue(client.route(JamWire.header(JamWire.Kind.heartbeat.rawValue), to: first))
        XCTAssertFalse(client.route(JamWire.header(JamWire.Kind.addressCheck.rawValue), to: second))
        client.tick(now: 1.151)
        client.tick(now: 1.252)
        XCTAssertEqual(goodbyes.filter { $0.1 == first }.count, 3)
    }

    func testNeverHelloedRelayDoesNotReceiveGoodbyesOnSwitch() {
        let client = client()
        client.connect(first)
        client.connect(second)
        client.tick(now: 1)
        XCTAssertTrue(goodbyes.isEmpty, "Only endpoints that received a hello belong to a departure")
    }

    func testShutdownDrainWaitsBetweenRemainingCopiesWithoutSendingHellos() {
        let client = client()
        join(client)
        client.disconnect()
        var waits: [TimeInterval] = []
        client.finishDepartures { waits.append($0) }
        XCTAssertEqual(waits.count, 2)
        XCTAssertEqual(waits.reduce(0, +), 0.2, accuracy: 0.000001)
        XCTAssertEqual(goodbyes.count, 3)
        XCTAssertEqual(sent.count, 3)
        client.finishDepartures { _ in XCTFail("Completed shutdown must not wait again") }
    }

    func testLateTickSpacesRemainingRetryRatherThanBursting() {
        let client = client()
        join(client)
        client.disconnect()
        client.tick(now: 5)
        XCTAssertEqual(goodbyes.count, 2)
        client.tick(now: 5.05)
        XCTAssertEqual(goodbyes.count, 2)
        client.tick(now: 5.101)
        XCTAssertEqual(goodbyes.count, 3)
    }

    func testRepeatedSameEndpointReconnectHasOnlyCurrentDeparture() {
        let client = client()
        for index in 0..<1000 {
            client.connect(first)
            client.tick(now: Double(index))
            client.disconnect()
        }
        sent.removeAll()
        client.tick(now: 999.101)
        client.tick(now: 999.202)
        XCTAssertEqual(goodbyes.count, 2, "Only the last visit may still have retries")
        XCTAssertTrue(sent.allSatisfy { $0.1 == first })
    }
}
