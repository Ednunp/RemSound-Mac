import Darwin
import Foundation
import RemSoundRuntime

/// Install and remove the DAW plugins from the app (Windows' DAW plugin menu: Install plugin, Remove plugin). The app
/// carries the AU, VST3 and CLAP plugins in Contents/PlugIns; installing copies each to its folder under
/// ~/Library/Audio/Plug-Ins, replacing what was there, and removing takes them out again. An isolated run (a test
/// configuration folder) uses Library/Audio/Plug-Ins inside that folder instead, so nothing of the person's is touched.
public enum PluginInstaller {
    /// Each plugin, and the Plug-Ins folder it goes in.
    public static let bundles = [("RemSound.component", "Components"), ("RemSound.vst3", "VST3"), ("RemSound.clap", "CLAP")]

    public enum Outcome: Equatable, Sendable {
        case installed(Int), removed(Int), nothingBundled, nothingInstalled, failed(String)

        /// Said to the person, in plain words.
        public var message: String {
            switch self {
            case .installed(let n):
                return "\(n == 3 ? "The AU, VST3 and CLAP plugins are" : "\(n) plugin\(n == 1 ? " is" : "s are")") installed in your "
                    + "Plug-Ins folder. Restart your DAW, or rescan its plugins, to load them."
            case .removed(let n): return "\(n) plugin\(n == 1 ? "" : "s") removed. Restart your DAW to let go of them."
            case .nothingBundled: return "This copy of RemSound does not carry the plugins. Download the full release to install them."
            case .nothingInstalled: return "The RemSound plugins are not installed."
            case .failed(let why): return "The plugins could not be changed: \(why)"
            }
        }
    }

    /// Where the app carries the plugins.
    public static func sourceFolder(app: URL = Bundle.main.bundleURL) -> URL {
        app.appendingPathComponent("Contents/PlugIns", isDirectory: true)
    }

    /// The Plug-Ins folder they go in: the person's, or the isolated configuration's.
    public static func targetRoot(_ configuration: RuntimeConfiguration) -> URL {
        (configuration.root ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Library/Audio/Plug-Ins", isDirectory: true)
    }

    public static func installed(in root: URL) -> [String] {
        bundles.compactMap { name, folder in
            FileManager.default.fileExists(atPath: root.appendingPathComponent(folder).appendingPathComponent(name).path) ? name : nil
        }
    }

    public static func install(from source: URL, to root: URL, fileManager: FileManager = .default) -> Outcome {
        install(from: source, to: root, fileManager: fileManager, verifyOwnership: verifyOwnership)
    }

    // Core-only injection keeps filesystem fault tests independent of signing credentials.
    // Normal callers always use the fixed publisher requirement.
    static func install(from source: URL, to root: URL, fileManager: FileManager = .default,
        verifyOwnership: (URL) throws -> Void, checkpoint: () throws -> Void = {}) -> Outcome {
        let available = bundles.filter { fileManager.fileExists(atPath: source.appendingPathComponent($0.0).path) }
        guard !available.isEmpty else { return .nothingBundled }
        do {
            guard available.count == bundles.count else { throw InstallerError.incompletePayload }
            try withLock(root, fileManager: fileManager) {
                var items = [UpdateInstallItem]()
                for (name, folder) in bundles {
                    let input = source.appendingPathComponent(name)
                    let target = root.appendingPathComponent(folder).appendingPathComponent(name)
                    try requireUnredirected(input); try requireUnredirected(target)
                    try verifyOwnership(input)
                    if fileManager.fileExists(atPath: target.path) { try verifyOwnership(target) }
                    items.append(.init(source: input, target: target))
                }
                try UpdateTransaction.install(items, copy: fileManager.copyItem, verify: { url in
                    try requireUnredirected(url)
                    try verifyOwnership(url)
                    if url == items.last?.target { try checkpoint() }
                })
            }
            return .installed(bundles.count)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public static func remove(from root: URL, fileManager: FileManager = .default) -> Outcome {
        remove(from: root, fileManager: fileManager, verifyOwnership: verifyOwnership)
    }

    static func remove(from root: URL, fileManager: FileManager = .default,
        verifyOwnership: (URL) throws -> Void, checkpoint: () throws -> Void = {}) -> Outcome {
        do {
            return try withLock(root, fileManager: fileManager) {
                let targets = bundles.map { root.appendingPathComponent($0.1).appendingPathComponent($0.0) }
                    .filter { fileManager.fileExists(atPath: $0.path) }
                guard !targets.isEmpty else { return .nothingInstalled }
                for target in targets { try requireUnredirected(target); try verifyOwnership(target) }
                try UpdateTransaction.removeFiles(targets, beforeMove: { url in
                    try requireUnredirected(url); try verifyOwnership(url)
                }, beforeCommit: checkpoint)
                return .removed(targets.count)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private enum InstallerError: LocalizedError {
        case incompletePayload, redirectedPath, busy
        var errorDescription: String? {
            switch self {
            case .incompletePayload: return "The app must contain all three plugin formats. Download the full Mac release."
            case .redirectedPath: return "A plugin path redirects elsewhere. No plugin was changed."
            case .busy: return "Another plugin operation is already running. Wait for it to finish."
            }
        }
    }

    private static func requireUnredirected(_ url: URL) throws {
        guard url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else {
            throw InstallerError.redirectedPath
        }
    }

    private static func verifyOwnership(_ url: URL) throws {
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"83NN3HS237\" and identifier \"org.remsound.plugin\""
        _ = try UpdateCommand.run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", "--test-requirement", "=" + requirement, url.path])
    }

    private static func withLock<T>(_ root: URL, fileManager: FileManager, _ action: () throws -> T) throws -> T {
        try requireUnredirected(root)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = root.appendingPathComponent(".remsound-plugin-operation.lock")
        let descriptor = open(lock.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw InstallerError.busy }
        var owned = stat()
        guard fstat(descriptor, &owned) == 0 else { _ = Darwin.close(descriptor); throw InstallerError.busy }
        defer {
            _ = Darwin.close(descriptor)
            var current = stat()
            if lstat(lock.path, &current) == 0, current.st_dev == owned.st_dev, current.st_ino == owned.st_ino {
                _ = unlink(lock.path)
            }
        }
        try requireUnredirected(root)
        return try action()
    }
}
