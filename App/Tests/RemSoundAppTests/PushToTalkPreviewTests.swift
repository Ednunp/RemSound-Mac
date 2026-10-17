import AVFoundation
import Foundation
import RemSoundJam
import RemSoundRuntime
import XCTest
@testable import RemSoundApp

@MainActor
final class PushToTalkPreviewTests: XCTestCase {
    private final class Output: PushToTalkPreviewOutput {
        var plays = 0, stops = 0, success = true
        var onPlay: (() -> Void)?
        func play() -> Bool { plays += 1; onPlay?(); return success }
        func stop() { stops += 1 }
    }
    @MainActor
    private final class Harness {
        var allowed = true, failures = [String](), outputs = [Output]()
        var jobs: [(PushToTalkDoubleTapSpeed, PushToTalkPreviewRequest, @MainActor (Data?) -> Void)] = []
        var finishes: [@MainActor (Bool) -> Void] = []
        var duringMake: (() -> Void)?
        var duringPlay: (() -> Void)?
        var failMake = false, failPlay = false
        lazy var owner = PushToTalkPreview(isAllowed: { [weak self] in self?.allowed == true },
            prepare: { [weak self] in self?.jobs.append(($0, $1, $2)) },
            makeOutput: { [weak self] _, finish in
                guard let self else { throw NSError(domain: "fixture", code: 1) }
                if failMake { throw NSError(domain: "fixture", code: 1) }
                let result = Output(); result.success = !failPlay; outputs.append(result); finishes.append(finish)
                result.onPlay = duringPlay; duringMake?(); return result
            })
        func drain(_ index: Int = 0, data: Data? = Data(repeating: 0, count: 48)) { jobs[index].2(data) }
    }
    func testAllSpeedsRenderIdenticalClicksAtExactFramesWithSilentGapAndNoTail() throws {
        let clip: [Float] = [0.25, -0.5, 0, 0.5]
        for speed in PushToTalkDoubleTapSpeed.allCases {
            let samples = try XCTUnwrap(PushToTalkPreviewBuffer.render(clip, speed: speed))
            let offset = Int(speed.maximumIntervalMilliseconds) * PushToTalkPreviewBuffer.sampleRate / 1000 * 2
            XCTAssertEqual(Array(samples.prefix(clip.count)), clip)
            XCTAssertEqual(Array(samples[offset...]), clip); XCTAssertEqual(samples.count, offset + clip.count)
            XCTAssertTrue(samples[clip.count..<offset].allSatisfy { $0 == 0 })
        }
    }
    func testInvalidEmptyOddNonfiniteAndOverlongClipsAreRejected() {
        for clip: [Float] in [[], [1], [.nan, 0], [.infinity, 0], [Float](repeating: 0, count: (PushToTalkPreviewBuffer.maximumClipFrames + 1) * 2)] {
            XCTAssertNil(PushToTalkPreviewBuffer.render(clip, speed: .slow))
        }
    }
    func testFloatWaveHeaderCountsAndExactSampleBits() throws {
        let samples: [Float] = [0.125, -0.5, 0, 1]
        let data = try XCTUnwrap(PushToTalkPreviewBuffer.wave(samples))
        func u32(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) } }
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(u32(4), UInt32(data.count - 8)); XCTAssertEqual(u32(24), 48_000)
        XCTAssertEqual(data[20], 3); XCTAssertEqual(data[22], 2); XCTAssertEqual(data[34], 32)
        XCTAssertEqual(u32(40), UInt32(samples.count * 4)); XCTAssertEqual(data.count, 44 + samples.count * 4)
        for (i, sample) in samples.enumerated() { XCTAssertEqual(u32(44 + i * 4), sample.bitPattern) }
    }
    func testSDKReadsFiniteRenderedWaveWithoutOpeningAnAudioDevice() throws {
        let samples = try XCTUnwrap(PushToTalkPreviewBuffer.render([0.25, -0.25, 0, 0.5], speed: .fast))
        let data = try XCTUnwrap(PushToTalkPreviewBuffer.wave(samples))
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let url = URL(fileURLWithPath: base).appendingPathComponent("preview-\(UUID()).wav")
        try data.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(file.length, Int64(samples.count / 2)); XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
    }
    func testReplacementCancelsOldPreparationAndObsoleteResultsCannotStart() {
        let h = Harness(); h.owner.play(.slow); h.owner.play(.fast)
        guard h.jobs.count == 2 else { return XCTFail("Two requests must reach the injected producer") }
        XCTAssertTrue(h.jobs[0].1.isCancelled); h.drain(0); XCTAssertTrue(h.outputs.isEmpty)
        h.drain(1); XCTAssertEqual(h.outputs.count, 1); XCTAssertEqual(h.outputs.first?.plays, 1)
        h.owner.shutdown(); XCTAssertEqual(h.outputs.first?.stops, 1)
    }
    func testNaturalCompletionAndStaleCompletionRetireOnlyExactOutputOnce() {
        let h = Harness(); h.owner.play(.slow)
        guard h.jobs.count == 1 else { return XCTFail("Preparation missing") }; h.drain()
        guard h.outputs.count == 1 else { return XCTFail("Output missing") }
        h.owner.play(.medium); h.drain(1); h.finishes[0](true)
        XCTAssertEqual(h.outputs[0].stops, 1); XCTAssertEqual(h.outputs[1].stops, 0); XCTAssertTrue(h.owner.hasOutput)
        h.finishes[1](true); h.finishes[1](false); h.owner.stop()
        XCTAssertEqual(h.outputs[1].stops, 1); XCTAssertFalse(h.owner.hasOutput)
    }
    func testMuteBeforeDrainAndDuringFactoryRetiresWithoutPlaying() {
        let h = Harness(); h.owner.play(.fast)
        guard h.jobs.count == 1 else { return XCTFail("Preparation missing") }
        h.allowed = false; h.owner.refresh(); h.drain(); XCTAssertTrue(h.outputs.isEmpty)
        h.allowed = true; h.owner.play(.medium)
        h.duringMake = { [weak h] in h?.allowed = false; h?.owner.refresh() }; h.drain(1)
        XCTAssertEqual(h.outputs.first?.plays, 0); XCTAssertEqual(h.outputs.first?.stops, 1); XCTAssertFalse(h.owner.hasOutput)
    }
    func testMuteActiveOutputIsImmediateAndUnmutingDoesNotReplay() {
        let h = Harness(); h.owner.play(.fast)
        guard h.jobs.count == 1 else { return XCTFail("Preparation missing") }; h.drain()
        h.allowed = false; h.owner.refresh(); h.owner.refresh()
        XCTAssertEqual(h.outputs.first?.stops, 1); XCTAssertFalse(h.owner.hasOutput)
        h.allowed = true; h.owner.refresh(); XCTAssertEqual(h.jobs.count, 1)
    }
    func testShutdownCancelsQueuedWorkIsPermanentAndIdempotent() {
        let h = Harness(); h.owner.play(.fast)
        guard h.jobs.count == 1 else { return XCTFail("Preparation missing") }
        h.owner.shutdown(); h.owner.shutdown(); h.drain(); h.owner.play(.slow)
        XCTAssertTrue(h.jobs[0].1.isCancelled); XCTAssertTrue(h.outputs.isEmpty); XCTAssertEqual(h.jobs.count, 1)
    }
    func testFailedStartAndDecodeReportOnceWithExactCleanupAndNoRetry() {
        let h = Harness(); h.failPlay = true; h.owner.onFailure = { [weak h] in h?.failures.append($0) }; h.owner.play(.fast)
        guard h.jobs.count == 1 else { return XCTFail("Preparation missing") }; h.drain(); h.owner.refresh()
        XCTAssertEqual(h.outputs.first?.stops, 1); XCTAssertEqual(h.failures.count, 1); XCTAssertFalse(h.owner.hasOutput)
        h.owner.play(.slow); h.drain(1, data: nil); XCTAssertEqual(h.failures.count, 2)
    }
    func testCompletionInsideConstructionOrPlayCannotLeakOrRestartOutput() {
        let h = Harness(); h.owner.play(.fast)
        guard h.jobs.count == 1 else { return XCTFail("Preparation missing") }
        h.duringMake = { [weak h] in h?.finishes.last?(true) }; h.drain()
        XCTAssertEqual(h.outputs.first?.stops, 1); XCTAssertEqual(h.outputs.first?.plays, 0)
        h.duringMake = nil; h.owner.play(.medium); h.drain(1)
        h.duringPlay = { [weak h] in h?.finishes.last?(true) }
        h.owner.play(.slow); h.drain(2); h.finishes.last?(true)
        XCTAssertTrue(h.outputs.allSatisfy { $0.stops == 1 })
    }
    func testDisallowedPolicyDoesNotDecodeOrConstruct() {
        let h = Harness(); h.allowed = false; h.owner.play(.slow); XCTAssertTrue(h.jobs.isEmpty); XCTAssertTrue(h.outputs.isEmpty)
    }
    func testDuplicatePreparedResultCannotLeakOrReplaceAnActiveOutput() {
        let h = Harness(); h.owner.play(.fast)
        guard h.jobs.count == 1 else { return XCTFail("Preparation missing") }; h.drain(); h.drain()
        XCTAssertEqual(h.outputs.count, 1); h.owner.shutdown()
        XCTAssertTrue(h.outputs.allSatisfy { $0.stops == 1 })
    }
    func testNativeBackendRefusesIsolatedSilentHeadlessAndAXBeforeConstruction() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        for flags in [[], ["--silent"], ["--headless"], ["--check-accessibility"]] {
            let root = URL(fileURLWithPath: base).appendingPathComponent("preview-native-\(UUID())")
            let config = try RuntimeConfiguration(options: LaunchOptions.parse(flags + ["--config-dir", root.path], environment: ["REMSOUND_ALLOW_VISIBLE_UI_TESTS": "1"]))
            defer { try? FileManager.default.removeItem(at: root) }
            var constructed = 0
            XCTAssertThrowsError(try NativePushToTalkPreviewOutput(configuration: config, data: Data(), completion: { _ in }, create: { _ in
                constructed += 1; throw NSError(domain: "fixture", code: 1)
            }))
            XCTAssertEqual(constructed, 0)
        }
    }
    func testDeinitRetiresActiveResourceAndQueuedCompletionDoesNotRetainOwner() {
        var finish: (@MainActor (Data?) -> Void)?, natural: (@MainActor (Bool) -> Void)?
        let output = Output()
        var owner: PushToTalkPreview? = PushToTalkPreview(isAllowed: { true }, prepare: { _, _, completed in finish = completed },
            makeOutput: { _, completed in natural = completed; return output })
        weak var weakOwner = owner
        owner?.play(.fast); finish?(Data(repeating: 0, count: 48)); XCTAssertEqual(output.plays, 1)
        owner = nil; XCTAssertNil(weakOwner); XCTAssertEqual(output.stops, 1)
        finish?(Data(repeating: 0, count: 48)); natural?(true); XCTAssertEqual(output.plays, 1); XCTAssertEqual(output.stops, 1)
    }

    func testActualBundledKeyDecodesAndFitsEveryFinitePreview() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let clip = try XCTUnwrap(TypingAudioCache.decode(app.appendingPathComponent("Resources/default sounds/key 1.wav")))
        XCTAssertGreaterThan(clip.count, 1000)
        let peak = try XCTUnwrap(clip.map { abs($0) }.max()); XCTAssertGreaterThan(peak, 0)
        let first = try XCTUnwrap(clip.firstIndex { abs($0) >= peak * 0.05 })
        for speed in PushToTalkDoubleTapSpeed.allCases {
            let samples = try XCTUnwrap(PushToTalkPreviewBuffer.render(clip, speed: speed))
            let offset = Int(speed.maximumIntervalMilliseconds) * PushToTalkPreviewBuffer.sampleRate / 1000 * 2
            let second = try XCTUnwrap(samples[clip.count...].firstIndex { abs($0) >= peak * 0.05 })
            XCTAssertEqual(second - first, offset); XCTAssertEqual(Array(samples[offset...]), clip)
            XCTAssertTrue(samples[clip.count..<offset].allSatisfy { $0 == 0 })
            XCTAssertEqual(samples.count, offset + clip.count)
            XCTAssertNotNil(PushToTalkPreviewBuffer.wave(samples))
        }
    }

}
