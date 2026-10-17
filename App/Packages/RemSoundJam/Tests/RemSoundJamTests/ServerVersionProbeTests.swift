import XCTest
@testable import RemSoundJam

final class ServerVersionProbeTests: XCTestCase {
    private let endpoint = JamEndpoint("127.0.0.1", 49146)
    private let id = UUID(uuidString: "0033A815-0B74-4F47-9EF6-88E4C064FC20")!
    private let tag: [UInt8] = [9, 8, 7, 6, 5, 4, 3, 2]
    private func probe() -> ServerVersionProbe { ServerVersionProbe(server: endpoint, clientID: id, groupTag: tag) }
    private func packet(_ kind: JamWire.Kind, body: [UInt8] = [], sender: UUID? = nil) -> [UInt8] {
        JamWire.header(kind.rawValue, version: JamWire.groupVersion) + (sender.map(JamWire.bytes(of:)) ?? [UInt8](repeating: 0, count: 16)) + body
    }
    private var proof: [UInt8] { JamWire.header(10) + [UInt8](repeating: 73, count: 16) }
    private func info(_ version: String) -> [UInt8] {
        let bytes = Array(version.utf8)
        return packet(.serverInfo, body: [1, UInt8(bytes.count)] + bytes + [UInt8](repeating: 0, count: 24))
    }
    func testThrowawayHelloHasNoSelectionsAndOnlyExpectedName() throws {
        let p = probe(), hello = try XCTUnwrap(p.tick(at: 0).first)
        XCTAssertEqual(hello.count, 69); XCTAssertEqual(hello[4], 2); XCTAssertEqual(hello[5], 6)
        XCTAssertEqual(Array(hello[12..<28]), JamWire.bytes(of: id))
        XCTAssertEqual(String(decoding: hello[28..<60].prefix { $0 != 0 }, as: UTF8.self), "server check")
        XCTAssertEqual(Array(hello[60..<68]), tag); XCTAssertEqual(hello[68], 0)
        XCTAssertTrue(p.tick(at: 0.399).isEmpty)
        XCTAssertEqual(p.tick(at: 0.4).filter { $0[5] == 6 }.count, 1)
    }
    func testAddressProofExactEchoAndOlderBoundary() throws {
        let p = probe(); _ = p.tick(at: 0)
        XCTAssertEqual(p.receive(proof, from: endpoint, at: 0.1), [proof])
        XCTAssertTrue(p.tick(at: 0.899).contains { $0[5] == 15 }); XCTAssertNil(p.result)
        let bye = p.tick(at: 0.901)
        let result = try XCTUnwrap(p.result)
        XCTAssertTrue(result.answered); XCTAssertNil(result.version); XCTAssertFalse(result.cancelled)
        XCTAssertEqual(bye.count, 2); XCTAssertTrue(bye.allSatisfy { $0[5] == 9 })
        XCTAssertTrue(p.tick(at: 10).isEmpty); XCTAssertTrue(p.cancel().isEmpty)
    }
    func testValidStatusFinishesImmediatelyAndSaysGoodbyeTwice() throws {
        let p = probe(); _ = p.tick(at: 0)
        let bye = p.receive(info("server-v2.17"), from: endpoint, at: 0.2)
        XCTAssertEqual(try XCTUnwrap(p.result).version, "server-v2.17")
        XCTAssertEqual(bye, [packet(.bye, sender: id), packet(.bye, sender: id)])
        XCTAssertTrue(p.receive(info("server-v2.99"), from: endpoint, at: 0.3).isEmpty)
        XCTAssertEqual(p.result?.version, "server-v2.17")
    }
    func testIssuedIdentityPingAndStatusWaitBoundary() throws {
        let p = probe(); _ = p.tick(at: 0); _ = p.receive(proof, from: endpoint, at: 0.1)
        let ping = try XCTUnwrap(p.tick(at: 0.1).first { $0[5] == 15 })
        XCTAssertEqual(ping.count, 36)
        _ = p.receive(ping, from: endpoint, at: 0.125)
        XCTAssertNil(p.result); _ = p.tick(at: 2.124); XCTAssertNil(p.result)
        let bye = p.tick(at: 2.126); XCTAssertEqual(bye.count, 2)
        XCTAssertEqual(try XCTUnwrap(p.result?.roundTripMs), 25, accuracy: 0.001)
    }
    func testWrongEndpointHeaderAndMalformedStatusDoNotAnswer() throws {
        let p = probe(); _ = p.tick(at: 0)
        _ = p.receive(proof, from: JamEndpoint("127.0.0.1", 49147), at: 0.1)
        var corrupt = proof; corrupt[0] = 0
        _ = p.receive(corrupt, from: endpoint, at: 0.2)
        _ = p.receive(Array(proof.prefix(27)), from: endpoint, at: 0.3)
        _ = p.receive(packet(.serverInfo, body: [1, 99]), from: endpoint, at: 0.4)
        _ = p.receive(packet(.roster, body: [1]), from: endpoint, at: 0.5)
        _ = p.tick(at: 3)
        XCTAssertFalse(try XCTUnwrap(p.result).answered)
    }
    func testInventedWrongIDAndDuplicatePingsCannotExtendWait() throws {
        let p = probe(); _ = p.tick(at: 0); _ = p.receive(proof, from: endpoint, at: 0.1)
        let ping = try XCTUnwrap(p.tick(at: 0.1).first { $0[5] == 15 })
        var wrong = ping; wrong[12] ^= 1
        _ = p.receive(wrong, from: endpoint, at: 0.11)
        var invented = ping; invented[28] ^= 1
        _ = p.receive(invented, from: endpoint, at: 0.12)
        _ = p.receive(ping, from: endpoint, at: 0.13)
        _ = p.receive(ping, from: endpoint, at: 2.12)
        _ = p.tick(at: 2.131)
        XCTAssertEqual(try XCTUnwrap(p.result?.roundTripMs), 30, accuracy: 0.001)
    }
    func testFullAndRosterAreDifferentFromNoAnswer() throws {
        let full = probe(); _ = full.tick(at: 0)
        XCTAssertEqual(full.receive(packet(.full), from: endpoint, at: 0.2).count, 2)
        XCTAssertTrue(try XCTUnwrap(full.result).full)
        let roster = probe(); _ = roster.tick(at: 0)
        _ = roster.receive(packet(.roster, body: [0, 0]), from: endpoint, at: 0.2)
        _ = roster.tick(at: 1.001)
        let result = try XCTUnwrap(roster.result)
        XCTAssertTrue(result.answered); XCTAssertFalse(result.full)
    }
    func testCancellationRetiresAllPacketsAndDoesNotImplyOldVersion() throws {
        let p = probe(); _ = p.tick(at: 0)
        XCTAssertEqual(p.cancel().count, 2)
        let result = try XCTUnwrap(p.result)
        XCTAssertTrue(result.cancelled); XCTAssertFalse(result.answered)
        XCTAssertTrue(p.receive(info("server-v2.99"), from: endpoint, at: 1).isEmpty)
        XCTAssertTrue(p.tick(at: 2).isEmpty); XCTAssertTrue(p.cancel().isEmpty)
    }
    func testThreeSecondNoAnswerLimitDoesNotCatchUpTraffic() throws {
        let p = probe(); XCTAssertEqual(p.tick(at: 0).count, 1)
        XCTAssertEqual(p.tick(at: 2.999).count, 1)
        XCTAssertEqual(p.tick(at: 3).count, 2)
        XCTAssertFalse(try XCTUnwrap(p.result).answered)
        XCTAssertNil(p.result?.roundTripMs)
    }
    func testAllTruncatedStatusesAndMemberPacketsAreIgnored() throws {
        let p = probe(); _ = p.tick(at: 0)
        let status = info("server-v2.17")
        for length in 0..<status.count { _ = p.receive(Array(status.prefix(length)), from: endpoint, at: 0.1) }
        _ = p.receive(packet(.serverInfo, body: Array(status.dropFirst(28)), sender: id), from: endpoint, at: 0.2)
        _ = p.receive(packet(.audio, body: [1, 2, 3]), from: endpoint, at: 0.3)
        _ = p.tick(at: 3)
        XCTAssertFalse(try XCTUnwrap(p.result).answered)
    }
    func testBeforeStartCancellationNeverCreatesTraffic() throws {
        let p = probe()
        XCTAssertTrue(p.receive(info("server-v2.17"), from: endpoint, at: 0).isEmpty)
        XCTAssertNil(p.result)
        XCTAssertTrue(p.cancel().isEmpty)
        XCTAssertTrue(try XCTUnwrap(p.result).cancelled)
        XCTAssertTrue(p.tick(at: 1).isEmpty)
    }
    func testDeadlineRejectsLateStatusAndInvalidTimes() throws {
        let p = probe(); _ = p.tick(at: 0)
        for time in [Double.nan, Double.infinity, -1] { XCTAssertTrue(p.tick(at: time).isEmpty) }
        XCTAssertNil(p.result)
        XCTAssertEqual(p.receive(info("server-v2.17"), from: endpoint, at: 3).count, 2)
        let result = try XCTUnwrap(p.result)
        XCTAssertNil(result.version); XCTAssertFalse(result.answered)
    }
    func testMockedProofPingAndStatusExchangeCarriesNoAudio() throws {
        let p = probe()
        var outgoing = p.tick(at: 0)
        XCTAssertEqual(outgoing.map { $0[5] }, [6])
        outgoing += p.receive(proof, from: endpoint, at: 0.01)
        let ping = try XCTUnwrap(p.tick(at: 0.025).first { $0[5] == 15 })
        outgoing.append(ping)
        _ = p.receive(ping, from: endpoint, at: 0.045)
        outgoing += p.receive(info("server-v2.17"), from: endpoint, at: 0.5)
        let result = try XCTUnwrap(p.result)
        XCTAssertEqual(result.version, "server-v2.17"); XCTAssertTrue(result.answered)
        XCTAssertEqual(try XCTUnwrap(result.roundTripMs), 20, accuracy: 0.001)
        XCTAssertEqual(outgoing.map { $0[5] }, [6, 10, 15, 9, 9])
    }

}
