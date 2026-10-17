import Foundation
import XCTest
import RemSoundJam
@testable import RemSoundCore

final class ServerVersionOperationTests: XCTestCase {
    private let endpoint = Endpoint("127.0.0.1", 49147)
    private final class Transport: ServerProbeTransport {
        var sent: [Data] = []
        var incoming: [(Data, Endpoint)] = []
        var closes = 0
        func send(_ packet: Data, to: Endpoint) { sent.append(packet) }
        func receive() -> (Data, Endpoint)? { incoming.isEmpty ? nil : incoming.removeFirst() }
        func close() { closes += 1 }
    }
    private func info() -> Data {
        let v = Array("server-v2.17".utf8)
        return Data(JamWire.header(14, version: 2) + [UInt8](repeating: 0, count: 16) + [1, UInt8(v.count)] + v + [UInt8](repeating: 0, count: 24))
    }
    func testIsolationRefusesBeforeFactoryAndCompletesOnce() {
        var made = 0, replies: [ServerVersionProbe.Result] = []
        let operation = ServerVersionOperation(endpoint: endpoint, permitted: false, clock: { 0 }, factory: { made += 1; return Transport() }, completion: { replies.append($0) })
        operation.tick(); operation.tick(); operation.cancel()
        XCTAssertEqual(made, 0); XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?.answered, false)
    }
    func testMockedStatusHasTwoGoodbyesAndExactClose() throws {
        let transport = Transport(); var now = 0.0, replies: [ServerVersionProbe.Result] = []
        let operation = ServerVersionOperation(endpoint: endpoint, permitted: true, clock: { now }, factory: { transport }, completion: { replies.append($0) })
        operation.tick(); XCTAssertEqual(transport.sent.map { $0[5] }, [6])
        let proof = Data(JamWire.header(10) + [UInt8](repeating: 29, count: 16))
        transport.incoming = [(proof, endpoint), (info(), endpoint)]; now = 0.5
        operation.tick(); operation.tick(); operation.cancel()
        XCTAssertEqual(transport.sent.map { $0[5] }, [6, 6, 10, 9, 9])
        XCTAssertEqual(replies.count, 1); XCTAssertEqual(replies.first?.version, "server-v2.17")
        XCTAssertEqual(transport.closes, 1)
        let hello = try XCTUnwrap(transport.sent.first)
        XCTAssertEqual(hello.count, 69); XCTAssertEqual(hello[68], 0)
    }
    func testCancellationClosesBeforeAnyObsoleteTickOrReply() {
        let transport = Transport(); var now = 0.0, replies = 0
        let operation = ServerVersionOperation(endpoint: endpoint, permitted: true, clock: { now }, factory: { transport }, completion: { _ in replies += 1 })
        operation.tick(); operation.cancel(); now = 3; transport.incoming = [(info(), endpoint)]
        operation.tick(); operation.cancel()
        XCTAssertEqual(transport.sent.map { $0[5] }, [6, 9, 9]); XCTAssertEqual(transport.closes, 1); XCTAssertEqual(replies, 0)
    }
    func testNativeSeparateSocketUsesOnlyOwnedSpareLoopback() throws {
        let relay = try UDP(port: 0, loopback: true)
        XCTAssertFalse([Wire.audioPort, Wire.discoveryPort, Wire.bridgePort].contains(relay.boundPort))
        let server = Endpoint("127.0.0.1", relay.boundPort); var now = 0.0
        var result: ServerVersionProbe.Result?
        let operation = ServerVersionOperation(endpoint: server, permitted: true, clock: { now }, factory: { try UDPServerProbeTransport(loopback: true) }, completion: { result = $0 })
        defer { operation.cancel() }; operation.tick()
        let until = Date().addingTimeInterval(1); var first: (Data, Endpoint)?
        while first == nil && Date() < until { first = relay.receive(); if first == nil { Thread.sleep(forTimeInterval: 0.005) } }
        let (_, client) = try XCTUnwrap(first)
        XCTAssertNotEqual(client.port, relay.boundPort)
        _ = relay.send(info(), to: client); now = 0.5
        while result == nil && Date() < until { operation.tick(); if result == nil { Thread.sleep(forTimeInterval: 0.005) } }
        XCTAssertEqual(result?.version, "server-v2.17")
        var byes: [Data] = []
        let byeDeadline = Date().addingTimeInterval(1)
        while byes.filter({ $0.count > 5 && $0[5] == 9 }).count < 2 && Date() < byeDeadline {
            if let (packet, _) = relay.receive() { byes.append(packet) }
            else { Thread.sleep(forTimeInterval: 0.005) }
        }
        XCTAssertEqual(byes.filter { $0[5] == 9 }.count, 2)
        XCTAssertFalse(byes.contains { $0[5] == 2 })
    }
    func testFactoryFailureReturnsUnansweredWithoutRetry() {
        var made = 0, replies: [ServerVersionProbe.Result] = []
        let operation = ServerVersionOperation(endpoint: endpoint, permitted: true, clock: { 0 }, factory: { made += 1; throw ProtocolError.invalid("fixture") }, completion: { replies.append($0) })
        operation.tick(); operation.tick()
        XCTAssertEqual(made, 1); XCTAssertEqual(replies.count, 1); XCTAssertEqual(replies.first?.answered, false)
    }
    func testDeadlineClosesExactSocketAndNoCatchUpAfterCompletion() {
        let transport = Transport(); var now = 0.0, results: [ServerVersionProbe.Result] = []
        let operation = ServerVersionOperation(endpoint: endpoint, permitted: true, clock: { now }, factory: { transport }, completion: { results.append($0) })
        operation.tick(); now = 3; operation.tick(); operation.tick()
        XCTAssertEqual(transport.sent.map { $0[5] }, [6, 9, 9]); XCTAssertEqual(transport.closes, 1)
        XCTAssertEqual(results.count, 1); XCTAssertEqual(results.first?.answered, false)
    }
    func testReceiveBudgetYieldsWithoutLosingPendingStatus() {
        let transport = Transport(); var now = 0.0, result: ServerVersionProbe.Result?
        let operation = ServerVersionOperation(endpoint: endpoint, permitted: true, clock: { now }, factory: { transport }, completion: { result = $0 })
        operation.tick()
        transport.incoming = (0..<17).map { _ in (Data([0]), endpoint) } + [(info(), endpoint)]
        now = 0.1; operation.tick(); XCTAssertNil(result); XCTAssertEqual(transport.incoming.count, 2)
        operation.tick(); XCTAssertEqual(result?.version, "server-v2.17"); XCTAssertEqual(transport.closes, 1)
    }

}
