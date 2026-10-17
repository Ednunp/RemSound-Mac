import AudioSupport
import AudioToolbox
import CoreAudio
import Foundation

// Immutable data retained by CoreAudio's copied block, including invocations that
// were retained before unregister. Its gate is checked before ring/wake access.
final class DirectInputCallback {
    let samples: StereoRing
    let channels: UInt32
    let pairs: [Int]
    let lease: OpaquePointer
    private let wake: OpaquePointer?

    init(samples: StereoRing, channels: UInt32, pairs: [Int], wake: OpaquePointer?) throws {
        guard channels > 0, !pairs.isEmpty,
            pairs.allSatisfy({ $0 >= 0 && $0 < Int(channels / 2) })
                || channels == 1 && pairs == [0] else {
            throw ProtocolError.invalid("The chosen input channel pair is unavailable.")
        }
        guard let lease = rs_capture_lease_create() else {
            throw ProtocolError.invalid("Could not allocate lock-free input callback ownership.")
        }
        self.samples = samples
        self.channels = channels
        self.pairs = pairs
        self.wake = wake
        self.lease = lease
    }
    func retire() { _ = rs_capture_lease_retire(lease) }
    var idle: Bool { rs_capture_lease_idle(lease) == 1 }

    func process(_ input: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>) {
        guard rs_capture_lease_enter(lease) == 1 else { return }
        defer { rs_capture_lease_leave(lease) }
        let began = rs_callback_begin()
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mNumberChannels == channels,
            let data = first.mData else { return }
        let count = Int(channels)
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * count)
        guard frames > 0 else { return }
        let dataSamples = data.assumingMemoryBound(to: Float.self)
        let accepted: Int
        if count == 1 {
            accepted = rs_ring_write(samples.raw, dataSamples, dataSamples, frames)
        } else {
            accepted = pairs.withUnsafeBufferPointer {
                rs_ring_write_interleaved_pairs(samples.raw, dataSamples, count,
                    $0.baseAddress, $0.count, frames)
            }
        }
        CaptureTimestampObservation.note(ring: samples.raw, began: began,
            time: time.pointee, frames: frames, accepted: accepted,
            rate: Double(Wire.sampleRate), origin: UInt32(RS_CAPTURE_HAL))
        if let wake, accepted > 0 { _ = rs_capture_wake_signal(wake, samples.available) }
        rs_ring_note_callback(samples.raw, began, frames, Double(Wire.sampleRate))
    }
    deinit {
        // A still-entered callback must keep its native-owned context alive. If a
        // provider violates that lifetime, retain the allocation instead of UAF.
        _ = rs_capture_lease_destroy(lease)
    }
}

// Internal injection boundary: tests retain the same block the native API copies.
// No alternate public capture API or callback-thread work queue is introduced.
struct DirectInputIO {
    var register: (AudioDeviceID, @escaping AudioDeviceIOBlock, UnsafeMutablePointer<AudioDeviceIOProcID?>) -> OSStatus
    var start: (AudioDeviceID, AudioDeviceIOProcID) -> OSStatus
    var stop: (AudioDeviceID, AudioDeviceIOProcID) -> OSStatus
    var destroy: (AudioDeviceID, AudioDeviceIOProcID) -> OSStatus
    static let coreAudio = DirectInputIO(
        register: { device, block, result in
            AudioDeviceCreateIOProcIDWithBlock(result, device, nil, block)
        }, start: AudioDeviceStart, stop: AudioDeviceStop, destroy: AudioDeviceDestroyIOProcID)
}

// Owned by the serial session worker, never called by the audio callback.
// The owner MUST retain failed/busy retirement until pollRetirement returns true.
final class DirectInputRegistration {
    private static let retryInterval: TimeInterval = 0.01
    private static let maximumDestroyAttempts = 100
    let context: DirectInputCallback
    private let device: AudioDeviceID
    private let io: DirectInputIO
    private var proc: AudioDeviceIOProcID?
    private var retiring = false
    private var nextRetryAt: TimeInterval = 0
    private(set) var stopStatus: OSStatus?
    private(set) var destroyStatus: OSStatus?
    private(set) var destroyAttempts = 0

    init(device: AudioDeviceID, context: DirectInputCallback, io: DirectInputIO = .coreAudio) {
        self.device = device
        self.context = context
        self.io = io
    }
    func start() throws {
        guard proc == nil, !retiring else {
            throw ProtocolError.invalid("Previous direct input capture is still active or retiring.")
        }
        let retainedContext = context
        let block: AudioDeviceIOBlock = { _, input, time, _, _ in
            retainedContext.process(input, time: time)
        }
        let result = io.register(device, block, &proc)
        guard result == noErr, let proc else {
            _ = retire()
            throw ProtocolError.invalid("Could not register direct input capture (Core Audio error \(result)).")
        }
        let started = io.start(device, proc)
        guard started == noErr else {
            _ = retire()
            throw ProtocolError.invalid("Could not start direct input capture (Core Audio error \(started)).")
        }
    }
    @discardableResult
    func retire(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if !retiring {
            retiring = true
            context.retire()
            if let proc { stopStatus = io.stop(device, proc) }
        }
        return pollRetirement(now: now)
    }
    func pollRetirement(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard retiring else { return false }
        if let proc, now >= nextRetryAt, destroyAttempts < Self.maximumDestroyAttempts {
            destroyAttempts += 1
            nextRetryAt = now + Self.retryInterval
            let status = io.destroy(device, proc)
            destroyStatus = status
            if status == noErr { self.proc = nil }
        }
        // Successful unregister alone is insufficient: an entered callback may
        // still be using the wake pointer. Late blocks only touch the closed gate.
        return proc == nil && context.idle
    }
    var retirementExhausted: Bool {
        retiring && proc != nil && destroyAttempts >= Self.maximumDestroyAttempts
    }
}
