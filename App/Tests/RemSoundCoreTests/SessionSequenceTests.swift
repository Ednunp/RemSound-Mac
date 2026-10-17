import XCTest
import RemSoundJam
@testable import RemSoundCore

final class SessionSequenceTests: XCTestCase {
    private let password = "isolated sequence test"

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

    private func start(_ session: Session, plugins: Bool = false, codec: SendCodec = .opusLive) {
        let ready = expectation(description: "isolated sender running")
        session.onChange = { view in
            guard view.running else { return }
            session.onChange = nil
            ready.fulfill()
        }
        session.start(password: password, peerAddress: "127.0.0.1", send: true,
            receive: false, plugins: plugins, name: "Test", sendCodec: codec)
        wait(for: [ready], timeout: 3)
    }

    private func verify(_ packets: [Wire.Packet], codec: StreamFormat.Codec,
        file: StaticString = #filePath, line: UInt = #line) throws {
        let formats = packets.filter { $0.kind == .format }
        XCTAssertGreaterThanOrEqual(formats.count, 3, "Exercise two format refreshes", file: file, line: line)
        let first = try XCTUnwrap(formats.first, file: file, line: line)
        let format = try XCTUnwrap(StreamFormat.parse(first.payload), file: file, line: line)
        XCTAssertEqual(format.codec, codec.rawValue, file: file, line: line)
        XCTAssertTrue(formats.allSatisfy { $0.stream == first.stream }, file: file, line: line)
        let audio = packets.filter { $0.kind == .audio && $0.stream == first.stream }
        XCTAssertEqual(audio.map(\.sequence), [1, 2, 3],
            "Formats must not consume audio sequence numbers", file: file, line: line)
        let decoder = StreamDecoder(format)
        let credentials = try Credentials(password: password)
        for packet in audio {
            XCTAssertTrue(decoder.accept(packet, credentials: credentials), file: file, line: line)
        }
        XCTAssertEqual(decoder.logConcealed, 0,
            "A lossless stream must not insert concealed frames at refreshes", file: file, line: line)
    }

    func testCustomFormatRefreshDoesNotCreateAudioLoss() throws {
        let peer = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: peer.boundPort, testCapturePushDriven: true)
        defer { session.shutdown() }
        session.setJamulusStyle(true)
        start(session)
        var capable = Data([0]); capable.put(UInt64(1))
        capable.append(JamulusStyle.labFlagCanDecode)
        peer.send(Wire.packet(.heartbeat, payload: capable),
            to: Endpoint("127.0.0.1", session.testPorts.audio))
        _ = collect(peer, seconds: 0.1)
        var packets: [Wire.Packet] = []
        for _ in 0..<3 {
            session.testCapture([Float](repeating: 0.1, count: JamulusStyle.frames * 2))
            packets += collect(peer, seconds: 1.1)
        }
        try verify(packets, codec: .opusCustom)
    }

    func testOrdinaryFormatRefreshDoesNotCreateAudioLoss() throws {
        let peer = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        start(session)
        _ = collect(peer, seconds: 0.1)
        var packets: [Wire.Packet] = []
        for _ in 0..<3 {
            session.testCapture([Float](repeating: 0.1, count: SendCodec.opusLive.frames * 2))
            packets += collect(peer, seconds: 1.1)
        }
        try verify(packets, codec: .opus)
    }

    func testDAWFormatRefreshDoesNotCreateAudioLoss() throws {
        let peer = try UDP(port: 0, loopback: true)
        let plugin = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        start(session, plugins: true)
        let bridge = Endpoint("127.0.0.1", session.testPorts.bridge)
        var pid = Data(); pid.put(UInt32(12345))
        plugin.send(Bridge.encode(.hello, instance: 17, payload: pid), to: bridge)
        _ = collect(peer, seconds: 0.1)
        var samples = Data()
        for _ in 0..<(SendCodec.opusLive.frames * 2) { samples.put(Float(0.1).bitPattern) }
        var packets: [Wire.Packet] = []
        for _ in 0..<3 {
            plugin.send(Bridge.encode(.trackAudio, instance: 17, payload: samples), to: bridge)
            packets += collect(peer, seconds: 1.1)
        }
        try verify(packets, codec: .opus)
    }

    func testParallelPCMLanesKeepIndependentFrameIDsAcrossFormatRefreshes() throws {
        let peer = try UDP(port: 0, loopback: true)
        let plugin = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        start(session, plugins: true, codec: .pcm)
        let bridge = Endpoint("127.0.0.1", session.testPorts.bridge)
        var pid = Data(); pid.put(UInt32(12345))
        plugin.send(Bridge.encode(.hello, instance: 17, payload: pid), to: bridge)
        _ = collect(peer, seconds: 0.1)
        let samples = [Float](repeating: 0.1, count: Wire.pcmFrames * 2)
        var payload = Data()
        for sample in samples { payload.put(sample.bitPattern) }
        var packets: [Wire.Packet] = []
        for _ in 0..<3 {
            session.testCapture(samples)
            plugin.send(Bridge.encode(.trackAudio, instance: 17, payload: payload), to: bridge)
            packets += collect(peer, seconds: 1.1)
        }
        let audio = packets.filter { $0.kind == .audio }
        let streams = Set(audio.map(\.stream))
        XCTAssertEqual(streams.count, 2, "The fixture actually sends both physical-input and DAW lanes")
        let key = try Credentials(password: password)
        for stream in streams {
            let lane = audio.filter { $0.stream == stream }
            XCTAssertEqual(lane.map(\.sequence), [1, 2, 3])
            XCTAssertEqual(lane.map { $0.payload.u32(0) }, [1, 2, 3],
                "Another lane must not consume this stream's PCM frame IDs")
            let decoder = StreamDecoder(.pcm(key.fingerprint), jitterMs: 2, smoothness: 10)
            for packet in lane { XCTAssertTrue(decoder.accept(packet, credentials: key)) }
            XCTAssertEqual(decoder.logConcealed, 0, "Lossless parallel lanes must not invent PCM loss")
            XCTAssertEqual(decoder.queuedFrames, 3 * Wire.pcmFrames)
        }
    }
}
