import AppKit
import Darwin
import RemSoundRuntime

enum BootstrapDialogAudit {
    static let permission = "REMSOUND_TEST_NATIVE_DIALOGS"
    static func accepts(root: URL?, environment: [String: String]) -> Bool {
        BootstrapProfileLogging.accepts(root: root, environment: environment, permission: permission)
    }
    // The explicit private fixture has one fixed source snapshot beside its empty configuration.
    // Source never enters a report and the ordinary application does not read it.
    static func sources(environment: [String: String], includeNativeSources: Bool = false) throws -> [String: String] {
        guard let raw = environment["REMSOUND_TEST_ROOT"] else { throw CocoaError(.fileReadNoSuchFile) }
        let base = URL(fileURLWithPath: raw).appendingPathComponent("dialog-audit-source")
        var directory = stat()
        guard base.resolvingSymlinksInPath() == base,
            lstat(base.path, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
            directory.st_uid == getuid(), directory.st_mode & 0o077 == 0,
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { throw CocoaError(.fileReadNoSuchFile) }
        var result = [String: String](), total = 0
        while let file = files.nextObject() as? URL {
            var before = stat(), after = stat()
            guard lstat(file.path, &before) == 0, before.st_uid == getuid(), before.st_mode & S_IFMT != S_IFLNK else { throw CocoaError(.fileReadNoPermission) }
            if before.st_mode & S_IFMT == S_IFDIR { continue }
            guard before.st_mode & S_IFMT == S_IFREG, (includeNativeSources ? ["swift", "c", "h", "cpp", "mm"].contains(file.pathExtension) : file.pathExtension == "swift"), before.st_size <= 1024 * 1024,
                result.count < 1024, total <= 16 * 1024 * 1024 - Int(before.st_size) else { throw CocoaError(.fileReadTooLarge) }
            let data = try Data(contentsOf: file)
            guard lstat(file.path, &after) == 0, before.st_ino == after.st_ino, before.st_size == after.st_size,
                before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
            total += data.count; result[String(file.path.dropFirst(base.path.count + 1))] = text
        }
        guard !result.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        return result
    }
    static func run(for options: LaunchOptions, controls: Bool) -> (assertions: Int, failures: [String])? {
        let environment = ProcessInfo.processInfo.environment
        guard accepts(root: options.configurationDirectory, environment: environment), Thread.isMainThread,
            AppRuntime.configuration == nil, let root = options.configurationDirectory else { return nil }
        do {
            let snapshot = try sources(environment: environment)
            try AppRuntime.prepare(LaunchOptions.parse(["--config-dir", root.path, "--headless", "--silent"]))
            return MainActor.assumeIsolated {
                _ = NSApplication.shared
                return AppDelegate.dialogProductCheck(sources: snapshot, controls: controls)
            }
        } catch { return (1, ["dialogs.native.isolated-source-or-configuration-refused"]) }
    }
}
