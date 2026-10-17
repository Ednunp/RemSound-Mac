import Foundation

public struct NamedPeerRecord: Codable, Equatable, Sendable {
    public let machineName: String
    public let friendlyName: String
    public let lastAddress: String?
    public let lastSeen: Date?
}

/// Serialized by the existing connection owner. Only explicit naming creates records.
public final class NamedPeerHistory {
    static let key = "namedPeerHistory"
    public static let maximumRecords = 512
    static let maximumBytes = 256 * 1024
    private static let maximumMachineNameBytes = 512
    private static let maximumFriendlyNameCharacters = 80
    private static let maximumFriendlyNameBytes = 4 * maximumFriendlyNameCharacters
    private let settings: SettingsStore
    private var values: [String: NamedPeerRecord]
    private var dirty = false

    public init(settings: SettingsStore) throws {
        self.settings = settings
        values = try Self.decode(settings.object(forKey: Self.key))
    }
    public var entries: [NamedPeerRecord] {
        values.values.sorted {
            let order = $0.friendlyName.localizedCaseInsensitiveCompare($1.friendlyName)
            return order == .orderedSame ? $0.machineName < $1.machineName : order == .orderedAscending
        }
    }
    private static func clean(_ text: String, limit: Int) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= limit, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }) else { return nil }
        return value
    }
    private static func address(_ value: String) -> String? {
        guard !value.contains(":"), let normalized = StartupOptions.numericPeer(value), normalized == value else { return nil }
        return normalized
    }
    private static func identity(_ machine: String) -> String { machine.lowercased() }
    private static func valid(_ date: Date?) -> Bool {
        date.map { $0.timeIntervalSince1970.isFinite && (0...4102444800).contains($0.timeIntervalSince1970) } ?? true
    }
    static func decode(_ object: Any?) throws -> [String: NamedPeerRecord] {
        guard let object else { return [:] }
        guard let data = object as? Data, data.count <= maximumBytes,
            let rows = try? JSONDecoder().decode([NamedPeerRecord].self, from: data), rows.count <= maximumRecords else { throw RuntimeConfigurationError.invalidSettings }
        var result: [String: NamedPeerRecord] = [:]
        for row in rows {
            guard let machine = clean(row.machineName, limit: Self.maximumMachineNameBytes), !machine.isEmpty, machine == row.machineName,
                let name = clean(row.friendlyName, limit: Self.maximumFriendlyNameBytes), !name.isEmpty, name.count <= Self.maximumFriendlyNameCharacters, name == row.friendlyName,
                row.lastAddress.map({ address($0) != nil }) ?? true, valid(row.lastSeen),
                result[identity(machine)] == nil else { throw RuntimeConfigurationError.invalidSettings }
            result[identity(machine)] = row
        }
        return result
    }
    @discardableResult
    public func name(machine: String, address: String?, friendlyName: String, at date: Date = Date()) -> Bool {
        guard let label = Self.clean(machine, limit: Self.maximumMachineNameBytes), let name = Self.clean(friendlyName, limit: Self.maximumFriendlyNameBytes),
            name.count <= Self.maximumFriendlyNameCharacters, address.map({ Self.address($0) != nil }) ?? true, Self.valid(date) else { return false }
        let machineName = label.isEmpty ? address ?? "" : label
        guard !machineName.isEmpty else { return false }
        let key = Self.identity(machineName), old = values, oldDirty = dirty
        if name.isEmpty { values.removeValue(forKey: key) }
        else {
            guard values[key] != nil || values.count < Self.maximumRecords else { return false }
            values[key] = .init(machineName: machineName, friendlyName: name, lastAddress: address, lastSeen: address == nil ? nil : date)
        }
        guard values != old else { return true }
        dirty = true
        guard flush() else { values = old; dirty = oldDirty; return false }
        return true
    }
    /// Management edits preserve observations and refuse a row replaced while a dialog was open.
    public func rename(_ record: NamedPeerRecord, friendlyName: String) -> Bool {
        let key = Self.identity(record.machineName)
        guard let current = values[key], current.friendlyName == record.friendlyName,
            let name = Self.clean(friendlyName, limit: Self.maximumFriendlyNameBytes),
            name.count <= Self.maximumFriendlyNameCharacters else { return false }
        if name.isEmpty { return forget([record]) }
        let old = values, wasDirty = dirty
        values[key] = .init(machineName: current.machineName, friendlyName: name,
            lastAddress: current.lastAddress, lastSeen: current.lastSeen)
        dirty = true
        guard flush() else { values = old; dirty = wasDirty; return false }
        return true
    }
    public func forget(_ records: [NamedPeerRecord]) -> Bool {
        guard !records.isEmpty, records.count <= Self.maximumRecords,
            Set(records.map { Self.identity($0.machineName) }).count == records.count,
            records.allSatisfy({ values[Self.identity($0.machineName)]?.friendlyName == $0.friendlyName }) else { return false }
        let old = values, wasDirty = dirty
        for record in records { values.removeValue(forKey: Self.identity(record.machineName)) }
        dirty = true
        guard flush() else { values = old; dirty = wasDirty; return false }
        return true
    }
    public func friendlyName(machine: String) -> String? { values[Self.identity(machine)]?.friendlyName }
    /// A healthy current connection may update an existing record; unnamed peers are never collected.
    @discardableResult
    public func noteConnected(machine: String, address: String, at date: Date = Date()) -> Bool {
        guard let machine = Self.clean(machine, limit: Self.maximumMachineNameBytes), Self.address(address) != nil, Self.valid(date),
            let old = values[Self.identity(machine)], old.lastSeen.map({ date >= $0 }) ?? true else { return false }
        let updated = NamedPeerRecord(machineName: old.machineName, friendlyName: old.friendlyName, lastAddress: address, lastSeen: date)
        guard updated != old else { return true }
        values[Self.identity(machine)] = updated; dirty = true
        // Match the connection owner's lifetime: address changes persist now; timestamps flush on stop.
        return old.lastAddress != address ? flush() : true
    }
    @discardableResult
    public func flush() -> Bool {
        guard dirty else { return true }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries), data.count <= Self.maximumBytes,
            settings.setValues([Self.key: data]) else { return false }
        dirty = false; return true
    }
}
