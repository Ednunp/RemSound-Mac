import Foundation
import XCTest
@testable import RemSoundCore

final class SecurityProductPackTests: XCTestCase {
    func testRealReceiveCountersSaturateAndDescribeOnlyBoundedNumericValues() {
        let totals = ReceiveTotals()
        totals.noteMalformed(); totals.noteRejectedAudio(); totals.noteReorderWait()
        totals.noteDecodedAudio(frames: -1)
        XCTAssertEqual(totals.decodedAudioFrames, 0)
        totals.noteDecodedAudio(frames: Int.max); totals.noteDecodedAudio(frames: Int.max)
        totals.noteDecodedAudio(frames: Int.max); totals.noteDecodedAudio(frames: 1)
        XCTAssertEqual(totals.decodedAudioFrames, UInt64.max)
        XCTAssertEqual(totals.malformedPackets, 1); XCTAssertEqual(totals.rejectedAudioPayloads, 1)
        XCTAssertEqual(totals.diagnosticDescription, "receive lifetime totals: malformed packets 1, refused audio envelopes 1, native decoded frames 18446744073709551615, selection-gate refusals 0, rejected PCM fragments 0, discarded PCM partials 0, reorder waits 1")
    }
    func testPendingPCMFragmentsAreNotCountedAsRejectedAudio() throws {
        let key = try Credentials(password: "synthetic pending fragments")
        let decoder = StreamDecoder(.pcm(key.fingerprint, frames: 80))
        let totals = ReceiveTotals(); decoder.receiveTotals = totals
        let encrypted = try key.seal(Data(repeating: 0, count: 480)), split = encrypted.count / 2
        for part in 0..<2 {
            var payload = Data(); payload.put(UInt32(12345)); payload.append(contentsOf: [UInt8(part), 2])
            payload.append(part == 0 ? encrypted.prefix(split) : encrypted.suffix(encrypted.count - split))
            let packet = try XCTUnwrap(Wire.parse(Wire.packet(.audio, sequence: UInt32(part + 1), payload: payload)))
            XCTAssertEqual(decoder.accept(packet, credentials: key), part == 1)
            XCTAssertEqual(totals.rejectedAudioPayloads, 0)
            XCTAssertEqual(totals.decodedAudioFrames, part == 1 ? 80 : 0)
        }
    }
    func testNamedEncryptionRunsActualCryptoButRetainsNormalCredentialStorageGap() throws {
        let report = ProductTestPack.run(pack: .feature, only: "Encryption round-trip", budget: 8)
        let step = try XCTUnwrap(report.steps.first)
        XCTAssertEqual(step.status, "UNVERIFIED"); XCTAssertGreaterThanOrEqual(step.assertions, 12)
        XCTAssertEqual(step.failures, ["normal-keychain-persistence-acceptance-unverified"])
        XCTAssertEqual(report.exitCode, 1)
    }
    func testNamedFramingExercisesActualSessionRejectionAndValidDispatch() throws {
        let report = ProductTestPack.run(pack: .feature, only: "Packet framing and rejection (unknown types and cut-short payloads too)", budget: 8)
        let step = try XCTUnwrap(report.steps.first)
        XCTAssertEqual(step.status, "PASS"); XCTAssertGreaterThanOrEqual(step.assertions, 30)
        XCTAssertTrue(step.failures.isEmpty, step.failures.joined(separator: ", ")); XCTAssertEqual(report.exitCode, 0)
    }
    func testNamedDecryptorProvesNoKeyWrongKeyAndExactRightKeyAudio() throws {
        let report = ProductTestPack.run(pack: .feature, only: "Receiver decryptor: wrong key yields silence, not noise", budget: 8)
        let step = try XCTUnwrap(report.steps.first)
        XCTAssertEqual(step.status, "PASS"); XCTAssertGreaterThanOrEqual(step.assertions, 8)
        XCTAssertTrue(step.failures.isEmpty, step.failures.joined(separator: ", ")); XCTAssertEqual(report.exitCode, 0)
    }
}
