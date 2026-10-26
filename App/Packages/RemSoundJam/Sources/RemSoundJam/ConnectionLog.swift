import Foundation

/// PEERS CONNECTING AND DROPPING, as the Windows log has said them since 6.2.3 (its issue 35). A disconnect says who and
/// why - stopped answering for how long, and whether this Mac's network had just changed or it had just woken - and
/// keeps the five minutes before it in the readings file; a reconnect says how long it was gone; and every connection
/// ends with one summary line. Plain logic, fed once a second; the session writes what it returns.
public final class ConnectionLog {
    public static let disconnectLookBack: TimeInterval = 300
    /// A network change or a wake this recent is named in a disconnect's reason.
    public static let contextWindow: TimeInterval = 60
    /// No sound for this long is said too.
    public static let silentAfter: TimeInterval = 3

    public enum State: Equatable, Sendable { case pending, healthy, stale, unreachable }

    /// One ticked (or just unticked) peer this second.
    public struct Seen {
        public var key: String
        public var name: String
        public var selected: Bool
        public var state: State
        public var pingMs: Double?
        /// How long since its last answer to a ping.
        public var silentMs: UInt64?
        /// Its audio this second: packets, audible gaps on its streams, sound filled in, and its buffer at its lowest.
        public var packets: Int
        public var gaps: Int
        public var filledIn: Int
        public var lowestBufferMs: Double?
        public init(key: String, name: String, selected: Bool, state: State, pingMs: Double? = nil, silentMs: UInt64? = nil,
                    packets: Int = 0, gaps: Int = 0, filledIn: Int = 0, lowestBufferMs: Double? = nil) {
            self.key = key; self.name = name; self.selected = selected; self.state = state; self.pingMs = pingMs
            self.silentMs = silentMs; self.packets = packets; self.gaps = gaps; self.filledIn = filledIn
            self.lowestBufferMs = lowestBufferMs
        }
    }

    /// A line for the log: its level, its words (category Peer), and how far back to keep every second for it.
    public struct Line: Equatable {
        public let level: LogLevel
        public let text: String
        public let captureLookBack: TimeInterval?
    }

    private struct Tally {
        var name: String
        let since: Date
        var gaps = 0, packets = 0, filledIn = 0
        var lowestBufferMs: Double?
        var pingSum = 0.0, pingCount = 0, pingWorst = 0.0
    }

    private var connected: [String: Tally] = [:]
    private var lostAt: [String: Date] = [:]
    private var lastSound: [String: Date] = [:]
    private var networkChangedAt: Date?
    private var wokeAt: Date?

    public init() {}

    public func networkChanged(_ at: Date) { networkChangedAt = at }
    public func woke(_ at: Date) { wokeAt = at }
    public var connectedCount: Int { connected.count }

    public func second(_ now: Date, _ peers: [Seen]) -> [Line] {
        var lines: [Line] = []
        let seenKeys = Set(peers.map(\.key))
        for p in peers {
            if p.packets > 0 { lastSound[p.key] = now }
            if var tally = connected[p.key] {
                tally.name = p.name
                if !p.selected {
                    connected[p.key] = nil
                    lines.append(Line(level: .info, text: "\(p.name) disconnected: you unticked it", captureLookBack: nil))
                    lines.append(summary(tally, "you unticked it", now))
                } else if p.state == .unreachable {
                    connected[p.key] = nil
                    lostAt[p.key] = now
                    lines.append(Line(level: .warn, text: "\(p.name) disconnected: \(whyLost(p, now))",
                                      captureLookBack: Self.disconnectLookBack))
                    lines.append(summary(tally, "disconnected", now))
                } else {
                    tally.gaps += p.gaps; tally.packets += p.packets; tally.filledIn += p.filledIn
                    if let low = p.lowestBufferMs { tally.lowestBufferMs = min(tally.lowestBufferMs ?? low, low) }
                    if p.state == .healthy, let ping = p.pingMs {
                        tally.pingSum += ping; tally.pingCount += 1; tally.pingWorst = max(tally.pingWorst, ping)
                    }
                    connected[p.key] = tally
                }
            } else if p.selected && p.state == .healthy {
                let back = lostAt.removeValue(forKey: p.key).map { ", back after \(GapEpisodes.duration(now.timeIntervalSince($0)))" } ?? ""
                connected[p.key] = Tally(name: p.name, since: now)
                lines.append(Line(level: .info, text: "\(p.name) connected\(back)", captureLookBack: nil))
            }
        }
        // A peer gone from the list altogether while connected (removed, or a server member that left).
        for (key, tally) in connected where !seenKeys.contains(key) {
            connected[key] = nil
            lostAt[key] = now
            lines.append(Line(level: .warn, text: "\(tally.name) disconnected: it is no longer listed\(context(now))",
                              captureLookBack: Self.disconnectLookBack))
            lines.append(summary(tally, "no longer listed", now))
        }
        return lines
    }

    /// RemSound stopping: every connection still open ends, each with its summary.
    public func endAll(_ how: String, _ now: Date) -> [Line] {
        let lines = connected.values.sorted { $0.name < $1.name }.map { summary($0, how, now) }
        connected = [:]
        return lines
    }

    func whyLost(_ p: Seen, _ now: Date) -> String {
        var why = "it stopped answering"
        if let ms = p.silentMs { why += " - no reply to its pings for \(GapEpisodes.duration(Double(ms) / 1000))" }
        if let sound = lastSound[p.key], now.timeIntervalSince(sound) >= Self.silentAfter {
            why += ", and no sound for \(GapEpisodes.duration(now.timeIntervalSince(sound)))"
        }
        return why + context(now)
    }

    private func context(_ now: Date) -> String {
        var words = ""
        if let at = networkChangedAt, now.timeIntervalSince(at) <= Self.contextWindow {
            words += "; this Mac's network changed \(GapEpisodes.duration(now.timeIntervalSince(at))) before"
        }
        if let at = wokeAt, now.timeIntervalSince(at) <= Self.contextWindow {
            words += "; this Mac woke from sleep \(GapEpisodes.duration(now.timeIntervalSince(at))) before"
        }
        return words
    }

    private func summary(_ t: Tally, _ how: String, _ now: Date) -> Line {
        var parts = ["\(GapEpisodes.grouped(t.gaps)) audible gap\(t.gaps == 1 ? "" : "s")",
                     "\(GapEpisodes.grouped(t.packets)) packets",
                     "\(GapEpisodes.grouped(t.filledIn)) filled in"]
        if let low = t.lowestBufferMs { parts.append("buffer at its lowest \(Int(low.rounded())) ms") }
        parts.append(t.pingCount > 0
            ? "ping \(Int((t.pingSum / Double(t.pingCount)).rounded())) ms on average and \(Int(t.pingWorst.rounded())) ms at worst"
            : "ping not measured")
        return Line(level: .info, text: "\(t.name): connection ended (\(how)) after \(GapEpisodes.duration(now.timeIntervalSince(t.since))): "
            + parts.joined(separator: ", "), captureLookBack: nil)
    }
}
