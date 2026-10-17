import AVFoundation
import XCTest
@testable import RemSoundCore

final class RecordingTests: XCTestCase {
    func testWAVWriterFlushesFiniteStereoAudioBeforeCompletion() throws {
        let folder = try IsolatedTestDirectory.root()
            .appendingPathComponent("remsound-recording-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.wav")
        let finished = expectation(description: "recording finalized")
        var recorder: RecordingFile? = try RecordingFile(url: url)
        for _ in 0..<20 {
            recorder?.append(Array(repeating: [Float(0.25), Float(-0.25)], count: 240).flatMap { $0 })
        }
        recorder?.finish { result, drops, error in
            XCTAssertEqual(result, url)
            XCTAssertEqual(drops, 0)
            XCTAssertNil(error)
            finished.fulfill()
        }
        recorder = nil
        wait(for: [finished], timeout: 3)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 48000)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)
        XCTAssertEqual(file.length, 4800)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800)!
        try file.read(into: buffer)
        XCTAssertGreaterThan(buffer.floatChannelData![0][100], 0.2)
        XCTAssertLessThan(buffer.floatChannelData![1][100], -0.2)
    }
    func testOggOpusWriterMakesAFileThatStartsAndEndsItsStream() throws {
        let folder = try IsolatedTestDirectory.root()
            .appendingPathComponent("remsound-opus-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for channels in RecordingChannels.allCases {
            let url = folder.appendingPathComponent("test \(channels.rawValue).opus")
            let finished = expectation(description: "Ogg Opus finalized")
            var recorder: RecordingFile? = try RecordingFile(url: url, format: .opus192, channels: channels)
            for block in 0..<200 {
                recorder?.append((0..<240).flatMap { i -> [Float] in
                    let v = Float(0.3 * sin(2 * Double.pi * 997 * Double(block * 240 + i) / 48000))
                    return [v, v]
                })
            }
            recorder?.finish { _, drops, error in
                XCTAssertEqual(drops, 0)
                XCTAssertNil(error)
                finished.fulfill()
            }
            recorder = nil
            wait(for: [finished], timeout: 3)
            let bytes = [UInt8](try Data(contentsOf: url))
            XCTAssertEqual(Array(bytes.prefix(4)), Array("OggS".utf8))
            XCTAssertEqual(bytes[5], 0x02, "the first page begins the stream")
            XCTAssertEqual(Array(bytes[28..<36]), Array("OpusHead".utf8))
            XCTAssertEqual(Int(bytes[37]), channels == .stereo ? 2 : 1)
            XCTAssertGreaterThan(Int(bytes[38]) | Int(bytes[39]) << 8, 0, "the encoder's lookahead is declared")
            // The last page: end of stream, its granule the pre-skip plus exactly the 48000 frames given.
            guard let last = (0..<(bytes.count - 4)).last(where: { Array(bytes[$0..<($0 + 4)]) == Array("OggS".utf8) }) else {
                return XCTFail("no pages")
            }
            XCTAssertEqual(bytes[last + 5], 0x04)
            let granule = (0..<8).reduce(0) { $0 | Int(bytes[last + 6 + $1]) << (8 * $1) }
            XCTAssertEqual(granule, (Int(bytes[38]) | Int(bytes[39]) << 8) + 48_000)
            XCTAssertLessThan(bytes.count, 48_000, "one second at 192 kbps is about 24 kB")
        }
        XCTAssertEqual(RecordingFormat.opus192.fileExtension, "opus")
        XCTAssertEqual(RecordingFormat.opus256.opusBitrate, 256_000)
        XCTAssertNil(RecordingFormat.flac24.opusBitrate)
    }
    func testFLACWriterRoundTripsLosslessAudio() throws {
        let folder = try IsolatedTestDirectory.root()
            .appendingPathComponent("remsound-flac-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.flac")
        let finished = expectation(description: "FLAC finalized")
        var recorder: RecordingFile? = try RecordingFile(url: url, format: .flac24)
        for _ in 0..<20 {
            recorder?.append(Array(repeating: [Float(0.25), Float(-0.25)], count: 240).flatMap { $0 })
        }
        recorder?.finish { _, drops, error in
            XCTAssertEqual(drops, 0)
            XCTAssertNil(error)
            finished.fulfill()
        }
        recorder = nil
        wait(for: [finished], timeout: 3)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertEqual(file.fileFormat.sampleRate, 48000)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800)!
        try file.read(into: buffer)
        XCTAssertEqual(buffer.frameLength, 4800)
        XCTAssertEqual(buffer.floatChannelData![0][100], 0.25, accuracy: 0.001)
        XCTAssertEqual(buffer.floatChannelData![1][100], -0.25, accuracy: 0.001)
    }

    func testMonoWAVWriterMixesLeftAndRight() throws {
        let folder = try IsolatedTestDirectory.root()
            .appendingPathComponent("remsound-mono-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("mono.wav")
        let finished = expectation(description: "mono recording finalized")
        let recorder = try RecordingFile(url: url, format: .wav24, channels: .mono)
        recorder.append(Array(repeating: [Float(0.5), Float(-0.25)], count: 240)
            .flatMap { $0 })
        recorder.finish { _, drops, error in
            XCTAssertEqual(drops, 0)
            XCTAssertNil(error)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 3)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, 240)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 240)!
        try file.read(into: buffer)
        XCTAssertEqual(buffer.floatChannelData![0][100], 0.125, accuracy: 0.001)
    }

    func testMonoFLACWriterMixesLeftAndRight() throws {
        let folder = try IsolatedTestDirectory.root()
            .appendingPathComponent("remsound-mono-flac-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("mono.flac")
        let finished = expectation(description: "mono FLAC finalized")
        let recorder = try RecordingFile(url: url, format: .flac24, channels: .mono)
        for _ in 0..<20 {
            recorder.append(Array(repeating: [Float(0.5), Float(-0.25)], count: 240)
                .flatMap { $0 })
        }
        recorder.finish { _, drops, error in
            XCTAssertEqual(drops, 0)
            XCTAssertNil(error)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 3)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, 4800)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800)!
        try file.read(into: buffer)
        XCTAssertEqual(buffer.floatChannelData![0][100], 0.125, accuracy: 0.001)
    }
}
