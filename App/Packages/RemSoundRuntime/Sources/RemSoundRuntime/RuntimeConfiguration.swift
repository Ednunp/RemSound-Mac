import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public final class RuntimeConfiguration {
    public let diagnosticLoggingEnabled: Bool
    public let settings: SettingsStore
    public let root: URL?
    public let logsDirectory: URL
    public let profilesDirectory: URL
    public let recordingsDirectory: URL
    private let explicitSilence: Bool
    public private(set) var isHeadless: Bool
    public var silent: Bool { explicitSilence || isHeadless }
    public var controlSocketURL: URL? { root?.appendingPathComponent("control.sock") }
    public func handOverToGUI() { isHeadless = false }
    public var isIsolated: Bool { root != nil }
    public var allowsKeychain: Bool { !isIsolated }
    public var allowsUpdates: Bool { !isIsolated }
    public var allowsLoginItem: Bool { !isIsolated }
    public var allowsGlobalHotkeys: Bool { !isIsolated }

    public init(options: LaunchOptions) throws {
        root = options.configurationDirectory
        explicitSilence = options.silent || options.checkAccessibility
        isHeadless = options.headless
        if let root {
            guard root.path != "/" else { throw RuntimeConfigurationError.invalidConfigurationDirectory }
            // Foundation does not resolve a link ancestor when the last path component is missing.
            // Inspect each existing ancestor before creating the root, rather than checking only the leaf.
            var ancestor = root
            while ancestor.path != "/" {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: ancestor.path),
                    attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    throw RuntimeConfigurationError.unsafeConfigurationDirectory
                }
                ancestor.deleteLastPathComponent()
            }
            let manager = FileManager.default
            if !manager.fileExists(atPath: root.path) {
                try manager.createDirectory(at: root, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            try Self.validatePrivateItem(root, directory: true)
            settings = try SettingsStore(file: root.appendingPathComponent("settings.plist"))
            logsDirectory = root.appendingPathComponent("Logs", isDirectory: true)
            profilesDirectory = root.appendingPathComponent("Profiles", isDirectory: true)
            recordingsDirectory = root.appendingPathComponent("Recordings", isDirectory: true)
            for directory in [logsDirectory, profilesDirectory, recordingsDirectory] {
                if !manager.fileExists(atPath: directory.path) {
                    try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700])
                }
                try Self.validatePrivateItem(directory, directory: true)
            }
        } else {
            settings = SettingsStore(defaults: .standard)
            logsDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RemSound")
            profilesDirectory = Self.chosenProfilesDirectory(settings)
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("RemSound/Profiles", isDirectory: true)
            recordingsDirectory = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RemSound Recordings", isDirectory: true)
        }
        diagnosticLoggingEnabled = DiagnosticLoggingPreferences.enabled(in: settings)
    }

    /// Opens only the existing settings backend, without a runtime, identity or resource directories.
    public static func settingsForStandaloneCommand(root: URL?) throws -> SettingsStore {
        guard let root else { return SettingsStore(defaults: .standard) }
        guard root.isFileURL, root.path != "/", root.path.hasPrefix("/") else { throw RuntimeConfigurationError.invalidConfigurationDirectory }
        var ancestor = root
        while ancestor.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: ancestor.path),
                attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw RuntimeConfigurationError.unsafeConfigurationDirectory }
            ancestor.deleteLastPathComponent()
        }
        let files = FileManager.default
        if !files.fileExists(atPath: root.path) {
            try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try validatePrivateItem(root, directory: true)
        // Avoid overwriting the in-memory book of an active isolated process.
        guard (try? files.attributesOfItem(atPath: root.appendingPathComponent("control.sock").path)) == nil else {
            throw RuntimeConfigurationError.invalidSettings
        }
        return try SettingsStore(file: root.appendingPathComponent("settings.plist"))
    }

    /// Resolves the same profile location without creating configuration, migrating settings or opening passwords.
    /// The profiles folder chosen in Preferences (Windows AppConfig.ProfilesDirectory), such as one shared through Dropbox.
    /// That folder IS the profiles folder. A folder that no longer exists is ignored, as on Windows.
    public static let chosenProfilesDirectoryKey = "RemSoundProfilesDirectory"
    public static func chosenProfilesDirectory(_ settings: SettingsStore) -> URL? {
        guard let path = settings.string(forKey: chosenProfilesDirectoryKey), path.hasPrefix("/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public static func profilesDirectoryForListing(root: URL?, defaultDirectory: () -> URL) throws -> URL {
        guard let root else { return defaultDirectory() }
        guard root.isFileURL, root.path != "/", root.path.hasPrefix("/") else { throw RuntimeConfigurationError.invalidConfigurationDirectory }
        var ancestor = root
        while ancestor.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: ancestor.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw RuntimeConfigurationError.unsafeConfigurationDirectory
            }
            ancestor.deleteLastPathComponent()
        }
        if FileManager.default.fileExists(atPath: root.path) { try validatePrivateItem(root, directory: true) }
        let profiles = root.appendingPathComponent("Profiles", isDirectory: true)
        if (try? FileManager.default.attributesOfItem(atPath: profiles.path)) != nil {
            try validatePrivateItem(profiles, directory: true)
        }
        return profiles
    }

    /// Reads only machine-wide named history. Missing isolated roots stay missing; no runtime or migration.
    public static func namedPeersForListing(root: URL?) throws -> [NamedPeerRecord] {
        guard let root else { return try NamedPeerHistory(settings: SettingsStore(defaults: .standard)).entries }
        guard root.isFileURL, root.path != "/", root.path.hasPrefix("/") else { throw RuntimeConfigurationError.invalidConfigurationDirectory }
        var ancestor = root
        while ancestor.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: ancestor.path),
                attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw RuntimeConfigurationError.unsafeConfigurationDirectory }
            ancestor.deleteLastPathComponent()
        }
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        try validatePrivateItem(root, directory: true)
        let file = root.appendingPathComponent("settings.plist")
        guard (try? FileManager.default.attributesOfItem(atPath: file.path)) != nil else { return [] }
        do {
            let bytes = try StableRegularFile.read(file, maximumBytes: 4 * 1024 * 1024, privateFile: true)
            guard let snapshot = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any] else { throw RuntimeConfigurationError.invalidSettings }
            return try NamedPeerHistory.decode(snapshot["namedPeerHistory"]).values.sorted {
                let order = $0.friendlyName.localizedCaseInsensitiveCompare($1.friendlyName)
                return order == .orderedSame ? $0.machineName < $1.machineName : order == .orderedAscending
            }
        } catch { throw RuntimeConfigurationError.invalidSettings }
    }

    public var serverClientID: UUID {
        let key = "RemSoundServerClientId"
        if let text = settings.string(forKey: key), let id = UUID(uuidString: text) { return id }
        let id = UUID()
        settings.set(id.uuidString, forKey: key)
        return id
    }

    static func validatePrivateItem(_ url: URL, directory: Bool) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
            let mode = attributes[.posixPermissions] as? NSNumber,
            mode.intValue & 0o077 == 0 else {
            throw RuntimeConfigurationError.unsafeConfigurationDirectory
        }
    }
}
