import Carbon
import RemSoundCore
import XCTest
@testable import RemSoundApp

@MainActor
final class PushToTalkInputOwnerTests: XCTestCase {
    private final class Token: PushToTalkRegistrationLifetime { var stops = 0; func stop() { stops += 1 } }
    private final class Backend: PushToTalkRegistrationBackend {
        struct Attempt { let receive: (PushToTalkNativeKeyEvent) -> Bool; let disabled: () -> Void; let token: Token }
        struct Refused: LocalizedError { var errorDescription: String? { "Injected listener failure." } }
        var attempts: [Attempt] = []; var failNext = false
        func install(receive: @escaping (PushToTalkNativeKeyEvent) -> Bool, disabled: @escaping () -> Void) throws -> PushToTalkRegistrationLifetime {
            if failNext { failNext = false; throw Refused() }
            let token = Token(); attempts.append(.init(receive: receive, disabled: disabled, token: token)); return token
        }
    }
    private final class Sends { var values: [Bool] = []; var failures: [String] = [] }
    private let key = HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_A), modifiers: [])
    private func settings() -> PushToTalkSettings { var s = PushToTalkSettings(); s.enabled = true; return s }
    private func fixture() -> (PushToTalkKeyController, PushToTalkInputOwner, Backend, Sends) {
        let keys = PushToTalkKeyController(), backend = Backend(), sends = Sends()
        keys.replaceBinding(key); keys.sendTalking = { v, _ in sends.values.append(v) }
        let owner = PushToTalkInputOwner(keys: keys, settings: settings(), backend: backend, permitted: true)
        owner.onFailure = { sends.failures.append($0) }
        addTeardownBlock { owner.shutdown(); keys.shutdown() }
        return (keys, owner, backend, sends)
    }
    private func receipt(_ generation: UUID, _ settings: PushToTalkSettings? = nil) -> PushToTalkWorkerReceipt {
        .init(settings: settings ?? self.settings(), running: true, generation: generation)
    }
    private func arm(_ owner: PushToTalkInputOwner, generation: UUID = UUID()) {
        let request = owner.beginRequest(settings: settings())
        owner.observe(settings: settings(), running: true, generation: generation)
        owner.acknowledge(request, receipt: receipt(generation))
    }
    private func event(down: Bool = true, repeatKey: Bool = false) -> PushToTalkNativeKeyEvent {
        .init(keyCode: UInt32(kVK_ANSI_A), modifiers: [], down: down, isRepeat: repeatKey, milliseconds: 100)
    }
    func testUnrequestedViewCannotArmEvenWithCorrectChoices() {
        let (keys, owner, b, _) = fixture(); owner.observe(settings: settings(), running: true, generation: UUID())
        XCTAssertFalse(keys.isArmed); XCTAssertFalse(owner.isRegistered); XCTAssertTrue(b.attempts.isEmpty)
    }
    func testChangedEpochAndMatchingViewDoNotReplaceActualReceipt() {
        let (_, owner, b, _) = fixture(); let request = owner.beginRequest(settings: settings())
        owner.observe(settings: settings(), running: true, generation: UUID())
        XCTAssertTrue(owner.isCurrent(request)); XCTAssertTrue(b.attempts.isEmpty)
    }
    func testOnlyNewestRequestCanAcceptMatchingReceipt() {
        let (_, owner, b, _) = fixture(); let old = owner.beginRequest(settings: settings()), fresh = owner.beginRequest(settings: settings()), g = UUID()
        owner.observe(settings: settings(), running: true, generation: g)
        owner.acknowledge(old, receipt: receipt(g)); XCTAssertTrue(b.attempts.isEmpty); XCTAssertTrue(owner.isCurrent(fresh))
        owner.acknowledge(fresh, receipt: receipt(g)); XCTAssertTrue(owner.isRegistered); XCTAssertEqual(b.attempts.count, 1)
        owner.acknowledge(fresh, receipt: nil); XCTAssertTrue(owner.isRegistered)
    }
    func testReceiptBeforeViewWaitsForExactReceiptEpoch() {
        let (_, owner, b, _) = fixture(); let id = owner.beginRequest(settings: settings()), g = UUID()
        owner.acknowledge(id, receipt: receipt(g)); owner.observe(settings: settings(), running: true, generation: UUID())
        XCTAssertTrue(b.attempts.isEmpty)
        owner.observe(settings: settings(), running: true, generation: g); XCTAssertTrue(owner.isRegistered)
    }
    func testBeginImmediatelyRetiresHeldKeyAndQueuedOldCallbacks() throws {
        let (keys, owner, b, sends) = fixture(); arm(owner); let old = try XCTUnwrap(b.attempts.first)
        XCTAssertTrue(old.receive(event())); let id = owner.beginRequest(settings: settings())
        XCTAssertFalse(keys.talking); XCTAssertFalse(owner.isRegistered); XCTAssertEqual(old.token.stops, 1)
        XCTAssertFalse(old.receive(event())); XCTAssertFalse(old.receive(event(down: false)))
        XCTAssertEqual(sends.values, [true, false]); XCTAssertTrue(owner.isCurrent(id))
    }
    func testFailedMismatchedStoppedAndCancelledReceiptsNeverArm() {
        for mode in 0..<4 {
            let (_, owner, b, _) = fixture(); let id = owner.beginRequest(settings: settings()), g = UUID()
            owner.observe(settings: settings(), running: true, generation: g)
            if mode == 0 { owner.acknowledge(id, receipt: nil) }
            if mode == 1 { owner.acknowledge(id, receipt: receipt(g, .init())) }
            if mode == 2 { owner.acknowledge(id, receipt: .init(settings: settings(), running: false, generation: g)) }
            if mode == 3 { owner.invalidate(); owner.acknowledge(id, receipt: receipt(g)) }
            XCTAssertFalse(owner.isRegistered); XCTAssertTrue(b.attempts.isEmpty)
        }
    }
    func testLaterSourceEpochRetiresOldCallbacksWithoutInventingAnotherRequest() throws {
        let (keys, owner, b, _) = fixture(); arm(owner); let old = try XCTUnwrap(b.attempts.first)
        XCTAssertTrue(old.receive(event())); owner.observe(settings: settings(), running: true, generation: UUID())
        XCTAssertFalse(old.receive(event())); XCTAssertEqual(old.token.stops, 1); XCTAssertEqual(b.attempts.count, 2)
        XCTAssertTrue(b.attempts[1].receive(event(repeatKey: true))); XCTAssertFalse(keys.talking)
        XCTAssertTrue(b.attempts[1].receive(event())); XCTAssertTrue(keys.talking)
    }
    func testGeneralCaptureNeedsFieldFocusAndKeyWindowAndRestoresOnCloseReopen() {
        let (_, owner, b, _) = fixture(); arm(owner)
        owner.setCapture(editorOpen: false, fieldFocused: true, windowKey: true); XCTAssertFalse(owner.isRegistered)
        owner.setCapture(editorOpen: false, fieldFocused: true, windowKey: false); XCTAssertTrue(owner.isRegistered)
        owner.setCapture(editorOpen: false, fieldFocused: true, windowKey: true); XCTAssertFalse(owner.isRegistered)
        owner.setCapture(editorOpen: false, fieldFocused: false, windowKey: true); XCTAssertTrue(owner.isRegistered)
        XCTAssertEqual(b.attempts.map { $0.token.stops }, [1, 1, 0])
    }
    func testEditorPauseDoesNotDependOnForegroundAndCannotRearmPendingRequest() {
        let (_, owner, b, _) = fixture(); arm(owner); owner.setCapture(editorOpen: true)
        XCTAssertFalse(owner.isRegistered); owner.beginRequest(settings: settings()); owner.setCapture(editorOpen: false)
        XCTAssertFalse(owner.isRegistered); XCTAssertEqual(b.attempts.count, 1)
    }
    func testPermissionLossAndObservedStopRetireUntilFreshAcceptedStart() {
        let (_, owner, b, _) = fixture(); arm(owner); owner.setPermitted(false); XCTAssertFalse(owner.isRegistered)
        owner.setPermitted(true); XCTAssertTrue(owner.isRegistered)
        owner.observe(settings: settings(), running: false, generation: UUID()); XCTAssertFalse(owner.isRegistered)
        owner.observe(settings: settings(), running: true, generation: UUID()); XCTAssertFalse(owner.isRegistered)
        arm(owner); XCTAssertTrue(owner.isRegistered); XCTAssertEqual(b.attempts.count, 3)
    }
    func testNativeFailureReportedOnceNoViewTickRetriesAndExplicitRetryWorks() {
        let (_, owner, b, sends) = fixture(); b.failNext = true; let g = UUID(); arm(owner, generation: g)
        XCTAssertFalse(owner.isRegistered); XCTAssertEqual(sends.failures.count, 1)
        for _ in 0..<4 { owner.observe(settings: settings(), running: true, generation: g) }
        XCTAssertTrue(b.attempts.isEmpty); XCTAssertEqual(sends.failures.count, 1)
        owner.retry(); XCTAssertTrue(owner.isRegistered); XCTAssertEqual(b.attempts.count, 1)
    }
    func testReservedAliasesPreventNativeRegistrationAndBindingChangeKeepsOwnershipTruthful() {
        let (_, owner, b, _) = fixture(); owner.setReservedBindings([key]); arm(owner)
        XCTAssertFalse(owner.isRegistered); XCTAssertTrue(b.attempts.isEmpty)
        XCTAssertFalse(owner.replaceBinding(key)); owner.setReservedBindings([]); owner.retry(); XCTAssertTrue(owner.isRegistered)
    }
    func testShutdownClosesExactTokenRejectsPendingAckAndPhysicalRepeat() throws {
        let (keys, owner, b, _) = fixture(); arm(owner); let old = try XCTUnwrap(b.attempts.first)
        XCTAssertTrue(old.receive(event())); let pending = owner.beginRequest(settings: settings()); owner.shutdown(); owner.shutdown()
        owner.acknowledge(pending, receipt: receipt(UUID())); owner.observe(settings: settings(), running: true, generation: UUID())
        XCTAssertFalse(owner.isRegistered); XCTAssertFalse(keys.talking); XCTAssertFalse(old.receive(event())); XCTAssertEqual(old.token.stops, 1)
        XCTAssertEqual(b.attempts.count, 1)
    }
}
