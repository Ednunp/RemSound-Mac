import XCTest
import RemSoundJam
@testable import RemSoundCore

final class ReceiveSmoothnessTests: XCTestCase {
    func testProfileRoundTripLegacyDefaultAndBounds() throws {
        var profile = ConnectionProfile(title: "Smoothness", displayName: "Test", manualPeerAddress: "",
            selectedPeerAddresses: [], sendInput: false, receiveAudio: false, allowPlugins: false,
            reconnectOnOpen: false, receiveSmoothness: 10)
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(ConnectionProfile.self, from: data), profile)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "receiveSmoothness")
        let migrated = try JSONDecoder().decode(ConnectionProfile.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(migrated.receiveSmoothness, 3)
        XCTAssertNotEqual(profile, migrated)
        old["receiveSmoothness"] = 99
        XCTAssertEqual(try JSONDecoder().decode(ConnectionProfile.self,
            from: JSONSerialization.data(withJSONObject: old)).receiveSmoothness, 10)
        profile.receiveSmoothness = 1
        XCTAssertNotEqual(profile, migrated)
    }

    func testActualEncryptedDecoderChoiceAffectsTrimmingAndKeepsRestartChoice() throws {
        let credentials = try Credentials(password: "isolated smoothness")
        for level in [1, 3, 10] {
            let decoder = StreamDecoder(StreamFormat.pcm(credentials.fingerprint), jitterMs: 10, smoothness: level)
            for frame in 1...20 {
                var pcm = Data()
                for _ in 0..<233 { pcm.append(contentsOf: [0, 0, 32, 0, 0, 32]) }
                var payload = Data(); payload.put(UInt32(frame)); payload.append(contentsOf: [0, 1])
                payload.append(try credentials.seal(pcm))
                let packet = try XCTUnwrap(Wire.parse(Wire.packet(.audio, stream: 7,
                    sequence: UInt32(frame), payload: payload)))
                XCTAssertTrue(decoder.accept(packet, credentials: credentials))
            }
            _ = decoder.read(240)
            XCTAssertEqual(decoder.trimmedFrames > 0, level != 10)
            if level == 1 { XCTAssertEqual(decoder.queuedFrames, 480) }
            if level == 3 { XCTAssertEqual(decoder.queuedFrames, 960) }
            if level == 10 { XCTAssertEqual(decoder.queuedFrames, 4420) }
            decoder.setSmoothness(10)
            XCTAssertEqual(decoder.smoothness, 10)
            let restarted = StreamDecoder(StreamFormat.pcm(credentials.fingerprint), jitterMs: 10, smoothness: level)
            for frame in [2002, 1] {
                var payload = Data(); payload.put(UInt32(frame)); payload.append(contentsOf: [0, 1])
                payload.append(try credentials.seal(Data(repeating: 0, count: 233 * 6)))
                let packet = try XCTUnwrap(Wire.parse(Wire.packet(.audio, stream: 7,
                    sequence: UInt32(frame), payload: payload)))
                XCTAssertTrue(restarted.accept(packet, credentials: credentials))
            }
            XCTAssertEqual(restarted.queuedFrames, 233, "Sender restart clears old audio")
            XCTAssertEqual(restarted.smoothness, level, "Sender restart retains the chosen policy")
        }
    }

    func testSessionAppliesChoiceToExistingAndNewStreamsAndPublishesIt() throws {
        let peer = try UDP(port: 0, loopback: true)
        let credentials = try Credentials(password: "isolated smoothness")
        let session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        let started = expectation(description: "isolated receiver")
        session.onChange = { view in
            guard view.running else { return }
            session.onChange = nil
            XCTAssertEqual(view.receiveSmoothness, 1)
            started.fulfill()
        }
        session.start(password: "isolated smoothness", peerAddress: "127.0.0.1", send: false,
            receive: true, monitorInApp: false, plugins: false, name: "Test",
            receiveJitterMs: 200, receiveSmoothness: 1)
        wait(for: [started], timeout: 3)
        let endpoint = Endpoint("127.0.0.1", session.testPorts.audio)
        func format(_ stream: UInt16) {
            peer.send(Wire.packet(.format, stream: stream, payload: StreamFormat.pcm(credentials.fingerprint).encode()), to: endpoint)
        }
        func waitForStreams(_ count: Int) {
            let end = ProcessInfo.processInfo.systemUptime + 1
            while session.testReceiveSmoothness().count < count && ProcessInfo.processInfo.systemUptime < end {
                Thread.sleep(forTimeInterval: 0.001)
            }
            XCTAssertEqual(session.testReceiveSmoothness().count, count)
        }
        format(7); waitForStreams(1)
        XCTAssertEqual(session.testReceiveSmoothness(), [1])
        let changed = expectation(description: "smoothness observed")
        session.onChange = { view in
            guard view.receiveSmoothness == 10 else { return }
            session.onChange = nil; changed.fulfill()
        }
        session.setReceiveSmoothness(10)
        wait(for: [changed], timeout: 3)
        XCTAssertEqual(session.testReceiveSmoothness(), [10])
        format(8); waitForStreams(2)
        XCTAssertEqual(session.testReceiveSmoothness(), [10, 10])
        session.setReceiveSmoothness(0)
        XCTAssertEqual(session.testReceiveSmoothness(), [1, 1])
    }
}
