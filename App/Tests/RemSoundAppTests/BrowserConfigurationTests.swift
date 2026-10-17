import Foundation
import RemSoundCore
import XCTest
@testable import RemSoundApp

@MainActor final class BrowserConfigurationTests: XCTestCase {
    private final class Backend: BrowserSessionBackend {
        var listenerState: BrowserListenerStatus.State = .off
        var prepares = [(Bool)->Void](), stops = [()->Void](), closes = [()->Void](), activations = [(BrowserListenerActivationResult)->Void]()
        var acceptsStop = true
        func prepareStart(_ request: UUID, completion: @escaping (Bool)->Void) -> Bool { prepares.append(completion); return true }
        func activate(_ request: UUID, binding: SessionNetworkBinding, options: BrowserListenerOptions, password: String) -> Bool { false }
        func activate(_ request: UUID, binding: SessionNetworkBinding, options: BrowserListenerOptions, password: String, completion: @escaping (BrowserListenerActivationResult)->Void) -> Bool { activations.append(completion); return true }
        func stop(completion: @escaping ()->Void) -> Bool { stops.append(completion); return acceptsStop }
        func shutdown(completion: @escaping ()->Void) -> Bool { closes.append(completion); return true }
    }
    private final class Storage: BrowserCredentialStorage {
        var value: String? = "synthetic browser", reads = 0, writes = 0, deletes = 0
        var hook: (()->Void)?
        func load(maximumUTF8Bytes: Int) throws -> String? { reads += 1; hook?(); return value }
        func save(_ password: String) throws { writes += 1; value = password; hook?() }
        func delete() throws { deletes += 1; value = nil; hook?() }
    }
    @MainActor private final class Fixture {
        let backend = Backend(), storage = Storage(), account = UUID(), revision = UUID(), request = UUID()
        var owner: BrowserSessionOwner!, ticket: BrowserSessionOwner.ConfigurationTicket?, access: BrowserCredentialAccess?, binding: SessionNetworkBinding?
        var queue = [()->Void](), results = [BrowserCredentialAccess.Outcome](), current = true
        init() { owner = BrowserSessionOwner(backend: backend) }
        func run() { if !queue.isEmpty { queue.removeFirst()() } }
    }
    private let enabled = BrowserListenerChoice(options: .init(enabled: true, autoStart: true), password: "synthetic")
    private func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.008)) }
    private func pump(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    }
    private func ready(running: Bool = false, readOnly: Bool = false) -> Fixture {
        let f = Fixture()
        if running {
            XCTAssertTrue(f.owner.beforeStart(f.request) { XCTAssertTrue($0) }); f.backend.prepares.last?(true); drain()
            let binding = SessionNetworkBinding(port: 49126, generation: UUID()), worker = PushToTalkWorkerReceipt(settings: .init(), running: true, generation: UUID())
            f.binding = binding
            f.owner.acknowledgeStart(f.request, binding: binding); f.owner.acknowledgeWorker(f.request, receipt: worker); f.owner.observe(running: true, binding: binding, workerGeneration: worker.generation)
        }
        f.ticket = f.owner.beginConfiguration(.init(account: f.account, revision: f.revision, readOnly: readOnly)); XCTAssertNotNil(f.ticket)
        if let ticket = f.ticket { f.access = BrowserCredentialAccess(owner: f.owner, configuration: ticket, storage: f.storage, isCurrent: { [weak f] in f?.current == true }, execute: { [weak f] in f?.queue.append($0) }) }
        return f
    }
    private func load(_ f: Fixture) { XCTAssertEqual(f.access?.load { [weak f] in f?.results.append($0) }, true) }
    func testStoppedConfigurationSealsAccountAndHasNoRunningOrNativeAuthority() {
        let f = ready(); XCTAssertEqual(f.ticket?.account, f.account); XCTAssertEqual(f.ticket?.isRunning, false); XCTAssertEqual(f.ticket?.allowsPersistence, true)
        XCTAssertNil(f.owner.currentVisitTicket); XCTAssertNil(f.owner.beginEditing()); XCTAssertFalse(f.owner.activate(options: .init(enabled: true), password: "synthetic")); XCTAssertTrue(f.backend.prepares.isEmpty); XCTAssertTrue(f.backend.activations.isEmpty)
    }
    func testStoppedPreviewIsOnlyStagedAndNeverConstructsNativeResources() {
        let f = ready(); guard let ticket = f.ticket else { return XCTFail("Missing configuration") }; var values = [BrowserSessionOwner.ConfigurationApplyResult]()
        XCTAssertTrue(f.owner.apply(enabled, configuration: ticket) { values.append($0) }); XCTAssertTrue(values.isEmpty); drain(); XCTAssertEqual(values, [.staged])
        XCTAssertTrue(f.backend.prepares.isEmpty); XCTAssertTrue(f.backend.stops.isEmpty); XCTAssertTrue(f.backend.activations.isEmpty); XCTAssertNil(f.owner.currentVisitTicket)
    }
    func testOneLedgerBlocksAThousandCredentialOrPreviewRequests() {
        let f = ready(); load(f); guard let ticket = f.ticket else { return XCTFail("Missing configuration") }
        for _ in 0..<1000 { XCTAssertEqual(f.access?.load { _ in XCTFail("Refused callback") }, false); XCTAssertFalse(f.owner.apply(enabled, configuration: ticket) { _ in XCTFail("Refused preview") }) }
        XCTAssertEqual(f.queue.count, 1); f.run(); drain(); XCTAssertEqual(f.storage.reads, 1); XCTAssertEqual(f.results, [.loaded("synthetic browser")])
    }
    func testStoppedReadOnlyContextAllowsLoadButRefusesSaveAndDeleteBeforeDispatch() {
        let f = ready(readOnly: true); XCTAssertEqual(f.ticket?.allowsPersistence, false); load(f); f.run(); drain(); XCTAssertEqual(f.results.count, 1)
        XCTAssertEqual(f.access?.save("replacement") { _ in XCTFail("Read-only save") }, false); XCTAssertEqual(f.access?.delete { _ in XCTFail("Read-only delete") }, false)
        XCTAssertTrue(f.queue.isEmpty); XCTAssertEqual(f.storage.writes, 0); XCTAssertEqual(f.storage.deletes, 0)
    }
    func testNewWindowAccountRevisionInvalidatesOldTicketWithoutBorrowingOldStore() {
        let f = ready(); guard let first = f.ticket else { return XCTFail("Missing configuration") }
        let second = f.owner.beginConfiguration(.init(account: UUID(), revision: UUID(), readOnly: false)); XCTAssertNotNil(second); XCTAssertFalse(f.owner.isCurrentConfiguration(first))
        XCTAssertEqual(f.access?.load { _ in XCTFail("Old account callback") }, false); XCTAssertEqual(f.storage.reads, 0)
        f.owner.endConfiguration(first); if let second { XCTAssertTrue(f.owner.isCurrentConfiguration(second)) }
    }
    func testForeignOwnerCannotReserveOrStageAnotherConfiguration() {
        let f = ready(), other = ready(); guard let ticket = f.ticket else { return XCTFail("Missing configuration") }
        XCTAssertFalse(other.owner.isCurrentConfiguration(ticket)); XCTAssertNil(other.owner.reserveConfigurationWork(ticket)); XCTAssertFalse(other.owner.apply(enabled, configuration: ticket) { _ in XCTFail("Foreign preview") })
    }
    func testStartImmediatelyRevokesBorrowButWaitsRawAndIndependentStop() {
        let f = ready(); load(f); var prepared: Bool?; XCTAssertTrue(f.owner.beforeStart(UUID()) { prepared = $0 }); XCTAssertEqual(f.backend.stops.count, 1)
        f.backend.stops.first?(); drain(); XCTAssertTrue(f.backend.prepares.isEmpty); f.run(); drain(); XCTAssertEqual(f.storage.reads, 0); XCTAssertEqual(f.results, [.stale]); XCTAssertNil(prepared)
        f.backend.prepares.last?(true); drain(); XCTAssertEqual(prepared, true)
    }
    func testStopMutationWaitsSecretReturnAndExactRetirement() {
        let f = ready(); load(f); var stopped = false; f.owner.perform(.stopSession) { stopped = true }; f.run(); drain(); XCTAssertFalse(stopped); XCTAssertTrue(f.results.isEmpty)
        f.backend.stops.first?(); drain(); XCTAssertEqual(f.results, [.stale]); XCTAssertFalse(stopped); f.backend.stops.last?(); drain(); XCTAssertTrue(stopped)
    }
    func testShutdownFirstNeverReleasesSecretCreditBeforeRawAndStop() {
        let f = ready(); load(f); var closed = false; XCTAssertTrue(f.owner.shutdown { _ in closed = true }); f.backend.closes.last?(); drain(); XCTAssertFalse(closed)
        f.run(); drain(); XCTAssertTrue(f.results.isEmpty); f.backend.stops.last?(); drain(); XCTAssertEqual(f.results, [.stale]); XCTAssertTrue(closed)
    }
    func testPermissionChangeImmediatelyFencesStoppedQueuedBorrow() {
        let f = ready(); load(f); XCTAssertNil(f.owner.suspendForPermission()); f.run(); drain(); XCTAssertEqual(f.storage.reads, 0); XCTAssertTrue(f.results.isEmpty)
        f.backend.stops.first?(); drain(); XCTAssertEqual(f.results, [.stale]); f.backend.stops.last?(); drain()
    }
    func testUnexpectedRunningObservationInvalidatesStoppedTicket() {
        let f = ready(); load(f); f.owner.observe(running: true, binding: .init(port: 49127, generation: UUID()), workerGeneration: UUID()); f.run(); drain()
        XCTAssertEqual(f.storage.reads, 0); XCTAssertTrue(f.results.isEmpty); f.backend.stops.first?(); drain(); XCTAssertEqual(f.results, [.stale]); f.backend.stops.last?(); drain()
    }
    func testRepeatedStoppedObservationKeepsConfigurationStable() {
        let f = ready(); guard let ticket = f.ticket else { return XCTFail("Missing configuration") }
        for _ in 0..<100 { f.owner.observe(running: false, binding: nil) }; XCTAssertTrue(f.owner.isCurrentConfiguration(ticket)); XCTAssertTrue(f.backend.stops.isEmpty)
    }
    func testReadOnlyPolicyIsImmutableEvenAfterAnotherWindowBecomesWritable() {
        let f = ready(readOnly: true); let old = f.ticket; let next = f.owner.beginConfiguration(.init(account: f.account, revision: f.revision, readOnly: false)); XCTAssertNotNil(next)
        XCTAssertEqual(old?.allowsPersistence, false); XCTAssertEqual(f.access?.save("obsolete") { _ in XCTFail("Obsolete policy") }, false); XCTAssertTrue(f.queue.isEmpty)
    }
    func testReleaseRevokesQueuedStoppedBorrowAndJoinsStopReceipt() {
        let f = ready(); load(f); f.access = nil; f.run(); drain(); XCTAssertEqual(f.storage.reads, 0); XCTAssertTrue(f.results.isEmpty); f.backend.stops.last?(); drain(); XCTAssertEqual(f.results, [.stale])
    }
    func testOwnerReleaseRequestsCoreShutdownAndNeverInventsAppCompletion() {
        let f = ready(); load(f); weak var prior = f.owner; f.owner = nil; XCTAssertNil(prior); XCTAssertEqual(f.backend.closes.count, 1); f.run(); drain(); XCTAssertEqual(f.storage.reads, 0); XCTAssertTrue(f.results.isEmpty)
    }
    func testAlreadyStartedStoppedSaveCanAffectOldAccountButCannotReportCurrentSuccess() {
        let f = ready(); f.storage.hook = { [weak f] in f?.owner.invalidate(discardMutations: true) }
        XCTAssertEqual(f.access?.save("replacement") { [weak f] in f?.results.append($0) }, true); f.run(); drain(); XCTAssertEqual(f.storage.value, "replacement"); XCTAssertTrue(f.results.isEmpty)
        f.backend.stops.first?(); drain(); XCTAssertEqual(f.results, [.stale]); f.backend.stops.last?(); drain()
    }
    func testRunningConfigurationStillUsesActualPrepareAndTypedListeningReceipt() {
        let f = ready(running: true); guard let ticket = f.ticket else { return XCTFail("Missing configuration") }; XCTAssertTrue(ticket.isRunning); var result: BrowserSessionOwner.ConfigurationApplyResult?
        XCTAssertTrue(f.owner.apply(enabled, configuration: ticket) { result = $0 }); XCTAssertEqual(f.backend.prepares.count, 2); XCTAssertNil(result)
        f.backend.prepares.last?(true); drain(); XCTAssertEqual(f.backend.activations.count, 1); XCTAssertNil(result); f.backend.activations.last?(.listening(port: 49128)); drain(); XCTAssertEqual(result, .listening)
    }
    func testRunningReadOnlyProfileCannotModifyCredentialStore() {
        let f = ready(running: true, readOnly: true); XCTAssertEqual(f.ticket?.isRunning, true); XCTAssertEqual(f.access?.save("replacement") { _ in XCTFail("Read-only") }, false); XCTAssertEqual(f.access?.delete { _ in XCTFail("Read-only") }, false); XCTAssertTrue(f.queue.isEmpty)
    }
    func testOwnRunningOffPreviewKeepsProfileAccountTicketValid() {
        let f = ready(running: true); guard let ticket = f.ticket else { return XCTFail("Missing configuration") }; var result: BrowserSessionOwner.ConfigurationApplyResult?
        XCTAssertTrue(f.owner.apply(.empty, configuration: ticket) { result = $0 }); f.backend.stops.last?(); drain(); XCTAssertEqual(result, .staged); XCTAssertTrue(f.owner.isCurrentConfiguration(ticket)); load(f); f.run(); drain(); XCTAssertEqual(f.results.count, 1)
    }
    func testRunningUnexpectedWorkerInvalidatesCredentialAndConfigurationTogether() {
        let f = ready(running: true); load(f); f.owner.observe(running: true, binding: f.binding, workerGeneration: UUID()); f.run(); drain(); XCTAssertEqual(f.storage.reads, 0); f.backend.stops.first?(); drain(); XCTAssertEqual(f.results, [.stale]); f.backend.stops.last?(); drain()
    }
    func testStoppedStagingCreditRetiresBeforeReentrantStartAndCanNeverClaimListening() {
        let f = ready(); guard let ticket = f.ticket else { return XCTFail("Missing configuration") }; var result: BrowserSessionOwner.ConfigurationApplyResult?, prepared: Bool?
        XCTAssertTrue(f.owner.apply(enabled, configuration: ticket) { result = $0 }); XCTAssertTrue(f.owner.beforeStart(UUID()) { prepared = $0 }); drain(); XCTAssertNil(result); XCTAssertNil(prepared)
        f.backend.stops.first?(); drain(); XCTAssertEqual(result, .failed); XCTAssertTrue(f.backend.activations.isEmpty); f.backend.prepares.last?(true); drain(); XCTAssertEqual(prepared, true)
    }
    func testPendingSecretWorkPreventsReplacementWindowEvenWithSameIdentity() {
        let f = ready(); load(f); XCTAssertNil(f.owner.beginConfiguration(.init(account: f.account, revision: f.revision, readOnly: false))); f.run(); drain(); XCTAssertEqual(f.storage.reads, 1)
    }
    func testRefusedRetirementRejectsStartAndStillWaitsPendingStoreReturn() {
        let f = ready(); load(f); f.backend.acceptsStop = false; var accepted: Bool?; XCTAssertTrue(f.owner.beforeStart(UUID()) { accepted = $0 }); drain(); XCTAssertEqual(accepted, false); XCTAssertTrue(f.results.isEmpty)
        f.run(); drain(); XCTAssertEqual(f.results, [.stale]); XCTAssertEqual(f.storage.reads, 0); XCTAssertTrue(f.backend.prepares.isEmpty)
    }
    func testEphemeralDedicatedAccountStoresRemainSeparatedDuringStoppedEditing() throws {
        let f = ready(); f.access = nil
        guard let ticket = f.owner.beginConfiguration(.init(account: f.account, revision: f.revision, readOnly: false)) else { return XCTFail("Missing renewed configuration") }; let stores = ProfilePasswordStores()
        let browser = stores.store(account: ticket.account.uuidString, role: .browser, isolated: true), audio = stores.store(account: ticket.account.uuidString, isolated: true), other = stores.store(account: UUID().uuidString, role: .browser, isolated: true)
        try browser.save("synthetic browser"); try audio.save("synthetic audio"); try other.save("other")
        f.access = BrowserCredentialAccess(owner: f.owner, configuration: ticket, storage: browser, isCurrent: { [weak f] in f?.current == true }, execute: { [weak f] in f?.queue.append($0) })
        load(f); f.run(); drain(); XCTAssertEqual(f.results, [.loaded("synthetic browser")]); XCTAssertEqual(try audio.load(), "synthetic audio"); XCTAssertEqual(try other.load(), "other")
    }
    func testStoppedSessionViewWorkerHintIsNotARealRunningVisit() {
        let f = ready(); guard let ticket = f.ticket else { return XCTFail("Missing configuration") }
        // Actual SessionView keeps a nonoptional PTT epoch even while stopped.
        let epoch = UUID(); f.owner.observe(running: false, binding: nil, workerGeneration: epoch)
        XCTAssertTrue(f.owner.isCurrentConfiguration(ticket)); XCTAssertTrue(f.backend.stops.isEmpty); XCTAssertNil(f.owner.currentVisitTicket)
        load(f); f.run(); drain(); XCTAssertEqual(f.results, [.loaded("synthetic browser")]); XCTAssertEqual(f.storage.reads, 1)
    }
    func testPartialRunningPreparationCannotBeRelabelledStoppedConfiguration() {
        let f = Fixture(); XCTAssertTrue(f.owner.beforeStart(f.request) { XCTAssertTrue($0) }); f.backend.prepares.last?(true); drain()
        XCTAssertNil(f.owner.beginConfiguration(.init(account: f.account, revision: f.revision, readOnly: false))); XCTAssertNil(f.owner.currentVisitTicket)
    }
    func testUnconfirmedNativeFailureStateCannotMintStoppedConfiguration() {
        let f = Fixture(); f.backend.listenerState = .unavailable
        XCTAssertNil(f.owner.beginConfiguration(.init(account: f.account, revision: f.revision, readOnly: false))); XCTAssertTrue(f.backend.prepares.isEmpty); XCTAssertTrue(f.backend.stops.isEmpty)
    }
    func testRunningConfigurationLateListeningAfterInvalidationWaitsRetirementAndFails() {
        let f = ready(running: true); guard let ticket = f.ticket else { return XCTFail("Missing configuration") }; var result: BrowserSessionOwner.ConfigurationApplyResult?
        XCTAssertTrue(f.owner.apply(enabled, configuration: ticket) { result = $0 }); f.backend.prepares.last?(true); drain(); f.owner.endConfiguration(ticket)
        f.backend.activations.last?(.listening(port: 49129)); drain(); XCTAssertNil(result); f.backend.stops.last?(); drain(); XCTAssertEqual(result, .failed)
    }
    func testActualModelStoppedStagingAndEphemeralCommitUseOneOwnerWithoutNativeActivation() throws {
        let f = ready(); f.access = nil
        guard let ticket = f.owner.beginConfiguration(.init(account: f.account, revision: f.revision, readOnly: false)) else { return XCTFail("Missing renewed configuration") }
        let stores = ProfilePasswordStores(), store = stores.store(account: ticket.account.uuidString, role: .browser, isolated: true)
        let access = BrowserCredentialAccess(owner: f.owner, configuration: ticket, storage: store, isCurrent: { [weak f] in f?.current == true }, execute: { [weak f] in f?.queue.append($0) })
        var persisted = BrowserListenerChoice.empty, end: BrowserListenerEdit.End?
        let edit = try XCTUnwrap(BrowserListenerEdit(opened: .empty, effectiveOpened: .empty, isCurrent: { [weak f] in f?.owner.isCurrentConfiguration(ticket) == true }, apply: { [weak f] choice,reply in
            f?.owner.apply(choice, configuration: ticket) { reply($0 != .failed) } ?? false
        }, commit: { choice,reply in
            access.save(choice.password) { value in if value == .stored { persisted = choice }; reply(value == .stored) }
        }))
        edit.ended = { result,_ in end = result }; edit.update(enabled); edit.accept(); pump { f.queue.count == 1 }; XCTAssertNil(end); XCTAssertEqual(f.queue.count, 1); XCTAssertEqual(persisted, .empty)
        f.run(); pump { end != nil }; XCTAssertEqual(end, .accepted); XCTAssertEqual(persisted, enabled); XCTAssertEqual(try store.load(), "synthetic"); XCTAssertTrue(f.backend.prepares.isEmpty); XCTAssertTrue(f.backend.activations.isEmpty)
        f.owner.endConfiguration(ticket)
    }
    func testReadOnlyDeleteAloneRefusesBeforeAnySecretQueueOrStoreEffect() {
        let f = ready(readOnly: true); XCTAssertEqual(f.access?.delete { _ in XCTFail("Read-only delete callback") }, false)
        XCTAssertTrue(f.queue.isEmpty); XCTAssertEqual(f.storage.deletes, 0)
    }
}
