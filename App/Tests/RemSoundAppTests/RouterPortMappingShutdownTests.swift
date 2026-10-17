import Foundation
import XCTest
import RemSoundCore
import RemSoundRuntime
@testable import RemSoundApp

@MainActor
final class RouterPortMappingShutdownTests: XCTestCase {
    private struct Refused: LocalizedError { var errorDescription: String? { "Terminal cleanup unresolved." } }
    @MainActor private final class Lease: RouterMappingLease {
        var externalAddress: String? = "203.0.113.7", externalPort: UInt16 = 49321
        var validFor: TimeInterval = 3600
        var removals: [(Result<Void, Error>) -> Void] = [], renewals: [(Result<TimeInterval, Error>) -> Void] = []
        func renew(_ completion: @escaping (Result<TimeInterval, Error>) -> Void) -> () -> Void { renewals.append(completion); return {} }
        func remove(_ completion: @escaping (Result<Void, Error>) -> Void) { removals.append(completion) }
    }
    @MainActor private final class Backend: RouterMappingBackend {
        var opened: [(Result<RouterMappingLease?, Error>) -> Void] = [], shutdowns: [(Result<Void, Error>) -> Void] = []
        func open(port: UInt16, leaseSeconds: Int, completion: @escaping (Result<RouterMappingLease?, Error>) -> Void) -> () -> Void { opened.append(completion); return {} }
        func shutdown(_ completion: @escaping (Result<Void, Error>) -> Void) { shutdowns.append(completion) }
    }
    @MainActor private final class Fixture {
        var time: TimeInterval = 0, factories = 0
        let backend = Backend()
        func owner() -> RouterPortMapping { .init(permitted: { true }, clock: { self.time }, makeBackend: { self.factories += 1; return self.backend }) }
        func opened() -> (RouterPortMapping, Lease) {
            let o = owner(), lease = Lease(); o.setEnabled(true); backend.opened.first?(.success(lease)); return (o, lease)
        }
    }
    func testOffTerminalReceiptCompletesOnMainWithoutFactory() {
        let f = Fixture(), o = f.owner(); var done = 0
        o.shutdown { result in XCTAssertTrue(Thread.isMainThread); if case .failure = result { XCTFail("Off cleanup failed") }; done += 1 }
        XCTAssertEqual(done, 1); XCTAssertEqual(f.factories, 0)
    }
    func testTerminalCompletionWaitsLateInitialLeaseAndRemoval() {
        let f = Fixture(), o = f.owner(), lease = Lease(); var done = 0; o.setEnabled(true)
        o.shutdown { _ in done += 1 }; XCTAssertEqual(done, 0); XCTAssertEqual(f.backend.shutdowns.count, 1)
        f.backend.shutdowns.first?(.success(())); XCTAssertEqual(done, 0)
        f.backend.opened.first?(.success(lease)); XCTAssertEqual(lease.removals.count, 1); XCTAssertEqual(done, 0)
        lease.removals.first?(.success(())); XCTAssertEqual(done, 1)
    }
    func testOwnedRemovalAndBackendReceiptAreIndependentRequiredBarriers() {
        let f = Fixture(), (o, lease) = f.opened(); var done = 0; o.shutdown { _ in done += 1 }
        XCTAssertEqual(lease.removals.count, 1); XCTAssertEqual(done, 0)
        lease.removals.first?(.success(())); XCTAssertEqual(done, 0)
        f.backend.shutdowns.first?(.success(())); XCTAssertEqual(done, 1)
    }
    func testBackendFailureIsTruthfulButStillWaitsPendingReceipt() {
        let f = Fixture(), o = f.owner(); var error: Error?; o.setEnabled(true)
        o.shutdown { if case .failure(let value) = $0 { error = value } }
        f.backend.shutdowns.first?(.failure(Refused())); XCTAssertNil(error)
        f.backend.opened.first?(.success(nil)); XCTAssertEqual(error?.localizedDescription, "Terminal cleanup unresolved.")
    }
    func testAwaitableShutdownRetainsOwnerThroughQuiescenceAfterWrapperRelease() {
        let f = Fixture(); var o: RouterPortMapping? = f.owner(); weak var retained = o; var done = 0
        o?.setEnabled(true); o?.shutdown { _ in done += 1 }; o = nil; XCTAssertNotNil(retained)
        f.backend.shutdowns.first?(.success(())); XCTAssertEqual(done, 0)
        f.backend.opened.first?(.success(nil)); XCTAssertEqual(done, 1); XCTAssertNil(retained)
    }
    func testMultipleWaitersAndDuplicateProofCompleteEachOnce() {
        let f = Fixture(), (o, lease) = f.opened(); var done = 0
        o.shutdown { _ in done += 1 }; o.shutdown { _ in done += 1 }; o.shutdown()
        XCTAssertEqual(f.backend.shutdowns.count, 1); XCTAssertEqual(done, 0)
        lease.removals.first?(.success(())); lease.removals.first?(.success(()))
        f.backend.shutdowns.first?(.success(())); f.backend.shutdowns.first?(.success(())); XCTAssertEqual(done, 2)
        o.shutdown { _ in done += 1 }; XCTAssertEqual(done, 3); XCTAssertEqual(f.backend.shutdowns.count, 1)
    }
    func testLateRenewalSecondDeletionMustFinishBeforeTerminalReceipt() {
        let f = Fixture(), (o, lease) = f.opened(); f.time = 900; o.tick(); var done = 0
        o.shutdown { _ in done += 1 }; f.backend.shutdowns.first?(.success(())); XCTAssertEqual(done, 0)
        lease.renewals.first?(.success(3600)); XCTAssertEqual(lease.removals.count, 1)
        lease.removals[0](.success(())); XCTAssertEqual(lease.removals.count, 2); XCTAssertEqual(done, 0)
        lease.removals[1](.success(())); XCTAssertEqual(done, 1)
    }
    func testAwaiterCanAttachAfterUnobservedShutdownWithoutRestartingBackend() {
        let f = Fixture(), o = f.owner(); var done = 0; o.setEnabled(true); o.shutdown()
        o.shutdown { _ in done += 1 }; XCTAssertEqual(done, 0); XCTAssertEqual(f.backend.shutdowns.count, 1)
        f.backend.opened.first?(.success(nil)); f.backend.shutdowns.first?(.success(())); XCTAssertEqual(done, 1)
    }
    func testCachedTerminalFailureReplaysWithoutNewRequests() {
        let f = Fixture(), o = f.owner(); o.setEnabled(true); var errors = 0
        o.shutdown { if case .failure = $0 { errors += 1 } }
        f.backend.opened.first?(.success(nil)); f.backend.shutdowns.first?(.failure(Refused()))
        o.shutdown { if case .failure = $0 { errors += 1 } }; XCTAssertEqual(errors, 2)
        XCTAssertEqual(f.factories, 1); XCTAssertEqual(f.backend.shutdowns.count, 1)
    }

    func testFailedExactDeletionCannotBeHiddenByBackendSuccess() {
        let f = Fixture(), (o, lease) = f.opened(); var failure: Error?
        o.shutdown { if case .failure(let error) = $0 { failure = error } }
        f.backend.shutdowns.first?(.success(())); XCTAssertNil(failure)
        lease.removals.first?(.failure(Refused())); XCTAssertEqual(failure?.localizedDescription, "Terminal cleanup unresolved.")
    }
    func testTerminalCallbackCanAttachAnotherWaiterWithoutRestartingOrRetainingOwner() {
        let f = Fixture(); var o: RouterPortMapping? = f.owner(); weak var released = o; var replies = 0
        o?.setEnabled(true)
        o?.shutdown { [weak o] _ in replies += 1; o?.shutdown { _ in replies += 1 } }
        f.backend.opened.first?(.success(nil)); f.backend.shutdowns.first?(.success(()))
        XCTAssertEqual(replies, 2); XCTAssertEqual(f.backend.shutdowns.count, 1); o = nil; XCTAssertNil(released)
    }
    func testActualIsolatedFacadeTerminalOwnerReceiptCompletesOnMain() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]!).appendingPathComponent("router-terminal-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try RuntimeConfiguration(options: LaunchOptions.parse(["--config-dir", root.path, "--silent", "--headless"]))
        let adapter = RouterMappingServiceBackend(service: .init(configuration: runtime)), o = RouterPortMapping(permitted: { true }, makeBackend: { adapter })
        let refused = expectation(description: "isolated owner refused")
        o.onChange = { if $0.status == .mappingFailed { refused.fulfill() } }; o.setEnabled(true)
        await fulfillment(of: [refused], timeout: 3); o.onChange = nil
        let done = expectation(description: "actual facade terminal completion")
        o.shutdown { result in
            XCTAssertTrue(Thread.isMainThread); if case .failure(let error) = result { XCTFail(error.localizedDescription) }; done.fulfill()
        }
        await fulfillment(of: [done], timeout: 3); XCTAssertEqual(o.state.status, .disabled)
    }
}
