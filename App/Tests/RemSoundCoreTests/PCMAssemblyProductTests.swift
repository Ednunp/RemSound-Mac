import Foundation
import XCTest
@testable import RemSoundCore

final class PCMAssemblyProductTests: XCTestCase {
    func testLargestPreviouslyValidFloatPCMFrameStillAuthenticatesInReverseOrder() throws {
        let key = try Credentials(password: "synthetic full-size PCM")
        var format = StreamFormat.pcm(key.fingerprint, frames: 2880)
        format.bits = 32; format.encoding = 3
        let decoder = StreamDecoder(format, jitterMs: 2, smoothness: 10), totals = ReceiveTotals()
        decoder.receiveTotals = totals
        var clear = Data()
        for _ in 0..<2880 { clear.put(Float(0.125).bitPattern); clear.put(Float(-0.0625).bitPattern) }
        let encrypted = try key.seal(clear)
        let parts = (encrypted.count + Wire.maxAudioPayload - 1) / Wire.maxAudioPayload
        for part in (0..<parts).reversed() {
            var payload = Data(); payload.put(UInt32(42)); payload.append(contentsOf: [UInt8(part), UInt8(parts)])
            payload.append(encrypted[(part * Wire.maxAudioPayload)..<min(encrypted.count, (part + 1) * Wire.maxAudioPayload)])
            let packet = try XCTUnwrap(Wire.parse(Wire.packet(.audio, sequence: UInt32(part), payload: payload)))
            XCTAssertEqual(decoder.accept(packet, credentials: key), part == 0)
        }
        XCTAssertEqual(totals.decodedAudioFrames, 2880); XCTAssertEqual(totals.rejectedPCMFragments, 0)
        XCTAssertEqual(decoder.pendingPCMFrames, 0); XCTAssertEqual(decoder.pendingPCMBytes, 0)
        let samples = decoder.read(2880)
        XCTAssertEqual(samples.count, 5760)
        XCTAssertTrue(stride(from: 0, to: samples.count, by: 2).allSatisfy { samples[$0] == 0.125 && samples[$0 + 1] == -0.0625 })
    }
    func testNamedAssemblyUsesActualDecoderAndRetainsDifferentWindowsDiscardPolicy() throws {
        let report = ProductTestPack.run(pack: .feature, only: "PCM frame reassembly (order, loss, discard counters)", budget: 8)
        let step = try XCTUnwrap(report.steps.first)
        XCTAssertEqual(step.status, "UNVERIFIED"); XCTAssertGreaterThanOrEqual(step.assertions, 25)
        XCTAssertEqual(step.failures, ["windows-single-active-in-order-discard-policy-not-matched"])
        XCTAssertEqual(report.exitCode, 1)
    }
    func testNamedAllowGateCountsStrangerAndAcceptsSelectedAddressAtAnotherSourcePort() throws {
        let report = ProductTestPack.run(pack: .feature, only: "Receiver allow-list gate (stranger rejected, no session)", budget: 8)
        let step = try XCTUnwrap(report.steps.first)
        XCTAssertEqual(step.status, "PASS"); XCTAssertGreaterThanOrEqual(step.assertions, 10)
        XCTAssertTrue(step.failures.isEmpty, step.failures.joined(separator: ", "))
        XCTAssertEqual(report.exitCode, 0)
    }
}
