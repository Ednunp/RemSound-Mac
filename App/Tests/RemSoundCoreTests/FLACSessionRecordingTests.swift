import AVFoundation
import XCTest
@testable import RemSoundCore

final class FLACSessionRecordingTests: XCTestCase {
    func testSessionPassesCompressionToMixedAndSplitPeerWriters() throws {
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let folder = URL(fileURLWithPath: root).appendingPathComponent("flac-session-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for split in [false, true] {
            for (level, maximumBlock) in [(0, 1152), (8, 4096)] {
                let peer = try UDP(port: 0, loopback: true)
                let credentials = try Credentials(password: "isolated FLAC session")
                let session = Session(testPeerPort: peer.boundPort)
                defer { session.shutdown() }
                let started = expectation(description: "FLAC isolated session started")
                let recording = expectation(description: "FLAC recording started")
                let finished = expectation(description: "FLAC recording finalized")
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
                session.start(password: "isolated FLAC session", peerAddress: "127.0.0.1",
                    send: false, receive: true, plugins: false, name: "Test")
                wait(for: [started], timeout: 3)
                let destination = folder.appendingPathComponent("\(split)-\(level)" + (split ? "" : ".flac"))
                session.startRecording(url: destination, source: .received, format: .flac24,
                    split: split, flacCompression: level)
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
                session.stopRecording()
                wait(for: [finished], timeout: 3)
                let url = split ? try XCTUnwrap(FileManager.default.contentsOfDirectory(at: destination,
                    includingPropertiesForKeys: nil).first) : destination
                let bytes = [UInt8](try Data(contentsOf: url))
                // These are the pinned libFLAC presets' encoded STREAMINFO maximum block sizes.
                XCTAssertEqual(Int(bytes[10]) * 256 + Int(bytes[11]), maximumBlock)
                let reader = try AVAudioFile(forReading: url)
                XCTAssertGreaterThan(reader.length, 0)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: reader.processingFormat,
                    frameCapacity: AVAudioFrameCount(reader.length)))
                try reader.read(into: buffer)
                let data = try XCTUnwrap(buffer.floatChannelData)
                XCTAssertGreaterThan((0..<Int(buffer.frameLength)).map { abs(data[0][$0]) }.max() ?? 0, 0.24)
                XCTAssertGreaterThan((0..<Int(buffer.frameLength)).map { abs(data[1][$0]) }.max() ?? 0, 0.24)
            }
        }
    }
}
