import XCTest
import AudioSupport

final class TypingMixerTests: XCTestCase {
    private func asset(_ mixer: OpaquePointer, _ index: UInt32, _ samples: [Float]) {
        samples.withUnsafeBufferPointer {
            XCTAssertEqual(RSTypingMixerSetAsset(mixer, index, $0.baseAddress, UInt32(samples.count / 2)), 1)
        }
    }
    private func render(_ mixer: OpaquePointer, _ frames: Int) -> [[Float]] {
        var left = [Float](repeating: 99, count: frames)
        var right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                RSTypingMixerRender(mixer, l.baseAddress, r.baseAddress, UInt32(frames))
            }
        }
        return [left, right]
    }
    func testCachedStereoCursorsAndSilenceAfterEnd() throws {
        let m = try XCTUnwrap(RSTypingMixerCreate()); defer { RSTypingMixerDestroy(m) }
        asset(m, 0, [0.1, 0.2, 0.3, 0.4, 0.5, 0.6])
        RSTypingMixerSetEnabled(m, 1)
        XCTAssertEqual(RSTypingMixerEnqueue(m, 0, 0), 1)
        XCTAssertEqual(render(m, 2), [[0.1, 0.3], [0.2, 0.4]])
        XCTAssertEqual(render(m, 3), [[0.5, 0, 0], [0.6, 0, 0]])
    }
    func testNewClickOverlapsWithoutCuttingPreviousVoice() throws {
        let m = try XCTUnwrap(RSTypingMixerCreate()); defer { RSTypingMixerDestroy(m) }
        asset(m, 0, [0.1, 0.2, 0.3, 0.4, 0.5, 0.6])
        RSTypingMixerSetEnabled(m, 1)
        XCTAssertEqual(RSTypingMixerEnqueue(m, 0, 0), 1)
        _ = render(m, 1)
        XCTAssertEqual(RSTypingMixerEnqueue(m, 0, 0), 1)
        let mixed = render(m, 3)
        for (actual, expected) in zip(mixed[0], [Float(0.4), 0.8, 0.5]) { XCTAssertEqual(actual, expected, accuracy: 0.00001) }
        for (actual, expected) in zip(mixed[1], [Float(0.6), 1, 0.6]) { XCTAssertEqual(actual, expected, accuracy: 0.00001) }
    }
    func testPasswordLayerStartsInSameRenderAsOrdinaryKey() throws {
        let m = try XCTUnwrap(RSTypingMixerCreate()); defer { RSTypingMixerDestroy(m) }
        asset(m, 0, [0.1, 0.2]); asset(m, UInt32(RS_TYPING_PASSWORD_ASSET), [0.3, 0.4, 0.5, 0.6])
        RSTypingMixerSetEnabled(m, 1)
        XCTAssertEqual(RSTypingMixerEnqueue(m, 0, 1), 1)
        let mixed = render(m, 3)
        XCTAssertEqual(mixed[0][0], 0.4, accuracy: 0.00001)
        XCTAssertEqual(mixed[1][0], 0.6, accuracy: 0.00001)
        XCTAssertEqual(Array(mixed[0].dropFirst()), [0.5, 0])
        XCTAssertEqual(Array(mixed[1].dropFirst()), [0.6, 0])
    }
    func testMuteRetiresPlayingAndQueuedGenerationsAcrossReenable() throws {
        let m = try XCTUnwrap(RSTypingMixerCreate()); defer { RSTypingMixerDestroy(m) }
        asset(m, 0, [Float](repeating: 0.25, count: 12))
        for _ in 0..<500 {
            RSTypingMixerSetEnabled(m, 1)
            XCTAssertEqual(RSTypingMixerEnqueue(m, 0, 0), 1)
            XCTAssertEqual(render(m, 1), [[0.25], [0.25]])
            XCTAssertEqual(RSTypingMixerEnqueue(m, 0, 0), 1)
            RSTypingMixerSetEnabled(m, 0)
            XCTAssertEqual(RSTypingMixerEnqueue(m, 0, 0), 0)
            RSTypingMixerSetEnabled(m, 1)
            XCTAssertEqual(render(m, 2), [[0, 0], [0, 0]])
        }
    }
    func testMissingAssetsAndInvalidInputAreInert() throws {
        let m = try XCTUnwrap(RSTypingMixerCreate()); defer { RSTypingMixerDestroy(m) }
        RSTypingMixerSetEnabled(m, 1)
        XCTAssertEqual(RSTypingMixerEnqueue(m, 0, 0), 0)
        XCTAssertEqual(RSTypingMixerSetAsset(m, 0, nil, 10), 0)
        asset(m, 0, [0.1, 0.2])
        XCTAssertEqual(RSTypingMixerEnqueue(m, UInt32(RS_TYPING_ASSETS), 0), 0)
        XCTAssertEqual(RSTypingMixerEnqueue(m, 0, 1), 1) // Missing passkey still permits the ordinary key.
        XCTAssertEqual(render(m, 1), [[0.1], [0.2]])
    }
    func testFloodDropsNewRequestsWithoutTruncatingExistingVoices() throws {
        let m = try XCTUnwrap(RSTypingMixerCreate()); defer { RSTypingMixerDestroy(m) }
        asset(m, 0, [Float](repeating: 0.001, count: 20))
        RSTypingMixerSetEnabled(m, 1)
        for _ in 0..<Int(RS_TYPING_REQUESTS) { XCTAssertEqual(RSTypingMixerEnqueue(m, 0, 0), 1) }
        XCTAssertEqual(RSTypingMixerEnqueue(m, 0, 0), 0)
        let first = render(m, 1)
        XCTAssertEqual(first[0][0], Float(RS_TYPING_VOICES) * 0.001, accuracy: 0.00001)
        XCTAssertEqual(RSTypingMixerDroppedRequests(m), UInt64(RS_TYPING_REQUESTS - RS_TYPING_VOICES + 1))
        XCTAssertEqual(RSTypingMixerEnqueue(m, 0, 0), 1)
        XCTAssertEqual(render(m, 1)[0][0], first[0][0], accuracy: 0.00001)
        XCTAssertEqual(RSTypingMixerDroppedRequests(m), UInt64(RS_TYPING_REQUESTS - RS_TYPING_VOICES + 2))
        _ = render(m, 8)
        XCTAssertEqual(render(m, 2), [[0, 0], [0, 0]])
    }
    func testAssetsAreCopiedAndInvalidSamplesCannotEnterCallback() throws {
        let m = try XCTUnwrap(RSTypingMixerCreate()); defer { RSTypingMixerDestroy(m) }
        var samples: [Float] = [0.1, 0.2]
        asset(m, 0, samples); samples[0] = 99
        XCTAssertEqual(RSTypingMixerSetAsset(m, 1, nil, UInt32(RS_TYPING_MAX_ASSET_FRAMES) + 1), 0)
        [Float.nan, 0].withUnsafeBufferPointer { XCTAssertEqual(RSTypingMixerSetAsset(m, 1, $0.baseAddress, 1), 0) }
        [Float.infinity, 0].withUnsafeBufferPointer { XCTAssertEqual(RSTypingMixerSetAsset(m, 1, $0.baseAddress, 1), 0) }
        RSTypingMixerSetEnabled(m, 1)
        XCTAssertEqual(RSTypingMixerEnqueue(m, 0, 0), 1)
        XCTAssertEqual(render(m, 1), [[0.1], [0.2]])
    }
    func testVoiceLimitNeverAdmitsOnlyHalfAPasswordPair() throws {
        let m = try XCTUnwrap(RSTypingMixerCreate()); defer { RSTypingMixerDestroy(m) }
        asset(m, 0, [Float](repeating: 0.001, count: 8))
        asset(m, UInt32(RS_TYPING_PASSWORD_ASSET), [Float](repeating: 0.01, count: 8))
        RSTypingMixerSetEnabled(m, 1)
        for _ in 0..<(Int(RS_TYPING_VOICES) - 1) { XCTAssertEqual(RSTypingMixerEnqueue(m, 0, 0), 1) }
        XCTAssertEqual(RSTypingMixerEnqueue(m, 0, 1), 1)
        XCTAssertEqual(render(m, 1)[0][0], Float(RS_TYPING_VOICES - 1) * 0.001, accuracy: 0.00001)
        XCTAssertEqual(RSTypingMixerDroppedRequests(m), 1)
    }
    func testConcurrentProducerAndCallbackDeliverTenThousandClicksOnce() throws {
        let m = try XCTUnwrap(RSTypingMixerCreate()); defer { RSTypingMixerDestroy(m) }
        asset(m, 0, [0.001, 0.001]); RSTypingMixerSetEnabled(m, 1)
        let permits = DispatchSemaphore(value: 64), finished = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        done.enter()
        DispatchQueue(label: "typing-test-producer").async {
            defer { finished.signal(); done.leave() }
            for _ in 0..<10_000 {
                guard permits.wait(timeout: .now() + 10) == .success else { return }
                if RSTypingMixerEnqueue(m, 0, 0) != 1 { return }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var heard = 0, producerFinished = false
        while ProcessInfo.processInfo.systemUptime < deadline && (!producerFinished || heard < 10_000) {
            let planes = render(m, 1)
            let count = Int((planes[0][0] / 0.001).rounded())
            heard += count
            for _ in 0..<count { permits.signal() }
            if !producerFinished { producerFinished = finished.wait(timeout: .now()) == .success }
        }
        XCTAssertEqual(done.wait(timeout: .now() + 11), .success)
        XCTAssertEqual(heard, 10_000); XCTAssertEqual(RSTypingMixerDroppedRequests(m), 0)
        XCTAssertEqual(render(m, 1), [[0], [0]])
    }
}
