import Foundation
import RemSoundCore
import XCTest
@testable import RemSoundApp

@MainActor final class BrowserSessionRenewalTests: XCTestCase {
    private final class Backend: BrowserSessionBackend {
        var listenerState: BrowserListenerStatus.State = .off
        var prepares = [(UUID, (Bool) -> Void)](), stops = [() -> Void](), closes = [() -> Void](), activated = 0
        func prepareStart(_ request: UUID, completion: @escaping (Bool) -> Void) -> Bool { prepares.append((request,completion)); return true }
        func activate(_ request: UUID, binding: SessionNetworkBinding, options: BrowserListenerOptions, password: String) -> Bool { activated += 1; return true }
        func activate(_ request: UUID, binding: SessionNetworkBinding, options: BrowserListenerOptions, password: String, completion: @escaping (BrowserListenerActivationResult) -> Void) -> Bool { false }
        func stop(completion: @escaping () -> Void) -> Bool { stops.append(completion); return true }
        func shutdown(completion: @escaping () -> Void) -> Bool { closes.append(completion); return true }
    }
    @MainActor private final class Fixture {
        let b = Backend(), request = UUID(), binding = SessionNetworkBinding(port: 49213, generation: UUID())
        let worker = PushToTalkWorkerReceipt(settings: .init(), running: true, generation: UUID())
        var owner: BrowserSessionOwner!
        init() { owner = .init(backend: b) }
    }
    private func drain() { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
    private func ready() -> Fixture {
        let f = Fixture(); XCTAssertTrue(f.owner.beforeStart(f.request) { XCTAssertTrue($0) }); f.b.prepares.first?.1(true); drain()
        f.owner.observe(running: true, binding: f.binding, workerGeneration: f.worker.generation); f.owner.acknowledgeStart(f.request, binding: f.binding); f.owner.acknowledgeWorker(f.request, receipt: f.worker)
        return f
    }
    func testExplicitCurrentRunningRenewalWaitsPreparationBeforePasswordBorrow() {
        let f = ready(); guard let ticket = f.owner.currentVisitTicket else { return XCTFail("Missing confirmed running visit") }
        var prepared = false; XCTAssertTrue(f.owner.prepareRunning(ticket) { prepared = $0 })
        XCTAssertFalse(f.owner.activate(ticket, options: .init(enabled: true), password: "synthetic")); XCTAssertFalse(prepared)
        f.b.prepares.last?.1(true); drain(); XCTAssertTrue(prepared)
        XCTAssertTrue(f.owner.activate(ticket, options: .init(enabled: true), password: "synthetic")); XCTAssertEqual(f.b.activated, 1)
    }
    func testNetworkObservationWithoutMatchingRootWorkerReceiptIsInsufficient() {
        let f = Fixture(); XCTAssertTrue(f.owner.beforeStart(f.request) { _ in }); f.b.prepares.first?.1(true); drain()
        f.owner.observe(running: true, binding: f.binding, workerGeneration: f.worker.generation); f.owner.acknowledgeStart(f.request, binding: f.binding)
        XCTAssertNil(f.owner.currentVisitTicket); f.owner.acknowledgeWorker(UUID(), receipt: f.worker); XCTAssertNil(f.owner.currentVisitTicket)
        f.owner.acknowledgeWorker(f.request, receipt: f.worker); XCTAssertNotNil(f.owner.currentVisitTicket)
    }
    func testSourceConfigurationRetainsRootButWaitsActualWorkerBeforeRenewal() {
        let f = ready(); guard let old = f.owner.currentVisitTicket else { return XCTFail("Missing initial visit") }
        var complete: ((PushToTalkWorkerReceipt?, Bool) -> Void)?
        f.owner.performSource(.audioOptions) { complete = $0 }; XCTAssertNil(f.owner.currentVisitTicket); XCTAssertEqual(f.b.stops.count,1)
        f.b.stops.first?(); drain(); XCTAssertNotNil(complete); XCTAssertNil(f.owner.currentVisitTicket)
        complete?(f.worker,true); drain(); guard let fresh = f.owner.currentVisitTicket else { return XCTFail("Source receipt did not restore a renewable root") }
        XCTAssertNotEqual(old,fresh); XCTAssertFalse(f.owner.prepareRunning(old) { _ in XCTFail("Old source ticket callback") })
        XCTAssertTrue(f.owner.prepareRunning(fresh) { XCTAssertTrue($0) }); f.b.prepares.last?.1(true); drain()
        XCTAssertTrue(f.owner.activate(fresh, options: .init(enabled:true), password:"synthetic"))
    }
    func testTwoWorkerCreditsAndCoalescedNextBatchStayBounded() {
        let f = ready(); var jobs = [(PushToTalkWorkerReceipt?, Bool) -> Void]()
        f.owner.performSource(.applications) { jobs.append($0) }; f.owner.performSource(.audioOptions) { jobs.append($0) }
        f.b.stops.first?(); drain(); XCTAssertEqual(jobs.count,2)
        for _ in 0..<1000 { f.owner.performSource(.audioOptions) { jobs.append($0) } }
        XCTAssertEqual(jobs.count,2); XCTAssertEqual(f.b.stops.count,1)
        jobs.first?(f.worker,true); drain(); XCTAssertEqual(jobs.count,2)
        jobs.last?(f.worker,true); drain(); XCTAssertEqual(f.b.stops.count,2); f.b.stops.last?(); drain(); XCTAssertEqual(jobs.count,3)
        jobs.last?(f.worker,true); drain(); XCTAssertNotNil(f.owner.currentVisitTicket)
    }
    func testShutdownCannotFinishBeforeAdmittedSourceWorkerCallback() {
        let f = ready(); var job: ((PushToTalkWorkerReceipt?, Bool) -> Void)?, done = false
        f.owner.performSource(.audioOptions) { job = $0 }; f.b.stops.first?(); drain()
        XCTAssertTrue(f.owner.shutdown { if case .success = $0 { done = true } }); f.b.closes.first?(); drain(); XCTAssertFalse(done)
        job?(nil,false); drain(); XCTAssertTrue(done)
    }
    func testProfileOrStopFencesOldCredentialAndPermissionTickets() {
        let f = ready(); guard let ticket = f.owner.suspendForPermission() else { return XCTFail("Missing permission ticket") }
        f.owner.invalidate(discardMutations:true); f.owner.completePermission(ticket,allowed:true); f.b.stops.first?(); drain()
        XCTAssertNil(f.owner.currentVisitTicket); XCTAssertFalse(f.owner.prepareRunning(ticket) { _ in XCTFail("Foreign profile callback") })
    }
    func testOnlyLatestPermissionAnswerCanEnableRenewal() {
        let f = ready(); let first = f.owner.suspendForPermission(), latest = f.owner.suspendForPermission()
        XCTAssertNotNil(first); XCTAssertNotNil(latest); f.owner.completePermission(first,allowed:true); f.b.stops.first?(); drain(); XCTAssertNil(f.owner.currentVisitTicket)
        f.owner.completePermission(latest,allowed:false); XCTAssertNil(f.owner.currentVisitTicket)
        let retry = f.owner.suspendForPermission(); f.owner.completePermission(retry,allowed:true); f.b.stops.last?(); drain(); XCTAssertNotNil(f.owner.currentVisitTicket)
    }
    func testFailedSourceReceiptNeverCreatesAUsableVisit() {
        let f = ready(); var job: ((PushToTalkWorkerReceipt?,Bool)->Void)?
        f.owner.performSource(.applications) { job = $0 }; f.b.stops.first?(); drain(); job?(nil,true); drain(); XCTAssertNil(f.owner.currentVisitTicket)
    }
    func testOldWorkerCallbackCannotRestoreAReplacedRootContext() {
        let f = ready(); var job: ((PushToTalkWorkerReceipt?,Bool)->Void)?
        f.owner.performSource(.audioOptions) { job = $0 }; f.b.stops.first?(); drain(); f.owner.invalidate(discardMutations:true)
        job?(f.worker,true); drain(); XCTAssertNil(f.owner.currentVisitTicket)
    }
    func testReentrantSourceCallbackIsMarshalledAndFirstReceiptWins() {
        let f = ready(); f.owner.performSource(.audioOptions) { callback in callback(nil,false); callback(f.worker,true) }
        f.b.stops.first?(); drain(); XCTAssertNil(f.owner.currentVisitTicket)
    }
    func testBindingLossInvalidatesSealedTicketEvenAtSamePort() {
        let f = ready(); guard let ticket = f.owner.currentVisitTicket else { return XCTFail("Missing initial visit") }
        f.owner.observe(running:true,binding:.init(port:f.binding.port,generation:UUID())); XCTAssertNil(f.owner.currentVisitTicket)
        XCTAssertFalse(f.owner.prepareRunning(ticket) { _ in XCTFail("Old socket callback") })
    }
    func testLateRenewalReceiptAfterSourceChangeCannotActivate() {
        let f = ready(); guard let ticket = f.owner.currentVisitTicket else { return XCTFail("Missing initial visit") }
        var replies = [Bool](); XCTAssertTrue(f.owner.prepareRunning(ticket) { replies.append($0) }); let reply = f.b.prepares.last?.1
        f.owner.suspendSource(); reply?(true); drain(); XCTAssertEqual(replies,[false]); XCTAssertFalse(f.owner.activate(ticket,options:.init(enabled:true),password:"synthetic"))
    }
    func testLateSourceReceiptCannotOverrideNewPermissionRefusal() {
        let f = ready(); var job: ((PushToTalkWorkerReceipt?,Bool)->Void)?
        f.owner.performSource(.audioOptions) { job = $0 }; f.b.stops.first?(); drain()
        let permission = f.owner.suspendForPermission(); f.owner.completePermission(permission, allowed:false)
        job?(f.worker,true); drain(); f.b.stops.last?(); drain(); XCTAssertNil(f.owner.currentVisitTicket)
    }
    func testObservedWorkerEpochMustMatchTheActualMutationReceipt() {
        let f = ready(), next = PushToTalkWorkerReceipt(settings:.init(),running:true,generation:UUID())
        var job: ((PushToTalkWorkerReceipt?,Bool)->Void)?
        f.owner.performSource(.audioOptions) { job = $0 }; f.b.stops.first?(); drain(); job?(next,true); drain()
        XCTAssertNil(f.owner.currentVisitTicket)
        f.owner.observe(running:true,binding:f.binding,workerGeneration:next.generation); XCTAssertNotNil(f.owner.currentVisitTicket)
        f.owner.acknowledgeWorker(f.request,receipt:f.worker); XCTAssertNotNil(f.owner.currentVisitTicket)
    }
    func testLastSubmittedWorkerReceiptWinsEvenWhenCallbacksArriveBackwards() {
        let f = ready(), next = PushToTalkWorkerReceipt(settings:.init(),running:true,generation:UUID())
        var jobs = [(PushToTalkWorkerReceipt?,Bool)->Void]()
        f.owner.performSource(.applications) { jobs.append($0) }; f.owner.performSource(.audioOptions) { jobs.append($0) }
        f.b.stops.first?(); drain(); guard jobs.count == 2 else { return XCTFail("Missing source callbacks") }
        jobs[1](next,true); drain(); XCTAssertNil(f.owner.currentVisitTicket); jobs[0](f.worker,false); drain()
        f.owner.observe(running:true,binding:f.binding,workerGeneration:next.generation); XCTAssertNotNil(f.owner.currentVisitTicket)
    }
    func testUnexpectedWorkerEpochImmediatelyRetiresActiveBrowserSource() {
        let f = ready(); XCTAssertTrue(f.owner.activate(options:.init(enabled:true),password:"synthetic"))
        f.owner.observe(running:true,binding:f.binding,workerGeneration:UUID()); XCTAssertEqual(f.b.stops.count,1)
        XCTAssertNil(f.owner.currentVisitTicket)
    }
    func testUnavailableNativeStateNotifiesOnceAndRequiresExplicitFreshPreparation() {
        let f = ready(); var failures = 0; f.owner.onListenerFailure = { failures += 1 }
        XCTAssertTrue(f.owner.activate(options:.init(enabled:true),password:"synthetic")); f.b.listenerState = .unavailable
        f.owner.refreshFailure(); f.owner.refreshFailure(); XCTAssertEqual(failures,1); XCTAssertEqual(f.b.stops.count,1)
        f.b.stops.first?(); drain(); guard let ticket = f.owner.currentVisitTicket else { return XCTFail("Lost confirmed root") }
        XCTAssertFalse(f.owner.activate(ticket,options:.init(enabled:true),password:"synthetic"))
        XCTAssertTrue(f.owner.prepareRunning(ticket) { XCTAssertTrue($0) }); f.b.prepares.last?.1(true); drain()
        XCTAssertEqual(f.b.activated,1)
    }
    func testProfileTransitionFencesPendingPermissionBeforeItCanApplySourceOptions() {
        let f = ready(); _ = f.owner.suspendForPermission(); let pending = f.owner.sourceScope
        XCTAssertTrue(f.owner.isCurrentSourceScope(pending)); f.owner.invalidate(discardMutations:true)
        XCTAssertFalse(f.owner.isCurrentSourceScope(pending))
    }
    func testActualWorkerCallbacksKeepShutdownPendingRegardlessOfArrivalOrder() {
        let f = ready(); var jobs = [(PushToTalkWorkerReceipt?,Bool)->Void](), closed = 0
        f.owner.performSource(.applications) { jobs.append($0) }; f.owner.performSource(.audioOptions) { jobs.append($0) }
        f.b.stops.first?(); drain(); guard jobs.count == 2 else { return XCTFail("Missing actual worker credits") }
        XCTAssertTrue(f.owner.shutdown { if case .success = $0 { closed += 1 } }); f.b.closes.first?(); drain()
        jobs[1](f.worker,true); drain(); XCTAssertEqual(closed,0); jobs[0](nil,false); drain(); XCTAssertEqual(closed,1)
        jobs[0](f.worker,true); drain(); XCTAssertEqual(closed,1)
    }
}
