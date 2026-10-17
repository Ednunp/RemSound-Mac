import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Fixed per-user locations only. Metadata presence is not signature, DAW or audio acceptance.
public struct PluginInstallationStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case missing, metadataPresent, incomplete, invalid, unavailable }
    public struct Item: Codable, Equatable, Sendable {
        public let format: String
        public let state: State
        public let version: String?
        public let build: String?
        public let executablePresent: Bool?
        public let sharedRuntimePresent: Bool?
    }
    public let schema: Int
    public let generatedUTC: String
    public let scope: String
    public let metadataOnly: Bool
    public let items: [Item]

    static let locations = [
        ("AU", "Library/Audio/Plug-Ins/Components/RemSound.component"),
        ("VST3", "Library/Audio/Plug-Ins/VST3/RemSound.vst3"),
        ("CLAP", "Library/Audio/Plug-Ins/CLAP/RemSound.clap")
    ]
    static func read(base: URL, isolated: Bool, beforeFinal: (() throws -> Void)? = nil) throws -> Self {
        #if canImport(Darwin)
        guard base.isFileURL, base.path.hasPrefix("/"), base.path != "/", base.path.utf8.count <= 1024,
            !base.path.utf8.contains(0), base.standardizedFileURL.path == base.path else {
            throw RuntimeConfigurationError.unsafeConfigurationDirectory
        }
        var receipts = [(URL, FileState?)]()
        func inspect(_ url: URL) throws -> FileState? {
            let value = try FileState.read(url)
            receipts.append((url, value))
            return value
        }
        var ancestors = [URL](), ancestor = base
        while ancestor.path != "/" { ancestors.append(ancestor); ancestor.deleteLastPathComponent() }
        var baseExists = true
        for url in ancestors.reversed() {
            guard let item = try inspect(url) else { baseExists = false; break }
            guard item.type == UInt32(S_IFDIR) else { throw RuntimeConfigurationError.unsafeConfigurationDirectory }
        }
        if isolated && baseExists { try RuntimeConfiguration.validatePrivateItem(base, directory: true) }
        func row(_ format: String, _ state: State) -> Item {
            .init(format: format, state: state, version: nil, build: nil,
                executablePresent: state == .missing ? false : nil,
                sharedRuntimePresent: state == .missing ? false : nil)
        }
        func directory(_ url: URL) throws -> Bool {
            guard let item = try inspect(url) else { return false }
            guard item.type == UInt32(S_IFDIR) else { throw StableRegularFile.Failure.unavailable }
            return true
        }
        func regular(_ url: URL, executable: Bool = false) throws -> Bool {
            guard let item = try inspect(url) else { return false }
            guard item.type == UInt32(S_IFREG) else { throw StableRegularFile.Failure.unavailable }
            return item.size > 0 && (!executable || item.mode & 0o111 != 0)
        }
        let items: [Item] = locations.map { format, relative in
            guard baseExists else { return row(format, .missing) }
            do {
                var bundle = base
                for component in relative.split(separator: "/") {
                    bundle.appendPathComponent(String(component))
                    guard try directory(bundle) else { return row(format, .missing) }
                }
                let contents = bundle.appendingPathComponent("Contents")
                guard try directory(contents) else { return row(format, .incomplete) }
                let info = contents.appendingPathComponent("Info.plist")
                guard let infoState = try inspect(info) else { return row(format, .incomplete) }
                guard infoState.type == UInt32(S_IFREG) else { return row(format, .unavailable) }
                let bytes = try StableRegularFile.read(info, maximumBytes: 128 * 1024)
                guard let metadata = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
                    metadata["CFBundleIdentifier"] as? String == "org.remsound.plugin",
                    metadata["CFBundleExecutable"] as? String == "RemSound",
                    let version = numericVersion(metadata["CFBundleShortVersionString"], parts: 3...3, bytes: 64),
                    metadata["CFBundleVersion"] == nil || numericVersion(metadata["CFBundleVersion"], parts: 1...3, bytes: 32) != nil
                else { return row(format, .invalid) }
                let macOS = contents.appendingPathComponent("MacOS"), frameworks = contents.appendingPathComponent("Frameworks")
                let executable = try directory(macOS) && regular(macOS.appendingPathComponent("RemSound"), executable: true)
                let runtime = try directory(frameworks) && regular(frameworks.appendingPathComponent("libRemSoundPluginHost-v1.dylib"))
                return .init(format: format, state: executable && runtime ? .metadataPresent : .incomplete,
                    version: version, build: metadata["CFBundleVersion"] as? String,
                    executablePresent: executable, sharedRuntimePresent: runtime)
            } catch { return row(format, .unavailable) }
        }
        try beforeFinal?()
        let unchanged = receipts.allSatisfy { url, initial in
            do { return try FileState.read(url) == initial } catch { return false }
        }
        return .init(schema: 1, generatedUTC: ISO8601DateFormatter().string(from: Date()),
            scope: isolated ? "isolated" : "user", metadataOnly: true,
            items: unchanged ? items : locations.map { row($0.0, .unavailable) })
        #else
        throw RuntimeConfigurationError.unsafeConfigurationDirectory
        #endif
    }

    private static func numericVersion(_ value: Any?, parts: ClosedRange<Int>, bytes: Int) -> String? {
        guard let value = value as? String, value.utf8.count <= bytes else { return nil }
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.contains(fields.count), fields.allSatisfy({
            !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } && UInt32($0) != nil
        }) else { return nil }
        return value
    }
    #if canImport(Darwin)
    private struct FileState: Equatable {
        let device: Int64, inode: UInt64, owner: UInt32, type: UInt32, mode: UInt16, size: Int64
        let seconds: Int, nanoseconds: Int
        static func read(_ url: URL) throws -> Self? {
            var value = stat()
            guard lstat(url.path, &value) == 0 else {
                if errno == ENOENT { return nil }
                throw StableRegularFile.Failure.unavailable
            }
            return .init(device: Int64(value.st_dev), inode: UInt64(value.st_ino), owner: value.st_uid,
                type: UInt32(value.st_mode) & UInt32(S_IFMT), mode: value.st_mode, size: value.st_size,
                seconds: value.st_mtimespec.tv_sec, nanoseconds: value.st_mtimespec.tv_nsec)
        }
    }
    #endif
}

extension RuntimeConfiguration {
    /// Does not create a runtime, settings, folders or any plugin/DAW process.
    public static func pluginStatusForListing(root: URL?) throws -> PluginInstallationStatus {
        try PluginInstallationStatus.read(base: root ?? FileManager.default.homeDirectoryForCurrentUser,
            isolated: root != nil)
    }
}
