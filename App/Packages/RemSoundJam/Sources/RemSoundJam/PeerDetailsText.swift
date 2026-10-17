import Foundation

/// The peer details box on the Connectivity tab (Windows MainForm BuildPeerDetailsText): what is known about the
/// highlighted peer, a line each, in Windows' order and words.
public enum PeerDetailsText {
    public static let nothingHighlighted = "Select a connected peer to see its details."

    public struct Facts: Equatable, Sendable {
        public var displayName: String
        /// The name the peer announces; empty when it was added by address and has not said.
        public var machineName: String
        public var address: String
        /// Seconds since the link became healthy; nil while it is not.
        public var connectedFor: TimeInterval?
        public var healthy: Bool
        public var pingMs: Int?
        /// What arrives from them: one entry a stream, its lane ("ASIO", "WASAPI", or nil) and codec name.
        public var streams: [(lane: String?, codec: String)]
        public var receiving: Bool
        /// Whether our sound goes to them.
        public var receivingYourAudio: Bool

        public init(displayName: String, machineName: String, address: String, connectedFor: TimeInterval?, healthy: Bool,
                    pingMs: Int?, streams: [(lane: String?, codec: String)], receiving: Bool, receivingYourAudio: Bool) {
            self.displayName = displayName; self.machineName = machineName; self.address = address
            self.connectedFor = connectedFor; self.healthy = healthy; self.pingMs = pingMs; self.streams = streams
            self.receiving = receiving; self.receivingYourAudio = receivingYourAudio
        }

        public static func == (a: Facts, b: Facts) -> Bool {
            a.displayName == b.displayName && a.machineName == b.machineName && a.address == b.address
                && a.connectedFor == b.connectedFor && a.healthy == b.healthy && a.pingMs == b.pingMs
                && a.streams.map { "\($0.lane ?? "")/\($0.codec)" } == b.streams.map { "\($0.lane ?? "")/\($0.codec)" }
                && a.receiving == b.receiving && a.receivingYourAudio == b.receivingYourAudio
        }
    }

    public static func text(_ f: Facts) -> String {
        var lines: [String] = []
        let machine = f.machineName.trimmingCharacters(in: .whitespaces)
        if !f.displayName.isEmpty, f.displayName.caseInsensitiveCompare(machine) != .orderedSame, f.displayName != f.address {
            lines.append("Name: \(f.displayName)")
        }
        lines.append("Machine name: " + (machine.isEmpty || machine == f.address ? "(unknown — added by address)" : machine))
        lines.append("Address: \(f.address)")
        if let since = f.connectedFor { lines.append("Connected for: \(duration(since))") }
        if f.healthy {
            lines.append(f.pingMs.map { "Link: healthy, ping \(Int((Double($0) / 5).rounded()) * 5) ms" } ?? "Link: healthy")
        } else {
            lines.append("Link: not connected")
        }
        lines.append("Sending: " + sending(f))
        lines.append("Receiving your audio: \(f.receivingYourAudio ? "yes" : "no")")
        return lines.joined(separator: "\n")
    }

    static func sending(_ f: Facts) -> String {
        guard !f.streams.isEmpty else { return f.receiving ? "no" : "turn on Receive audio to see the details" }
        let lanes = Array(Set(f.streams.compactMap(\.lane))).sorted()
        let codecs = Array(Set(f.streams.map(\.codec))).sorted()
        let count = "\(f.streams.count) stream\(f.streams.count == 1 ? "" : "s")"
        return count + (lanes.isEmpty ? "" : " on " + lanes.joined(separator: " and ")) + " at 48000 Hz, " + codecs.joined(separator: " and ")
    }

    /// Windows' DescribeDuration: seconds under a minute, minutes under an hour, then hours and minutes.
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if s < 60 { return plural(s, "second") }
        if s < 3_600 { return plural(s / 60, "minute") }
        return plural(s / 3_600, "hour") + " " + plural((s % 3_600) / 60, "minute")
    }
}
