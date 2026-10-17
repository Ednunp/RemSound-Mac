import AVFoundation
import XCTest
@testable import RemSoundApp

final class TypingAudioCacheTests: XCTestCase {
    private func directory() throws -> URL {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("typing-cache-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func wave(_ url: URL, rate: Double, channels: AVAudioChannelCount, frames: UInt32) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) { data[channel][frame] = Float(sin(Double(frame) * .pi / 16) * 0.2) }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    func testMono22050HzIsDecodedOnceIntoFinite48kStereo() throws {
        let url = try directory().appendingPathComponent("key 1.wav")
        try wave(url, rate: 22_050, channels: 1, frames: 2_205)
        let samples = try XCTUnwrap(TypingAudioCache.decode(url))
        XCTAssertEqual(samples.count, 9_600)
        XCTAssertTrue(samples.allSatisfy(\.isFinite)); XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.1)
        for frame in 0..<(samples.count / 2) { XCTAssertEqual(samples[frame * 2], samples[frame * 2 + 1], accuracy: 0.00001) }
    }
    func testMissingCorruptAndOversizedAssetsAreIgnored() throws {
        let root = try directory()
        try Data("invalid wave".utf8).write(to: root.appendingPathComponent("key 2.wav"))
        try wave(root.appendingPathComponent("key 3.wav"), rate: 48_000, channels: 2, frames: 480_001)
        XCTAssertTrue(TypingAudioCache.bundled(directory: root).assets.isEmpty)
        XCTAssertTrue(TypingAudioCache.bundled(directory: nil).assets.isEmpty)
    }
    func testShippedFourKeysAndPasswordDecodeWithoutOpeningOutput() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cache = TypingAudioCache.bundled(directory: app.appendingPathComponent("Resources/default sounds"))
        XCTAssertEqual(cache.keys, [0, 1, 2, 3]); XCTAssertEqual(cache.assets.count, 5)
        XCTAssertNotNil(cache.assets[8])
        for samples in cache.assets.values {
            XCTAssertFalse(samples.isEmpty); XCTAssertTrue(samples.count.isMultiple(of: 2))
            XCTAssertTrue(samples.allSatisfy(\.isFinite))
        }
        for (index, samples) in cache.assets {
            let name = index == 8 ? "passkey.wav" : "key \(index + 1).wav"
            let file = try AVAudioFile(forReading: app.appendingPathComponent("Resources/default sounds/\(name)"))
            let expected = Double(file.length) * 48_000 / file.processingFormat.sampleRate
            XCTAssertEqual(Double(samples.count / 2), expected, accuracy: 1)
        }
    }
    func testInvalidNativeCacheFailsBeforeEngineConstruction() {
        for assets: [Int: [Float]] in [[:], [0: [0.1]], [0: [0.1, 0.2], 8: [.nan, 0]],
            [0: [0.1, 0.2], -1: [0.1, 0.2]], [8: [0.1, 0.2]]] {
            XCTAssertThrowsError(try TypingAudioOutput(cache: TypingAudioCache(assets: assets)))
        }
    }
}
