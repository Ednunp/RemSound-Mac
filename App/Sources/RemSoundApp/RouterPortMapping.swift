import Foundation

enum RouterMappingStatus { case disabled, searching, mapped, noRouterFound, cgnatDetected, mappingFailed }
struct RouterMappingState: Equatable {
    var status: RouterMappingStatus = .disabled
    var externalAddress: String?
    var externalPort: UInt16?
    var lastError: String?
}

@MainActor
protocol RouterMappingLease: AnyObject {
    var externalAddress: String? { get }
    var externalPort: UInt16 { get }
    var validFor: TimeInterval { get }
    var expiresAtUptime: TimeInterval? { get }
    func renew(_ completion: @escaping (Result<TimeInterval, Error>) -> Void) -> () -> Void
    func remove(_ completion: @escaping (Result<Void, Error>) -> Void)
}
@MainActor
extension RouterMappingLease {
    var expiresAtUptime: TimeInterval? { nil }
    func remove() { remove { _ in } }
}

@MainActor
protocol RouterMappingBackend: AnyObject {
    // Cancellation waits for quiescence and retains any already created mapping.
    func open(port: UInt16, leaseSeconds: Int, completion: @escaping (Result<RouterMappingLease?, Error>) -> Void) -> () -> Void
    func shutdown(_ completion: @escaping (Result<Void, Error>) -> Void)
}

@MainActor
final class RouterPortMapping {
    static let audioPort: UInt16 = 47830
    static let leaseSeconds = 3600
    static let renewInterval: TimeInterval = 900
    static let discoveryTimeout: TimeInterval = 8
    private(set) var state = RouterMappingState()
    var onChange: ((RouterMappingState) -> Void)?
    private let permitted: () -> Bool, clock: () -> TimeInterval
    private let makeBackend: () -> RouterMappingBackend
    private var backend: RouterMappingBackend?
    private var wanted = false, closed = false, restartAfterRetirement = false, retiring = false
    var isBlocked: Bool { blocked }
    private var blocked = false, clockBlocked = false
    private var lastFailure: String?, lastTime: TimeInterval?, retryNotBefore: TimeInterval?
    private var port = audioPort
    private var pending: Attempt?, owned: OwnedLease?
    private var shutdownResult: Result<Void, Error>?, backendShutdownResult: Result<Void, Error>?
    private var shutdownCompletions: [(Result<Void, Error>) -> Void] = []
    private var shutdownRetention: RouterPortMapping?
    private var shutdownCleanupFailure: Error?
    private var cleanups = 0
    private var cleanupTargets: [ObjectIdentifier: Int] = [:]
    private var expiresAt: TimeInterval = 0, nextDue: TimeInterval = 0

    // This exact deletion queue survives release of the UI owner. A late renewal
    // can require a second removal, but never concurrently with the first one.
    @MainActor private final class OwnedLease {
        private final class Removal { var handled = false }
        let value: RouterMappingLease
        private var active = false
        private var result: Result<Void, Error>?
        private var callbacks: [(Result<Void, Error>) -> Void] = [], next: [(Result<Void, Error>) -> Void] = []
        init(_ value: RouterMappingLease) { self.value = value }
        func remove(again: Bool = false, _ completion: @escaping (Result<Void, Error>) -> Void) {
            if !again, let result { completion(result); return }
            if active {
                if again { next.append(completion) } else { callbacks.append(completion) }
                return
            }
            callbacks.append(completion); start()
        }
        private func start() {
            active = true; let removal = Removal()
            value.remove { [self] result in
                guard !removal.handled else { return }; removal.handled = true
                self.result = result; active = false
                let replies = callbacks; callbacks = []; replies.forEach { $0(result) }
                if !next.isEmpty { callbacks = next; next = []; start() }
            }
        }
    }
    @MainActor private final class Attempt {
        let began: TimeInterval
        var renewal: OwnedLease?
        var retired = false, handled = false
        var delivered: RouterMappingLease?
        private var cancellation: (() -> Void)?
        private var cancelSent = false
        init(began: TimeInterval, renewal: OwnedLease? = nil) { self.began = began; self.renewal = renewal }
        func install(_ cancel: @escaping () -> Void) { if cancelSent { cancel() } else { cancellation = cancel } }
        func cancel() {
            guard !cancelSent else { return }; cancelSent = true
            let cancel = cancellation; cancellation = nil; cancel?()
        }
    }
    init(permitted: @escaping () -> Bool, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         makeBackend: @escaping () -> RouterMappingBackend) {
        self.permitted = permitted; self.clock = clock; self.makeBackend = makeBackend
    }
    deinit {
        MainActor.assumeIsolated {
            pending?.retired = true; owned?.remove { _ in }; pending?.cancel()
            if !closed { backend?.shutdown { _ in } }
        }
    }
    func setEnabled(_ enabled: Bool, port: UInt16 = audioPort) {
        guard !closed else { return }
        let changed = wanted != enabled || self.port != port
        wanted = enabled; self.port = port
        guard enabled, permitted(), port > 0 else {
            restartAfterRetirement = false; retire()
            publish(.init(status: enabled && port == 0 ? .mappingFailed : .disabled)); return
        }
        guard readClock() != nil else { return }
        guard !blocked else { publishFailure(lastFailure ?? "Router cleanup requires matching recovery."); return }
        guard changed else { return }
        restartAfterRetirement = true; retire(); publish(.init(status: .searching)); resumeAfterRetirement()
    }
    func tick() {
        guard !closed, wanted else { return }
        guard permitted(), port > 0 else { restartAfterRetirement = false; retire(); publish(.init()); return }
        guard let now = readClock(), !blocked else { return }
        if let owned, now >= expiresAt || !validGrant(owned.value.validFor) {
            nextDue = now + Self.renewInterval; restartAfterRetirement = false; retire()
            publishFailure("The router mapping lease expired."); return
        }
        if let pending {
            guard !pending.retired, now - pending.began >= Self.discoveryTimeout else { return }
            let renewing = pending.renewal != nil
            nextDue = now + Self.renewInterval; restartAfterRetirement = false; retire()
            publish(.init(status: renewing ? .mappingFailed : .noRouterFound,
                          lastError: renewing ? "The router did not answer the renewal." : nil)); return
        }
        guard cleanups == 0 else { return }
        if restartAfterRetirement { resumeAfterRetirement(); return }
        guard now >= nextDue else { return }
        if let owned { beginRenewal(owned, now: now) } else { beginOpen() }
    }
    func refresh() {
        guard !closed, wanted, permitted(), port > 0, !blocked, readClock() != nil else { return }
        restartAfterRetirement = true; retire(); publish(.init(status: .searching)); resumeAfterRetirement()
    }
    func shutdown(_ completion: @escaping (Result<Void, Error>) -> Void) {
        if let shutdownResult { completion(shutdownResult); return }
        shutdownCompletions.append(completion)
        // An observed terminal request holds its owner through all actual
        // receipts. Unobserved legacy teardown still leaves cleanup in backend.
        shutdownRetention = self
        shutdown(); completeShutdownIfReady()
    }
    func shutdown() {
        guard !closed else { return }; closed = true; wanted = false; restartAfterRetirement = false
        retire(); publish(.init())
        guard let backend else { backendShutdownResult = .success(()); completeShutdownIfReady(); return }
        backend.shutdown { [weak self] result in
            guard let self, backendShutdownResult == nil else { return }
            backendShutdownResult = result
            if case .failure(let error) = result { blocked = true; publishFailure(error.localizedDescription) }
            completeShutdownIfReady()
        }
    }
    private func completeShutdownIfReady() {
        guard closed, shutdownResult == nil, pending == nil, cleanups == 0, let backendShutdownResult else { return }
        let result: Result<Void, Error> = shutdownCleanupFailure.map { .failure($0) } ?? backendShutdownResult
        shutdownResult = result; let replies = shutdownCompletions; shutdownCompletions = []
        replies.forEach { $0(result) }; shutdownRetention = nil
    }
    private func retire() {
        retiring = true; defer { retiring = false }
        pending?.retired = true
        let previous = owned; owned = nil
        if let previous { clean(previous) }; pending?.cancel()
    }
    private func clean(_ lease: OwnedLease, again: Bool = false) {
        cleanups += 1; let target = ObjectIdentifier(lease)
        cleanupTargets[target, default: 0] += 1
        lease.remove(again: again) { [weak self] result in
            guard let self else { return }; cleanups -= 1
            let remaining = (cleanupTargets[target] ?? 1) - 1
            if remaining == 0 { cleanupTargets.removeValue(forKey: target) } else { cleanupTargets[target] = remaining }
            if case .failure(let error) = result {
                if closed { shutdownCleanupFailure = error }
                blocked = true; restartAfterRetirement = false; nextDue = .infinity; publishFailure(error.localizedDescription)
            }
            resumeAfterRetirement(); completeShutdownIfReady()
        }
    }
    private func beginOpen() {
        guard !closed, !retiring, !blocked, wanted, permitted(), port > 0, pending == nil, cleanups == 0,
              let now = readClock(), retryNotBefore.map({ now >= $0 }) ?? true else { return }
        restartAfterRetirement = false
        let attempt = Attempt(began: now); pending = attempt; publish(.init(status: .searching))
        guard pending === attempt, !attempt.retired, !closed, wanted, permitted() else {
            if pending === attempt { pending = nil }; attempt.handled = true; attempt.cancel(); resumeAfterRetirement(); return
        }
        if backend == nil { backend = makeBackend() }
        guard pending === attempt, !attempt.retired, !closed, wanted, permitted(), let backend else {
            if pending === attempt { pending = nil }; attempt.handled = true; attempt.cancel(); resumeAfterRetirement(); return
        }
        let cancel = backend.open(port: port, leaseSeconds: Self.leaseSeconds) { [weak self] result in
            if attempt.handled {
                if case let .success(lease?) = result, lease !== attempt.delivered { lease.remove() }; return
            }
            attempt.handled = true
            if case let .success(lease?) = result { attempt.delivered = lease }
            attempt.cancel()
            guard let self else { if case let .success(lease?) = result { lease.remove() }; return }
            completeOpen(attempt, result)
        }
        attempt.install(cancel)
    }
    private func completeOpen(_ attempt: Attempt, _ result: Result<RouterMappingLease?, Error>) {
        if pending === attempt { pending = nil }
        defer { completeShutdownIfReady() }
        guard !attempt.retired, !closed, wanted, permitted(), !blocked else {
            if case let .success(lease?) = result { clean(OwnedLease(lease)) }
            if case let .failure(error) = result { remember(error) }
            resumeAfterRetirement(); return
        }
        guard let now = readClock() else {
            if case let .success(lease?) = result { clean(OwnedLease(lease)) }; return
        }
        nextDue = now + Self.renewInterval
        switch result {
        case let .success(lease?):
            guard lease.externalPort > 0, setGrant(lease, duration: lease.validFor, now: now) else {
                clean(OwnedLease(lease)); publishFailure("The router returned an invalid mapping lease."); return
            }
            owned = OwnedLease(lease); publishMapped(lease)
        case .success(nil): publish(.init(status: .noRouterFound))
        case let .failure(error): remember(error); publishFailure(error.localizedDescription)
        }
    }
    private func beginRenewal(_ lease: OwnedLease, now: TimeInterval) {
        let attempt = Attempt(began: now, renewal: lease); pending = attempt
        let cancel = lease.value.renew { [weak self] result in
            guard !attempt.handled, let lease = attempt.renewal else { return }
            attempt.renewal = nil; attempt.handled = true; attempt.cancel()
            guard let self else { if case .success = result { lease.remove(again: true) { _ in } }; return }
            if pending === attempt { pending = nil }
            defer { completeShutdownIfReady() }
            guard !attempt.retired, !closed, wanted, permitted(), owned === lease, !blocked else {
                if case .success = result { clean(lease, again: true) }
                if case let .failure(error) = result {
                    remember(error, awaitingExactCleanup: cleanupTargets[ObjectIdentifier(lease)] != nil)
                }
                resumeAfterRetirement(); return
            }
            if case let .success(duration) = result, let now = readClock(), setGrant(lease.value, duration: duration, now: now) {
                publishMapped(lease.value); return
            }
            owned = nil
            let error: Error
            if case let .failure(value) = result { error = value }
            else { error = RouterMappingServiceError("The router returned an invalid renewed lease.") }
            remember(error); publishFailure(error.localizedDescription); clean(lease)
        }
        attempt.install(cancel)
    }
    private func remember(_ error: Error, awaitingExactCleanup: Bool = false) {
        lastFailure = error.localizedDescription
        if let error = error as? RouterMappingServiceError {
            // A cancellation receipt may precede the corresponding queued deletion.
            // Only that exact pending proof may settle it; failed/unknown evidence
            // and a closed service remain blocked without any local reset.
            if error.serviceClosed || (error.requiresRecovery && !(error.isCancellation && awaitingExactCleanup)) {
                blocked = true; nextDue = .infinity
            }
            if let deadline = error.retryNotBeforeUptime {
                guard deadline >= 0 else { blocked = true; nextDue = .infinity; return }
                retryNotBefore = max(retryNotBefore ?? 0, deadline)
                if let now = readClock(), !blocked { nextDue = max(now, retryNotBefore ?? now) }; return
            }
        }
        if let now = readClock(), !blocked { nextDue = now + Self.renewInterval }
    }
    private func readClock() -> TimeInterval? {
        guard !clockBlocked else { return nil }; let now = clock()
        guard now.isFinite, now >= 0, lastTime.map({ now >= $0 }) ?? true else {
            clockBlocked = true; blocked = true; restartAfterRetirement = false; nextDue = .infinity
            retire(); publishFailure("The router monotonic clock is invalid or moved backward."); return nil
        }
        lastTime = now; return now
    }
    private func resumeAfterRetirement() {
        guard !retiring, restartAfterRetirement, pending == nil, cleanups == 0 else { return }; beginOpen()
    }
    private func validGrant(_ duration: TimeInterval) -> Bool { duration.isFinite && duration > 0 }
    private func setGrant(_ lease: RouterMappingLease, duration: TimeInterval, now: TimeInterval) -> Bool {
        guard validGrant(duration) else { return false }
        let deadline = lease.expiresAtUptime ?? now + duration
        guard deadline.isFinite, deadline > now else { return false }
        expiresAt = deadline; nextDue = now + min(Self.renewInterval, (deadline - now) / 2); return true
    }
    private func publishMapped(_ lease: RouterMappingLease) {
        publish(.init(status: lease.externalAddress.map(Self.isCgnatAddress) == true ? .cgnatDetected : .mapped,
                      externalAddress: lease.externalAddress, externalPort: lease.externalPort))
    }
    private func publishFailure(_ message: String) { lastFailure = message; publish(.init(status: .mappingFailed, lastError: message)) }
    private func publish(_ value: RouterMappingState) { guard state != value else { return }; state = value; onChange?(value) }
    static func isCgnatAddress(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var bytes: [UInt8] = []
        for part in parts {
            guard let byte = UInt8(part), String(byte) == part else { return false }
            bytes.append(byte)
        }
        return bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127
    }
}
