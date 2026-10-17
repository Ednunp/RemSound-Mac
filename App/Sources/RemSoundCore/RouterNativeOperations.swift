import Foundation
import RemSoundRuntime

final class RouterNativeOperations {
    typealias HTTPFetch = (RouterHTTPTransport.Request, TimeInterval, @escaping () -> Bool, @escaping (RouterHTTPTransport.Outcome) -> Void) -> () -> Void
    typealias Schedule = (DispatchQueue, TimeInterval, @escaping () -> Void) -> () -> Void
    private let environment: Environment
    init(queue: DispatchQueue, allowed: @escaping () -> Bool, clock: @escaping () -> TimeInterval,
         route: @escaping () -> RouterGatewayRoute?, udpTransport: @escaping (RouterGatewayRoute) throws -> RouterUDPTransport,
         discoveryTransport: @escaping (RouterGatewayRoute, RouterDiscovery.Mode) throws -> RouterUDPTransport,
         http: @escaping HTTPFetch, schedule: Schedule? = nil,
         nonce: @escaping () -> Data? = RouterUDPMapping.secureNonce, token: @escaping () -> String? = UPnPMappingCreation.secureToken) {
        environment = Environment(executor: Executor(queue), allowed: allowed, clock: clock, route: route,
            udpTransport: udpTransport, discoveryTransport: discoveryTransport, http: http, schedule: schedule ?? Self.schedule, nonce: nonce, token: token)
    }
    convenience init(runtime: RuntimeConfiguration, queue: DispatchQueue = DispatchQueue(label: "RemSound.Router", qos: .utility)) {
        self.init(queue: queue, allowed: { !runtime.isIsolated }, clock: { ProcessInfo.processInfo.systemUptime }, route: RouterGatewayRoute.read,
            udpTransport: { try NativeRouterUDPTransport(sourceAddress: $0.sourceAddress) },
            discoveryTransport: { try NativeRouterDiscoveryTransport(sourceAddress: $0.sourceAddress, mode: $1) },
            http: { request, budget, gate, reply in RouterHTTPTransport.fetch(request, permitted: gate, timeout: budget, completion: reply) },
            schedule: Self.schedule)
    }
    func make(_ operation: RouterMappingTransactions.Operation, _ permitted: @escaping () -> Bool,
              _ completion: @escaping (RouterMappingTransactions.Receipt) -> Void) -> RouterMappingTransactions.Control {
        let state = Driver(environment, operation, permitted, completion), handle = Handle(state)
        environment.executor.perform { state.start() }
        return .init(tick: handle.tick, cancel: handle.cancel)
    }
    private static func schedule(_ queue: DispatchQueue, _ interval: TimeInterval, _ pulse: @escaping () -> Void) -> () -> Void {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler(handler: pulse); timer.resume()
        return { timer.setEventHandler {}; timer.cancel() }
    }
    private final class Executor {
        let queue: DispatchQueue
        private let key = DispatchSpecificKey<UInt8>()
        init(_ queue: DispatchQueue) { self.queue = queue; queue.setSpecific(key: key, value: 1) }
        func perform(_ body: @escaping () -> Void) {
            if DispatchQueue.getSpecific(key: key) == 1 { body() } else { queue.async(execute: body) }
        }
        deinit { queue.setSpecific(key: key, value: nil) }
    }
    private final class Environment {
        let executor: Executor, allowed: () -> Bool, clock: () -> TimeInterval, route: () -> RouterGatewayRoute?
        let udpTransport: (RouterGatewayRoute) throws -> RouterUDPTransport
        let discoveryTransport: (RouterGatewayRoute, RouterDiscovery.Mode) throws -> RouterUDPTransport
        let http: HTTPFetch, schedule: Schedule, nonce: () -> Data?, token: () -> String?
        init(executor: Executor, allowed: @escaping () -> Bool, clock: @escaping () -> TimeInterval,
             route: @escaping () -> RouterGatewayRoute?, udpTransport: @escaping (RouterGatewayRoute) throws -> RouterUDPTransport,
             discoveryTransport: @escaping (RouterGatewayRoute, RouterDiscovery.Mode) throws -> RouterUDPTransport,
             http: @escaping HTTPFetch, schedule: @escaping Schedule, nonce: @escaping () -> Data?, token: @escaping () -> String?) {
            self.executor = executor; self.allowed = allowed; self.clock = clock; self.route = route
            self.udpTransport = udpTransport; self.discoveryTransport = discoveryTransport
            self.http = http; self.schedule = schedule; self.nonce = nonce; self.token = token
        }
        func assembly(_ operation: RouterMappingTransactions.Operation) -> RouterProtocolOperations {
            var expected: RouterGatewayRoute?
            switch operation {
            case .upnpCreate(let route, _, _, _): expected = route
            case .upnpMaintain(.lease(let lease), _): expected = lease.claim.route
            case .upnpMaintain(.claim(let claim), _): expected = claim.route
            default: break
            }
            return RouterProtocolOperations(clock: clock, route: { [self] in
                let selected = route(); expected = selected; return selected
            }, udp: { [self] request, selected, gate, reply in
                let owner = RouterUDPExchange(request: request, permitted: gate, clock: clock, route: {
                    guard gate(), self.route() == selected else { return nil }; return selected
                }, transport: udpTransport, completion: reply)
                let control = RouterMappingTransactions.Control(tick: owner.tick, cancel: owner.cancel)
                owner.tick(); return control
            }, discovery: { [self] selected, budget, gate, reply in
                let owner = RouterDiscovery(timeout: budget, mode: .unicast, permitted: gate, clock: clock, route: {
                    guard gate(), self.route() == selected else { return nil }; return selected
                }, transport: discoveryTransport, completion: reply)
                let control = RouterMappingTransactions.Control(tick: owner.tick, cancel: owner.cancel)
                owner.tick(); return control
            }, http: { [self] request, budget, gate, reply in
                guard gate(), let expected, route() == expected, gate() else { reply(.refused); return .init(tick: {}, cancel: {}) }
                let cancel = http(request, budget, gate) { [executor] outcome in
                    // URLSession invalidation is the raw quiescence receipt. Delivery
                    // waits for this factory to return, and always uses the owner queue.
                    executor.queue.async { reply(outcome) }
                }
                return .init(tick: {}, cancel: cancel)
            }, nonce: nonce, token: token)
        }
    }
    private final class Cancellation {
        private let lock = NSLock()
        private var cancelled = false
        func retire() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }
    private final class Handle {
        let state: Driver
        init(_ state: Driver) { self.state = state }
        func tick() { state.environment.executor.perform { [state] in state.tick() } }
        func cancel() { state.cancellation.retire(); state.environment.executor.perform { [state] in state.cancel() } }
        deinit {
            let state = self.state; state.cancellation.retire()
            state.environment.executor.perform { state.cancel() }
        }
    }
    // Exactly one finite driver belongs to each typed transaction. Cancellation
    // stops polling immediately, while raw receipt ownership survives until actual
    // resource quiescence. There is no idle timer or fabricated completion deadline.
    private final class Driver {
        private static let interval: TimeInterval = 0.02
        let environment: Environment, cancellation = Cancellation()
        private let operation: RouterMappingTransactions.Operation, permitted: () -> Bool
        private var completion: ((RouterMappingTransactions.Receipt) -> Void)?
        private var began: TimeInterval = 0, root: RouterMappingTransactions.Control?, received: RouterMappingTransactions.Receipt?
        private var rootInstalled = false, rootCancelled = false, finished = false, hasClock = false
        private var stopTimer: (() -> Void)?, timerInstalled = false, timerRetired = false
        init(_ environment: Environment, _ operation: RouterMappingTransactions.Operation, _ permitted: @escaping () -> Bool,
             _ completion: @escaping (RouterMappingTransactions.Receipt) -> Void) {
            self.environment = environment; self.operation = operation; self.permitted = permitted; self.completion = completion
        }
        private var gate: Bool {
            guard !cancellation.isCancelled, environment.allowed(), permitted() else { return false }
            guard hasClock else { return true }
            let now = environment.clock()
            return now.isFinite && now >= began && now - began < RouterUDPExchange.deadline
        }
        func start() {
            guard !finished else { return }
            if cancellation.isCancelled { finish(.cancelled); return }
            guard gate else { finish(.refused); return }
            guard operation.isValid else { finish(.blocked("Invalid native router operation.")); return }
            began = environment.clock()
            guard began.isFinite else { finish(.blocked("Invalid native router driver clock.")); return }
            hasClock = true
            let assembly = environment.assembly(operation)
            let control = assembly.make(operation, { [self] in gate }) { [self] receipt in
                guard received == nil, !finished else { return }; received = receipt
                if rootInstalled { consume() }
            }
            root = control; rootInstalled = true
            if cancellation.isCancelled { cancelRoot() }
            consume()
            guard !finished else { return }
            guard gate else { cancel(); return }
            let stop = environment.schedule(environment.executor.queue, Self.interval) { [self] in
                environment.executor.perform { [self] in tick() }
            }
            stopTimer = stop; timerInstalled = true
            if timerRetired { stop(); stopTimer = nil }
            if !gate { cancel() }
        }
        func tick() {
            guard !finished else { return }
            let now = environment.clock()
            if !gate || !now.isFinite || now < began || now - began >= RouterUDPExchange.deadline { cancel(); return }
            root?.tick()
        }
        func cancel() {
            guard !finished else { return }
            cancellation.retire(); retireTimer(); cancelRoot()
        }
        private func cancelRoot() {
            guard rootInstalled, !rootCancelled else { return }; rootCancelled = true; root?.cancel()
        }
        private func retireTimer() {
            guard !timerRetired else { return }; timerRetired = true
            if timerInstalled { let stop = stopTimer; stopTimer = nil; stop?() }
        }
        private func consume() {
            guard rootInstalled, let receipt = received, !finished else { return }
            received = nil; finish(receipt)
        }
        private func finish(_ receipt: RouterMappingTransactions.Receipt) {
            guard !finished else { return }; finished = true
            retireTimer(); cancelRoot(); root = nil
            let callback = completion; completion = nil; callback?(receipt)
        }
    }
}
