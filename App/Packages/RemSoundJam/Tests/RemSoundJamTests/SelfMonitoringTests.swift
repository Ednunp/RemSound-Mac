import XCTest
@testable import RemSoundJam

final class SelfMonitoringTests: XCTestCase {
    func testReturnedPacketCountsBelongToTheirOwnStreamAndInterval() {
        var monitor = SelfMonitorTiming()
        monitor.start(nowUs: 0)
        monitor.noteSent(stream: 1, sequence: 1, capturedUs: 100)
        monitor.noteSent(stream: 2, sequence: 1, capturedUs: 100)
        monitor.noteEcho(stream: 1, sequence: 1, arrivedUs: 10_100)
        monitor.noteEcho(stream: 1, sequence: 2, arrivedUs: 11_100)
        monitor.noteEcho(stream: 2, sequence: 1, arrivedUs: 20_100)
        let first = monitor.takeMeasurements()
        XCTAssertEqual(first[1]?.returnedCount, 2, "Unmatched returns still belong to this stream")
        XCTAssertEqual(first[2]?.returnedCount, 1, "Another stream's packets must not inflate this count")
        XCTAssertEqual(first[1]?.count, 1, "Returned and successfully timed counts are distinct")
        monitor.noteSent(stream: 1, sequence: 3, capturedUs: 30_100)
        monitor.noteEcho(stream: 1, sequence: 3, arrivedUs: 40_100)
        XCTAssertEqual(monitor.takeMeasurements()[1]?.returnedCount, 1, "The prior interval is reset")
        monitor.stop()
        monitor.start(nowUs: 50_000)
        monitor.noteSent(stream: 2, sequence: 1, capturedUs: 50_100)
        monitor.noteEcho(stream: 2, sequence: 1, arrivedUs: 60_100)
        XCTAssertEqual(monitor.takeMeasurements()[2]?.returnedCount, 1, "Restart does not retain old counts")
    }

    func testSelfTickSurvivesFullListAndRoutesAloneWithoutBecomingPeer() {
        let me = UUID()
        let relay = JamEndpoint("127.0.0.1", 49999)
        let group = RelayGroupClient(clientId: me)
        group.setIdentity(name: "Test", fingerprint: Array(1...8))
        group.connect(relay)
        group.setTicked(Set((0..<64).map { _ in UUID() }))
        group.setSelfMonitoring(true)
        let hello = group.buildHello()
        XCTAssertEqual(hello[68], 64)
        XCTAssertEqual(Array(hello[69..<85]), JamWire.bytes(of: me))
        XCTAssertEqual(group.sendTargets(for: []), [relay])
        let roster = JamWire.header(7, version: 2) + [UInt8](repeating: 0, count: 16) + [0, 0]
        _ = group.handleInbound(roster, from: relay, now: 1)
        XCTAssertTrue(group.everyReceiver(on: relay) { $0 == group.ownMemberAddress })
        XCTAssertEqual(group.sendTargets(for: [relay]), [relay], "Only one server copy")
        XCTAssertTrue(group.members.isEmpty)
        for kind: UInt8 in [1, 2, 4, 5, 12] {
            let packet = JamWire.header(kind, stream: 7, sequence: 3, version: 2)
                + JamWire.bytes(of: me) + [9, 8, 7]
            let result = group.handleInbound(packet, from: relay, now: 2)
            if kind == 1 || kind == 2 {
                XCTAssertEqual(result, .delivered(packet: JamWire.header(kind, stream: 7, sequence: 3) + [9, 8, 7],
                                                from: group.ownMemberAddress))
            } else { XCTAssertEqual(result, .consumed) }
        }
        group.setSelfMonitoring(false)
        XCTAssertTrue(group.sendTargets(for: []).isEmpty)
        let audio = JamWire.header(2, version: 2) + JamWire.bytes(of: me) + [1]
        XCTAssertEqual(group.handleInbound(audio, from: relay, now: 3), .consumed)
        group.setSelfMonitoring(true)
        group.connect(JamEndpoint("127.0.0.2", 49999))
        XCTAssertFalse(group.selfMonitoring)
        group.setSelfMonitoring(true)
        group.disconnect()
        XCTAssertFalse(group.selfMonitoring)
    }

    func testEveryOtherReceiverMustStillSupportCustomFrames() {
        let me = UUID(), other = UUID()
        let relay = JamEndpoint("127.0.0.1", 49999)
        let group = RelayGroupClient(clientId: me)
        group.connect(relay)
        group.setTicked([other])
        var roster = JamWire.header(7, version: 2) + [UInt8](repeating: 0, count: 16) + [1]
        roster += JamWire.bytes(of: other) + RelayGroupClient.encodeName("Other") + [1, 0]
        _ = group.handleInbound(roster, from: relay, now: 1)
        group.setSelfMonitoring(true)
        XCTAssertFalse(group.everyReceiver(on: relay) { $0 == group.ownMemberAddress })
        XCTAssertTrue(group.everyReceiver(on: relay) { _ in true })
    }

    func testRoundTripMatchesEitherArrivalOrderAndTimesOutAfterSuccess() {
        var monitor = SelfMonitorTiming()
        monitor.start(nowUs: 1_000_000)
        XCTAssertFalse(monitor.expired(nowUs: 5_999_999))
        XCTAssertTrue(monitor.expired(nowUs: 6_000_000))
        monitor.noteSent(stream: 1, sequence: 1, capturedUs: 1_010_000)
        monitor.noteEcho(stream: 1, sequence: 1, arrivedUs: 1_020_000)
        monitor.noteEcho(stream: 2, sequence: 1, arrivedUs: 1_040_000)
        monitor.noteSent(stream: 2, sequence: 1, capturedUs: 1_020_000)
        let result = monitor.takeMeasurements()
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[1]?.medianMs, 10)
        XCTAssertEqual(result[2]?.medianMs, 20)
        XCTAssertTrue(monitor.takeMeasurements().isEmpty)
        XCTAssertFalse(monitor.expired(nowUs: 6_039_999))
        XCTAssertTrue(monitor.expired(nowUs: 6_040_000))
        monitor.stop()
        XCTAssertFalse(monitor.expired(nowUs: 100_000_000))
        XCTAssertFalse(monitor.enabled)
    }

    func testTimingKeepsBoundedEntriesAndRejectsImpossibleOrRepeatedMeasurements() {
        var monitor = SelfMonitorTiming()
        monitor.start(nowUs: 0)
        for sequence in 0..<2_000 {
            monitor.noteSent(stream: 1, sequence: UInt32(sequence), capturedUs: Int64(sequence))
        }
        XCTAssertLessThanOrEqual(monitor.pendingCount, SelfMonitorTiming.capacity)
        monitor.noteEcho(stream: 1, sequence: 0, arrivedUs: 10_000)
        XCTAssertTrue(monitor.takeMeasurements().isEmpty, "Evicted captures cannot be measured")
        monitor.noteSent(stream: 9, sequence: 1, capturedUs: 100)
        monitor.noteEcho(stream: 9, sequence: 1, arrivedUs: 99)
        XCTAssertTrue(monitor.takeMeasurements().isEmpty)
        monitor.noteSent(stream: 9, sequence: 2, capturedUs: 100)
        monitor.noteEcho(stream: 9, sequence: 2, arrivedUs: 200)
        monitor.noteEcho(stream: 9, sequence: 2, arrivedUs: 201)
        XCTAssertEqual(monitor.takeMeasurements()[9]?.count, 1)
    }
}
