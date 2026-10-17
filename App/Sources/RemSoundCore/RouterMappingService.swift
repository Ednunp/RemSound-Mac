import Foundation
import RemSoundRuntime

public final class RouterMappingService {
    public struct Mapping: Equatable, Sendable {
        public let id: UUID, externalAddress: String, externalPort: UInt16
        public let observedAtUptime: TimeInterval, expiresAtUptime: TimeInterval, epochChanged: Bool
        public func remainingLifetime(at uptime: TimeInterval) -> TimeInterval {
            guard uptime.isFinite, observedAtUptime.isFinite, expiresAtUptime.isFinite, uptime >= observedAtUptime else { return 0 }
            return max(0, expiresAtUptime - uptime)
        }
    }
    public struct Unresolved: Equatable, Sendable {
        public let id: UUID, canRecover: Bool, reason: String
    }
    public struct Snapshot: Equatable, Sendable {
        public let enabled: Bool, closed: Bool, mapping: Mapping?, observedAtUptime: TimeInterval
        public let retryNotBeforeUptime: TimeInterval?, hasUnresolvedState: Bool, unresolved: [Unresolved]
    }
    public enum Outcome: Equatable, Sendable {
        case ready, mapped(Mapping), removed, unavailable, cancelled, refused, blocked(String), failed(String)
    }
    public struct Receipt: Equatable, Sendable {
        public let requestID: UUID, outcome: Outcome, snapshot: Snapshot
    }
    // Requests are explicitly cancelled. Dropping a token does not revoke an
    // already authorized operation; a completed token cannot retire newer work.
    public final class Request: @unchecked Sendable {
        public let id: UUID
        private let lock = NSLock()
        private var cancelled = false, completed = false
        private var onCancel: ((UUID) -> Void)?
        fileprivate init(_ onCancel: @escaping (UUID) -> Void) { id = UUID(); self.onCancel = onCancel }
        @discardableResult public func cancel() -> Bool {
            lock.lock()
            guard !completed, !cancelled else { lock.unlock(); return false }
            cancelled = true; let callback = onCancel; lock.unlock(); callback?(id); return true
        }
        fileprivate var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        fileprivate func finish() -> Bool {
            lock.lock(); defer { lock.unlock() }
            completed = true; onCancel = nil; return cancelled
        }
    }
    private let state: State
    public convenience init(configuration: RuntimeConfiguration) {
        let queue = DispatchQueue(label: "RemSound.Router.Service", qos: .utility)
        let native = RouterNativeOperations(runtime: configuration, queue: queue)
        self.init(queue: queue, callbackQueue: .main, allowed: { !configuration.isIsolated },
                  clock: { ProcessInfo.processInfo.systemUptime }, factory: native.make)
    }
    // Injection remains inside Core. App receives values/identifiers and never
    // gains construction or deletion authority over raw protocol leases/sockets.
    init(queue: DispatchQueue, callbackQueue: DispatchQueue, allowed: @escaping () -> Bool,
         clock: @escaping () -> TimeInterval, factory: @escaping RouterMappingTransactions.Factory) {
        state = State(queue, callbackQueue, allowed, clock, factory)
    }
    @discardableResult public func setEnabled(_ enabled: Bool, completion: @escaping (Receipt) -> Void) -> Request { issue(.choice(enabled), completion) }
    @discardableResult public func open(port: UInt16, lifetime: UInt32 = 3600, completion: @escaping (Receipt) -> Void) -> Request { issue(.open(port, lifetime), completion) }
    @discardableResult public func renew(_ id: UUID, lifetime: UInt32 = 3600, completion: @escaping (Receipt) -> Void) -> Request { issue(.renew(id, lifetime), completion) }
    @discardableResult public func remove(_ id: UUID, completion: @escaping (Receipt) -> Void) -> Request { issue(.remove(id), completion) }
    @discardableResult public func recover(_ id: UUID, completion: @escaping (Receipt) -> Void) -> Request { issue(.recover(id), completion) }
    @discardableResult public func stop(completion: @escaping (Receipt) -> Void) -> Request { issue(.stop, completion) }
    @discardableResult public func wake(completion: @escaping (Receipt) -> Void) -> Request { issue(.wake, completion) }
    @discardableResult public func snapshot(completion: @escaping (Receipt) -> Void) -> Request { issue(.snapshot, completion) }
    @discardableResult public func shutdown(completion: @escaping (Receipt) -> Void) -> Request { issue(.shutdown, completion) }
    private func issue(_ intent: State.Intent, _ completion: @escaping (Receipt) -> Void) -> Request { state.issue(intent, completion) }
    func tickForTesting() { state.queue.async { [state] in state.workflow?.tick() } }
    deinit { let state = self.state; state.queue.async { state.closeImplicitly() } }

    private final class State {
        enum Intent { case choice(Bool), open(UInt16, UInt32), renew(UUID, UInt32), remove(UUID), recover(UUID), stop, wake, snapshot, shutdown }
        private final class Context {
            var enabled = false, closed = false
            var current: Request?
        }
        private final class Pending {
            let request: Request, intent: Intent, completion: (Receipt) -> Void
            var completing = false
            init(_ request: Request, _ intent: Intent, _ completion: @escaping (Receipt) -> Void) {
                self.request = request; self.intent = intent; self.completion = completion
            }
        }
        let queue: DispatchQueue, callbackQueue: DispatchQueue, clock: () -> TimeInterval
        private let allowed: () -> Bool, factory: RouterMappingTransactions.Factory, context = Context()
        fileprivate var workflow: RouterMappingWorkflow?
        private var pending: [UUID: Pending] = [:]
        init(_ queue: DispatchQueue, _ callbacks: DispatchQueue, _ allowed: @escaping () -> Bool,
             _ clock: @escaping () -> TimeInterval, _ factory: @escaping RouterMappingTransactions.Factory) {
            self.queue = queue; callbackQueue = callbacks; self.allowed = allowed; self.clock = clock; self.factory = factory
        }
        func issue(_ intent: Intent, _ completion: @escaping (Receipt) -> Void) -> Request {
            let request = Request { [weak self] id in
                guard let self else { return }; queue.async { self.cancel(id) }
            }
            let value = Pending(request, intent, completion)
            queue.async { [self] in begin(value) }; return request
        }
        private func prepare() {
            guard workflow == nil else { return }
            let context = self.context
            workflow = RouterMappingWorkflow(allowed: allowed, enabled: { context.enabled }, clock: clock, factory: { [factory] operation, gate, reply in
                let request = context.current
                return factory(operation, { gate() && (operation.isCleanup || request?.isCancelled == false) }, reply)
            })
        }
        private func begin(_ value: Pending) {
            pending[value.request.id] = value; prepare()
            if value.request.isCancelled { finish(value, .cancelled); return }
            if case .snapshot = value.intent { finish(value, .ready); return }
            guard !context.closed, let workflow else { finish(value, .refused); return }
            if case .choice(true) = value.intent {
                if value.request.finish() { finish(value, .cancelled); return }
                context.enabled = true; finish(value, .ready); return
            }
            context.current = value.request
            let completed: (RouterMappingWorkflow.Outcome) -> Void = { [self, value] in complete(value, $0) }
            switch value.intent {
            case .choice(false): context.enabled = false; workflow.stop(completion: completed)
            case .open(let port, let duration): workflow.open(internalPort: port, lifetime: duration, completion: completed)
            case .renew(let id, let duration): workflow.renew(id, lifetime: duration, completion: completed)
            case .remove(let id): workflow.remove(id, completion: completed)
            case .recover(let id): workflow.recover(id, completion: completed)
            case .stop: workflow.stop(completion: completed)
            case .wake: workflow.wake(completion: completed)
            case .shutdown: context.closed = true; context.enabled = false; workflow.shutdown(completion: completed)
            case .snapshot, .choice(true): break
            }
        }
        private func cancel(_ id: UUID) {
            guard let value = pending[id], !value.completing, context.current?.id == id, !context.closed else { return }
            workflow?.stop { [self] _ in
                if context.current?.id == id { context.current = nil }
            }
            // The original request's callback follows its actual quiescence/cleanup.
            // The internal Stop owns restoration but does not duplicate that callback.
        }
        func closeImplicitly() {
            guard !context.closed else { return }; context.closed = true; context.enabled = false
            prepare(); workflow?.shutdown { [self] _ in context.current = nil }
        }
        private func complete(_ value: Pending, _ outcome: RouterMappingWorkflow.Outcome) {
            guard pending[value.request.id] === value else { return }
            // Linearize cancellation admission and completion under the ticket lock,
            // before clocks/DTO construction can invoke reentrant code. A winning
            // cancellation still waits for its corresponding owned cleanup receipt.
            let cancelled = value.request.finish()
            value.completing = true
            if cancelled, context.current?.id == value.request.id, let grant = workflow?.current {
                workflow?.remove(grant.id) { [self, value] _ in finish(value, .cancelled) }; return
            }
            if cancelled { finish(value, .cancelled); return }
            switch outcome {
            case .mapped(let grant, _):
                let now = clock(), mapping = map(grant, at: now)
                finish(value, mapping.remainingLifetime(at: now) > 0 ? .mapped(mapping) : .failed("The router grant expired before delivery."))
            case .refused: finish(value, .refused)
            case .blocked(let reason): finish(value, .blocked(Self.reason(reason)))
            case .cancelled(let result):
                if result == nil {
                    switch value.intent { case .stop, .shutdown, .choice(false), .wake: finish(value, .ready); return; default: break }
                }
                finish(value, .cancelled)
            case .finished(let result): finish(value, translate(result.receipt))
            }
        }
        private func translate(_ receipt: RouterMappingTransactions.Receipt) -> Outcome {
            if receipt.confirmsRemoval { return .removed }
            switch receipt {
            case .capability(.unavailable): return .unavailable
            case .refused, .capability(.refused), .udp(.refused), .created(.refused), .maintained(.refused): return .refused
            case .blocked(let text): return .blocked(Self.reason(text))
            case .cancelled, .capability(.cancelled), .udp(.cancelled), .created(.cancelled), .maintained(.cancelled): return .cancelled
            case .capability(.failure(let text, _)), .udp(.failure(let text, _, _)), .created(.failure(let text)), .maintained(.failure(let text)):
                return .failed(Self.reason(text))
            case .udp(.existingMapping): return .failed("An existing router mapping was not accepted as owned.")
            case .udp(.expired), .maintained(.expired): return .failed("The router mapping lease expired; remote absence is unverified.")
            case .created(.occupied): return .failed("The router mapping slot is occupied.")
            case .created(.acknowledged), .created(.uncertain), .maintained(.uncertain), .maintained(.retained), .maintained(.changed), .udp(.retained):
                return .failed("Router mutation or cleanup is unconfirmed; matching inspection is required.")
            case .udp(.timedOut), .created(.timedOut), .maintained(.timedOut): return .failed("The router operation timed out.")
            default: return .failed("The router operation did not produce a usable mapping.")
            }
        }
        private func finish(_ value: Pending, _ outcome: Outcome) {
            guard pending.removeValue(forKey: value.request.id) === value else { return }
            let cancelled = value.request.finish()
            if context.current?.id == value.request.id { context.current = nil }
            let receipt = Receipt(requestID: value.request.id, outcome: cancelled ? .cancelled : outcome, snapshot: snapshot())
            callbackQueue.async { value.completion(receipt) }
        }
        private func map(_ grant: RouterMappingWorkflow.Grant, at now: TimeInterval) -> Mapping {
            let remaining = grant.remainingLifetime(at: now)
            return .init(id: grant.id, externalAddress: grant.externalAddress, externalPort: grant.externalPort,
                         observedAtUptime: now, expiresAtUptime: now.isFinite ? now + remaining : 0, epochChanged: grant.epochChanged)
        }
        private func snapshot() -> Snapshot {
            let now = clock(), mapping = workflow?.current.map { map($0, at: now) }
            let unresolved = workflow?.unresolvedEvidence.map { Unresolved(id: $0.id, canRecover: $0.target != nil, reason: Self.reason($0.reason)) } ?? []
            return .init(enabled: context.enabled, closed: context.closed, mapping: mapping, observedAtUptime: now,
                         retryNotBeforeUptime: workflow?.retryNotBefore, hasUnresolvedState: workflow?.hasUnresolvedState ?? false, unresolved: unresolved)
        }
        private static func reason(_ value: String) -> String {
            let text = value.unicodeScalars.prefix(256).map { CharacterSet.controlCharacters.contains($0) || $0 == "\u{2028}" || $0 == "\u{2029}" ? " " : String($0) }.joined()
            return text.isEmpty ? "Router operation failed." : text
        }
    }
}
