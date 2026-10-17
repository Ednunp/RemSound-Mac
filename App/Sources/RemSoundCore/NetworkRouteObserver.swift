import Foundation

// All state and deliveries belong to the session queue. OS interface/type
// lookups run elsewhere so a slow diagnostic cannot stall audio sending.
final class NetworkRouteObserver {
    private static let refreshInterval: TimeInterval = 5
    private let owner: DispatchQueue
    private let lookupQueue = DispatchQueue(label: "RemSound route observations", qos: .utility)
    private let read: (Endpoint) -> NetworkRoute?
    private var generation: UInt64 = 0
    private var nextCheck: TimeInterval = 0
    private var routes: [Endpoint: String] = [:]
    private(set) var isPending = false

    init(owner: DispatchQueue, read: @escaping (Endpoint) -> NetworkRoute? = NetworkRoute.read) {
        self.owner = owner
        self.read = read
    }

    func invalidate() {
        dispatchPrecondition(condition: .onQueue(owner))
        generation &+= 1
        routes.removeAll()
        nextCheck = 0
        // Keep a blocked lookup counted across stop/restart; never accumulate
        // concurrent jobs or publish its result into a new session generation.
    }

    func request(_ endpoints: [Endpoint], now: TimeInterval,
        onChange: @escaping (Endpoint, String) -> Void) {
        dispatchPrecondition(condition: .onQueue(owner))
        guard !endpoints.isEmpty, !isPending, now >= nextCheck else { return }
        routes = routes.filter { endpoints.contains($0.key) }
        nextCheck = now + Self.refreshInterval
        isPending = true
        let requestedGeneration = generation
        let owner = self.owner, read = self.read
        lookupQueue.async { [weak self] in
            let observed = endpoints.map { ($0, read($0)?.description ?? "unavailable") }
            owner.async { [weak self] in
                guard let self else { return }
                self.isPending = false
                guard self.generation == requestedGeneration else { return }
                for (endpoint, route) in observed where self.routes[endpoint] != route {
                    self.routes[endpoint] = route
                    onChange(endpoint, route)
                }
            }
        }
    }
}
