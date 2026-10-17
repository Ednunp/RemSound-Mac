import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Normal launches retain Apple's preferences semantics. Isolated launches never consult CFPreferences.
public final class SettingsStore {
    private let defaults: UserDefaults?
    private let file: URL?
    private var values: [String: Any] = [:]
    private let lock = NSLock()
    private var failed = false
    public var persistenceFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        file = nil
    }

    public init(file: URL) throws {
        defaults = nil
        self.file = file
        try RuntimeConfiguration.validatePrivateItem(file.deletingLastPathComponent(), directory: true)
        if (try? FileManager.default.attributesOfItem(atPath: file.path)) != nil {
            try RuntimeConfiguration.validatePrivateItem(file, directory: false)
            guard let data = try? Data(contentsOf: file),
                let stored = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                let dictionary = stored as? [String: Any] else {
                throw RuntimeConfigurationError.invalidSettings
            }
            values = dictionary
        }
    }

    public func object(forKey key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return defaults?.object(forKey: key) ?? values[key]
    }
    public func string(forKey key: String) -> String? {
        if let defaults { return defaults.string(forKey: key) }
        return object(forKey: key) as? String
    }
    public func data(forKey key: String) -> Data? {
        if let defaults { return defaults.data(forKey: key) }
        return object(forKey: key) as? Data
    }
    public func array(forKey key: String) -> [Any]? {
        if let defaults { return defaults.array(forKey: key) }
        return object(forKey: key) as? [Any]
    }
    public func stringArray(forKey key: String) -> [String]? {
        if let defaults { return defaults.stringArray(forKey: key) }
        return object(forKey: key) as? [String]
    }
    public func dictionary(forKey key: String) -> [String: Any]? {
        if let defaults { return defaults.dictionary(forKey: key) }
        return object(forKey: key) as? [String: Any]
    }
    public func bool(forKey key: String) -> Bool {
        if let defaults { return defaults.bool(forKey: key) }
        if let number = object(forKey: key) as? NSNumber { return number.boolValue }
        return (object(forKey: key) as? NSString)?.boolValue ?? false
    }
    public func integer(forKey key: String) -> Int {
        if let defaults { return defaults.integer(forKey: key) }
        if let number = object(forKey: key) as? NSNumber { return number.intValue }
        return (object(forKey: key) as? NSString)?.integerValue ?? 0
    }
    public func url(forKey key: String) -> URL? {
        if let defaults { return defaults.url(forKey: key) }
        guard let stored = object(forKey: key) as? [String: String], let text = stored["runtimeURL"] else { return nil }
        return URL(string: text)
    }
    public func set(_ value: Any?, forKey key: String) {
        _ = setValues([key: value])
    }
    /// Validate all changes before applying them. An isolated file publishes one complete replacement.
    /// Normal Apple preferences retain per-key writes; this is not a cross-process or crash transaction.
    @discardableResult
    public func setValues(_ updates: [String: Any?]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !updates.isEmpty else { return true }
        var updated = values
        for (key, value) in updates {
            updated[key] = (value as? URL).map { ["runtimeURL": $0.absoluteString] } ?? value
        }
        do {
            // Serialize before touching either backend, including removal and URL validation.
            let data = try PropertyListSerialization.data(fromPropertyList: updated, format: .binary, options: 0)
            if let defaults {
                for (key, value) in updates { defaults.set(value, forKey: key) }
            } else {
                guard let file else { throw RuntimeConfigurationError.invalidSettings }
                try publish(data, to: file)
                values = updated
            }
            failed = false
            return true
        } catch {
            // A failed isolated write must never fall back to the user's preferences.
            failed = true
            return false
        }
    }
    private func publish(_ data: Data, to file: URL) throws {
        let parent = file.deletingLastPathComponent()
        func validateDestination() throws {
            try RuntimeConfiguration.validatePrivateItem(parent, directory: true)
            if (try? FileManager.default.attributesOfItem(atPath: file.path)) != nil {
                try RuntimeConfiguration.validatePrivateItem(file, directory: false)
            }
        }
        try validateDestination()
        let stage = parent.appendingPathComponent(".settings-" + UUID().uuidString)
        let descriptor = stage.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
        guard descriptor >= 0 else { throw RuntimeConfigurationError.invalidSettings }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: stage) }
        guard fchmod(descriptor, 0o600) == 0 else { throw RuntimeConfigurationError.invalidSettings }
        try handle.write(contentsOf: data)
        try handle.close()
        try RuntimeConfiguration.validatePrivateItem(stage, directory: false)
        try validateDestination()
        // Publish only after its private mode is established. No fallible post-publication chmod.
        let result = stage.path.withCString { source in file.path.withCString { rename(source, $0) } }
        guard result == 0 else { throw RuntimeConfigurationError.invalidSettings }
    }
    public func removeObject(forKey key: String) { set(nil, forKey: key) }
}
