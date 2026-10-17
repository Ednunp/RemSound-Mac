import Foundation
import Security

final class RouterUDPMapping {
    enum Kind { case pcp, natPmp }
    struct Lease: Equatable {
        let kind: Kind, route: RouterGatewayRoute, internalPort: UInt16, externalPort: UInt16
        let externalAddress: String, lifetime: UInt32, epoch: UInt32, obtainedAt: TimeInterval, validUntil: TimeInterval, nonce: Data?
        fileprivate init(kind: Kind, route: RouterGatewayRoute, internalPort: UInt16, externalPort: UInt16,
                         externalAddress: String, lifetime: UInt32, epoch: UInt32, obtainedAt: TimeInterval, validUntil: TimeInterval, nonce: Data?) {
            self.kind = kind; self.route = route; self.internalPort = internalPort; self.externalPort = externalPort
            self.externalAddress = externalAddress; self.lifetime = lifetime; self.epoch = epoch; self.obtainedAt = obtainedAt; self.validUntil = validUntil; self.nonce = nonce
        }
        func epochChanged(to value: UInt32, at now: TimeInterval) -> Bool {
            guard now.isFinite, now >= obtainedAt, now - obtainedAt < TimeInterval(UInt32.max) else { return true }
            let elapsed = Int64(now - obtainedAt)
            if kind == .natPmp { return Int64(value) + 2 < Int64(epoch) + elapsed * 7 / 8 }
            let difference = Int64(value) - Int64(epoch)
            if difference < -1 { return true }
            let serverDelta = max(0, difference)
            return elapsed + 2 < serverDelta - serverDelta / 16 || serverDelta + 2 < elapsed - elapsed / 16
        }
    }
    enum Intent {
        case create(RouterCapability.Selection, internalPort: UInt16, lifetime: UInt32)
        case renew(Lease, lifetime: UInt32), remove(Lease)
    }
    enum Outcome: Equatable {
        case granted(Lease, retired: Bool, epochChanged: Bool), retained(Lease, retired: Bool), removed(retired: Bool)
        case existingMapping(externalAddress: String, externalPort: UInt16), refused, expired
        case cancelled(mutationMayHaveOccurred: Bool), timedOut(mutationMayHaveOccurred: Bool)
        case failure(String, mutationMayHaveOccurred: Bool, retryAfter: TimeInterval)
    }
    typealias ExchangeFactory = (RouterUDPExchange.Request, RouterGatewayRoute, @escaping (RouterUDPExchange.Outcome) -> Void) -> () -> Void
    private let intent: Intent, permitted: () -> Bool, clock: () -> TimeInterval, makeNonce: () -> Data?
    private let exchange: ExchangeFactory, completion: (Outcome) -> Void
    init(intent: Intent, permitted: @escaping () -> Bool, clock: @escaping () -> TimeInterval,
         nonce: @escaping () -> Data? = RouterUDPMapping.secureNonce, exchange: @escaping ExchangeFactory,
         completion: @escaping (Outcome) -> Void) {
        self.intent = intent; self.permitted = permitted; self.clock = clock; makeNonce = nonce; self.exchange = exchange; self.completion = completion
    }
    static let deadline: TimeInterval = 8
    private static let shortErrorLifetime: TimeInterval = 30
    private static let longErrorLifetime: TimeInterval = 1800
    private enum PCPError {
        static let networkFailure: UInt16 = 7, noResources: UInt16 = 8, userQuota: UInt16 = 10
        static let shortLifetime = [networkFailure, noResources, userQuota]
    }
    private enum NATError { static let networkFailure: UInt16 = 3, noResources: UInt16 = 4 }
    static func secureNonce() -> Data? {
        var bytes = [UInt8](repeating: 0, count: RouterMappingPackets.pcpNonceSize)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }
    private struct Prepared {
        let kind: Kind, route: RouterGatewayRoute, internalPort: UInt16, lifetime: UInt32, nonce: Data?
        let externalAddress: String?, externalPort: UInt16, previous: Lease?, began: TimeInterval
        let removing: Bool
        var request: RouterUDPExchange.Request {
            if kind == .pcp {
                return .pcpMap(nonce: nonce!, internalPort: internalPort, externalPort: externalPort, lifetime: lifetime, externalAddress: externalAddress)
            }
            return .natMap(internalPort: internalPort, externalPort: removing ? 0 : externalPort, lifetime: lifetime)
        }
    }
    private final class Ticket {
        let prepared: Prepared
        var handled = false, retired = false, expired = false
        private var cancelSent = false, cancellation: (() -> Void)?
        init(_ prepared: Prepared) { self.prepared = prepared }
        func install(_ cancel: @escaping () -> Void) { if cancelSent { cancel() } else { cancellation = cancel } }
        func cancel() {
            guard !cancelSent else { return }; cancelSent = true
            let cancel = cancellation; cancellation = nil; cancel?()
        }
    }
    private var began: TimeInterval?, pending: Ticket?, finished = false
    // The exchange runs on the same owner queue and reports after exact socket quiescence.
    // A retired successful mutation is returned to the caller, never silently discarded.
    func start() {
        guard !finished, began == nil else { return }
        guard permitted() else { finish(.refused); return }
        let now = clock()
        guard now.isFinite else { failBeforeSend("Invalid router mapping clock."); return }
        began = now
        let previous: Lease?
        switch intent { case .renew(let lease, _), .remove(let lease): previous = lease; default: previous = nil }
        if let previous {
            guard now >= previous.obtainedAt else { failBeforeSend("Router lease clock went backwards."); return }
            // Expiry is conservative: request start, not delayed receipt. An expired
            // tuple could now belong to another operation, especially with NAT-PMP.
            guard now < previous.validUntil else { finish(.expired); return }
        }
        guard let prepared = prepare(at: now) else { failBeforeSend("Invalid router UDP mapping request or nonce."); return }
        guard permitted() else { finish(.refused); return }
        let after = clock()
        guard after.isFinite, after >= now else { failBeforeSend("Invalid router mapping clock."); return }
        guard after - now < Self.deadline else { finish(.timedOut(mutationMayHaveOccurred: false)); return }
        let ticket = Ticket(prepared); pending = ticket
        let cancel = exchange(prepared.request, prepared.route) { [weak self, ticket, completion, clock, permitted] outcome in
            guard !ticket.handled else { return }; ticket.handled = true; ticket.cancel()
            if let self {
                guard self.pending === ticket else { return }
                self.pending = nil; self.finished = true
            } else { ticket.retired = true }
            let now = clock()
            if !permitted() || !now.isFinite || now < prepared.began || now - prepared.began >= Self.deadline { ticket.retired = true }
            completion(Self.result(outcome, ticket: ticket, at: now.isFinite && now >= prepared.began ? now : prepared.began))
        }
        ticket.install(cancel)
    }
    func tick() {
        guard !finished, let pending, !pending.handled else { return }
        let now = clock()
        if !permitted() || !now.isFinite || now < pending.prepared.began { pending.retired = true; pending.cancel(); return }
        if now - pending.prepared.began >= Self.deadline { pending.retired = true; pending.expired = true; pending.cancel() }
    }
    func cancel() {
        guard !finished else { return }
        guard let pending else { finish(.cancelled(mutationMayHaveOccurred: false)); return }
        pending.retired = true; pending.cancel()
    }
    private func prepare(at now: TimeInterval) -> Prepared? {
        switch intent {
        case .create(let selection, let port, let lifetime):
            guard port > 0, lifetime > 0 else { return nil }
            switch selection {
            case .pcp(let route, _):
                guard route.isValid, let nonce = makeNonce(), nonce.count == RouterMappingPackets.pcpNonceSize else { return nil }
                return .init(kind: .pcp, route: route, internalPort: port, lifetime: lifetime, nonce: nonce, externalAddress: nil, externalPort: port, previous: nil, began: now, removing: false)
            case .natPmp(let route, let address, _):
                guard route.isValid, RouterMappingPackets.ipv4(address) != nil else { return nil }
                return .init(kind: .natPmp, route: route, internalPort: port, lifetime: lifetime, nonce: nil, externalAddress: address, externalPort: port, previous: nil, began: now, removing: false)
            case .upnp: return nil
            }
        case .renew(let lease, let lifetime):
            guard lifetime > 0 else { return nil }
            return .init(kind: lease.kind, route: lease.route, internalPort: lease.internalPort, lifetime: lifetime,
                nonce: lease.nonce, externalAddress: lease.externalAddress, externalPort: lease.externalPort, previous: lease, began: now, removing: false)
        case .remove(let lease):
            return .init(kind: lease.kind, route: lease.route, internalPort: lease.internalPort, lifetime: 0,
                nonce: lease.nonce, externalAddress: lease.externalAddress, externalPort: lease.externalPort, previous: lease, began: now, removing: true)
        }
    }
    private static func result(_ outcome: RouterUDPExchange.Outcome, ticket: Ticket, at now: TimeInterval) -> Outcome {
        let p = ticket.prepared
        switch outcome {
        case .response(let reply, let route), .lateResponse(let reply, let route):
            let late: Bool
            if case .lateResponse = outcome { late = true } else { late = false }
            let retired = ticket.retired || late
            guard route == p.route, reply.internalPort == p.internalPort else {
                return .failure("Router mapping reply did not match the captured route/port.", mutationMayHaveOccurred: true, retryAfter: longErrorLifetime)
            }
            guard reply.resultCode == 0 else {
                let retry: TimeInterval
                if p.kind == .pcp {
                    retry = reply.lifetime > 0 ? TimeInterval(reply.lifetime) : (PCPError.shortLifetime.contains(reply.resultCode) ? shortErrorLifetime : longErrorLifetime)
                } else {
                    retry = [NATError.networkFailure, NATError.noResources].contains(reply.resultCode) ? shortErrorLifetime : longErrorLifetime
                }
                return .failure("Router mapping refused (code \(reply.resultCode)).", mutationMayHaveOccurred: false, retryAfter: retry)
            }
            if p.removing, reply.lifetime == 0, reply.externalPort == 0 { return .removed(retired: retired) }
            guard reply.lifetime > 0, reply.externalPort > 0, let address = p.kind == .pcp ? reply.externalAddress : p.externalAddress,
                  RouterMappingPackets.ipv4(address) != nil, !p.removing || p.kind == .pcp else {
                return .failure("Router returned an invalid or unconfirmed mapping grant.", mutationMayHaveOccurred: true, retryAfter: longErrorLifetime)
            }
            // Static mappings can echo a new nonce. The usual permanent-lifetime marker
            // is never turned into a locally deletable lease or treated as newly created.
            if reply.lifetime == UInt32.max { return .existingMapping(externalAddress: address, externalPort: reply.externalPort) }
            let lease = Lease(kind: p.kind, route: p.route, internalPort: p.internalPort, externalPort: reply.externalPort,
                externalAddress: address, lifetime: reply.lifetime, epoch: reply.epoch, obtainedAt: now, validUntil: p.began + TimeInterval(reply.lifetime), nonce: p.nonce)
            if p.removing { return .retained(lease, retired: retired) }
            return .granted(lease, retired: retired, epochChanged: p.previous?.epochChanged(to: reply.epoch, at: now) ?? false)
        case .timedOut(let uncertain): return .timedOut(mutationMayHaveOccurred: uncertain)
        case .cancelled(let uncertain): return ticket.expired ? .timedOut(mutationMayHaveOccurred: uncertain) : .cancelled(mutationMayHaveOccurred: uncertain)
        case .failed(let message, let uncertain): return .failure(message, mutationMayHaveOccurred: uncertain, retryAfter: longErrorLifetime)
        case .refused: return .refused
        case .unavailable: return .failure("Router mapping transport was unavailable.", mutationMayHaveOccurred: false, retryAfter: shortErrorLifetime)
        }
    }
    private func failBeforeSend(_ message: String) { finish(.failure(message, mutationMayHaveOccurred: false, retryAfter: Self.shortErrorLifetime)) }
    private func finish(_ result: Outcome) { guard !finished else { return }; finished = true; completion(result) }
    deinit { cancel() }
}
