import Foundation

// Session-worker policy only. Keys identify independent sources, never inferred shared host clocks.
final class PluginSourceClock<Key: Hashable> {
    static var maximumSources: Int { 64 }
    static var maximumFrames: Int { Bridge.maxAudioBytes / (MemoryLayout<Float>.size * Bridge.channels) }
    static var driverStaleAfter: TimeInterval { 0.250 }
    static var sourceExpiry: TimeInterval { 2 }

    enum Role: Equatable { case driver, secondary, refused, retired, closed }
    enum Failure: Equatable {
        case staleGeneration, invalidFrames, capacity, closed, invalidClock, unknownSource, staleVisit, orderExhausted
    }
    fileprivate final class Owner: Equatable {
        static func == (lhs: Owner, rhs: Owner) -> Bool { lhs === rhs }
    }
    struct Visit: Equatable {
        let generation: UUID, key: Key, order: UInt64
        fileprivate let owner: Owner
    }
    struct Receipt {
        let role: Role, failure: Failure?
        let visit: Visit?, driver: Visit?, retired: [Visit]
        let sourceCount: Int, driverChanged: Bool
        var singleSourceDirect: Bool { role == .driver && sourceCount == 1 }
    }
    private struct Entry { let order: UInt64; var lastBlock: TimeInterval }
    private let owner = Owner()
    private let generation: UUID
    private var entries: [Key: Entry] = [:], driver: Key?
    private var order: UInt64 = 0
    private var lastTime: TimeInterval?
    private(set) var isClosed = false
    var count: Int { entries.count }
    var currentDriver: Visit? { driver.flatMap { visit($0) } }

    init(generation: UUID) {
        self.generation = generation
        entries.reserveCapacity(Self.maximumSources)
    }
    func observe(_ key: Key, generation proposed: UUID, frames: Int, now: TimeInterval) -> Receipt {
        let before = currentDriver
        guard proposed == generation else { return receipt(.refused, .staleGeneration, before: before) }
        guard !isClosed else { return receipt(.closed, .closed, before: before) }
        guard (1...Self.maximumFrames).contains(frames) else {
            return receipt(.refused, .invalidFrames, before: before)
        }
        guard validTime(now) else {
            let retired = drain(); isClosed = true
            return receipt(.closed, .invalidClock, retired: retired, before: before)
        }
        lastTime = now
        // Retirement receipts are bounded and precede reuse of a returning key's memory lane.
        let expired = entries.filter { now - $0.value.lastBlock >= Self.sourceExpiry }
            .sorted { $0.value.order < $1.value.order }.map { makeVisit($0.key, $0.value.order) }
        for item in expired { entries.removeValue(forKey: item.key) }
        electDriver()
        if entries[key] == nil {
            guard entries.count < Self.maximumSources else {
                return receipt(.refused, .capacity, retired: expired, before: before)
            }
            guard order < UInt64.max else {
                return receipt(.refused, .orderExhausted, retired: expired, before: before)
            }
            order += 1
            entries[key] = Entry(order: order, lastBlock: now)
        } else { entries[key]?.lastBlock = now }
        electDriver()
        if let previous = driver, previous != key, let state = entries[previous],
            now - state.lastBlock > Self.driverStaleAfter {
            driver = key
        }
        return receipt(driver == key ? .driver : .secondary, key: key, retired: expired, before: before)
    }
    func retire(_ proposed: Visit) -> Receipt {
        let before = currentDriver
        guard proposed.generation == generation else { return receipt(.refused, .staleGeneration, before: before) }
        guard !isClosed else { return receipt(.closed, .closed, before: before) }
        guard let existing = entries[proposed.key] else {
            return receipt(.refused, .unknownSource, before: before)
        }
        guard proposed.owner == owner, existing.order == proposed.order else {
            return receipt(.refused, .staleVisit, before: before)
        }
        entries.removeValue(forKey: proposed.key)
        electDriver()
        return receipt(.retired, retired: [makeVisit(proposed.key, existing.order)], before: before)
    }
    func stop(generation proposed: UUID) -> Receipt {
        let before = currentDriver
        guard proposed == generation else { return receipt(.refused, .staleGeneration, before: before) }
        let retired = drain(); isClosed = true
        return receipt(.closed, retired: retired, before: before)
    }
    private func validTime(_ now: TimeInterval) -> Bool {
        guard now.isFinite, now >= 0, lastTime.map({ now >= $0 }) ?? true else { return false }
        let expiry = now + Self.sourceExpiry, takeover = now + Self.driverStaleAfter
        return expiry.isFinite && expiry > now && takeover.isFinite && takeover > now
    }
    private func electDriver() {
        if let driver, entries[driver] != nil { return }
        driver = entries.min { $0.value.order < $1.value.order }?.key
    }
    private func makeVisit(_ key: Key, _ order: UInt64) -> Visit {
        Visit(generation: generation, key: key, order: order, owner: owner)
    }
    private func visit(_ key: Key) -> Visit? { entries[key].map { makeVisit(key, $0.order) } }
    private func drain() -> [Visit] {
        let retired = entries.sorted { $0.value.order < $1.value.order }.map { makeVisit($0.key, $0.value.order) }
        entries.removeAll(keepingCapacity: true); driver = nil
        return retired
    }
    private func receipt(_ role: Role, _ failure: Failure? = nil, key: Key? = nil,
        retired: [Visit] = [], before: Visit?) -> Receipt {
        Receipt(role: role, failure: failure, visit: key.flatMap { visit($0) }, driver: currentDriver,
            retired: retired, sourceCount: entries.count, driverChanged: before != currentDriver)
    }
}
