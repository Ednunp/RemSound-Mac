import Foundation

final class RouterProtocolOperations {
    typealias Control = RouterMappingTransactions.Control
    typealias UDPFactory = (RouterUDPExchange.Request, RouterGatewayRoute, @escaping () -> Bool, @escaping (RouterUDPExchange.Outcome) -> Void) -> Control
    typealias DiscoveryFactory = (RouterGatewayRoute, TimeInterval, @escaping () -> Bool, @escaping (RouterDiscovery.Outcome) -> Void) -> Control
    typealias HTTPFactory = (RouterHTTPTransport.Request, TimeInterval, @escaping () -> Bool, @escaping (RouterHTTPTransport.Outcome) -> Void) -> Control
    private let clock: () -> TimeInterval, route: () -> RouterGatewayRoute?, nonce: () -> Data?, token: () -> String?
    private let udp: UDPFactory, discovery: DiscoveryFactory, http: HTTPFactory
    init(clock: @escaping () -> TimeInterval, route: @escaping () -> RouterGatewayRoute?, udp: @escaping UDPFactory,
         discovery: @escaping DiscoveryFactory, http: @escaping HTTPFactory,
         nonce: @escaping () -> Data? = RouterUDPMapping.secureNonce, token: @escaping () -> String? = UPnPMappingCreation.secureToken) {
        self.clock = clock; self.route = route; self.udp = udp; self.discovery = discovery; self.http = http
        self.nonce = nonce; self.token = token
    }
    func make(_ operation: RouterMappingTransactions.Operation, _ permitted: @escaping () -> Bool,
              _ completion: @escaping (RouterMappingTransactions.Receipt) -> Void) -> Control {
        let state = State(operation: operation, permitted: permitted, clock: clock, route: route, udp: udp,
            discovery: discovery, http: http, nonce: nonce, token: token, completion: completion)
        let handle = Handle(state); state.start()
        return .init(tick: handle.tick, cancel: handle.cancel)
    }
    // Copies of Control share this handle. Dropping the last copy retires its visit;
    // receipt state remains alive until the injected transport really quiesces.
    private final class Handle {
        let state: State
        init(_ state: State) { self.state = state }
        func tick() { state.tick() }
        func cancel() { state.cancel() }
        deinit { state.cancel() }
    }
    private final class State {
        private final class Raw {
            var control: Control?, installed = false, received = false, delivery: (() -> Void)?
            private var cancelSent = false
            func install(_ value: Control) { control = value; installed = true; if cancelSent { value.cancel() } }
            func cancel() { guard !cancelSent else { return }; cancelSent = true; control?.cancel() }
            func retire() { cancel(); control = nil }
        }
        let operation: RouterMappingTransactions.Operation, permitted: () -> Bool, clock: () -> TimeInterval
        let route: () -> RouterGatewayRoute?, udp: UDPFactory, discovery: DiscoveryFactory, http: HTTPFactory
        let nonce: () -> Data?, token: () -> String?, completion: (RouterMappingTransactions.Receipt) -> Void
        private var root: Control?, raw: Raw?, finished = false, ticking = false
        init(operation: RouterMappingTransactions.Operation, permitted: @escaping () -> Bool, clock: @escaping () -> TimeInterval,
             route: @escaping () -> RouterGatewayRoute?, udp: @escaping UDPFactory, discovery: @escaping DiscoveryFactory,
             http: @escaping HTTPFactory, nonce: @escaping () -> Data?, token: @escaping () -> String?,
             completion: @escaping (RouterMappingTransactions.Receipt) -> Void) {
            self.operation = operation; self.permitted = permitted; self.clock = clock; self.route = route
            self.udp = udp; self.discovery = discovery; self.http = http; self.nonce = nonce; self.token = token; self.completion = completion
        }
        func start() {
            guard !finished else { return }
            guard permitted() else { finish(.refused); return }
            guard operation.isValid else { finish(.blocked("Invalid protocol dispatch operation.")); return }
            switch operation {
            case .capability:
                let owner = RouterCapability(permitted: permitted, clock: clock, route: route,
                    udp: { [self] request, selected, reply in udpStep(request, selected, reply) },
                    discover: { [self] selected, budget, reply in discoveryStep(selected, budget, reply) },
                    http: { [self] request, budget, reply in httpStep(request, budget, reply) },
                    completion: { [self] in finish(.capability($0)) })
                root = .init(tick: owner.tick, cancel: owner.cancel); owner.start()
            case .udp(let intent):
                let owner = RouterUDPMapping(intent: intent, permitted: permitted, clock: clock, nonce: nonce,
                    exchange: { [self] request, selected, reply in udpStep(request, selected, reply) },
                    completion: { [self] in finish(.udp($0)) })
                root = .init(tick: owner.tick, cancel: owner.cancel); owner.start()
            case .upnpCreate(let selected, let service, let port, let lifetime):
                let owner = UPnPMappingCreation(route: selected, service: service, internalPort: port, lifetime: lifetime,
                    permitted: permitted, clock: clock, token: token,
                    http: { [self] request, budget, reply in httpStep(request, budget, reply) },
                    completion: { [self] in finish(.created($0)) })
                root = .init(tick: owner.tick, cancel: owner.cancel); owner.start()
            case .upnpMaintain(let target, let action):
                let owner: UPnPMappingMaintenance
                let factory: RouterCapability.HTTPFactory = { [self] request, budget, reply in httpStep(request, budget, reply) }
                let done: (UPnPMappingMaintenance.Outcome) -> Void = { [self] in finish(.maintained($0)) }
                switch target {
                case .lease(let lease): owner = UPnPMappingMaintenance(lease: lease, action: action, permitted: permitted, clock: clock, http: factory, completion: done)
                case .claim(let claim): owner = UPnPMappingMaintenance(claim: claim, permitted: permitted, clock: clock, http: factory, completion: done)
                }
                root = .init(tick: owner.tick, cancel: owner.cancel); owner.start()
            }
        }
        func tick() {
            guard !finished, !ticking else { return }; ticking = true; defer { ticking = false }
            let current = raw; current?.control?.tick()
            guard !finished else { return }; root?.tick()
        }
        func cancel() { guard !finished else { return }; root?.cancel() }
        private func udpStep(_ request: RouterUDPExchange.Request, _ selected: RouterGatewayRoute,
                             _ reply: @escaping (RouterUDPExchange.Outcome) -> Void) -> () -> Void {
            step(refused: .refused, factory: { [self] callback in udp(request, selected, permitted, callback) }, reply: reply)
        }
        private func discoveryStep(_ selected: RouterGatewayRoute, _ budget: TimeInterval,
                                   _ reply: @escaping (URL?) -> Void) -> () -> Void {
            step(refused: RouterDiscovery.Outcome.refused,
                factory: { [self] callback in discovery(selected, budget, permitted, callback) },
                reply: { outcome in if case .found(let location) = outcome { reply(location) } else { reply(nil) } })
        }
        private func httpStep(_ request: RouterHTTPTransport.Request, _ budget: TimeInterval,
                              _ reply: @escaping (RouterHTTPTransport.Outcome) -> Void) -> () -> Void {
            step(refused: .refused, factory: { [self] callback in http(request, budget, permitted, callback) }, reply: reply)
        }
        // Each raw factory reports after transport quiescence. Buffer a synchronous
        // report until the factory returns its exact Control, then retire it before a
        // real protocol owner can construct its next stage.
        private func step<Value>(refused: Value, factory: (@escaping (Value) -> Void) -> Control,
                                 reply: @escaping (Value) -> Void) -> () -> Void {
            guard !finished, permitted(), raw == nil else { reply(refused); return {} }
            let slot = Raw(); raw = slot
            let control = factory { [self, slot] value in
                guard raw === slot, !slot.received else { return }; slot.received = true
                slot.delivery = { reply(value) }
                if slot.installed { consume(slot) }
            }
            slot.install(control)
            if slot.delivery != nil { consume(slot) }
            return { slot.cancel() }
        }
        private func consume(_ slot: Raw) {
            guard raw === slot, slot.installed, let delivery = slot.delivery else { return }
            slot.delivery = nil; slot.retire(); raw = nil; delivery()
        }
        private func finish(_ receipt: RouterMappingTransactions.Receipt) {
            guard !finished else { return }; finished = true; root = nil; completion(receipt)
        }
    }
}
