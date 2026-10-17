import Foundation

/// How often RemSound looks for a newer release in the background (Windows UpdateCheckFrequency; the stored numbers are
/// Windows' too). The check when RemSound opens is a separate choice.
public enum UpdateCheckFrequency: Int, CaseIterable, Sendable {
    case never = 0, everyHour = 1, every6Hours = 2, every24Hours = 3

    public static let `default` = UpdateCheckFrequency.every24Hours
    public static let settingsKey = "RemSoundUpdateCheckFrequency"

    public var title: String {
        switch self {
        case .never: return "Never"
        case .everyHour: return "Every hour"
        case .every6Hours: return "Every 6 hours"
        case .every24Hours: return "Every 24 hours"
        }
    }
    /// Seconds between background checks; nil for never.
    public var interval: TimeInterval? {
        switch self {
        case .never: return nil
        case .everyHour: return 3_600
        case .every6Hours: return 6 * 3_600
        case .every24Hours: return 24 * 3_600
        }
    }
}

/// The daily time range automatic installs keep to (Windows UpdateWindow), so an update never cuts someone's sound while
/// they are using the Mac: it lands overnight instead. A check you ask for yourself is never held back. Start inclusive,
/// end exclusive, wrapping past midnight; the same start and end mean no restriction, because a range that blocks every
/// update for ever is a support trap.
public enum UpdateWindow {
    public static let slotMinutes = 15
    public static let slotsPerDay = 24 * 60 / slotMinutes
    public static let defaultStart = 60     // 01:00
    public static let defaultEnd = 360      // 06:00
    public static let enabledKey = "RemSoundUpdateWindowEnabled"
    public static let startKey = "RemSoundUpdateWindowStart"
    public static let endKey = "RemSoundUpdateWindowEnd"

    /// "HH:mm" for a minutes-of-day value (the Preferences list text).
    public static func format(_ minutesOfDay: Int) -> String {
        String(format: "%02d:%02d", minutesOfDay / 60, minutesOfDay % 60)
    }

    public static func isWithin(minutesOfDay m: Int, start: Int, end: Int) -> Bool {
        if start == end { return true }
        return start < end ? (m >= start && m < end) : (m >= start || m < end)
    }

    /// Seconds from this time of day until the range next opens: a check found outside it is tried again then.
    public static func untilNextStart(secondsOfDay: TimeInterval, start: Int) -> TimeInterval {
        var seconds = TimeInterval(start * 60) - secondsOfDay
        if seconds <= 0 { seconds += 24 * 3_600 }
        return seconds
    }
}

/// Release notes made short enough for a question (Windows TruncateForDialog): the whole notes are on the release page.
public enum ReleaseNotesText {
    public static let maximum = 600

    public static func forDialog(_ notes: String) -> String {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximum else { return trimmed }
        return String(trimmed.prefix(maximum)) + "\n…"
    }

    /// The question before an install, with the notes when there are any.
    public static func question(version: String, notes: String) -> String {
        let short = forDialog(notes)
        return short.isEmpty ? "RemSound Mac \(version) is available. Install now?"
            : "RemSound Mac \(version) is available.\n\n\(short)\n\nInstall now?"
    }
}
