import XCTest
@testable import RemSoundJam

final class RelayServerStatusTests: XCTestCase {
    private var clockUs: Int64 = 0
    private let relay = JamEndpoint("127.0.0.1", 49144)
    private let id = UUID(uuidString: "0033A815-0B74-4F47-9EF6-88E4C064FC20")!

    private func packet(_ kind: UInt8, _ body: [UInt8], sender: UUID? = nil) -> [UInt8] {
        var p = JamWire.header(kind, version: JamWire.groupVersion)
        p += sender.map(JamWire.bytes(of:)) ?? [UInt8](repeating: 0, count: 16)
        return p + body
    }
    private func infoBody() -> [UInt8] {
        let version = Array("2.16".utf8)
        var b: [UInt8] = [1, UInt8(version.count)] + version
        b.appendLE(UInt32(123456)); b.appendLE(UInt16(11)); b.appendLE(UInt16(3))
        b.appendLE(UInt16(89)); b.appendLE(UInt16(2)); b.appendLE(UInt32(3456))
        b.appendLE(UInt32(23789)); b.appendLE(UInt16(7)); b.appendLE(UInt16(60))
        return b
    }
    private func client() -> RelayGroupClient {
        let c = RelayGroupClient(clientId: id, pingClock: { [unowned self] in self.clockUs })
        c.setIdentity(name: "Test", fingerprint: [1,2,3,4,5,6,7,8]); c.connect(relay)
        return c
    }
    private func receive(_ c: RelayGroupClient, _ p: [UInt8], from endpoint: JamEndpoint, now: Double) -> RelayGroupClient.Inbound {
        clockUs = Int64(now * 1_000_000)
        return c.handleInbound(p, from: endpoint, now: now)
    }
    private func tick(_ c: RelayGroupClient, now: Double) {
        clockUs = Int64(now * 1_000_000)
        c.tick(now: now)
    }
    private func join(_ c: RelayGroupClient, at now: Double) {
        _ = receive(c, packet(7, [0, 0]), from: relay, now: now)
    }
    private func ping(_ c: RelayGroupClient, at now: Double) throws -> [UInt8] {
        var sent = [[UInt8]]()
        c.send = { b, to in if to == self.relay && b[5] == 15 { sent.append(b) } }
        join(c, at: now); tick(c, now: now)
        return try XCTUnwrap(sent.first, "one server ping while in the group")
    }

    func testStatusLayoutAndReceiptAreExact() throws {
        let info = try XCTUnwrap(RelayGroupClient.readServerInfo(infoBody(), receivedAt: 42))
        XCTAssertEqual(info.version, "2.16"); XCTAssertEqual(info.uptime, 123456)
        XCTAssertEqual(info.people, 11); XCTAssertEqual(info.groups, 3)
        XCTAssertEqual(info.placesFree, 89); XCTAssertEqual(info.phones, 2)
        XCTAssertEqual(info.yourPackets, 3456); XCTAssertEqual(info.yourLongestGapMs, 23.789)
        XCTAssertEqual(info.yourLongGaps, 7); XCTAssertEqual(info.yourSeconds, 60)
        XCTAssertEqual(info.receivedAt, 42)
    }
    func testEveryTruncatedBodyAndUnknownVersionAreRejected() {
        let body = infoBody()
        for n in 0..<body.count { XCTAssertNil(RelayGroupClient.readServerInfo(Array(body.prefix(n)), receivedAt: 0)) }
        var unknown = body; unknown[0] = 2
        XCTAssertNil(RelayGroupClient.readServerInfo(unknown, receivedAt: 0))
    }
    func testExtensionsAndUnsignedLimitsMatchWindows() throws {
        var b: [UInt8] = [1, 1, 255]
        b.appendLE(UInt32.max)
        for _ in 0..<4 { b.appendLE(UInt16.max) }
        b.appendLE(UInt32.max); b.appendLE(UInt32.max)
        b.appendLE(UInt16.max); b.appendLE(UInt16.max); b += [123, 45]
        let info = try XCTUnwrap(RelayGroupClient.readServerInfo(b, receivedAt: 1))
        XCTAssertEqual(info.version, "?"); XCTAssertEqual(info.uptime, Double(UInt32.max))
        XCTAssertEqual(info.yourPackets, Int(Int32.max)); XCTAssertEqual(info.yourLongestGapMs, Double(UInt32.max) / 1000)
        XCTAssertEqual(info.yourSeconds, 65535)
    }
    func testInfoIsBookkeepingNotAPeerOrAudioRoute() throws {
        let c = client(); join(c, at: 0)
        XCTAssertEqual(receive(c, packet(14, infoBody()), from: relay, now: 2), .consumed)
        XCTAssertEqual(try XCTUnwrap(c.latestServerInfo).receivedAt, 2)
        XCTAssertTrue(c.members.isEmpty)
        XCTAssertNil(c.relayOf(JamEndpoint("240.0.0.1")))
    }
    func testWrongSourceAndFramingCannotChangeTelemetry() {
        let c = client(); let p = packet(14, infoBody())
        XCTAssertEqual(receive(c, p, from: JamEndpoint("127.0.0.2", 49144), now: 1), .notGroup)
        var ordinary = p; ordinary[4] = 1
        XCTAssertEqual(receive(c, ordinary, from: relay, now: 1), .notGroup)
        XCTAssertNil(c.latestServerInfo); XCTAssertNil(c.serverRoundTripMs)
    }
    func testMalformedInfoIsConsumedWithoutReplacingValidStatus() throws {
        let c = client(); _ = receive(c, packet(14, infoBody()), from: relay, now: 1)
        let good = try XCTUnwrap(c.latestServerInfo)
        XCTAssertEqual(receive(c, packet(14, [1, 200]), from: relay, now: 2), .consumed)
        XCTAssertEqual(c.latestServerInfo, good); XCTAssertTrue(c.members.isEmpty)
    }
    func testPingBytesCadenceAndGroupGate() throws {
        let c = client(); var sent = [[UInt8]]()
        c.send = { b, _ in sent.append(b) }; tick(c, now: 0)
        XCTAssertFalse(sent.contains { $0[5] == 15 }, "no ping before joining")
        join(c, at: 1); tick(c, now: 1)
        let first = try XCTUnwrap(sent.first { $0[5] == 15 })
        XCTAssertEqual(first.count, 36); XCTAssertEqual(Array(first[12..<28]), JamWire.bytes(of: id))
        XCTAssertEqual(first.readLE(Int64.self, at: 28), 1_000_000)
        tick(c, now: 1.99); XCTAssertEqual(sent.filter { $0[5] == 15 }.count, 1)
        tick(c, now: 2); XCTAssertEqual(sent.filter { $0[5] == 15 }.count, 2)
        tick(c, now: 7); XCTAssertFalse(c.isInGroup(relay))
        XCTAssertEqual(sent.filter { $0[5] == 15 }.count, 2)
    }
    func testOnlyOurIssuedEchoMeasuresAndDuplicateIsIgnored() throws {
        let c = client(); let p = try ping(c, at: 10)
        var foreign = p; foreign.replaceSubrange(12..<28, with: JamWire.bytes(of: UUID()))
        XCTAssertEqual(receive(c, foreign, from: relay, now: 10.02), .consumed)
        XCTAssertNil(c.serverRoundTripMs)
        _ = receive(c, p, from: relay, now: 10.02)
        XCTAssertEqual(try XCTUnwrap(c.serverRoundTripMs), 20, accuracy: 0.001)
        _ = receive(c, p, from: relay, now: 10.2)
        XCTAssertEqual(try XCTUnwrap(c.serverRoundTripMs), 20, accuracy: 0.001)
        XCTAssertTrue(c.members.isEmpty)
    }
    func testFutureExpiredAndUnissuedPingsCannotMeasure() throws {
        let c = client(); let p = try ping(c, at: 10)
        _ = receive(c, p, from: relay, now: 9); XCTAssertNil(c.serverRoundTripMs)
        _ = receive(c, p, from: relay, now: 20); XCTAssertNil(c.serverRoundTripMs)
        var unissued = p; unissued.replaceSubrange(28..<36, with: [UInt8](repeating: 0, count: 8))
        _ = receive(c, unissued, from: relay, now: 20); XCTAssertNil(c.serverRoundTripMs)
    }
    func testMedianUsesOnlyTenMostRecentValidReplies() throws {
        let c = client()
        for i in 0..<12 {
            let at = Double(i * 2), p = try ping(c, at: at)
            _ = receive(c, p, from: relay, now: at + Double(i + 1) / 1000)
        }
        XCTAssertEqual(try XCTUnwrap(c.serverRoundTripMs), 7.5, accuracy: 0.001)
    }
    func testLeaveSwitchTimeoutAndRejoinRetireAllMeasurements() throws {
        let c = client(); let p = try ping(c, at: 1)
        _ = receive(c, p, from: relay, now: 1.03)
        _ = receive(c, packet(14, infoBody()), from: relay, now: 1.04)
        XCTAssertEqual(c.inGroupSince, 1)
        tick(c, now: 6.01)
        XCTAssertNil(c.latestServerInfo); XCTAssertNil(c.serverRoundTripMs); XCTAssertNil(c.inGroupSince)
        join(c, at: 7); XCTAssertEqual(c.inGroupSince, 7)
        _ = receive(c, p, from: relay, now: 7.1); XCTAssertNil(c.serverRoundTripMs)
        c.connect(JamEndpoint("127.0.0.2", 49145)); XCTAssertNil(c.inGroupSince)
        XCTAssertEqual(receive(c, packet(14, infoBody()), from: relay, now: 8), .notGroup)
        c.disconnect(); XCTAssertNil(c.latestServerInfo); XCTAssertNil(c.inGroupSince)
    }
    func testRoundTripUsesMonotonicClockWhenLifecycleWallTimeMoves() throws {
        let c = client(); let p = try ping(c, at: 10)
        clockUs = 10_020_000
        _ = c.handleInbound(p, from: relay, now: 1)
        XCTAssertEqual(try XCTUnwrap(c.serverRoundTripMs), 20, accuracy: 0.001)
    }
    func testRosterRefreshKeepsOriginalJoinTime() {
        let c = client(); join(c, at: 10); join(c, at: 12)
        XCTAssertEqual(c.inGroupSince, 10)
    }
}
