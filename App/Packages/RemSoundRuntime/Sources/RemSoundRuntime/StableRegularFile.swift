import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Shared by the two bounded standalone readers; no settings/runtime is constructed here.
enum StableRegularFile {
    enum Failure: Error { case unavailable }
    static func read(_ url: URL, maximumBytes: Int, privateFile: Bool = false,
        beforeFinal: (() throws -> Void)? = nil) throws -> Data {
        #if canImport(Darwin)
        guard url.isFileURL, !url.path.utf8.contains(0), url.path.utf8.count < Int(PATH_MAX), maximumBytes > 0 else { throw Failure.unavailable }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd) }
        var initial = stat()
        guard fstat(fd, &initial) == 0, UInt32(initial.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG),
            initial.st_size > 0, initial.st_size <= maximumBytes,
            !privateFile || (initial.st_uid == getuid() && initial.st_mode & 0o077 == 0) else { throw Failure.unavailable }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024), calls = 0
        while bytes.count < initial.st_size {
            guard calls < 4096 else { throw Failure.unavailable }; calls += 1
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, min($0.count, Int(initial.st_size) - bytes.count)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.unavailable }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        try beforeFinal?()
        var final = stat(), named = stat()
        guard fstat(fd, &final) == 0, lstat(url.path, &named) == 0,
            final.st_dev == initial.st_dev, final.st_ino == initial.st_ino,
            named.st_dev == initial.st_dev, named.st_ino == initial.st_ino,
            UInt32(named.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG),
            final.st_size == initial.st_size, final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
            final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
            !privateFile || (final.st_uid == getuid() && named.st_uid == getuid() && final.st_mode & 0o077 == 0 && named.st_mode & 0o077 == 0)
        else { throw Failure.unavailable }
        return bytes
        #else
        throw Failure.unavailable
        #endif
    }
}
