import Foundation

/// Observation model shared by the AppKit monitor and isolated tests. Owned by
/// the monitor's serial worker; no part of this model runs in an audio callback.
public struct ResponsivenessDiagnostics {
    public enum Operation: String {
        case startSession, stopSession, audioConfiguration, jitterBuffer, receiveSmoothness, receiveArtifact, peerSelection, showWindow, hideWindow, sessionViewUpdate
    }
    public enum ActionOutcome { case effectObserved, localStateOnly, failed, superseded }
    public enum EventKind: String {
        case handlerReturned, effectObserved, localStateOnly, failed, superseded, expired, probeDelayed, probeRecovered
    }
    public struct Event {
        public let kind: EventKind
        public let operation: Operation?
        public let id: UUID
        public let observedAt: TimeInterval
        public let seconds: TimeInterval
        public var description: String {
            "UI observation \(kind.rawValue): \(operation?.rawValue ?? "no tagged action"), "
                + "id \(id), observed monotonic \(String(format: "%.6f", observedAt)) s, "
                + "\(String(format: "%.3f", seconds * 1000)) ms. "
                + "Operation is context, not proof of a stall's cause; effect time may include permission dialogs."
        }
    }
    private struct Action {
        let operation: Operation
        let began: TimeInterval
        var handlerReturned = false
    }
    private struct Probe {
        let id: UUID
        let began: TimeInterval
        var warned = false
    }
    public static let stallThresholdSeconds: TimeInterval = 0.1
    private static let actionObservationLimit: TimeInterval = 30
    private static let maximumPendingActions = 64
    private var actions = [UUID: Action]()
    private var actionOrder = [UUID]()
    private var probe: Probe?
    private var lastOperation: Operation?
    var pendingActionCount: Int { actions.count }
    public var hasPendingProbe: Bool { probe != nil }
    public init() {}

    @discardableResult
    public mutating func beginAction(id: UUID, operation: Operation, at: TimeInterval) -> Event? {
        guard at.isFinite else { return nil }
        var evicted: Event?
        if actions[id] != nil { actionOrder.removeAll { $0 == id } }
        else if actions.count == Self.maximumPendingActions, let oldest = actionOrder.first {
            evicted = removeAction(id: oldest, kind: .superseded, at: max(at, actions[oldest]?.began ?? at))
        }
        actions[id] = Action(operation: operation, began: at)
        actionOrder.append(id)
        lastOperation = operation
        return evicted
    }
    public mutating func handlerReturned(id: UUID, at: TimeInterval) -> Event? {
        guard let action = actions[id], !action.handlerReturned, at.isFinite, at >= action.began else { return nil }
        actions[id]?.handlerReturned = true
        return .init(kind: .handlerReturned, operation: action.operation, id: id, observedAt: at, seconds: at - action.began)
    }
    public mutating func finishAction(id: UUID, outcome: ActionOutcome, at: TimeInterval) -> Event? {
        let kind: EventKind
        switch outcome {
        case .effectObserved: kind = .effectObserved
        case .localStateOnly: kind = .localStateOnly
        case .failed: kind = .failed
        case .superseded: kind = .superseded
        }
        return removeAction(id: id, kind: kind, at: at)
    }
    private mutating func removeAction(id: UUID, kind: EventKind, at: TimeInterval) -> Event? {
        guard let action = actions[id], at.isFinite, at >= action.began else { return nil }
        actions.removeValue(forKey: id)
        actionOrder.removeAll { $0 == id }
        return .init(kind: kind, operation: action.operation, id: id, observedAt: at, seconds: at - action.began)
    }
    public mutating func expireActions(at: TimeInterval) -> [Event] {
        actionOrder.compactMap { id in
            guard let action = actions[id], at - action.began > Self.actionObservationLimit else { return nil }
            return removeAction(id: id, kind: .expired, at: at)
        }
    }
    public mutating func beginProbe(id: UUID, at: TimeInterval) -> Bool {
        guard probe == nil, at.isFinite else { return false }
        probe = Probe(id: id, began: at)
        return true
    }
    private var context: Operation? {
        for id in actionOrder.reversed() {
            if let action = actions[id], !action.handlerReturned { return action.operation }
        }
        return lastOperation
    }
    public mutating func poll(at: TimeInterval) -> Event? {
        guard let probe, !probe.warned, at.isFinite, at - probe.began > Self.stallThresholdSeconds else { return nil }
        self.probe?.warned = true
        return .init(kind: .probeDelayed, operation: context, id: probe.id, observedAt: at, seconds: at - probe.began)
    }
    public mutating func probeCompleted(id: UUID, at: TimeInterval) -> Event? {
        guard let probe, probe.id == id, at.isFinite, at >= probe.began else { return nil }
        self.probe = nil
        guard probe.warned || at - probe.began > Self.stallThresholdSeconds else { return nil }
        return .init(kind: .probeRecovered, operation: context, id: id, observedAt: at, seconds: at - probe.began)
    }
    public mutating func reset() {
        actions.removeAll()
        actionOrder.removeAll()
        probe = nil
        lastOperation = nil
    }
}
