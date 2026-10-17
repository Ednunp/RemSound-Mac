import Foundation
import XCTest
import RemSoundJam
@_spi(NativeReplay) import RemSoundSim
@testable import RemSoundCore

final class CustomReplayTests: XCTestCase {
    private func recording(codec: Int = 3, frames: Int = 64, missing: Set<Int> = [40]) -> String {
        var value = NetworkRecording()
        value.streams = [.init(index: 0, from: "10.0.0.9:1", streamId: 7, lane: "private lane",
            format: "private format", codec: codec, frameSamples: frames)]
        value.facts = [.init("buffer ms", "15")]
        value.packets = (0..<120).filter { !missing.contains($0) }.map {
            .init(ms: Double($0 * frames) / 48 + 5, stream: 0, sequence: UInt32($0), bytes: 60)
        }
        value.packets.append(.init(ms: Double(80 * frames) / 48 + 5.5, stream: 0, sequence: 80, bytes: 60))
        value.packets.sort { $0.ms < $1.ms }
        return value.text()
    }
    func testActualCustom64RecordedRunUsesNativeCodecAndKeepsOriginalDescriptor() throws {
        let text = recording(), date = Date(timeIntervalSince1970: 0)
        let result = try NativeReplaySimulation.run(text, seconds: 0.25, oneWayMs: 5, date: date)
        XCTAssertTrue(result.nativeCodec)
        XCTAssertGreaterThan(result.nativeDecodedFrames, 0)
        XCTAssertEqual(result.recordedCodec, 3)
        XCTAssertEqual(result.recordedFrameSamples, 64)
        XCTAssertEqual(result.packetFrames, 64)
        XCTAssertEqual(result.lost, 1)
        XCTAssertEqual(result.doubled, 1)
        XCTAssertGreaterThan(result.concealed, 0)
        XCTAssertEqual(result, try NativeReplaySimulation.run(text, seconds: 0.25, oneWayMs: 5, date: date))
        XCTAssertTrue(result.comparisons.isEmpty)
    }
    func testReferenceComparisonIncludesCustom64AcrossSixBuffersWithFreshFates() throws {
        let text = recording(codec: 1, frames: 120), date = Date(timeIntervalSince1970: 0)
        let result = try NativeReplaySimulation.compare(text, seconds: 0.4, oneWayMs: 5, date: date)
        XCTAssertEqual(result.comparisons.count, 18)
        guard result.comparisons.count == 18 else { return }
        XCTAssertEqual(result.comparisons.map(\.packetFrames), Array(repeating: 64, count: 6) + Array(repeating: 120, count: 6) + Array(repeating: 480, count: 6))
        for (index, row) in result.comparisons.enumerated() {
            XCTAssertEqual(row.bufferMs, [5, 8, 10, 15, 20, 30][index % 6])
            XCTAssertGreaterThan(row.nativeDecodedFrames, 0)
            XCTAssertGreaterThan(row.packetsLost, 0)
            XCTAssertEqual(row.codec, index < 6 ? "custom-opus-celt" : "ordinary-opus-lowdelay")
            XCTAssertEqual(row.seed, 1)
        }
        XCTAssertEqual(result.recordedCodec, 1)
        XCTAssertEqual(result.recordedFrameSamples, 120)
        XCTAssertFalse(result.nativeCodec)
        XCTAssertEqual(result, try NativeReplaySimulation.compare(text, seconds: 0.4, oneWayMs: 5, date: date))
        let data = try JSONEncoder().encode(result)
        XCTAssertLessThan(data.count, 16384)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private format"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("10.0.0.9"))
    }
    func testUnsupportedCustomGeometryDoesNotSilentlyUsePureModelOrOrdinaryCodec() throws {
        XCTAssertThrowsError(try NativeReplaySimulation.run(recording(frames: 256), seconds: 0.4))
        XCTAssertThrowsError(try NativeReplaySimulation.compare(recording(frames: 256), seconds: 0.4))
        XCTAssertThrowsError(try NativeReplaySimulation.run(recording(frames: 65), seconds: 0.25))
    }
    func testActualCustomOutputContainsKnownToneAndSilentRightAndReleasesSource() throws {
        let result = try ProductTestPack.customReplayWaveform()
        XCTAssertTrue(result.native)
        XCTAssertTrue(result.finite)
        XCTAssertTrue(result.tone)
        XCTAssertTrue(result.stereo)
        XCTAssertTrue(result.wire)
        XCTAssertTrue(result.deterministic)
        XCTAssertTrue(result.released)
    }
    func testCustomLossConcealsEightPacketsButCountsLargerUnrepairedGap() throws {
        // Stop before the 160 ms recording repeats its loss pattern.
        let eight = try NativeReplaySimulation.run(recording(missing: Set(40..<48)), seconds: 0.15)
        XCTAssertEqual(eight.concealed, 8)
        XCTAssertEqual(eight.gapsNotRepaired, 0)
        let nine = try NativeReplaySimulation.run(recording(missing: Set(40..<49)), seconds: 0.15)
        XCTAssertEqual(nine.concealed, 0)
        XCTAssertEqual(nine.gapsNotRepaired, 1)
        XCTAssertEqual(nine.lost, 9)
        XCTAssertGreaterThan(nine.nativeDecodedFrames, 0)
    }
    func testCustomEncoderErrorAndUnsupportedMonoGeometryNeverBecomeFallbackSuccess() throws {
        var scenario = MacScenario("custom error")
        scenario.seconds = 0.05; scenario.packetFrames = 64; scenario.sendCard = SimCard(frames: 64)
        XCTAssertThrowsError(try NativeReplaySimulation.runNative(scenario, frames: 64, channels: 2, codec: .opusCustom, encode: { _ in nil }))
        XCTAssertThrowsError(try NativeReplaySimulation.runNative(scenario, frames: 64, channels: 1, codec: .opusCustom, encode: { _ in XCTFail("refused before encoder"); return nil }))
        XCTAssertThrowsError(try NativeReplaySimulation.runNative(scenario, frames: 64, channels: 2, codec: .opus, encode: { _ in XCTFail("wrong codec geometry"); return nil }))
        let sender = try XCTUnwrap(OpusCustomSender(frames: 64))
        XCTAssertNil(sender.encode([Float](repeating: 0, count: 126)))
    }
}
