import Foundation

/// Discovery identity, before any user-friendly alias is applied.
public struct RememberedPeerIdentity: Equatable {
    public let instanceID: UUID
    public let advertisedName: String
    public let address: String

    public init(instanceID: UUID, advertisedName: String, address: String) {
        self.instanceID = instanceID
        self.advertisedName = advertisedName
        self.address = address
    }
}

/// Machine-wide peer entries. The connection owner serializes edits; profiles never own this list.
public final class RememberedPeerPreferences {
    private static let key = "rememberedPeerBook"
    private let settings: SettingsStore

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public var entries: [String] {
        Self.normalized(settings.dictionary(forKey: Self.key)?["entries"] as? [String] ?? [])
    }

    public func replace(with entries: [String]) {
        // Keep the list and migration marker in one write, including an explicitly empty list.
        settings.set(["entries": Self.normalized(entries), "migrated": true], forKey: Self.key)
    }

    public func remember(_ entry: String) {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let updated = Self.normalized(entries + [trimmed])
        guard updated != entries else { return }
        replace(with: updated)
    }

    public func forget(_ entry: String) {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        replace(with: entries.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame })
    }

    /// Import a real legacy list once; selected addresses and aliases are not legacy remembered lists.
    public func migrateLegacy(_ legacyEntries: [String]) {
        guard settings.dictionary(forKey: Self.key)?["migrated"] as? Bool != true else { return }
        let legacy = Self.normalized(legacyEntries)
        guard !legacy.isEmpty else { return }
        replace(with: entries + legacy)
    }

    public static func entry(for peer: RememberedPeerIdentity, among peers: [RememberedPeerIdentity],
                             isKnownServer: Bool = false) -> String? {
        guard !isKnownServer else { return nil }
        let name = peer.advertisedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = peer.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        let collision = peers.contains {
            $0.instanceID != peer.instanceID
                && $0.advertisedName.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(name) == .orderedSame
        }
        return name.isEmpty || name.caseInsensitiveCompare(address) == .orderedSame || collision ? address : name
    }

    private static func normalized(_ entries: [String]) -> [String] {
        var result: [String] = []
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !result.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { continue }
            result.append(trimmed)
        }
        return result
    }
}
