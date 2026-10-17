import Foundation
import XCTest
@testable import RemSoundCore

final class ResponsivenessDiagnosticsTests: XCTestCase {
    func testOnlyOneOutstandingProbeAndOneWarningPerStall() {
        var state = ResponsivenessDiagnostics()
        let probe = UUID()
        XCTAssertTrue(state.beginProbe(id: probe, at: 0))
        XCTAssertFalse(state.beginProbe(id: UUID(), at: 0.05))
        XCTAssertNil(state.poll(at: 0.1))
        let delayed = state.poll(at: 0.101)
        XCTAssertEqual(delayed?.kind, .probeDelayed)
        XCTAssertEqual(delayed?.seconds ?? 0, 0.101, accuracy: 0.000001)
        XCTAssertNil(state.poll(at: 1))
        let recovered = state.probeCompleted(id: probe, at: 1.2)
        XCTAssertEqual(recovered?.kind, .probeRecovered)
        XCTAssertEqual(recovered?.seconds, 1.2)
        XCTAssertFalse(state.hasPendingProbe)
    }

    func testHandlerTimeAndStateEffectAreDifferentObservations() {
        var state = ResponsivenessDiagnostics()
        let action = UUID(), probe = UUID()
        state.beginAction(id: action, operation: .audioConfiguration, at: 1)
        XCTAssertTrue(state.beginProbe(id: probe, at: 1.01))
        XCTAssertEqual(state.poll(at: 1.15)?.operation, .audioConfiguration)
        let handler = state.handlerReturned(id: action, at: 1.3)
        XCTAssertEqual(handler?.kind, .handlerReturned)
        XCTAssertEqual(handler?.seconds ?? 0, 0.3, accuracy: 0.000001)
        let effect = state.finishAction(id: action, outcome: .effectObserved, at: 1.7)
        XCTAssertEqual(effect?.kind, .effectObserved)
        XCTAssertEqual(effect?.seconds ?? 0, 0.7, accuracy: 0.000001)
        XCTAssertEqual(effect?.observedAt, 1.7)
        XCTAssertNil(state.finishAction(id: action, outcome: .effectObserved, at: 1.8))
        XCTAssertEqual(state.probeCompleted(id: probe, at: 1.9)?.operation, .audioConfiguration)
    }

    func testBoundedActionsExpireAndResetIgnoresOldProbeCompletion() {
        var state = ResponsivenessDiagnostics()
        for _ in 0..<1_000 { state.beginAction(id: UUID(), operation: .peerSelection, at: 0) }
        XCTAssertEqual(state.pendingActionCount, 64)
        XCTAssertEqual(state.expireActions(at: 31).count, 64)
        XCTAssertEqual(state.pendingActionCount, 0)
        let oldProbe = UUID()
        XCTAssertTrue(state.beginProbe(id: oldProbe, at: 32))
        state.reset()
        XCTAssertNil(state.probeCompleted(id: oldProbe, at: 40))
        XCTAssertNil(state.poll(at: 40))
    }

    func testPromptRecoveryAndOutOfOrderClocksDoNotCreateFalseStalls() {
        var state = ResponsivenessDiagnostics()
        let probe = UUID(), action = UUID()
        XCTAssertTrue(state.beginProbe(id: probe, at: 10))
        XCTAssertNil(state.probeCompleted(id: UUID(), at: 10.2))
        XCTAssertNil(state.poll(at: 9))
        XCTAssertNil(state.probeCompleted(id: probe, at: 10.02))
        state.beginAction(id: action, operation: .startSession, at: 11)
        XCTAssertNil(state.handlerReturned(id: action, at: 10))
        XCTAssertEqual(state.finishAction(id: action, outcome: .failed, at: 12)?.kind, .failed)
        XCTAssertEqual(state.pendingActionCount, 0)
    }

    func testBackwardActionClockCannotBreakTheRetentionBound() {
        var state = ResponsivenessDiagnostics()
        for _ in 0..<64 { state.beginAction(id: UUID(), operation: .audioConfiguration, at: 100) }
        let evicted = state.beginAction(id: UUID(), operation: .startSession, at: 99)
        XCTAssertEqual(evicted?.kind, .superseded)
        XCTAssertEqual(evicted?.seconds, 0)
        XCTAssertEqual(state.pendingActionCount, 64)
    }
}
