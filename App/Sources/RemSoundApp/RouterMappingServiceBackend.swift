import Foundation
import RemSoundCore

// A value-only seam for App fixtures. Production keeps the same Core service,
// including its unresolved evidence, across every attempt and lease.
@MainActor
struct RouterMappingServiceCalls {
    typealias Reply = (RouterMappingService.Receipt) -> Void
    typealias Cancel = () -> Bool
    let enable: (@escaping Reply) -> Cancel
    let open: (UInt16, UInt32, @escaping Reply) -> Cancel
    let renew: (UUID, UInt32, @escaping Reply) -> Cancel
    let remove: (UUID, @escaping Reply) -> Cancel
    let stop: (@escaping Reply) -> Cancel
    let shutdown: (@escaping Reply) -> Cancel
    init(service: RouterMappingService) {
        enable = { reply in let request = service.setEnabled(true, completion: reply); return { request.cancel() } }
        open = { port, duration, reply in let request = service.open(port: port, lifetime: duration, completion: reply); return { request.cancel() } }
        renew = { id, duration, reply in let request = service.renew(id, lifetime: duration, completion: reply); return { request.cancel() } }
        remove = { id, reply in let request = service.remove(id, completion: reply); return { request.cancel() } }
        stop = { reply in let request = service.stop(completion: reply); return { request.cancel() } }
        shutdown = { reply in let request = service.shutdown(completion: reply); return { request.cancel() } }
    }
    init(enable: @escaping (@escaping Reply) -> Cancel, open: @escaping (UInt16, UInt32, @escaping Reply) -> Cancel,
         renew: @escaping (UUID, UInt32, @escaping Reply) -> Cancel, remove: @escaping (UUID, @escaping Reply) -> Cancel,
         stop: @escaping (@escaping Reply) -> Cancel, shutdown: @escaping (@escaping Reply) -> Cancel) {
        self.enable = enable; self.open = open; self.renew = renew; self.remove = remove; self.stop = stop; self.shutdown = shutdown
    }
}

struct RouterMappingServiceError: LocalizedError {
    let message: String
    let retryNotBeforeUptime: TimeInterval?
    let requiresRecovery: Bool
    let serviceClosed: Bool
    let isCancellation: Bool
    var errorDescription: String? { message }
    init(_ message: String, receipt: RouterMappingService.Receipt? = nil, closed: Bool = false) {
        self.message = message
        let retry = receipt?.snapshot.retryNotBeforeUptime
        retryNotBeforeUptime = retry?.isFinite == true ? retry : nil
        requiresRecovery = receipt?.snapshot.hasUnresolvedState == true
        serviceClosed = closed || receipt?.snapshot.closed == true
        isCancellation = receipt?.outcome == .cancelled
    }
}

@MainActor
final class RouterMappingServiceBackend: RouterMappingBackend {
    private static let maximumRequestedLifetime = 604800
    fileprivate final class Action {
        enum Phase { case pending, enabled, delivered }
        var cancelled = false, finished = false
        var phase = Phase.pending
        private var cancelCurrent: RouterMappingServiceCalls.Cancel?
        func install(_ cancel: @escaping RouterMappingServiceCalls.Cancel) {
            guard !finished else { return }
            cancelCurrent = cancel
            if cancelled { _ = cancel() }
        }
        func cancel() {
            guard !finished, !cancelled else { return }
            cancelled = true; _ = cancelCurrent?()
        }
        func finish() -> Bool {
            guard !finished else { return false }
            finished = true; cancelCurrent = nil; return true
        }
    }
    fileprivate final class State {
        let calls: RouterMappingServiceCalls, clock: () -> TimeInterval
        var closed = false
        private var active: Action?
        private var queue: [(Action, () -> Void)] = []
        private var shutdownReplies: [(Result<Void, Error>) -> Void] = []
        private var shutdownResult: Result<Void, Error>?
        init(_ calls: RouterMappingServiceCalls, _ clock: @escaping () -> TimeInterval) { self.calls = calls; self.clock = clock }
        func enqueue(_ action: Action, _ work: @escaping () -> Void) { queue.append((action, work)); drain() }
        func end(_ action: Action) {
            guard action.finish() else { return }
            if active === action { active = nil }; drain()
        }
        private func drain() {
            guard active == nil, !queue.isEmpty else { return }
            let (action, work) = queue.removeFirst(); active = action; work()
        }
        func close(_ completion: @escaping (Result<Void, Error>) -> Void) {
            if let shutdownResult { completion(shutdownResult); return }
            shutdownReplies.append(completion)
            guard !closed else { return }
            closed = true; queue.forEach { $0.0.cancel() }; active?.cancel()
            let action = Action()
            enqueue(action) { [self] in
                _ = calls.shutdown { receipt in
                    Task { @MainActor in
                        guard !action.finished else { return }
                        let result: Result<Void, Error>
                        if receipt.snapshot.closed, !receipt.snapshot.hasUnresolvedState,
                           receipt.snapshot.mapping == nil, receipt.outcome == .ready || receipt.outcome == .removed {
                            result = .success(())
                        } else { result = .failure(Self.error(receipt)) }
                        shutdownResult = result; let replies = shutdownReplies; shutdownReplies = []
                        end(action); replies.forEach { $0(result) }
                    }
                }
            }
        }
        static func error(_ receipt: RouterMappingService.Receipt) -> RouterMappingServiceError {
            let message: String
            switch receipt.outcome {
            case .failed(let text), .blocked(let text): message = text
            case .cancelled: message = "The router operation was cancelled."
            case .refused: message = "The router operation was refused."
            default: message = "The router operation did not confirm usable state."
            }
            return RouterMappingServiceError(message, receipt: receipt)
        }
        func usable(_ receipt: RouterMappingService.Receipt, id: UUID? = nil) -> RouterMappingService.Mapping? {
            guard !closed, receipt.snapshot.enabled, !receipt.snapshot.closed, !receipt.snapshot.hasUnresolvedState,
                  case let .mapped(mapping) = receipt.outcome, receipt.snapshot.mapping == mapping,
                  id == nil || mapping.id == id, mapping.externalPort > 0,
                  mapping.remainingLifetime(at: clock()) > 0 else { return nil }
            return mapping
        }
    }
    private let state: State
    init(service: RouterMappingService, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        state = State(.init(service: service), clock)
    }
    init(calls: RouterMappingServiceCalls, clock: @escaping () -> TimeInterval) { state = State(calls, clock) }
    deinit { MainActor.assumeIsolated { state.close { _ in } } }
    func shutdown(_ completion: @escaping (Result<Void, Error>) -> Void = { _ in }) { state.close(completion) }
    func open(port: UInt16, leaseSeconds: Int, completion: @escaping (Result<RouterMappingLease?, Error>) -> Void) -> () -> Void {
        let action = Action(), state = self.state
        guard port > 0, leaseSeconds > 0, leaseSeconds <= Self.maximumRequestedLifetime, !state.closed else {
            action.finish(); completion(.failure(RouterMappingServiceError("The router mapping request is invalid or closed.", closed: state.closed))); return {}
        }
        state.enqueue(action) {
            guard !action.cancelled, !state.closed else {
                state.end(action); completion(.failure(RouterMappingServiceError("The router operation was cancelled."))); return
            }
            action.install(state.calls.enable { receipt in
                Task { @MainActor in
                    guard !action.finished, action.phase == .pending else { return }
                    action.phase = .enabled
                    guard !action.cancelled, !state.closed, receipt.outcome == .ready, receipt.snapshot.enabled,
                          !receipt.snapshot.closed, !receipt.snapshot.hasUnresolvedState else {
                        state.end(action); completion(.failure(State.error(receipt))); return
                    }
                    action.install(state.calls.open(port, UInt32(leaseSeconds)) { receipt in
                        Task { @MainActor in
                            guard !action.finished, action.phase == .enabled else { return }
                            action.phase = .delivered
                            if action.cancelled, case let .mapped(mapping) = receipt.outcome {
                                // Core may have completed before the main actor saw its
                                // receipt. Retire that exact handle before reporting cancellation.
                                _ = state.calls.remove(mapping.id) { cleanup in
                                    Task { @MainActor in
                                        guard !action.finished else { return }
                                        state.end(action); completion(.failure(State.error(cleanup)))
                                    }
                                }
                                return
                            }
                            let result: Result<RouterMappingLease?, Error>
                            if !action.cancelled, let mapping = state.usable(receipt) {
                                result = .success(Lease(state, mapping, UInt32(leaseSeconds)))
                            } else if !action.cancelled, receipt.outcome == .unavailable, !receipt.snapshot.closed,
                                      !receipt.snapshot.hasUnresolvedState, receipt.snapshot.mapping == nil {
                                result = .success(nil)
                            } else { result = .failure(State.error(receipt)) }
                            state.end(action); completion(result)
                        }
                    })
                }
            })
        }
        return { action.cancel() }
    }
    @MainActor
    fileprivate final class Lease: RouterMappingLease {
        private let state: State, duration: UInt32
        private var mapping: RouterMappingService.Mapping
        private var retiring = false
        private var removalReplies: [(Result<Void, Error>) -> Void]?
        private var removalResult: Result<Void, Error>?
        var externalAddress: String? { mapping.externalAddress }
        var externalPort: UInt16 { mapping.externalPort }
        var expiresAtUptime: TimeInterval? { mapping.expiresAtUptime }
        var epochChanged: Bool { mapping.epochChanged }
        var validFor: TimeInterval { retiring || state.closed ? 0 : mapping.remainingLifetime(at: state.clock()) }
        init(_ state: State, _ mapping: RouterMappingService.Mapping, _ duration: UInt32) {
            self.state = state; self.mapping = mapping; self.duration = duration
        }
        func renew(_ completion: @escaping (Result<TimeInterval, Error>) -> Void) -> () -> Void {
            let action = Action(), id = mapping.id
            state.enqueue(action) { [self] in
                guard !retiring, !state.closed, !action.cancelled, validFor > 0 else {
                    state.end(action); completion(.failure(RouterMappingServiceError("The router lease is retired or expired."))); return
                }
                action.install(state.calls.renew(id, duration) { receipt in
                    Task { @MainActor in
                        guard !action.finished, action.phase == .pending else { return }
                        action.phase = .enabled
                        if action.cancelled {
                            self.retiring = true
                            if case let .mapped(mapping) = receipt.outcome, mapping.id == id {
                                _ = self.state.calls.remove(id) { cleanup in
                                    Task { @MainActor in
                                        guard !action.finished else { return }
                                        self.removalResult = Self.removal(cleanup)
                                        self.state.end(action); completion(.failure(State.error(cleanup)))
                                    }
                                }
                                return
                            }
                        }
                        if receipt.snapshot.closed || receipt.snapshot.hasUnresolvedState || receipt.snapshot.mapping?.id != id {
                            self.retiring = true
                        }
                        let result: Result<TimeInterval, Error>
                        if !action.cancelled, !self.retiring, let mapping = self.state.usable(receipt, id: id) {
                            self.mapping = mapping; result = .success(self.validFor)
                        } else { result = .failure(State.error(receipt)) }
                        self.state.end(action); completion(result)
                    }
                })
            }
            return { action.cancel() }
        }
        private static func removal(_ receipt: RouterMappingService.Receipt) -> Result<Void, Error> {
            receipt.outcome == .removed && !receipt.snapshot.hasUnresolvedState && receipt.snapshot.mapping == nil
                ? .success(()) : .failure(State.error(receipt))
        }
        private func finishRemoval(_ receipt: RouterMappingService.Receipt, _ action: Action, allowReady: Bool = false) {
            guard !action.finished else { return }
            let result: Result<Void, Error>
            if allowReady, !receipt.snapshot.closed, !receipt.snapshot.hasUnresolvedState, receipt.snapshot.mapping == nil,
               receipt.outcome == .ready || receipt.outcome == .removed {
                result = .success(())
            } else { result = Self.removal(receipt) }
            removalResult = result; let replies = removalReplies ?? []; removalReplies = nil
            state.end(action); replies.forEach { $0(result) }
        }
        func remove() { remove { _ in } }
        func remove(_ completion: @escaping (Result<Void, Error>) -> Void) {
            if let removalResult { completion(removalResult); return }
            if removalReplies != nil { removalReplies?.append(completion); return }
            retiring = true; removalReplies = [completion]
            let action = Action(), id = mapping.id
            state.enqueue(action) { [self] in
                if let removalResult {
                    let replies = removalReplies ?? []; removalReplies = nil
                    state.end(action); replies.forEach { $0(removalResult) }; return
                }
                // Deletion is serialized and deliberately not cancellable by an old
                // request token. The persistent Core book keeps failed cleanup evidence.
                _ = state.calls.remove(id) { receipt in
                    Task { @MainActor in
                        guard !action.finished, action.phase == .pending else { return }
                        action.phase = .delivered
                        if receipt.outcome == .refused, !receipt.snapshot.closed, !receipt.snapshot.hasUnresolvedState,
                           receipt.snapshot.mapping == nil {
                            // A completed cancellation can already have retired this
                            // identifier. Snapshot nil alone is not remote absence:
                            // obtain a fresh Stop receipt within this exclusive lane.
                            _ = self.state.calls.stop { confirmation in
                                Task { @MainActor in self.finishRemoval(confirmation, action, allowReady: true) }
                            }
                        } else { self.finishRemoval(receipt, action) }
                    }
                }
            }
        }
    }
}
