import Foundation

final class UPnPMappingCreation {
    struct Claim: Equatable {
        let route: RouterGatewayRoute, service: UPnPRouterService, token: String
        let internalPort: UInt16, externalPort: UInt16, externalAddress: String
        let requestedLifetime: UInt32, requestStarted: TimeInterval
        fileprivate init(route: RouterGatewayRoute, service: UPnPRouterService, token: String, internalPort: UInt16,
                         externalPort: UInt16, externalAddress: String, requestedLifetime: UInt32, requestStarted: TimeInterval) {
            self.route = route; self.service = service; self.token = token; self.internalPort = internalPort; self.externalPort = externalPort
            self.externalAddress = externalAddress; self.requestedLifetime = requestedLifetime; self.requestStarted = requestStarted
        }
    }
    struct Lease: Equatable {
        let claim: Claim, lifetime: UInt32, validUntil: TimeInterval
        fileprivate init(claim: Claim, lifetime: UInt32, validUntil: TimeInterval) { self.claim = claim; self.lifetime = lifetime; self.validUntil = validUntil }
    }
    enum Outcome: Equatable {
        case granted(Lease, retired: Bool), acknowledged(Claim, retired: Bool, reason: String), uncertain(Claim, reason: String)
        case occupied, refused, cancelled, timedOut, failure(String)
    }
    static let deadline: TimeInterval = 8
    private static let maximumLease: UInt32 = 604800
    static func secureToken() -> String? {
        guard let bytes = RouterUDPMapping.secureNonce() else { return nil }
        return "RemSound-" + bytes.map { String(format: "%02x", $0) }.joined()
    }
    private let state: State
    init(route: RouterGatewayRoute, service: UPnPRouterService, internalPort: UInt16, lifetime: UInt32,
         permitted: @escaping () -> Bool, clock: @escaping () -> TimeInterval,
         token: @escaping () -> String? = UPnPMappingCreation.secureToken,
         http: @escaping RouterCapability.HTTPFactory, completion: @escaping (Outcome) -> Void) {
        state = State(route: route, service: service, port: internalPort, lifetime: lifetime,
            permitted: permitted, clock: clock, token: token, http: http, completion: completion)
    }
    func start() { state.start() }
    func tick() { state.tick() }
    func cancel() { state.cancel() }
    deinit { state.cancel() }
    // The receipt state survives owner release until HTTP cancellation quiesces, so an
    // accepted Add and its exact token cannot disappear when the wrapper is retired.
    private final class State {
        private enum Stage { case preflight, externalIP, add, readback }
        private final class Ticket {
            let stage: Stage
            var handled = false
            private var cancelSent = false, cancellation: (() -> Void)?
            init(_ stage: Stage) { self.stage = stage }
            func install(_ cancel: @escaping () -> Void) { if cancelSent { cancel() } else { cancellation = cancel } }
            func cancel() {
                guard !cancelSent else { return }; cancelSent = true
                let cancel = cancellation; cancellation = nil; cancel?()
            }
        }
        let route: RouterGatewayRoute, service: UPnPRouterService, port: UInt16, lifetime: UInt32
        let permitted: () -> Bool, clock: () -> TimeInterval, makeToken: () -> String?
        let http: RouterCapability.HTTPFactory, completion: (Outcome) -> Void
        private var began: TimeInterval?, token: String?, address: String?, claim: Claim?, knownAdd = false
        private var pending: Ticket?, done = false, retired = false
        private var retirement: Outcome = .cancelled
        init(route: RouterGatewayRoute, service: UPnPRouterService, port: UInt16, lifetime: UInt32,
             permitted: @escaping () -> Bool, clock: @escaping () -> TimeInterval,
             token: @escaping () -> String?, http: @escaping RouterCapability.HTTPFactory, completion: @escaping (Outcome) -> Void) {
            self.route = route; self.service = service; self.port = port; self.lifetime = lifetime
            self.permitted = permitted; self.clock = clock; makeToken = token; self.http = http; self.completion = completion
        }
        func start() {
            guard !done, began == nil else { return }
            guard permitted() else { finish(.refused); return }
            guard route.isValid, service.gatewayAddress == route.gateway.address,
                  UPnPRouterProtocol.safeURL(service.controlURL, gateway: route.gateway.address) != nil,
                  port > 0, lifetime > 0, lifetime <= maximumLease else { finish(.failure("Invalid UPnP mapping route or lease.")); return }
            let now = clock()
            guard now.isFinite else { finish(.failure("Invalid UPnP clock.")); return }
            began = now
            guard let token = makeToken(), token.hasPrefix("RemSound-"), token.count > 9, token.count <= 64,
                  token.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
                finish(.failure("Invalid UPnP ownership token.")); return
            }
            self.token = token; issue(.preflight)
        }
        func tick() {
            guard !done, pending != nil else { return }
            if let reason = terminal() { retired = true; retirement = reason; pending?.cancel() }
        }
        func cancel() {
            guard !done else { return }; retired = true; retirement = .cancelled
            if let pending { pending.cancel() } else { finishRetired() }
        }
        private func terminal() -> Outcome? {
            if retired { return retirement }
            guard permitted() else { return .refused }
            guard let began else { return nil }
            let now = clock()
            guard now.isFinite, now >= began else { return .failure("Invalid UPnP clock.") }
            return now - began >= deadline ? .timedOut : nil
        }
        private func issue(_ stage: Stage) {
            guard !done, pending == nil, let began else { return }
            if let reason = terminal() { retired = true; retirement = reason; finishRetired(); return }
            let now = clock(), remaining = deadline - (now - began)
            let action: UPnPRouterProtocol.Action
            switch stage { case .preflight, .readback: action = .specificMapping; case .externalIP: action = .externalIP; case .add: action = .add }
            if case .add = stage, let token, let address {
                claim = .init(route: route, service: service, token: token, internalPort: port, externalPort: port,
                    externalAddress: address, requestedLifetime: lifetime, requestStarted: now)
            }
            guard let request = RouterHTTPTransport.Request.soap(service: service, action: action, internalClient: route.sourceAddress,
                internalPort: port, externalPort: port, leaseSeconds: lifetime, mappingDescription: token ?? "RemSound audio") else {
                finish(.failure("UPnP request could not be constructed.")); return
            }
            let ticket = Ticket(stage); pending = ticket
            let cancel = http(request, remaining) { [self, ticket] result in
                guard !ticket.handled else { return }; ticket.handled = true; ticket.cancel()
                guard pending === ticket else { return }; pending = nil
                if let reason = terminal() { retired = true; retirement = reason }
                received(result, stage: stage)
            }
            ticket.install(cancel)
        }
        private func received(_ result: RouterHTTPTransport.Outcome, stage: Stage) {
            switch stage {
            case .preflight:
                guard !retired else { finishRetired(); return }
                switch result {
                case .soap(.fault(code: 714, description: _)): issue(.externalIP)
                case .soap(.mapping): finish(.occupied)
                default: finish(.failure("UPnP existing-rule preflight was refused or unavailable."))
                }
            case .externalIP:
                guard !retired else { finishRetired(); return }
                guard case .soap(.success(let address?)) = result, RouterMappingPackets.ipv4(address) != nil else {
                    finish(.failure("UPnP external address was invalid or unavailable.")); return
                }
                self.address = address; issue(.add)
            case .add:
                guard let claim else { finish(.failure("UPnP Add has no local claim.")); return }
                if case .soap(.success(externalAddress: nil)) = result {
                    knownAdd = true
                    if retired { finishRetired() } else { issue(.readback) }
                } else if result.mutationMayHaveOccurred {
                    finish(.uncertain(claim, reason: "UPnP Add reply was lost; remote state is unconfirmed."))
                } else if retired { finishRetired() }
                else { finish(.failure("UPnP Add was refused; no permanent-lease fallback was attempted.")) }
            case .readback:
                guard let claim else { finish(.failure("UPnP readback has no local claim.")); return }
                guard case .soap(.mapping(let mapping)) = result, mapping.internalClient == route.sourceAddress,
                      mapping.internalPort == port, mapping.enabled, mapping.description == claim.token,
                      mapping.leaseSeconds > 0, mapping.leaseSeconds <= maximumLease else {
                    finish(.acknowledged(claim, retired: retired, reason: "UPnP Add was accepted, but exact finite ownership readback was not verified.")); return
                }
                finish(.granted(.init(claim: claim, lifetime: mapping.leaseSeconds,
                    validUntil: claim.requestStarted + TimeInterval(mapping.leaseSeconds)), retired: retired))
            }
        }
        private func finishRetired() {
            if knownAdd, let claim { finish(.acknowledged(claim, retired: true, reason: "UPnP Add was accepted before this operation retired.")) }
            else { finish(retirement) }
        }
        private func finish(_ result: Outcome) { guard !done else { return }; done = true; completion(result) }
    }
}

final class UPnPMappingMaintenance {
    enum Action { case renew(lifetime: UInt32), remove }
    enum Outcome: Equatable {
        case renewed(UPnPMappingCreation.Lease, retired: Bool), removed, absent, expired
        case changed(UPnPMappingCreation.Claim, mutationAcknowledged: Bool)
        case retained(UPnPMappingCreation.Claim, mutationAcknowledged: Bool, reason: String)
        case uncertain(UPnPMappingCreation.Claim, reason: String)
        case refused, cancelled, timedOut, failure(String)
    }
    private let state: State
    init(lease: UPnPMappingCreation.Lease, action: Action, permitted: @escaping () -> Bool,
         clock: @escaping () -> TimeInterval, http: @escaping RouterCapability.HTTPFactory,
         completion: @escaping (Outcome) -> Void) {
        state = State(claim: lease.claim, validUntil: lease.validUntil, action: action,
            permitted: permitted, clock: clock, http: http, completion: completion)
    }
    init(claim: UPnPMappingCreation.Claim, permitted: @escaping () -> Bool,
         clock: @escaping () -> TimeInterval, http: @escaping RouterCapability.HTTPFactory,
         completion: @escaping (Outcome) -> Void) {
        // An unverified claim is only a bounded opportunity to inspect its exact marker.
        // It grants no authority to overwrite an occupied or permanent entry.
        state = State(claim: claim, validUntil: claim.requestStarted + TimeInterval(claim.requestedLifetime), action: .remove,
            permitted: permitted, clock: clock, http: http, completion: completion)
    }
    func start() { state.start() }
    func tick() { state.tick() }
    func cancel() { state.cancel() }
    deinit { state.cancel() }

    // All methods and injected receipts belong to the coordinator's serial executor.
    // Receipt state outlives the wrapper until HTTP reports actual quiescence.
    private final class State {
        private enum Stage { case preflight, externalIP, mutation, readback }
        private final class Ticket {
            var handled = false
            private var cancelSent = false, cancellation: (() -> Void)?
            func install(_ cancel: @escaping () -> Void) { if cancelSent { cancel() } else { cancellation = cancel } }
            func cancel() {
                guard !cancelSent else { return }; cancelSent = true
                let cancel = cancellation; cancellation = nil; cancel?()
            }
        }
        private static let maximumLease: UInt32 = 604800
        let original: UPnPMappingCreation.Claim, validUntil: TimeInterval, action: Action
        let permitted: () -> Bool, clock: () -> TimeInterval, http: RouterCapability.HTTPFactory
        let completion: (Outcome) -> Void
        private var began: TimeInterval?, pending: Ticket?, done = false, retired = false
        private var retirement: Outcome = .cancelled, mutationSubmitted = false, acknowledged = false
        private var changedClaim: UPnPMappingCreation.Claim?
        init(claim: UPnPMappingCreation.Claim, validUntil: TimeInterval, action: Action,
             permitted: @escaping () -> Bool, clock: @escaping () -> TimeInterval,
             http: @escaping RouterCapability.HTTPFactory, completion: @escaping (Outcome) -> Void) {
            original = claim; self.validUntil = validUntil; self.action = action
            self.permitted = permitted; self.clock = clock; self.http = http; self.completion = completion
        }
        func start() {
            guard !done, began == nil else { return }
            guard permitted() else { finish(.refused); return }
            if case .renew(let lifetime) = action, lifetime == 0 || lifetime > Self.maximumLease {
                finish(.failure("Invalid UPnP renewal lifetime.")); return
            }
            let now = clock()
            guard now.isFinite, now >= original.requestStarted, validUntil.isFinite else { finish(.failure("Invalid UPnP clock or expiry.")); return }
            guard now < validUntil else { finish(.expired); return }
            began = now; issue(.preflight)
        }
        func tick() {
            guard !done, pending != nil else { return }
            if let reason = terminal() { retired = true; retirement = reason; pending?.cancel() }
        }
        func cancel() {
            guard !done else { return }; retired = true; retirement = .cancelled
            if let pending { pending.cancel() } else { finishRetired() }
        }
        private func terminal() -> Outcome? {
            if retired { return retirement }
            guard permitted() else { return .refused }
            guard let began else { return nil }
            let now = clock()
            guard now.isFinite, now >= began else { return .failure("Invalid UPnP clock.") }
            if !mutationSubmitted, now >= validUntil { return .expired }
            return now - began >= UPnPMappingCreation.deadline ? .timedOut : nil
        }
        private var receiptClaim: UPnPMappingCreation.Claim { changedClaim ?? original }
        private func issue(_ stage: Stage) {
            guard !done, pending == nil, let began else { return }
            if let reason = terminal() { retired = true; retirement = reason; finishRetired(); return }
            let now = clock(), remaining = UPnPMappingCreation.deadline - (now - began)
            let soapAction: UPnPRouterProtocol.Action, lifetime: UInt32
            switch stage {
            case .preflight, .readback: soapAction = .specificMapping; lifetime = original.requestedLifetime
            case .externalIP: soapAction = .externalIP; lifetime = original.requestedLifetime
            case .mutation:
                switch action {
                case .remove: soapAction = .delete; lifetime = 0
                case .renew(let duration):
                    soapAction = .add; lifetime = duration
                    changedClaim = .init(route: original.route, service: original.service, token: original.token,
                        internalPort: original.internalPort, externalPort: original.externalPort,
                        externalAddress: original.externalAddress, requestedLifetime: duration, requestStarted: now)
                }
            }
            guard let request = RouterHTTPTransport.Request.soap(service: original.service, action: soapAction,
                internalClient: original.route.sourceAddress, internalPort: original.internalPort,
                externalPort: original.externalPort, leaseSeconds: lifetime, mappingDescription: original.token) else {
                finish(.failure("UPnP maintenance request could not be constructed.")); return
            }
            if case .mutation = stage { mutationSubmitted = true }
            let ticket = Ticket(); pending = ticket
            let cancel = http(request, remaining) { [self, ticket] result in
                guard !ticket.handled else { return }; ticket.handled = true; ticket.cancel()
                guard pending === ticket else { return }; pending = nil
                if let reason = terminal() { retired = true; retirement = reason }
                received(result, stage: stage)
            }
            ticket.install(cancel)
        }
        private func matches(_ mapping: UPnPPortMapping) -> Bool {
            mapping.internalClient == original.route.sourceAddress && mapping.internalPort == original.internalPort &&
                mapping.enabled && mapping.description == original.token && mapping.leaseSeconds > 0 && mapping.leaseSeconds <= Self.maximumLease
        }
        private func received(_ result: RouterHTTPTransport.Outcome, stage: Stage) {
            switch stage {
            case .preflight:
                guard !retired else { finishRetired(); return }
                switch result {
                case .soap(.fault(code: 714, description: _)): finish(.absent)
                case .soap(.mapping(let mapping)):
                    guard matches(mapping) else { finish(.changed(original, mutationAcknowledged: false)); return }
                    issue(.externalIP)
                default: finish(.retained(original, mutationAcknowledged: false, reason: "UPnP ownership preflight was refused or unavailable."))
                }
            case .externalIP:
                guard !retired else { finishRetired(); return }
                guard case .soap(.success(let address?)) = result else {
                    finish(.retained(original, mutationAcknowledged: false, reason: "UPnP external address was unavailable.")); return
                }
                guard address == original.externalAddress else { finish(.changed(original, mutationAcknowledged: false)); return }
                // UPnP has no compare-and-mutate primitive. This proof is not atomic
                // against another controller; the backend must serialize its own work.
                issue(.mutation)
            case .mutation:
                if case .soap(.success(externalAddress: nil)) = result {
                    acknowledged = true
                    if retired { finishRetired() } else { issue(.readback) }
                } else if result.mutationMayHaveOccurred {
                    finish(.uncertain(receiptClaim, reason: "UPnP mutation reply was lost; remote state is unconfirmed."))
                } else if case .remove = action, case .soap(.fault(code: 714, description: _)) = result { finish(.absent) }
                else { finish(.retained(original, mutationAcknowledged: false, reason: "UPnP mutation was refused or not acknowledged.")) }
            case .readback:
                switch action {
                case .remove:
                    switch result {
                    case .soap(.fault(code: 714, description: _)): finish(.removed)
                    case .soap(.mapping(let mapping)) where !matches(mapping): finish(.changed(original, mutationAcknowledged: true))
                    default: finish(.retained(original, mutationAcknowledged: true, reason: "UPnP Delete was accepted, but removal was not confirmed."))
                    }
                case .renew:
                    let claim = receiptClaim
                    guard case .soap(.mapping(let mapping)) = result, matches(mapping) else {
                        finish(.retained(claim, mutationAcknowledged: true, reason: "UPnP renewal was accepted, but exact finite readback was not verified.")); return
                    }
                    let expiry = claim.requestStarted + TimeInterval(mapping.leaseSeconds)
                    let now = clock()
                    guard now.isFinite, now >= claim.requestStarted, now < expiry else {
                        finish(.retained(claim, mutationAcknowledged: true, reason: "UPnP renewal readback arrived after its conservative expiry.")); return
                    }
                    finish(.renewed(.init(claim: claim, lifetime: mapping.leaseSeconds, validUntil: expiry), retired: retired))
                }
            }
        }
        private func finishRetired() {
            if acknowledged { finish(.retained(receiptClaim, mutationAcknowledged: true, reason: "UPnP mutation was accepted before this operation retired; remote state needs fresh inspection.")) }
            else { finish(retirement) }
        }
        private func finish(_ result: Outcome) { guard !done else { return }; done = true; completion(result) }
    }
}
