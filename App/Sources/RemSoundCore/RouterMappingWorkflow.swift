import Foundation

final class RouterMappingWorkflow {
    struct Grant {
        let id: UUID, externalAddress: String, externalPort: UInt16, epochChanged: Bool
        private let began: TimeInterval, validUntil: TimeInterval
        fileprivate init(id: UUID, address: String, port: UInt16, began: TimeInterval, validUntil: TimeInterval, epochChanged: Bool) {
            self.id = id; externalAddress = address; externalPort = port
            self.began = began; self.validUntil = validUntil; self.epochChanged = epochChanged
        }
        func remainingLifetime(at now: TimeInterval) -> TimeInterval {
            guard now.isFinite, began.isFinite, validUntil.isFinite, now >= began else { return 0 }
            return max(0, validUntil - now)
        }
    }
    enum Outcome {
        case mapped(Grant, RouterMappingTransactions.Result), finished(RouterMappingTransactions.Result)
        case cancelled(RouterMappingTransactions.Result?), refused, blocked(String)
    }
    private let state: State
    var unresolvedEvidence: [RouterMappingTransactions.Evidence] { state.lane.unresolvedEvidence }
    var current: Grant? { state.current }
    var hasUnresolvedState: Bool { state.unresolved }
    var retryNotBefore: TimeInterval? { state.retryNotBefore }
    init(allowed: @escaping () -> Bool, enabled: @escaping () -> Bool, clock: @escaping () -> TimeInterval,
         factory: @escaping RouterMappingTransactions.Factory) {
        state = State(allowed: allowed, enabled: enabled, clock: clock, factory: factory)
    }
    func open(internalPort: UInt16, lifetime: UInt32, completion: @escaping (Outcome) -> Void) {
        state.request(.open(internalPort, lifetime), completion)
    }
    func renew(_ id: UUID, lifetime: UInt32, completion: @escaping (Outcome) -> Void) { state.request(.renew(id, lifetime), completion) }
    func remove(_ id: UUID, completion: @escaping (Outcome) -> Void) { state.request(.remove(id), completion) }
    func recover(_ id: UUID, completion: @escaping (Outcome) -> Void) { state.request(.recover(id), completion) }
    func stop(completion: @escaping (Outcome) -> Void) { state.request(.stop, completion) }
    func wake(completion: @escaping (Outcome) -> Void) { state.wake(completion) }
    func shutdown(completion: @escaping (Outcome) -> Void = { _ in }) { state.shutdown(completion) }
    func tick() { state.lane.tick() }
    deinit { state.shutdown { _ in } }

    // The backend serial executor owns requests, receipts and this memory-only book.
    // It retains one lane for its lifetime: unresolved evidence cannot be reset by
    // reconstructing a lane. Recovery must prove the matching remote state.
    private final class State {
        private static let maximumRequestedLifetime: UInt32 = 604800
        private final class Permission { var current: () -> Bool = { false } }
        private enum Owned {
            case udp(RouterUDPMapping.Lease), upnp(UPnPMappingCreation.Lease), claim(UPnPMappingCreation.Claim)
            var removal: RouterMappingTransactions.Operation {
                switch self {
                case .udp(let lease): return .udp(.remove(lease))
                case .upnp(let lease): return .upnpMaintain(.lease(lease), .remove)
                case .claim(let claim): return .upnpMaintain(.claim(claim), .remove)
                }
            }
            func matches(_ target: RouterMappingTransactions.RecoveryTarget?) -> Bool {
                switch (self, target) {
                case (.udp(let lease), .udp(let exact)): return lease == exact
                case (.upnp(let lease), .upnpLease(let exact)): return lease == exact
                case (.claim(let claim), .upnpClaim(let exact)): return claim == exact
                case (.upnp(let lease), .upnpClaim(let claim)): return lease.claim == claim
                case (.claim(let claim), .upnpLease(let lease)): return claim == lease.claim
                default: return false
                }
            }
            func grant(_ id: UUID, epochChanged: Bool) -> Grant? {
                switch self {
                case .udp(let lease):
                    return .init(id: id, address: lease.externalAddress, port: lease.externalPort, began: lease.obtainedAt, validUntil: lease.validUntil, epochChanged: epochChanged)
                case .upnp(let lease):
                    return .init(id: id, address: lease.claim.externalAddress, port: lease.claim.externalPort, began: lease.claim.requestStarted, validUntil: lease.validUntil, epochChanged: epochChanged)
                case .claim: return nil
                }
            }
        }
        enum Intent { case open(UInt16, UInt32), renew(UUID, UInt32), remove(UUID), recover(UUID), stop, shutdown }
        private final class Request {
            let intent: Intent, completion: (Outcome) -> Void
            var retired = false
            init(_ intent: Intent, _ completion: @escaping (Outcome) -> Void) { self.intent = intent; self.completion = completion }
        }
        private final class Stage {
            var id: UUID?, installed = false, delivered: RouterMappingTransactions.Result?, handled = false, cancel = false
        }
        let lane: RouterMappingTransactions
        private let permission: Permission
        let allowed: () -> Bool, enabled: () -> Bool, clock: () -> TimeInterval
        private var active: Request?, desired: Request?, stage: Stage?, closing = false
        private var book: (id: UUID, owned: Owned, epochChanged: Bool)?
        private var lastOpen: (UInt16, UInt32)?
        var unresolved = false
        private var localUnresolved = false
        private(set) var retryNotBefore: TimeInterval?
        var current: Grant? {
            guard !unresolved, !closing, let book, let grant = book.owned.grant(book.id, epochChanged: book.epochChanged),
                  grant.remainingLifetime(at: clock()) > 0 else { return nil }
            return grant
        }
        init(allowed: @escaping () -> Bool, enabled: @escaping () -> Bool, clock: @escaping () -> TimeInterval,
             factory: @escaping RouterMappingTransactions.Factory) {
            self.allowed = allowed; self.enabled = enabled; self.clock = clock
            let permission = Permission(); self.permission = permission
            lane = RouterMappingTransactions(allowed: allowed, enabled: enabled, clock: clock, factory: { operation, gate, reply in
                let requestIsCurrent = permission.current
                return factory(operation, { gate() && (operation.isCleanup || requestIsCurrent()) }, reply)
            })
        }
        func request(_ intent: Intent, _ completion: @escaping (Outcome) -> Void) {
            guard !closing else { completion(.refused); return }
            enqueue(Request(intent, completion))
        }
        func wake(_ completion: @escaping (Outcome) -> Void) {
            guard let lastOpen else { request(.stop, completion); return }
            request(.open(lastOpen.0, lastOpen.1), completion)
        }
        func shutdown(_ completion: @escaping (Outcome) -> Void) {
            guard !closing else { completion(.refused); return }
            closing = true; enqueue(Request(.shutdown, completion))
        }
        private func enqueue(_ request: Request) {
            let replaced = desired; desired = request
            active?.retired = true
            if let stage { stage.cancel = true; if let id = stage.id { lane.cancel(id) } }
            replaced?.completion(.cancelled(nil)); drain()
        }
        private func drain() {
            guard active == nil, let request = desired else { return }
            desired = nil; active = request
            switch request.intent {
            case .open(let port, let duration):
                guard port > 0, duration > 0, duration <= Self.maximumRequestedLifetime, allowed(), enabled() else { finish(request, .refused); return }
                guard ready(request) else { return }
                lastOpen = (port, duration)
                if let book {
                    run(book.owned.removal, request) { result in
                        self.record(result, removing: true)
                        guard !request.retired, !result.retired else { self.finish(request, .cancelled(result)); return }
                        guard result.receipt.confirmsRemoval else { self.finish(request, .finished(result)); return }
                        self.probe(request, port, duration)
                    }
                } else { probe(request, port, duration) }
            case .renew(let id, let duration):
                guard let book, book.id == id, duration > 0, duration <= Self.maximumRequestedLifetime, allowed(), enabled() else { finish(request, .refused); return }
                guard ready(request) else { return }
                let operation: RouterMappingTransactions.Operation
                switch book.owned {
                case .udp(let lease): operation = .udp(.renew(lease, lifetime: duration))
                case .upnp(let lease): operation = .upnpMaintain(.lease(lease), .renew(lifetime: duration))
                case .claim: finish(request, .refused); return
                }
                run(operation, request) { self.completeMutation(request, $0) }
            case .remove(let id):
                guard let book, book.id == id else { finish(request, .refused); return }
                run(book.owned.removal, request) { self.completeMutation(request, $0) }
            case .recover(let id):
                let evidence = lane.unresolvedEvidence.first(where: { $0.id == id })
                run(request, submit: { self.lane.recover(id, completion: $0) }) { result in
                    let matchedBook = self.book?.owned.matches(evidence?.target) == true
                    if matchedBook && result.receipt.confirmsRemoval {
                        self.book = nil; self.localUnresolved = false
                    } else if matchedBook, case .udp(.retained(let lease, _)) = result.receipt, let old = self.book {
                        self.book = (old.id, .udp(lease), old.epochChanged)
                    }
                    self.unresolved = self.localUnresolved || !self.lane.unresolvedEvidence.isEmpty
                    self.backoff(result.receipt)
                    self.finish(request, request.retired || result.retired ? .cancelled(result) : .finished(result))
                }
            case .stop, .shutdown:
                lastOpen = nil
                guard !unresolved else { finish(request, .blocked("Router state remains unresolved; explicit matching inspection is required.")); return }
                guard let book else { finish(request, .cancelled(nil)); return }
                run(book.owned.removal, request) { self.completeMutation(request, $0) }
            }
        }
        private func ready(_ request: Request) -> Bool {
            guard !unresolved else { finish(request, .blocked("Router state remains unresolved; new mutations are blocked.")); return false }
            let now = clock()
            guard now.isFinite else { finish(request, .blocked("Invalid router workflow clock.")); return false }
            if let retryNotBefore, now < retryNotBefore { finish(request, .blocked("Router retry lifetime has not elapsed.")); return false }
            return true
        }
        private func probe(_ request: Request, _ port: UInt16, _ duration: UInt32) {
            guard !request.retired else { finish(request, .cancelled(nil)); return }
            run(.capability, request) { result in
                self.record(result, removing: false)
                self.backoff(result.receipt)
                guard !request.retired, !result.retired else { self.finish(request, .cancelled(result)); return }
                guard case .capability(.selected(let selection)) = result.receipt else { self.finish(request, .finished(result)); return }
                let operation: RouterMappingTransactions.Operation
                switch selection {
                case .pcp, .natPmp: operation = .udp(.create(selection, internalPort: port, lifetime: duration))
                case .upnp(let route, let service): operation = .upnpCreate(route, service, internalPort: port, lifetime: duration)
                }
                self.run(operation, request) { self.completeMutation(request, $0) }
            }
        }
        private func run(_ operation: RouterMappingTransactions.Operation, _ request: Request,
                         _ reply: @escaping (RouterMappingTransactions.Result) -> Void) {
            run(request, submit: { self.lane.submit(operation, completion: $0) }, reply)
        }
        private func run(_ request: Request, submit: (@escaping (RouterMappingTransactions.Result) -> Void) -> UUID,
                         _ reply: @escaping (RouterMappingTransactions.Result) -> Void) {
            guard active === request, stage == nil else { return }
            // Fence the higher request before entering a possibly reentrant raw
            // factory, when submit has not yet returned its cancellation UUID.
            permission.current = { [weak request] in request?.retired == false }
            let ticket = Stage(); stage = ticket
            let id = submit { [self, ticket, request] result in
                guard stage === ticket, active === request, !ticket.handled else { return }
                ticket.handled = true; ticket.delivered = result
                if ticket.installed { consume(ticket, reply) }
            }
            ticket.id = id; ticket.installed = true
            if ticket.cancel { lane.cancel(id) }
            consume(ticket, reply)
        }
        private func consume(_ ticket: Stage, _ reply: (RouterMappingTransactions.Result) -> Void) {
            guard stage === ticket, ticket.installed, let result = ticket.delivered else { return }
            ticket.delivered = nil; stage = nil; reply(result)
        }
        private func completeMutation(_ request: Request, _ result: RouterMappingTransactions.Result) {
            let removing: Bool
            switch request.intent { case .remove, .stop, .shutdown: removing = true; default: removing = false }
            record(result, removing: removing); backoff(result.receipt)
            if request.retired || result.retired { finish(request, .cancelled(result)); return }
            if result.cleanup == nil, !unresolved, let current,
               case .udp(.granted) = result.receipt { finish(request, .mapped(current, result)); return }
            if result.cleanup == nil, !unresolved, let current {
                switch result.receipt {
                case .created(.granted), .maintained(.renewed): finish(request, .mapped(current, result)); return
                default: break
                }
            }
            finish(request, .finished(result))
        }
        private func record(_ result: RouterMappingTransactions.Result, removing: Bool) {
            let id = book?.id ?? UUID()
            switch result.receipt {
            case .udp(.granted(let lease, _, let epochChanged)): book = (id, .udp(lease), epochChanged)
            case .udp(.retained(let lease, _)): book = (id, .udp(lease), book?.epochChanged ?? false)
            case .created(.granted(let lease, _)), .maintained(.renewed(let lease, _)): book = (id, .upnp(lease), false)
            case .created(.acknowledged(let claim, _, _)), .created(.uncertain(let claim, _)),
                 .maintained(.retained(let claim, _, _)), .maintained(.changed(let claim, _)), .maintained(.uncertain(let claim, _)):
                book = (id, .claim(claim), false)
            default: break
            }
            if result.receipt.confirmsRemoval || result.cleanup?.confirmsRemoval == true { book = nil; localUnresolved = false; unresolved = false }
            else if let cleanup = result.cleanup {
                if case .udp(.retained(let lease, _)) = cleanup { book = (id, .udp(lease), false) }
                unresolved = true
            } else if removing || result.receipt.uncertain || result.retired && book != nil {
                unresolved = true
            } else {
                switch result.receipt {
                case .udp(.expired), .maintained(.expired), .maintained(.changed), .maintained(.retained): unresolved = true
                case .refused, .blocked, .udp(.refused), .maintained(.refused): if book != nil { unresolved = true }
                default: break
                }
            }
            if let book, let grant = book.owned.grant(book.id, epochChanged: book.epochChanged), grant.remainingLifetime(at: clock()) == 0 {
                unresolved = true
            }
            if unresolved && lane.unresolvedEvidence.isEmpty { localUnresolved = true }
            unresolved = localUnresolved || !lane.unresolvedEvidence.isEmpty
        }
        private func backoff(_ receipt: RouterMappingTransactions.Receipt) {
            let duration: TimeInterval
            switch receipt {
            case .capability(.failure(_, let retry)), .udp(.failure(_, _, let retry)): duration = retry
            default: return
            }
            let now = clock()
            guard now.isFinite, duration.isFinite, duration >= 0, (now + duration).isFinite else { unresolved = true; localUnresolved = true; return }
            retryNotBefore = max(retryNotBefore ?? now, now + duration)
        }
        private func finish(_ request: Request, _ outcome: Outcome) {
            guard active === request, stage == nil else { return }
            active = nil
            if case .shutdown = request.intent { lane.shutdown() }
            request.completion(outcome); drain()
        }
    }
}
