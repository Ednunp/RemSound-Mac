import Foundation

public struct UpdateInstallItem {
    public let source: URL
    public let target: URL

    public init(source: URL, target: URL) {
        self.source = source
        self.target = target
    }
}

public enum UpdateTransactionError: LocalizedError {
    case rollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .rollbackFailed(let detail):
            "The update failed and the previous installation could not be fully restored: \(detail)"
        }
    }
}

public enum UpdateTransaction {
    public static func install(_ items: [UpdateInstallItem],
        copy: (URL, URL) throws -> Void,
        verify: (URL) throws -> Void) throws {
        let manager = FileManager.default
        let suffix = UUID().uuidString
        let staged = items.map { item in
            (item: item, candidate: URL(fileURLWithPath:
                item.target.deletingPathExtension().path + ".new-\(suffix).\(item.target.pathExtension)"),
                backup: URL(fileURLWithPath:
                    item.target.deletingPathExtension().path + ".old-\(suffix).\(item.target.pathExtension)"))
        }
        var installed = [Int]()
        var backedUp = [Int]()
        do {
            for entry in staged {
                try manager.createDirectory(at: entry.item.target.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try copy(entry.item.source, entry.candidate)
                try verify(entry.candidate)
            }
            for (index, entry) in staged.enumerated() {
                if manager.fileExists(atPath: entry.item.target.path) {
                    try manager.moveItem(at: entry.item.target, to: entry.backup)
                    backedUp.append(index)
                }
                try manager.moveItem(at: entry.candidate, to: entry.item.target)
                installed.append(index)
            }
            for entry in staged { try verify(entry.item.target) }
        } catch {
            var rollbackFailures = [String]()
            for index in installed.reversed() {
                let target = staged[index].item.target
                do { try manager.removeItem(at: target) }
                catch { rollbackFailures.append("remove \(target.lastPathComponent): \(error)") }
            }
            for index in backedUp.reversed() {
                let entry = staged[index]
                do { try manager.moveItem(at: entry.backup, to: entry.item.target) }
                catch { rollbackFailures.append("restore \(entry.item.target.lastPathComponent): \(error)") }
            }
            for entry in staged where manager.fileExists(atPath: entry.candidate.path) {
                try? manager.removeItem(at: entry.candidate)
            }
            if !rollbackFailures.isEmpty {
                throw UpdateTransactionError.rollbackFailed(rollbackFailures.joined(separator: "; "))
            }
            throw error
        }
        for entry in staged where manager.fileExists(atPath: entry.backup.path) {
            try? manager.removeItem(at: entry.backup)
        }
    }
    /// Internal companion for the fixed plugin command. Keep originals until the caller's final check.
    static func removeFiles(_ targets: [URL], beforeMove: (URL) throws -> Void,
        beforeCommit: () throws -> Void) throws {
        let manager = FileManager.default, suffix = UUID().uuidString
        var moved = [(target: URL, backup: URL)]()
        do {
            for target in targets {
                try beforeMove(target)
                let backup = target.deletingLastPathComponent().appendingPathComponent(".plugin-remove-" + suffix + "-" + String(moved.count))
                try manager.moveItem(at: target, to: backup)
                moved.append((target, backup))
            }
            try beforeCommit()
        } catch {
            var failed = false
            for entry in moved.reversed() {
                do { try manager.moveItem(at: entry.backup, to: entry.target) } catch { failed = true }
            }
            if failed { throw UpdateTransactionError.rollbackFailed("Plugin removal originals could not all be restored.") }
            throw error
        }
        for entry in moved {
            do { try manager.removeItem(at: entry.backup) }
            catch { throw UpdateTransactionError.rollbackFailed("Plugin removal completed but original-backup cleanup is incomplete.") }
        }
    }

}
