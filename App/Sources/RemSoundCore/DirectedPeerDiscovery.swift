import Darwin
import Foundation
import Network

/// Session-owned discovery hints; this resolves targets but never selects peers or sends packets.
final class DirectedPeerDiscovery {
    typealias Lookup = DirectPeerResolver.Lookup
    static let maximumHints = 64
    static let maximumHeardSources = 64
    static let maximumQueries = 8
    static let heardSourceExpiry: TimeInterval = 30
    static let refreshInterval: TimeInterval = 30
    private struct Entry {
        let host: String
        var address: String?
        var nextAttempt: TimeInterval = 0
        var query: UUID?
        var cancel: (() -> Void)?
    }
    private let owner: DispatchQueue
    private let lookup: Lookup
    private let now: () -> TimeInterval
    private let isServer: (String, String?) -> Bool
    private let monitorNetwork: Bool
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var heard: [String: TimeInterval] = [:]
    private var generation = UUID()
    private var active = false
    private var monitor: NWPathMonitor?
    private var receivedInitialPath = false

    init(owner: DispatchQueue, monitorNetwork: Bool = true,
         now: @escaping () -> TimeInterval = { Date.timeIntervalSinceReferenceDate },
         lookup: @escaping Lookup = { DNSAddressLookup.start($0, completion: $1) },
         isServer: @escaping (String, String?) -> Bool = { _, _ in false }) {
        self.owner = owner
        self.monitorNetwork = monitorNetwork
        self.now = now
        self.lookup = lookup
        self.isServer = isServer
    }

    func start() {
        stop()
        active = true
        guard monitorNetwork else { return }
        let current = generation, watcher = NWPathMonitor()
        watcher.pathUpdateHandler = { [weak self] _ in
            guard let self, self.active, self.generation == current else { return }
            guard self.receivedInitialPath else { self.receivedInitialPath = true; return }
            self.networkChanged()
        }
        monitor = watcher
        watcher.start(queue: owner)
    }

    func stop() {
        active = false
        generation = UUID()
        monitor?.cancel()
        monitor = nil
        receivedInitialPath = false
        for entry in entries.values { entry.cancel?() }
        entries.removeAll()
        order.removeAll()
        heard.removeAll()
    }

    func update(remembered: [String], addresses: [String], at time: TimeInterval) {
        guard active, time.isFinite else { return }
        var desired: [String: String] = [:], nextOrder: [String] = []
        // Bound both input scans and the combined book; selected/manual numeric routes take priority.
        for raw in Array(addresses.prefix(Self.maximumHints)) + Array(remembered.prefix(Self.maximumHints)) {
            guard desired.count < Self.maximumHints,
                  let parsed = PeerAddressEntry.parse(raw, defaultPort: Wire.audioPort),
                  !isServer(parsed.host, nil) else { continue }
            let key = parsed.host.lowercased()
            guard desired[key] == nil else { continue }
            desired[key] = parsed.host
            nextOrder.append(key)
        }
        for key in entries.keys where desired[key] == nil {
            entries[key]?.cancel?()
            entries.removeValue(forKey: key)
        }
        for key in nextOrder where entries[key] == nil {
            let host = desired[key]!
            var numeric = in_addr()
            let isNumeric = inet_pton(AF_INET, host, &numeric) == 1
            if isNumeric, !Self.validAddress(host) { continue }
            entries[key] = Entry(host: host, address: isNumeric ? host : nil,
                                 nextAttempt: isNumeric ? .infinity : 0)
        }
        order = nextOrder.filter { entries[$0] != nil }
        pump(at: time)
    }

    func noteHeard(_ address: String, at time: TimeInterval) {
        guard active, time.isFinite, Self.validAddress(address), !isServer(address, address) else { return }
        heard[address] = time
        if heard.count > Self.maximumHeardSources,
           let oldest = heard.min(by: { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }) {
            heard.removeValue(forKey: oldest.key)
        }
    }

    func targets(at time: TimeInterval) -> [String] {
        guard active, time.isFinite else { return [] }
        pump(at: time)
        heard = heard.filter { time >= $0.value && time - $0.value <= Self.heardSourceExpiry }
        var result = Set(order.compactMap { key -> String? in
            guard let entry = entries[key], let address = entry.address,
                  !isServer(entry.host, address) else { return nil }
            return address
        })
        result.formUnion(heard.keys.filter { !isServer($0, $0) })
        return result.sorted()
    }

    func networkChanged() {
        guard active else { return }
        for key in order {
            guard var entry = entries[key], entry.nextAttempt != .infinity else { continue }
            entry.cancel?()
            entry.cancel = nil
            entry.query = nil
            entry.nextAttempt = 0
            entries[key] = entry
        }
        pump(at: now())
    }

    private func pump(at time: TimeInterval) {
        guard active, time.isFinite else { return }
        var pending = entries.values.filter { $0.query != nil }.count
        for key in order {
            guard var entry = entries[key] else { continue }
            if isServer(entry.host, entry.address) {
                entry.cancel?()
                entry.cancel = nil
                entry.query = nil
                entry.address = nil
                entries[key] = entry
                continue
            }
            guard pending < Self.maximumQueries, entry.query == nil, entry.nextAttempt <= time else { continue }
            let current = generation, query = UUID()
            entry.query = query
            entries[key] = entry
            pending += 1
            entries[key]?.cancel = lookup(entry.host) { [weak self] address in
                guard let self else { return }
                self.owner.async { [weak self] in
                    guard let self, self.active, self.generation == current,
                          var entry = self.entries[key], entry.query == query else { return }
                    entry.query = nil
                    entry.cancel = nil
                    entry.address = address.flatMap { Self.validAddress($0) && !self.isServer(entry.host, $0) ? $0 : nil }
                    entry.nextAttempt = self.now() + Self.refreshInterval
                    self.entries[key] = entry
                    self.pump(at: self.now())
                }
            }
        }
    }

    private static func validAddress(_ address: String) -> Bool {
        var numeric = in_addr()
        guard inet_pton(AF_INET, address, &numeric) == 1 else { return false }
        let firstOctet = UInt32(bigEndian: numeric.s_addr) >> 24
        return firstOctet > 0 && firstOctet < 224
    }

    deinit {
        monitor?.cancel()
        for entry in entries.values { entry.cancel?() }
    }
}
