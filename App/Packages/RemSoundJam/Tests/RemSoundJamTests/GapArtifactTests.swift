import XCTest
@testable import RemSoundJam

final class GapArtifactTests: XCTestCase {
    private func stereo(_ frames: Int, left: Float = 0.5, right: Float = -0.25) -> [Float] {
        (0..<frames).flatMap { _ in [left, right] }
    }

    func testTransientGapDoesNotRearmJitterTarget() {
        let queue = PlayoutQueue(jitterMs: 5, packetFrames: 120, now: 0, smoothness: 10)
        queue.append(stereo(240))
        _ = queue.read(240, now: 0.005, keepsInTime: false)
        _ = queue.read(96, now: 0.007, keepsInTime: false)
        XCTAssertTrue(queue.playing, "Windows keeps a previously armed stream playing through transient gaps")
        queue.append(stereo(8))
        let resumed = queue.read(96, now: 0.009, keepsInTime: false)
        XCTAssertEqual(queue.queuedFrames, 0, "A small returning packet must not wait for another full jitter target")
        XCTAssertTrue(resumed.prefix(16).contains { $0 != 0 })
    }

    func testNoiseBurstHasTheWindowsEnvelopeStereoPeakAndBoundedEmptyStreak() {
        let queue = PlayoutQueue(jitterMs: 2, packetFrames: 120, now: 0, smoothness: 10)
        queue.append(stereo(96)); _ = queue.read(96, now: 0.002, keepsInTime: false)
        for gap in 1...8 {
            let output = queue.read(48, now: 0.002 + Double(gap) / 1000, keepsInTime: false)
            XCTAssertTrue(output.prefix(62).contains { $0 != 0 })
            XCTAssertTrue((0..<31).contains { output[$0 * 2] != output[$0 * 2 + 1] })
            for frame in 0..<32 {
                let bound = Float((cos(.pi * Double(frame + 1) / 32) + 1) / 2) * 0.5
                XCTAssertLessThanOrEqual(abs(output[frame * 2]), bound + 0.000001)
                XCTAssertLessThanOrEqual(abs(output[frame * 2 + 1]), bound + 0.000001)
            }
            XCTAssertTrue(output.dropFirst(62).allSatisfy { $0 == 0 })
        }
        for gap in 9...100 {
            XCTAssertTrue(queue.read(48, now: 0.002 + Double(gap) / 1000, keepsInTime: false).allSatisfy { $0 == 0 })
        }
        XCTAssertEqual(queue.underrunsTotal, 100, "Starvation remains visible to auto-tune after the audible cue stops")
    }

    func testPartialReadHasNoNoiseAndTheNextRealReadFadesOnlyOnce() {
        let queue = PlayoutQueue(jitterMs: 2, packetFrames: 120, now: 0, smoothness: 10)
        queue.append(stereo(120)); _ = queue.read(96, now: 0.002, keepsInTime: false)
        let partial = queue.read(48, now: 0.003, keepsInTime: false)
        XCTAssertEqual(Array(partial.prefix(48)), stereo(24))
        XCTAssertTrue(partial.dropFirst(48).allSatisfy { $0 == 0 })
        _ = queue.read(48, now: 0.004, keepsInTime: false)
        queue.append(stereo(120))
        let resumed = queue.read(48, now: 0.005, keepsInTime: false)
        for frame in 0..<32 {
            let gain = Float((1 - cos(.pi * Double(frame) / 32)) / 2)
            XCTAssertEqual(resumed[frame * 2], 0.5 * gain, accuracy: 0.000001)
            XCTAssertEqual(resumed[frame * 2 + 1], -0.25 * gain, accuracy: 0.000001)
        }
        XCTAssertEqual(Array(resumed.dropFirst(64)), stereo(16))
        XCTAssertEqual(queue.read(48, now: 0.006, keepsInTime: false), stereo(48))
    }

    func testInitialPrimingResetAndSafetyOverflowCannotReuseTheOldTail() {
        let queue = PlayoutQueue(jitterMs: 2, packetFrames: 120, now: 0, smoothness: 10)
        for _ in 0..<12 { XCTAssertTrue(queue.read(48, now: 0, keepsInTime: false).allSatisfy { $0 == 0 }) }
        queue.append(stereo(8))
        XCTAssertTrue(queue.read(48, now: 0.001, keepsInTime: false).allSatisfy { $0 == 0 })
        XCTAssertEqual(queue.queuedFrames, 8)
        queue.append(stereo(88)); _ = queue.read(96, now: 0.002, keepsInTime: false)
        _ = queue.read(48, now: 0.003, keepsInTime: false)
        queue.reset(now: 0.004)
        XCTAssertTrue(queue.read(48, now: 0.005, keepsInTime: false).allSatisfy { $0 == 0 })
        queue.append(stereo(96)); _ = queue.read(96, now: 0.006, keepsInTime: false)
        queue.append(stereo(19_000, left: 0, right: 0))
        queue.append(stereo(240, left: 0, right: 0))
        XCTAssertEqual(queue.overflows, 1)
        _ = queue.read(240, now: 0.007, keepsInTime: false)
        XCTAssertTrue(queue.read(48, now: 0.008, keepsInTime: false).allSatisfy { $0 == 0 })
        XCTAssertEqual(queue.read(0, now: 0.009, keepsInTime: false), [])
    }

    func testClickIsRawZeroFillAndTheLiveChoiceDoesNotClearQueuedAudio() {
        let queue = PlayoutQueue(jitterMs: 2, packetFrames: 120, now: 0, smoothness: 10, artifact: .click)
        queue.append(stereo(96)); _ = queue.read(96, now: 0.002, keepsInTime: false)
        XCTAssertTrue(queue.read(48, now: 0.003, keepsInTime: false).allSatisfy { $0 == 0 })
        queue.append(stereo(96))
        XCTAssertEqual(queue.read(48, now: 0.004, keepsInTime: false), stereo(48))
        let depth = queue.queuedFrames
        queue.setArtifact(.noiseBurst)
        XCTAssertEqual(queue.queuedFrames, depth)
        _ = queue.read(48, now: 0.005, keepsInTime: false)
        XCTAssertTrue(queue.read(48, now: 0.006, keepsInTime: false).contains { $0 != 0 })
        queue.setArtifact(.click)
        queue.append(stereo(96))
        XCTAssertEqual(queue.read(48, now: 0.007, keepsInTime: false), stereo(48))
        XCTAssertEqual(queue.artifact, .click)
    }

    func testResamplerPartialReadsStaySilentAndItsRealReturnResolvesTheFade() {
        let queue = PlayoutQueue(jitterMs: 2, packetFrames: 120, now: 0, smoothness: 10)
        var made = 0.0, sent = 0, now = 0.0
        while now < 25 {
            made += 48.048
            let frames = Int(made) - sent
            queue.append(stereo(frames)); queue.produced(frames, now: now); sent += frames
            _ = queue.read(48, now: now + 0.0005, keepsInTime: true); now += 0.001
        }
        XCTAssertTrue(queue.clockTracking)
        XCTAssertGreaterThan(queue.resampleRatio, 1)
        let partial = queue.read(240, now: now, keepsInTime: true)
        for frame in 0..<240 { XCTAssertEqual(partial[frame * 2 + 1], -partial[frame * 2] / 2, accuracy: 0.000001) }
        _ = queue.read(48, now: now + 0.001, keepsInTime: true)
        queue.append(stereo(240))
        let resumed = queue.read(48, now: now + 0.002, keepsInTime: true)
        XCTAssertEqual(resumed[0], 0)
        XCTAssertLessThan(resumed[20], 0.5)
        XCTAssertEqual(resumed[66], 0.5, accuracy: 0.000001)
        XCTAssertEqual(queue.read(48, now: now + 0.003, keepsInTime: true)[0], 0.5, accuracy: 0.000001)
        XCTAssertTrue(queue.clockTracking, "A brief gap must not discard clock measurement")
    }

    func testHeldResamplerOutputResolvesAPendingFadeWithoutNewInput() {
        var concealment = UnderrunConcealment(seed: 123)
        var first = stereo(48)
        concealment.real(&first, lastFrame: (0.5, -0.25), artifact: .noiseBurst)
        _ = concealment.empty(frames: 48, artifact: .noiseBurst)
        var held = stereo(48)
        concealment.real(&held, lastFrame: nil, artifact: .noiseBurst)
        XCTAssertEqual(held[0], 0)
        XCTAssertEqual(held[66], 0.5)
        var next = stereo(48)
        concealment.real(&next, lastFrame: nil, artifact: .noiseBurst)
        XCTAssertEqual(next, stereo(48))
    }

    func testWindowsLegacyArtifactNumbersMigrateAndInvalidPeaksStayBounded() throws {
        for raw in [0, 1, 2, 99] {
            XCTAssertEqual(try JSONDecoder().decode(ConcealmentArtifact.self, from: Data(String(raw).utf8)), .noiseBurst)
        }
        XCTAssertEqual(try JSONDecoder().decode(ConcealmentArtifact.self, from: Data("3".utf8)), .click)
        XCTAssertEqual(String(data: try JSONEncoder().encode(ConcealmentArtifact.click), encoding: .utf8), "3")
        var concealment = UnderrunConcealment(seed: 123)
        var real = stereo(48)
        concealment.real(&real, lastFrame: (.infinity, .nan), artifact: .noiseBurst)
        XCTAssertTrue(concealment.empty(frames: 48, artifact: .noiseBurst).allSatisfy { $0 == 0 })
        concealment.real(&real, lastFrame: (100, -100), artifact: .noiseBurst)
        XCTAssertTrue(concealment.empty(frames: 48, artifact: .noiseBurst).allSatisfy { $0.isFinite && abs($0) <= 1 })
    }
}
