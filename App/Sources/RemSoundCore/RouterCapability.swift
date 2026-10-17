import Foundation
import RemSoundRuntime

final class RouterCapability {
    enum Selection: Equatable {
        case pcp(RouterGatewayRoute, epoch: UInt32)
        case natPmp(RouterGatewayRoute, externalAddress: String, epoch: UInt32)
        case upnp(RouterGatewayRoute, UPnPRouterService)
    }
    enum Outcome: Equatable { case selected(Selection), refused, unavailable, cancelled, failure(String, retryAfter: TimeInterval) }
    typealias UDPFactory = (RouterUDPExchange.Request, RouterGatewayRoute, @escaping (RouterUDPExchange.Outcome) -> Void) -> () -> Void
    typealias DiscoveryFactory = (RouterGatewayRoute, TimeInterval, @escaping (URL?) -> Void) -> () -> Void
    typealias HTTPFactory = (RouterHTTPTransport.Request, TimeInterval, @escaping (RouterHTTPTransport.Outcome) -> Void) -> () -> Void
    private let permitted: () -> Bool, clock: () -> TimeInterval, readRoute: () -> RouterGatewayRoute?
    private let udp: UDPFactory, discover: DiscoveryFactory, http: HTTPFactory, completion: (Outcome) -> Void
    init(permitted: @escaping () -> Bool, clock: @escaping () -> TimeInterval,
         route: @escaping () -> RouterGatewayRoute?, udp: @escaping UDPFactory, discover: @escaping DiscoveryFactory,
         http: @escaping HTTPFactory, completion: @escaping (Outcome) -> Void) {
        self.permitted = permitted; self.clock = clock; readRoute = route; self.udp = udp
        self.discover = discover; self.http = http; self.completion = completion
    }
    convenience init(configuration: RuntimeConfiguration, enabled: @escaping () -> Bool,
                     route: @escaping () -> RouterGatewayRoute?, udp: @escaping UDPFactory,
                     discover: @escaping DiscoveryFactory, http: @escaping HTTPFactory, completion: @escaping (Outcome) -> Void) {
        self.init(permitted: { !configuration.isIsolated && enabled() }, clock: { ProcessInfo.processInfo.systemUptime },
            route: route, udp: udp, discover: discover, http: http, completion: completion)
    }
    static let deadline: TimeInterval = 8
    private static let queryWindow: TimeInterval = 2
    private static let shortErrorLifetime: TimeInterval = 30
    private static let longErrorLifetime: TimeInterval = 1800
    private static let unsupportedVersion: UInt16 = 1
    private enum PCPError {
        static let networkFailure: UInt16 = 7, noResources: UInt16 = 8, userQuota: UInt16 = 10, excessiveRemotePeers: UInt16 = 13
        static let shortLifetime = [networkFailure, noResources, userQuota]
    }
    private enum Stage { case pcp, nat, discovery, description(URL) }
    private enum Reply { case udp(RouterUDPExchange.Outcome), discovery(URL?), http(RouterHTTPTransport.Outcome) }
    private enum Retirement { case fallback(Stage), finish(Outcome) }
    private final class Attempt {
        let stage: Stage, began: TimeInterval, budget: TimeInterval
        var retirement: Retirement?, handled = false
        private var cancellation: (() -> Void)?, cancelSent = false
        init(_ stage: Stage, began: TimeInterval, budget: TimeInterval) { self.stage = stage; self.began = began; self.budget = budget }
        func install(_ cancel: @escaping () -> Void) {
            if cancelSent { cancel() } else { cancellation = cancel }
        }
        func cancel() {
            guard !cancelSent else { return }; cancelSent = true
            let cancel = cancellation; cancellation = nil; cancel?()
        }
    }
    private var began: TimeInterval?, selectedRoute: RouterGatewayRoute?, pending: Attempt?, finished = false
    // All factories and callbacks run on the same owner queue. A factory reports once,
    // after quiescence, including cancellation; no replacement begins before that receipt.
    func start() {
        guard !finished, began == nil else { return }
        guard permitted() else { finish(.refused); return }
        let now = clock()
        guard now.isFinite else { finish(.failure("Invalid router capability clock.", retryAfter: Self.shortErrorLifetime)); return }
        began = now
        guard let route = readRoute(), route.isValid else { finish(.unavailable); return }
        selectedRoute = route; begin(.pcp)
    }
    func tick() {
        guard !finished, began != nil else { return }
        if let terminal = terminal() { retire(.finish(terminal)); return }
        guard let pending, pending.retirement == nil, clock() - pending.began >= pending.budget else { return }
        switch pending.stage {
        case .pcp: retire(.fallback(.nat))
        case .nat: retire(.fallback(.discovery))
        case .discovery, .description: retire(.finish(.unavailable))
        }
    }
    func cancel() { guard !finished else { return }; retire(.finish(.cancelled)) }
    private func terminal() -> Outcome? {
        guard permitted() else { return .refused }
        guard let began else { return nil }
        let now = clock()
        guard now.isFinite, now >= began else { return .failure("Invalid router capability clock.", retryAfter: Self.shortErrorLifetime) }
        return now - began >= Self.deadline ? .unavailable : nil
    }
    private func begin(_ stage: Stage) {
        guard !finished, pending == nil, let began, let route = selectedRoute else { return }
        if let terminal = terminal() { finish(terminal); return }
        let remaining = Self.deadline - (clock() - began)
        let budget: TimeInterval
        switch stage { case .description: budget = remaining; default: budget = min(Self.queryWindow, remaining) }
        let attempt = Attempt(stage, began: clock(), budget: budget); pending = attempt
        let reply: (Reply) -> Void = { [weak self, attempt, completion] value in
            guard !attempt.handled else { return }
            attempt.handled = true; attempt.cancel()
            guard let self else { completion(.cancelled); return }
            guard self.pending === attempt else { return }
            self.pending = nil
            if let retirement = attempt.retirement {
                switch retirement {
                case .finish(let outcome): self.finish(outcome)
                case .fallback(let stage): self.begin(stage)
                }
                return
            }
            if let terminal = self.terminal() { self.finish(terminal); return }
            self.received(value, stage: stage, route: route)
        }
        let cancel: () -> Void
        switch stage {
        case .pcp: cancel = udp(.pcpAnnounce, route) { reply(.udp($0)) }
        case .nat: cancel = udp(.natAddress, route) { reply(.udp($0)) }
        case .discovery: cancel = discover(route, budget) { reply(.discovery($0)) }
        case .description(let url):
            guard let request = RouterHTTPTransport.Request.description(location: url, gateway: route.gateway.address) else {
                reply(.http(.failure("Invalid router description URL.", mutationMayHaveOccurred: false))); return
            }
            cancel = http(request, budget) { reply(.http($0)) }
        }
        attempt.install(cancel)
    }
    private func retire(_ retirement: Retirement) {
        guard let pending else {
            if case .finish(let outcome) = retirement { finish(outcome) }; return
        }
        // Stop/permission/overall expiry supersede a stage timeout while its cancellation
        // is draining. Cancellation itself is issued once and never fabricates quiescence.
        if case .finish = retirement { pending.retirement = retirement }
        else if pending.retirement == nil { pending.retirement = retirement }
        pending.cancel()
    }
    private func received(_ reply: Reply, stage: Stage, route: RouterGatewayRoute) {
        switch (stage, reply) {
        case (.pcp, .udp(let outcome)), (.nat, .udp(let outcome)):
            let fallback: Stage
            let pcp: Bool
            if case .pcp = stage { fallback = .nat; pcp = true } else { fallback = .discovery; pcp = false }
            switch outcome {
            case .response(let response, let returnedRoute), .lateResponse(let response, let returnedRoute):
                guard returnedRoute == route, response.internalPort == 0, response.externalPort == 0 else {
                    finish(.failure("Router capability reply did not match this route/query.", retryAfter: Self.shortErrorLifetime)); return
                }
                if response.resultCode == Self.unsupportedVersion { begin(fallback); return }
                guard response.resultCode == 0 else {
                    let short = PCPError.shortLifetime.contains(response.resultCode)
                    let retry = response.lifetime > 0 ? TimeInterval(response.lifetime) : (short ? Self.shortErrorLifetime : Self.longErrorLifetime)
                    finish(.failure("Router capability refused (code \(response.resultCode)).", retryAfter: retry)); return
                }
                if pcp { finish(.selected(.pcp(route, epoch: response.epoch))); return }
                guard let address = response.externalAddress, RouterMappingPackets.ipv4(address) != nil else {
                    finish(.failure("Router external address was invalid.", retryAfter: Self.shortErrorLifetime)); return
                }
                finish(.selected(.natPmp(route, externalAddress: address, epoch: response.epoch)))
            case .unavailable: begin(fallback)
            case .timedOut(let uncertain), .cancelled(let uncertain), .failed(_, let uncertain):
                guard !uncertain else { finish(.failure("Router result has uncertain remote state; no fallback was sent.", retryAfter: Self.longErrorLifetime)); return }
                begin(fallback)
            case .refused: finish(.refused)
            }
        case (.discovery, .discovery(let location)):
            guard let location, let safe = UPnPRouterProtocol.safeURL(location, gateway: route.gateway.address) else { finish(.unavailable); return }
            begin(.description(safe))
        case (.description, .http(.description(let services))):
            let kinds = [UPnPRouterService.Kind.ip2, .ip1, .ppp1]
            let safe = services.prefix(8).filter {
                $0.gatewayAddress == route.gateway.address && UPnPRouterProtocol.safeURL($0.controlURL, gateway: route.gateway.address) != nil
            }.sorted {
                let a = kinds.firstIndex(of: $0.kind)!, b = kinds.firstIndex(of: $1.kind)!
                return a == b ? $0.controlURL.absoluteString < $1.controlURL.absoluteString : a < b
            }
            guard let service = safe.first else { finish(.unavailable); return }
            finish(.selected(.upnp(route, service)))
        case (.description, .http(.refused)): finish(.refused)
        case (.description, .http(.failure(let message, _))): finish(.failure(message, retryAfter: Self.shortErrorLifetime))
        default: finish(.failure("Router capability returned an unexpected result.", retryAfter: Self.shortErrorLifetime))
        }
    }
    private func finish(_ result: Outcome) {
        guard !finished else { return }; finished = true; completion(result)
    }
    deinit { cancel() }
}
