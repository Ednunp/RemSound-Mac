import CryptoKit
import Darwin
import Foundation

enum WebListenerPage {
    private static let expectedBytes = 44_218, chunkBytes = 16_384, maximumReadCalls = 16
    private static let expectedDigest = "bcb2b5e4b449953c495247eda673fd0f8194ea84c7c594fc0bae3e04c98c2a7a"
    static func load(bundle: Bundle = .main) -> Data? {
        // A packaged app must not fall back to the compiler's absolute workspace path.
        if bundle.bundleURL.pathExtension == "app" {
            guard let resources = bundle.resourceURL else { return nil }
            return read(resources.appendingPathComponent("web-listener.html"))
        }
        guard let url = Bundle.module.url(forResource: "web-listener", withExtension: "html") else { return nil }
        return read(url)
    }
    // Core-only owned-file seam. The returned bytes must be the exact shared protocol page.
    static func read(_ url: URL, afterRead: (() -> Void)? = nil) -> Data? {
        guard url.isFileURL, expectedBytes <= WebAdmission.maximumPageBytes else { return nil }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }; defer { Darwin.close(fd) }
        var before = stat(), after = stat(), named = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size == expectedBytes, before.st_nlink > 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data(); data.reserveCapacity(expectedBytes)
        for _ in 0..<maximumReadCalls {
            if data.count == expectedBytes { break }
            guard let part = try? file.read(upToCount: min(chunkBytes, expectedBytes - data.count)), !part.isEmpty else { return nil }
            data.append(part)
        }
        var byte: UInt8 = 0
        guard data.count == expectedBytes, Darwin.read(fd, &byte, 1) == 0 else { return nil }
        afterRead?()
        guard fstat(fd, &after) == 0, lstat(url.path, &named) == 0,
              stable(before, after), stable(after, named),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expectedDigest else { return nil }
        return data
    }
    private static func stable(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size && a.st_nlink == b.st_nlink
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
