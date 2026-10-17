import Foundation

/// A MUSIC-LIKE SIGNAL, and the listening that goes with it (Windows' SimMusic, ported). A four-second bar on the left
/// channel (the delay clicks stay on the right): three plucked notes, a held note, a quiet note 24 dB down, and a rest.
/// The listening knows the bar, so it knows what should be coming out at every moment, and finds three kinds of fault -
/// a DIP (sound missing), ADDED SOUND (louder than the music has there: the noise of a repair, heard best in a rest), and
/// a CLICK - each placed (loud passage, quiet passage, rest; on a note's attack or not) and judged plain or slight.
public enum SimMusic {
    public struct Note { public let start, length, hz, level: Double; public let plucked: Bool }
    public static let barSeconds = 4.0
    public static let bar: [Note] = [
        Note(start: 0.10, length: 0.45, hz: 440.00, level: 0.50, plucked: true),
        Note(start: 0.60, length: 0.45, hz: 554.37, level: 0.50, plucked: true),
        Note(start: 1.10, length: 0.45, hz: 659.25, level: 0.50, plucked: true),
        Note(start: 1.60, length: 0.90, hz: 880.00, level: 0.40, plucked: false),
        Note(start: 2.60, length: 0.70, hz: 220.00, level: 0.03, plucked: false),
    ]
    static let attackSec = 0.002, releaseSec = 0.010, decaySec = 0.15
    static let rate = 48_000
    public static let fullLevel = 0.5 * ((0.8 * 0.8 + 0.2 * 0.2) / 2).squareRoot()

    /// The bar's sound at a moment of its own time (seconds; it repeats).
    public static func sample(_ t: Double) -> Float {
        let inBar = t - (t / barSeconds).rounded(.down) * barSeconds
        for n in bar {
            let x = inBar - n.start
            guard x >= 0, x < n.length else { continue }
            var envelope = min(1, x / attackSec) * min(1, (n.length - x) / releaseSec)
            if n.plucked { envelope *= exp(-x / decaySec) }
            let phase = 2 * Double.pi * n.hz * x
            return Float(n.level * envelope * (0.8 * sin(phase) + 0.2 * sin(2 * phase)))
        }
        return 0
    }

    public enum Kind: Equatable { case dip, added, click }
    public static let loudPassage = "a loud passage", quietPassage = "a quiet passage", rest = "a rest"

    public struct Fault {
        public let atSec, ms: Double
        public let kind: Kind
        public let passage: String
        public let onAttack: Bool
        public let depthDb, faultDb: Double
        public let audible: String
        public var describe: String {
            let what: String
            switch kind {
            case .dip: what = String(format: "a dip of %.0f ms, %.0f dB deep", ms, -depthDb)
            case .added: what = String(format: "%.0f ms of added sound", ms)
            case .click: what = "a click"
            }
            return String(format: "at %.3f s ", atSec) + what + " in \(passage)" + (onAttack ? ", on a note's attack" : "")
                + String(format: "; %.0f dB %@ the loudest passage: ", abs(faultDb), faultDb > 0.5 ? "above" : "below") + audible
        }
    }

    public struct Findings {
        public let clicksHeard: Int
        public let delayMedianMs: Double
        public let faults: [Fault]
        public let judgedSeconds: Double
        public var plain: Int { faults.filter { $0.audible == "plain" }.count }
        public var slight: Int { faults.filter { $0.audible == "slight" }.count }
        public var clean: Bool { clicksHeard > 0 && judgedSeconds > 0 && faults.isEmpty }
        public var describe: String {
            clicksHeard == 0 ? "NOTHING HEARD" : faults.isEmpty ? String(format: "the music whole (%.1f s judged)", judgedSeconds)
                : "\(faults.count) faults in the music - \(plain) plain to hear, \(slight) slight; first: \(faults[0].describe)"
        }
    }

    static let window = 120, hop = 48
    static let gridSec = 0.0005, levelFloor = 0.004, dipBelow = 0.6, addedAbove = 2.0, jumpAbove = 2.5, jumpFloor = 0.02
    static let toleranceSec = 0.003, unjudgedBeyondSec = 0.020, loudFromDb = -12.0

    static let reference: (level: [Double], step: [Double]) = {
        let count = Int((barSeconds / gridSec).rounded())
        var level = [Double](repeating: 0, count: count), step = [Double](repeating: 0, count: count)
        for i in 0..<count {
            var sum = 0.0, biggest = 0.0
            var before = Double(sample(Double(i) * gridSec - 1.0 / Double(rate)))
            for k in 0..<window {
                let x = Double(sample(Double(i) * gridSec + Double(k) / Double(rate)))
                sum += x * x
                biggest = max(biggest, abs(x - before))
                before = x
            }
            level[i] = (sum / Double(window)).squareRoot()
            step[i] = biggest
        }
        return (level, step)
    }()

    static func barAround(_ musicTime: Double, _ tolerance: Double) -> (least: Double, most: Double, step: Double) {
        let (level, step) = reference
        let count = level.count
        let centre = Int((musicTime / gridSec).rounded())
        let reach = Int((tolerance / gridSec).rounded(.up))
        var least = Double.greatestFiniteMagnitude, most = 0.0, jump = 0.0
        for d in -reach...reach {
            let i = ((centre + d) % count + count) % count
            least = min(least, level[i]); most = max(most, level[i]); jump = max(jump, step[i])
        }
        return (least, most, jump)
    }

    static func onAnAttack(_ musicTime: Double) -> Bool {
        let inBar = musicTime - (musicTime / barSeconds).rounded(.down) * barSeconds
        return bar.contains { inBar >= $0.start - 0.005 && inBar < $0.start + 0.030 }
    }

    public static func analyse(_ s: [Float], _ blockTimes: [(frame: Int, time: Double)], sendRate: Double, fromSecond: Double = 0) -> Findings {
        let frames = s.count / 2
        let clicks = SimAnalysis.clicks(s, blockTimes, sendRate: sendRate)
        guard !clicks.isEmpty else { return Findings(clicksHeard: 0, delayMedianMs: .nan, faults: [], judgedSeconds: 0) }
        let delays = clicks.map(\.delayMs).sorted()
        let start = max(Int(fromSecond * Double(rate)), clicks[0].frame + rate / 5)
        let end = frames - rate / 10
        var marked: [(frame: Int, kind: Kind, depthDb: Double, fault: Double, most: Double, musicTime: Double)] = []
        var judged = 0, nearest = 0
        var b = max(start, 1)
        while b + window <= end {
            defer { b += hop }
            while nearest + 1 < clicks.count && abs(clicks[nearest + 1].frame - b) <= abs(clicks[nearest].frame - b) { nearest += 1 }
            let click = clicks[nearest]
            let other = click.frame <= b ? (nearest + 1 < clicks.count ? clicks[nearest + 1] : click) : nearest > 0 ? clicks[nearest - 1] : click
            let moving = abs(other.delayMs - click.delayMs) / 1000
            if moving > unjudgedBeyondSec { continue }
            let tolerance = toleranceSec + moving
            let musicTime = (SimAnalysis.timeOf(b, blockTimes) - click.delayMs / 1000) * sendRate / Double(rate)
            let (least, most, step) = barAround(musicTime, tolerance)
            var sum = 0.0, jump = 0.0
            for i in b..<(b + window) {
                let x = Double(s[2 * i])
                sum += x * x
                jump = max(jump, abs(x - Double(s[2 * i - 2])))
            }
            let level = (sum / Double(window)).squareRoot()
            judged += 1
            if least >= levelFloor && level < dipBelow * least {
                marked.append((b, .dip, 20 * log10(max(level, 1e-5) / least), least, most, musicTime))
            } else if level > addedAbove * most + levelFloor {
                marked.append((b, .added, 0, level, most, musicTime))
            } else if jump > jumpAbove * step + jumpFloor {
                marked.append((b, .click, 0, jump * fullLevel / 0.5, most, musicTime))
            }
        }
        var faults: [Fault] = []
        var i = 0
        while i < marked.count {
            var j = i
            while j + 1 < marked.count && marked[j + 1].frame - marked[j].frame <= rate / 100 { j += 1 }
            let part = marked[i...j]
            let kind: Kind = part.contains { $0.kind == .dip } ? .dip : part.contains { $0.kind == .added } ? .added : .click
            let ofKind = part.filter { $0.kind == kind }
            let most = part.map(\.most).max()!
            let passage = most < levelFloor ? rest : 20 * log10(most / fullLevel) >= loudFromDb ? loudPassage : quietPassage
            let ms = Double(part.last!.frame - part.first!.frame) * 1000 / Double(rate) + 1
            let depthDb = kind == .dip ? ofKind.map(\.depthDb).min()! : 0
            let faultDb = 20 * log10(max(ofKind.map(\.fault).max()!, 1e-6) / fullLevel)
            faults.append(Fault(atSec: SimAnalysis.timeOf(part.first!.frame, blockTimes), ms: ms, kind: kind, passage: passage,
                                onAttack: part.contains { onAnAttack($0.musicTime) }, depthDb: depthDb, faultDb: faultDb,
                                audible: howAudible(kind, passage, faultDb, ms)))
            i = j + 1
        }
        return Findings(clicksHeard: clicks.count, delayMedianMs: delays[delays.count / 2], faults: faults,
                        judgedSeconds: Double(judged * hop) / Double(rate))
    }

    static func howAudible(_ kind: Kind, _ passage: String, _ faultDb: Double, _ ms: Double) -> String {
        switch kind {
        case .dip: return passage == loudPassage && ms >= 2 ? "plain" : "slight"
        case .added: return faultDb >= -30 ? "plain" : "slight"
        case .click: return faultDb >= -20 || (passage != loudPassage && faultDb >= -30) ? "plain" : "slight"
        }
    }
}
