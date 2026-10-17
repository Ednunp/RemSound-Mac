import Foundation

/// Looking after the logs folder (Windows Preferences, Logs): a warning at start when it has grown past a size, deleting
/// logs older than a number of days at start, and deleting them all. Kept apart from the disk so it can be tested; the
/// app lists the folder and deletes what this says.
public enum LogFolderCare {
    public struct File: Equatable, Sendable {
        public var name: String
        public var modified: Date
        public var bytes: Int64
        public init(name: String, modified: Date, bytes: Int64) {
            self.name = name; self.modified = modified; self.bytes = bytes
        }
    }

    public static let warnKey = "RemSoundWarnIfLogsFolderExceeds"
    public static let warnMegabytesKey = "RemSoundLogsFolderWarnMegabytes"
    public static let pruneKey = "RemSoundPruneOldLogs"
    public static let pruneDaysKey = "RemSoundPruneOldLogsDays"
    public static let defaultWarnMegabytes = 100
    public static let defaultPruneDays = 14
    public static let warnChoices = [50, 100, 250, 500, 1_000]
    public static let pruneDayRange = 1...30
    /// The logs RemSound itself writes to while it runs: never deleted from under it.
    public static let inUse: Set<String> = ["Latest.log", "Startup.log", "Responsiveness.log", "Update.log"]
    /// Anything written to in the last ten minutes is taken to be in use too (the detailed log of a running session).
    public static let recentlyWritten: TimeInterval = 600

    public static func totalBytes(_ files: [File]) -> Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// The warning, when the folder is bigger than the limit; nil when it is not.
    public static func warning(_ files: [File], megabytes: Int) -> String? {
        let total = totalBytes(files)
        guard total > Int64(megabytes) * 1_048_576 else { return nil }
        let size = Double(total) / 1_048_576
        return "The logs folder is \(Int(size.rounded())) megabytes, more than the \(megabytes) you set. "
            + "You can delete old logs in Preferences, General."
    }

    private static func deletable(_ file: File, now: Date) -> Bool {
        !inUse.contains(file.name) && now.timeIntervalSince(file.modified) >= recentlyWritten
    }

    /// The logs older than `days` days.
    public static func older(_ files: [File], thanDays days: Int, now: Date) -> [File] {
        let limit = TimeInterval(min(max(days, pruneDayRange.lowerBound), pruneDayRange.upperBound)) * 86_400
        return files.filter { deletable($0, now: now) && now.timeIntervalSince($0.modified) > limit }
    }

    /// Every log but those in use.
    public static func all(_ files: [File], now: Date) -> [File] { files.filter { deletable($0, now: now) } }
}
