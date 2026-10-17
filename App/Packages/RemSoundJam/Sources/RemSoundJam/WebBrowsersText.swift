import Foundation

/// Each browser listening, in words, for the Web listener window and the log (Windows WebListener.DescribeBrowsers and
/// FromBrowser, Ed 2026-10-12): the page's own figures, the round trip now and at worst in the last minute, what this end
/// dropped, and how often it has had to reconnect. Only numbers from a page are used, so nothing it says reaches the log
/// as it was written.
public enum WebBrowsersText {
    public struct Stream: Equatable, Sendable {
        public var id, depthMs, targetMs, longestWaitMs, gaps, skips: Int
        public init(id: Int, depthMs: Int, targetMs: Int, longestWaitMs: Int, gaps: Int, skips: Int) {
            self.id = id; self.depthMs = depthMs; self.targetMs = targetMs; self.longestWaitMs = longestWaitMs
            self.gaps = gaps; self.skips = skips
        }
    }

    /// A page's report in words.
    public static func report(streams: [Stream], outMs: Int, rate: Int) -> String {
        let parts = streams.prefix(4).map { s in
            "stream \(s.id): buffer \(s.depthMs) ms (aiming for \(s.targetMs)), longest wait \(s.longestWaitMs) ms, "
                + "gaps \(s.gaps), catch-ups \(s.skips)"
        }
        return (parts.isEmpty ? "no sound playing" : parts.joined(separator: "; "))
            + (outMs > 0 ? "; its sound card adds about \(outMs) ms" : "") + (rate > 0 ? " at \(rate) Hz" : "")
    }

    /// One browser; nil before it has said anything.
    public static func describe(pcm: Bool, report: String?, roundTrips: [Int], dropped: Int, reconnects: Int) -> String? {
        guard report != nil || !roundTrips.isEmpty else { return nil }
        let trip = roundTrips.last.map { "round trip \($0) ms, worst \(roundTrips.max() ?? $0) ms in the last minute" }
            ?? "round trip not yet known"
        return "\(pcm ? "16-bit PCM" : "Opus"), \(report ?? "no report yet"); \(trip); dropped here \(dropped)"
            + "; reconnected \(reconnects) \(reconnects == 1 ? "time" : "times")"
    }

    public static func line(number: Int, description: String?) -> String { "Browser \(number): \(description ?? "just joined")." }

    /// The window's status for the list: who is listening, or nobody.
    public static func status(_ lines: [String]) -> String {
        lines.isEmpty ? "No browser is listening." : lines.joined(separator: "\n")
    }

    /// What must change before a browser's line is logged again (inside a minute): its counts, not its moving figures.
    public static func logKey(_ line: String) -> String {
        var key = line
        for pattern in [#"buffer \d+ ms"#, #"round trip \d+ ms, worst \d+ ms"#, #"sound card adds about \d+ ms"#,
                        #"aiming for \d+"#, #"longest wait \d+ ms"#] {
            key = key.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return key
    }
}
