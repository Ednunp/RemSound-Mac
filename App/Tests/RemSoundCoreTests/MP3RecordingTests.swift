import AVFoundation
import XCTest
@testable import RemSoundCore

final class MP3RecordingTests: XCTestCase {
    private func folder() throws -> URL {
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let url = URL(fileURLWithPath: root).appendingPathComponent("mp3-recording-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testEveryMP3ChoiceWrites48kHzCBRAndFinalizesPlayableMonoOrStereo() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        for bitrate in [128, 192, 256, 320] {
            let choice = try XCTUnwrap(RecordingFormat(rawValue: "mp3\(bitrate)"))
            XCTAssertEqual(choice.fileExtension, "mp3")
            for channels in RecordingChannels.allCases {
                let url = root.appendingPathComponent("\(bitrate)-\(channels.rawValue).mp3")
                let file = try RecordingFile(url: url, format: choice, channels: channels)
                let frames = 48_167 // Includes a tail shorter than one MP3 frame.
                file.append((0..<frames).flatMap { frame -> [Float] in
                    let left = Float(0.3 * sin(2 * Double.pi * 997 * Double(frame) / 48_000))
                    let right = channels == .mono ? -left : Float(0.15 * sin(2 * Double.pi * 1889 * Double(frame) / 48_000))
                    return [left, right]
                })
                let completed = expectation(description: "MP3 drain and final tag")
                file.finish { _, drops, error in
                    XCTAssertEqual(drops, 0)
                    XCTAssertNil(error)
                    completed.fulfill()
                }
                wait(for: [completed], timeout: 10)
                let bytes = [UInt8](try Data(contentsOf: url))
                let packets = try headers(bytes)
                XCTAssertGreaterThan(packets.count, frames / 1152)
                XCTAssertTrue(packets.allSatisfy { $0.channels == (channels == .mono ? 1 : 2) })
                XCTAssertTrue(packets.dropFirst().allSatisfy { $0.bitrate == bitrate })
                let tagOffset = 4 + (channels == .mono ? 17 : 32)
                XCTAssertEqual(String(bytes: bytes[tagOffset..<(tagOffset + 4)], encoding: .ascii), "Info")
                let taggedFrames = bytes[(tagOffset + 8)..<(tagOffset + 12)].reduce(0) { ($0 << 8) | Int($1) }
                XCTAssertGreaterThan(taggedFrames, 0, "The initial placeholder must be replaced after flush.")
                XCTAssertEqual(taggedFrames, packets.count - 1)
                let decoded = try AVAudioFile(forReading: url)
                XCTAssertEqual(decoded.fileFormat.sampleRate, 48_000)
                XCTAssertEqual(decoded.fileFormat.channelCount, channels == .mono ? 1 : 2)
                XCTAssertGreaterThanOrEqual(decoded.length, AVAudioFramePosition(frames))
                XCTAssertLessThanOrEqual(decoded.length, AVAudioFramePosition(frames + 2304))
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: decoded.processingFormat,
                    frameCapacity: AVAudioFrameCount(decoded.length)))
                try decoded.read(into: buffer)
                let audio = try XCTUnwrap(buffer.floatChannelData)
                let count = Int(buffer.frameLength)
                let leftRMS = sqrt((0..<count).reduce(0.0) { $0 + Double(audio[0][$1] * audio[0][$1]) } / Double(count))
                if channels == .mono {
                    XCTAssertLessThan(leftRMS, 0.0002, "Opposite channels must cancel when mixed to mono.")
                } else {
                    let rightRMS = sqrt((0..<count).reduce(0.0) { $0 + Double(audio[1][$1] * audio[1][$1]) } / Double(count))
                    XCTAssertGreaterThan(leftRMS, 0.18)
                    XCTAssertGreaterThan(rightRMS, 0.08)
                    XCTAssertEqual(leftRMS / rightRMS, 2, accuracy: 0.15)
                }
            }
        }
    }

    func testMP3ChoicesPersistWithoutChangingLegacyWAVDefault() throws {
        for bitrate in [128, 192, 256, 320] {
            let format = try XCTUnwrap(RecordingFormat(rawValue: "mp3\(bitrate)"))
            let profile = ConnectionProfile(title: "Synthetic MP3", displayName: "Fixture", manualPeerAddress: "",
                selectedPeerAddresses: [], sendInput: false, receiveAudio: false, allowPlugins: false,
                reconnectOnOpen: false, recordingFormat: format,
                recordingChannels: .mono)
            let restored = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile))
            XCTAssertEqual(restored.recordingFormat, format)
            XCTAssertEqual(restored.recordingChannels, .mono)
        }
        let profile = ConnectionProfile(title: "Legacy", displayName: "Fixture", manualPeerAddress: "",
            selectedPeerAddresses: [], sendInput: false, receiveAudio: false, allowPlugins: false, reconnectOnOpen: false)
        let data = try JSONEncoder().encode(profile)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "recordingFormat")
        let restored = try JSONDecoder().decode(ConnectionProfile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.recordingFormat, .wav24)
    }

    func testProgressiveMP3IsPlayableBeforeFinalizationAndRejectsClosedWrites() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("progressive.mp3")
        let snapshot = root.appendingPathComponent("interrupted.mp3")
        let file = try MP3File(url: url, channels: 2, bitrate: 320)
        defer { try? file.close() }
        XCTAssertThrowsError(try file.write([0]))
        let block = (0..<480).flatMap { frame -> [Float] in
            let sample = Float(0.25 * sin(2 * Double.pi * 1000 * Double(frame) / 48_000))
            return [sample, sample]
        }
        for _ in 0..<300 { try file.write(block) }
        let bytes = try Data(contentsOf: url)
        XCTAssertGreaterThan(try headers([UInt8](bytes), allowPartialTail: true).count, 100)
        try bytes.write(to: snapshot)
        let interrupted = try AVAudioFile(forReading: snapshot)
        XCTAssertGreaterThan(interrupted.length, 96_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: interrupted.processingFormat,
            frameCapacity: AVAudioFrameCount(interrupted.length)))
        try interrupted.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertGreaterThan((0..<Int(buffer.frameLength)).map { abs(samples[0][$0]) }.max() ?? 0, 0.2)
        try file.close()
        XCTAssertThrowsError(try file.write(block))
        XCTAssertNoThrow(try file.close())
    }

    func testMP3ShutdownWaitsForActiveAndAlreadyFinishingFiles() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        let started = expectation(description: "hardware-free MP3 session")
        session.onChange = { view in
            guard view.running else { return }
            session.onChange = nil
            started.fulfill()
        }
        session.start(password: "isolated MP3 shutdown", peerAddress: "", send: false,
            receive: false, plugins: false, name: "Test")
        wait(for: [started], timeout: 3)
        let first = root.appendingPathComponent("first.mp3")
        let second = root.appendingPathComponent("second.mp3")
        session.startRecording(url: first, source: .both, format: .mp3320)
        session.stopRecording()
        session.startRecording(url: second, source: .both, format: .mp3128)
        let drained = expectation(description: "MP3 writers finalized before shutdown completion")
        drained.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            session.shutdown {
                for url in [first, second] {
                    do {
                        let bytes = [UInt8](try Data(contentsOf: url))
                        XCTAssertGreaterThan(try self.headers(bytes).count, 1)
                        XCTAssertNoThrow(try AVAudioFile(forReading: url))
                    } catch { XCTFail("Unfinished MP3 at shutdown: \(error)") }
                }
                drained.fulfill()
            }
        }
        wait(for: [drained], timeout: 5)
    }

    private func headers(_ bytes: [UInt8], allowPartialTail: Bool = false) throws -> [(bitrate: Int, channels: Int)] {
        let bitrates = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
        var position = 0
        var result = [(bitrate: Int, channels: Int)]()
        while position < bytes.count {
            // An interrupted stream can end during its last frame; finalized files must have no partial tail.
            if allowPartialTail && bytes.count - position < 4 { break }
            guard bytes.count - position >= 4, bytes[position] == 0xff,
                bytes[position + 1] & 0xfe == 0xfa,
                bytes[position + 2] >> 2 & 3 == 1 else {
                throw ProtocolError.invalid("Invalid or truncated 48 kHz MPEG1 Layer3 frame.")
            }
            let bitrate = bitrates[Int(bytes[position + 2] >> 4)]
            let length = 144_000 * bitrate / 48_000 + Int(bytes[position + 2] >> 1 & 1)
            if allowPartialTail && bitrate > 0 && length > bytes.count - position { break }
            guard bitrate > 0, length <= bytes.count - position else {
                throw ProtocolError.invalid("Invalid MP3 bitrate or unfinished frame.")
            }
            result.append((bitrate, bytes[position + 3] >> 6 == 3 ? 1 : 2))
            position += length
        }
        return result
    }
}
