import Foundation
import Network

/// Discovery controls selection intent only; it never establishes authenticated audio identity.
struct DirectPeerSelectionPolicy {
    static let emptyInstanceID = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
    static let unreachableGrace: TimeInterval = 6
    static let moveCooldown: TimeInterval = 15

    struct Discovery {
        let instanceID: UUID
        let endpoint: Endpoint
        let name: String
        let seen: TimeInterval
    }
    struct Resolution: Equatable {
        let instanceID: UUID
        let endpoint: Endpoint
        let name: String
    }
    private var unreachableSince: [UUID: TimeInterval] = [:]
    private var lastMove: [UUID: TimeInterval] = [:]

    mutating func resolve(instanceID: UUID?, typedEntry: String?, pinned: Endpoint,
                         pinResponds: Bool, discovered: [Discovery], locked: Bool,
                         now: TimeInterval) -> Resolution? {
        guard now.isFinite else { return nil }
        if locked {
            if let instanceID { unreachableSince.removeValue(forKey: instanceID) }
            return nil
        }
        let current = discovered.filter {
            $0.instanceID != Self.emptyInstanceID && now >= $0.seen && now - $0.seen <= Wire.discoveryExpiry
        }
        let candidate: Discovery
        if let instanceID {
            guard let found = latest(current.filter { $0.instanceID == instanceID }) else { return nil }
            candidate = found
        } else {
            let exact = current.filter { $0.endpoint == pinned }
            if Set(exact.map(\.instanceID)).count == 1, let found = latest(exact) {
                candidate = found
            } else {
                guard let typedEntry else { return nil }
                let text = typedEntry.trimmingCharacters(in: .whitespacesAndNewlines)
                let pieces = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let host = pieces.count == 2 && UInt16(pieces[1]) != nil ? String(pieces[0]) : text
                guard !host.isEmpty, IPv4Address(host) == nil, !host.contains(":") else { return nil }
                let named = current.filter { $0.name.caseInsensitiveCompare(host) == .orderedSame }
                guard Set(named.map(\.instanceID)).count == 1, let found = latest(named) else { return nil }
                candidate = found
            }
        }
        let identity = candidate.instanceID
        if candidate.endpoint == pinned || pinResponds {
            unreachableSince.removeValue(forKey: identity)
            return instanceID == identity ? nil : Resolution(instanceID: identity, endpoint: pinned, name: candidate.name)
        }
        // Only a typed unresolved identity may immediately correct a stale DNS result.
        if instanceID != nil {
            guard let since = unreachableSince[identity], now >= since else {
                unreachableSince[identity] = now
                return nil
            }
            guard now - since >= Self.unreachableGrace else { return nil }
        }
        if let last = lastMove[identity], now - last < Self.moveCooldown { return nil }
        lastMove[identity] = now
        unreachableSince.removeValue(forKey: identity)
        return Resolution(instanceID: identity, endpoint: candidate.endpoint, name: candidate.name)
    }

    mutating func forget(_ instanceID: UUID?) {
        guard let instanceID else { return }
        unreachableSince.removeValue(forKey: instanceID)
        lastMove.removeValue(forKey: instanceID)
    }

    mutating func reset() {
        unreachableSince.removeAll()
        lastMove.removeAll()
    }

    private func latest(_ entries: [Discovery]) -> Discovery? {
        entries.max {
            if $0.seen != $1.seen { return $0.seen < $1.seen }
            if $0.endpoint.address != $1.endpoint.address { return $0.endpoint.address > $1.endpoint.address }
            return $0.endpoint.port > $1.endpoint.port
        }
    }
}
