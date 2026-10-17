import Foundation
import XCTest
import RemSoundJam
@_spi(NativeReplay) import RemSoundSim
@testable import RemSoundCore

final class NativeReplayEquivalenceTests: XCTestCase {
    private func run(_ scenario: MacScenario) throws -> MacResult {
        let sender = try XCTUnwrap(OpusSender(bitrate: 320_000))
        return try NativeReplaySimulation.runNative(scenario, frames: 120, channels: 2, encode: sender.encode)
    }
    func testActualNativeRecordingTextReplayKeepsEachPacketTimeOrderAndOutput() throws {
        var scenario = MacScenario("native receiver recording roundtrip")
        scenario.seconds = 12; scenario.seed = 1; scenario.network = .internet
        scenario.packetFrames = 120; scenario.sendCard = SimCard(frames: 120, jitterMs: 0)
        scenario.bufferMs = 30; scenario.keepAudio = true; scenario.recordNetwork = true
        let original = try run(scenario), record = try XCTUnwrap(original.recording)
        let loaded = try NetworkRecording.read(record.text())
        XCTAssertEqual(loaded.text(), record.text())
        XCTAssertEqual(loaded.packets.count, record.packets.count)
        XCTAssertEqual(loaded.streams.first?.codec, 2)
        XCTAssertEqual(loaded.streams.first?.frameSamples, 120)
        let replay = try NetworkReplay.from(loaded)
        XCTAssertGreaterThan(replay.lost, 0)
        var target = scenario
        target.network = .replaying(replay, oneWayMs: 12)
        let repeated = try run(target), twice = try XCTUnwrap(repeated.recording)
        func first(_ value: NetworkRecording) -> [UInt32: Double] {
            var result: [UInt32: Double] = [:]
            for packet in value.packets where result[packet.sequence] == nil { result[packet.sequence] = packet.ms }
            return result
        }
        let was = first(record), now = first(twice), shared = Set(was.keys).intersection(now.keys)
        XCTAssertGreaterThanOrEqual(shared.count, was.count - 2)
        XCTAssertLessThanOrEqual(now.count, was.count + 2)
        let offsets = shared.map { now[$0]! - was[$0]! }.sorted(), offset = offsets[offsets.count / 2]
        let worst = shared.map { abs(now[$0]! - was[$0]! - offset) }.max() ?? .infinity
        print("Native replay roundtrip: shared=\(shared.count), worstMs=\(worst), delayMs=\(original.findings.delayMedianMs)/\(repeated.findings.delayMedianMs), glitches=\(original.findings.glitches)/\(repeated.findings.glitches), late=\(original.lateDropped)/\(repeated.lateDropped), underruns=\(original.underruns)/\(repeated.underruns), PCMEqual=\(original.audio == repeated.audio)")
        XCTAssertLessThan(worst, 0.002)
        XCTAssertEqual(record.packets.map(\.sequence), twice.packets.map(\.sequence))
        XCTAssertLessThan(abs(original.findings.delayMedianMs - repeated.findings.delayMedianMs), 1)
        XCTAssertEqual(original.findings.glitches, repeated.findings.glitches)
        XCTAssertEqual(original.lateDropped, repeated.lateDropped)
        XCTAssertEqual(original.underruns, repeated.underruns)
        XCTAssertEqual(original.concealed, repeated.concealed)
        XCTAssertEqual(original.gapsNotRepaired, repeated.gapsNotRepaired)
    }
    func testHandmadeStallLossOvertakingAndDoublingReachActualNativeOutputAtTheirTimes() throws {
        var recording = NetworkRecording()
        recording.streams = [.init(index: 0, from: "192.0.2.1:1", streamId: 7, lane: "Mixed", format: "synthetic", codec: 2, frameSamples: 120)]
        for index in 0..<4000 where index != 2000 {
            let sent = Double(index) * 2.5
            var arrival = sent + 5
            if sent >= 3000 && sent < 3120 { arrival = 3125 }
            if index == 2800 { arrival += 4 }
            recording.packets.append(.init(ms: arrival, stream: 0, sequence: UInt32(index + 1000), bytes: 60))
            if index == 3200 { recording.packets.append(.init(ms: arrival + 0.5, stream: 0, sequence: UInt32(index + 1000), bytes: 60)) }
        }
        recording.packets.sort { $0.ms < $1.ms }
        var scenario = MacScenario("handmade native faults")
        scenario.seconds = 10; scenario.seed = 1; scenario.packetFrames = 120
        scenario.sendCard = SimCard(frames: 120, jitterMs: 0); scenario.bufferMs = 15
        scenario.network = .replaying(try NetworkReplay.from(recording), oneWayMs: 5)
        let result = try run(scenario)
        let first = try XCTUnwrap(result.findings.firstGlitchAt)
        print("Handmade native faults: firstGlitch=\(first), lost=\(result.packetsLost), late=\(result.lateDropped), underruns=\(result.underruns)")
        XCTAssertEqual(first, 3, accuracy: 0.3)
        XCTAssertEqual(result.packetsLost, 1)
        XCTAssertGreaterThanOrEqual(result.lateDropped, 1)
        XCTAssertTrue(result.nativeCodec)
        XCTAssertGreaterThan(result.nativeDecodedFrames, 0)
    }
    func testActualNativeSourceSelectionUsesMostPacketsOrExplicitStreamWithoutDescriptorRewrite() throws {
        var recording = NetworkRecording()
        recording.streams = [
            .init(index: 0, from: "192.0.2.1:1", streamId: 7, lane: "Mixed", format: "first", codec: 2, frameSamples: 120),
            .init(index: 1, from: "192.0.2.2:2", streamId: 8, lane: "Mixed", format: "second", codec: 2, frameSamples: 480)
        ]
        recording.packets = (0..<40).map { .init(ms: Double($0) * 2.5, stream: 0, sequence: UInt32($0), bytes: 60) }
            + (0..<80).map { .init(ms: Double($0) * 10, stream: 1, sequence: UInt32($0), bytes: 100) }
        recording.packets.sort { $0.ms < $1.ms }
        let original = recording.text()
        let chosen = try NativeReplaySimulation.run(original, seconds: 0.8)
        let explicit = try NativeReplaySimulation.run(original, stream: 0, seconds: 0.8)
        XCTAssertEqual(chosen.stream, 1); XCTAssertEqual(chosen.recordedFrameSamples, 480)
        XCTAssertEqual(explicit.stream, 0); XCTAssertEqual(explicit.recordedFrameSamples, 120)
        XCTAssertTrue(chosen.nativeCodec && explicit.nativeCodec)
        XCTAssertGreaterThan(chosen.nativeDecodedFrames, 0); XCTAssertGreaterThan(explicit.nativeDecodedFrames, 0)
        XCTAssertEqual(recording.text(), original)
    }

    func testActualNativeRecordingReplayAndHandmadeUseObservedDecoderWaitCounts() throws {
        let pair = try ProductTestPack.nativeReplayRoundTrip()
        let handmade = try ProductTestPack.nativeReplayHandmade()
        print("Actual decoder waits: original=\(pair.originalReorderWaits), replayed=\(pair.replayedReorderWaits), handmade=\(handmade.waits)")
        XCTAssertGreaterThan(pair.originalReorderWaits, 0)
        XCTAssertEqual(pair.replayedReorderWaits, pair.originalReorderWaits)
        XCTAssertGreaterThan(handmade.waits, 0)
    }
}
