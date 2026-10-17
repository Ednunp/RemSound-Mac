import XCTest
import RemSoundJam
@testable import RemSoundCore

final class SessionLaneTests: XCTestCase {
    private func collect(_ peer: UDP, seconds: Double) -> [Wire.Packet] {
        var packets: [Wire.Packet] = []
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < end {
            while let (data, _) = peer.receive() {
                if let packet = Wire.parse(data) { packets.append(packet) }
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return packets
    }

    private func start(_ session: Session, system: Bool = false, plugins: Bool = false) {
        let ready = expectation(description: "isolated sender running")
        session.onChange = { view in
            guard view.running else { return }
            session.onChange = nil
            ready.fulfill()
        }
        session.start(password: "isolated lane test", peerAddress: "127.0.0.1",
            send: true, receive: false, plugins: plugins, name: "Test", systemAudio: system,
            sendCodec: .opusLive)
        wait(for: [ready], timeout: 3)
    }

    func testEnabledButEmptyInputAndSystemLanesDoNotAnnounceStreams() throws {
        let peer = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        start(session, system: true)
        let packets = collect(peer, seconds: 1.7)
        XCTAssertTrue(packets.contains { $0.kind == .heartbeat })
        XCTAssertFalse(packets.contains { $0.kind == .format || $0.kind == .audio },
            "Enabled controls without source frames must not create empty Windows lanes")
    }

    func testFirstOrdinaryInputFrameIsPrecededByItsFormatAndSilenceStopsAnnouncements() throws {
        let peer = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        start(session)
        _ = collect(peer, seconds: 0.05)
        session.testCapture([Float](repeating: 0, count: SendCodec.opusLive.frames * 2))
        let packets = collect(peer, seconds: 0.1)
        let index = try XCTUnwrap(packets.firstIndex { $0.kind == .audio })
        let format = try XCTUnwrap(packets.prefix(index).first { $0.kind == .format })
        XCTAssertEqual(format.stream, packets[index].stream)
        XCTAssertEqual(format.payload[32], StreamFormat.Lane.wasapi.rawValue)
        XCTAssertFalse(collect(peer, seconds: 1.6).contains { $0.kind == .format },
            "A stopped source must not keep reviving a format-only stream")
    }

    func testCustomOnlyDestinationReceivesNoOrdinaryInputFormat() throws {
        let peer = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: peer.boundPort, testCapturePushDriven: true)
        defer { session.shutdown() }
        session.setJamulusStyle(true)
        start(session)
        var capable = Data([0])
        capable.put(UInt64(1))
        capable.append(JamulusStyle.labFlagCanDecode)
        peer.send(Wire.packet(.heartbeat, payload: capable),
            to: Endpoint("127.0.0.1", session.testPorts.audio))
        let initial = collect(peer, seconds: 0.1)
        session.testCapture([Float](repeating: 0.1, count: JamulusStyle.frames * 2))
        let packets = initial + collect(peer, seconds: 1.7)
        let formats = packets.filter { $0.kind == .format }
        XCTAssertEqual(formats.count, 1)
        let format = try XCTUnwrap(formats.first)
        XCTAssertEqual(StreamFormat.parse(format.payload)?.codec, StreamFormat.Codec.opusCustom.rawValue)
        XCTAssertTrue(packets.contains { $0.kind == .audio && $0.stream == format.stream })
    }

    func testEmptyPluginAudioDoesNotAnnounceAMixedLane() throws {
        let peer = try UDP(port: 0, loopback: true)
        let plugin = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        start(session, plugins: true)
        let bridge = Endpoint("127.0.0.1", session.testPorts.bridge)
        var pid = Data(); pid.put(UInt32(12345))
        plugin.send(Bridge.encode(.hello, instance: 17, payload: pid), to: bridge)
        _ = collect(peer, seconds: 0.05)
        plugin.send(Bridge.encode(.trackAudio, instance: 17), to: bridge)
        XCTAssertFalse(collect(peer, seconds: 0.1).contains { $0.kind == .format })
    }
}
