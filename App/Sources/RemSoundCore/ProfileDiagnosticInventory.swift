import Darwin
import Foundation

/// Counts only: no profile identities, titles, paths, addresses or contents leave the store.
public struct ProfileDiagnosticInventory: Equatable, Sendable {
    public let readable: Int
    public let readOnly: Int
    public let unreadable: Int
    public let deferred: Int
    public let complete: Bool
    public init(readable: Int, readOnly: Int, unreadable: Int, deferred: Int, complete: Bool) {
        self.readable = readable; self.readOnly = readOnly; self.unreadable = unreadable
        self.deferred = deferred; self.complete = complete
    }
}

public enum ProfileDiagnosticError: Error { case invalidDirectory, unavailable }

extension ProfileStore {
    public func diagnosticInventory() throws -> ProfileDiagnosticInventory {
        try diagnosticInventory(afterRead: nil)
    }
    // Core-only fault seam. The public reader never exposes a callback or raw file authority.
    func diagnosticInventory(afterRead: ((URL) -> Void)?) throws -> ProfileDiagnosticInventory {
        guard let descriptor = try DiagnosticProfileReader.openDirectory(directory) else {
            return .init(readable: 0, readOnly: 0, unreadable: 0, deferred: 0, complete: true)
        }
        defer { Darwin.close(descriptor) }
        var directoryBefore = stat()
        guard fstat(descriptor, &directoryBefore) == 0 else { throw ProfileDiagnosticError.unavailable }
        var failed = false
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants], errorHandler: { _, _ in failed = true; return false }) else {
            throw ProfileDiagnosticError.unavailable
        }
        var readable = 0, readOnly = 0, unreadable = 0, deferred = 0
        var scanned = 0, visits = 0, reservedBytes = 0
        for case let url as URL in entries {
            guard scanned < DiagnosticProfileReader.maximumEntries else { failed = true; break }
            scanned += 1
            guard url.pathExtension.lowercased() == "json" else { continue }
            let name = url.lastPathComponent
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), name == id.uuidString + ".json" else {
                unreadable += 1; continue
            }
            guard visits < DiagnosticProfileReader.maximumFileVisits else { deferred += 1; continue }
            visits += 1
            switch DiagnosticProfileReader.read(name, in: descriptor,
                remainingBytes: DiagnosticProfileReader.maximumTotalBytes - reservedBytes,
                afterRead: afterRead.map { hook in { hook(url) } }) {
            case .unreadable(let reservation): reservedBytes += reservation; unreadable += 1
            case .deferred(let reservation): reservedBytes += reservation; deferred += 1
            case .data(let data, let reservation):
                reservedBytes += reservation
                switch DiagnosticProfileReader.structure(data) {
                case .tooDeep: deferred += 1; continue
                case .malformed: unreadable += 1; continue
                case .valid: break
                }
                guard let profile = try? JSONDecoder().decode(ConnectionProfile.self, from: data), profile.id == id else {
                    unreadable += 1; continue
                }
                readable += 1
                if profile.readOnly { readOnly += 1 }
            }
        }
        var directoryAfter = stat()
        let current = directory.path.withCString { lstat($0, &directoryAfter) }
        if current != 0 || directoryBefore.st_ino != directoryAfter.st_ino || directoryBefore.st_dev != directoryAfter.st_dev
            || directoryBefore.st_mtimespec.tv_sec != directoryAfter.st_mtimespec.tv_sec
            || directoryBefore.st_mtimespec.tv_nsec != directoryAfter.st_mtimespec.tv_nsec
            || directoryBefore.st_ctimespec.tv_sec != directoryAfter.st_ctimespec.tv_sec
            || directoryBefore.st_ctimespec.tv_nsec != directoryAfter.st_ctimespec.tv_nsec {
            failed = true
        }
        return .init(readable: readable, readOnly: readOnly, unreadable: unreadable, deferred: deferred,
            complete: !failed && deferred == 0)
    }
}

private enum DiagnosticProfileReader {
    static let maximumEntries = 4096
    static let maximumFileVisits = 256
    static let maximumFileBytes = 2 * 1024 * 1024
    static let maximumTotalBytes = 16 * 1024 * 1024
    private static let maximumJSONDepth = 64
    private static let chunkBytes = 32 * 1024
    private static let maximumReadCalls = 80
    enum Result { case data(Data, Int), unreadable(Int), deferred(Int) }
    enum Structure { case valid, malformed, tooDeep }

    // Walk relative to held descriptors so replacing a path ancestor cannot redirect a file read.
    static func openDirectory(_ url: URL) throws -> Int32? {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
            url.path != "/", !url.path.utf8.contains(0) else { throw ProfileDiagnosticError.invalidDirectory }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        var descriptor = Darwin.open("/", flags)
        guard descriptor >= 0 else { throw ProfileDiagnosticError.unavailable }
        for component in url.standardizedFileURL.pathComponents where component != "/" {
            let next = component.withCString { openat(descriptor, $0, flags) }
            if next < 0 {
                let reason = errno; Darwin.close(descriptor)
                if reason == ENOENT { return nil }
                throw ProfileDiagnosticError.invalidDirectory
            }
            Darwin.close(descriptor); descriptor = next
        }
        return descriptor
    }
    static func read(_ name: String, in directory: Int32, remainingBytes: Int, afterRead: (() -> Void)?) -> Result {
        let descriptor = name.withCString { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard descriptor >= 0 else { return .unreadable(0) }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
            UInt32(before.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG), before.st_size >= 0 else { return .unreadable(0) }
        guard before.st_size <= maximumFileBytes, before.st_size + 1 <= remainingBytes else { return .deferred(0) }
        let expected = Int(before.st_size), reservation = expected + 1
        var data = Data(), buffer = [UInt8](repeating: 0, count: min(chunkBytes, reservation)), calls = 0
        while data.count <= expected {
            guard calls < maximumReadCalls else { return .deferred(reservation) }
            calls += 1
            let limit = min(buffer.count, reservation - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, limit) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { return .unreadable(reservation) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        afterRead?()
        var after = stat(), named = stat()
        guard fstat(descriptor, &after) == 0,
            name.withCString({ fstatat(directory, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
            stable(before, after), stable(before, named), data.count == expected else { return .deferred(reservation) }
        return .data(data, reservation)
    }
    private static func stable(_ a: stat, _ b: stat) -> Bool {
        a.st_ino == b.st_ino && a.st_dev == b.st_dev && a.st_mode == b.st_mode && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    static func structure(_ data: Data) -> Structure {
        var quoted = false, escaped = false, depth = 0
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == JSONByte.escape { escaped = true }
                else if byte == JSONByte.quote { quoted = false }
                continue
            }
            if byte == JSONByte.quote { quoted = true }
            else if byte == JSONByte.objectOpen || byte == JSONByte.arrayOpen {
                depth += 1
                if depth > maximumJSONDepth { return .tooDeep }
            } else if byte == JSONByte.objectClose || byte == JSONByte.arrayClose {
                depth -= 1
                if depth < 0 { return .malformed }
            }
        }
        return quoted || depth != 0 ? .malformed : .valid
    }
    private enum JSONByte {
        static let quote: UInt8 = 0x22, escape: UInt8 = 0x5c
        static let objectOpen: UInt8 = 0x7b, objectClose: UInt8 = 0x7d
        static let arrayOpen: UInt8 = 0x5b, arrayClose: UInt8 = 0x5d
    }
}
