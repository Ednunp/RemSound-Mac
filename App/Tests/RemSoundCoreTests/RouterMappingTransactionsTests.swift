import Foundation
import XCTest
@testable import RemSoundCore

final class RouterMappingTransactionsTests: XCTestCase {
    private final class Fixture {
        var now: TimeInterval = 2, allowed = true, enabled = true
        let route = RouterGatewayRoute(gateway: Endpoint("192.0.2.1", 5351), sourceAddress: "192.0.2.10", interface: "fixture")
        var service: UPnPRouterService { .init(kind: .ip2, controlURL: URL(string: "http://192.0.2.1/control")!, gatewayAddress: "192.0.2.1") }
        var operations: [RouterMappingTransactions.Operation] = []
        var callbacks: [(RouterMappingTransactions.Receipt) -> Void] = [], gates: [() -> Bool] = []
        var cancels: [Int] = [], trace: [String] = [], results: [RouterMappingTransactions.Result] = []
        var onFactory: ((Int) -> Void)?
        func owner() -> RouterMappingTransactions {
            RouterMappingTransactions(allowed: { self.allowed }, enabled: { self.enabled }, clock: { self.now }, factory: { operation, gate, completion in
                let index = self.operations.count
                self.operations.append(operation); self.callbacks.append(completion); self.gates.append(gate); self.cancels.append(0); self.trace.append("start\(index)")
                self.onFactory?(index)
                return .init(tick: {}, cancel: { self.cancels[index] += 1; self.trace.append("close\(index)") })
            })
        }
        func reply(_ value: RouterMappingTransactions.Receipt, index: Int? = nil) {
            let index = index ?? callbacks.count - 1
            guard callbacks.indices.contains(index) else { XCTFail("Missing transaction callback"); return }; callbacks[index](value)
        }
        var create: RouterMappingTransactions.Operation { .udp(.create(.natPmp(route, externalAddress: "203.0.113.7", epoch: 100), internalPort: 47830, lifetime: 3600)) }
        func lease() throws -> RouterUDPMapping.Lease {
            var value: RouterUDPMapping.Outcome?
            let op = RouterUDPMapping(intent: .create(.natPmp(route, externalAddress: "203.0.113.7", epoch: 100), internalPort: 47830, lifetime: 3600), permitted: { true }, clock: { 0 }, exchange: { _, route, reply in
                reply(.response(.init(resultCode: 0, internalPort: 47830, externalPort: 49321, lifetime: 120, epoch: 100, externalAddress: nil), route)); return {}
            }, completion: { value = $0 })
            op.start(); guard case .granted(let lease, _, _)? = value else { throw NSError(domain: "Missing private UDP lease", code: 1) }; return lease
        }
        func upnpLease() throws -> UPnPMappingCreation.Lease {
            var value: UPnPMappingCreation.Outcome?, stage = 0
            let op = UPnPMappingCreation(route: route, service: service, internalPort: 47830, lifetime: 3600, permitted: { true }, clock: { 0 }, token: { "RemSound-fixture-0123456789" }, http: { _, _, reply in
                let replies: [RouterHTTPTransport.Outcome] = [.soap(.fault(code: 714, description: "Absent")), .soap(.success(externalAddress: "203.0.113.7")), .soap(.success(externalAddress: nil)), .soap(.mapping(.init(internalPort: 47830, internalClient: "192.0.2.10", enabled: true, description: "RemSound-fixture-0123456789", leaseSeconds: 120)))]
                guard replies.indices.contains(stage) else { XCTFail("Unexpected creation stage"); return {} }; let result = replies[stage]; stage += 1; reply(result); return {}
            }, completion: { value = $0 })
            op.start(); guard case .granted(let lease, _)? = value else { throw NSError(domain: "Missing private UPnP lease", code: 1) }; return lease
        }
    }
    func testOffAndIsolatedRefuseBeforeFactory() {
        for isolated in [false, true] {
            let f = Fixture(); if isolated { f.allowed = false } else { f.enabled = false }; let owner = f.owner()
            owner.submit(f.create) { f.results.append($0) }
            XCTAssertTrue(f.operations.isEmpty); XCTAssertEqual(f.results.first?.receipt, .refused)
        }
    }
    func testDisablePermitsOnlyExactOpaqueCleanupAndIsolationStillRefuses() throws {
        let f = Fixture(), lease = try f.lease(); f.enabled = false; let owner = f.owner()
        owner.submit(.udp(.remove(lease))) { f.results.append($0) }; XCTAssertEqual(f.operations.count, 1); XCTAssertTrue(f.gates.first?() == true)
        f.reply(.udp(.removed(retired: false))); f.allowed = false
        owner.submit(.udp(.remove(lease))) { f.results.append($0) }; XCTAssertEqual(f.operations.count, 1); XCTAssertEqual(f.results.last?.receipt, .refused)
    }
    func testQueueNeverConstructsSecondOperationBeforeReceipt() {
        let f = Fixture(), owner = f.owner(); owner.submit(.capability) { f.results.append($0) }; owner.submit(f.create) { f.results.append($0) }
        XCTAssertEqual(f.operations.count, 1); f.reply(.capability(.unavailable), index: 0)
        XCTAssertEqual(f.operations.count, 2); XCTAssertEqual(f.trace.prefix(3), ["start0", "close0", "start1"])
        owner.shutdown(); f.reply(.udp(.cancelled(mutationMayHaveOccurred: false)), index: 1)
    }
    func testCancelWaitsForQuiescenceAndDoesNotFabricateTimeoutReceipt() {
        let f = Fixture(), owner = f.owner(), id = owner.submit(.capability) { f.results.append($0) }
        owner.submit(f.create) { f.results.append($0) }; owner.cancel(id); owner.cancel(id); f.now = 100; owner.tick()
        XCTAssertEqual(f.operations.count, 1); XCTAssertTrue(f.results.isEmpty); XCTAssertEqual(f.cancels, [1])
        f.reply(.capability(.cancelled)); XCTAssertEqual(f.operations.count, 2)
        owner.shutdown(); f.reply(.udp(.cancelled(mutationMayHaveOccurred: false)))
    }
    func testRetiredCreatedLeaseCleanupFinishesBeforeQueuedMutation() throws {
        let f = Fixture(), lease = try f.lease(), owner = f.owner(), id = owner.submit(f.create) { f.results.append($0) }
        owner.submit(f.create) { f.results.append($0) }; owner.cancel(id)
        f.reply(.udp(.granted(lease, retired: true, epochChanged: false)))
        XCTAssertEqual(f.operations.count, 2); guard case .udp(.remove(let exact))? = f.operations.last else { return XCTFail("Late created lease not cleaned") }
        XCTAssertEqual(exact, lease); XCTAssertTrue(f.results.isEmpty)
        f.reply(.udp(.removed(retired: false))); XCTAssertEqual(f.operations.count, 3); XCTAssertEqual(f.results.first?.cleanup, .udp(.removed(retired: false))); XCTAssertEqual(f.results.first?.remainingLifetime(at: 2), 0)
        owner.shutdown(); f.reply(.udp(.cancelled(mutationMayHaveOccurred: false)))
    }
    func testRetiredUpnpGrantAndAcknowledgedOrUncertainClaimUseExactCleanup() throws {
        for variant in 0..<3 {
            let f = Fixture(), lease = try f.upnpLease(), owner = f.owner()
            let id = owner.submit(.upnpCreate(f.route, f.service, internalPort: 47830, lifetime: 3600)) { f.results.append($0) }; owner.cancel(id)
            if variant == 0 { f.reply(.created(.granted(lease, retired: true))) }
            else if variant == 1 { f.reply(.created(.acknowledged(lease.claim, retired: true, reason: "Accepted"))) }
            else { f.reply(.created(.uncertain(lease.claim, reason: "Lost reply"))) }
            guard case .upnpMaintain(let target, .remove)? = f.operations.last else { XCTFail("UPnP cleanup missing"); continue }
            switch target { case .lease(let exact): XCTAssertEqual(exact, lease); case .claim(let exact): XCTAssertEqual(exact, lease.claim) }
            f.reply(.maintained(.absent)); XCTAssertEqual(f.results.count, 1); XCTAssertTrue(f.results.first?.retired == true)
        }
    }
    func testRenewedRetiredLeaseIsRemovedWithItsReturnedTuple() throws {
        let f = Fixture(), lease = try f.lease(), owner = f.owner(), id = owner.submit(.udp(.renew(lease, lifetime: 3600))) { f.results.append($0) }
        owner.cancel(id); f.reply(.udp(.granted(lease, retired: true, epochChanged: true)))
        guard case .udp(.remove(let exact))? = f.operations.last else { return XCTFail("Renewed lease not cleaned") }; XCTAssertEqual(exact, lease)
        f.reply(.udp(.removed(retired: true))); XCTAssertEqual(f.results.first?.cleanup, .udp(.removed(retired: true)))
    }
    func testUnderlyingRetiredGrantTriggersCleanupWithoutExplicitCancel() throws {
        let f = Fixture(), lease = try f.lease(), owner = f.owner(); owner.submit(f.create) { f.results.append($0) }
        f.reply(.udp(.granted(lease, retired: true, epochChanged: false))); XCTAssertEqual(f.operations.count, 2)
        f.reply(.udp(.removed(retired: false))); XCTAssertTrue(f.results.first?.retired == true)
    }
    func testRetainedCleanupBlocksNewMutationsWithoutReportingRemoved() throws {
        let f = Fixture(), lease = try f.lease(), owner = f.owner(), id = owner.submit(f.create) { f.results.append($0) }
        owner.submit(f.create) { f.results.append($0) }; owner.cancel(id); f.reply(.udp(.granted(lease, retired: true, epochChanged: false)))
        f.reply(.udp(.retained(lease, retired: false)))
        XCTAssertEqual(f.operations.count, 2); XCTAssertEqual(f.results.first?.cleanup, .udp(.retained(lease, retired: false)))
        guard case .blocked? = f.results.last?.receipt else { return XCTFail("New mutation ignored unresolved cleanup") }
    }
    func testExpiredCleanupDoesNotProveRemoteAbsence() throws {
        let f = Fixture(), lease = try f.lease(), owner = f.owner(), id = owner.submit(f.create) { f.results.append($0) }
        owner.cancel(id); f.reply(.udp(.granted(lease, retired: true, epochChanged: false))); f.reply(.udp(.expired))
        owner.submit(f.create) { f.results.append($0) }; XCTAssertEqual(f.operations.count, 2)
        guard case .blocked? = f.results.last?.receipt else { return XCTFail("Local expiry was treated as confirmed remote removal") }
    }
    func testLostInitialUdpMutationBlocksBlindRetryAndFallback() {
        let f = Fixture(), owner = f.owner(); owner.submit(f.create) { f.results.append($0) }
        f.reply(.udp(.failure("Lost", mutationMayHaveOccurred: true, retryAfter: 1800)))
        owner.submit(f.create) { f.results.append($0) }; XCTAssertEqual(f.operations.count, 1)
        guard case .blocked? = f.results.last?.receipt else { return XCTFail("Lost creation retried") }
        owner.submit(.capability) { f.results.append($0) }; XCTAssertEqual(f.operations.count, 2); f.reply(.capability(.unavailable))
    }
    func testKnownRenewalUncertaintyCleansOnlyPriorPrivateLease() throws {
        let f = Fixture(), lease = try f.lease(), owner = f.owner(), id = owner.submit(.udp(.renew(lease, lifetime: 3600))) { f.results.append($0) }
        owner.cancel(id); f.reply(.udp(.timedOut(mutationMayHaveOccurred: true)))
        guard case .udp(.remove(let exact))? = f.operations.last else { return XCTFail("Known renewal lease lost") }; XCTAssertEqual(exact, lease)
        f.reply(.udp(.removed(retired: false))); XCTAssertEqual(f.results.count, 1)
    }
    func testCleanupReplyFailurePreservesClaimAndBlocksOpen() throws {
        let f = Fixture(), lease = try f.upnpLease(), owner = f.owner()
        let id = owner.submit(.upnpCreate(f.route, f.service, internalPort: 47830, lifetime: 3600)) { f.results.append($0) }; owner.cancel(id)
        f.reply(.created(.acknowledged(lease.claim, retired: true, reason: "Accepted")))
        f.reply(.maintained(.retained(lease.claim, mutationAcknowledged: true, reason: "Unconfirmed delete")))
        XCTAssertEqual(f.results.first?.cleanup, .maintained(.retained(lease.claim, mutationAcknowledged: true, reason: "Unconfirmed delete")))
        owner.submit(f.create) { f.results.append($0) }; XCTAssertEqual(f.operations.count, 2)
    }
    func testCleanupUsesAllowedGateAfterDisableButNeverBypassesIsolation() throws {
        let f = Fixture(), lease = try f.lease(), owner = f.owner(), id = owner.submit(f.create) { f.results.append($0) }
        f.enabled = false; owner.cancel(id); f.reply(.udp(.granted(lease, retired: true, epochChanged: false)))
        XCTAssertEqual(f.operations.count, 2); XCTAssertTrue(f.gates.last?() == true)
        f.allowed = false; XCTAssertTrue(f.gates.last?() == false); f.reply(.udp(.refused)); XCTAssertEqual(f.results.first?.cleanup, .udp(.refused))
    }
    func testDuplicateOldReceiptsCannotDeleteNewWorkOrRepeatCompletion() {
        let f = Fixture(), owner = f.owner(); owner.submit(.capability) { f.results.append($0) }; f.reply(.capability(.unavailable), index: 0)
        owner.submit(.capability) { f.results.append($0) }; f.reply(.capability(.cancelled), index: 0)
        XCTAssertEqual(f.results.count, 1); XCTAssertEqual(f.operations.count, 2); f.reply(.capability(.unavailable), index: 1); XCTAssertEqual(f.results.count, 2)
    }
    func testQueuedCancellationHasNoFactorySideEffect() {
        let f = Fixture(), owner = f.owner(); owner.submit(.capability) { f.results.append($0) }; let queued = owner.submit(f.create) { f.results.append($0) }
        owner.cancel(queued); XCTAssertEqual(f.results.first?.receipt, .cancelled); XCTAssertEqual(f.operations.count, 1); f.reply(.capability(.unavailable)); XCTAssertEqual(f.operations.count, 1)
    }
    func testSynchronousReceiptWaitsForFactoryReturnAndExactCleanup() {
        let f = Fixture(), owner = f.owner()
        f.onFactory = { index in
            guard index == 0 else { return }
            owner.submit(.capability) { f.results.append($0) }; f.reply(.capability(.unavailable), index: 0)
            XCTAssertTrue(f.results.isEmpty); XCTAssertEqual(f.operations.count, 1)
        }
        owner.submit(.capability) { f.results.append($0) }; f.onFactory = nil
        XCTAssertEqual(f.trace.prefix(3), ["start0", "close0", "start1"]); f.reply(.capability(.unavailable), index: 1)
        XCTAssertEqual(f.results.count, 2)
    }
    func testShutdownCancelsQueuedWorkAndCleansLateCreationBeforeReceipt() throws {
        let f = Fixture(), lease = try f.lease(), owner = f.owner(); owner.submit(f.create) { f.results.append($0) }; owner.submit(f.create) { f.results.append($0) }
        owner.shutdown(); XCTAssertEqual(f.results.first?.receipt, .cancelled); f.reply(.udp(.granted(lease, retired: true, epochChanged: false)))
        XCTAssertEqual(f.operations.count, 2); f.reply(.udp(.removed(retired: false))); XCTAssertEqual(f.results.count, 2)
        owner.submit(f.create) { f.results.append($0) }; XCTAssertEqual(f.operations.count, 2); XCTAssertEqual(f.results.last?.receipt, .refused)
    }
    func testOwnerReleaseStillReturnsCleanupReceiptAfterQuiescence() throws {
        let f = Fixture(), lease = try f.lease(); var owner: RouterMappingTransactions? = f.owner(); owner?.submit(f.create) { f.results.append($0) }; weak var released = owner; owner = nil
        XCTAssertNil(released); f.reply(.udp(.granted(lease, retired: true, epochChanged: false))); XCTAssertEqual(f.operations.count, 2)
        f.reply(.udp(.removed(retired: false))); XCTAssertEqual(f.results.first?.cleanup, .udp(.removed(retired: false)))
    }
    func testRemainingValidityUsesConservativeDeadlineNotReceiptTime() throws {
        let f = Fixture(), lease = try f.lease(), owner = f.owner(); owner.submit(f.create) { f.results.append($0) }; f.now = 6
        f.reply(.udp(.granted(lease, retired: false, epochChanged: false)))
        XCTAssertEqual(f.results.first?.remainingLifetime(at: 6), 114); XCTAssertEqual(f.results.first?.remainingLifetime(at: 121), 0); XCTAssertEqual(f.results.first?.remainingLifetime(at: .nan), 0); XCTAssertEqual(f.results.first?.remainingLifetime(at: -1), 0)
    }
    func testCapabilityErrorLifetimeAndEpochReceiptArePreserved() throws {
        let f = Fixture(), owner = f.owner(); owner.submit(.capability) { f.results.append($0) }
        f.reply(.capability(.failure("Quota", retryAfter: 1810))); XCTAssertEqual(f.results.first?.receipt, .capability(.failure("Quota", retryAfter: 1810)))
        let lease = try f.lease(); owner.submit(.udp(.renew(lease, lifetime: 3600))) { f.results.append($0) }; f.reply(.udp(.granted(lease, retired: false, epochChanged: true)))
        XCTAssertEqual(f.results.last?.receipt, .udp(.granted(lease, retired: false, epochChanged: true)))
    }
    func testDeadlineCancelsOnceButWaitsForReceipt() {
        let f = Fixture(), owner = f.owner(); owner.submit(.capability) { f.results.append($0) }; f.now = 10; owner.tick(); owner.tick()
        XCTAssertEqual(f.cancels, [1]); XCTAssertTrue(f.results.isEmpty); f.reply(.capability(.cancelled)); XCTAssertTrue(f.results.first?.retired == true)
    }
    func testQueueIsBoundedAndInvalidRequestsDoNotConstruct() {
        let f = Fixture(), owner = f.owner(); owner.submit(.capability) { f.results.append($0) }
        for _ in 0..<20 { owner.submit(.capability) { f.results.append($0) } }
        XCTAssertEqual(f.operations.count, 1); XCTAssertEqual(f.results.count, 4)
        owner.shutdown(); f.reply(.capability(.cancelled)); XCTAssertEqual(f.results.count, 21)
        let second = Fixture(), other = second.owner(); other.submit(.udp(.create(.pcp(second.route, epoch: 1), internalPort: 0, lifetime: 3600))) { second.results.append($0) }
        XCTAssertTrue(second.operations.isEmpty); guard case .blocked? = second.results.first?.receipt else { return XCTFail("Invalid operation reached factory") }
    }
    func testQueuedWorkRechecksDisableAtConstruction() {
        let f = Fixture(), owner = f.owner(); owner.submit(.capability) { f.results.append($0) }; owner.submit(f.create) { f.results.append($0) }
        f.enabled = false; f.reply(.capability(.selected(.pcp(f.route, epoch: 1))))
        XCTAssertEqual(f.operations.count, 1); XCTAssertEqual(f.results.last?.receipt, .refused); XCTAssertTrue(f.results.first?.retired == true)
    }
    func testLateGrantWithoutTickStillNeedsCleanup() throws {
        let f = Fixture(), lease = try f.lease(), owner = f.owner(); owner.submit(f.create) { f.results.append($0) }; f.now = 10
        f.reply(.udp(.granted(lease, retired: false, epochChanged: false))); XCTAssertEqual(f.operations.count, 2); XCTAssertTrue(f.results.isEmpty)
        f.reply(.udp(.removed(retired: false))); XCTAssertTrue(f.results.first?.retired == true)
    }
    func testMismatchedReceiptRetainsEvidenceAndBlocksMutationWithoutGuessingCleanup() throws {
        let f = Fixture(), lease = try f.lease(), owner = f.owner(); owner.submit(.capability) { f.results.append($0) }; f.reply(.udp(.granted(lease, retired: false, epochChanged: false)))
        XCTAssertEqual(f.results.first?.receipt, .udp(.granted(lease, retired: false, epochChanged: false))); guard case .blocked? = f.results.first?.cleanup else { return XCTFail("Mismatched evidence disappeared") }
        owner.submit(f.create) { f.results.append($0) }; XCTAssertEqual(f.operations.count, 1)
    }
}
