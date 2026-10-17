import XCTest
import RemSoundJam
@testable import RemSoundCore

final class SendPacketSizeTests: XCTestCase {
    func testWindowsPacketSizesAndAnnouncedFormats() throws {
        let fingerprint = Data(repeating: 4, count: 8)
        for (codec, standard, small) in [(SendCodec.pcm, 233, 120), (.opusBroadcast, 960, 480), (.opusLive, 120, 120)] {
            for (size, frames) in [(SendPacketSize.standard, standard), (.small, small)] {
                XCTAssertEqual(size.frames(for: codec), frames)
                let format = try XCTUnwrap(StreamFormat.parse(codec.format(fingerprint, packetSize: size).encode()))
                XCTAssertEqual(format.frames, frames)
                XCTAssertEqual(format.codec, codec == .pcm ? 1 : 2)
                XCTAssertEqual(format.fingerprint, fingerprint)
            }
        }
        XCTAssertEqual(JamulusStyle.frames, 64, "Custom mode has its own independent frame size")
    }

    func testProfileRoundTripAndLegacyStandardDefault() throws {
        let profile = ConnectionProfile(title: "Packets", displayName: "Test", manualPeerAddress: "",
            selectedPeerAddresses: [], sendInput: false, receiveAudio: false, allowPlugins: false,
            reconnectOnOpen: false, sendCodec: .opusBroadcast, sendPacketSize: .small)
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(ConnectionProfile.self, from: data), profile)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "sendPacketSize")
        let restored = try JSONDecoder().decode(ConnectionProfile.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(restored.sendPacketSize, .standard)
        XCTAssertNotEqual(restored, profile, "Packet changes must participate in profile dirty detection")
    }

    private func collect(_ socket: UDP, seconds: Double = 0.08) -> [Wire.Packet] {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        var packets: [Wire.Packet] = []
        while ProcessInfo.processInfo.systemUptime < end {
            while let (data, _) = socket.receive() {
                if let packet = Wire.parse(data) { packets.append(packet) }
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return packets
    }

    private func ready(_ session: Session, codec: SendCodec, size: SendPacketSize) {
        let started = expectation(description: "isolated packet sender")
        session.onChange = { view in
            guard view.running else { return }
            session.onChange = nil
            XCTAssertEqual(view.sendPacketSize, size)
            started.fulfill()
        }
        session.start(password: "packet test", peerAddress: "127.0.0.1", send: true,
            receive: false, plugins: true, name: "Test", sendCodec: codec, sendPacketSize: size)
        wait(for: [started], timeout: 3)
    }

    private func verifyAudio(_ packets: [Wire.Packet], codec: SendCodec, frames: Int, lane: StreamFormat.Lane) throws -> UInt16 {
        let index = try XCTUnwrap(packets.firstIndex { $0.kind == .audio })
        let audio = packets[index]
        let announced = try XCTUnwrap(packets[..<index].last { $0.kind == .format && $0.stream == audio.stream })
        let format = try XCTUnwrap(StreamFormat.parse(announced.payload))
        XCTAssertEqual(format.frames, frames)
        XCTAssertEqual(announced.payload[32], lane.rawValue)
        let credentials = try Credentials(password: "packet test")
        if codec == .pcm {
            XCTAssertEqual(audio.payload[4], 0)
            XCTAssertEqual(audio.payload[5], 1, "Small/standard PCM remain one fragment")
            XCTAssertEqual(try credentials.open(Data(audio.payload.dropFirst(6))).count, frames * 6)
        }
        let decoder = StreamDecoder(format, jitterMs: 2)
        XCTAssertTrue(decoder.accept(audio, credentials: credentials), "Real encrypted frames must decode")
        XCTAssertEqual(decoder.queuedFrames, frames)
        return audio.stream
    }

    func testInputPacketResizeStartsANewStreamAndClearsPluginPartialAudio() throws {
        let peer = try UDP(port: 0, loopback: true)
        let plugin = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        ready(session, codec: .pcm, size: .small)
        _ = collect(peer)
        session.testCapture([Float](repeating: 0.2, count: 120 * 2))
        let old = try verifyAudio(collect(peer), codec: .pcm, frames: 120, lane: .wasapi)
        let bridge = Endpoint("127.0.0.1", session.testPorts.bridge)
        var pid = Data(); pid.put(UInt32(1))
        plugin.send(Bridge.encode(.hello, instance: 19, payload: pid), to: bridge)
        _ = collect(peer)
        var partial = Data()
        for _ in 0..<119 * 2 { partial.put(Float(0.9).bitPattern) }
        plugin.send(Bridge.encode(.trackAudio, instance: 19, payload: partial), to: bridge)
        _ = collect(peer)
        let changed = expectation(description: "new packet size observed")
        session.onChange = { view in
            guard view.sendPacketSize == .standard else { return }
            session.onChange = nil
            changed.fulfill()
        }
        session.setAudioOptions(send: true, receive: false, plugins: true,
            sendCodec: .pcm, sendPacketSize: .standard)
        wait(for: [changed], timeout: 3)
        _ = collect(peer)
        var insufficient = Data()
        for _ in 0..<114 * 2 { insufficient.put(Float(0.3).bitPattern) }
        plugin.send(Bridge.encode(.trackAudio, instance: 19, payload: insufficient), to: bridge)
        XCTAssertFalse(collect(peer).contains { $0.kind == .audio }, "Old pending plugin frames must not leak into a new packet")
        session.testCapture([Float](repeating: 0.3, count: 233 * 2))
        XCTAssertNotEqual(try verifyAudio(collect(peer), codec: .pcm, frames: 233, lane: .wasapi), old)
    }

    func testPluginSendsEveryCodecAtBothActualPacketSizes() throws {
        for codec in SendCodec.allCases {
            for size in SendPacketSize.allCases {
                let peer = try UDP(port: 0, loopback: true)
                let plugin = try UDP(port: 0, loopback: true)
                let session = Session(testPeerPort: peer.boundPort)
                defer { session.shutdown() }
                ready(session, codec: codec, size: size)
                _ = collect(peer)
                let bridge = Endpoint("127.0.0.1", session.testPorts.bridge)
                var pid = Data(); pid.put(UInt32(1))
                plugin.send(Bridge.encode(.hello, instance: 23, payload: pid), to: bridge)
                _ = collect(peer)
                let frames = size.frames(for: codec)
                var samples = Data()
                for frame in 0..<frames {
                    let value = Float(sin(Double(frame) * 0.07) * 0.2)
                    samples.put(value.bitPattern); samples.put(value.bitPattern)
                }
                plugin.send(Bridge.encode(.trackAudio, instance: 23, payload: samples), to: bridge)
                _ = try verifyAudio(collect(peer), codec: codec, frames: frames, lane: .mixed)
            }
        }
    }
}
