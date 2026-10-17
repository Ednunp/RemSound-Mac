import AudioSupport
import CoreAudio
import Foundation

struct CaptureTimestampObservation {
    private(set) var callbackAgeMs: Double?
    private(set) var oldestUnreadAgeMs: Double?
    private(set) var queueOriginDifferenceMs: Double?
    private(set) var sampleTime: Double?
    private(set) var unavailableReason = "no coherent capture observation"
    private let snapshot: RSCaptureSnapshot

    init(_ snapshot: RSCaptureSnapshot, nowTicks: UInt64, secondsPerTick: Double) {
        self.snapshot = snapshot
        guard snapshot.coherent == 1 else { return }
        if snapshot.timestamp_flags & AudioTimeStampFlags.sampleTimeValid.rawValue != 0, snapshot.sample_time.isFinite {
            sampleTime = snapshot.sample_time
        }
        guard secondsPerTick.isFinite, secondsPerTick > 0 else {
            unavailableReason = "host timebase unavailable"; return
        }
        guard snapshot.timestamp_flags & AudioTimeStampFlags.hostTimeValid.rawValue != 0, snapshot.capture_host_time > 0 else {
            unavailableReason = "capture host timestamp unavailable"; return
        }
        guard snapshot.callback_host_time >= snapshot.capture_host_time,
            nowTicks >= snapshot.callback_host_time else {
            unavailableReason = "future capture or callback timestamp"; return
        }
        callbackAgeMs = Double(snapshot.callback_host_time - snapshot.capture_host_time) * secondsPerTick * 1000
        guard snapshot.sample_rate.isFinite, snapshot.sample_rate > 0 else {
            unavailableReason = "capture format rate unavailable"; return
        }
        guard snapshot.frames > 0, snapshot.accepted_frames == snapshot.frames,
            snapshot.written_frame >= snapshot.first_frame,
            snapshot.written_frame - snapshot.first_frame == snapshot.accepted_frames else {
            unavailableReason = "capture block was not wholly accepted"; return
        }
        guard snapshot.read_frame < snapshot.written_frame else {
            unavailableReason = "no unread frames"; return
        }
        guard snapshot.read_frame >= snapshot.first_frame else {
            unavailableReason = "oldest unread frame predates observed block"; return
        }
        // Only map unread frames inside this callback. Older blocks may have different clocks,
        // a discontinuity or overflow; extrapolating backward would invent an acquisition origin.
        let age = Double(nowTicks - snapshot.capture_host_time) * secondsPerTick
            - Double(snapshot.read_frame - snapshot.first_frame) / snapshot.sample_rate
        guard age.isFinite, age >= 0 else {
            unavailableReason = "future unread frame timestamp"; return
        }
        oldestUnreadAgeMs = age * 1000
        queueOriginDifferenceMs = (age - Double(snapshot.written_frame - snapshot.read_frame) / snapshot.sample_rate) * 1000
        unavailableReason = "available within observed block"
    }

    static func describe(ring: OpaquePointer, name: String) -> String {
        let snapshot = rs_ring_capture_snapshot(ring)
        return Self(snapshot, nowTicks: rs_callback_begin(),
            secondsPerTick: rs_ring_host_seconds(ring, 1)).logDescription(name: name)
    }

    static func note(ring: OpaquePointer, began: UInt64, time: AudioTimeStamp,
        frames: Int, accepted: Int, rate: Double, origin: UInt32) {
        rs_ring_note_capture(ring, began, time.mHostTime, time.mSampleTime,
            time.mFlags.rawValue, frames, accepted, rate, origin)
    }

    func logDescription(name: String) -> String {
        let origin: String
        switch snapshot.origin {
        case UInt32(RS_CAPTURE_HAL): origin = "HAL input first-frame timestamp"
        case UInt32(RS_CAPTURE_AV_TAP): origin = "AV input tap timestamp"
        case UInt32(RS_CAPTURE_PROCESS_TAP): origin = "process-tap aggregate, not an ADC measurement"
        default: origin = "unavailable timestamp source"
        }
        func ms(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "unavailable" }
        return "capture timestamp: \(name), \(origin), observation \(snapshot.sequence), flags \(snapshot.timestamp_flags), "
            + "sample time \(sampleTime.map { String(format: "%.3f", $0) } ?? "unavailable"), "
            + "format rate \(snapshot.sample_rate) Hz, block \(snapshot.frames)/\(snapshot.accepted_frames) native/accepted frames, "
            + "ring first/write/read \(snapshot.first_frame)/\(snapshot.written_frame)/\(snapshot.read_frame), drops \(snapshot.dropped_frames); "
            + "first frame age at callback \(ms(callbackAgeMs)) ms, oldest unread age now \(ms(oldestUnreadAgeMs)) ms, "
            + "oldest age minus queued duration \(ms(queueOriginDifferenceMs)) ms (excludes AV/device adjustment); "
            + "\(unavailableReason); observation only; capture origin unchanged."
    }
}
