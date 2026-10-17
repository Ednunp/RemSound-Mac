import Darwin
import Foundation
import Network

// All state belongs to Session's worker. Native lookups run on a separate
// utility queue, have deadlines, and cannot deliver into a later session.
final class DirectPeerResolver {
    typealias Lookup = (String, @escaping (String?) -> Void) -> (() -> Void)
    static let retryInterval: TimeInterval = 30
    static let maximumEntries = 64
    static let maximumQueries = 8
    private struct Entry {
        let name: String
        var port: UInt16
        var host: String { PeerAddressEntry.parse(name, defaultPort: port)?.host ?? name }
        var nextAttempt: TimeInterval = 0
        var address: String?
        var query: UUID?
        var cancel: (() -> Void)?
        var reportedFailure = false
    }
    private let owner: DispatchQueue
    private let lookup: Lookup
    private let now: () -> TimeInterval
    private let monitorNetwork: Bool
    private var entries: [Entry] = []
    private var generation = UUID()
    private var monitor: NWPathMonitor?
    private var receivedInitialPath = false
    private var nextCheck: TimeInterval = 0
    var resolved: ((String, Endpoint) -> Void)?
    var unavailable: ((String) -> Void)?
    private var port: UInt16 = Wire.audioPort

    init(owner: DispatchQueue, monitorNetwork: Bool = true,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        lookup: @escaping Lookup = { DNSAddressLookup.start($0, completion: $1) }) {
        self.owner = owner
        self.monitorNetwork = monitorNetwork
        self.now = now
        self.lookup = lookup
    }

    func start(_ names: [String], port: UInt16) {
        stop()
        self.port = port
        var seen = Set<String>()
        entries = names.prefix(Self.maximumEntries).compactMap { raw in
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = PeerAddressEntry.parse(name, defaultPort: port)
            let maximumBytes = parsed == nil ? PeerAddressEntry.maximumHostBytes : PeerAddressEntry.maximumEntryBytes
            guard !name.isEmpty, name.utf8.count <= maximumBytes,
                seen.insert(name.lowercased()).inserted else { return nil }
            return Entry(name: name, port: parsed?.port ?? port)
        }
        for index in entries.indices {
            var numeric = in_addr()
            if inet_pton(AF_INET, entries[index].host, &numeric) == 1 {
                entries[index].address = entries[index].host
                resolved?(entries[index].name, Endpoint(entries[index].host, entries[index].port))
            }
        }
        if monitorNetwork, entries.contains(where: { $0.address == nil }) {
            let current = generation
            let watcher = NWPathMonitor()
            watcher.pathUpdateHandler = { [weak self] _ in
                guard let self, self.generation == current else { return }
                guard self.receivedInitialPath else {
                    self.receivedInitialPath = true
                    return
                }
                self.networkChanged()
            }
            monitor = watcher
            watcher.start(queue: owner)
        }
        pump()
    }

    func stop() {
        generation = UUID()
        monitor?.cancel()
        monitor = nil
        receivedInitialPath = false
        for entry in entries { entry.cancel?() }
        entries.removeAll()
        nextCheck = 0
    }

    func tick() {
        guard now() >= nextCheck else { return }
        pump()
    }

    func networkChanged() {
        for index in entries.indices where entries[index].address == nil && entries[index].query == nil {
            entries[index].nextAttempt = 0
        }
        pump()
    }

    @discardableResult
    func record(name: String, address: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        if let index = entries.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            entries[index].cancel?()
            entries[index].cancel = nil
            entries[index].query = nil
            entries[index].address = address
            entries[index].port = PeerAddressEntry.parse(name, defaultPort: port)?.port ?? port
            return true
        }
        guard entries.count < Self.maximumEntries else { return false }
        entries.append(Entry(name: name, port: PeerAddressEntry.parse(name, defaultPort: port)?.port ?? port, address: address))
        return true
    }

    func redirect(address: String, to destination: String) {
        for index in entries.indices where entries[index].address == address {
            entries[index].address = destination
        }
    }

    func savedEntries(selectedAddresses: Set<String>) -> [String] {
        let names = entries.filter { $0.address == nil || selectedAddresses.contains($0.address!) }
        let covered = Set(names.compactMap(\.address))
        return names.map(\.name) + selectedAddresses.subtracting(covered).sorted()
    }

    private func pump() {
        let time = now()
        nextCheck = time + 1
        var active = entries.filter { $0.query != nil }.count
        for index in entries.indices {
            guard active < Self.maximumQueries else { break }
            guard entries[index].address == nil, entries[index].query == nil,
                entries[index].nextAttempt <= time else { continue }
            let current = generation, query = UUID(), name = entries[index].name
            entries[index].query = query
            active += 1
            let port = entries[index].port
            entries[index].cancel = lookup(entries[index].host) { [weak self] address in
                guard let self else { return }
                self.owner.async { [weak self] in
                    guard let self, self.generation == current,
                        let index = self.entries.firstIndex(where: { $0.query == query }) else { return }
                    self.entries[index].query = nil
                    self.entries[index].cancel = nil
                    if let address {
                        self.entries[index].address = address
                        self.resolved?(name, Endpoint(address, port))
                    } else {
                        self.entries[index].nextAttempt = self.now() + Self.retryInterval
                        if !self.entries[index].reportedFailure {
                            self.entries[index].reportedFailure = true
                            self.unavailable?(name)
                        }
                    }
                    self.pump()
                }
            }
        }
    }

    deinit {
        monitor?.cancel()
        for entry in entries { entry.cancel?() }
    }
}
