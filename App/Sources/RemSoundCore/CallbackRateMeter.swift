import AudioSupport
import Foundation

// Worker observations of frames delivered to a capture callback, before ring overflow.
// This is not a rate measured from hardware timestamps or the physical ADC clock.
struct CallbackRateMeter {
    struct Counter {
        let id: UUID
        let name: String
        let frames: UInt64
        let callbacks: UInt64
        let formatRate: Double
    }
    struct Measurement {
        let name: String
        let frames: UInt64
        let callbacks: UInt64
        let seconds: TimeInterval
        let wholeRunFrames: UInt64
        let wholeRunCallbacks: UInt64
        let wholeRunSeconds: TimeInterval
        let formatRate: Double
        var framesPerSecond: Double { Double(frames) / seconds }
        var callbacksPerSecond: Double { Double(callbacks) / seconds }
        var wholeRunFramesPerSecond: Double { Double(wholeRunFrames) / wholeRunSeconds }
        var wholeRunCallbacksPerSecond: Double { Double(wholeRunCallbacks) / wholeRunSeconds }
        var logDescription: String {
            "capture callback delivery: \(name), \(frames) format frames, \(callbacks) callbacks in "
                + "\(String(format: "%.3f", seconds)) s; \(String(format: "%.1f", framesPerSecond)) frames/s, "
                + "\(String(format: "%.3f", callbacksPerSecond)) callbacks/s, format rate \(String(format: "%.1f", formatRate)) Hz; "
                + "whole observed run \(String(format: "%.1f", wholeRunFramesPerSecond)) frames/s, "
                + "\(String(format: "%.3f", wholeRunCallbacksPerSecond)) callbacks/s in \(String(format: "%.3f", wholeRunSeconds)) s. "
                + "Valid captured callback frames, including ring overflow; not a physical ADC clock measurement. "
                + "Live atomic snapshot may span a completing callback."
        }
    }
    private struct Sample {
        let counter: Counter
        let at: TimeInterval
        let first: Counter
        let firstAt: TimeInterval
    }
    private var previous = [UUID: Sample]()

    static func counter(ring: StereoRing, id: UUID, name: String, formatRate: Double) -> Counter? {
        guard rs_ring_callback_metrics_lock_free(ring.raw) == 1 else { return nil }
        let figures = rs_ring_callback_figures(ring.raw)
        return Counter(id: id, name: name, frames: figures.frames, callbacks: figures.callbacks, formatRate: formatRate)
    }
    mutating func take(_ counters: [Counter], now: TimeInterval) -> [Measurement] {
        guard now.isFinite else { return [] }
        var current = [UUID: Sample]()
        var measurements = [Measurement]()
        for counter in counters where counter.formatRate.isFinite && counter.formatRate > 0 {
            current[counter.id] = Sample(counter: counter, at: now, first: counter, firstAt: now)
            guard let before = previous[counter.id], counter.frames >= before.counter.frames,
                  counter.callbacks >= before.counter.callbacks, counter.formatRate == before.counter.formatRate,
                  now >= before.at else { continue }
            if now == before.at {
                current[counter.id] = before
                continue
            }
            current[counter.id] = Sample(counter: counter, at: now, first: before.first, firstAt: before.firstAt)
            measurements.append(.init(name: counter.name, frames: counter.frames - before.counter.frames,
                callbacks: counter.callbacks - before.counter.callbacks, seconds: now - before.at,
                wholeRunFrames: counter.frames - before.first.frames,
                wholeRunCallbacks: counter.callbacks - before.first.callbacks, wholeRunSeconds: now - before.firstAt,
                formatRate: counter.formatRate))
        }
        previous = current
        return measurements
    }
}
