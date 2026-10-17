import Foundation
import XCTest

@testable import RemSoundCore

final class ReceiveReorderTests: XCTestCase {
    private var previousClock = true
    override func setUp() { previousClock = ClockKeeping.on; ClockKeeping.on = false }
    override func tearDown() { ClockKeeping.on = previousClock }

    private func send(_ decoder: StreamDecoder, _ key: Credentials, _ sequence: UInt32,
        frames: Int = 120, tampered: Bool = false, malformed: Bool = false) throws -> Bool {
        var raw = Data()
        let sample = Int32(sequence % 16) * 1024 << 8
        for _ in 0..<(frames * 2) {
            raw.append(UInt8(truncatingIfNeeded: sample))
            raw.append(UInt8(truncatingIfNeeded: sample >> 8))
            raw.append(UInt8(truncatingIfNeeded: sample >> 16))
        }
        if malformed { raw.append(0) }
        var sealed = try key.seal(raw)
        if tampered { sealed[sealed.count - 1] ^= 1 }
        let count = (sealed.count + Wire.maxAudioPayload - 1) / Wire.maxAudioPayload
        var accepted = false
        for part in (0..<count).reversed() {
            var payload = Data(); payload.put(sequence)
            payload.append(contentsOf: [UInt8(part), UInt8(count)])
            payload.append(sealed[(part * Wire.maxAudioPayload)..<min(sealed.count, (part + 1) * Wire.maxAudioPayload)])
            let packet = try XCTUnwrap(Wire.parse(Wire.packet(.audio, stream: 7,
                sequence: sequence &+ UInt32(part), payload: payload)))
            accepted = decoder.accept(packet, credentials: key) || accepted
        }
        return accepted
    }

    private func primed(_ key: Credentials) throws -> StreamDecoder {
        let decoder = StreamDecoder(.pcm(key.fingerprint), jitterMs: 2, smoothness: 10)
        decoder.receiveTotals = ReceiveTotals()
        for sequence in UInt32(1)...5 { XCTAssertTrue(try send(decoder, key, sequence)) }
        return decoder
    }

    func testTwoMissingArrivalsPlayInOrderWithoutConcealment() throws {
        let key = try Credentials(password: "isolated reorder recovery")
        let decoder = try primed(key)
        XCTAssertTrue(try send(decoder, key, 8), "A held authenticated packet is handled")
        XCTAssertEqual(decoder.queuedFrames, 600)
        XCTAssertTrue(try send(decoder, key, 6))
        XCTAssertEqual(decoder.queuedFrames, 720)
        XCTAssertTrue(try send(decoder, key, 7))
        XCTAssertEqual(decoder.queuedFrames, 960)
        XCTAssertEqual(decoder.receiveTotals?.concealed, 0)
        let samples = decoder.read(960)
        XCTAssertEqual(samples[600 * 2], 6.0 / 32)
        XCTAssertEqual(samples[720 * 2], 7.0 / 32)
        XCTAssertEqual(samples[840 * 2], 8.0 / 32)
        XCTAssertEqual(decoder.takeLogFigures().packets, 8, "Held packets count once, on arrival")
    }

    func testImmediatePredecessorReleasesHeldFrameAndRepairsOnlyEarlierLoss() throws {
        let key = try Credentials(password: "isolated predecessor reorder")
        let decoder = try primed(key)
        XCTAssertTrue(try send(decoder, key, 8))
        XCTAssertTrue(try send(decoder, key, 7))
        XCTAssertEqual(decoder.queuedFrames, 960)
        XCTAssertEqual(decoder.receiveTotals?.concealed, 1)
        let samples = decoder.read(960)
        XCTAssertEqual(samples[(720 + 48) * 2], 7.0 / 32)
        XCTAssertEqual(samples[840 * 2], 8.0 / 32)
    }

    func testSecondOlderArrivalReleasesHeldAndFurtherPredecessorIsLate() throws {
        let key = try Credentials(password: "isolated bounded reorder arrivals")
        let decoder = try primed(key)
        XCTAssertTrue(try send(decoder, key, 9))
        XCTAssertEqual(decoder.queuedFrames, 600)
        XCTAssertTrue(try send(decoder, key, 6))
        XCTAssertEqual(decoder.queuedFrames, 720)
        XCTAssertTrue(try send(decoder, key, 7))
        XCTAssertEqual(decoder.queuedFrames, 1080)
        XCTAssertEqual(decoder.receiveTotals?.concealed, 1)
        XCTAssertFalse(try send(decoder, key, 8))
        XCTAssertEqual(decoder.receiveTotals?.lateOrDoubledDropped, 1)
    }

    func testNewerArrivalReleasesHeldBeforeItCanTakeAnotherHold() throws {
        let key = try Credentials(password: "isolated replacing reorder hold")
        let decoder = try primed(key)
        XCTAssertTrue(try send(decoder, key, 7))
        XCTAssertEqual(decoder.queuedFrames, 600)
        XCTAssertTrue(try send(decoder, key, 9))
        XCTAssertEqual(decoder.queuedFrames, 840, "7 is released; 9 is held against newly played7")
        XCTAssertEqual(decoder.receiveTotals?.concealed, 1)
        XCTAssertTrue(try send(decoder, key, 8))
        XCTAssertEqual(decoder.queuedFrames, 1080)
        XCTAssertEqual(decoder.receiveTotals?.concealed, 1)
    }

    func testHeldDuplicatesDoNotReleaseOrCreateALateRestartRun() throws {
        let key = try Credentials(password: "isolated held duplicate reorder")
        let decoder = try primed(key)
        XCTAssertTrue(try send(decoder, key, 8))
        for _ in 0..<9 { XCTAssertFalse(try send(decoder, key, 8)) }
        XCTAssertEqual(decoder.queuedFrames, 600)
        XCTAssertEqual(decoder.receiveTotals?.lateOrDoubledDropped, 9)
        XCTAssertTrue(try send(decoder, key, 6))
        XCTAssertTrue(try send(decoder, key, 7))
        XCTAssertEqual(decoder.queuedFrames, 960)
        XCTAssertEqual(decoder.receiveTotals?.concealed, 0)
    }

    func testHoldUsesAnnouncedDurationAndRequiresTheWholeThreshold() throws {
        let key = try Credentials(password: "isolated exact reorder threshold")
        for (announced, threshold) in [(233, 528), (120, 336)] {
            for available in [threshold - 1, threshold] {
                let decoder = StreamDecoder(.pcm(key.fingerprint, frames: announced), jitterMs: 2, smoothness: 10)
                XCTAssertTrue(try send(decoder, key, 1, frames: available))
                XCTAssertTrue(try send(decoder, key, 3))
                XCTAssertEqual(decoder.queuedFrames, available == threshold ? available : available + 240)
                if available == threshold {
                    XCTAssertTrue(try send(decoder, key, 2))
                    XCTAssertEqual(decoder.queuedFrames, available + 240)
                }
            }
        }
    }

    func testFourMissingFramesDoNotWaitEvenWithEnoughBuffer() throws {
        let key = try Credentials(password: "isolated maximum reorder gap")
        let decoder = try primed(key)
        XCTAssertTrue(try send(decoder, key, 10))
        XCTAssertEqual(decoder.queuedFrames, 1200)
        XCTAssertEqual(decoder.receiveTotals?.concealed, 4)
    }

    func testReadsDoNotReleaseAHoldAndNewStreamDoesNotInheritIt() throws {
        let key = try Credentials(password: "isolated reorder without arrivals")
        let decoder = try primed(key)
        XCTAssertTrue(try send(decoder, key, 7))
        XCTAssertEqual(decoder.queuedFrames, 600)
        _ = decoder.read(600)
        XCTAssertEqual(decoder.queuedFrames, 0)
        for _ in 0..<60 { _ = decoder.read(96) }
        XCTAssertEqual(decoder.queuedFrames, 0)
        XCTAssertEqual(decoder.receiveTotals?.concealed, 0)
        let replacement = StreamDecoder(.pcm(key.fingerprint), jitterMs: 2, smoothness: 10)
        XCTAssertTrue(try send(replacement, key, 7))
        XCTAssertEqual(replacement.queuedFrames, 120)
        XCTAssertTrue(try send(decoder, key, 6))
        XCTAssertEqual(decoder.queuedFrames, 240, "The old hold releases only on its predecessor arrival")
    }

    func testUnauthenticatedOrMalformedFrameCannotReleaseOrReplaceHeldAudio() throws {
        let key = try Credentials(password: "isolated authenticated reorder")
        let decoder = try primed(key)
        XCTAssertTrue(try send(decoder, key, 7))
        XCTAssertFalse(try send(decoder, key, 100, tampered: true))
        XCTAssertFalse(try send(decoder, key, 100, malformed: true))
        XCTAssertEqual(decoder.queuedFrames, 600)
        XCTAssertEqual(decoder.receiveTotals?.concealed, 0)
        XCTAssertTrue(try send(decoder, key, 6))
        XCTAssertEqual(decoder.queuedFrames, 840)
        XCTAssertEqual(decoder.receiveTotals?.concealed, 0)
    }

    func testLargeAuthenticatedBackwardJumpDiscardsHeldOldSequence() throws {
        let key = try Credentials(password: "isolated reordered sender restart")
        let decoder = StreamDecoder(.pcm(key.fingerprint), jitterMs: 2, smoothness: 10)
        decoder.receiveTotals = ReceiveTotals()
        XCTAssertTrue(try send(decoder, key, 2002, frames: 600))
        XCTAssertTrue(try send(decoder, key, 2004))
        XCTAssertFalse(try send(decoder, key, 500, tampered: true))
        XCTAssertEqual(decoder.queuedFrames, 600)
        XCTAssertTrue(try send(decoder, key, 500))
        XCTAssertEqual(decoder.queuedFrames, 120)
        XCTAssertTrue(try send(decoder, key, 501))
        XCTAssertEqual(decoder.queuedFrames, 240)
        XCTAssertEqual(decoder.receiveTotals?.concealed, 0)
    }

    func testEighthAuthenticatedLateArrivalRestartsAndSuccessfulPlayResetsRun() throws {
        let key = try Credentials(password: "isolated late run reorder restart")
        let decoder = StreamDecoder(.pcm(key.fingerprint), jitterMs: 2, smoothness: 10)
        decoder.receiveTotals = ReceiveTotals()
        XCTAssertTrue(try send(decoder, key, 500, frames: 600))
        for sequence in UInt32(100)...106 { XCTAssertFalse(try send(decoder, key, sequence)) }
        XCTAssertEqual(decoder.queuedFrames, 600)
        XCTAssertFalse(try send(decoder, key, 107, tampered: true))
        XCTAssertTrue(try send(decoder, key, 107))
        XCTAssertEqual(decoder.queuedFrames, 120)
        XCTAssertEqual(decoder.receiveTotals?.lateOrDoubledDropped, 7)
        for sequence in UInt32(100)...106 { XCTAssertFalse(try send(decoder, key, sequence)) }
        XCTAssertTrue(try send(decoder, key, 108))
        XCTAssertFalse(try send(decoder, key, 100), "An actual play reset the seven-packet late run")
        XCTAssertEqual(decoder.queuedFrames, 240)
    }

    func testWrapRecoversMissingPredecessorWithoutRestartOrConcealment() throws {
        let key = try Credentials(password: "isolated wrap reorder")
        let decoder = StreamDecoder(.pcm(key.fingerprint), jitterMs: 2, smoothness: 10)
        decoder.receiveTotals = ReceiveTotals()
        XCTAssertTrue(try send(decoder, key, UInt32.max - 1, frames: 600))
        XCTAssertTrue(try send(decoder, key, 0))
        XCTAssertEqual(decoder.queuedFrames, 600)
        XCTAssertTrue(try send(decoder, key, UInt32.max))
        XCTAssertEqual(decoder.queuedFrames, 840)
        XCTAssertEqual(decoder.receiveTotals?.concealed, 0)
    }

    func testOpusReorderUsesWireSequenceAndAnnouncedTenMillisecondThreshold() throws {
        let key = try Credentials(password: "isolated Opus wire reorder")
        let encoder = try XCTUnwrap(OpusSender(bitrate: 128_000))
        let plain = try XCTUnwrap(encoder.encode([Float](repeating: 0.125, count: 960)))
        for priming in [2, 3] {
            let decoder = StreamDecoder(.opus(key.fingerprint, frames: 480), jitterMs: 2, smoothness: 10)
            decoder.receiveTotals = ReceiveTotals()
            func packet(_ sequence: UInt32) throws -> Bool {
                let wire = try XCTUnwrap(Wire.parse(Wire.packet(.audio, sequence: sequence,
                    payload: try key.seal(plain))))
                return decoder.accept(wire, credentials: key)
            }
            for sequence in 1...priming { XCTAssertTrue(try packet(UInt32(sequence))) }
            XCTAssertTrue(try packet(UInt32(priming + 2)))
            XCTAssertEqual(decoder.queuedFrames, priming == 2 ? 1920 : 1440,
                "Two10ms blocks are below21ms; three can afford a hold")
            if priming == 3 {
                XCTAssertTrue(try packet(4))
                XCTAssertEqual(decoder.queuedFrames, 2400)
                XCTAssertEqual(decoder.receiveTotals?.concealed, 0)
            }
        }
    }

    func testCustomOpusUsesFiveMillisecondThresholdWithoutInventingLoss() throws {
        let key = try Credentials(password: "isolated custom64 reorder")
        let encoder = try XCTUnwrap(OpusCustomSender(frames: 64))
        let plain = try XCTUnwrap(encoder.encode([Float](repeating: 0.125, count: 128)))
        for priming in [3, 4] {
            let decoder = StreamDecoder(.opusCustom(key.fingerprint, frames: 64), jitterMs: 2, smoothness: 10)
            decoder.receiveTotals = ReceiveTotals()
            func packet(_ sequence: UInt32) throws -> Bool {
                let wire = try XCTUnwrap(Wire.parse(Wire.packet(.audio, sequence: sequence,
                    payload: try key.seal(plain))))
                return decoder.accept(wire, credentials: key)
            }
            for sequence in 1...priming { XCTAssertTrue(try packet(UInt32(sequence))) }
            XCTAssertTrue(try packet(UInt32(priming + 2)))
            XCTAssertEqual(decoder.queuedFrames, priming == 3 ? 320 : 256)
            if priming == 4 {
                XCTAssertTrue(try packet(5))
                XCTAssertEqual(decoder.queuedFrames, 384)
                XCTAssertEqual(decoder.receiveTotals?.concealed, 0)
            }
        }
    }

    func testCounterRecordsOnlyNewAuthenticatedHoldEpisodes() throws {
        let key = try Credentials(password: "isolated counted hold")
        let decoder = try primed(key)
        XCTAssertEqual(decoder.receiveTotals?.reorderWaits, 0)
        XCTAssertFalse(try send(decoder, key, 7, tampered: true))
        XCTAssertEqual(decoder.receiveTotals?.reorderWaits, 0)
        XCTAssertTrue(try send(decoder, key, 7))
        XCTAssertEqual(decoder.receiveTotals?.reorderWaits, 1)
        XCTAssertEqual(decoder.queuedFrames, 600)
        XCTAssertFalse(try send(decoder, key, 7))
        XCTAssertFalse(try send(decoder, key, 8, malformed: true))
        XCTAssertEqual(decoder.receiveTotals?.reorderWaits, 1)
        XCTAssertEqual(decoder.queuedFrames, 600)
        XCTAssertTrue(try send(decoder, key, 6))
        XCTAssertEqual(decoder.receiveTotals?.reorderWaits, 1)
        XCTAssertEqual(decoder.queuedFrames, 840)
        let heard = decoder.read(840)
        XCTAssertEqual(heard[600 * 2], 6.0 / 32)
        XCTAssertEqual(heard[720 * 2], 7.0 / 32)
    }
    func testCounterUsesLaterArrivalCutoffAndCountsReplacementHoldOnce() throws {
        let key = try Credentials(password: "isolated counted arrival expiry")
        let decoder = try primed(key)
        XCTAssertTrue(try send(decoder, key, 7))
        XCTAssertEqual(decoder.receiveTotals?.reorderWaits, 1)
        XCTAssertTrue(try send(decoder, key, 9))
        XCTAssertEqual(decoder.receiveTotals?.reorderWaits, 2)
        XCTAssertEqual(decoder.queuedFrames, 840)
        XCTAssertTrue(try send(decoder, key, 8))
        XCTAssertEqual(decoder.receiveTotals?.reorderWaits, 2)
        XCTAssertEqual(decoder.queuedFrames, 1080)
        let cutoff = try primed(key)
        XCTAssertTrue(try send(cutoff, key, 9))
        XCTAssertTrue(try send(cutoff, key, 6))
        XCTAssertTrue(try send(cutoff, key, 7))
        XCTAssertFalse(try send(cutoff, key, 8))
        XCTAssertEqual(cutoff.receiveTotals?.reorderWaits, 1)
        XCTAssertEqual(cutoff.receiveTotals?.lateOrDoubledDropped, 1)
    }
    func testCounterIsNotAReadTimerOrGaugeAndRestartKeepsLifetimeTotal() throws {
        let key = try Credentials(password: "isolated counted hold lifetime")
        let decoder = try primed(key)
        XCTAssertTrue(try send(decoder, key, 7))
        _ = decoder.read(600)
        for _ in 0..<20 { _ = decoder.read(96) }
        XCTAssertEqual(decoder.receiveTotals?.reorderWaits, 1)
        XCTAssertEqual(decoder.queuedFrames, 0)
        XCTAssertTrue(try send(decoder, key, 6))
        XCTAssertEqual(decoder.queuedFrames, 240)
        XCTAssertEqual(decoder.receiveTotals?.reorderWaits, 1)
        let small = StreamDecoder(.pcm(key.fingerprint, frames: 120), jitterMs: 2, smoothness: 10)
        small.receiveTotals = ReceiveTotals()
        XCTAssertTrue(try send(small, key, 1)); XCTAssertTrue(try send(small, key, 3))
        XCTAssertEqual(small.receiveTotals?.reorderWaits, 0)
        let restarted = StreamDecoder(.pcm(key.fingerprint), jitterMs: 2, smoothness: 10)
        restarted.receiveTotals = ReceiveTotals()
        XCTAssertTrue(try send(restarted, key, 2002, frames: 600))
        XCTAssertTrue(try send(restarted, key, 2004))
        XCTAssertTrue(try send(restarted, key, 500))
        XCTAssertEqual(restarted.queuedFrames, 120)
        XCTAssertEqual(restarted.receiveTotals?.reorderWaits, 1)
    }
}
