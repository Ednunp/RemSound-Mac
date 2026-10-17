import AppKit
import Darwin
import RemSoundRuntime

enum BootstrapProfileLogging {
    static func accepts(root: URL?, environment: [String: String], permission: String = "REMSOUND_TEST_NATIVE_PROFILE_LOGGING") -> Bool {
        guard environment[permission] == "1", let root,
            let raw = environment["REMSOUND_TEST_ROOT"], raw.hasPrefix("/"), raw != "/" else { return false }
        let base = URL(fileURLWithPath: raw).standardizedFileURL
        guard base.path == raw, base.resolvingSymlinksInPath().path == raw,
            base.path != FileManager.default.homeDirectoryForCurrentUser.path,
            root.standardizedFileURL == root, root.resolvingSymlinksInPath() == root,
            root.path.hasPrefix(base.path + "/") else { return false }
        for url in [base, root] {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { return false }
        }
        // A native fixture owns a new empty configuration, never an existing profile collection.
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
            entries.nextObject() == nil else { return false }
        return true
    }
    static func run(for options: LaunchOptions) -> (assertions: Int, failures: [String])? {
        guard accepts(root: options.configurationDirectory, environment: ProcessInfo.processInfo.environment),
            Thread.isMainThread, AppRuntime.configuration == nil, let root = options.configurationDirectory else { return nil }
        do {
            try AppRuntime.prepare(LaunchOptions.parse(["--config-dir", root.path, "--headless", "--silent"]))
            return MainActor.assumeIsolated {
                _ = NSApplication.shared
                return AppDelegate.profileLoggingProductCheck()
            }
        } catch { return (1, ["logs.native.isolated-configuration-failed"]) }
    }
}
