import XCTest
import RemSoundJam
@testable import RemSoundCore

final class ReceiveArtifactTests: XCTestCase {
    func testProfilePreservesClickAndMigratesLegacyArtifactNumbers() throws {
        let profile = ConnectionProfile(title: "Artifacts", displayName: "Test", manualPeerAddress: "",
            selectedPeerAddresses: [], sendInput: false, receiveAudio: false, allowPlugins: false, reconnectOnOpen: false)
        let original = try JSONEncoder().encode(profile)
        let originalObject = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        XCTAssertEqual(originalObject["receiveArtifact"] as? Int, 2, "New profiles use Noise burst")
        for (raw, expected) in [(0, 2), (1, 2), (3, 3), (99, 2)] {
            var object = originalObject
            object["receiveArtifact"] = raw
            let loaded = try JSONDecoder().decode(ConnectionProfile.self,
                from: JSONSerialization.data(withJSONObject: object))
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded)) as? [String: Any])
            XCTAssertEqual(saved["receiveArtifact"] as? Int, expected, "Artifact choice must survive profile loading and saving")
        }
        var legacy = originalObject
        legacy.removeValue(forKey: "receiveArtifact")
        let loaded = try JSONDecoder().decode(ConnectionProfile.self, from: JSONSerialization.data(withJSONObject: legacy))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded)) as? [String: Any])
        XCTAssertEqual(saved["receiveArtifact"] as? Int, 2, "Old profiles migrate to Noise burst")
    }

    func testProfileRoundTripDirtyEqualityAndMalformedArtifact() throws {
        var profile = ConnectionProfile(title: "Artifact", displayName: "Test", manualPeerAddress: "",
            selectedPeerAddresses: [], sendInput: false, receiveAudio: false, allowPlugins: false,
            reconnectOnOpen: false, receiveArtifact: .click)
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(ConnectionProfile.self, from: data), profile)
        profile.receiveArtifact = .noiseBurst
        XCTAssertNotEqual(try JSONDecoder().decode(ConnectionProfile.self, from: data), profile)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["receiveArtifact"] = "click"
        XCTAssertThrowsError(try JSONDecoder().decode(ConnectionProfile.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testEncryptedDecoderUsesTheLiveChoiceAndRetainsItAcrossSenderRestart() throws {
        let credentials = try Credentials(password: "isolated artifact")
        func packet(_ sequence: UInt32) throws -> Wire.Packet {
            var pcm = Data()
            for _ in 0..<233 { pcm.append(contentsOf: [0, 0, 32, 0, 0, 16]) }
            var payload = Data(); payload.put(sequence); payload.append(contentsOf: [0, 1])
            payload.append(try credentials.seal(pcm))
            return try XCTUnwrap(Wire.parse(Wire.packet(.audio, stream: 7, sequence: sequence, payload: payload)))
        }
        for choice in ConcealmentArtifact.allCases {
            let decoder = StreamDecoder(StreamFormat.pcm(credentials.fingerprint), jitterMs: 2, smoothness: 10, artifact: choice)
            XCTAssertTrue(decoder.accept(try packet(2002), credentials: credentials))
            _ = decoder.read(233)
            let gap = decoder.read(96)
            XCTAssertEqual(gap.contains { $0 != 0 }, choice == .noiseBurst)
            XCTAssertTrue(decoder.accept(try packet(2003), credentials: credentials))
            let resumed = decoder.read(96)
            XCTAssertEqual(resumed[0], choice == .noiseBurst ? 0 : 0.25, accuracy: 0.000001)
            XCTAssertEqual(resumed[66], 0.25, accuracy: 0.000001)
            let queued = decoder.queuedFrames
            let other: ConcealmentArtifact = choice == .noiseBurst ? .click : .noiseBurst
            decoder.setArtifact(other)
            XCTAssertEqual(decoder.artifact, other)
            XCTAssertEqual(decoder.queuedFrames, queued, "Live selection does not discard queued sound")
            XCTAssertTrue(decoder.accept(try packet(1), credentials: credentials))
            XCTAssertEqual(decoder.queuedFrames, 233)
            XCTAssertEqual(decoder.artifact, other, "Sender restart retains the chosen gap policy")
            _ = decoder.read(233)
            XCTAssertEqual(decoder.read(96).contains { $0 != 0 }, other == .noiseBurst)
        }
    }

    func testSessionAppliesArtifactToExistingAndNewStreamsAndPublishesIt() throws {
        let peer = try UDP(port: 0, loopback: true)
        let credentials = try Credentials(password: "isolated artifact")
        let session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        let started = expectation(description: "isolated receiver")
        session.onChange = { view in
            guard view.running else { return }
            session.onChange = nil
            XCTAssertEqual(view.receiveArtifact, .click)
            started.fulfill()
        }
        session.start(password: "isolated artifact", peerAddress: "127.0.0.1", send: false,
            receive: true, monitorInApp: false, plugins: false, name: "Test", receiveJitterMs: 200, receiveArtifact: .click)
        wait(for: [started], timeout: 3)
        let endpoint = Endpoint("127.0.0.1", session.testPorts.audio)
        func format(_ stream: UInt16) {
            peer.send(Wire.packet(.format, stream: stream, payload: StreamFormat.pcm(credentials.fingerprint).encode()), to: endpoint)
        }
        func waitForStreams(_ count: Int) {
            let end = ProcessInfo.processInfo.systemUptime + 1
            while session.testReceiveArtifacts().count < count && ProcessInfo.processInfo.systemUptime < end {
                Thread.sleep(forTimeInterval: 0.001)
            }
            XCTAssertEqual(session.testReceiveArtifacts().count, count)
        }
        format(7); waitForStreams(1)
        XCTAssertEqual(session.testReceiveArtifacts(), [.click])
        let changed = expectation(description: "artifact observed")
        session.onChange = { view in
            guard view.receiveArtifact == .noiseBurst else { return }
            session.onChange = nil; changed.fulfill()
        }
        session.setReceiveArtifact(.noiseBurst)
        wait(for: [changed], timeout: 3)
        XCTAssertEqual(session.testReceiveArtifacts(), [.noiseBurst])
        format(8); waitForStreams(2)
        XCTAssertEqual(session.testReceiveArtifacts(), [.noiseBurst, .noiseBurst])
        session.setReceiveArtifact(.click)
        XCTAssertEqual(session.testReceiveArtifacts(), [.click, .click])
    }
}
