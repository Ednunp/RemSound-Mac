import Foundation
import XCTest
import RemSoundJam
@testable import RemSoundCore

final class SessionRelayDepartureTests: XCTestCase {
    private func started(_ relay: UDP, selected: Bool = false) -> Session {
        let session = Session(testPeerPort: relay.boundPort)
        session.start(password: "isolated departure fixture", peerAddress: selected ? "127.0.0.1" : "",
            send: false, receive: false, plugins: false, name: "Departure fixture")
        XCTAssertNotEqual(session.testPorts.audio, 0)
        return session
    }

    private func receiveHello(_ relay: UDP) throws {
        let until = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < until {
            if let (data, _) = relay.receive(), data.count >= JamWire.groupHeaderSize,
                data[4] == JamWire.groupVersion, data[5] == JamWire.Kind.hello.rawValue { return }
            Thread.sleep(forTimeInterval: 0.005)
        }
        throw NSError(domain: "Departure fixture did not receive hello", code: 1)
    }

    private func packets(_ relay: UDP, seconds: TimeInterval) -> [Data] {
        var result: [Data] = []
        let until = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            while let (data, _) = relay.receive() { result.append(data) }
            Thread.sleep(forTimeInterval: 0.005)
        } while ProcessInfo.processInfo.systemUptime < until
        return result
    }

    private func isBye(_ packet: Data) -> Bool {
        packet.count >= JamWire.groupHeaderSize && packet[4] == JamWire.groupVersion
            && packet[5] == JamWire.Kind.bye.rawValue
    }

    func testDisconnectBeforeRosterDeliversAllThreeCopiesOnRealSessionSocket() throws {
        let relay = try UDP(port: 0, loopback: true)
        let session = started(relay)
        defer { session.shutdown() }
        session.connectServer("127.0.0.1:\(relay.boundPort)")
        try receiveHello(relay)
        session.disconnectServer()
        _ = session.testPorts
        XCTAssertEqual(packets(relay, seconds: 0.35).filter(isBye).count, 3)
    }

    func testShutdownFinishesGoodbyesBeforeClosingItsSocket() throws {
        let relay = try UDP(port: 0, loopback: true)
        let session = started(relay)
        session.connectServer("127.0.0.1:\(relay.boundPort)")
        try receiveHello(relay)
        session.shutdown()
        XCTAssertEqual(session.testPorts.audio, 0)
        XCTAssertEqual(packets(relay, seconds: 0.02).filter(isBye).count, 3)
    }

    func testDepartedServerCannotBeReclaimedBySelectedDirectPeerHeartbeats() throws {
        let relay = try UDP(port: 0, loopback: true)
        let session = started(relay, selected: true)
        defer { session.shutdown() }
        session.connectServer("127.0.0.1:\(relay.boundPort)")
        try receiveHello(relay)
        _ = packets(relay, seconds: 0.02)
        session.disconnectServer()
        _ = session.testPorts
        let after = packets(relay, seconds: 1.7)
        XCTAssertEqual(after.filter(isBye).count, 3)
        XCTAssertTrue(after.allSatisfy(isBye), "Ordinary heartbeats can reoccupy the slot after departure")
    }

    func testNewHelloCancelsGoodbyesFromPreviousVisit() throws {
        let relay = try UDP(port: 0, loopback: true)
        let session = started(relay)
        defer { session.shutdown() }
        session.connectServer("127.0.0.1:\(relay.boundPort)")
        try receiveHello(relay)
        session.disconnectServer()
        _ = session.testPorts
        session.connectServer("127.0.0.1:\(relay.boundPort)")
        try receiveHello(relay)
        XCTAssertTrue(packets(relay, seconds: 0.35).filter(isBye).isEmpty)
    }

    func testRoutingHistorySurvivesStopAndSessionRestartUntilExplicitConnect() throws {
        let relay = try UDP(port: 0, loopback: true)
        let session = started(relay, selected: true)
        defer { session.shutdown() }
        session.connectServer("127.0.0.1:\(relay.boundPort)")
        try receiveHello(relay)
        session.shutdown()
        _ = packets(relay, seconds: 0.02)
        session.start(password: "isolated departure fixture", peerAddress: "127.0.0.1",
            send: false, receive: false, plugins: false, name: "Departure fixture")
        XCTAssertNotEqual(session.testPorts.audio, 0, "The old socket must be closed before restart")
        XCTAssertTrue(packets(relay, seconds: 1.7).isEmpty)
        session.connectServer("127.0.0.1:\(relay.boundPort)")
        try receiveHello(relay)
        let after = packets(relay, seconds: 1.7)
        XCTAssertTrue(after.contains { Wire.parse($0)?.kind == .heartbeat },
            "Explicit reconnect restores ordinary pair-slot traffic")
        XCTAssertTrue(after.filter(isBye).isEmpty)
    }
}
