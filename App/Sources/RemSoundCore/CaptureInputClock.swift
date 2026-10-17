import Foundation
import RemSoundJam

struct CaptureCallbackPeak {
    private static let settlingSeconds = 0.5
    private var sequence: UInt64 = 0
    private var frames = 0
    private var peakAt: Double?
    private var lastAt: Double?

    mutating func observe(_ callback: CaptureInputClocks.Callback, now: Double) -> Int {
        if callback.sequence > 0, callback.frames > 0, callback.sequence != sequence {
            if callback.sequence < sequence { self = Self() }
            sequence = callback.sequence
            lastAt = now
            // Hold alternating callback sizes steady, but follow a sustained buffer change.
            if callback.frames >= frames || (peakAt.map({ now - $0 >= Self.settlingSeconds }) ?? true) {
                frames = callback.frames
                peakAt = now
            }
        }
        guard let lastAt, now - lastAt < Self.settlingSeconds else {
            frames = 0
            return 0
        }
        return frames
    }
}

// Used only for selected physical inputs, on the session worker. Generic tap mixes bypass it.
final class CaptureInputClocks {
    struct Callback {
        let sequence: UInt64
        let frames: Int
        static let unavailable = Callback(sequence: 0, frames: 0)
    }
    struct Figures {
        let callbackFrames, targetFrames: Int
        let tracking, primed, keepingInTime: Bool
        let ratio, ppm: Double
        let rejected: Int
        func logDescription(name: String) -> String {
            let state = !keepingInTime ? "bypassed" : !primed ? "priming"
                : tracking ? "tracking" : "measuring"
            let callback = callbackFrames > 0 ? "\(callbackFrames) frames" : "unavailable"
            let measured = tracking ? String(format: "%+.1f ppm", ppm) : "unavailable"
            return String(format: "input clock correction: %@, %@, normalized callback=%@, "
                + "common target=%d frames (%.3f ms), measured=%@, applied input/output ratio=%.9f, rejected=%d",
                name, state, callback, targetFrames, Double(targetFrames) * 1000 / Double(Wire.sampleRate),
                measured, ratio, rejected)
        }
    }
    private static let dispatchFrames = Wire.sampleRate / 1_000
    private static let interpolationFrames = 2
    private static let primingPackets = 2
    private static let maximumPrimingSeconds = 0.1
    private let sources: [StereoRing]
    private let callbacks: () -> [Callback]
    private var peaks: [CaptureCallbackPeak]
    private var observedFrames: [Int]
    private var clocks: [InputClock]
    private var keepingInTime = ClockKeeping.on
    private var targetFrames = 0
    private var primed = false
    private var primingStartedAt: Double?

    init(sources: [StereoRing], callbacks: @escaping () -> [Callback]) {
        self.sources = sources
        self.callbacks = callbacks
        peaks = sources.map { _ in CaptureCallbackPeak() }
        observedFrames = sources.map { _ in 0 }
        clocks = sources.map(InputClock.init)
    }

    static func target(callbackFrames: Int, packetFrames: Int) -> Int {
        max(callbackFrames, packetFrames * 2 + dispatchFrames + interpolationFrames)
    }

    var figures: [Figures] {
        clocks.enumerated().map { index, clock in
            Figures(callbackFrames: observedFrames[index], targetFrames: targetFrames,
                tracking: clock.tracking, primed: primed, keepingInTime: keepingInTime,
                ratio: clock.ratio, ppm: clock.ppm, rejected: clock.rejected)
        }
    }

    func resetAfterTrim() { clocks = sources.map(InputClock.init) }

    private func resetForPriming() {
        resetAfterTrim()
        primed = false
        primingStartedAt = nil
    }

    func prepareRead(frames: Int, now: Double, keepingInTime: Bool) -> Bool {
        if self.keepingInTime != keepingInTime {
            self.keepingInTime = keepingInTime
            resetForPriming()
        }
        let observations = callbacks()
        for index in sources.indices {
            let callback = index < observations.count ? observations[index] : .unavailable
            observedFrames[index] = peaks[index].observe(callback, now: now)
        }
        let target = Self.target(callbackFrames: observedFrames.max() ?? 0, packetFrames: frames)
        if target != targetFrames {
            targetFrames = target
            resetForPriming()
        }
        guard keepingInTime, !primed else { return true }
        if primingStartedAt == nil { primingStartedAt = now }
        let ready = sources.allSatisfy { $0.available >= targetFrames + Self.primingPackets * frames }
        if !ready && now - primingStartedAt! < Self.maximumPrimingSeconds { return false }
        primed = true
        // Exclude setup/priming frames from the first measured steady clock window.
        resetAfterTrim()
        return true
    }

    func read(sourceAt index: Int, frames: Int, now: Double) -> [Float] {
        guard keepingInTime else { return sources[index].read(frames) }
        return clocks[index].read(source: sources[index], frames: frames, now: now, target: targetFrames)
    }

    private final class InputClock {
        private var meter = DriftMeter()
        private var previousProduced: Int
        private var resampler = StereoResampler()
        private var resampling = false
        var tracking: Bool { meter.tracking }
        var ratio: Double { meter.tracking ? meter.ratio : 1 }
        var ppm: Double { meter.ppm }
        var rejected: Int { meter.rejected }

        init(source: StereoRing) { previousProduced = source.writtenFrames + source.droppedFrames }

        func read(source: StereoRing, frames: Int, now: Double, target: Int) -> [Float] {
            let produced = source.writtenFrames + source.droppedFrames
            if produced < previousProduced {
                meter.reset()
                resampler.reset()
                resampling = false
            }
            let difference = max(0, produced - previousProduced)
            previousProduced = produced
            if difference > 0 { meter.produced(difference, now: now) }
            meter.consumed(frames, now: now)
            let ratio = meter.update(depthFrames: Double(source.available), targetFrames: Double(target), now: now)
            guard meter.tracking else { return source.read(frames) }
            if !resampling {
                resampling = true
                resampler.reset()
            }
            // Preserve held interpolation frames across brief padding; resetting on every
            // short pull repeatedly consumes lookahead and can prevent the cushion filling.
            let requested = resampler.inputFrames(forOutput: frames, ratio: ratio)
            return resampler.pull(source.read(requested), outFrames: frames, ratio: ratio)
        }
    }
}
