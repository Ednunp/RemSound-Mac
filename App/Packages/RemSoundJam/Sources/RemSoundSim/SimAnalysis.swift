import Foundation

/// Listens to what came out of a simulation (Windows' SimAnalysis, ported). The signal went in as LEFT = a steady 1 kHz
/// tone at half scale, RIGHT = a click every 500 ms. From the clicks: the true delay, input to output, and how it moved.
/// From the tone: every break-up (a millisecond that went quiet), every click (a jump between samples a clean 1 kHz sine
/// cannot make), pitch wobble (cents, per 100 ms) and noise (how far each 100 ms is from a perfect sine).
public enum SimAnalysis {
    public static let rate = 48_000
    public static let toneHz = 1000.0
    public static let toneLevel: Float = 0.5
    public static let clickEverySec = 0.5
    public static let clickLevel: Float = 0.9
    /// Sound in the clicks' channel is not a click when, within half a millisecond of its peak, it swings the other way
    /// by more than this share of the peak.
    static let notAClickAbove: Float = 0.55

    public struct Findings: Equatable {
        public var clicksHeard: Int
        public var delayMedianMs, delayMinMs, delayMaxMs, delayFirstMs, delayLastMs: Double
        public var glitches, quietMs, stepClicks: Int
        public var worstPitchCents, medianSnrDb, worstSnrDb: Double
        public var analysedSeconds: Double
        public var firstGlitchAt: Double?
        public var pitchP95Cents = Double.nan, pitchMedianCents = Double.nan

        /// Heard, not a single break-up or click, and the tone still a tone everywhere: its worst 100 ms at least 15 dB
        /// above the noise.
        public var clean: Bool { clicksHeard > 0 && glitches == 0 && worstSnrDb > 15 }
        /// The same by the tone alone, for sound that carries no delay clicks.
        public var cleanTone: Bool { analysedSeconds > 0 && glitches == 0 && worstSnrDb > 15 }

        public var describe: String {
            clicksHeard == 0 ? "NOTHING HEARD"
                : "delay \(Self.ms(delayMedianMs)) ms (\(Self.ms(delayMinMs))-\(Self.ms(delayMaxMs))), \(glitches) glitch(es)"
                    + " (\(quietMs) ms quiet, \(stepClicks) steps), pitch \(String(format: "%.1f", worstPitchCents)) cents at worst,"
                    + " SNR \(String(format: "%.0f", worstSnrDb)) dB at worst"
                    + (firstGlitchAt.map { ", first at \(String(format: "%.3f", $0)) s" } ?? "")
        }
        static func ms(_ v: Double) -> String { v.isNaN ? "-" : String(format: "%.1f", v) }
    }

    /// The time an output frame is heard, from the blocks' first frames and times.
    static func timeOf(_ frame: Int, _ blockTimes: [(frame: Int, time: Double)]) -> Double {
        guard !blockTimes.isEmpty else { return 0 }
        var lo = 0, hi = blockTimes.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if blockTimes[mid].frame <= frame { lo = mid } else { hi = mid - 1 }
        }
        return blockTimes[lo].time + Double(frame - blockTimes[lo].frame) / Double(rate)
    }

    /// Every delay click in the right channel: its frame, when it is heard, and how long after it was sent that is.
    public static func clicks(_ s: [Float], _ blockTimes: [(frame: Int, time: Double)], sendRate: Double)
        -> [(frame: Int, heard: Double, delayMs: Double)] {
        let frames = s.count / 2
        let clickInterval = clickEverySec * Double(rate) / sendRate
        var found: [(Int, Double, Double)] = []
        var f = 0
        while f < frames {
            defer { f += 1 }
            if abs(s[2 * f + 1]) < 0.3 { continue }
            var best = f
            for g in f..<min(frames, f + 48) where abs(s[2 * g + 1]) > abs(s[2 * best + 1]) { best = g }
            let peak = s[2 * best + 1]
            var otherWay: Float = 0
            for g in max(0, best - 24)..<min(frames, best + 24) where s[2 * g + 1] * peak < 0 {
                otherWay = max(otherWay, abs(s[2 * g + 1]))
            }
            if otherWay > notAClickAbove * abs(peak) {
                f = best + 24
                continue
            }
            let heard = timeOf(best, blockTimes)
            let sentAt = (heard / clickInterval).rounded(.down) * clickInterval
            found.append((best, heard, (heard - sentAt) * 1000))
            f = best + rate / 5
        }
        return found
    }

    public static func analyse(_ s: [Float], _ blockTimes: [(frame: Int, time: Double)], sendRate: Double,
                               expectedToneRatio: Double = 1, countFromFrame: Int = 0, countToFrame: Int = .max) -> Findings {
        let frames = s.count / 2
        let found = clicks(s, blockTimes, sendRate: sendRate)
        let firstClickFrame = found.first?.frame ?? -1
        var delays = found.filter { $0.frame >= countFromFrame && $0.frame < countToFrame }.map(\.delayMs)

        var toneBegins = -1
        if countFromFrame <= 0 && firstClickFrame < 0 {
            for f in 0..<frames where abs(s[2 * f]) > 0.5 * toneLevel {
                toneBegins = f
                break
            }
        }
        let start = countFromFrame > 0 ? countFromFrame : firstClickFrame >= 0 ? firstClickFrame + rate / 5
            : toneBegins >= 0 ? toneBegins + rate / 5 : frames
        let end = min(frames - rate / 10, countToFrame)
        let maxStep = 2.5 * Double(toneLevel) * 2 * Double.pi * toneHz * expectedToneRatio / Double(rate)
        let expectedRms = Double(toneLevel) / 2.0.squareRoot()
        var events: [Int] = []
        var quietMs = 0, stepClicks = 0
        var b = start
        while b + 48 <= end {
            var sum = 0.0
            for i in b..<(b + 48) { sum += Double(s[2 * i] * s[2 * i]) }
            if (sum / 48).squareRoot() < 0.1 * expectedRms {
                quietMs += 1
                events.append(b)
            }
            b += 48
        }
        if end > max(start, 1) {
            for i in max(start, 1)..<end where Double(abs(s[2 * i] - s[2 * i - 2])) > maxStep {
                stepClicks += 1
                events.append(i)
            }
            var nearZero = 0
            for i in start..<end {
                if abs(s[2 * i]) < 0.01 {
                    nearZero += 1
                    if nearZero == rate / 4000 { events.append(i - nearZero + 1) }
                } else {
                    nearZero = 0
                }
            }
        }
        events.sort()
        var glitches = 0, lastEvent = -rate
        for e in events {
            if e - lastEvent > rate / 100 { glitches += 1 }
            lastEvent = e
        }

        // Pitch and noise, 100 ms at a time, over windows with no glitch in them.
        let window = rate / 10
        var pitches: [Double] = [], snrs: [Double] = []
        let f0 = toneHz * expectedToneRatio
        var w = start
        var e0 = 0
        while w + window <= end {
            while e0 < events.count && events[e0] < w { e0 += 1 }
            let hasGlitch = e0 < events.count && events[e0] < w + window
            var first = -1.0, last = -1.0, crossings = 0
            for i in (w + 1)..<(w + window) {
                let a = s[2 * i - 2], c = s[2 * i]
                if a < 0 && c >= 0 {
                    let at = Double(i - 1) + Double(a / (a - c))
                    if first < 0 { first = at }
                    last = at
                    crossings += 1
                }
            }
            if crossings >= 3 && !hasGlitch {
                let hz = Double(crossings - 1) / ((last - first) / Double(rate))
                pitches.append(1200 * log2(hz / f0))
            }
            let fit = crossings >= 3 ? Double(crossings - 1) / ((last - first) / Double(rate)) : f0
            var ss = 0.0, cc = 0.0, sc = 0.0, xs = 0.0, xc = 0.0, x2 = 0.0
            for i in 0..<window {
                let ph = 2 * Double.pi * fit * Double(i) / Double(rate)
                let s1 = sin(ph), c1 = cos(ph), x = Double(s[2 * (w + i)])
                ss += s1 * s1; cc += c1 * c1; sc += s1 * c1; xs += x * s1; xc += x * c1; x2 += x * x
            }
            let det = ss * cc - sc * sc
            if det > 0 && x2 > 0 {
                let a1 = (xs * cc - xc * sc) / det, b1 = (xc * ss - xs * sc) / det
                let fitted = a1 * xs + b1 * xc
                let residual = max(x2 - fitted, 1e-12)
                snrs.append(10 * log10(max(fitted, 1e-12) / residual))
            }
            w += window
        }

        let firstDelay = delays.first ?? .nan, lastDelay = delays.last ?? .nan
        delays.sort()
        let absPitch = pitches.map(abs).sorted()
        return Findings(
            clicksHeard: delays.count,
            delayMedianMs: delays.isEmpty ? .nan : delays[delays.count / 2],
            delayMinMs: delays.first ?? .nan, delayMaxMs: delays.last ?? .nan,
            delayFirstMs: firstDelay, delayLastMs: lastDelay,
            glitches: glitches, quietMs: quietMs, stepClicks: stepClicks,
            worstPitchCents: absPitch.last ?? .nan,
            medianSnrDb: snrs.isEmpty ? .nan : snrs.sorted()[snrs.count / 2],
            worstSnrDb: snrs.min() ?? .nan,
            analysedSeconds: max(0, Double(end - start) / Double(rate)),
            firstGlitchAt: events.first.map { timeOf($0, blockTimes) },
            pitchP95Cents: absPitch.isEmpty ? .nan : absPitch[min(absPitch.count - 1, Int(Double(absPitch.count) * 0.95))],
            pitchMedianCents: absPitch.isEmpty ? .nan : absPitch[absPitch.count / 2])
    }
}
