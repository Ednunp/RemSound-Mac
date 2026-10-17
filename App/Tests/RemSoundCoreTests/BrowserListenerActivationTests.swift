import Foundation
import XCTest
@testable import RemSoundCore

final class BrowserListenerActivationTests: XCTestCase {
    private final class Listener: WebRoom.Listener {
        var hold = false, receipt: (() -> Void)?, failed: (() -> Void)?
        func start(offer: @escaping (WebRoom.Incoming) -> Bool, failed: @escaping () -> Void) { self.failed = failed }
        func close(completion: @escaping () -> Void) { receipt = completion; if !hold { retire() } }
        func retire() { let reply = receipt; receipt = nil; reply?() }
    }
    private final class Fixture {
        let queue = DispatchQueue(label: "test.browser.activation"), listener = Listener(), request = UUID()
        let binding = SessionNetworkBinding(port: 49121, generation: UUID())
        var service: BrowserListenerService!, actual: SessionNetworkBinding?, bound: ((UInt16) -> Void)?
        var observe: ((SessionNetworkBinding?) -> Void)?, attach: ((Bool) -> Void)?
        var holdObserve = false, holdAttach = false, observeAccept = true, attachAccept = true
        var missingPage = false, missingCredential = false, nilListener = false
        var pageHook: (() -> Void)?, listenerHook: (() -> Void)?
        var factories = 0, secrets = 0, results = [BrowserListenerActivationResult]()
        init(isolated: Bool = false) {
            actual = binding
            let deps = WebBrowserDependencies(observe: { [unowned self] reply in
                observe = reply; if !holdObserve { reply(actual) }; return observeAccept
            }, revoke: {}, attach: { [unowned self] _, reply in
                attach = reply; if !holdAttach { reply(true) }; return attachAccept
            }, page: { [unowned self] in pageHook?(); return missingPage ? nil : Data("page".utf8) },
            credential: { [unowned self] password in
                secrets += 1
                return missingCredential ? nil : WebAuthentication.Credential.make(password: password, salt: Data(repeating: 0, count: 16), derive: { _, _ in Data(repeating: 1, count: 32) })
            }, listener: { [unowned self] _, _, reply in
                factories += 1; bound = reply; listenerHook?(); return nilListener ? nil : listener
            }, clock: { 100 }, admissionSchedule: { _ in { _, _ in {} } }, peerSchedule: { _ in { _, _ in {} } })
            service = BrowserListenerService(queue: queue, isolated: isolated, dependencies: deps)
        }
        func drain() { for _ in 0..<64 { queue.sync {} } }
        func prepare(_ id: UUID? = nil) {
            var reply: Bool?; XCTAssertTrue(service.prepareStart(id ?? request) { reply = $0 }); drain(); XCTAssertEqual(reply, true)
        }
        @discardableResult func start(_ id: UUID? = nil) -> Bool {
            let admitted = service.activate(id ?? request, binding: binding, options: .init(enabled: true), password: "synthetic") { [unowned self] in results.append($0) }
            drain(); return admitted
        }
        func cleanup() {
            _ = service?.shutdown {}; queue.sync { observe?(actual); attach?(false); listener.hold = false; listener.retire() }
            drain(); service = nil; drain()
        }
    }
    func testBindThenAttachmentCompletesOnceWithActualPort() {
        let f = Fixture(); defer { f.cleanup() }; f.holdAttach = true; f.prepare(); XCTAssertTrue(f.start()); XCTAssertEqual(f.results, [])
        f.bound?(49222); f.drain(); XCTAssertEqual(f.results, [])
        f.attach?(true); f.drain(); XCTAssertEqual(f.results, [.listening(port: 49222)])
        f.bound?(49223); f.attach?(false); f.drain(); XCTAssertEqual(f.results, [.listening(port: 49222)])
    }
    func testAttachmentThenBindAndZeroPortIsNotCompletion() {
        let f = Fixture(); defer { f.cleanup() }; f.prepare(); XCTAssertTrue(f.start()); XCTAssertEqual(f.results, [])
        f.bound?(0); f.drain(); XCTAssertEqual(f.results, [])
        f.bound?(49224); f.drain(); XCTAssertEqual(f.results, [.listening(port: 49224)])
    }
    func testRefusalHasNoCompletionAndNoSensitiveFactory() {
        let f = Fixture(isolated: true); defer { f.cleanup() }; f.prepare(); XCTAssertFalse(f.start()); XCTAssertEqual(f.results, []); XCTAssertEqual(f.secrets + f.factories, 0)
    }
    func testWrongBindingCompletesUnavailableAfterObservation() {
        let f = Fixture(); defer { f.cleanup() }; f.actual = nil; f.prepare(); XCTAssertTrue(f.start())
        XCTAssertEqual(f.results, [.unavailable]); XCTAssertFalse(f.service.status.retiring); XCTAssertEqual(f.factories + f.secrets, 0)
    }
    func testMissingConfigurationOrListenerCompletesUnavailable() {
        for kind in 0..<3 {
            let f = Fixture(); defer { f.cleanup() }; f.missingPage = kind == 0; f.missingCredential = kind == 1; f.nilListener = kind == 2
            f.prepare(); XCTAssertTrue(f.start()); XCTAssertEqual(f.results, [.unavailable]); XCTAssertFalse(f.service.status.retiring)
        }
    }
    func testCancelledWaitsObservationAndStopBarrierBeforeCallback() {
        let f = Fixture(); defer { f.cleanup() }; f.holdObserve = true; f.prepare(); XCTAssertTrue(f.start())
        var stopped = 0; XCTAssertTrue(f.service.stop { stopped += 1 }); f.drain(); XCTAssertEqual(f.results, []); XCTAssertEqual(stopped, 0)
        f.observe?(f.binding); f.drain(); XCTAssertEqual(f.results, [.cancelled]); XCTAssertEqual(stopped, 1); XCTAssertEqual(f.secrets, 0)
    }
    func testFailureWaitsBothListenerAndAdmittedAttachment() {
        let f = Fixture(); defer { f.cleanup() }; f.holdAttach = true; f.listener.hold = true; f.prepare(); XCTAssertTrue(f.start())
        f.queue.sync { f.listener.failed?() }; f.drain(); XCTAssertEqual(f.results, [])
        f.queue.sync { f.listener.retire() }; f.drain(); XCTAssertEqual(f.results, [])
        f.attach?(true); f.drain(); XCTAssertEqual(f.results, [.unavailable]); XCTAssertFalse(f.service.status.retiring)
    }
    func testStopCannotRelabelFailureAndDuplicateLateReceiptsCannotCompleteAgain() {
        let f = Fixture(); defer { f.cleanup() }; f.listener.hold = true; f.prepare(); XCTAssertTrue(f.start())
        f.queue.sync { f.listener.failed?() }; f.drain(); XCTAssertTrue(f.service.stop {}); f.drain(); XCTAssertEqual(f.results, [])
        f.queue.sync { f.listener.retire() }; f.drain(); XCTAssertEqual(f.results, [.unavailable])
        f.bound?(49224); f.attach?(true); f.observe?(f.binding); f.drain(); XCTAssertEqual(f.results, [.unavailable])
    }
    func testRefusedInlineAttachmentCannotProduceListening() {
        let f = Fixture(); defer { f.cleanup() }; f.attachAccept = false; f.prepare(); XCTAssertTrue(f.start()); f.bound?(49224); f.drain()
        XCTAssertEqual(f.results, [.unavailable]); XCTAssertFalse(f.service.status.sourceAttached)
    }
    func testCallbackIsOnOwnerAfterActivateReturnsAndMayReenterPrepare() {
        let f = Fixture(); defer { f.cleanup() }; f.prepare()
        let key = DispatchSpecificKey<Int>(); f.queue.setSpecific(key: key, value: 1)
        var returned = false, callbacks = 0, renewed: Bool?
        f.queue.sync {
            XCTAssertTrue(f.service.activate(f.request, binding: f.binding, options: .init(enabled: true), password: "synthetic") { result in
                XCTAssertTrue(returned); XCTAssertEqual(DispatchQueue.getSpecific(key: key), 1); XCTAssertEqual(result, .listening(port: 49224)); callbacks += 1
                XCTAssertTrue(f.service.prepareStart(UUID()) { renewed = $0 })
            }); returned = true
        }
        f.drain(); f.bound?(49224); f.drain(); XCTAssertEqual(callbacks, 1); XCTAssertEqual(renewed, true)
    }
    func testReentrantFactoryCancelWaitsReturnedNativeResource() {
        let f = Fixture(); defer { f.cleanup() }; f.listener.hold = true; f.listenerHook = { XCTAssertTrue(f.service.stop {}) }
        f.prepare(); XCTAssertTrue(f.start()); f.bound?(49224); f.drain(); XCTAssertEqual(f.results, [])
        f.queue.sync { f.listener.retire() }; f.drain(); XCTAssertEqual(f.results, [.cancelled])
    }
    func testReplacementCannotReceiveOldCompletionAndReleaseStillCompletes() {
        let f = Fixture(); defer { f.cleanup() }; f.holdObserve = true; f.prepare(); XCTAssertTrue(f.start()); let old = f.observe
        var prepared: Bool?; let next = UUID(); XCTAssertTrue(f.service.prepareStart(next) { prepared = $0 }); f.drain(); XCTAssertNil(prepared)
        old?(f.binding); f.drain(); XCTAssertEqual(f.results, [.cancelled]); XCTAssertEqual(prepared, true)
        f.holdObserve = false; XCTAssertTrue(f.start(next)); f.bound?(49224); f.drain(); XCTAssertEqual(f.results, [.cancelled, .listening(port: 49224)])
    }
    func testCancellationCauseSurvivesLaterFailureAndNoBoundReceiptIsInvented() {
        let f = Fixture(); defer { f.cleanup() }; f.holdAttach = true; f.listener.hold = true; f.prepare(); XCTAssertTrue(f.start())
        XCTAssertTrue(f.service.stop {}); f.drain(); f.queue.sync { f.listener.failed?(); f.listener.retire() }; f.drain(); XCTAssertEqual(f.results, [])
        f.attach?(true); f.drain(); XCTAssertEqual(f.results, [.cancelled])
    }
    func testFirstForeignReceiptsWinWithoutDuplicateCompletions() {
        let f = Fixture(); defer { f.cleanup() }; f.holdObserve = true; f.holdAttach = true; f.prepare(); XCTAssertTrue(f.start())
        let observed = f.observe, done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { observed?(f.binding); observed?(nil); done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success); f.drain()
        let attached = f.attach, bound = f.bound
        DispatchQueue.global().async { bound?(49224); attached?(true); attached?(false); done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success); f.drain(); XCTAssertEqual(f.results, [.listening(port: 49224)])
    }
    func testSingleCompletionCreditRejectsThousandCallsWithoutCallbacks() {
        let f = Fixture(); defer { f.cleanup() }; f.holdObserve = true; f.prepare(); XCTAssertTrue(f.start()); var refusedReplies = 0
        for _ in 0..<1000 {
            XCTAssertFalse(f.service.activate(f.request, binding: f.binding, options: .init(enabled: true), password: "synthetic") { _ in refusedReplies += 1 })
        }
        f.observe?(f.binding); f.drain(); f.bound?(49224); f.drain(); XCTAssertEqual(f.results, [.listening(port: 49224)]); XCTAssertEqual(refusedReplies, 0)
    }
    func testListeningReceiptIsHistoricalAndLaterFailureDoesNotCompleteAgain() {
        let f = Fixture(); defer { f.cleanup() }; f.prepare(); XCTAssertTrue(f.start()); f.bound?(49224); f.drain(); XCTAssertEqual(f.results, [.listening(port: 49224)])
        f.queue.sync { f.listener.failed?() }; f.drain(); XCTAssertEqual(f.service.status.state, .unavailable); XCTAssertEqual(f.results, [.listening(port: 49224)])
    }
    func testStopInsidePageFactoryNeverCompletesSuccessOrBorrowsCredential() {
        let f = Fixture(); defer { f.cleanup() }; f.pageHook = { XCTAssertTrue(f.service.stop {}) }; f.prepare(); XCTAssertTrue(f.start())
        XCTAssertEqual(f.results, [.cancelled]); XCTAssertEqual(f.factories + f.secrets, 0)
    }
    func testBoundInsideFactoryCannotOutrunReentrantStopOrReturnedCleanup() {
        let f = Fixture(); defer { f.cleanup() }; f.listener.hold = true
        f.listenerHook = { f.bound?(49224); XCTAssertTrue(f.service.stop {}) }
        f.prepare(); XCTAssertTrue(f.start()); XCTAssertEqual(f.results, [])
        f.queue.sync { f.listener.retire() }; f.drain(); XCTAssertEqual(f.results, [.cancelled])
    }
    func testRepeatedRootUUIDHasIndependentCompletionLifetimes() {
        let f = Fixture(); defer { f.cleanup() }; f.prepare(); XCTAssertTrue(f.start()); f.bound?(49224); f.drain()
        f.prepare(); XCTAssertTrue(f.start()); f.bound?(49225); f.drain(); XCTAssertEqual(f.results, [.listening(port: 49224), .listening(port: 49225)])
    }
    func testReleaseBeforeBindingWaitsNativeCloseThenCancelledReceipt() {
        let f = Fixture(); defer { f.cleanup() }; f.listener.hold = true; f.prepare(); XCTAssertTrue(f.start())
        f.service = nil; f.drain(); XCTAssertEqual(f.results, [])
        f.queue.sync { f.listener.retire() }; f.drain(); XCTAssertEqual(f.results, [.cancelled])
    }
}
