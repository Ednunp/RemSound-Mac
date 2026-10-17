import AudioSupport
import CoreAudio
import Foundation
import XCTest
@testable import RemSoundCore

final class CaptureTimestampTests: XCTestCase {
    private func write(_ ring: OpaquePointer, frames: Int, host: UInt64,
        sample: Double, rate: Double = 48_000, flags: UInt32 = 3) {
        let audio = [Float](repeating: 0.25, count: frames * 2)
        let accepted = rs_ring_write_interleaved(ring, audio, frames)
        rs_ring_note_capture(ring, host + 10_000_000, host, sample, flags,
            frames, accepted, rate, UInt32(RS_CAPTURE_HAL))
    }

    func testFreshBlockReadAndTrimPreserveAcquisitionOrigin() throws {
        let ring = try XCTUnwrap(rs_ring_create(960))
        defer { rs_ring_destroy(ring) }
        XCTAssertEqual(rs_ring_capture_snapshot(ring).coherent, 0)
        write(ring, frames: 480, host: 1_000_000_000, sample: 42)
        let first = CaptureTimestampObservation(rs_ring_capture_snapshot(ring),
            nowTicks: 1_015_000_000, secondsPerTick: 1e-9)
        XCTAssertEqual(try XCTUnwrap(first.callbackAgeMs), 10, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(first.oldestUnreadAgeMs), 15, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(first.queueOriginDifferenceMs), 5, accuracy: 0.0001)
        XCTAssertEqual(first.sampleTime, 42)
        _ = rs_ring_discard(ring, 240)
        let trimmed = CaptureTimestampObservation(rs_ring_capture_snapshot(ring),
            nowTicks: 1_015_000_000, secondsPerTick: 1e-9)
        XCTAssertEqual(try XCTUnwrap(trimmed.oldestUnreadAgeMs), 10, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(trimmed.queueOriginDifferenceMs), 5, accuracy: 0.0001)
        XCTAssertTrue(trimmed.logDescription(name: "Mic").contains("observation only"))
        _ = rs_ring_discard(ring, 240)
        let empty = CaptureTimestampObservation(rs_ring_capture_snapshot(ring),
            nowTicks: 1_015_000_000, secondsPerTick: 1e-9)
        XCTAssertNil(empty.oldestUnreadAgeMs)
    }

    func testBacklogOverflowAndUnpublishedWritesCannotInventAnOrigin() throws {
        let ring = try XCTUnwrap(rs_ring_create(960))
        defer { rs_ring_destroy(ring) }
        write(ring, frames: 480, host: 1_000_000_000, sample: 0)
        write(ring, frames: 480, host: 1_010_000_000, sample: 480)
        let backlog = CaptureTimestampObservation(rs_ring_capture_snapshot(ring),
            nowTicks: 1_025_000_000, secondsPerTick: 1e-9)
        XCTAssertNil(backlog.oldestUnreadAgeMs, "Do not extrapolate across older callbacks")
        XCTAssertEqual(backlog.unavailableReason, "oldest unread frame predates observed block")
        write(ring, frames: 480, host: 1_020_000_000, sample: 960)
        let overflow = CaptureTimestampObservation(rs_ring_capture_snapshot(ring),
            nowTicks: 1_035_000_000, secondsPerTick: 1e-9)
        XCTAssertNil(overflow.oldestUnreadAgeMs)
        XCTAssertEqual(overflow.unavailableReason, "capture block was not wholly accepted")
        _ = rs_ring_discard(ring, 960)
        write(ring, frames: 480, host: 1_030_000_000, sample: 1_440)
        let recovered = CaptureTimestampObservation(rs_ring_capture_snapshot(ring),
            nowTicks: 1_045_000_000, secondsPerTick: 1e-9)
        XCTAssertEqual(try XCTUnwrap(recovered.oldestUnreadAgeMs), 15, accuracy: 0.0001)
        let extra = [Float](repeating: 0, count: 2)
        _ = rs_ring_write_interleaved(ring, extra, 1)
        XCTAssertEqual(rs_ring_capture_snapshot(ring).coherent, 0,
            "A new ring write without its matching timestamp must invalidate the old tuple")
    }

    func testMissingFutureInvalidAndDifferentTimestampOriginsStayExplicit() throws {
        let ring = try XCTUnwrap(rs_ring_create(960))
        defer { rs_ring_destroy(ring) }
        write(ring, frames: 480, host: 1_000_000_000, sample: .nan, flags: 0)
        var observation = CaptureTimestampObservation(rs_ring_capture_snapshot(ring),
            nowTicks: 1_015_000_000, secondsPerTick: 1e-9)
        XCTAssertNil(observation.callbackAgeMs)
        XCTAssertNil(observation.sampleTime)
        XCTAssertNil(observation.oldestUnreadAgeMs)
        _ = rs_ring_discard(ring, 480)
        write(ring, frames: 480, host: 2_000_000_000, sample: 480)
        observation = CaptureTimestampObservation(rs_ring_capture_snapshot(ring),
            nowTicks: 1_015_000_000, secondsPerTick: 1e-9)
        XCTAssertNil(observation.oldestUnreadAgeMs)
        XCTAssertTrue(observation.unavailableReason.contains("future"))
        var snapshot = rs_ring_capture_snapshot(ring)
        for rate in [0.0, -1, .nan, .infinity] {
            snapshot.sample_rate = rate
            XCTAssertNil(CaptureTimestampObservation(snapshot, nowTicks: 2_020_000_000,
                secondsPerTick: 1e-9).oldestUnreadAgeMs)
        }
        snapshot.sample_rate = 96_000
        snapshot.read_frame = snapshot.first_frame + 240
        snapshot.origin = UInt32(RS_CAPTURE_PROCESS_TAP)
        let tap = CaptureTimestampObservation(snapshot, nowTicks: 2_020_000_000, secondsPerTick: 1e-9)
        XCTAssertEqual(try XCTUnwrap(tap.oldestUnreadAgeMs), 17.5, accuracy: 0.0001)
        XCTAssertTrue(tap.logDescription(name: "System").contains("process-tap aggregate"))
        XCTAssertTrue(tap.logDescription(name: "System").contains("not an ADC measurement"))
    }

    func testConcurrentSnapshotsNeverCombineDifferentCaptureBlocks() throws {
        let ring = try XCTUnwrap(rs_ring_create(10_000))
        defer { rs_ring_destroy(ring) }
        XCTAssertEqual(rs_ring_capture_metrics_lock_free(ring), 1)
        DispatchQueue.concurrentPerform(iterations: 3) { lane in
            for index in 0..<5_000 {
                if lane == 0 {
                    self.write(ring, frames: 1, host: UInt64(index + 1) * 1_000_000,
                        sample: Double(index))
                } else {
                    let value = rs_ring_capture_snapshot(ring)
                    if value.coherent == 1 {
                        XCTAssertEqual(value.capture_host_time, (value.first_frame + 1) * 1_000_000)
                        XCTAssertEqual(value.sample_time, Double(value.first_frame))
                        XCTAssertEqual(value.callback_host_time, value.capture_host_time + 10_000_000)
                        XCTAssertEqual(value.written_frame, value.first_frame + 1)
                    }
                }
            }
        }
        let final = rs_ring_capture_snapshot(ring)
        XCTAssertEqual(final.coherent, 1)
        XCTAssertEqual(final.written_frame, 5_000)
        XCTAssertEqual(final.sequence, 10_000)
        XCTAssertTrue(rs_ring_host_seconds(ring, 1).isFinite)
        XCTAssertGreaterThan(rs_ring_host_seconds(ring, 1), 0)
    }

    func testAdapterPreservesFlagsAndFreshRingResetsWithoutExtrapolatingDiscontinuities() throws {
        let ring = try XCTUnwrap(rs_ring_create(960))
        let restarted = try XCTUnwrap(rs_ring_create(960))
        defer { rs_ring_destroy(ring); rs_ring_destroy(restarted) }
        let audio = [Float](repeating: 0, count: 960)
        let accepted = rs_ring_write_interleaved(ring, audio, 480)
        var time = AudioTimeStamp()
        time.mHostTime = 1_000_000_000
        time.mSampleTime = -480
        time.mFlags = [.hostTimeValid, .sampleTimeValid]
        CaptureTimestampObservation.note(ring: ring, began: 1_010_000_000, time: time,
            frames: 480, accepted: accepted, rate: 96_000, origin: UInt32(RS_CAPTURE_AV_TAP))
        var observation = CaptureTimestampObservation(rs_ring_capture_snapshot(ring),
            nowTicks: 1_015_000_000, secondsPerTick: 1e-9)
        XCTAssertEqual(observation.sampleTime, -480, "Valid negative sample positions can be pre-roll")
        XCTAssertEqual(try XCTUnwrap(observation.queueOriginDifferenceMs), 10, accuracy: 0.0001)
        XCTAssertTrue(observation.logDescription(name: "Input").contains("AV input tap timestamp"))
        _ = rs_ring_discard(ring, 480)
        write(ring, frames: 480, host: 900_000_000, sample: 0, rate: 48_000)
        observation = CaptureTimestampObservation(rs_ring_capture_snapshot(ring),
            nowTicks: 1_015_000_000, secondsPerTick: 1e-9)
        XCTAssertEqual(try XCTUnwrap(observation.oldestUnreadAgeMs), 115, accuracy: 0.0001,
            "Report the current block's timestamp after a discontinuity; never extrapolate the previous origin")
        XCTAssertEqual(rs_ring_capture_snapshot(restarted).coherent, 0)
        write(restarted, frames: 480, host: 1_000_000_000, sample: 0, flags: 2)
        observation = CaptureTimestampObservation(rs_ring_capture_snapshot(restarted),
            nowTicks: 1_015_000_000, secondsPerTick: 1e-9)
        XCTAssertNil(observation.sampleTime, "Host-valid is not sample-valid")
        XCTAssertEqual(try XCTUnwrap(observation.oldestUnreadAgeMs), 15, accuracy: 0.0001)
    }
}
