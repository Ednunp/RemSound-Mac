import Foundation

// The Windows receive-buffer auto-tunes, ported number for number (RemSound.Core AutoTuneDescent.cs,
// ContinuousAutoTune.cs and DropoutTuner.cs; Ed 2026-08-15 to 2026-09-29). The comments that explain each rule are in
// those files; the short ones here say where each piece is. The usual auto-tune measures what the network and the output
// need (the worst arrival gaps and render periods over 15 seconds, a lone spike ignored) and raises to that at once when
// the buffer runs short; it descends on evidence of cushion never used, and then creeps down 3 ms at a time, each step
// earned by a quiet spell, never back through a depth that has already run short. The lowest-delay auto-tune instead
// counts audible gaps: it runs as thin as it can, accepting a rare dropout.

/// AutoTuneDescent: how far a clean tick may come down, and how far a short one must go up.
public enum AutoTuneDescent {
    public struct Policy: Equatable, Sendable {
        public var headroomMs = 15
        public var bigStepFraction = 0.7
        public var smallStepFraction = 0.2
        public var minStepMs = 5
        public var cleanTicksForBigStep = 3
        public var minSamplesForEvidence = 10
        public var creepStepMs = 3
        public var creepIntervalTicks = 3
        public var creepCleanTicks = 6
        public var sillyAboveNeedMs = 100
        public init() {}
    }
    public static let `default` = Policy()

    /// What a lane has learned about how thin it can run.
    public final class CreepState {
        public private(set) var discoveredFloorMs = 0
        public var ticksSinceProbe = 0
        public init() {}

        public func noteShortfallAt(_ atMs: Int, justifiedMs: Int, policy: Policy = AutoTuneDescent.default) {
            let floor = min(atMs, max(justifiedMs, 0)) + policy.creepStepMs
            if floor > discoveredFloorMs { discoveredFloorMs = floor }
        }

        public func noteCleanRun(_ cleanTicks: Int, policy: Policy = AutoTuneDescent.default) {
            guard discoveredFloorMs > 0, cleanTicks > 0, cleanTicks % max(1, policy.creepIntervalTicks) == 0 else { return }
            discoveredFloorMs = max(0, discoveredFloorMs - policy.creepStepMs)
        }

        public func restoreFloor(_ floorMs: Int) { discoveredFloorMs = max(0, floorMs); ticksSinceProbe = 0 }
        public func reset() { discoveredFloorMs = 0; ticksSinceProbe = 0 }
    }

    public static func nextRaiseTarget(currentMs: Int, recommendedMs: Int, learnedFloorMs: Int, minStepMs: Int = 0) -> Int {
        let target = max(recommendedMs, learnedFloorMs)
        if target <= currentMs { return currentMs }
        return max(target, currentMs + minStepMs)
    }

    public static func nextTarget(currentMs: Int, recommendedMs: Int, lowWaterMs: Int, sampleCount: Int,
                                  consecutiveCleanTicks: Int, policy: Policy = AutoTuneDescent.default,
                                  creep: CreepState? = nil) -> Int {
        let p = policy
        if recommendedMs >= currentMs { return currentMs }
        let floor = max(recommendedMs, creep?.discoveredFloorMs ?? 0)
        if currentMs <= floor { return currentMs }
        if currentMs - floor > p.sillyAboveNeedMs { return floor + p.headroomMs }
        let haveEvidence = lowWaterMs >= 0 && sampleCount >= p.minSamplesForEvidence
            && consecutiveCleanTicks >= p.cleanTicksForBigStep
        var goal = floor
        if haveEvidence {
            let shed = max(0, lowWaterMs - p.headroomMs)
            goal = max(floor, currentMs - shed)
        }
        let fraction = haveEvidence ? p.bigStepFraction : p.smallStepFraction
        let distance = currentMs - goal
        // C#'s Math.Round rounds halves to even; Swift's .toNearestOrEven matches it.
        let step = max(p.minStepMs, Int((Double(distance) * fraction).rounded(.toNearestOrEven)))
        let next = max(goal, max(floor, currentMs - step))
        if let creep, abs(next - currentMs) < p.minStepMs {
            if consecutiveCleanTicks >= p.creepCleanTicks {
                creep.ticksSinceProbe += 1
                if creep.ticksSinceProbe >= p.creepIntervalTicks {
                    creep.ticksSinceProbe = 0
                    return max(floor, currentMs - p.creepStepMs)
                }
            }
            return currentMs
        }
        creep?.ticksSinceProbe = 0
        return next
    }
}

/// ContinuousAutoTune.Decide: one tick of the usual auto-tune on one output.
public enum ContinuousAutoTune {
    public static let hysteresisMs = 5
    public static let recommendationCapMs = 200
    public static let lookbackSeconds = 15
    /// The usual margins (MainForm.StreamBuffers: a 2 ms render floor and 5 ms of safety).
    public static let renderPeriodFloorMs = 2
    public static let safetyMarginMs = 5

    /// The least a codec's frames can be buffered at (MainForm.CodecFloorMs).
    public static func codecFloorMs(frameMs: Int) -> Int { Int((1.5 * Double(frameMs)).rounded(.up)) }

    public enum Verdict: Equatable, Sendable { case raise, holdAfterShortfall, move, stay }

    public struct Decision: Equatable, Sendable {
        public var verdict: Verdict
        public var target: Int
        public var currentMs: Int
        public var gapPeakMs: Int
        public var gapUsedMs: Int
        public var renderCbUsedMs: Int
        public var sampleCount: Int
        public var recommendedMs: Int
        public var cappedMs: Int
        public var lowWaterMs: Int
        public var learnedFloorMs: Int
        public var cappedFloorMs: Int
    }

    public static func decide(currentMs: Int, sliderMinMs: Int, sliderMaxMs: Int, underrunDelta: Int,
                              arrivalGaps: [Int], renderCbGaps: [Int], minBuffers: [Int],
                              codecFloorMs: Int, renderPeriodFloorMs: Int = ContinuousAutoTune.renderPeriodFloorMs,
                              safetyMarginMs: Int = ContinuousAutoTune.safetyMarginMs,
                              cleanTicks: inout Int, creep: AutoTuneDescent.CreepState) -> Decision {
        let sampleCount = min(lookbackSeconds, arrivalGaps.count)
        var gapPeak = 0, gapSecond = 0
        for gap in arrivalGaps.suffix(sampleCount) {
            if gap > gapPeak { gapSecond = gapPeak; gapPeak = gap } else if gap > gapSecond { gapSecond = gap }
        }
        let observedGap = sampleCount >= 2 ? gapSecond : gapPeak

        var rcbPeak = renderPeriodFloorMs, rcbSecond = renderPeriodFloorMs
        for rcb in renderCbGaps.suffix(min(sampleCount, renderCbGaps.count)) {
            if rcb > rcbPeak { rcbSecond = rcbPeak; rcbPeak = rcb } else if rcb > rcbSecond { rcbSecond = rcb }
        }
        let observedRenderCb = sampleCount >= 2 ? rcbSecond : rcbPeak

        let jitterBased = observedGap + observedRenderCb + safetyMarginMs
        let recommended = max(codecFloorMs, jitterBased)
        let capped = min(recommended, recommendationCapMs)
        let current = currentMs
        func made(_ verdict: Verdict, _ target: Int, lowWater: Int = -1, learnedFloor: Int = 0, cappedFloor: Int = 0) -> Decision {
            .init(verdict: verdict, target: target, currentMs: current, gapPeakMs: gapPeak, gapUsedMs: observedGap,
                  renderCbUsedMs: observedRenderCb, sampleCount: sampleCount, recommendedMs: recommended, cappedMs: capped,
                  lowWaterMs: lowWater, learnedFloorMs: learnedFloor, cappedFloorMs: cappedFloor)
        }
        func clamp(_ v: Int) -> Int { min(max(v, sliderMinMs), sliderMaxMs) }

        if underrunDelta > 0 {
            cleanTicks = 0
            creep.noteShortfallAt(current, justifiedMs: capped)
            let learnedFloor = creep.discoveredFloorMs
            let cappedFloor = min(learnedFloor, recommendationCapMs)
            let raiseTarget = AutoTuneDescent.nextRaiseTarget(currentMs: current, recommendedMs: capped,
                learnedFloorMs: cappedFloor, minStepMs: hysteresisMs)
            if raiseTarget > current {
                return made(.raise, clamp(raiseTarget), learnedFloor: learnedFloor, cappedFloor: cappedFloor)
            }
            return made(.holdAfterShortfall, current, learnedFloor: learnedFloor, cappedFloor: cappedFloor)
        }
        cleanTicks += 1
        creep.noteCleanRun(cleanTicks)

        let lowWater = minBuffers.isEmpty ? -1 : (minBuffers.suffix(min(lookbackSeconds, minBuffers.count)).min() ?? -1)
        let target = capped > current ? capped
            : AutoTuneDescent.nextTarget(currentMs: current, recommendedMs: capped, lowWaterMs: lowWater,
                sampleCount: sampleCount, consecutiveCleanTicks: cleanTicks, creep: creep)
        let clamped = clamp(target)
        if abs(clamped - current) < hysteresisMs { return made(.stay, current, lowWater: lowWater, learnedFloor: creep.discoveredFloorMs) }
        if clamped > current { cleanTicks = 0 }
        return made(.move, clamped, lowWater: lowWater, learnedFloor: creep.discoveredFloorMs)
    }
}

/// DropoutTuner: the lowest-delay auto-tune, once a second, on audible gaps.
public final class DropoutTuner {
    public static let windowSeconds = 20
    public static let raiseWhenGapsInWindow = 4
    public static let raiseWhenGapsInOneSecond = 3
    public static let raiseStepMs = 2
    public static let quietSecondsToLower = 5
    public static let quietSecondsToLowerAfterRaise = 30
    public static let quietSecondsToStepBig = 2
    public static let maxRaiseStepMs = 16

    private var metGap = false
    private var window: [Int] = []
    private var gapsInWindow = 0
    private var quietSeconds = 0
    private var sinceRaise = false
    private var nextRaiseMs = DropoutTuner.raiseStepMs
    public private(set) var lastReason = ""

    public init() {}

    public func reset() {
        window.removeAll(); gapsInWindow = 0; quietSeconds = 0; sinceRaise = false; metGap = false
        nextRaiseMs = Self.raiseStepMs; lastReason = ""
    }

    public func tick(gapsThisSecond: Int, currentMs: Int, floorMs: Int, ceilingMs: Int) -> Int {
        window.append(gapsThisSecond)
        gapsInWindow += gapsThisSecond
        while window.count > Self.windowSeconds { gapsInWindow -= window.removeFirst() }
        if gapsThisSecond > 0 { metGap = true }
        if gapsThisSecond >= Self.raiseWhenGapsInOneSecond || gapsInWindow >= Self.raiseWhenGapsInWindow {
            let step = sinceRaise ? nextRaiseMs : Self.raiseStepMs
            nextRaiseMs = min(Self.maxRaiseStepMs, step * 2)
            lastReason = gapsThisSecond >= Self.raiseWhenGapsInOneSecond
                ? "\(gapsThisSecond) gaps in one second - up \(step) ms"
                : "\(gapsInWindow) gaps in \(window.count) s - up \(step) ms"
            window.removeAll(); gapsInWindow = 0; quietSeconds = 0; sinceRaise = true
            return min(ceilingMs, currentMs + step)
        }
        if gapsThisSecond > 0 {
            quietSeconds = 0
            lastReason = "a gap, still rare - holding"
            return currentMs
        }
        quietSeconds += 1
        if !metGap {
            if quietSeconds < Self.quietSecondsToStepBig || currentMs <= floorMs { return currentMs }
            let next = max(floorMs, currentMs - max(1, (currentMs - floorMs) / 2))
            lastReason = "\(quietSeconds) s without a gap, none met yet - down \(currentMs - next) ms"
            quietSeconds = 0
            return next
        }
        let needed = sinceRaise ? Self.quietSecondsToLowerAfterRaise : Self.quietSecondsToLower
        if quietSeconds >= needed && currentMs > floorMs {
            lastReason = "\(quietSeconds) s without a gap - down 1 ms"
            quietSeconds = 0; sinceRaise = false; nextRaiseMs = Self.raiseStepMs
            return currentMs - 1
        }
        return currentMs
    }
}
