import Foundation
import XCTest

@testable import RemSoundCore

final class PCMLossTests: XCTestCase {
    private func send(_ decoder: StreamDecoder, key: Credentials, frame: UInt32, frames: Int,
        left: Int16 = 16384, right: Int16 = -8192, wireSequence: UInt32 = 77,
        tampered: Bool = false, malformed: Bool = false) throws -> Bool {
        var raw = Data()
        for _ in 0..<frames {
            for sample in decoder.format.channels == 1 ? [left] : [left, right] {
                let bits = UInt32(bitPattern: Int32(sample) << 8)
                raw.append(UInt8(truncatingIfNeeded: bits))
                raw.append(UInt8(truncatingIfNeeded: bits >> 8))
                raw.append(UInt8(truncatingIfNeeded: bits >> 16))
            }
        }
        if malformed { raw.append(0) }
        var encrypted = try key.seal(raw)
        if tampered { encrypted[encrypted.count - 1] ^= 1 }
        let parts = (encrypted.count + Wire.maxAudioPayload - 1) / Wire.maxAudioPayload
        var accepted = false
        // Exercise the existing reverse-order fragment assembler too; frame IDs own loss accounting.
        for part in (0..<parts).reversed() {
            var payload = Data()
            payload.put(frame)
            payload.append(contentsOf: [UInt8(part), UInt8(parts)])
            payload.append(encrypted[(part * Wire.maxAudioPayload)..<min(encrypted.count, (part + 1) * Wire.maxAudioPayload)])
            let packet = try XCTUnwrap(Wire.parse(Wire.packet(.audio, stream: 7,
                sequence: wireSequence &+ UInt32(part), payload: payload)))
            accepted = decoder.accept(packet, credentials: key) || accepted
        }
        return accepted
    }

    func testMissingFramesUseArrivingPieceLengthAndFrameID() throws {
        let key = try Credentials(password: "isolated PCM piece loss")
        let decoder = StreamDecoder(.pcm(key.fingerprint), jitterMs: 2, smoothness: 10)
        let totals = ReceiveTotals()
        decoder.receiveTotals = totals
        XCTAssertTrue(try send(decoder, key: key, frame: 10, frames: 233, wireSequence: 900))
        XCTAssertTrue(try send(decoder, key: key, frame: 13, frames: 171, wireSequence: 901))
        XCTAssertEqual(decoder.queuedFrames, 233 + 2 * 171 + 171)
        XCTAssertEqual(totals.concealed, 2)
        XCTAssertEqual(totals.gapsNotRepaired, 0)
        XCTAssertEqual(decoder.takeLogFigures().concealed, 2)
    }

    func testLostStereoTailFadesToSilenceThenArrivingAudioFadesIn() throws {
        let previous = ClockKeeping.on
        ClockKeeping.on = false
        defer { ClockKeeping.on = previous }
        let key = try Credentials(password: "isolated PCM fade loss")
        let decoder = StreamDecoder(.pcm(key.fingerprint), jitterMs: 2, smoothness: 10)
        XCTAssertTrue(try send(decoder, key: key, frame: 1, frames: 120))
        XCTAssertTrue(try send(decoder, key: key, frame: 3, frames: 120, left: -16384, right: 16384))
        XCTAssertEqual(decoder.queuedFrames, 360)
        let output = decoder.read(360)
        XCTAssertEqual(output[0], 0.5)
        XCTAssertEqual(output[1], -0.25)
        XCTAssertGreaterThan(output[120 * 2], 0.49)
        XCTAssertLessThan(output[120 * 2 + 1], -0.24)
        XCTAssertEqual(output[144 * 2], 0.25, accuracy: 0.025)
        XCTAssertEqual(output[167 * 2], 0, accuracy: 0.001)
        XCTAssertTrue(output[(168 * 2)..<(240 * 2)].allSatisfy { $0 == 0 })
        XCTAssertEqual(output[240 * 2], 0, accuracy: 0.001)
        XCTAssertEqual(output[264 * 2], -0.25, accuracy: 0.025)
        XCTAssertEqual(output[288 * 2], -0.5)
        XCTAssertEqual(output[288 * 2 + 1], 0.5)
    }

    func testEightLostFramesAreFilledButNineAreNot() throws {
        let key = try Credentials(password: "isolated bounded PCM loss")
        for missing in [8, 9] {
            let decoder = StreamDecoder(.pcm(key.fingerprint), jitterMs: 2, smoothness: 10)
            let totals = ReceiveTotals()
            decoder.receiveTotals = totals
            XCTAssertTrue(try send(decoder, key: key, frame: 1, frames: 120))
            XCTAssertTrue(try send(decoder, key: key, frame: UInt32(missing + 2), frames: 120))
            XCTAssertEqual(decoder.queuedFrames, (missing == 8 ? 10 : 2) * 120)
            XCTAssertEqual(totals.concealed, missing == 8 ? 8 : 0)
            XCTAssertEqual(totals.gapsNotRepaired, missing == 9 ? 9 : 0)
        }
    }

    func testInvalidOrLateFramesCannotWriteFillOrAdvanceLossHistory() throws {
        let key = try Credentials(password: "isolated rejected PCM loss")
        let decoder = StreamDecoder(.pcm(key.fingerprint), jitterMs: 2, smoothness: 10)
        let totals = ReceiveTotals()
        decoder.receiveTotals = totals
        XCTAssertTrue(try send(decoder, key: key, frame: 1, frames: 120))
        XCTAssertFalse(try send(decoder, key: key, frame: 3, frames: 120, tampered: true))
        XCTAssertFalse(try send(decoder, key: key, frame: 3, frames: 120, malformed: true))
        XCTAssertEqual(decoder.queuedFrames, 120)
        XCTAssertEqual(totals.concealed, 0)
        XCTAssertTrue(try send(decoder, key: key, frame: 3, frames: 120))
        XCTAssertFalse(try send(decoder, key: key, frame: 2, frames: 120))
        XCTAssertFalse(try send(decoder, key: key, frame: 3, frames: 120))
        XCTAssertEqual(decoder.queuedFrames, 360)
        XCTAssertEqual(totals.concealed, 1)
        XCTAssertEqual(totals.lateOrDoubledDropped, 2)
    }

    func testSequenceWrapAndAuthenticatedRestartKeepIndependentHistory() throws {
        let key = try Credentials(password: "isolated PCM restart loss")
        let decoder = StreamDecoder(.pcm(key.fingerprint), jitterMs: 2, smoothness: 10)
        let totals = ReceiveTotals()
        decoder.receiveTotals = totals
        XCTAssertTrue(try send(decoder, key: key, frame: UInt32.max, frames: 120))
        XCTAssertTrue(try send(decoder, key: key, frame: 1, frames: 120))
        XCTAssertEqual(decoder.queuedFrames, 360)
        XCTAssertEqual(totals.concealed, 1)
        XCTAssertTrue(try send(decoder, key: key, frame: 2002, frames: 120))
        XCTAssertTrue(try send(decoder, key: key, frame: 1, frames: 120, left: -16384))
        XCTAssertEqual(decoder.queuedFrames, 120, "Restart clears old real and concealed audio")
        XCTAssertTrue(try send(decoder, key: key, frame: 3, frames: 120))
        XCTAssertEqual(decoder.queuedFrames, 360)
        XCTAssertEqual(totals.concealed, 2)
    }

    func testFragmentedFramesAreConcealedOnceAfterCompleteAuthentication() throws {
        let key = try Credentials(password: "isolated fragmented PCM loss")
        let decoder = StreamDecoder(.pcm(key.fingerprint), jitterMs: 2, smoothness: 10)
        XCTAssertTrue(try send(decoder, key: key, frame: 1, frames: 480))
        XCTAssertTrue(try send(decoder, key: key, frame: 3, frames: 480))
        XCTAssertEqual(decoder.queuedFrames, 1440)
        XCTAssertEqual(decoder.takeLogFigures().concealed, 1)
    }

    func testShortMonoPieceKeepsStereoNormalizationAndBoundedFades() throws {
        let previous = ClockKeeping.on
        ClockKeeping.on = false
        defer { ClockKeeping.on = previous }
        let key = try Credentials(password: "isolated short mono PCM loss")
        var format = StreamFormat.pcm(key.fingerprint)
        format.channels = 1
        let decoder = StreamDecoder(format, jitterMs: 2, smoothness: 10)
        XCTAssertTrue(try send(decoder, key: key, frame: 1, frames: 100))
        XCTAssertTrue(try send(decoder, key: key, frame: 3, frames: 8, left: -16384))
        XCTAssertEqual(decoder.queuedFrames, 116)
        let output = decoder.read(116)
        XCTAssertEqual(output[107 * 2], 0)
        XCTAssertEqual(output[107 * 2 + 1], 0)
        XCTAssertEqual(output[115 * 2], -0.5)
        XCTAssertEqual(output[115 * 2 + 1], -0.5)
        for frame in 100..<116 {
            XCTAssertEqual(output[frame * 2], output[frame * 2 + 1])
        }
    }
}
