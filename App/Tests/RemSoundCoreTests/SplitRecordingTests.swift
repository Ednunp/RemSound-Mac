import AVFoundation
import XCTest
@testable import RemSoundCore

final class SplitRecordingTests: XCTestCase {
    func testSelectedPeerGetsSeparateFinalizedWAV() throws {
        let folder = try IsolatedTestDirectory.root()
            .appendingPathComponent("remsound-split-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let peer = try UDP(port: 0, loopback: true)
        let credentials = try Credentials(password: "isolated test")
        let session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        let started = expectation(description: "session started")
        let recording = expectation(description: "split recording started")
        let finished = expectation(description: "recording finalized")
        var didStart = false, didRecord = false, didFinish = false
        session.onChange = { view in
            if !didStart && view.running && view.status.hasPrefix("Running.") {
                didStart = true
                started.fulfill()
            }
            if !didRecord && view.recording && view.status.hasPrefix("Recording ") {
                didRecord = true
                recording.fulfill()
            }
            if !didFinish && view.status.hasPrefix("Recording finished.") {
                didFinish = true
                finished.fulfill()
            }
        }
        session.start(password: "isolated test", peerAddress: "127.0.0.1",
            send: false, receive: true, plugins: false, name: "Test")
        wait(for: [started], timeout: 3)
        session.startRecording(url: folder, source: .received, split: true)
        wait(for: [recording], timeout: 3)
        let remote = Endpoint("127.0.0.1", session.testPorts.audio)
        peer.send(Wire.packet(.format, stream: 7,
            payload: StreamFormat.pcm(credentials.fingerprint).encode()), to: remote)
        var pcm = Data()
        for _ in 0..<Wire.pcmFrames { pcm.append(contentsOf: [0, 0, 32, 0, 0, 224]) }
        for frame in 1...16 {
            var payload = Data()
            payload.put(UInt32(frame))
            payload.append(contentsOf: [0, 1])
            payload.append(try credentials.seal(pcm))
            peer.send(Wire.packet(.audio, stream: 7, sequence: UInt32(frame), payload: payload),
                to: remote)
            Thread.sleep(forTimeInterval: 0.005)
        }
        Thread.sleep(forTimeInterval: 0.1)
        session.stopRecording()
        wait(for: [finished], timeout: 3)
        let files = try FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let file = try AVAudioFile(forReading: files[0])
        XCTAssertGreaterThan(file.length, 0)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let left = UnsafeBufferPointer(start: buffer.floatChannelData![0],
            count: Int(buffer.frameLength))
        XCTAssertGreaterThan(left.map { abs($0) }.max() ?? 0, 0.2)
    }
}
