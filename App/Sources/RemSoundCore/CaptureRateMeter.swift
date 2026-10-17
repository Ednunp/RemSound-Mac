import Foundation
import RemSoundJam

// Snapshot existing atomic capture counters on the session queue, never in an audio callback.
struct CaptureRateMeter {
    struct Counter {
        let id: UUID
        let name: String
        let frames: Int
        var queuedFrames: Int = 0
    }
    struct Measurement {
        let name: String
        let frames: Int
        let seconds: TimeInterval
        let wholeRunFrames: Int
        let wholeRunSeconds: TimeInterval
        var framesPerSecond: Double { Double(frames) / seconds }
        var wholeRunFramesPerSecond: Double { Double(wholeRunFrames) / wholeRunSeconds }
    }
    private struct Sample {
        let frames: Int
        let at: TimeInterval
        let firstFrames: Int
        let firstAt: TimeInterval
    }
    private var previous: [UUID: Sample] = [:]

    mutating func take(_ counters: [Counter], now: TimeInterval) -> [Measurement] {
        guard now.isFinite else { return [] }
        var current: [UUID: Sample] = [:]
        var measurements: [Measurement] = []
        for counter in counters where counter.frames >= 0 {
            current[counter.id] = Sample(frames: counter.frames, at: now, firstFrames: counter.frames, firstAt: now)
            guard let before = previous[counter.id], counter.frames >= before.frames, now >= before.at else { continue }
            if now == before.at {
                current[counter.id] = before
                continue
            }
            current[counter.id] = Sample(frames: counter.frames, at: now,
                                         firstFrames: before.firstFrames, firstAt: before.firstAt)
            measurements.append(Measurement(name: counter.name, frames: counter.frames - before.frames,
                                            seconds: now - before.at, wholeRunFrames: counter.frames - before.firstFrames,
                                            wholeRunSeconds: now - before.firstAt))
        }
        previous = current
        return measurements
    }
}

// Observe the capture and send clocks without changing the mix or applying a resampling ratio.
struct CaptureSourceDriftDiagnostics {
    struct Snapshot {
        let id: UUID
        let name: String
        let queuedFrames: Int
        let ppm: Double?
        let rejectedWindows: Int
    }
    private final class Source {
        var previousFrames: Int
        var meter = DriftMeter()
        var name: String
        var queuedFrames: Int
        init(previousFrames: Int, name: String, queuedFrames: Int) {
            self.previousFrames = previousFrames
            self.name = name
            self.queuedFrames = queuedFrames
        }
    }
    private var sources: [UUID: Source] = [:]
    private var order: [UUID] = []
    var snapshots: [Snapshot] {
        order.compactMap { id in
            guard let source = sources[id] else { return nil }
            return Snapshot(id: id, name: source.name, queuedFrames: source.queuedFrames,
                            ppm: source.meter.tracking ? source.meter.ppm : nil,
                            rejectedWindows: source.meter.rejected)
        }
    }
    mutating func observe(_ counters: [CaptureRateMeter.Counter], consumedFrames: Int, now: TimeInterval) {
        var current: [UUID: Source] = [:]
        for counter in counters {
            let source = sources[counter.id] ?? Source(previousFrames: counter.frames,
                                                       name: counter.name, queuedFrames: counter.queuedFrames)
            if counter.frames < source.previousFrames { source.meter.reset() }
            let produced = max(0, counter.frames - source.previousFrames)
            if produced > 0 { source.meter.produced(produced, now: now) }
            if consumedFrames > 0 { source.meter.consumed(consumedFrames, now: now) }
            _ = source.meter.update(depthFrames: Double(counter.queuedFrames), targetFrames: 0, now: now)
            source.previousFrames = counter.frames
            source.name = counter.name
            source.queuedFrames = counter.queuedFrames
            current[counter.id] = source
        }
        sources = current
        order = counters.map(\.id)
    }
}
