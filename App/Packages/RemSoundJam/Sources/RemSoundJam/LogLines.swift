import Foundation

/// How serious a log line is: the first word of every line, so a search for WARN or ERROR finds the problems.
public enum LogLevel: Sendable, Equatable {
    case info, warn, error
    public var word: String {
        switch self {
        case .info: return "INFO"
        case .warn: return "WARN"
        case .error: return "ERROR"
        }
    }
}

/// EVERY EVENT LINE STARTS WITH A SEVERITY WORD AND A CATEGORY, as the Windows RemSound's have since 6.2.3 (its issue 35,
/// Jonathan Schuster: "WARN Peer: LAPTOP disconnected"), so a person, Spotlight or grep can pick out the problems, or
/// everything about the server. The lines written on purpose say their level and category themselves; the rest keep
/// their words and are sorted here: a short "metronome: ..." style start becomes the category, and a few plain words
/// that mean trouble make a line a warning or an error.
public enum LogLines {
    /// The start of a line that does not say its own category, and the category it belongs to.
    static let prefixes: [String: String] = [
        "relay": "Server", "server": "Server", "servers": "Server", "server status": "Server",
        "updater": "Updates", "update": "Updates", "updates": "Updates", "security": "Security",
        "accept connections": "Peers", "discovery": "Peers", "metronome": "Metronome", "hear myself": "Hear myself",
        "hear myself components": "Hear myself",
        "recording": "Recording", "push to talk": "Push to talk", "web listener": "Web listener", "plugin": "Plugin",
        "daw plugin": "Plugin", "device": "Devices", "devices": "Devices", "upnp": "Router", "router": "Router",
        "log started": "Log", "log stopped": "Log", "logs": "Log", "network": "Network", "profile": "Profile",
        "jamming": "Audio", "audio": "Audio", "capture": "Audio", "output": "Audio", "input": "Audio",
    ]
    /// The first word of a line with no such start, and its category.
    static let firstWords: [String: String] = [
        "profile": "Profile", "peer": "Peer", "server": "Server", "audio": "Audio", "user": "Log", "log": "Log",
        "metronome": "Metronome", "update": "Updates", "plugin": "Plugin", "device": "Devices", "web": "Web listener",
        "push": "Push to talk", "hear": "Hear myself", "recording": "Recording",
    ]

    // Plain words, so a line is not called an error for mentioning one.
    private static let errorWords = try! NSRegularExpression(
        pattern: #"\b[A-Za-z]+Exception\b|\b(crash|crashed|fatal)\b|\bFAILED\b|\bthrew\b"#, options: [.caseInsensitive])
    private static let warnWords = try! NSRegularExpression(
        pattern: #"\b(failed|failure|could not|couldn't|cannot|can't|refused|refuses|timed out|unreachable|stalled|mismatch|"#
            + #"wrong password|out of date|too old|gave up|giving up|unavailable|disconnected|went quiet|overrun)\b"#,
        options: [.caseInsensitive])
    // "metronome: ...", "accept connections: ...", "push to talk: ..." - up to three short words before a colon and a space.
    private static let prefixed = try! NSRegularExpression(
        pattern: #"^([A-Za-z][A-Za-z'\-]*(?: [A-Za-z][A-Za-z'\-]*){0,2}): (.*)$"#, options: [.dotMatchesLineSeparators])

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// A line that does not say its own level and category: its level from its words, its category from how it starts.
    /// A start the tables do not know becomes the category as it is ("Gate copy"), so its words still read the same.
    public static func classify(_ message: String) -> (level: LogLevel, category: String, text: String) {
        let level: LogLevel = matches(errorWords, message) ? .error : matches(warnWords, message) ? .warn : .info
        let whole = NSRange(message.startIndex..., in: message)
        if let m = prefixed.firstMatch(in: message, range: whole),
           let p = Range(m.range(at: 1), in: message), let rest = Range(m.range(at: 2), in: message) {
            let prefix = String(message[p])
            let category = prefixes[prefix.lowercased()] ?? (prefix.prefix(1).uppercased() + prefix.dropFirst())
            return (level, category, String(message[rest]))
        }
        let first = message.split(separator: " ", maxSplits: 1).first.map {
            String($0).trimmingCharacters(in: CharacterSet(charactersIn: ":,"))
        } ?? ""
        return (level, firstWords[first.lowercased()] ?? "App", message)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// The line as written: the severity word, the time, then "Category: text". Tabs between, so a spreadsheet splits
    /// it; nothing in the text can start another line.
    public static func format(_ level: LogLevel, _ time: Date, _ category: String, _ text: String) -> String {
        "\(level.word)\t\(clock.string(from: time))\t\(category): \(clean(text))"
    }

    public static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
