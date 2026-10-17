import Foundation

public struct RememberedPeerConnection: Equatable {
    public let identity: RememberedPeerIdentity
    public let selected: Bool
    public let isKnownServer: Bool

    public init(identity: RememberedPeerIdentity, selected: Bool, isKnownServer: Bool = false) {
        self.identity = identity
        self.selected = selected
        self.isKnownServer = isKnownServer
    }
}

/// One serialized connection owner. Snapshots bind existing entries without writing or re-remembering them.
public final class RememberedPeerConnections {
    private struct Reference {
        var instanceID: UUID
        var address: String
    }
    private let preferences: RememberedPeerPreferences
    private var references: [String: Reference] = [:]
    private var connections: [RememberedPeerConnection] = []
    private var serverEntries: Set<String> = []
    private var serverAddresses: Set<String> = []
    public private(set) var generation = UUID()

    public init(settings: SettingsStore) {
        preferences = RememberedPeerPreferences(settings: settings)
    }

    public var entries: [String] { preferences.entries }

    public var availableEntries: [String] {
        preferences.entries.filter { entry in
            guard !isServer(entry) else { return false }
            guard let reference = references[entry] else { return true }
            guard !serverAddresses.contains(reference.address.lowercased()) else { return false }
            return !connections.contains { $0.selected && $0.identity.instanceID == reference.instanceID }
        }
    }

    public func update(_ connections: [RememberedPeerConnection]) {
        self.connections = connections
        for connection in connections where connection.isKnownServer {
            serverAddresses.insert(connection.identity.address.lowercased())
        }
        let entries = preferences.entries
        references = references.filter { entries.contains($0.key) }
        for entry in entries where references[entry] == nil && !isServer(entry) {
            let host = Self.host(entry)
            let matches = connections.filter {
                !$0.isKnownServer && ($0.identity.address.caseInsensitiveCompare(host) == .orderedSame
                    || $0.identity.advertisedName.caseInsensitiveCompare(host) == .orderedSame)
            }
            guard Set(matches.map { $0.identity.instanceID }).count == 1,
                  let match = matches.first(where: \.selected) ?? matches.first else { continue }
            references[entry] = Reference(instanceID: match.identity.instanceID, address: match.identity.address)
        }
    }

    @discardableResult
    public func rememberManual(_ entry: String, peer: RememberedPeerIdentity,
                               generation: UUID? = nil, isKnownServer: Bool = false) -> Bool {
        guard generation == nil || generation == self.generation,
              !isKnownServer, !isServer(entry), !serverAddresses.contains(peer.address.lowercased()) else { return false }
        preferences.remember(entry)
        return bind(entry: entry, peer: peer)
    }

    @discardableResult
    public func rememberDiscovered(_ peer: RememberedPeerIdentity, among peers: [RememberedPeerIdentity],
                                   isKnownServer: Bool = false) -> Bool {
        guard !serverAddresses.contains(peer.address.lowercased()),
              let entry = RememberedPeerPreferences.entry(for: peer, among: peers, isKnownServer: isKnownServer),
              !isServer(entry) else { return false }
        preferences.remember(entry)
        return bind(entry: entry, peer: peer)
    }

    public func redirect(address: String, to peer: RememberedPeerIdentity) {
        for entry in references.keys.sorted() where references[entry]?.address == address {
            references[entry] = Reference(instanceID: peer.instanceID, address: peer.address)
        }
    }

    public func isKnownServer(entry: String, address: String? = nil) -> Bool {
        isServer(entry) || address.map { serverAddresses.contains($0.lowercased()) } == true
    }

    public func noteServer(entry: String, address: String) {
        let host = Self.host(entry).lowercased()
        if !host.isEmpty { serverEntries.insert(host) }
        if !address.isEmpty { serverAddresses.insert(address.lowercased()) }
    }

    @discardableResult
    public func forget(_ entry: String) -> Bool {
        generation = UUID()
        preferences.forget(entry)
        update(connections)
        return !preferences.entries.contains { $0.caseInsensitiveCompare(entry.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }
    }

    @discardableResult
    public func clear() -> Bool {
        generation = UUID()
        preferences.replace(with: [])
        update(connections)
        return preferences.entries.isEmpty
    }

    public func resetRuntime() {
        generation = UUID()
        references.removeAll()
        connections.removeAll()
    }

    private func bind(entry: String, peer: RememberedPeerIdentity) -> Bool {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored = preferences.entries.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return false }
        references[stored] = Reference(instanceID: peer.instanceID, address: peer.address)
        return true
    }

    private func isServer(_ entry: String) -> Bool {
        let host = Self.host(entry).lowercased()
        return serverEntries.contains(host) || serverAddresses.contains(host)
    }

    private static func host(_ entry: String) -> String {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        return pieces.count == 2 && UInt16(pieces[1]) != nil ? String(pieces[0]) : trimmed
    }
}
