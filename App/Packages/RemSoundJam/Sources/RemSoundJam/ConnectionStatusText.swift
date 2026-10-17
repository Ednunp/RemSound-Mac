import Foundation

/// The Connection status box (Windows MainForm's status readout): who you are connected to and how, how long, the
/// traffic, and what RemSound itself is using, a line each, in Windows' order and words. The "speak status" key reads it.
public enum ConnectionStatusText {
    public struct Facts: Equatable, Sendable {
        /// Each connected peer: its name and its link ("ping 20 ms, total latency about 45 ms").
        public var connected: [(name: String, link: String)]
        /// Ticked peers on another password.
        public var differentPassword: [String]
        /// Seconds since a peer was first connected without a break; nil while none is.
        public var uptime: TimeInterval?
        /// Push to talk's and the metronome's lines, when in use.
        public var extras: [String]
        public var receivingKBs: Double
        public var sendingKBs: Double
        public var receivedBytes: Int64
        public var sentBytes: Int64
        public var cpuPercent: Double
        public var memoryBytes: Int64

        public init(connected: [(name: String, link: String)], differentPassword: [String], uptime: TimeInterval?,
                    extras: [String], receivingKBs: Double, sendingKBs: Double, receivedBytes: Int64, sentBytes: Int64,
                    cpuPercent: Double, memoryBytes: Int64) {
            self.connected = connected; self.differentPassword = differentPassword; self.uptime = uptime
            self.extras = extras; self.receivingKBs = receivingKBs; self.sendingKBs = sendingKBs
            self.receivedBytes = receivedBytes; self.sentBytes = sentBytes; self.cpuPercent = cpuPercent
            self.memoryBytes = memoryBytes
        }
        public static func == (a: Facts, b: Facts) -> Bool { text(a) == text(b) }
    }

    public static func text(_ f: Facts) -> String {
        var lines: [String] = []
        if f.connected.isEmpty {
            lines.append("Not connected to any peer.")
        } else {
            lines.append("Connected to \(f.connected.count) peer\(f.connected.count == 1 ? "" : "s").")
            for peer in f.connected { lines.append("  \(peer.name): \(peer.link)") }
        }
        for name in f.differentPassword { lines.append("  \(name): a different password, not connected") }
        lines.append("Uptime: \(f.uptime.map(uptime) ?? "0 seconds").")
        for extra in f.extras { lines.append(extra.hasSuffix(".") ? extra : extra + ".") }
        lines.append(String(format: "Receiving %.1f kB/s; sending %.1f kB/s.", f.receivingKBs, f.sendingKBs))
        lines.append("Total received \(dataSize(f.receivedBytes)); sent \(dataSize(f.sentBytes)).")
        lines.append("CPU usage \(Int(max(0, f.cpuPercent).rounded()))% and memory \(dataSize(f.memoryBytes)).")
        return lines.joined(separator: "\n")
    }

    /// Windows' FormatDataSize: megabytes to one place, gigabytes from a gigabyte (binary units).
    public static func dataSize(_ bytes: Int64) -> String {
        let mb = 1_048_576.0, gb = 1_073_741_824.0
        return Double(bytes) >= gb ? String(format: "%.1f GB", Double(bytes) / gb) : String(format: "%.1f MB", Double(bytes) / mb)
    }

    /// Windows' FormatUptime.
    public static func uptime(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if s < 1 { return "0 seconds" }
        if s < 60 { return plural(s, "second") }
        if s < 3_600 { return plural(s / 60, "minute") + " " + plural(s % 60, "second") }
        return plural(s / 3_600, "hour") + " " + plural((s % 3_600) / 60, "minute")
    }

    /// The process's share of the whole machine, as Activity Monitor's figure divided by the cores (Windows' rule).
    public static func cpuPercent(cpuSecondsDelta: Double, elapsed: Double, cores: Int) -> Double {
        guard elapsed > 0 else { return 0 }
        return max(0, cpuSecondsDelta / elapsed / Double(max(1, cores)) * 100)
    }
}
