import Foundation

final class RouterMappingTransactions {
    enum RecoveryTarget: Equatable {
        case udp(RouterUDPMapping.Lease), upnpLease(UPnPMappingCreation.Lease), upnpClaim(UPnPMappingCreation.Claim)
        fileprivate var operation: Operation {
            switch self {
            case .udp(let lease): return .udp(.remove(lease))
            case .upnpLease(let lease): return .upnpMaintain(.lease(lease), .remove)
            case .upnpClaim(let claim): return .upnpMaintain(.claim(claim), .remove)
            }
        }
    }
    struct Evidence {
        let id: UUID, target: RecoveryTarget?, operation: Operation, originalReceipt: Receipt, latestReceipt: Receipt, reason: String
        fileprivate init(id: UUID = UUID(), target: RecoveryTarget?, operation: Operation, originalReceipt: Receipt, latestReceipt: Receipt, reason: String) {
            self.id = id; self.target = target; self.operation = operation
            self.originalReceipt = originalReceipt; self.latestReceipt = latestReceipt; self.reason = reason
        }
    }
    enum Target { case lease(UPnPMappingCreation.Lease), claim(UPnPMappingCreation.Claim) }
    enum Operation {
        case capability, udp(RouterUDPMapping.Intent)
        case upnpCreate(RouterGatewayRoute, UPnPRouterService, internalPort: UInt16, lifetime: UInt32)
        case upnpMaintain(Target, UPnPMappingMaintenance.Action)
        var isCleanup: Bool {
            switch self { case .udp(.remove), .upnpMaintain(_, .remove): return true; default: return false }
        }
        var isMutation: Bool { if case .capability = self { return false }; return true }
        var isValid: Bool {
            switch self {
            case .udp(.create(_, let port, let duration)): return port > 0 && duration > 0 && duration <= State.maximumRequestedLifetime
            case .udp(.renew(_, let duration)), .upnpMaintain(.lease, .renew(let duration)):
                return duration > 0 && duration <= State.maximumRequestedLifetime
            case .upnpCreate(let route, let service, let port, let duration):
                return route.isValid && service.gatewayAddress == route.gateway.address && port > 0 && duration > 0 && duration <= State.maximumRequestedLifetime
            case .upnpMaintain(.claim, .renew): return false
            default: return true
            }
        }
        func accepts(_ receipt: Receipt) -> Bool {
            switch (self, receipt) {
            case (.capability, .capability), (.udp, .udp), (.upnpCreate, .created), (.upnpMaintain, .maintained): return true
            case (_, .refused), (_, .cancelled), (_, .blocked): return true
            default: return false
            }
        }
    }
    enum Receipt: Equatable {
        case capability(RouterCapability.Outcome), udp(RouterUDPMapping.Outcome)
        case created(UPnPMappingCreation.Outcome), maintained(UPnPMappingMaintenance.Outcome)
        case refused, cancelled, blocked(String)
        var retired: Bool {
            switch self {
            case .udp(.granted(_, let retired, _)), .udp(.retained(_, let retired)), .udp(.removed(let retired)),
                 .created(.granted(_, let retired)), .created(.acknowledged(_, let retired, _)), .maintained(.renewed(_, let retired)): return retired
            default: return false
            }
        }
        var confirmsRemoval: Bool {
            switch self { case .udp(.removed), .maintained(.removed), .maintained(.absent): return true; default: return false }
        }
        var uncertain: Bool {
            switch self {
            case .udp(.cancelled(let uncertain)), .udp(.timedOut(let uncertain)), .udp(.failure(_, let uncertain, _)): return uncertain
            case .created(.uncertain), .maintained(.uncertain): return true
            default: return false
            }
        }
    }
    struct Result {
        let receipt: Receipt, retired: Bool, cleanup: Receipt?
        func remainingLifetime(at now: TimeInterval) -> TimeInterval? {
            let expiry: TimeInterval, began: TimeInterval
            switch receipt {
            case .udp(.granted(let lease, _, _)), .udp(.retained(let lease, _)): expiry = lease.validUntil; began = lease.obtainedAt
            case .created(.granted(let lease, _)), .maintained(.renewed(let lease, _)): expiry = lease.validUntil; began = lease.claim.requestStarted
            default: return nil
            }
            guard !retired, cleanup == nil, now.isFinite, expiry.isFinite, began.isFinite, now >= began else { return 0 }
            return max(0, expiry - now)
        }
    }
    struct Control { let tick: () -> Void, cancel: () -> Void }
    typealias Factory = (Operation, @escaping () -> Bool, @escaping (Receipt) -> Void) -> Control
    private let state: State
    var unresolvedEvidence: [Evidence] { state.evidence }
    init(allowed: @escaping () -> Bool, enabled: @escaping () -> Bool, clock: @escaping () -> TimeInterval, factory: @escaping Factory) {
        state = State(allowed: allowed, enabled: enabled, clock: clock, factory: factory)
    }
    @discardableResult func submit(_ operation: Operation, completion: @escaping (Result) -> Void) -> UUID { state.submit(operation, completion: completion) }
    @discardableResult func recover(_ id: UUID, completion: @escaping (Result) -> Void) -> UUID { state.recover(id, completion: completion) }
    func cancel(_ id: UUID) { state.cancel(id) }
    func tick() { state.tick() }
    func shutdown() { state.shutdown() }
    deinit { state.shutdown() }

    // Factories and receipts share the backend's serial executor. A receipt means that
    // transport has quiesced; even a synchronous receipt waits for its factory return.
    // State survives wrapper release to retain exact late mutation and cleanup receipts.
    private final class State {
        static let maximumRequestedLifetime: UInt32 = 604800
        private static let deadline: TimeInterval = 8
        private static let maximumQueue = 16
        private static let maximumEvidence = 16
        private final class Request {
            let id = UUID(), operation: Operation, completion: (Result) -> Void
            let recovery: Evidence?
            var retired = false
            init(_ operation: Operation, recovery: Evidence? = nil, completion: @escaping (Result) -> Void) {
                self.operation = operation; self.recovery = recovery; self.completion = completion
            }
        }
        private final class Ticket {
            let operation: Operation, request: Request, began: TimeInterval, original: Receipt?
            var control: Control?, installed = false, handled = false, delivered: Receipt?
            private var cancelSent = false
            var isCancelled: Bool { cancelSent }
            init(_ operation: Operation, request: Request, began: TimeInterval, original: Receipt? = nil) {
                self.operation = operation; self.request = request; self.began = began; self.original = original
            }
            func install(_ value: Control) { control = value; installed = true; if cancelSent { value.cancel() } }
            func cancel() { guard !cancelSent else { return }; cancelSent = true; control?.cancel() }
            func retireResource() { cancel(); control = nil }
        }
        let allowed: () -> Bool, enabled: () -> Bool, clock: () -> TimeInterval, factory: Factory
        private var queue: [Request] = [], pending: Ticket?, closed = false, draining = false
        private(set) var evidence: [Evidence] = []
        init(allowed: @escaping () -> Bool, enabled: @escaping () -> Bool, clock: @escaping () -> TimeInterval, factory: @escaping Factory) {
            self.allowed = allowed; self.enabled = enabled; self.clock = clock; self.factory = factory
        }
        func submit(_ operation: Operation, completion: @escaping (Result) -> Void) -> UUID {
            let request = Request(operation, completion: completion)
            return enqueue(request)
        }
        func recover(_ id: UUID, completion: @escaping (Result) -> Void) -> UUID {
            guard let item = evidence.first(where: { $0.id == id }), let target = item.target else {
                let id = UUID(); completion(.init(receipt: .blocked("No matching provable router cleanup target."), retired: false, cleanup: nil)); return id
            }
            return enqueue(Request(target.operation, recovery: item, completion: completion))
        }
        private func enqueue(_ request: Request) -> UUID {
            let operation = request.operation, completion = request.completion
            guard !closed else { completion(.init(receipt: .refused, retired: false, cleanup: nil)); return request.id }
            guard operation.isValid else { completion(.init(receipt: .blocked("Invalid router transaction."), retired: false, cleanup: nil)); return request.id }
            guard queue.count < Self.maximumQueue else { completion(.init(receipt: .blocked("Router transaction queue is full."), retired: false, cleanup: nil)); return request.id }
            queue.append(request); drain(); return request.id
        }
        func cancel(_ id: UUID) {
            if let index = queue.firstIndex(where: { $0.id == id }) {
                let request = queue.remove(at: index); request.retired = true
                request.completion(.init(receipt: .cancelled, retired: true, cleanup: nil)); return
            }
            guard let pending, pending.request.id == id, pending.original == nil else { return }
            pending.request.retired = true; pending.cancel()
        }
        func tick() {
            guard let ticket = pending else { return }
            ticket.control?.tick()
            guard pending === ticket else { return }
            let now = clock()
            if !allowed() || (!ticket.operation.isCleanup && !enabled()) || !now.isFinite || now < ticket.began || now - ticket.began >= Self.deadline {
                ticket.request.retired = true; ticket.cancel()
            }
        }
        func shutdown() {
            guard !closed else { return }; closed = true
            let queued = queue; queue.removeAll()
            for request in queued { request.retired = true; request.completion(.init(receipt: .cancelled, retired: true, cleanup: nil)) }
            if let pending, pending.original == nil { pending.request.retired = true; pending.cancel() }
        }
        private func drain() {
            guard !draining else { return }; draining = true; defer { draining = false }
            while pending == nil && !queue.isEmpty {
                let request = queue.removeFirst(), operation = request.operation
                if request.recovery == nil && evidence.count >= Self.maximumEvidence {
                    request.completion(.init(receipt: .blocked("Router evidence ledger is full; matching recovery is required."), retired: false, cleanup: nil)); continue
                }
                guard allowed(), operation.isCleanup || enabled() else {
                    retainUnconstructedCleanup(request, receipt: .refused)
                    request.completion(.init(receipt: .refused, retired: false, cleanup: nil)); continue
                }
                if let recovery = request.recovery {
                    guard evidence.contains(where: { $0.id == recovery.id && $0.target == recovery.target }) else {
                        request.completion(.init(receipt: .blocked("Router recovery target was retired or changed."), retired: false, cleanup: nil)); continue
                    }
                }
                if operation.isMutation && !operation.isCleanup, let first = evidence.first {
                    request.completion(.init(receipt: .blocked(first.reason), retired: false, cleanup: nil)); continue
                }
                begin(operation, request: request)
            }
        }
        private func begin(_ operation: Operation, request: Request, original: Receipt? = nil) {
            guard pending == nil else { return }
            guard allowed(), operation.isCleanup || enabled() else {
                completeWithoutFactory(request, original: original, receipt: .refused); return
            }
            let now = clock()
            guard now.isFinite else { completeWithoutFactory(request, original: original, receipt: .blocked("Invalid router transaction clock.")); return }
            let ticket = Ticket(operation, request: request, began: now, original: original); pending = ticket
            let gate = { [allowed, enabled, weak ticket] in
                guard let ticket, !ticket.isCancelled else { return false }
                return allowed() && (operation.isCleanup || enabled())
            }
            let control = factory(operation, gate) { [self, ticket] receipt in
                guard pending === ticket, !ticket.handled else { return }
                ticket.handled = true; ticket.delivered = receipt
                if ticket.installed { consume(ticket) }
            }
            ticket.install(control)
            if ticket.delivered != nil { consume(ticket) }
        }
        private func consume(_ ticket: Ticket) {
            guard pending === ticket, ticket.installed, let receipt = ticket.delivered else { return }
            ticket.delivered = nil; ticket.retireResource(); pending = nil
            let now = clock()
            if !allowed() || (!ticket.operation.isCleanup && !enabled()) || !now.isFinite || now < ticket.began || now - ticket.began >= Self.deadline || receipt.retired {
                ticket.request.retired = true
            }
            guard ticket.operation.accepts(receipt) else {
                let reason = "Router factory returned a mismatched receipt; remote state needs inspection."
                appendEvidence(target: nil, operation: ticket.request.operation, original: ticket.original ?? receipt, receipt: receipt, reason: reason)
                ticket.request.completion(.init(receipt: receipt, retired: true, cleanup: .blocked(reason))); drain(); return
            }
            if let recovery = ticket.request.recovery {
                if let index = evidence.firstIndex(where: { $0.id == recovery.id && $0.target == recovery.target }) {
                    if receipt.confirmsRemoval { evidence.remove(at: index) }
                    else {
                        let target = updatedTarget(recovery.target, receipt: receipt)
                        evidence[index] = .init(id: recovery.id, target: target, operation: recovery.operation, originalReceipt: recovery.originalReceipt, latestReceipt: receipt, reason: recovery.reason)
                    }
                }
                ticket.request.completion(.init(receipt: receipt, retired: ticket.request.retired, cleanup: nil)); drain(); return
            }
            if let original = ticket.original {
                if !receipt.confirmsRemoval {
                    appendEvidence(target: target(ticket.operation, receipt: receipt), operation: ticket.request.operation, original: original, receipt: receipt,
                                   reason: "Router cleanup was not confirmed; new mutations are blocked.")
                }
                ticket.request.completion(.init(receipt: original, retired: ticket.request.retired, cleanup: receipt)); drain(); return
            }
            if !ticket.operation.isCleanup, let cleanup = cleanupOperation(ticket.operation, receipt: receipt, retired: ticket.request.retired) {
                begin(cleanup, request: ticket.request, original: receipt); return
            }
            if receipt.uncertain || (ticket.operation.isCleanup && !receipt.confirmsRemoval) {
                appendEvidence(target: target(ticket.operation, receipt: receipt), operation: ticket.request.operation, original: receipt, receipt: receipt,
                               reason: "Router remote state is unresolved; no blind mutation retry is permitted.")
            }
            ticket.request.completion(.init(receipt: receipt, retired: ticket.request.retired, cleanup: nil)); drain()
        }
        private func completeWithoutFactory(_ request: Request, original: Receipt?, receipt: Receipt) {
            if let original {
                appendEvidence(target: target(request.operation, receipt: original), operation: request.operation, original: original, receipt: receipt,
                               reason: "Router cleanup could not run; remote state is unresolved.")
                request.completion(.init(receipt: original, retired: request.retired, cleanup: receipt))
            } else {
                retainUnconstructedCleanup(request, receipt: receipt)
                request.completion(.init(receipt: receipt, retired: request.retired, cleanup: nil))
            }
            drain()
        }
        private func retainUnconstructedCleanup(_ request: Request, receipt: Receipt) {
            guard request.operation.isCleanup else { return }
            if let recovery = request.recovery {
                if let index = evidence.firstIndex(where: { $0.id == recovery.id && $0.target == recovery.target }) {
                    evidence[index] = .init(id: recovery.id, target: recovery.target, operation: recovery.operation,
                                           originalReceipt: recovery.originalReceipt, latestReceipt: receipt, reason: recovery.reason)
                }
            } else {
                appendEvidence(target: target(request.operation, receipt: receipt), operation: request.operation,
                               original: receipt, receipt: receipt, reason: "Owned router cleanup could not construct; fresh matching proof is required.")
            }
        }
        private func appendEvidence(target: RecoveryTarget?, operation: Operation, original: Receipt, receipt: Receipt, reason: String) {
            // Reserve one fail-closed unknown entry for malformed recovery receipts
            // at capacity. Keep every prior target; this entry has no cleanup authority.
            if evidence.count > Self.maximumEvidence {
                let index = evidence.count - 1, prior = evidence[index]
                evidence[index] = .init(id: prior.id, target: nil, operation: prior.operation, originalReceipt: prior.originalReceipt, latestReceipt: receipt, reason: reason)
                return
            }
            evidence.append(.init(target: evidence.count == Self.maximumEvidence ? nil : target, operation: operation, originalReceipt: original, latestReceipt: receipt, reason: reason))
        }
        private func target(_ operation: Operation, receipt: Receipt) -> RecoveryTarget? {
            switch receipt {
            case .udp(.granted(let lease, _, _)), .udp(.retained(let lease, _)): return .udp(lease)
            case .created(.granted(let lease, _)), .maintained(.renewed(let lease, _)): return .upnpLease(lease)
            case .created(.acknowledged(let claim, _, _)), .created(.uncertain(let claim, _)), .maintained(.uncertain(let claim, _)):
                return .upnpClaim(claim)
            default:
                switch operation {
                case .udp(.remove(let lease)), .udp(.renew(let lease, _)): return .udp(lease)
                case .upnpMaintain(.lease(let lease), _): return .upnpLease(lease)
                case .upnpMaintain(.claim(let claim), _): return .upnpClaim(claim)
                default: return nil
                }
            }
        }
        private func updatedTarget(_ target: RecoveryTarget?, receipt: Receipt) -> RecoveryTarget? {
            // A retained UDP response may change its actual lifetime. Keep that
            // returned lease, but never extend a UPnP lease to its claim's raw request.
            if case .udp(.retained(let lease, _)) = receipt, case .udp? = target { return .udp(lease) }
            return target
        }
        private func cleanupOperation(_ operation: Operation, receipt: Receipt, retired: Bool) -> Operation? {
            switch receipt {
            case .udp(.granted(let lease, _, _)), .udp(.retained(let lease, _)):
                return retired ? .udp(.remove(lease)) : nil
            case .created(.granted(let lease, _)), .maintained(.renewed(let lease, _)):
                return retired ? .upnpMaintain(.lease(lease), .remove) : nil
            case .created(.acknowledged(let claim, _, _)), .created(.uncertain(let claim, _)), .maintained(.uncertain(let claim, _)):
                return .upnpMaintain(.claim(claim), .remove)
            case .maintained(.retained(let claim, mutationAcknowledged: true, _)):
                return .upnpMaintain(.claim(claim), .remove)
            default:
                if receipt.uncertain, case .udp(.renew(let lease, _)) = operation { return .udp(.remove(lease)) }
                return nil
            }
        }
    }
}
