import Foundation

/// RUNS OF AUDIBLE GAPS, as the Windows RemSound has had them since 6.2.3. A run of gaps is one EPISODE: it starts with
/// the first gap after a quiet spell (a capture of the seconds around it), gets a fresh capture only if a gap comes that
/// is clearly longer than any before it, says once an hour that it is still going, and ends after `quietToEnd` without
/// a gap with one summary line: how long, how many, the longest, and the stream most of them were on.
public final class GapEpisodes {
    public static let quietToEnd: TimeInterval = 60
    public static let stillGoingEvery: TimeInterval = 3_600
    /// How much longer than the longest so far a gap must be to count as the run getting worse (a fresh capture).
    public static let worseByMs = 20

    public enum Kind: Equatable { case started, worse, stillGoing, ended }
    public struct Change: Equatable {
        public let kind: Kind
        public let words: String
    }

    private var active = false
    private var started = Date.distantPast, lastGap = Date.distantPast, lastStillGoing = Date.distantPast
    private var gaps = 0
    private var longestMs = 0
    private var byStream: [String: Int] = [:]

    public init() {}
    public var isActive: Bool { active }

    /// One second: the new gaps, the longest of them in ms (0 when not known), and which stream each was on. Returns what
    /// changed, in words for the log.
    public func second(_ now: Date, newGaps: Int, longestGapMs: Int = 0, byStream streams: [String: Int] = [:]) -> [Change] {
        var changes: [Change] = []
        guard newGaps > 0 else {
            if active && now.timeIntervalSince(lastGap) >= Self.quietToEnd {
                changes.append(Change(kind: .ended, words: "gaps ended after \(Self.duration(lastGap.timeIntervalSince(started))): "
                    + "\(count(gaps))\(longest())\(mostOn())"))
                active = false
                byStream = [:]
            } else if active && now.timeIntervalSince(lastStillGoing) >= Self.stillGoingEvery {
                stillGoing(now, &changes)
            }
            return changes
        }
        for (stream, n) in streams where n > 0 { byStream[stream, default: 0] += n }
        guard active else {
            active = true
            started = now; lastStillGoing = now; lastGap = now
            gaps = newGaps
            longestMs = longestGapMs
            changes.append(Change(kind: .started, words: "gaps started: \(count(newGaps)) this second\(longest())\(mostOn())"))
            return changes
        }
        gaps += newGaps
        lastGap = now
        if longestMs > 0 && longestGapMs >= longestMs + Self.worseByMs {
            changes.append(Change(kind: .worse,
                words: "gaps got worse: a \(longestGapMs) ms gap, the longest in this run (it was \(longestMs) ms)"))
        }
        if longestGapMs > longestMs { longestMs = longestGapMs }
        if now.timeIntervalSince(lastStillGoing) >= Self.stillGoingEvery { stillGoing(now, &changes) }
        return changes
    }

    private func stillGoing(_ now: Date, _ changes: inout [Change]) {
        lastStillGoing = now
        changes.append(Change(kind: .stillGoing,
            words: "gaps still going after \(Self.duration(now.timeIntervalSince(started))): \(count(gaps)) so far\(longest())\(mostOn())"))
    }

    private func count(_ n: Int) -> String { "\(Self.grouped(n)) gap\(n == 1 ? "" : "s")" }
    private func longest() -> String { longestMs > 0 ? ", the longest \(longestMs) ms" : "" }
    private func mostOn() -> String {
        guard let top = byStream.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else { return "" }
        return byStream.count == 1 ? ", on \(top.key)" : ", most on \(top.key) (\(Self.grouped(top.value)))"
    }

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_GB")
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// A length of time in words: "12 seconds", "14 minutes", "2 hours 5 minutes".
    public static func duration(_ span: TimeInterval) -> String {
        let span = Swift.max(0, span)
        let s = Int(span.rounded())
        if s < 90 { return "\(s) second\(s == 1 ? "" : "s")" }
        let m = Int((span / 60).rounded())
        if m < 90 { return "\(m) minutes" }
        let h = Int(span / 3_600)
        let rest = Int(span.truncatingRemainder(dividingBy: 3_600) / 60)
        let hours = "\(h) hour\(h == 1 ? "" : "s")"
        return rest == 0 ? hours : "\(hours) \(rest) minute\(rest == 1 ? "" : "s")"
    }
}
