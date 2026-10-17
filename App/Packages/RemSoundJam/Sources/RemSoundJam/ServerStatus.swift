import Foundation

/// Readable server facts. The transport supplies counts and the member's own measurements, never other groups' names.
public enum ServerStatus {
    public static let olderAfter: TimeInterval = 8
    public static let logInterval: TimeInterval = 60
    public struct Member {
        public var name: String
        public var ticksUs: Bool
        public init(name: String, ticksUs: Bool) { self.name = name; self.ticksUs = ticksUs }
    }
    public struct Facts {
        public var entry: String
        public var address: JamEndpoint
        public var connectedFor: TimeInterval
        public var roundTripMs: Double?
        public var info: RelayGroupClient.ServerInfo?
        public var olderServer: Bool
        public var sending: Bool
        public var group: [Member]
        public var phonePaired: Bool
        public var sendOn: Bool
        public init(entry: String, address: JamEndpoint, connectedFor: TimeInterval, roundTripMs: Double? = nil,
                    info: RelayGroupClient.ServerInfo? = nil, olderServer: Bool, sending: Bool, group: [Member],
                    phonePaired: Bool, sendOn: Bool = true) {
            self.entry = entry; self.address = address; self.connectedFor = connectedFor; self.roundTripMs = roundTripMs
            self.info = info; self.olderServer = olderServer; self.sending = sending; self.group = group
            self.phonePaired = phonePaired; self.sendOn = sendOn
        }
    }
    public static func text(_ f: Facts) -> String {
        let entry = oneLine(f.entry)
        let location = entry.caseInsensitiveCompare(f.address.address) == .orderedSame ? entry : "\(entry) (\(f.address.address))"
        var lines = ["On \(location), connected for \(duration(f.connectedFor))."]
        if !f.olderServer {
            lines.append(f.roundTripMs.map { "Your round trip to the server: \(number($0)) ms." }
                         ?? "Your round trip to the server: measuring.")
            if !f.sendOn { lines.append("Send my audio is off, so none of your sound goes to the server.") }
            else if !f.sending { lines.append("Send my audio is on: your sound goes to the server once you tick somebody there, or unmute yourself to test round trip.") }
            else if let info = f.info {
                if info.yourPackets == 0 { lines.append("None of your sound has reached the server in the last minute.") }
                else if info.yourLongGaps == 0 {
                    lines.append("Your sound reaches the server steadily: longest gap \(number(info.yourLongestGapMs)) ms in the last minute.")
                } else {
                    lines.append("Your sound reaches the server unevenly: longest gap \(number(info.yourLongestGapMs)) ms, and \(info.yourLongGaps) \(info.yourLongGaps == 1 ? "gap" : "gaps") over 20 ms in the last minute.")
                }
            } else { lines.append("How steadily your sound reaches the server: measuring.") }
        }
        lines.append(groupLine(f.group))
        if let info = f.info {
            lines.append("On the server: \(info.people) \(info.people == 1 ? "person" : "people") in \(info.groups) \(info.groups == 1 ? "group" : "groups"), \(info.placesFree) \(info.placesFree == 1 ? "place" : "places") free.")
            lines.append("Server version \(oneLine(info.version)).")
        }
        if f.phonePaired { lines.append("A phone or older app is paired with you here.") }
        if f.olderServer { lines.append("This server doesn't report its size, version or your round trip (it's older than server-v2.16).") }
        return lines.joined(separator: "\n")
    }
    /// Figures may move without resetting a focused reader; a change in wording still reaches it.
    public static func shape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\d+", with: "#", options: .regularExpression)
    }
    public static func isOlder(info: RelayGroupClient.ServerInfo?, roundTripMs: Double?, inGroupSince: TimeInterval?,
                               now: TimeInterval, knownOlder: Bool = false) -> Bool {
        info == nil && roundTripMs == nil && (knownOlder || inGroupSince.map { now - $0 >= olderAfter } == true)
    }
    private static func number(_ n: Double) -> String { String(format: "%.0f", n) }
    private static func oneLine(_ text: String) -> String {
        let breaks = CharacterSet.controlCharacters.union(.newlines)
        return text.unicodeScalars.map { breaks.contains($0) ? " " : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func joined(_ names: [String]) -> String {
        names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
    private static func groupLine(_ members: [Member]) -> String {
        guard !members.isEmpty else { return "Nobody else from your group is on the server yet." }
        let group = members.map { Member(name: oneLine($0.name).isEmpty ? "someone not yet named" : oneLine($0.name), ticksUs: $0.ticksUs) }
        let names = joined(group.map(\.name))
        if group.count == 1 { return "In your group: \(names), who \(group[0].ticksUs ? "has ticked you" : "hasn't ticked you yet")." }
        let ticked = group.filter(\.ticksUs).map(\.name), waiting = group.filter { !$0.ticksUs }.map(\.name)
        if waiting.isEmpty { return "In your group: \(names). All of them have ticked you." }
        if ticked.isEmpty { return "In your group: \(names). None of them has ticked you yet." }
        return "In your group: \(names). \(joined(ticked)) \(ticked.count == 1 ? "has" : "have") ticked you; \(joined(waiting)) \(waiting.count == 1 ? "hasn't" : "haven't") yet."
    }
    private static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 60 else { return "less than a minute" }
        let minutes = Int(min(seconds / 60, Double(Int.max / 60)))
        func unit(_ n: Int, _ singular: String) -> String { "\(n) \(singular)\(n == 1 ? "" : "s")" }
        if minutes < 60 { return unit(minutes, "minute") }
        if minutes < 1440 { return unit(minutes / 60, "hour") + (minutes % 60 == 0 ? "" : " " + unit(minutes % 60, "minute")) }
        return unit(minutes / 1440, "day") + (minutes / 60 % 24 == 0 ? "" : " " + unit(minutes / 60 % 24, "hour"))
    }
    public struct State {
        private static let minimumRoundTripChangeMs = 2.0
        private static let roundTripChangeFraction = 0.1
        private static let minimumGapChangeMs = 3.0
        private var shownRoundTripMs: Double?
        private var shownGapMs: Double?
        private var shownLongGaps = 0
        private var lastLog: TimeInterval?
        public init() {}
        public mutating func render(_ original: Facts) -> String {
            var f = original
            if let rtt = f.roundTripMs {
                if shownRoundTripMs.map({ abs(rtt - $0) >= max(Self.minimumRoundTripChangeMs, $0 * Self.roundTripChangeFraction) }) ?? true { shownRoundTripMs = rtt }
            } else { shownRoundTripMs = nil }
            f.roundTripMs = shownRoundTripMs
            if let info = f.info {
                if shownGapMs.map({ abs(info.yourLongestGapMs - $0) >= Self.minimumGapChangeMs }) ?? true
                    || (info.yourLongGaps > 0) != (shownLongGaps > 0) {
                    shownGapMs = info.yourLongestGapMs; shownLongGaps = info.yourLongGaps
                }
                f.info = .init(version: info.version, uptime: info.uptime, people: info.people, groups: info.groups,
                               placesFree: info.placesFree, phones: info.phones, yourPackets: info.yourPackets,
                               yourLongestGapMs: shownGapMs ?? info.yourLongestGapMs, yourLongGaps: shownLongGaps,
                               yourSeconds: info.yourSeconds, receivedAt: info.receivedAt)
            }
            return ServerStatus.text(f)
        }
        public mutating func reset() { self = .init() }
        /// The caller's monotonic log clock; nil means the visit ended and resets the cadence.
        public mutating func takeLog(_ text: String?, now: TimeInterval) -> String? {
            guard let text else { lastLog = nil; return nil }
            guard lastLog.map({ now - $0 >= ServerStatus.logInterval }) ?? true else { return nil }
            lastLog = now
            return text.replacingOccurrences(of: "\n", with: " | ")
        }
    }
}
