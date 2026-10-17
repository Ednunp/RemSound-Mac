import AVFoundation
import RemSoundJam
import XCTest
@testable import RemSoundCore

final class RecordingBypassTests: XCTestCase {
    func testMixedAndSplitBypassRecordRawWhilePlaybackStaysShaped() throws {
        for split in [false, true] {
            for bypass in [false, true] {
                try checkRecording(split: split, bypass: bypass)
            }
        }
    }

    func testProfileRoundTripAndLegacyBypassDefault() throws {
        let profile = ConnectionProfile(title: "Test", displayName: "Test", manualPeerAddress: "",
            selectedPeerAddresses: [], sendInput: false, receiveAudio: true,
            allowPlugins: false, reconnectOnOpen: false, recordingBypassShaping: true)
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(ConnectionProfile.self, from: data), profile)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "recordingBypassShaping")
        XCTAssertFalse(try JSONDecoder().decode(ConnectionProfile.self,
            from: JSONSerialization.data(withJSONObject: legacy)).recordingBypassShaping)
    }

    func testBypassAlsoExcludesEQFromMixedAndSplitRecordings() throws {
        for split in [false, true] { try checkRecording(split: split, bypass: true, equalize: true) }
    }

    private func checkRecording(split: Bool, bypass: Bool, equalize: Bool = false) throws {
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let folder = URL(fileURLWithPath: root).appendingPathComponent("bypass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent(split ? "tracks" : "mix.wav")
        let peer = try UDP(port: 0, loopback: true)
        let credentials = try Credentials(password: "isolated test")
        let session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        let started = expectation(description: "session started")
        let recording = expectation(description: "recording started")
        let finished = expectation(description: "recording finalized")
        var didStart = false, didRecord = false, didFinish = false
        session.onChange = { view in
            if !didStart && view.running && view.status.hasPrefix("Running.") {
                didStart = true; started.fulfill()
            }
            if !didRecord && view.recording && view.status.hasPrefix("Recording ") {
                didRecord = true; recording.fulfill()
            }
            if !didFinish && view.status.hasPrefix("Recording finished.") {
                didFinish = true; finished.fulfill()
            }
        }
        session.start(password: "isolated test", peerAddress: "127.0.0.1", send: false,
            receive: true, plugins: false, name: "Test")
        wait(for: [started], timeout: 3)
        session.setAllPeerShaping(true)
        session.setPeerMix(address: "127.0.0.1", mix: PeerMix(volume: 50, pan: 100,
            eq: PeerEq(simpleDb: equalize ? [6, 6, 6] : [0, 0, 0])))
        session.setListening(volume: 50, muted: false)
        session.startRecording(url: destination, source: .received, format: .wavFloat,
            split: split, bypassShaping: bypass)
        wait(for: [recording], timeout: 3)
        let remote = Endpoint("127.0.0.1", session.testPorts.audio)
        peer.send(Wire.packet(.format, stream: 7,
            payload: StreamFormat.pcm(credentials.fingerprint).encode()), to: remote)
        var pcm = Data()
        for _ in 0..<Wire.pcmFrames { pcm.append(contentsOf: [0, 0, 32, 0, 0, 224]) }
        for frame in 1...20 {
            var payload = Data()
            payload.put(UInt32(frame)); payload.append(contentsOf: [0, 1])
            payload.append(try credentials.seal(pcm))
            peer.send(Wire.packet(.audio, stream: 7, sequence: UInt32(frame), payload: payload), to: remote)
            Thread.sleep(forTimeInterval: 0.005)
        }
        Thread.sleep(forTimeInterval: 0.1)
        let playback = session.testPlayback(24_000)
        session.stopRecording()
        wait(for: [finished], timeout: 3)
        let url = split ? try XCTUnwrap(FileManager.default.contentsOfDirectory(at: destination,
            includingPropertiesForKeys: nil).first) : destination
        let file = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(file.length, 0)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let maxima = (0..<2).map { channel in
            UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength))
                .map { abs($0) }.max() ?? 0
        }
        XCTAssertEqual(maxima[0], bypass ? 0.25 : 0, accuracy: 0.002)
        XCTAssertEqual(maxima[1], bypass ? 0.25 : (split ? 0.125 : 0.0625), accuracy: 0.002)
        XCTAssertFalse(playback.isEmpty)
        let left = stride(from: 0, to: playback.count, by: 2).map { abs(playback[$0]) }.max() ?? 0
        let right = stride(from: 1, to: playback.count, by: 2).map { abs(playback[$0]) }.max() ?? 0
        XCTAssertEqual(left, 0, accuracy: 0.002)
        if equalize {
            XCTAssertGreaterThan(right, 0.08, "EQ still changes live playback")
            XCTAssertLessThan(right, 0.25)
        } else { XCTAssertEqual(right, 0.0625, accuracy: 0.002) }
    }
}
