import Foundation
import XCTest
import RemSoundJam
@_spi(NativeReplay) import RemSoundSim
@testable import RemSoundCore

final class Custom128ReplayTests: XCTestCase {
    private func recording(frames: Int = 128, missing: Set<Int> = [40]) -> String {
        var value = NetworkRecording()
        value.streams = [.init(index: 0, from: "192.0.2.1:1", streamId: 7, lane: "Mixed",
            format: "synthetic custom128", codec: 3, frameSamples: frames)]
        value.facts = [.init("buffer ms", "15")]
        value.packets = (0..<120).filter { !missing.contains($0) }.map {
            .init(ms: Double($0 * frames) / 48 + 5, stream: 0, sequence: UInt32($0), bytes: 125)
        }
        value.packets.append(.init(ms: Double(80 * frames) / 48 + 5.5, stream: 0, sequence: 80, bytes: 125))
        value.packets.sort { $0.ms < $1.ms }
        return value.text()
    }
    func testAsRecorded128UsesActualNativeCodecAndKeepsDescriptorAndFates() throws {
        let text = recording(), date = Date(timeIntervalSince1970: 0)
        let result = try NativeReplaySimulation.run(text, seconds: 0.29, oneWayMs: 5, date: date)
        XCTAssertTrue(result.nativeCodec)
        XCTAssertGreaterThan(result.nativeDecodedFrames, 0)
        XCTAssertEqual(result.recordedCodec, 3)
        XCTAssertEqual(result.recordedFrameSamples, 128)
        XCTAssertEqual(result.packetFrames, 128)
        XCTAssertEqual(result.lost, 1)
        XCTAssertEqual(result.doubled, 1)
        XCTAssertGreaterThan(result.concealed, 0)
        XCTAssertTrue(result.comparisons.isEmpty)
        XCTAssertEqual(result, try NativeReplaySimulation.run(text, seconds: 0.29, oneWayMs: 5, date: date))
    }
    func testCustom128BaselineDoesNotChangeFixedReferenceComparisonTable() throws {
        let result = try NativeReplaySimulation.compare(recording(), seconds: 0.29)
        XCTAssertTrue(result.nativeCodec)
        XCTAssertEqual(result.recordedCodec, 3)
        XCTAssertEqual(result.recordedFrameSamples, 128)
        XCTAssertEqual(result.packetFrames, 128)
        XCTAssertEqual(result.comparisons.map(\.packetFrames), Array(repeating: 64, count: 6) + Array(repeating: 120, count: 6) + Array(repeating: 480, count: 6))
        XCTAssertEqual(result.comparisons.map(\.bufferMs), [5,8,10,15,20,30,5,8,10,15,20,30,5,8,10,15,20,30])
        XCTAssertTrue(result.comparisons.allSatisfy { $0.nativeDecodedFrames > 0 && $0.encoderBitrate == 320000 && $0.seed == 1 })
    }
    func testCustom128ActualModeProducesReference85ByteCBRPackets() throws {
        let sender = try XCTUnwrap(OpusCustomSender(frames: 128))
        let samples = (0..<128).flatMap { frame -> [Float] in
            [Float(sin(2 * Double.pi * 1000 * Double(frame) / 48000) * 0.5), 0]
        }
        let packet = try XCTUnwrap(sender.encode(samples))
        XCTAssertEqual(packet.count, 85)
        XCTAssertNil(sender.encode(Array(samples.dropLast())))
    }
    func testCustom128NativeWaveformWireAndSourceLifetimeAreConsumedByProductPath() throws {
        let result = try ProductTestPack.customReplayWaveform(frames: 128)
        XCTAssertTrue(result.native); XCTAssertTrue(result.finite)
        XCTAssertTrue(result.tone); XCTAssertTrue(result.stereo)
        XCTAssertTrue(result.wire); XCTAssertTrue(result.deterministic); XCTAssertTrue(result.released)
    }
    func testCustom128LossConcealsEightAndRefusesLargerGapWithoutFallback() throws {
        let eight = try NativeReplaySimulation.run(recording(missing: Set(40..<48)), seconds: 0.29)
        XCTAssertEqual(eight.concealed, 8)
        XCTAssertEqual(eight.gapsNotRepaired, 0)
        let nine = try NativeReplaySimulation.run(recording(missing: Set(40..<49)), seconds: 0.29)
        XCTAssertEqual(nine.concealed, 0)
        XCTAssertEqual(nine.gapsNotRepaired, 1)
        XCTAssertEqual(nine.lost, 9)
        XCTAssertGreaterThan(nine.nativeDecodedFrames, 0)
    }
    func testCustom128ErrorAndUnsupportedGeometryRefuseBeforeFallback() throws {
        var scenario = MacScenario("custom128 error")
        scenario.seconds = 0.05; scenario.packetFrames = 128; scenario.sendCard = SimCard(frames: 128)
        var calls = 0
        XCTAssertThrowsError(try NativeReplaySimulation.runNative(scenario, frames: 128, channels: 2, codec: .opusCustom, encode: { _ in calls += 1; return nil }))
        XCTAssertGreaterThan(calls, 0)
        XCTAssertThrowsError(try NativeReplaySimulation.runNative(scenario, frames: 128, channels: 1, codec: .opusCustom, encode: { _ in XCTFail("refused before encoder"); return nil }))
        XCTAssertThrowsError(try NativeReplaySimulation.runNative(scenario, frames: 128, channels: 2, codec: .opus, encode: { _ in XCTFail("wrong codec geometry"); return nil }))
        XCTAssertThrowsError(try NativeReplaySimulation.run(recording(frames: 129), seconds: 0.29))
        XCTAssertThrowsError(try NativeReplaySimulation.run(recording(frames: 256), seconds: 0.29))
    }
}
