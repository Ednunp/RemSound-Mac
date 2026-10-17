import Foundation
import RemSoundCore
import XCTest
@testable import RemSoundApp

@MainActor final class BrowserProfileRemovalTests: XCTestCase {
    private final class Backend: BrowserSessionBackend {
        var listenerState: BrowserListenerStatus.State = .off
        var inlineStop = false, inStop = false
        var stops = [()->Void](), closes = [()->Void](), prepares = [(Bool)->Void](), acceptsStop = true
        func prepareStart(_ request: UUID, completion: @escaping (Bool)->Void) -> Bool { prepares.append(completion); return true }
        func activate(_ request: UUID, binding: SessionNetworkBinding, options: BrowserListenerOptions, password: String) -> Bool { XCTFail("No native activation"); return false }
        func activate(_ request: UUID, binding: SessionNetworkBinding, options: BrowserListenerOptions, password: String, completion: @escaping (BrowserListenerActivationResult)->Void) -> Bool { XCTFail("No native activation"); return false }
        func stop(completion: @escaping ()->Void) -> Bool { inStop=true; defer {inStop=false}; stops.append(completion); if inlineStop {completion(); completion()}; return acceptsStop }
        func shutdown(completion: @escaping ()->Void) -> Bool { closes.append(completion); return true }
    }
    private final class Storage: BrowserCredentialStorage {
        enum Fault: Error { case synthetic }
        var value: String? = "synthetic", reads = 0, writes = 0, deletes = 0, fails = false
        var deleting: (()->Void)?
        func load(maximumUTF8Bytes: Int) throws -> String? { reads += 1; return value }
        func save(_ password: String) throws { writes += 1; value = password }
        func delete() throws { deletes += 1; value = nil; deleting?(); if fails { throw Fault.synthetic } }
    }
    @MainActor private final class Fixture {
        let backend = Backend(), browser = Storage(), audio = Storage(), owner: BrowserSessionOwner, account = UUID()
        var request: BrowserSessionOwner.RemovalRequest?, ticket: BrowserSessionOwner.RemovalTicket?, replies = 0
        var access: BrowserCredentialAccess?, queue = [@Sendable ()->Void](), results = [BrowserCredentialAccess.Outcome](), current = true
        init() { owner = .init(backend: backend) }
        func begin() { request = owner.prepareRemoval(account: account) { [weak self] value in self?.ticket = value; self?.replies += 1 } }
        func attach() {
            guard let ticket else { return XCTFail("Missing removal ticket") }
            access = .init(owner: owner, removal: ticket, browser: browser, audio: audio, isCurrent: { [weak self] in self?.current == true }, execute: { [weak self] in self?.queue.append($0) })
        }
        func run() { if !queue.isEmpty { queue.removeFirst()() } }
    }
    private func pump(_ done: ()->Bool) { let end = Date().addingTimeInterval(2); while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) } }
    private func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    private func ready() -> Fixture {
        let f = Fixture(); f.begin(); XCTAssertNotNil(f.request); guard f.request != nil else { return f }
        pump { !f.backend.stops.isEmpty }; f.backend.stops.first?(); pump { f.replies == 1 }; XCTAssertNotNil(f.ticket)
        if f.ticket != nil { f.attach() }; return f
    }
    private func remove(_ f: Fixture) { XCTAssertEqual(f.access?.delete { f.results.append($0) }, true) }
    func testPreparationDefersStopAndCannotMintBeforeActualReceipt() {
        let f = Fixture(); f.begin(); XCTAssertNotNil(f.request); guard f.request != nil else { return }
        XCTAssertTrue(f.backend.stops.isEmpty); XCTAssertEqual(f.replies, 0); pump { f.backend.stops.count == 1 }; XCTAssertNil(f.ticket)
        f.backend.stops.first?(); pump { f.replies == 1 }; XCTAssertEqual(f.ticket?.account, f.account); XCTAssertTrue(f.backend.prepares.isEmpty)
    }
    func testOnePendingPreparationAndOneIssuedPurposeRefuseReplacement() {
        let f = ready(); guard f.ticket != nil else { return }
        for _ in 0..<1000 { XCTAssertNil(f.owner.prepareRemoval(account: UUID()) { _ in XCTFail("Foreign replacement") }) }
        XCTAssertNil(f.owner.beginConfiguration(.init(account: f.account, revision: UUID(), readOnly: false)))
        XCTAssertEqual(f.backend.stops.count, 1)
    }
    func testRemovalPurposeCanOnlyDeleteAndDoesNotLoadEitherSecret() {
        let f = ready(); guard f.ticket != nil else { return }
        XCTAssertEqual(f.access?.load { _ in XCTFail("No removal load") }, false)
        XCTAssertEqual(f.access?.save("synthetic") { _ in XCTFail("No removal save") }, false)
        XCTAssertTrue(f.queue.isEmpty); remove(f); f.run(); pump { !f.results.isEmpty }
        XCTAssertEqual(f.results, [.stored]); XCTAssertEqual(f.browser.deletes, 1); XCTAssertEqual(f.audio.deletes, 1)
        XCTAssertEqual(f.browser.reads + f.audio.reads + f.browser.writes + f.audio.writes, 0)
    }
    func testBrowserDeleteFailureNeverDeletesAudioAndCanHaveOldAccountEffects() {
        let f = ready(); guard f.ticket != nil else { return }; f.browser.fails = true; remove(f); f.run(); pump { !f.results.isEmpty }
        XCTAssertEqual(f.results, [.failed]); XCTAssertNil(f.browser.value); XCTAssertEqual(f.audio.value, "synthetic"); XCTAssertEqual(f.audio.deletes, 0)
    }
    func testAudioDeleteFailureDoesNotPromiseBrowserRollback() {
        let f = ready(); guard f.ticket != nil else { return }; f.audio.fails = true; remove(f); f.run(); pump { !f.results.isEmpty }
        XCTAssertEqual(f.results, [.failed]); XCTAssertNil(f.browser.value); XCTAssertNil(f.audio.value)
    }
    func testRevocationBeforeUtilityRunBorrowsNeitherAccountStore() {
        let f = ready(); guard f.ticket != nil else { return }; remove(f); f.access?.invalidate(); f.run(); XCTAssertTrue(f.results.isEmpty)
        f.backend.stops.last?(); pump { !f.results.isEmpty }; XCTAssertEqual(f.results, [.stale]); XCTAssertEqual(f.browser.deletes + f.audio.deletes, 0)
    }
    func testRevocationBetweenStoresNeverStartsAudioDelete() {
        let f = ready(); guard f.ticket != nil else { return }; f.browser.deleting = { [weak f] in f?.owner.invalidate() }
        remove(f); f.run(); f.backend.stops.last?(); pump { !f.results.isEmpty }
        XCTAssertEqual(f.results, [.stale]); XCTAssertNil(f.browser.value); XCTAssertEqual(f.audio.deletes, 0)
    }
    func testSharedCreditBlocksAnotherDeleteUntilRawAndStopReceipts() {
        let f = ready(); guard f.ticket != nil else { return }; remove(f)
        XCTAssertEqual(f.access?.delete { _ in XCTFail("Second work") }, false)
        f.owner.invalidate(); f.backend.stops.last?(); drain(); XCTAssertTrue(f.results.isEmpty)
        f.run(); pump { !f.results.isEmpty }; XCTAssertEqual(f.results, [.stale])
    }
    func testShutdownFirstWaitsRawDeleteAndItsMainDelivery() {
        let f = ready(); guard f.ticket != nil else { return }; remove(f); var closed = false
        XCTAssertTrue(f.owner.shutdown { if case .success = $0 { closed = true } }); f.backend.closes.first?(); drain(); XCTAssertFalse(closed)
        f.backend.stops.last?(); drain(); XCTAssertFalse(closed); f.run(); pump { closed }
        XCTAssertTrue(closed); XCTAssertEqual(f.results, [.stale]); XCTAssertEqual(f.browser.deletes + f.audio.deletes, 0)
    }
    func testCancelledPreparationWaitsActualStopBeforeNilReply() {
        let f = Fixture(); f.begin(); guard let request = f.request else { return XCTFail("Missing preparation") }
        f.owner.endRemoval(request); pump { f.backend.stops.count == 1 }; XCTAssertEqual(f.replies, 0)
        f.backend.stops.first?(); pump { f.replies == 1 }; XCTAssertNil(f.ticket)
    }
    func testNewStartCancelsPreparationButRetirementPrecedesPrepareFactory() {
        let f = Fixture(); f.begin(); guard f.request != nil else { return XCTFail("Missing preparation") }
        XCTAssertTrue(f.owner.beforeStart(UUID()) { _ in }); pump { f.backend.stops.count == 1 }; XCTAssertTrue(f.backend.prepares.isEmpty)
        f.backend.stops.first?(); pump { f.replies == 1 && !f.backend.prepares.isEmpty }; XCTAssertNil(f.ticket)
    }
    func testUnavailableStateAfterStopRefusesWithoutRetryOrTicket() {
        let f = Fixture(); f.backend.listenerState = .unavailable; f.begin(); guard f.request != nil else { return XCTFail("Missing preparation") }
        pump { f.backend.stops.count == 1 }; f.backend.stops.first?(); pump { f.replies == 1 }; XCTAssertNil(f.ticket); drain(); XCTAssertEqual(f.backend.stops.count, 1)
    }
    func testRefusedStopCompletesFailureWithoutGrantingDeletionAuthority() {
        let f = Fixture(); f.backend.acceptsStop = false; f.begin(); guard f.request != nil else { return XCTFail("Missing preparation") }
        pump { f.replies == 1 }; XCTAssertNil(f.ticket); XCTAssertNil(f.owner.prepareRemoval(account: f.account) { _ in XCTFail("Blocked") })
    }
    func testOldAndForeignTicketsNeverReserveNewOwnerWork() {
        let f = ready(), other = ready(); guard let ticket = f.ticket, other.ticket != nil else { return }
        XCTAssertNil(other.owner.reserveRemovalWork(ticket)); f.access?.invalidate(); XCTAssertFalse(f.owner.isCurrentRemoval(ticket)); XCTAssertNil(f.owner.reserveRemovalWork(ticket))
    }
    func testDuplicateAndForeignStopCallbacksCompleteOnePurposeOnly() {
        let f = Fixture(); f.begin(); guard f.request != nil else { return XCTFail("Missing preparation") }; pump { f.backend.stops.count == 1 }
        let callback = f.backend.stops[0]; DispatchQueue.global().sync { callback(); callback() }; pump { f.replies == 1 }; callback(); drain(); XCTAssertEqual(f.replies, 1); XCTAssertNotNil(f.ticket)
    }
    func testPermanentShutdownCancelsPendingPreparationAfterItsOwnReceipt() {
        let f = Fixture(); f.begin(); guard f.request != nil else { return XCTFail("Missing preparation") }; pump { f.backend.stops.count == 1 }
        var closed = false; XCTAssertTrue(f.owner.shutdown { if case .success = $0 { closed = true } }); drain(); XCTAssertEqual(f.replies, 0)
        f.backend.closes.first?(); pump { closed }; XCTAssertEqual(f.replies, 1); XCTAssertNil(f.ticket); XCTAssertTrue(closed)
        f.backend.stops.first?(); drain(); XCTAssertEqual(f.replies, 1)
    }
    func testReadonlyEditingHasNoDeletionButSeparatelyPreparedPurposeCanRemove() {
        let f = Fixture(); guard let config = f.owner.beginConfiguration(.init(account: f.account, revision: UUID(), readOnly: true)) else { return XCTFail("Configuration missing") }
        let edit = BrowserCredentialAccess(owner: f.owner, configuration: config, storage: f.browser, isCurrent: { true }, execute: { _ in XCTFail("Read-only borrow") })
        XCTAssertFalse(edit.delete { _ in XCTFail("Read-only callback") }); f.begin(); guard f.request != nil else { return XCTFail("Removal missing") }
        pump { f.backend.stops.count == 1 }; f.backend.stops.first?(); pump { f.replies == 1 }; f.attach(); remove(f); f.run(); pump { !f.results.isEmpty }
        XCTAssertEqual(f.results, [.stored]); XCTAssertEqual(f.browser.deletes + f.audio.deletes, 2)
    }
    func testSourcePermissionInvalidatesIssuedPurposeAndReleasesNoNativeAuthority() {
        let f = ready(); guard let ticket = f.ticket else { return }; _ = f.owner.suspendForPermission()
        XCTAssertFalse(f.owner.isCurrentRemoval(ticket)); XCTAssertNil(f.owner.currentVisitTicket)
        XCTAssertEqual(f.access?.delete { _ in XCTFail("Permission lost") }, false); XCTAssertTrue(f.backend.prepares.isEmpty)
    }
    func testDeliveryStillOwnsSlotAgainstReentrantNextDelete() {
        let f = ready(); guard f.ticket != nil else { return }; var refused = false
        XCTAssertEqual(f.access?.delete { value in f.results.append(value); refused = f.access?.delete { _ in XCTFail("Reentrant delete") } == false }, true)
        f.run(); pump { !f.results.isEmpty }; XCTAssertTrue(refused); XCTAssertEqual(f.queue.count, 0)
    }
    func testReleasedAccessRevokesQueuedBorrowButOwnerStillJoinsRawReturn() {
        let f = ready(); guard f.ticket != nil else { return }; remove(f); weak var access = f.access; f.access = nil; XCTAssertNil(access)
        f.backend.stops.last?(); f.run(); pump { !f.results.isEmpty }; XCTAssertEqual(f.results, [.stale]); XCTAssertEqual(f.browser.deletes + f.audio.deletes, 0)
    }
    func testRemovalReplacementCannotReenterBeforeOldMainDeliveryReturns() {
        let f = ready(); guard f.ticket != nil else { return }; var refused = false
        XCTAssertEqual(f.access?.delete { _ in
            f.access?.invalidate()
            refused = f.owner.prepareRemoval(account: UUID()) { _ in XCTFail("Reentrant purpose") } == nil
        }, true)
        f.run(); pump { refused || !f.backend.stops.isEmpty && f.browser.deletes > 0 }; drain(); XCTAssertTrue(refused)
    }
    func testInlineDuplicateProviderReceiptIsDeliveredOnlyAfterRawReturn() {
        let f = Fixture(); f.backend.inlineStop = true; var replies = 0
        let request = f.owner.prepareRemoval(account: f.account) { ticket in XCTAssertFalse(f.backend.inStop); XCTAssertNotNil(ticket); replies += 1 }
        XCTAssertNotNil(request); XCTAssertEqual(replies, 0); pump { replies == 1 }; XCTAssertEqual(replies, 1)
    }
    func testOutstandingOldEditorRequiresRawReturnAndTwoDistinctRetirementReceipts() {
        let f = Fixture(); guard let config = f.owner.beginConfiguration(.init(account: f.account, revision: UUID(), readOnly: false)) else { return XCTFail("Missing old configuration") }
        let old = BrowserCredentialAccess(owner: f.owner, configuration: config, storage: f.browser, isCurrent: { true }, execute: { f.queue.append($0) })
        var loaded: BrowserCredentialAccess.Outcome?
        XCTAssertTrue(old.load { loaded = $0 }); f.begin(); XCTAssertNotNil(f.request)
        XCTAssertEqual(f.backend.stops.count, 1); f.backend.stops[0](); drain(); XCTAssertEqual(f.replies, 0)
        f.run(); pump { f.backend.stops.count == 2 }; XCTAssertEqual(loaded, .stale); XCTAssertEqual(f.replies, 0)
        f.backend.stops[1](); pump { f.replies == 1 }; XCTAssertNotNil(f.ticket); XCTAssertEqual(f.browser.reads, 0)
    }
    func testReentrantSourceReplacementDuringAdmissionRefusesWithoutNewCallback() {
        let f = Fixture(); var entered = false, replies = 0
        f.owner.onConfigurationInvalidated = {
            guard !entered else { return }; entered = true
            _ = f.owner.beforeStart(UUID()) { _ in }
        }
        XCTAssertNil(f.owner.prepareRemoval(account: f.account) { _ in replies += 1 }); drain(); XCTAssertEqual(replies, 0); XCTAssertTrue(entered)
    }
    func testRepeatedRawExecutionNeverReplaysEitherDeleteOrReceipt() {
        let f = ready(); guard f.ticket != nil else { return }; remove(f); XCTAssertEqual(f.queue.count, 1)
        guard let work = f.queue.first else { return }; work(); work(); pump { !f.results.isEmpty }; drain()
        XCTAssertEqual(f.browser.deletes, 1); XCTAssertEqual(f.audio.deletes, 1); XCTAssertEqual(f.results, [.stored])
    }
    func testCancelledPreparationCanBeReplacedOnlyAfterItsReceipt() {
        let f = Fixture(); f.begin(); guard let request = f.request else { return XCTFail("Missing preparation") }; f.owner.endRemoval(request)
        XCTAssertNil(f.owner.prepareRemoval(account: UUID()) { _ in XCTFail("Replacement before receipt") })
        pump { f.backend.stops.count == 1 }; f.backend.stops.first?(); pump { f.replies == 1 }
        XCTAssertNotNil(f.owner.prepareRemoval(account: f.account) { _ in })
    }

    func testRemovalPreparationCallbackRetainsItsCreditUntilItReturns() {
        let f=Fixture();var delivered=false,refused=false
        XCTAssertNotNil(f.owner.prepareRemoval(account:f.account) { ticket in
            if let ticket {f.owner.endRemoval(ticket)}
            refused=f.owner.prepareRemoval(account:UUID()) {_ in XCTFail("Reentrant preparation")} == nil
            delivered=true
        })
        pump {f.backend.stops.count==1};f.backend.stops[0]();pump {delivered}
        XCTAssertTrue(delivered);XCTAssertTrue(refused)
        XCTAssertNotNil(f.owner.prepareRemoval(account:f.account) {_ in})
    }

}
