import AVFoundation
import AudioSupport
import XCTest
@testable import RemSoundCore

final class FLACRecordingTests: XCTestCase {
    private func folder() throws -> URL {
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let url = URL(fileURLWithPath: root).appendingPathComponent("flac-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func samples(_ frames: Int) -> [Float] {
        (0..<frames).flatMap { i -> [Float] in
            if i < 8 {
                let edge: [Float] = [.nan, .infinity, -.infinity, 2, -2, 1, -1, 0]
                return [edge[i], edge[7 - i]]
            }
            let phase = Double(i) / 48_000
            return [Float(0.6 * sin(2 * .pi * (phase * 97 + phase * phase * 341))),
                Float(0.35 * sin(2 * .pi * (phase * 113 + phase * phase * 207)))]
        }
    }

    private func quantized(_ value: Float, bits: Int) -> Int32 {
        Int32(min(1, max(-1, value)) * Float(bits == 16 ? 32_767 : 8_388_607))
    }

    private func verify(_ url: URL, source: [Float], bits: Int, channels: RecordingChannels) throws {
        let reader = try AVAudioFile(forReading: url)
        XCTAssertEqual(reader.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(reader.fileFormat.channelCount, channels == .mono ? 1 : 2)
        XCTAssertEqual(Int(reader.length), source.count / 2)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: reader.processingFormat,
            frameCapacity: AVAudioFrameCount(reader.length)))
        try reader.read(into: buffer)
        XCTAssertEqual(Int(buffer.frameLength), source.count / 2)
        let data = try XCTUnwrap(buffer.floatChannelData)
        let scale = Double(bits == 16 ? 32_768 : 8_388_608)
        for frame in 0..<Int(buffer.frameLength) {
            let left = source[frame * 2].isFinite ? source[frame * 2] : 0
            let right = source[frame * 2 + 1].isFinite ? source[frame * 2 + 1] : 0
            let expectedLeft = quantized(channels == .mono ? (left + right) * 0.5 : left, bits: bits)
            if Int32((Double(data[0][frame]) * scale).rounded()) != expectedLeft {
                XCTFail("Incorrect decoded sample at frame \(frame), \(bits) bit, \(channels)")
                return
            }
            if channels == .stereo && Int32((Double(data[1][frame]) * scale).rounded()) != quantized(right, bits: bits) {
                XCTFail("Incorrect decoded right sample at frame \(frame), \(bits) bit")
                return
            }
        }
    }

    func testAllCompressionLevelsLosslesslyPreserveDepthChannelsAndPartialTail() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = samples(48_167)
        var sizes = [Int]()
        var blockSizes = [Int]()
        for level in 0...8 {
            for bits in [16, 24] {
                for channels in RecordingChannels.allCases {
                    let url = root.appendingPathComponent("\(level)-\(bits)-\(channels.rawValue).flac")
                    let file = try RecordingFile(url: url, format: bits == 16 ? .flac16 : .flac24,
                        channels: channels, flacCompression: level)
                    file.append(source)
                    let done = expectation(description: "FLAC finalization")
                    file.finish { _, drops, error in
                        XCTAssertEqual(drops, 0)
                        XCTAssertNil(error)
                        done.fulfill()
                    }
                    wait(for: [done], timeout: 10)
                    try verify(url, source: source, bits: bits, channels: channels)
                    let bytes = [UInt8](try Data(contentsOf: url))
                    XCTAssertEqual(Array(bytes.prefix(4)), Array("fLaC".utf8))
                    XCTAssertEqual(((Int(bytes[20]) & 1) << 4 | Int(bytes[21]) >> 4) + 1, bits)
                    if bits == 24 && channels == .stereo {
                        sizes.append(bytes.count)
                        blockSizes.append(Int(bytes[10]) * 256 + Int(bytes[11]))
                    }
                }
            }
        }
        // Compression must actually change encoder work/output, rather than only saving a setting.
        XCTAssertGreaterThan(Set(blockSizes).count, 1)
        XCTAssertGreaterThan(Set(sizes).count, 2)
        XCTAssertLessThan(sizes[8], sizes[0])
    }

    func testProgressiveSnapshotSurvivesAbandonmentAndClosedWriterRejectsWrites() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = samples(144_167)
        let url = root.appendingPathComponent("active.flac")
        let snapshot = root.appendingPathComponent("interrupted.flac")
        var file: FLACFile? = try FLACFile(url: url, channels: 2, bits: 24, compression: 5)
        XCTAssertThrowsError(try file?.write([0]))
        try file?.write(source)
        try file?.synchronize()
        try FileManager.default.copyItem(at: url, to: snapshot)
        file = nil // No close/final metadata: model an interrupted encoder.
        XCTAssertTrue(try Data(contentsOf: url) == Data(contentsOf: snapshot),
            "Destroying an abandoned encoder must not finish its tail or rewrite metadata.")
        let reader = try AVAudioFile(forReading: snapshot)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 144_167))
        try reader.read(into: buffer)
        XCTAssertGreaterThanOrEqual(Int(buffer.frameLength), 144_167 - 4608)
        XCTAssertLessThanOrEqual(Int(buffer.frameLength), 144_167)
        let audio = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertGreaterThan((0..<Int(buffer.frameLength)).map { abs(audio[0][$0]) }.max() ?? 0, 0.5)
        let closed = try FLACFile(url: root.appendingPathComponent("finished.flac"), channels: 1, bits: 16, compression: 0)
        try closed.write(source)
        try closed.close()
        XCTAssertNoThrow(try closed.close())
        XCTAssertThrowsError(try closed.write(source))
        XCTAssertThrowsError(try closed.synchronize())
        XCTAssertThrowsError(try FLACFile(url: root.appendingPathComponent("missing/file.flac"), channels: 2, bits: 16, compression: 5))
        XCTAssertThrowsError(try FLACFile(url: root.appendingPathComponent("invalid.flac"), channels: 2, bits: 16, compression: 9))
        XCTAssertThrowsError(try FLACFile(url: root.appendingPathComponent("overflow.flac"), channels: Int.max, bits: 16, compression: Int.max))
    }

    func testCompressionProfileRoundTripLegacyDefaultAndClamping() throws {
        for level in 0...8 {
            let profile = ConnectionProfile(title: "FLAC fixture", displayName: "Test", manualPeerAddress: "",
                selectedPeerAddresses: [], sendInput: false, receiveAudio: false, allowPlugins: false,
                reconnectOnOpen: false, recordingFormat: .flac24, flacCompression: level)
            let restored = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile))
            XCTAssertEqual(restored.flacCompression, level)
            XCTAssertEqual(restored.recordingFormat, .flac24)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
            object.removeValue(forKey: "flacCompression")
            XCTAssertEqual(try JSONDecoder().decode(ConnectionProfile.self,
                from: JSONSerialization.data(withJSONObject: object)).flacCompression, 5)
            for (invalid, expected) in [(-999, 0), (999, 8)] {
                object["flacCompression"] = invalid
                XCTAssertEqual(try JSONDecoder().decode(ConnectionProfile.self,
                    from: JSONSerialization.data(withJSONObject: object)).flacCompression, expected)
            }
        }
    }
}
