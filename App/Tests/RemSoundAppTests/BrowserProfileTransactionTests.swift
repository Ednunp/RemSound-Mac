import Foundation
import RemSoundCore
import XCTest
@testable import RemSoundApp

@MainActor final class BrowserProfileTransactionTests: XCTestCase {
    private final class Backend: BrowserSessionBackend {
        var listenerState: BrowserListenerStatus.State = .off
        var stops = [()->Void](), closes = [()->Void]()
        func prepareStart(_ request: UUID, completion: @escaping (Bool)->Void) -> Bool { XCTFail("Stopped native prepare"); return false }
        func activate(_ request: UUID, binding: SessionNetworkBinding, options: BrowserListenerOptions, password: String) -> Bool { XCTFail("Stopped native activation"); return false }
        func activate(_ request: UUID, binding: SessionNetworkBinding, options: BrowserListenerOptions, password: String, completion: @escaping (BrowserListenerActivationResult)->Void) -> Bool { XCTFail("Stopped native activation"); return false }
        func stop(completion: @escaping ()->Void) -> Bool { stops.append(completion); return true }
        func shutdown(completion: @escaping ()->Void) -> Bool { closes.append(completion); return true }
    }
    private final class Storage: BrowserCredentialStorage {
        enum Fault: Error { case syntheticSecretMustNotBeLogged }
        var value: String? = "opened", reads = 0, saves = 0, deletes = 0, failRead = false, failWrite = false
        func load(maximumUTF8Bytes: Int) throws -> String? { reads += 1; if failRead { throw Fault.syntheticSecretMustNotBeLogged }; return value }
        func save(_ password: String) throws { saves += 1; value = password; if failWrite { throw Fault.syntheticSecretMustNotBeLogged } }
        func delete() throws { deletes += 1; value = nil; if failWrite { throw Fault.syntheticSecretMustNotBeLogged } }
    }
    @MainActor private final class Fixture {
        let backend = Backend(), store = Storage(), owner: BrowserSessionOwner
        var transaction: BrowserProfileTransaction?, model: BrowserListenerEdit?, queue = [()->Void]()
        var current = true, metadataAllowed = true, flags = BrowserListenerOptions(), replies = 0
        var ends = [BrowserListenerEdit.End](), effective = [BrowserListenerChoice]()
        init(readOnly: Bool = false, temporary: String? = nil) {
            owner = BrowserSessionOwner(backend: backend)
            guard let ticket = owner.beginConfiguration(.init(account: UUID(), revision: UUID(), readOnly: readOnly)) else { XCTFail("Missing configuration"); return }
            let access = BrowserCredentialAccess(owner: owner, configuration: ticket, storage: store, isCurrent: { [weak self] in self?.current == true }, execute: { [weak self] in self?.queue.append($0) })
            transaction = .init(owner: owner, ticket: ticket, access: access, options: .init(), temporaryPassword: temporary, isCurrent: { [weak self] in self?.current == true }, commitMetadata: { [weak self] value in
                guard let self else { return false }; self.flags = value; return self.metadataAllowed
            })
            transaction?.onEnd = { [weak self] result,_ in self?.ends.append(result) }
            transaction?.onEffective = { [weak self] value in self?.effective.append(value) }
        }
        func run() { if !queue.isEmpty { queue.removeFirst()() } }
    }
    private let changed = BrowserListenerChoice(options: .init(enabled: true, autoStart: true), password: "replacement")
    private func pump(_ condition: () -> Bool) { let end = Date().addingTimeInterval(2); while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) } }
    private func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    private func open(_ f: Fixture) {
        XCTAssertEqual(f.transaction?.open { [weak f] model in f?.model = model; f?.replies += 1 }, true)
    }
    private func ready(readOnly: Bool = false, temporary: String? = nil) -> Fixture {
        let f = Fixture(readOnly: readOnly, temporary: temporary); open(f); f.run(); if f.replies == 0 && f.store.reads > 0 { pump { f.replies == 1 } }; XCTAssertNotNil(f.model); return f
    }
    func testConstructionDoesNotBorrowAndOpenIsOneBoundedExplicitLoad() {
        let f = Fixture(); XCTAssertEqual(f.store.reads, 0); open(f)
        for _ in 0..<1000 { XCTAssertEqual(f.transaction?.open { _ in XCTFail("Duplicate open") }, false) }
        XCTAssertEqual(f.queue.count, 1); f.run(); pump { f.replies == 1 }; XCTAssertEqual(f.store.reads, 1); XCTAssertEqual(f.model?.choice.password, "opened")
    }
    func testOpenReplyCanImmediatelySubmitPreviewAfterLowerDeliveryCreditEnds() {
        let f = Fixture(); XCTAssertEqual(f.transaction?.open { [weak f] model in f?.model = model; f?.replies += 1; model?.update(self.changed) }, true)
        f.run(); pump { f.replies == 1 && f.model?.busy == false }; XCTAssertTrue(f.model?.message.isEmpty == true); XCTAssertEqual(f.effective.last, .empty)
    }
    func testLoadFailureReturnsNilOnceWithValueFreeErrorAndNoMetadata() {
        let f = Fixture(); f.store.failRead = true; open(f); f.run(); pump { f.replies == 1 }
        XCTAssertNil(f.model); XCTAssertEqual(f.ends, [.invalidated]); XCTAssertFalse(f.transaction?.message.contains("syntheticSecret") == true); XCTAssertEqual(f.flags, .init()); XCTAssertEqual(f.store.saves, 0)
    }
    func testStoredEmptyItemIsRefusedWithoutConflatingItWithAbsence() {
        let f = Fixture(); f.store.value = ""; open(f); f.run(); pump { f.replies == 1 }; XCTAssertNil(f.model); XCTAssertEqual(f.store.value, ""); XCTAssertEqual(f.store.deletes, 0); XCTAssertEqual(f.ends, [.invalidated])
    }
    func testAbsentCredentialCommitsAnExactDeleteReceiptInsteadOfSavingEmpty() {
        let f = Fixture(); f.store.value = nil; open(f); f.run(); pump { f.replies == 1 }; XCTAssertEqual(f.model?.choice.password, "")
        f.model?.accept(); XCTAssertEqual(f.queue.count, 1); f.run(); pump { !f.ends.isEmpty }; XCTAssertEqual(f.ends, [.accepted]); XCTAssertEqual(f.store.deletes, 1); XCTAssertEqual(f.store.saves, 0); XCTAssertNil(f.store.value)
    }
    func testWritableAcceptWaitsStagingThenRawPersistenceBeforeMetadataAndEnd() {
        let f = ready(); guard let model = f.model else { return XCTFail("Missing model") }; model.update(changed); model.accept(); pump { f.queue.count == 1 }
        XCTAssertTrue(f.ends.isEmpty); XCTAssertEqual(f.flags, .init()); XCTAssertEqual(f.store.value, "opened")
        f.run(); pump { !f.ends.isEmpty }; XCTAssertEqual(f.ends, [.accepted]); XCTAssertEqual(f.flags, changed.options); XCTAssertEqual(f.store.value, "replacement"); XCTAssertEqual(model.choice, .empty)
    }
    func testFailedStoreMayHaveSideEffectsButKeepsWindowAndMetadataUncommitted() {
        let f = ready(); guard let model = f.model else { return XCTFail("Missing model") }; f.store.failWrite = true; model.update(changed); model.accept(); pump { f.queue.count == 1 }; f.run(); pump { !model.busy }
        XCTAssertTrue(f.ends.isEmpty); XCTAssertEqual(f.store.value, "replacement"); XCTAssertEqual(f.flags, .init()); XCTAssertFalse(model.message.isEmpty); XCTAssertFalse(model.closingRequested)
    }
    func testMetadataRefusalRequiresExactCredentialAndFlagRestoreOnCancel() {
        let f = ready(); guard let model = f.model else { return XCTFail("Missing model") }; f.metadataAllowed = false; model.update(changed); model.accept(); pump { f.queue.count == 1 }; f.run(); pump { !model.busy }
        XCTAssertTrue(f.ends.isEmpty); XCTAssertEqual(f.store.value, "replacement"); f.metadataAllowed = true; model.cancel(); pump { f.queue.count == 1 }; f.run(); pump { !f.ends.isEmpty }
        XCTAssertEqual(f.ends, [.cancelled]); XCTAssertEqual(f.store.value, "opened"); XCTAssertEqual(f.flags, .init())
    }
    func testReadOnlyTemporaryAcceptNeverWritesOrDeletesCredential() {
        let f = ready(readOnly: true); guard let model = f.model else { return XCTFail("Missing model") }; model.update(changed); model.accept(); pump { !f.ends.isEmpty }
        XCTAssertEqual(f.ends, [.accepted]); XCTAssertEqual(f.flags, changed.options); XCTAssertEqual(f.store.value, "opened"); XCTAssertEqual(f.store.saves, 0); XCTAssertEqual(f.store.deletes, 0); XCTAssertTrue(f.queue.isEmpty)
    }
    func testReadOnlyWorkingPasswordRemainsUiStateSeparateFromStoredValue() {
        let f = ready(readOnly: true, temporary: "temporary"); XCTAssertEqual(f.model?.choice.password, "temporary"); XCTAssertEqual(f.store.value, "opened"); f.model?.cancel(); XCTAssertEqual(f.ends, [.cancelled]); XCTAssertEqual(f.store.value, "opened")
    }
    func testWritableContextIgnoresTemporaryPasswordOverlay() {
        let f = ready(temporary: "not-current-store"); XCTAssertEqual(f.model?.choice.password, "opened"); f.model?.cancel(); XCTAssertEqual(f.ends, [.cancelled])
    }
    func testCancelDuringCommitWaitsRawEffectThenRestoresOpenedCredential() {
        let f = ready(); guard let model = f.model else { return XCTFail("Missing model") }; model.update(changed); model.accept(); pump { f.queue.count == 1 }; model.cancel(); XCTAssertTrue(f.ends.isEmpty)
        f.run(); pump { f.queue.count == 1 }; XCTAssertTrue(f.ends.isEmpty); f.run(); pump { !f.ends.isEmpty }; XCTAssertEqual(f.ends, [.cancelled]); XCTAssertEqual(f.store.value, "opened"); XCTAssertEqual(f.flags, .init())
    }
    func testInvalidationWhileLoadingWaitsRawAndIndependentStopWithoutOldSecret() {
        let f = Fixture(); open(f); var closed = false; XCTAssertEqual(f.transaction?.close { closed = true }, true); XCTAssertFalse(closed); f.run(); drain(); XCTAssertFalse(closed); XCTAssertEqual(f.store.reads, 0)
        f.backend.stops.last?(); pump { closed }; XCTAssertEqual(f.replies, 1); XCTAssertNil(f.model); XCTAssertEqual(f.ends, [.invalidated])
    }
    func testPermanentCoreShutdownFirstCannotCompleteTransactionUiCallback() {
        let f = ready(); guard let model = f.model else { return XCTFail("Missing model") }; model.update(changed); model.accept(); pump { f.queue.count == 1 }
        var editorClosed = false, coreClosed = false; XCTAssertEqual(f.transaction?.close { editorClosed = true }, true); XCTAssertTrue(f.owner.shutdown { _ in coreClosed = true }); f.backend.closes.last?(); drain(); XCTAssertFalse(editorClosed); XCTAssertFalse(coreClosed)
        f.run(); drain(); XCTAssertFalse(editorClosed); f.backend.stops.last?(); pump { editorClosed && coreClosed }; XCTAssertEqual(f.ends, [.invalidated]); XCTAssertEqual(f.flags, .init()); XCTAssertEqual(f.store.value, "opened")
    }
    func testExternalRootContextLossAfterRawLoadSuppressesModelConstruction() {
        let f = Fixture(); open(f); f.run(); f.current = false; pump { f.replies == 1 }; XCTAssertNil(f.model); XCTAssertEqual(f.ends, [.invalidated])
    }
    func testForeignNewAccountContextCannotReceiveLoadedPassword() {
        let f = Fixture(); open(f); f.owner.invalidate(discardMutations: true); f.run(); f.backend.stops.first?(); pump { f.replies == 1 }; XCTAssertNil(f.model); XCTAssertEqual(f.store.reads, 0); XCTAssertEqual(f.ends, [.invalidated]); f.backend.stops.last?(); drain()
    }
    func testCloseWaitersAreBoundedAndReceiveOneCompletionAfterRealReceipts() {
        let f = Fixture(); open(f); var completions = 0
        for _ in 0..<16 { XCTAssertEqual(f.transaction?.close { completions += 1 }, true) }; XCTAssertEqual(f.transaction?.close { XCTFail("Refused waiter") }, false)
        f.run(); f.backend.stops.first?(); pump { completions == 16 }; XCTAssertEqual(completions, 16); XCTAssertEqual(f.replies, 1); f.backend.stops.first?(); drain(); XCTAssertEqual(completions, 16)
    }
    func testReleaseDoesNotRetainTransactionOrBorrowQueuedSecret() {
        let f = Fixture(); open(f); weak var transaction = f.transaction; f.transaction = nil; XCTAssertNil(transaction); f.run(); drain(); XCTAssertEqual(f.store.reads, 0); XCTAssertEqual(f.replies, 0); XCTAssertEqual(f.backend.stops.count, 1)
    }
    func testClosedModelReleasesPasswordBeforeEndAndWaiterCallbacks() {
        let f = ready(); guard let model = f.model else { return XCTFail("Missing model") }
        f.transaction?.onEnd = { _,value in XCTAssertEqual(model.choice, .empty); XCTAssertNotNil(value) }; model.cancel(); XCTAssertTrue(f.transaction?.finished == true); XCTAssertEqual(model.choice, .empty)
        XCTAssertEqual(f.transaction?.close { XCTAssertEqual(model.choice, .empty) }, true)
    }
    func testRootInvalidationBeforeQueuedSaveCannotReportAccepted() {
        let f = ready(); guard let model = f.model else { return XCTFail("Missing model") }; model.update(changed); model.accept(); pump { f.queue.count == 1 }; f.current = false; f.transaction?.invalidate(); f.run(); f.backend.stops.last?(); pump { !f.ends.isEmpty }
        XCTAssertEqual(f.ends, [.invalidated]); XCTAssertEqual(f.flags, .init()); XCTAssertEqual(f.store.value, "opened")
    }
    func testExternalSourceInvalidationNotifiesRootBeforeQueuedStorageCanBorrow() {
        let f = Fixture(); var notices = 0
        f.owner.onConfigurationInvalidated = { notices += 1; f.transaction?.invalidate() }
        open(f); f.owner.suspendSource()
        XCTAssertEqual(notices, 1); XCTAssertTrue(f.ends.isEmpty)
        f.run(); f.backend.stops.forEach { $0() }; pump { f.replies == 1 }
        XCTAssertEqual(f.store.reads, 0); XCTAssertNil(f.model); XCTAssertEqual(f.ends, [.invalidated])
        f.owner.invalidate(); XCTAssertEqual(notices, 2)
    }
    func testExternalReplacementClearsAlreadyShownValueSynchronously() {
        let f = ready(); var notices = 0
        f.owner.onConfigurationInvalidated = { notices += 1; f.transaction?.invalidate() }
        XCTAssertEqual(f.model?.choice.password, "opened")
        let replacement = f.owner.beginConfiguration(.init(account: UUID(), revision: UUID(), readOnly: false))
        XCTAssertNotNil(replacement); XCTAssertEqual(notices, 1)
        XCTAssertEqual(f.model?.choice, .empty); XCTAssertEqual(f.ends, [.invalidated])
        XCTAssertTrue(replacement.map { f.owner.isCurrentConfiguration($0) } == true)
    }
    func testIntentionalCompletionDoesNotRevokeRootConfigurationIdentity() {
        let f = ready(); var notices = 0
        f.owner.onConfigurationInvalidated = { notices += 1 }
        f.model?.cancel()
        XCTAssertEqual(notices, 0); XCTAssertEqual(f.ends, [.cancelled])
    }

    func testSourceInvalidationWithoutAnOpenWindowStillClearsRootCachedChoice() {
        let f = ready(); f.model?.cancel(); var cached: BrowserListenerChoice? = changed
        f.owner.onConfigurationInvalidated = { cached = nil }
        f.owner.suspendSource(); XCTAssertNil(cached)
        cached = changed; f.owner.invalidate(); XCTAssertNil(cached)
    }

}
