import XCTest
@testable import RemSoundJam

final class BufferSmoothnessTests: XCTestCase {
    private func append(_ queue: PlayoutQueue, frames: Int, packets: Int) {
        for _ in 0..<packets { queue.append([Float](repeating: 0.25, count: frames * 2)) }
    }

    func testEveryWindowsLevelAndActualIntegerWriteDuration() {
        let extras = [0, 3, 8, 16, 28, 45, 70, 110, 200]
        for (frames, writeMs) in [(233, 5), (120, 2), (960, 20), (64, 1)] {
            for level in 1...9 {
                let floor = level == 1 ? max(writeMs * 2 + 4, 4) : max(writeMs * 4 + 4, 15)
                XCTAssertEqual(PlayoutQueue.excessLimitFrames(targetMs: 10, packetFrames: frames, smoothness: level),
                    (10 + floor + extras[level - 1]) * 48)
                let cushion = level == 1 ? writeMs : writeMs * 2 + 5
                XCTAssertEqual(PlayoutQueue.trimDestinationFrames(targetMs: 10, packetFrames: frames, smoothness: level),
                    (10 + cushion) * 48)
            }
            XCTAssertEqual(PlayoutQueue.excessLimitFrames(targetMs: 10, packetFrames: frames, smoothness: 10), Int.max)
        }
        XCTAssertEqual(BufferSmoothness.defaultLevel, 3)
        XCTAssertEqual(BufferSmoothness.clamped(0), 1)
        XCTAssertEqual(BufferSmoothness.clamped(11), 10)
    }

    func testLiveChoiceReallyChangesSurgeTrimmingWithoutClearingAudio() {
        var depths: [Int] = []
        for (level, expected) in [(1, (10 + 5) * 48 - 240), (3, (10 + 15) * 48 - 240), (10, 20 * 233 - 240)] {
            let queue = PlayoutQueue(jitterMs: 10, packetFrames: 233, now: 0)
            append(queue, frames: 233, packets: 20)
            let before = queue.queuedFrames
            queue.setSmoothness(level)
            XCTAssertEqual(queue.queuedFrames, before, "Choosing a level must not clear or rebuffer the stream")
            XCTAssertEqual(queue.read(240, now: 0.01, keepsInTime: false).first, 0.25)
            XCTAssertEqual(queue.trims, level == 10 ? 0 : 1)
            XCTAssertEqual(queue.queuedFrames, expected)
            depths.append(queue.queuedFrames)
        }
        XCTAssertLessThan(depths[0], depths[1])
        XCTAssertLessThan(depths[1], depths[2])
    }

    func testLargestDecodedWriteAndRestartAreUsedInsteadOfOnlyFormatSize() {
        let queue = PlayoutQueue(jitterMs: 10, packetFrames: 120, now: 0)
        append(queue, frames: 480, packets: 1)
        append(queue, frames: 120, packets: 10)
        _ = queue.read(240, now: 0.01, keepsInTime: false)
        XCTAssertEqual(queue.trims, 0, "The actual largest write is 10 ms, allowing this burst")
        queue.reset(now: 0.02)
        append(queue, frames: 120, packets: 14)
        _ = queue.read(240, now: 0.03, keepsInTime: false)
        XCTAssertEqual(queue.trims, 1, "Restart forgets the previous larger write")
        queue.setSmoothness(99)
        XCTAssertEqual(queue.smoothness, 10)
        queue.setSmoothness(0)
        XCTAssertEqual(queue.smoothness, 1)
    }

    func testNoTrimRetainsSafetyCapClockKeepingAndJitterMoves() {
        let queue = PlayoutQueue(jitterMs: 20, packetFrames: 120, now: 0, smoothness: 10)
        append(queue, frames: 120, packets: 161)
        XCTAssertEqual(queue.overflows, 1)
        XCTAssertEqual(queue.queuedFrames, 19_200)
        XCTAssertEqual(queue.overflowDroppedFrames, 120)
        queue.reset(now: 0)
        var made = 0.0, sent = 0, now = 0.0
        while now < 25 {
            made += 480.48
            let whole = Int(made) - sent
            queue.append([Float](repeating: 0.1, count: whole * 2))
            queue.produced(whole, now: now)
            sent += whole
            _ = queue.read(480, now: now + 0.005, keepsInTime: true)
            now += 0.01
        }
        XCTAssertTrue(queue.clockTracking)
        XCTAssertEqual(queue.clockPpm ?? 0, 1000, accuracy: 60)
        XCTAssertEqual(queue.trims, 0)
        XCTAssertEqual(queue.smoothness, 10)
        queue.setJitterMs(10, byHand: true, keepsInTime: true)
        XCTAssertGreaterThan(queue.skippedFrames, 0, "No trim does not disable explicit target changes")
        XCTAssertEqual(queue.smoothness, 10)
    }
}
