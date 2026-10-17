import Foundation

/// Immutable observations from the hardware-free product checks, never a full-app acceptance gate.
public struct SelfCheckReport: Equatable, Sendable {
    public enum ID: String, CaseIterable, Sendable { case wire, format, encryption, ring, opus }
    public enum Status: String, Sendable { case passed, failed, notRun }
    public enum Termination: String, Sendable { case completed, cancelled, invalidBudget, invalidClock, deadline }
    public enum Unverified: String, CaseIterable, Sendable {
        case physicalAudio = "Physical capture and playback"
        case network = "UDP session and router"
        case accessibility = "Native keyboard and spoken output"
        case storageAndAssets = "Storage and packaged assets"
    }
    public struct Step: Equatable, Sendable {
        public let id: ID, status: Status
        public let assertions: Int
        public init(id: ID, status: Status, assertions: Int) { self.id=id;self.status=status;self.assertions=assertions }
    }
    public let steps: [Step]
    public let termination: Termination
    public init(steps: [Step], termination: Termination) { self.steps=steps;self.termination=termination }
    public var unverified: [Unverified] { Unverified.allCases }
    public var fullAcceptance: Bool { false }
    private static let maximumAssertions = 10_000
    public var isValid: Bool {
        guard steps.count == ID.allCases.count else { return false }
        guard zip(steps,ID.allCases).allSatisfy({ step,id in
            step.id == id && (0...Self.maximumAssertions).contains(step.assertions)
                && (step.status != .passed || step.assertions > 0)
                && (step.status != .notRun || step.assertions == 0)
        }) else { return false }
        return termination != .completed || !steps.contains { $0.status == .notRun }
    }
    public var exitCode: Int {
        guard isValid, !steps.contains(where:{ $0.status == .failed }) else { return 1 }
        switch termination {
        case .completed, .cancelled: return 3
        case .invalidBudget, .invalidClock, .deadline: return 1
        }
    }
}

public enum ProductSelfCheck {
    /// Synchronous, cooperative budget; does not query devices, storage, permissions or networks.
    public static func run(budget: Double) -> SelfCheckReport {
        let raw=CoreSelfCheck.run(budget:budget)
        func id(_ value: CoreSelfCheck.ID) -> SelfCheckReport.ID {
            switch value { case .wire: return .wire;case .format: return .format;case .encryption: return .encryption;case .ring: return .ring;case .opus: return .opus }
        }
        func status(_ value: CoreSelfCheck.Status) -> SelfCheckReport.Status {
            switch value { case .passed: return .passed;case .failed: return .failed;case .notRun: return .notRun }
        }
        let termination:SelfCheckReport.Termination
        switch raw.termination {
        case .completed: termination = .completed
        case .cancelled: termination = .cancelled
        case .invalidBudget: termination = .invalidBudget
        case .invalidClock: termination = .invalidClock
        case .deadline: termination = .deadline
        }
        return .init(steps:raw.steps.map { .init(id:id($0.id),status:status($0.status),assertions:$0.assertions) },termination:termination)
    }
}
