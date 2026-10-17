import Foundation
import RemSoundCore
import RemSoundRuntime
import XCTest
@testable import RemSoundApp

@MainActor final class BrowserSessionOwnerTests: XCTestCase {
    private final class Backend: BrowserSessionBackend {
        var listenerState: BrowserListenerStatus.State = .off
        var preparations = [(UUID, (Bool) -> Void)](), stops = [() -> Void](), shutdowns = [() -> Void]()
        var activations = [(UUID, SessionNetworkBinding, BrowserListenerOptions)]()
        var accept = true, inline: Bool?, hook: (() -> Void)?
        func prepareStart(_ request: UUID, completion: @escaping (Bool) -> Void) -> Bool { preparations.append((request, completion)); hook?(); if let inline { completion(inline) }; return accept }
        func activate(_ request: UUID, binding: SessionNetworkBinding, options: BrowserListenerOptions, password: String) -> Bool { activations.append((request, binding, options)); return accept }
        func activate(_ request: UUID, binding: SessionNetworkBinding, options: BrowserListenerOptions, password: String, completion: @escaping (BrowserListenerActivationResult) -> Void) -> Bool { false }
        func stop(completion: @escaping () -> Void) -> Bool { stops.append(completion); hook?(); if inline != nil { completion() }; return accept }
        func shutdown(completion: @escaping () -> Void) -> Bool { shutdowns.append(completion); hook?(); if inline != nil { completion() }; return accept }
    }
    private func drain() { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
    private func fixture() -> (BrowserSessionOwner, Backend) { let b = Backend(); return (BrowserSessionOwner(backend: b), b) }
    private let worker = PushToTalkWorkerReceipt(settings: .init(), running: true, generation: UUID())
    private let binding = SessionNetworkBinding(port: 49211, generation: UUID())
    private func ready(_ owner: BrowserSessionOwner, _ backend: Backend, _ request: UUID) {
        XCTAssertTrue(owner.beforeStart(request) { XCTAssertTrue($0) }); backend.preparations.last?.1(true); drain()
        owner.observe(running: true, binding: binding, workerGeneration: worker.generation); owner.acknowledgeStart(request, binding: binding); owner.acknowledgeWorker(request, receipt: worker)
    }
    func testStartWaitsActualPreparationAndMarshalsFirstReceipt() {
        let (o,b) = fixture(); var replies = [Bool](); XCTAssertTrue(o.beforeStart(UUID()) { replies.append($0) })
        XCTAssertEqual(b.preparations.count, 1); XCTAssertTrue(replies.isEmpty); let reply = b.preparations.first?.1
        reply?(true); reply?(false); XCTAssertTrue(replies.isEmpty); drain(); XCTAssertEqual(replies, [true])
    }
    func testLatestStartCoalescesAndOldReceiptCannotStartIt() {
        let (o,b) = fixture(); let first = UUID(), last = UUID(); var old = [Bool](), latest = [Bool]()
        XCTAssertTrue(o.beforeStart(first) { old.append($0) }); XCTAssertTrue(o.beforeStart(last) { latest.append($0) })
        XCTAssertEqual(old, [false]); XCTAssertEqual(b.preparations.count, 1); b.preparations.first?.1(true); drain()
        XCTAssertTrue(latest.isEmpty); XCTAssertEqual(b.preparations.last?.0, last); b.preparations.last?.1(true); drain(); XCTAssertEqual(latest, [true])
    }
    func testInvalidateBeforePermissionCallbackSuppressesStart() {
        let (o,b) = fixture(); var replies = [Bool](); XCTAssertTrue(o.beforeStart(UUID()) { replies.append($0) })
        o.invalidate(discardMutations: true); XCTAssertEqual(replies, [false]); b.preparations.first?.1(true); drain(); XCTAssertEqual(replies, [false])
        XCTAssertEqual(b.stops.count, 1); b.stops.first?(); drain()
    }
    func testAudioAndApplicationsAreBoundedAndLatestPerKindSurvives() {
        let (o,b) = fixture(); var applied = [Int]()
        for i in 0..<1000 { o.perform(.audioOptions) { applied.append(i) }; o.perform(.applications) { applied.append(1000+i) } }
        XCTAssertEqual(b.stops.count, 1); XCTAssertTrue(applied.isEmpty); b.stops.first?(); drain(); XCTAssertEqual(applied, [1999, 999])
    }
    func testStopSupersedesQueuedOptionsAndProfileDiscardsOldMutations() {
        let (o,b) = fixture(); var actions = [String]()
        o.perform(.audioOptions) { actions.append("old") }; o.perform(.stopSession) { actions.append("stop") }
        b.stops.first?(); drain(); XCTAssertEqual(actions, ["stop"])
        o.perform(.applications) { actions.append("old profile") }; o.invalidate(discardMutations: true)
        b.stops.last?(); drain(); XCTAssertEqual(actions, ["stop"])
    }
    func testQueuedMutationsRunBeforeNextSessionStart() {
        let (o,b) = fixture(); var actions = [String]()
        o.perform(.applications) { actions.append("applications") }; XCTAssertTrue(o.beforeStart(UUID()) { if $0 { actions.append("start") } })
        b.stops.first?(); drain(); XCTAssertEqual(actions, ["applications"]); XCTAssertEqual(b.preparations.count, 1)
        b.preparations.first?.1(true); drain(); XCTAssertEqual(actions, ["applications", "start"])
    }
    func testBothCurrentRootReceiptAndObservedSocketRequiredBeforeSecretBorrow() {
        let (o,b) = fixture(); let request = UUID(); XCTAssertTrue(o.beforeStart(request) { _ in }); b.preparations.first?.1(true); drain()
        XCTAssertFalse(o.activate(options: .init(enabled: true), password: "synthetic")); o.acknowledgeStart(UUID(), binding: binding)
        o.observe(running: true, binding: binding, workerGeneration: worker.generation); XCTAssertFalse(o.activate(options: .init(enabled: true), password: "synthetic"))
        o.acknowledgeStart(request, binding: binding); o.acknowledgeWorker(request, receipt: worker); XCTAssertTrue(o.activate(options: .init(enabled: true), password: "synthetic")); XCTAssertEqual(b.activations.count, 1)
        XCTAssertEqual(b.activations.first?.0, request); XCTAssertEqual(b.activations.first?.1, binding)
    }
    func testDefaultOffChoiceNeverCallsActivation() {
        let (o,b) = fixture(); ready(o,b,UUID()); XCTAssertFalse(o.activate(options: .init(), password: "synthetic")); XCTAssertTrue(b.activations.isEmpty)
    }
    func testAutomaticBindingLossImmediatelyRequestsRetirementAndForgetsEligibility() {
        let (o,b) = fixture(); ready(o,b,UUID()); o.observe(running: false, binding: nil)
        XCTAssertEqual(b.stops.count, 1); XCTAssertFalse(o.activate(options: .init(enabled: true), password: "synthetic")); b.stops.first?(); drain()
    }
    func testSamePortDifferentSocketGenerationRetiresOldSource() {
        let (o,b) = fixture(); ready(o,b,UUID()); o.observe(running: true, binding: .init(port: binding.port, generation: UUID()))
        XCTAssertEqual(b.stops.count, 1); XCTAssertFalse(o.activate(options: .init(enabled: true), password: "synthetic")); b.stops.first?(); drain()
    }
    func testShutdownWaitsSeparateReceiptBeforeRouterSessionAndInstaller() {
        let (o,b) = fixture(); var order = [String]()
        o.perform(.audioOptions) { order.append("old") }
        XCTAssertTrue(o.shutdown { result in if case .success = result { order += ["router", "session", "installer"] } })
        XCTAssertEqual(b.shutdowns.count, 1); b.stops.first?(); drain(); XCTAssertTrue(order.isEmpty)
        b.shutdowns.first?(); drain(); XCTAssertEqual(order, ["router", "session", "installer"])
        XCTAssertFalse(o.beforeStart(UUID()) { _ in XCTFail("Closed callback") })
    }
    func testRefusedInlinePositivePreparationNeverStartsOrMutates() {
        let (o,b) = fixture(); b.accept = false; b.inline = true; var replies = [Bool]()
        XCTAssertTrue(o.beforeStart(UUID()) { replies.append($0) }); drain(); XCTAssertEqual(replies, [false])
        var writes = 0; o.perform(.audioOptions) { writes += 1 }; drain(); XCTAssertEqual(writes, 0)
    }
    func testShutdownRefusalIsFailureNeverSuccessfulQuiescence() {
        let (o,b) = fixture(); b.accept = false; b.inline = true; var failures = 0
        XCTAssertTrue(o.shutdown { if case .failure = $0 { failures += 1 } else { XCTFail("Guessed quiescence") } }); drain(); XCTAssertEqual(failures, 1)
    }
    func testShutdownWaitersAreBoundedAndNoRepeatedNativeShutdown() {
        let (o,b) = fixture(); var done = 0
        for _ in 0..<16 { XCTAssertTrue(o.shutdown { if case .success = $0 { done += 1 } }) }
        XCTAssertFalse(o.shutdown { _ in XCTFail("Refused callback") }); XCTAssertEqual(b.shutdowns.count, 1); XCTAssertEqual(done, 0)
        b.shutdowns.first?(); drain(); XCTAssertEqual(done, 16)
    }
    func testReentrantMutationDiscardsRemainingObsoleteBatch() {
        let (o,b) = fixture(); var actions = [String]()
        o.perform(.applications) { actions.append("first"); o.invalidate(discardMutations: true) }
        o.perform(.audioOptions) { actions.append("obsolete") }; b.stops.first?(); drain(); XCTAssertEqual(actions, ["first"])
        b.stops.last?(); drain()
    }
    func testReleaseRequestsExactBackendShutdownWithoutApplyingQueuedMutation() {
        let b = Backend(); var o: BrowserSessionOwner? = .init(backend: b); var writes = 0
        o?.perform(.audioOptions) { writes += 1 }; weak var weakOwner = o; o = nil
        XCTAssertNil(weakOwner); XCTAssertEqual(b.shutdowns.count, 1); b.stops.first?(); drain(); XCTAssertEqual(writes, 0); b.shutdowns.first?(); drain()
    }
    func testForeignDuplicateReceiptRunsContinuationOnlyOnMain() {
        let (o,b) = fixture(); let done = expectation(description: "main owner receipt"); var replies = 0
        XCTAssertTrue(o.beforeStart(UUID()) { value in XCTAssertTrue(Thread.isMainThread); XCTAssertTrue(value); replies += 1; done.fulfill() })
        let reply = b.preparations.first?.1
        DispatchQueue.global().async { reply?(true); reply?(false) }
        wait(for: [done], timeout: 2); drain(); XCTAssertEqual(replies, 1)
    }
    func testReentrantShutdownDuringPrepareRefusesLateRawAdmission() {
        let (o,b) = fixture(); var replies = [Bool](), closed = 0
        b.hook = { b.hook = nil; XCTAssertTrue(o.shutdown { if case .success = $0 { closed += 1 } }) }
        XCTAssertTrue(o.beforeStart(UUID()) { replies.append($0) }); b.preparations.first?.1(true); drain()
        XCTAssertEqual(replies, [false]); XCTAssertEqual(closed, 0); b.shutdowns.first?(); drain(); XCTAssertEqual(closed, 1)
    }
    func testObservationBeforeAndAfterAcknowledgementAgreeAndWrongReceiptCannotReplaceIt() {
        let (o,b) = fixture(); let id = UUID(); XCTAssertTrue(o.beforeStart(id) { _ in }); b.preparations.first?.1(true); drain()
        o.acknowledgeStart(id, binding: binding); o.acknowledgeWorker(id, receipt: worker); XCTAssertFalse(o.activate(options: .init(enabled: true), password: "synthetic"))
        o.observe(running: true, binding: binding, workerGeneration: worker.generation); XCTAssertTrue(o.activate(options: .init(enabled: true), password: "synthetic"))
        o.acknowledgeStart(UUID(), binding: .init(port: 1, generation: UUID()))
        XCTAssertTrue(o.activate(options: .init(enabled: true), password: "synthetic")); XCTAssertEqual(b.activations.count, 2)
    }
    func testNegativePreparationReceiptNeverCertifiesRetirementForMutation() {
        let (o,b) = fixture(); var ready = [Bool](), writes = 0; XCTAssertTrue(o.beforeStart(UUID()) { ready.append($0) })
        b.preparations.first?.1(false); drain(); o.perform(.audioOptions) { writes += 1 }; drain()
        XCTAssertEqual(ready, [false]); XCTAssertEqual(writes, 0)
    }
    func testOldDuplicateStopReceiptCannotReleaseNewerMutation() {
        let (o,b) = fixture(); var writes = 0; o.perform(.audioOptions) { writes += 1 }; let old = b.stops.first
        old?(); drain(); XCTAssertEqual(writes, 1); o.perform(.audioOptions) { writes += 1 }
        old?(); drain(); XCTAssertEqual(writes, 1); b.stops.last?(); drain(); XCTAssertEqual(writes, 2)
    }
    func testActualPublicIsolatedFacadeOwnerStaysOffAndRetiresBeforeSessionCleanup() throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]))
            .appendingPathComponent("browser-owner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try RuntimeConfiguration(options: LaunchOptions.parse(["--config-dir",root.path,"--headless","--silent"]))
        let session = Session(configuration: runtime)
        let backend = BrowserListenerService(runtime: runtime, session: session)
        let owner = BrowserSessionOwner(backend: backend), id = UUID(), prepared = expectation(description: "actual Core prep"), retired = expectation(description: "actual source and Room"), sessionDone = expectation(description: "Session stopped cleanup")
        XCTAssertTrue(owner.beforeStart(id) { XCTAssertTrue($0); prepared.fulfill() }); wait(for: [prepared], timeout: 2)
        owner.observe(running: true, binding: binding, workerGeneration: worker.generation); owner.acknowledgeStart(id, binding: binding)
        XCTAssertFalse(owner.activate(options: .init(enabled: true), password: "synthetic")); XCTAssertNil(backend.status.boundPort)
        XCTAssertTrue(owner.shutdown { result in
            if case .failure = result { XCTFail("Actual empty isolated cleanup failed") }
            retired.fulfill(); session.shutdown { sessionDone.fulfill() }
        }); wait(for: [retired, sessionDone], timeout: 2); XCTAssertEqual(backend.status.state, .closed)
    }
}
