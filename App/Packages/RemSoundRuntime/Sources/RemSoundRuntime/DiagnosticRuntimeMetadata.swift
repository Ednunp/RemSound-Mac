import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct DiagnosticRuntimeMetadata: Equatable, Sendable {
    public enum Settings: String, Sendable { case notInspected, missing, present, unsafe, unavailable }
    public let settings: Settings
    public let settingsBytes: Int64?
    public let logFiles: Int
    public let logBytes: Int64?
    public let logsComplete: Bool
    public init(settings: Settings, settingsBytes: Int64?, logFiles: Int, logBytes: Int64?, logsComplete: Bool) {
        self.settings = settings; self.settingsBytes = settingsBytes; self.logFiles = logFiles
        self.logBytes = logBytes; self.logsComplete = logsComplete
    }
    /// Metadata only. Does not read settings values, log lines, credentials or construct a runtime.
    public static func collect(root: URL?) throws -> DiagnosticRuntimeMetadata {
        try collect(root: root, normalLogs: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RemSound"))
    }
    static func collect(root: URL?, normalLogs: URL, afterLogScan: (() -> Void)? = nil) throws -> DiagnosticRuntimeMetadata {
        #if canImport(Darwin)
        var status: Settings = .notInspected, size: Int64?
        if let root {
            guard let descriptor = try DiagnosticFileScope.directory(root, privateRoot: true) else {
                return .init(settings: .missing, settingsBytes: nil, logFiles: 0, logBytes: 0, logsComplete: true)
            }
            defer { Darwin.close(descriptor) }
            var info = stat()
            if fstatat(descriptor, "settings.plist", &info, AT_SYMLINK_NOFOLLOW) == 0 {
                if DiagnosticFileScope.regular(info), info.st_uid == getuid(), info.st_mode & 0o077 == 0 {
                    status = .present; size = info.st_size >= 0 ? info.st_size : nil
                } else { status = .unsafe }
            } else { status = errno == ENOENT ? .missing : .unavailable }
        }
        let logs = root?.appendingPathComponent("Logs", isDirectory: true) ?? normalLogs
        guard let descriptor = try DiagnosticFileScope.directory(logs, privateRoot: root != nil) else {
            return .init(settings: status, settingsBytes: size, logFiles: 0, logBytes: 0, logsComplete: true)
        }
        defer { Darwin.close(descriptor) }
        var before = stat(); guard fstat(descriptor, &before) == 0 else { throw DiagnosticReportError.invalidScope }
        var complete = true, entries = 0, count = 0, total: Int64 = 0
        var observed: [(String, stat)] = []
        guard let iterator = FileManager.default.enumerator(at: logs, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants], errorHandler: { _, _ in complete = false; return false }) else {
            throw DiagnosticReportError.invalidScope
        }
        for case let entry as URL in iterator {
            guard entries < DiagnosticFileScope.maximumEntries else { complete = false; break }; entries += 1
            guard entry.pathExtension.lowercased() == "log" else { continue }
            guard count < DiagnosticFileScope.maximumLogs else { complete = false; break }
            var info = stat()
            guard entry.lastPathComponent.withCString({ fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0,
                DiagnosticFileScope.regular(info), info.st_size >= 0 else { complete = false; continue }
            let sum = total.addingReportingOverflow(info.st_size)
            guard !sum.overflow else { complete = false; break }
            count += 1; total = sum.partialValue
            observed.append((entry.lastPathComponent, info))
        }
        afterLogScan?()
        count = 0; total = 0
        for (name, original) in observed {
            var current = stat()
            guard name.withCString({ fstatat(descriptor, $0, &current, AT_SYMLINK_NOFOLLOW) }) == 0,
                DiagnosticFileScope.sameFile(original, current) else { complete = false; continue }
            count += 1; total += current.st_size
        }
        if !DiagnosticFileScope.sameDirectory(before, at: logs) { complete = false }
        return .init(settings: status, settingsBytes: size, logFiles: count, logBytes: total, logsComplete: complete)
        #else
        throw DiagnosticReportError.unsupported
        #endif
    }
}

public enum DiagnosticReportError: Error, LocalizedError {
    case invalidScope, invalidDestination, tooLarge, unsupported
    public var errorDescription: String? {
        switch self {
        case .invalidScope: return "The diagnostic configuration folder is unsafe or unavailable. No normal settings were read."
        case .invalidDestination: return "The report destination is unsafe, already exists or could not be written. No prior file was replaced."
        case .tooLarge: return "The diagnostic report exceeds its complete-output limit."
        case .unsupported: return "Diagnostic file operations are unavailable on this platform."
        }
    }
}

public enum DiagnosticReportPublication: Equatable, Sendable { case published, cleanupUncertain, locationUncertain }

public enum DiagnosticReportFile {
    public static let maximumBytes = 256 * 1024
    private static let maximumWriteCalls = 1024
    /// Publishes one complete private UTF-8 report without replacing an existing destination.
    public static func publish(_ text: String, to destination: URL) throws -> DiagnosticReportPublication {
        try publish(text, to: destination, beforePublish: nil)
    }
    static func publish(_ text: String, to destination: URL, beforePublish: (() -> Void)?) throws -> DiagnosticReportPublication {
        guard text.utf8.count <= maximumBytes else { throw DiagnosticReportError.tooLarge }
        #if canImport(Darwin)
        guard destination.isFileURL, !destination.hasDirectoryPath, destination.path != "/",
            !destination.path.utf8.contains(0), destination.path.utf8.count < Int(PATH_MAX) else { throw DiagnosticReportError.invalidDestination }
        let parent = destination.deletingLastPathComponent(), name = destination.lastPathComponent
        guard !name.isEmpty, name.utf8.count <= Int(NAME_MAX),
            let directory = try? DiagnosticFileScope.directory(parent, privateRoot: false) else { throw DiagnosticReportError.invalidDestination }
        defer { Darwin.close(directory) }
        var folder = stat()
        guard fstat(directory, &folder) == 0, folder.st_uid == getuid(), folder.st_mode & 0o022 == 0 else { throw DiagnosticReportError.invalidDestination }
        let stage = ".diagnostic-" + UUID().uuidString
        let descriptor = stage.withCString { openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600) }
        guard descriptor >= 0 else { throw DiagnosticReportError.invalidDestination }
        var stagePresent = true
        defer {
            if stagePresent {
                var opened = stat(), named = stat()
                if fstat(descriptor, &opened) == 0,
                    stage.withCString({ fstatat(directory, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
                    opened.st_dev == named.st_dev && opened.st_ino == named.st_ino {
                    _ = stage.withCString { unlinkat(directory, $0, 0) }
                }
            }
            Darwin.close(descriptor)
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw DiagnosticReportError.invalidDestination }
        let data = Data(text.utf8)
        var offset = 0, calls = 0
        try data.withUnsafeBytes { bytes in
            while offset < data.count {
                guard calls < maximumWriteCalls else { throw DiagnosticReportError.invalidDestination }; calls += 1
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw DiagnosticReportError.invalidDestination }; offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw DiagnosticReportError.invalidDestination }
        var written = stat(); guard fstat(descriptor, &written) == 0 else { throw DiagnosticReportError.invalidDestination }
        beforePublish?()
        var current = stat(), named = stat()
        guard DiagnosticFileScope.samePublicationParent(folder, at: parent), fstat(descriptor, &current) == 0,
            stage.withCString({ fstatat(directory, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
            DiagnosticFileScope.sameFile(written, current), DiagnosticFileScope.sameFile(written, named) else { throw DiagnosticReportError.invalidDestination }
        let linked = stage.withCString { source in name.withCString { target in linkat(directory, source, directory, target, 0) } }
        guard linked == 0 else { throw DiagnosticReportError.invalidDestination }
        let removed = stage.withCString { unlinkat(directory, $0, 0) }
        stagePresent = removed != 0
        if !DiagnosticFileScope.sameIdentity(folder, at: parent) { return .locationUncertain }
        return removed == 0 ? .published : .cleanupUncertain
        #else
        throw DiagnosticReportError.unsupported
        #endif
    }
}

#if canImport(Darwin)
private enum DiagnosticFileScope {
    static let maximumEntries = 4096
    static let maximumLogs = 1024
    private static let maximumPathBytes = Int(PATH_MAX) - 1
    static func regular(_ info: stat) -> Bool { UInt32(info.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG) }
    static func directory(_ url: URL, privateRoot: Bool) throws -> Int32? {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
            url.path != "/", url.path.utf8.count <= maximumPathBytes, !url.path.utf8.contains(0) else { throw DiagnosticReportError.invalidScope }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        var descriptor = Darwin.open("/", flags)
        guard descriptor >= 0 else { throw DiagnosticReportError.invalidScope }
        for component in url.standardizedFileURL.pathComponents where component != "/" {
            let next = component.withCString { openat(descriptor, $0, flags) }
            if next < 0 {
                let reason = errno; Darwin.close(descriptor)
                if reason == ENOENT { return nil }; throw DiagnosticReportError.invalidScope
            }
            Darwin.close(descriptor); descriptor = next
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), !privateRoot || info.st_mode & 0o077 == 0 else {
            Darwin.close(descriptor); throw DiagnosticReportError.invalidScope
        }
        return descriptor
    }
    static func sameIdentity(_ original: stat, at url: URL) -> Bool {
        guard let descriptor = try? directory(url, privateRoot: false) else { return false }
        defer { Darwin.close(descriptor) }
        var info = stat()
        return fstat(descriptor, &info) == 0 && original.st_dev == info.st_dev && original.st_ino == info.st_ino
    }
    static func sameFile(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    static func samePublicationParent(_ original: stat, at url: URL) -> Bool {
        guard let descriptor = try? directory(url, privateRoot: false) else { return false }
        defer { Darwin.close(descriptor) }
        var info = stat()
        // This operation creates/removes its own stage, so directory timestamps necessarily change.
        return fstat(descriptor, &info) == 0 && original.st_dev == info.st_dev && original.st_ino == info.st_ino
            && original.st_uid == info.st_uid && original.st_mode == info.st_mode
    }
    static func sameDirectory(_ original: stat, at url: URL) -> Bool {
        guard let descriptor = try? directory(url, privateRoot: false) else { return false }
        defer { Darwin.close(descriptor) }
        var info = stat()
        return fstat(descriptor, &info) == 0 && original.st_dev == info.st_dev && original.st_ino == info.st_ino
            && original.st_mode == info.st_mode && original.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec
            && original.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec && original.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec
            && original.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec
    }
}
#endif
