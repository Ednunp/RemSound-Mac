import Foundation
import RemSoundCore
import XCTest
@testable import RemSoundApp

@MainActor final class BrowserSessionEditorTests: XCTestCase {
    private final class Backend: BrowserSessionBackend {
        var listenerState: BrowserListenerStatus.State = .off
        var prepares = [(Bool) -> Void](), stops = [() -> Void](), closes = [() -> Void](), activations = [(BrowserListenerActivationResult) -> Void]()
        var acceptPrepare = true, acceptActivation = true, acceptStop = true
        var inline: BrowserListenerActivationResult?, hook: (() -> Void)?
        func prepareStart(_ request: UUID, completion: @escaping (Bool) -> Void) -> Bool { prepares.append(completion); return acceptPrepare }
        func activate(_ request: UUID, binding: SessionNetworkBinding, options: BrowserListenerOptions, password: String) -> Bool { XCTFail("Editor must never use admission-only activate"); return false }
        func activate(_ request: UUID, binding: SessionNetworkBinding, options: BrowserListenerOptions, password: String, completion: @escaping (BrowserListenerActivationResult) -> Void) -> Bool {
            activations.append(completion); hook?(); if let inline { completion(inline) }; return acceptActivation
        }
        func stop(completion: @escaping () -> Void) -> Bool { stops.append(completion); return acceptStop }
        func shutdown(completion: @escaping () -> Void) -> Bool { closes.append(completion); return true }
    }
    @MainActor private final class Fixture {
        let backend = Backend(), request = UUID(), binding = SessionNetworkBinding(port: 49123, generation: UUID())
        let worker = PushToTalkWorkerReceipt(settings: .init(), running: true, generation: UUID())
        var owner: BrowserSessionOwner!, ticket: BrowserSessionOwner.EditorTicket?, replies = [Bool]()
        var choice: BrowserListenerChoice { .init(options: .init(enabled: true, autoStart: true), password: "synthetic") }
        init() { owner = .init(backend: backend) }
    }
    private func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.003)) }
    private func ready() -> Fixture {
        let f = Fixture(); XCTAssertTrue(f.owner.beforeStart(f.request) { XCTAssertTrue($0) }); f.backend.prepares.last?(true); drain()
        f.owner.acknowledgeStart(f.request, binding: f.binding); f.owner.acknowledgeWorker(f.request, receipt: f.worker)
        f.owner.observe(running: true, binding: f.binding, workerGeneration: f.worker.generation); f.ticket = f.owner.beginEditing(); XCTAssertNotNil(f.ticket); return f
    }
    @discardableResult private func apply(_ f: Fixture, _ choice: BrowserListenerChoice? = nil) -> Bool {
        guard let ticket = f.ticket else { return false }
        return f.owner.apply(choice ?? f.choice, editor: ticket) { [weak f] in f?.replies.append($0) }
    }
    private func activate(_ f: Fixture) { XCTAssertTrue(apply(f)); f.backend.prepares.last?(true); drain(); XCTAssertEqual(f.backend.activations.count, 1) }
    func testNoEditorBeforeActualRootWorkerAndNetworkReceipts() { let f = Fixture(); XCTAssertNil(f.owner.beginEditing()) }
    func testOwnPreparationAndCompletedReceiptKeepSameEditorContext() {
        let f = ready(); guard let ticket = f.ticket else { return }; XCTAssertTrue(apply(f)); XCTAssertTrue(f.owner.isCurrentEditor(ticket)); XCTAssertEqual(f.replies, [])
        f.backend.prepares.last?(true); drain(); XCTAssertTrue(f.owner.isCurrentEditor(ticket)); XCTAssertEqual(f.replies, [])
        f.backend.activations.last?(.listening(port: 49124)); drain(); XCTAssertEqual(f.replies, [true]); XCTAssertTrue(f.owner.isCurrentEditor(ticket))
    }
    func testOffWaitsExactStopAndCanApplyAgainWithSameContext() {
        let f = ready(); XCTAssertTrue(apply(f, .empty)); XCTAssertEqual(f.backend.stops.count, 1); XCTAssertEqual(f.replies, [])
        f.backend.stops.last?(); drain(); XCTAssertEqual(f.replies, [true]); XCTAssertTrue(apply(f)); XCTAssertEqual(f.backend.prepares.count, 2)
        f.backend.prepares.last?(true); drain(); f.backend.activations.last?(.listening(port: 49124)); drain(); XCTAssertEqual(f.replies, [true,true])
    }
    func testActivationAdmissionIsNeverEditorSuccessAndUnavailableCanRetry() {
        let f = ready(); activate(f); XCTAssertEqual(f.replies, []); f.backend.activations.last?(.unavailable); drain(); XCTAssertEqual(f.replies, [false])
        XCTAssertTrue(apply(f)); f.backend.prepares.last?(true); drain(); f.backend.activations.last?(.listening(port: 49124)); drain(); XCTAssertEqual(f.replies, [false,true])
    }
    func testOneCreditRefusesThousandPreviewCallsWithoutReplyOrBorrow() {
        let f = ready(); activate(f); guard let ticket = f.ticket else { return }
        for _ in 0..<1000 { XCTAssertFalse(f.owner.apply(f.choice, editor: ticket) { _ in XCTFail("Refused callback") }) }
        XCTAssertEqual(f.backend.activations.count, 1); f.backend.activations.last?(.cancelled); drain(); XCTAssertEqual(f.replies, [false])
    }
    func testStopImmediatelyCancelsButWaitsBothRetirementAndActivationCallbacks() {
        let f = ready(); activate(f); var mutated = false
        f.owner.perform(.stopSession) { mutated = true }; XCTAssertEqual(f.backend.stops.count, 1); XCTAssertFalse(mutated)
        f.backend.stops.first?(); drain(); XCTAssertEqual(f.replies, []); XCTAssertFalse(mutated)
        f.backend.activations.last?(.listening(port: 49124)); drain(); XCTAssertEqual(f.replies, [false]); XCTAssertFalse(mutated)
        f.backend.stops.last?(); drain(); XCTAssertTrue(mutated)
    }
    func testActivationCallbackFirstCannotReleaseSeatOrSessionMutationEarly() {
        let f = ready(); activate(f); var mutated = false; f.owner.perform(.stopSession) { mutated = true }
        f.backend.activations.last?(.cancelled); drain(); XCTAssertEqual(f.replies, []); XCTAssertFalse(mutated)
        f.backend.stops.first?(); drain(); XCTAssertEqual(f.replies, [false]); XCTAssertFalse(mutated)
        f.backend.stops.last?(); drain(); XCTAssertTrue(mutated)
    }
    func testPendingPrepareIsStillOwnedAfterProfileInvalidation() {
        let f = ready(); XCTAssertTrue(apply(f)); guard let ticket = f.ticket else { return }; f.owner.invalidate(); XCTAssertFalse(f.owner.isCurrentEditor(ticket))
        f.backend.stops.first?(); drain(); XCTAssertEqual(f.replies, [])
        f.backend.prepares.last?(true); drain(); XCTAssertEqual(f.replies, [false]); XCTAssertTrue(f.backend.activations.isEmpty)
        f.backend.stops.last?(); drain()
    }
    func testShutdownWaitsPreviewRawReceiptEvenWhenFullCoreShutdownArrivesFirst() {
        let f = ready(); activate(f); var ended = false; XCTAssertTrue(f.owner.shutdown { _ in ended = true })
        f.backend.closes.last?(); f.backend.stops.first?(); drain(); XCTAssertFalse(ended); XCTAssertEqual(f.replies, [])
        f.backend.activations.last?(.cancelled); drain(); XCTAssertEqual(f.replies, [false]); XCTAssertTrue(ended)
    }
    func testPermissionAndAudioMutationsInvalidateBeforeLateProof() {
        for permission in [false,true] {
            let f = ready(); activate(f); guard let ticket = f.ticket else { continue }
            if permission { _ = f.owner.suspendForPermission() } else { f.owner.performSource(.audioOptions) { done in done(nil,false) } }
            XCTAssertFalse(f.owner.isCurrentEditor(ticket)); f.backend.activations.last?(.listening(port: 49124)); drain(); XCTAssertEqual(f.replies, [])
            f.backend.stops.first?(); drain(); XCTAssertEqual(f.replies, [false]); f.backend.stops.last?(); drain()
        }
    }
    func testBindingLossAndWorkerReplacementInvalidateEditor() {
        for worker in [false,true] {
            let f = ready(); guard let ticket = f.ticket else { continue }
            f.owner.observe(running: true, binding: worker ? f.binding : .init(port: f.binding.port,generation: UUID()), workerGeneration: worker ? UUID() : f.worker.generation)
            XCTAssertFalse(f.owner.isCurrentEditor(ticket)); XCTAssertFalse(apply(f)); f.backend.stops.last?(); drain()
        }
    }
    func testWindowAndForeignOwnerTicketsCannotBorrowOrApply() {
        let f = ready(), other = ready(); guard let old = f.ticket, let foreign = other.ticket else { return }
        f.ticket = f.owner.beginEditing(); XCTAssertFalse(f.owner.isCurrentEditor(old)); XCTAssertFalse(f.owner.isCurrentEditor(foreign))
        XCTAssertFalse(f.owner.apply(f.choice, editor: old) { _ in XCTFail("Old window") }); XCTAssertFalse(f.owner.apply(f.choice, editor: foreign) { _ in XCTFail("Foreign window") })
    }
    func testEndEditingCancelsOwnedWorkButDoesNotFabricateCallback() {
        let f = ready(); activate(f); guard let ticket = f.ticket else { return }; f.owner.endEditing(ticket); XCTAssertFalse(f.owner.isCurrentEditor(ticket)); XCTAssertEqual(f.replies, [])
        f.backend.activations.last?(.cancelled); drain(); XCTAssertEqual(f.replies, []); f.backend.stops.last?(); drain(); XCTAssertEqual(f.replies, [false])
    }
    func testRefusedActivationAndInlinePositiveCannotOverrideAdmission() {
        let f = ready(); f.backend.acceptActivation = false; f.backend.inline = .listening(port: 49124); activate(f); drain(); XCTAssertEqual(f.replies, [false])
    }
    func testFirstForeignReceiptMarshalsToMainAndCompletesOnce() {
        let f = ready(); activate(f); guard let callback = f.backend.activations.last else { return }; let ready = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { callback(.listening(port: 49124)); callback(.unavailable); ready.signal() }; XCTAssertEqual(ready.wait(timeout: .now()+1), .success)
        drain(); XCTAssertEqual(f.replies, [true])
    }
    func testZeroPortAndCancelledAreNeverPositiveReceipts() {
        for result: BrowserListenerActivationResult in [.listening(port: 0),.cancelled] { let f = ready(); activate(f); f.backend.activations.last?(result); drain(); XCTAssertEqual(f.replies, [false]) }
    }
    func testOversizedAndBlankEnabledSecretRefuseBeforePreparation() {
        let f = ready(); var choice = f.choice; choice.password = String(repeating: "é", count: 513); XCTAssertFalse(apply(f,choice)); choice.password = ""; XCTAssertFalse(apply(f,choice)); XCTAssertEqual(f.backend.prepares.count, 1)
    }
    func testRefusedInterruptionRejectsQueuedStartAndKeepsRawCredit() {
        let f = ready(); activate(f); f.backend.acceptStop = false; var rejected: Bool?, failures = 0
        f.owner.onFailure = { failures += 1 }; XCTAssertTrue(f.owner.beforeStart(UUID()) { rejected = $0 }); drain()
        XCTAssertEqual(rejected, false); XCTAssertEqual(failures, 1); XCTAssertEqual(f.replies, [])
        f.backend.activations.last?(.cancelled); drain(); XCTAssertEqual(f.replies, [false]); XCTAssertEqual(f.backend.prepares.count, 2)
    }
    func testReleaseRequestsBackendShutdownWithoutRetainingOwnerOrInventingCompletion() {
        let f = ready(); activate(f); weak var released = f.owner; f.owner = nil
        XCTAssertNil(released); XCTAssertEqual(f.backend.closes.count, 1); XCTAssertEqual(f.replies, [])
        f.backend.closes.last?(); f.backend.activations.last?(.cancelled); drain(); XCTAssertEqual(f.replies, [])
    }
    func testRepeatedInvalidationCoalescesOneImmediateRetirement() {
        let f = ready(); activate(f)
        for _ in 0..<200 { f.owner.suspendSource() }
        XCTAssertEqual(f.backend.stops.count, 1); f.backend.activations.last?(.cancelled); drain(); XCTAssertEqual(f.replies, [])
        f.backend.stops.first?(); drain(); XCTAssertEqual(f.replies, [false]); XCTAssertEqual(f.backend.stops.count, 2)
        f.backend.stops.last?(); drain(); XCTAssertEqual(f.backend.prepares.count, 2)
    }
    func testReentrantRawActivationInvalidationWinsOverInlineListening() {
        let f = ready(); guard let ticket = f.ticket else { return }
        f.backend.hook = { [weak f] in f?.owner.endEditing(ticket) }; f.backend.inline = .listening(port: 49124)
        activate(f); drain(); XCTAssertFalse(f.owner.isCurrentEditor(ticket)); XCTAssertEqual(f.replies, [])
        f.backend.stops.last?(); drain(); XCTAssertEqual(f.replies, [false])
    }
    func testActualEditCancelWaitsOwnerEnabledThenExactOffRestoration() {
        let f = ready(); guard let ticket = f.ticket else { return }
        guard let edit = BrowserListenerEdit(opened: .empty, isCurrent: { f.owner.isCurrentEditor(ticket) }, apply: { value, reply in
            f.owner.apply(value, editor: ticket, completion: reply)
        }) else { return XCTFail("Missing bounded actual editor") }
        var end: BrowserListenerEdit.End?, restored: BrowserListenerChoice?
        edit.ended = { end = $0; restored = $1 }; edit.update(f.choice); edit.cancel()
        func pump(_ done: () -> Bool) { let limit=Date().addingTimeInterval(2); while !done() && Date()<limit { drain() } }
        XCTAssertNil(end); f.backend.prepares.last?(true); pump {!f.backend.activations.isEmpty}; XCTAssertNil(end)
        f.backend.activations.last?(.listening(port: 49124)); pump {f.backend.stops.count==1}; XCTAssertNil(end); XCTAssertEqual(f.backend.stops.count, 1)
        f.backend.stops.last?(); pump {end != nil}; XCTAssertEqual(end, .cancelled); XCTAssertEqual(restored, .empty)
    }
    func testActualEditContextLossWaitsBothCallbacksAndNeverRestoresOldSecret() {
        let f = ready(); guard let ticket = f.ticket else { return }
        guard let edit = BrowserListenerEdit(opened: .empty, isCurrent: { f.owner.isCurrentEditor(ticket) }, apply: { value, reply in
            f.owner.apply(value, editor: ticket, completion: reply)
        }) else { return XCTFail("Missing bounded actual editor") }
        var end: BrowserListenerEdit.End?, value: BrowserListenerChoice?
        edit.ended = { end = $0; value = $1 }; edit.update(f.choice); f.owner.invalidate(); edit.invalidate()
        f.backend.stops.first?(); drain(); XCTAssertNil(end)
        f.backend.prepares.last?(true); drain(); XCTAssertEqual(end, .invalidated); XCTAssertNil(value); XCTAssertTrue(f.backend.activations.isEmpty)
        f.backend.stops.last?(); drain()
    }
    func testNewStartWaitsOldEditorCleanupAndCannotUseOldTicket() {
        let f = ready(); activate(f); let next = UUID(); var prepared = false; XCTAssertTrue(f.owner.beforeStart(next) { prepared = $0 })
        XCTAssertEqual(f.backend.prepares.count, 2); f.backend.stops.first?(); f.backend.activations.last?(.cancelled); drain(); XCTAssertEqual(f.backend.prepares.count, 3); XCTAssertFalse(prepared)
        f.backend.prepares.last?(true); drain(); XCTAssertTrue(prepared); XCTAssertFalse(apply(f))
    }
}
