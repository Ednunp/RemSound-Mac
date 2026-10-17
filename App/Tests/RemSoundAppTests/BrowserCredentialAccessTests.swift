import Foundation
import RemSoundCore
import XCTest
@testable import RemSoundApp

@MainActor final class BrowserCredentialAccessTests: XCTestCase {
    private final class Backend: BrowserSessionBackend {
        var listenerState: BrowserListenerStatus.State = .off
        var acceptStop = true
        var prepares = [(Bool) -> Void](), stops = [() -> Void](), closes = [() -> Void]()
        func prepareStart(_ request: UUID, completion: @escaping (Bool) -> Void) -> Bool { prepares.append(completion); return true }
        func activate(_ request: UUID, binding: SessionNetworkBinding, options: BrowserListenerOptions, password: String) -> Bool { false }
        func activate(_ request: UUID, binding: SessionNetworkBinding, options: BrowserListenerOptions, password: String, completion: @escaping (BrowserListenerActivationResult) -> Void) -> Bool { false }
        func stop(completion: @escaping () -> Void) -> Bool { stops.append(completion); return acceptStop }
        func shutdown(completion: @escaping () -> Void) -> Bool { closes.append(completion); return true }
    }
    private final class Storage: BrowserCredentialStorage {
        enum Failure: Error { case synthetic }
        var value: String? = "synthetic", reads = 0, writes = 0, deletes = 0, limit: Int?, fail = false
        var hook: (() -> Void)?, onMain: Bool?
        func load(maximumUTF8Bytes: Int) throws -> String? { reads += 1; limit = maximumUTF8Bytes; onMain = Thread.isMainThread; hook?(); if fail { throw Failure.synthetic }; return value }
        func save(_ password: String) throws { writes += 1; value = password; hook?(); if fail { throw Failure.synthetic } }
        func delete() throws { deletes += 1; value = nil; hook?(); if fail { throw Failure.synthetic } }
    }
    @MainActor private final class Fixture {
        let backend = Backend(), storage = Storage(), request = UUID(), binding = SessionNetworkBinding(port: 49125, generation: UUID())
        let worker = PushToTalkWorkerReceipt(settings: .init(), running: true, generation: UUID())
        var owner: BrowserSessionOwner!, editor: BrowserSessionOwner.EditorTicket?, access: BrowserCredentialAccess!
        var work = [() -> Void](), current = true, results = [BrowserCredentialAccess.Outcome]()
        init() { owner = .init(backend: backend) }
    }
    private func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.003)) }
    private func ready() -> Fixture {
        let f = Fixture(); XCTAssertTrue(f.owner.beforeStart(f.request) { XCTAssertTrue($0) }); f.backend.prepares.last?(true); drain()
        f.owner.acknowledgeStart(f.request, binding: f.binding); f.owner.acknowledgeWorker(f.request, receipt: f.worker); f.owner.observe(running: true, binding: f.binding, workerGeneration: f.worker.generation)
        f.editor = f.owner.beginEditing(); if let editor = f.editor { f.access = .init(owner: f.owner, editor: editor, storage: f.storage, isCurrent: { [weak f] in f?.current ?? false }, execute: { [weak f] in f?.work.append($0) }) }
        XCTAssertNotNil(f.access); return f
    }
    private func load(_ f: Fixture) { XCTAssertTrue(f.access.load { [weak f] in f?.results.append($0) }) }
    func testLoadIsBoundedAndCallbackIsMainAfterRawReturn() {
        let f = ready(); load(f); XCTAssertEqual(f.storage.reads, 0); XCTAssertEqual(f.work.count, 1); XCTAssertNil(f.owner.currentVisitTicket)
        f.work.first?(); XCTAssertEqual(f.results, []); drain(); XCTAssertEqual(f.results, [.loaded("synthetic")]); XCTAssertEqual(f.storage.limit, 1024); XCTAssertNotNil(f.owner.currentVisitTicket)
    }
    func testSaveDeleteAndAbsenceAreSeparateCompletedReceipts() {
        let f = ready(); XCTAssertTrue(f.access.save("replacement") { [weak f] in f?.results.append($0) }); if !f.work.isEmpty { f.work.removeFirst()() }; drain(); XCTAssertEqual(f.results, [.stored]); XCTAssertEqual(f.storage.value, "replacement")
        XCTAssertTrue(f.access.delete { [weak f] in f?.results.append($0) }); if !f.work.isEmpty { f.work.removeFirst()() }; drain(); XCTAssertEqual(f.results, [.stored,.stored]); XCTAssertNil(f.storage.value)
        load(f); if !f.work.isEmpty { f.work.removeFirst()() }; drain(); XCTAssertEqual(f.results.last, .loaded(nil))
    }
    func testOneCreditRefusesThousandJobsAndPreviewBeforeDispatch() {
        let f = ready(); load(f)
        for _ in 0..<1000 { XCTAssertFalse(f.access.load { _ in XCTFail("Refused callback") }) }
        if let editor = f.editor { XCTAssertFalse(f.owner.apply(.empty, editor: editor) { _ in XCTFail("Concurrent preview") }) }
        XCTAssertEqual(f.work.count, 1); f.work.first?(); drain(); XCTAssertEqual(f.storage.reads, 1)
    }
    func testInvalidationBeforeDispatchMakesNoStoreCallAndWaitsNativeStop() {
        let f = ready(); load(f); f.access.invalidate(); XCTAssertEqual(f.backend.stops.count, 1)
        f.work.first?(); drain(); XCTAssertEqual(f.storage.reads, 0); XCTAssertEqual(f.results, [])
        f.backend.stops.last?(); drain(); XCTAssertEqual(f.results, [.stale])
    }
    func testRootInvalidationImmediatelyStopsAndRetainsRawCreditBeforeMutation() {
        let f = ready(); load(f); var mutated = false; f.owner.perform(.stopSession) { mutated = true }; XCTAssertEqual(f.backend.stops.count, 1)
        f.backend.stops.first?(); drain(); XCTAssertFalse(mutated); f.work.first?(); drain(); XCTAssertEqual(f.results, [.stale]); XCTAssertFalse(mutated)
        f.backend.stops.last?(); drain(); XCTAssertTrue(mutated)
    }
    func testShutdownReceiptFirstStillWaitsRawAndIndependentStop() {
        let f = ready(); load(f); var closed = false; XCTAssertTrue(f.owner.shutdown { _ in closed = true }); f.backend.closes.last?(); drain(); XCTAssertFalse(closed)
        f.work.first?(); drain(); XCTAssertEqual(f.results, []); XCTAssertFalse(closed)
        f.backend.stops.last?(); drain(); XCTAssertEqual(f.results, [.stale]); XCTAssertTrue(closed)
    }
    func testRawStoreErrorNeverReturnsSecretOrDropsReceipt() {
        let f = ready(); f.storage.fail = true; load(f); f.work.first?(); drain(); XCTAssertEqual(f.results, [.failed]); XCTAssertNotNil(f.owner.currentVisitTicket)
    }
    func testOversizedLoadFailsClosedWithoutTruncatingOrDeleting() {
        let f = ready(); f.storage.value = String(repeating: "é", count: 513); load(f); f.work.first?(); drain(); XCTAssertEqual(f.results, [.failed]); XCTAssertEqual(f.storage.deletes, 0)
    }
    func testInvalidSaveRefusesBeforeAnyQueueOrStoreBorrow() {
        let f = ready(); for value in ["",String(repeating: "é",count: 513)] { XCTAssertFalse(f.access.save(value) { _ in XCTFail("Refused callback") }) }; XCTAssertTrue(f.work.isEmpty); XCTAssertEqual(f.storage.writes, 0)
    }
    func testDuplicateExecutorDoesNotRepeatRawStoreOrCompletion() {
        let f = ready(); load(f); guard let work = f.work.first else { return }; work(); work(); drain(); XCTAssertEqual(f.storage.reads, 1); XCTAssertEqual(f.results.count, 1)
    }
    func testLateScopeRefusalSuppressesLoadedSecret() {
        let f = ready(); load(f); f.work.first?(); f.current = false; drain(); XCTAssertEqual(f.results, [.stale])
    }
    func testAlreadyStartedWriteCanAffectOldStoreButNeverReportsCurrentSuccess() {
        let f = ready(); f.storage.hook = { [weak f] in f?.owner.invalidate() }
        XCTAssertTrue(f.access.save("replacement") { [weak f] in f?.results.append($0) }); f.work.first?(); drain(); XCTAssertEqual(f.storage.value,"replacement"); XCTAssertEqual(f.results, [])
        f.backend.stops.first?(); drain(); XCTAssertEqual(f.results, [.stale]); f.backend.stops.last?(); drain()
    }
    func testForeignAndDuplicateWorkReceiptCannotReleaseAnotherJob() {
        let f = ready(), other = ready(); guard let a = f.editor, let b = other.editor else { return }
        guard let first = f.owner.reserveEditorWork(a), let foreign = other.owner.reserveEditorWork(b) else { return XCTFail("Missing work credits") }
        XCTAssertFalse(f.owner.completeEditorWork(foreign) {}); XCTAssertNil(f.owner.currentVisitTicket)
        var delivered = 0; XCTAssertTrue(f.owner.completeEditorWork(first) { delivered += 1 }); XCTAssertFalse(f.owner.completeEditorWork(first) { delivered += 1000 }); XCTAssertEqual(delivered,1)
        XCTAssertTrue(other.owner.completeEditorWork(foreign) {})
    }
    func testCompletionDeliveryPrecedesShutdownAndCannotAdmitReentrantJob() {
        let f = ready(); guard let editor = f.editor, let token = f.owner.reserveEditorWork(editor) else { return XCTFail("Missing work credit") }
        var closed = false; XCTAssertTrue(f.owner.shutdown { _ in closed = true }); f.backend.closes.last?(); f.backend.stops.last?(); drain()
        XCTAssertTrue(f.owner.completeEditorWork(token) { XCTAssertFalse(closed); XCTAssertNil(f.owner.reserveEditorWork(editor)) }); XCTAssertTrue(closed)
    }
    func testAccessReleaseRevokesBorrowButWaitsOwnedReceipt() {
        let f = ready(); load(f); f.access = nil; XCTAssertNil(f.owner.currentVisitTicket); f.work.first?(); drain(); XCTAssertEqual(f.storage.reads,0); XCTAssertEqual(f.results,[])
        f.backend.stops.last?(); drain(); XCTAssertEqual(f.results,[.stale])
    }
    func testOwnerReleaseRevokesBorrowAndRequestsCoreShutdown() {
        let f = ready(); load(f); weak var owner = f.owner; f.owner = nil; XCTAssertNil(owner); XCTAssertEqual(f.backend.closes.count,1)
        f.work.first?(); drain(); XCTAssertEqual(f.storage.reads,0); XCTAssertEqual(f.results,[])
    }
    func testActualUtilityExecutionReturnsOnlyOnMain() {
        let f = ready(); guard let editor = f.editor else { return }; let done = expectation(description:"utility store/main receipt")
        let access = BrowserCredentialAccess(owner:f.owner,editor:editor,storage:f.storage,isCurrent:{true})
        XCTAssertTrue(access.load { value in XCTAssertTrue(Thread.isMainThread); XCTAssertEqual(value,.loaded("synthetic")); done.fulfill() }); wait(for:[done],timeout:2); XCTAssertEqual(f.storage.onMain,false)
    }
    func testRefusedStopRejectsQueuedStartButRetainsSecretWorkCredit() {
        let f = ready(); load(f); f.backend.acceptStop = false; var accepted: Bool?, failures = 0
        f.owner.onFailure = { failures += 1 }; XCTAssertTrue(f.owner.beforeStart(UUID()) { accepted = $0 }); drain()
        XCTAssertEqual(accepted,false); XCTAssertEqual(failures,1); XCTAssertEqual(f.results,[])
        f.work.first?(); drain(); XCTAssertEqual(f.results,[.stale]); XCTAssertEqual(f.storage.reads,0); XCTAssertEqual(f.backend.prepares.count,1)
    }
    func testPermissionAndWorkerInvalidationFenceQueuedBorrow() {
        for permission in [false,true] {
            let f = ready(); load(f)
            if permission { _ = f.owner.suspendForPermission() }
            else { f.owner.observe(running:true,binding:f.binding,workerGeneration:UUID()) }
            XCTAssertEqual(f.backend.stops.count,1); f.work.first?(); drain(); XCTAssertEqual(f.storage.reads,0); XCTAssertEqual(f.results,[])
            f.backend.stops.first?(); drain(); XCTAssertEqual(f.results,[.stale]); f.backend.stops.last?(); drain()
        }
    }
    func testActualEphemeralCoreStoreAndBrowserRoleUseBoundedRead() throws {
        let f = ready(); f.access = nil; guard let editor = f.owner.beginEditing() else { return XCTFail("Missing renewed editor") }
        let stores = ProfilePasswordStores(), account = UUID().uuidString
        let audio = stores.store(account:account,isolated:true), browser = stores.store(account:account,role:.browser,isolated:true)
        try audio.save("synthetic audio"); let oversized = String(repeating:"é",count:513); try browser.save(oversized)
        let access = BrowserCredentialAccess(owner:f.owner,editor:editor,storage:browser,isCurrent:{true},execute:{[weak f] in f?.work.append($0)})
        XCTAssertTrue(access.load {[weak f] in f?.results.append($0) }); f.work.first?(); drain()
        XCTAssertEqual(f.results,[.failed]); XCTAssertEqual(try browser.load(),oversized); XCTAssertEqual(try audio.load(),"synthetic audio")
    }
    func testChangingEditorWindowAfterCompletionCannotBorrowOldAccount() {
        let f = ready(); load(f); if !f.work.isEmpty { f.work.removeFirst()() }; drain(); XCTAssertNotNil(f.owner.beginEditing()); XCTAssertFalse(f.access.load { _ in XCTFail("Old window callback") }); XCTAssertEqual(f.storage.reads,1)
    }
}
