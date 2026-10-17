import Foundation
import RemSoundJam

// A secondary source is pulled only by an actual driver's block, on the Session worker.
final class PluginSecondaryLane {
    static let sampleRate = Bridge.sampleRate, channels = Bridge.channels, capacityFrames = sampleRate / 2
    private static let framesPerMillisecond = sampleRate / 1_000
    private static let initialCushionMilliseconds = 12, minimumCushionMilliseconds = 8, maximumCushionMilliseconds = 50
    private static let cushionHysteresisMilliseconds = 2, resamplerHeldFrames = 2
    private static let pullMargin = 1.2, minimumRepresentableStep = 0.0005
    static let maximumFrames = Bridge.maxAudioBytes / (MemoryLayout<Float>.size * channels)
    private static let minimumRatio = DriftMeter.ratioMin - DriftMeter.maxDepthBias
    private static let maximumRatio = DriftMeter.ratioMax + DriftMeter.maxDepthBias
    private static let maximumInputFrames = Int((Double(maximumFrames) * maximumRatio).rounded(.up)) + resamplerHeldFrames
    enum Failure: Equatable { case invalidClock, counterOverflow, invalidResampler }
    struct Snapshot {
        let bufferedFrames: Int, targetFrames: Int, droppedFrames: UInt64, shortFrames: UInt64
        let primed: Bool, ratio: Double, clockRatio: Double, tracking: Bool, acceptedWindows: Int
        let discardedStartupWindow: Bool
        let failure: Failure?
    }
    private var ring = [Float](repeating: 0, count: capacityFrames * channels)
    private var head = 0, available = 0
    private var resampler = StereoResampler(), meter = DriftMeter()
    private var lastTime: Double?, primed = false
    private var discardedStartupWindow = false
    private var produced: Int64 = 0, consumed: Int64 = 0
    private var dropped: UInt64 = 0, short: UInt64 = 0
    private var targetMilliseconds = initialCushionMilliseconds, windowStart: Double?
    private var pullFrames: UInt64 = 0, pullCount: UInt64 = 0
    private(set) var failure: Failure?
    var snapshot: Snapshot {
        Snapshot(bufferedFrames: available, targetFrames: targetMilliseconds * Self.framesPerMillisecond,
            droppedFrames: dropped, shortFrames: short, primed: primed, ratio: meter.ratio, clockRatio: meter.clockRatio,
            tracking: meter.tracking, acceptedWindows: meter.accepted, discardedStartupWindow: discardedStartupWindow, failure: failure)
    }
    @discardableResult func feed(_ samples: [Float], now: Double) -> Bool {
        guard failure == nil, !samples.isEmpty, samples.count.isMultiple(of: Self.channels),
            samples.count <= Self.maximumFrames * Self.channels, samples.allSatisfy(\.isFinite) else { return false }
        guard admitTime(now) else { return false }
        let frames = samples.count / Self.channels
        let excess = max(0, available + frames - Self.capacityFrames)
        if excess > 0 {
            guard add(&dropped, UInt64(excess)) else { return fail(.counterOverflow) }
            head = (head + excess) % Self.capacityFrames; available -= excess
            // A capacity cut is a discontinuity: do not interpolate with sound from before the cut.
            resetMeasurement()
        }
        if primed {
            guard produced <= Int64.max - Int64(frames) else { return fail(.counterOverflow) }
            produced += Int64(frames); meter.produced(frames, now: now)
        }
        for frame in 0..<frames {
            let slot = (head + available + frame) % Self.capacityFrames
            ring[slot * 2] = samples[frame * 2]; ring[slot * 2 + 1] = samples[frame * 2 + 1]
        }
        available += frames
        return true
    }
    func pull(frames: Int, now: Double) -> [Float]? {
        guard failure == nil, (1...Self.maximumFrames).contains(frames) else { return nil }
        guard admitTime(now) else { return nil }
        let ratio = meter.ratio
        guard ratio.isFinite, (Self.minimumRatio...Self.maximumRatio).contains(ratio),
            resampler.nextPosition.isFinite, (0...Double(Self.resamplerHeldFrames)).contains(resampler.nextPosition) else {
            fail(.invalidResampler); return nil
        }
        let needed = resampler.inputFrames(forOutput: frames, ratio: ratio)
        guard (1...Self.maximumInputFrames).contains(needed) else { fail(.invalidResampler); return nil }
        if !primed {
            guard available >= max(targetMilliseconds * Self.framesPerMillisecond, needed) else {
                return [Float](repeating: 0, count: frames * Self.channels)
            }
            primed = true; meter.reset(); produced = 0; consumed = 0
            windowStart = now; pullFrames = 0; pullCount = 0
        }
        guard consumed <= Int64.max - Int64(frames), add(&pullFrames, UInt64(frames)), add(&pullCount, 1) else {
            fail(.counterOverflow); return nil
        }
        consumed += Int64(frames); meter.consumed(frames, now: now)
        updateTarget(now)
        // This reading affects the next pull; this pull uses the already-validated ratio above.
        _ = meter.update(depthFrames: Double(available), targetFrames: Double(targetMilliseconds * Self.framesPerMillisecond), now: now)
        if !discardedStartupWindow, meter.accepted > 0 || meter.rejected > 0 {
            // The first completed window belongs to acquisition, not an applied clock ratio.
            discardedStartupWindow = true; meter.reset(); produced = 0; consumed = 0
        }
        let taken = min(available, needed)
        var input = [Float](repeating: 0, count: needed * Self.channels)
        for frame in 0..<taken {
            let slot = (head + frame) % Self.capacityFrames
            input[frame * 2] = ring[slot * 2]; input[frame * 2 + 1] = ring[slot * 2 + 1]
        }
        head = (head + taken) % Self.capacityFrames; available -= taken
        guard add(&short, UInt64(needed - taken)) else { fail(.counterOverflow); return nil }
        let output = resampler.pull(input, outFrames: frames, ratio: ratio)
        guard output.count == frames * Self.channels, output.allSatisfy(\.isFinite) else {
            fail(.invalidResampler); return nil
        }
        return output
    }
    // The existing OutputCushion stays private to RemSoundJam. This worker's target follows
    // the same primary adaptive rule, using its actual pulls rather than a card's counters.
    private func updateTarget(_ now: Double) {
        guard let start = windowStart, now - start >= DriftMeter.windowSec else { return }
        if pullCount > 0 {
            let average = Double(pullFrames) / Double(pullCount)
            let candidate = Int(min(Double(Self.maximumCushionMilliseconds), max(Double(Self.minimumCushionMilliseconds),
                average / Double(Self.framesPerMillisecond) * Self.pullMargin)).rounded(.toNearestOrEven))
            if abs(candidate - targetMilliseconds) >= Self.cushionHysteresisMilliseconds { targetMilliseconds = candidate }
        }
        windowStart = now; pullFrames = 0; pullCount = 0
    }
    private func admitTime(_ now: Double) -> Bool {
        guard now.isFinite, now >= 0, lastTime.map({ now >= $0 }) ?? true,
            (now + DriftMeter.windowSec).isFinite, now + Self.minimumRepresentableStep > now else { return fail(.invalidClock) }
        lastTime = now; return true
    }
    private func resetMeasurement() {
        resampler.reset(); meter.reset(); primed = false; produced = 0; consumed = 0
        windowStart = nil; pullFrames = 0; pullCount = 0; targetMilliseconds = Self.initialCushionMilliseconds
        discardedStartupWindow = false
    }
    @discardableResult private func fail(_ reason: Failure) -> Bool {
        failure = reason; head = 0; available = 0; resetMeasurement(); return false
    }
    private func add(_ value: inout UInt64, _ amount: UInt64) -> Bool {
        let next = value.addingReportingOverflow(amount)
        guard !next.overflow else { return false }; value = next.partialValue; return true
    }
}

// Memory mixing only. Session registration and Handoff/Room cleanup retain their own ownership.
final class PluginSourceMixer<Key: Hashable> {
    typealias Clock = PluginSourceClock<Key>
    enum Failure: Equatable { case invalidSamples, clock(Clock.Failure), secondary(PluginSecondaryLane.Failure) }
    struct Result {
        let state: Clock.Receipt?, samples: [Float]?, failure: Failure?
    }
    private struct Secondary { let visit: Clock.Visit, lane: PluginSecondaryLane }
    private let clock: Clock
    private var lanes: [Key: Secondary] = [:]
    var currentDriver: Clock.Visit? { clock.currentDriver }
    var sourceCount: Int { clock.count }
    var secondaryCount: Int { lanes.count }
    var isClosed: Bool { clock.isClosed }
    init(generation: UUID) { clock = Clock(generation: generation); lanes.reserveCapacity(Clock.maximumSources - 1) }
    func snapshot(_ key: Key) -> PluginSecondaryLane.Snapshot? { lanes[key]?.lane.snapshot }
    func offer(_ samples: [Float], from key: Key, generation: UUID, now: Double) -> Result {
        guard !samples.isEmpty, samples.count.isMultiple(of: PluginSecondaryLane.channels),
            samples.count <= Clock.maximumFrames * PluginSecondaryLane.channels, samples.allSatisfy(\.isFinite) else {
            return Result(state: nil, samples: nil, failure: .invalidSamples)
        }
        let state = clock.observe(key, generation: generation, frames: samples.count / 2, now: now)
        apply(state)
        guard state.role == .driver || state.role == .secondary, let visit = state.visit else {
            return Result(state: state, samples: nil, failure: state.failure.map { .clock($0) })
        }
        if state.role == .secondary {
            let secondary = lanes[key] ?? Secondary(visit: visit, lane: PluginSecondaryLane())
            lanes[key] = secondary
            guard secondary.visit == visit, secondary.lane.feed(samples, now: now) else {
                return closeAfterFailure(generation: generation, failure: secondary.lane.failure ?? .invalidResampler)
            }
            return Result(state: state, samples: nil, failure: nil)
        }
        if lanes.isEmpty { return Result(state: state, samples: samples, failure: nil) }
        var mix = samples.map(Double.init)
        for secondary in lanes.values.sorted(by: { $0.visit.order < $1.visit.order }) {
            guard let part = secondary.lane.pull(frames: samples.count / 2, now: now) else {
                return closeAfterFailure(generation: generation, failure: secondary.lane.failure ?? .invalidResampler)
            }
            for index in mix.indices { mix[index] += Double(part[index]) }
        }
        let limit = Double(Float.greatestFiniteMagnitude)
        return Result(state: state, samples: mix.map { Float(max(-limit, min(limit, $0))) }, failure: nil)
    }
    func retire(_ visit: Clock.Visit) -> Clock.Receipt { let state = clock.retire(visit); apply(state); return state }
    func stop(generation: UUID) -> Clock.Receipt { let state = clock.stop(generation: generation); apply(state); return state }
    private func apply(_ state: Clock.Receipt) {
        for old in state.retired where lanes[old.key]?.visit == old { lanes.removeValue(forKey: old.key) }
        if state.driverChanged, let next = state.driver { lanes.removeValue(forKey: next.key) }
        if state.role == .closed { lanes.removeAll(keepingCapacity: true) }
    }
    private func closeAfterFailure(generation: UUID, failure: PluginSecondaryLane.Failure) -> Result {
        let closed = clock.stop(generation: generation); apply(closed)
        return Result(state: closed, samples: nil, failure: .secondary(failure))
    }
}
