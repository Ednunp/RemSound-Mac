import Foundation
import XCTest
@testable import RemSoundCore

final class RouterMappingRecoveryTests: XCTestCase {
    private final class Fixture {
        var now: TimeInterval = 2, allowed = true, enabled = true
        let route = RouterGatewayRoute(gateway: Endpoint("192.0.2.1", 5351), sourceAddress: "192.0.2.10", interface: "fixture")
        var operations: [RouterMappingTransactions.Operation] = [], callbacks: [(RouterMappingTransactions.Receipt) -> Void] = []
        var cancels: [Int] = [], results: [RouterMappingTransactions.Result] = [], outcomes: [RouterMappingWorkflow.Outcome] = []
        var onFactory: ((Int) -> Void)?
        var service: UPnPRouterService { .init(kind: .ip2, controlURL: URL(string: "http://192.0.2.1/control")!, gatewayAddress: "192.0.2.1") }
        var create: RouterMappingTransactions.Operation { .udp(.create(.natPmp(route, externalAddress: "203.0.113.7", epoch: 100), internalPort: 47830, lifetime: 3600)) }
        var factory: RouterMappingTransactions.Factory {
            { operation, gate, reply in
                XCTAssertTrue(gate()); let i = self.operations.count
                self.operations.append(operation); self.callbacks.append(reply); self.cancels.append(0); self.onFactory?(i)
                return .init(tick: {}, cancel: { self.cancels[i] += 1 })
            }
        }
        func lane() -> RouterMappingTransactions { .init(allowed: { self.allowed }, enabled: { self.enabled }, clock: { self.now }, factory: factory) }
        func workflow() -> RouterMappingWorkflow { .init(allowed: { self.allowed }, enabled: { self.enabled }, clock: { self.now }, factory: factory) }
        func reply(_ r: RouterMappingTransactions.Receipt, _ i: Int? = nil) {
            let i = i ?? callbacks.count - 1; guard callbacks.indices.contains(i) else { return XCTFail("Missing recovery callback") }; callbacks[i](r)
        }
        func udp(_ port: UInt16 = 47830, duration: UInt32 = 120) throws -> RouterUDPMapping.Lease {
            var result: RouterUDPMapping.Outcome?
            let o = RouterUDPMapping(intent: .create(.natPmp(route, externalAddress: "203.0.113.7", epoch: 100), internalPort: port, lifetime: 3600), permitted: { true }, clock: { 0 }, exchange: { _, route, reply in
                reply(.response(.init(resultCode: 0, internalPort: port, externalPort: port, lifetime: duration, epoch: 100, externalAddress: nil), route)); return {}
            }, completion: { result = $0 }); o.start()
            guard case .granted(let lease, _, _)? = result else { throw NSError(domain: "Missing UDP fixture lease", code: 1) }; return lease
        }
        func upnp() throws -> UPnPMappingCreation.Lease {
            var result: UPnPMappingCreation.Outcome?, step = 0
            let o = UPnPMappingCreation(route: route, service: service, internalPort: 47830, lifetime: 3600, permitted: { true }, clock: { 0 }, token: { "RemSound-fixture-0123456789" }, http: { _, _, reply in
                let rows: [RouterHTTPTransport.Outcome] = [.soap(.fault(code: 714, description: "Absent")), .soap(.success(externalAddress: "203.0.113.7")), .soap(.success(externalAddress: nil)), .soap(.mapping(.init(internalPort: 47830, internalClient: "192.0.2.10", enabled: true, description: "RemSound-fixture-0123456789", leaseSeconds: 120)))]
                guard rows.indices.contains(step) else { XCTFail("Unexpected fixture stage"); return {} }; let row = rows[step]; step += 1; reply(row); return {}
            }, completion: { result = $0 }); o.start()
            guard case .granted(let lease, _)? = result else { throw NSError(domain: "Missing UPnP fixture lease", code: 1) }; return lease
        }
        func fail(_ lane: RouterMappingTransactions, _ lease: RouterUDPMapping.Lease) throws -> RouterMappingTransactions.Evidence {
            lane.submit(.udp(.remove(lease))) { self.results.append($0) }; reply(.udp(.expired))
            return try XCTUnwrap(lane.unresolvedEvidence.last)
        }
        func open(_ o: RouterMappingWorkflow) throws -> RouterMappingWorkflow.Grant {
            o.open(internalPort: 47830, lifetime: 3600) { self.outcomes.append($0) }
            reply(.capability(.selected(.natPmp(route, externalAddress: "203.0.113.7", epoch: 100))))
            reply(.udp(.granted(try udp(), retired: false, epochChanged: false))); return try XCTUnwrap(o.current)
        }
    }
    func testFailedCleanupKeepsExactTargetAndOriginalReceipt() throws {
        let f = Fixture(), lane = f.lane(), lease = try f.udp(), e = try f.fail(lane, lease)
        XCTAssertEqual(e.target, .udp(lease)); XCTAssertEqual(e.originalReceipt, .udp(.expired)); XCTAssertEqual(e.latestReceipt, .udp(.expired))
        lane.submit(f.create) { f.results.append($0) }; XCTAssertEqual(f.operations.count, 1)
    }
    func testLateGrantEvidenceSurvivesAndExplicitRecoveryAllowsFreshMutation() throws {
        let f = Fixture(), lane = f.lane(), lease = try f.udp()
        let id = lane.submit(f.create) { f.results.append($0) }; lane.cancel(id)
        let original: RouterMappingTransactions.Receipt = .udp(.granted(lease, retired: true, epochChanged: false))
        f.reply(original); f.reply(.udp(.retained(lease, retired: false)))
        let e = try XCTUnwrap(lane.unresolvedEvidence.first); XCTAssertEqual(e.originalReceipt, original)
        lane.recover(e.id) { f.results.append($0) }; guard case .udp(.remove(let exact))? = f.operations.last else { return XCTFail("No matching removal") }; XCTAssertEqual(exact, lease)
        f.reply(.udp(.removed(retired: false))); XCTAssertTrue(lane.unresolvedEvidence.isEmpty)
        lane.submit(f.create) { f.results.append($0) }; XCTAssertEqual(f.operations.count, 4)
        lane.shutdown(); f.reply(.udp(.cancelled(mutationMayHaveOccurred: false)))
    }
    func testOneRecoveryCannotClearAnotherTargetOrUnknownMutation() throws {
        let f = Fixture(), lane = f.lane(); lane.submit(f.create) { f.results.append($0) }
        f.reply(.udp(.failure("Lost", mutationMayHaveOccurred: true, retryAfter: 1800)))
        let unknown = try XCTUnwrap(lane.unresolvedEvidence.first); XCTAssertNil(unknown.target)
        let lease = try f.udp(47831), known = try f.fail(lane, lease)
        lane.recover(known.id) { f.results.append($0) }; f.reply(.udp(.removed(retired: false)))
        XCTAssertEqual(lane.unresolvedEvidence.map(\.id), [unknown.id])
        let n = f.operations.count; lane.submit(f.create) { f.results.append($0) }; lane.recover(unknown.id) { f.results.append($0) }; XCTAssertEqual(f.operations.count, n)
    }
    func testOrdinaryUnrelatedCleanupSuccessNeverClearsEvidence() throws {
        let f = Fixture(), lane = f.lane(), lease = try f.udp(), e = try f.fail(lane, lease)
        lane.submit(.udp(.remove(try f.udp(47831)))) { f.results.append($0) }; f.reply(.udp(.removed(retired: false)))
        XCTAssertEqual(lane.unresolvedEvidence.map(\.id), [e.id])
        lane.submit(.udp(.remove(lease))) { f.results.append($0) }; f.reply(.udp(.removed(retired: false)))
        XCTAssertEqual(lane.unresolvedEvidence.map(\.id), [e.id])
    }
    func testExpiredOrRefusedRecoveryCannotClearEvidence() throws {
        for receipt: RouterMappingTransactions.Receipt in [.udp(.expired), .udp(.refused), .udp(.timedOut(mutationMayHaveOccurred: true))] {
            let f = Fixture(), lane = f.lane(), e = try f.fail(lane, f.udp())
            lane.recover(e.id) { f.results.append($0) }; f.reply(receipt)
            XCTAssertEqual(lane.unresolvedEvidence.count, 1); XCTAssertEqual(lane.unresolvedEvidence.first?.id, e.id)
            XCTAssertEqual(lane.unresolvedEvidence.first?.latestReceipt, receipt)
        }
    }
    func testUnknownOrStaleEvidenceIDRefusesBeforeFactory() {
        let f = Fixture(), lane = f.lane(); lane.recover(UUID()) { f.results.append($0) }
        XCTAssertTrue(f.operations.isEmpty); XCTAssertEqual(f.results.count, 1)
    }
    func testQueuedDuplicateRecoveryRechecksEvidenceBeforeFactory() throws {
        let f = Fixture(), lane = f.lane(), e = try f.fail(lane, f.udp())
        lane.recover(e.id) { f.results.append($0) }; lane.recover(e.id) { f.results.append($0) }
        XCTAssertEqual(f.operations.count, 2); f.reply(.udp(.removed(retired: false)))
        XCTAssertEqual(f.operations.count, 2); XCTAssertTrue(lane.unresolvedEvidence.isEmpty); XCTAssertEqual(f.results.count, 3)
    }
    func testRetainedGrantChangesRecoveryTargetAndRetiresQueuedOldProof() throws {
        let f = Fixture(), lane = f.lane(), lease = try f.udp(), e = try f.fail(lane, lease), retained = try f.udp(duration: 100)
        lane.recover(e.id) { f.results.append($0) }; lane.recover(e.id) { f.results.append($0) }
        f.reply(.udp(.retained(retained, retired: false))); XCTAssertEqual(f.operations.count, 2)
        XCTAssertEqual(lane.unresolvedEvidence.first?.target, .udp(retained)); XCTAssertEqual(lane.unresolvedEvidence.first?.originalReceipt, e.originalReceipt)
        lane.recover(e.id) { f.results.append($0) }; guard case .udp(.remove(let exact))? = f.operations.last else { return XCTFail("Updated lease lost") }; XCTAssertEqual(exact, retained)
        f.reply(.udp(.removed(retired: false))); XCTAssertTrue(lane.unresolvedEvidence.isEmpty)
    }
    func testOffAllowsMatchingRecoveryAndIsolationNeverConstructs() throws {
        let f = Fixture(), lane = f.lane(), e = try f.fail(lane, f.udp()); f.enabled = false
        lane.recover(e.id) { f.results.append($0) }; XCTAssertEqual(f.operations.count, 2); f.reply(.udp(.removed(retired: false)))
        let f2 = Fixture(), l2 = f2.lane(), e2 = try f2.fail(l2, f2.udp()); f2.allowed = false
        l2.recover(e2.id) { f2.results.append($0) }; XCTAssertEqual(f2.operations.count, 1); XCTAssertEqual(l2.unresolvedEvidence.count, 1)
    }
    func testRecoveryCancelAndDeadlineWaitForQuiescence() throws {
        let f = Fixture(), lane = f.lane(), e = try f.fail(lane, f.udp())
        let id = lane.recover(e.id) { f.results.append($0) }; lane.cancel(id); f.now = 20; lane.tick()
        XCTAssertEqual(f.results.count, 1); XCTAssertEqual(f.cancels, [1, 1]); XCTAssertEqual(lane.unresolvedEvidence.count, 1)
        f.reply(.udp(.expired)); XCTAssertEqual(f.results.count, 2); XCTAssertTrue(f.results.last?.retired == true); XCTAssertEqual(lane.unresolvedEvidence.count, 1)
    }
    func testSynchronousConfirmationWaitsForFactoryReturn() throws {
        let f = Fixture(), lane = f.lane(), e = try f.fail(lane, f.udp())
        f.onFactory = { i in
            guard i == 1 else { return }; f.reply(.udp(.removed(retired: false)), i)
            XCTAssertEqual(lane.unresolvedEvidence.count, 1); XCTAssertEqual(f.results.count, 1)
        }
        lane.recover(e.id) { f.results.append($0) }; XCTAssertTrue(lane.unresolvedEvidence.isEmpty); XCTAssertEqual(f.results.count, 2)
    }
    func testMismatchedRecoveryReceiptCannotClearOriginalTarget() throws {
        let f = Fixture(), lane = f.lane(), e = try f.fail(lane, f.udp())
        lane.recover(e.id) { f.results.append($0) }; f.reply(.maintained(.absent))
        XCTAssertTrue(lane.unresolvedEvidence.contains { $0.id == e.id }); XCTAssertTrue(lane.unresolvedEvidence.contains { $0.target == nil })
    }
    func testEvidenceLedgerBoundRefusesBeforeAdditionalFactory() throws {
        let f = Fixture(), lane = f.lane()
        for port: UInt16 in 47830..<47846 { _ = try f.fail(lane, f.udp(port)) }
        XCTAssertEqual(lane.unresolvedEvidence.count, 16)
        let n = f.operations.count; lane.submit(.udp(.remove(try f.udp(47846)))) { f.results.append($0) }; lane.submit(.capability) { f.results.append($0) }
        XCTAssertEqual(f.operations.count, n); XCTAssertEqual(lane.unresolvedEvidence.count, 16)
    }
    func testOwnerReleaseKeepsExactRecoveryReceiptThroughQuiescence() throws {
        let f = Fixture(); var lane: RouterMappingTransactions? = f.lane(); let e = try f.fail(try XCTUnwrap(lane), f.udp())
        lane?.recover(e.id) { f.results.append($0) }; weak var weakLane = lane; lane = nil; XCTAssertNil(weakLane)
        XCTAssertEqual(f.results.count, 1); f.reply(.udp(.removed(retired: true))); XCTAssertEqual(f.results.count, 2)
    }
    func testUpnpLeaseAndAcknowledgedClaimRequireMatchingFreshProof() throws {
        for claimOnly in [false, true] {
            let f = Fixture(), lane = f.lane(), lease = try f.upnp()
            if claimOnly {
                lane.submit(.upnpCreate(f.route, f.service, internalPort: 47830, lifetime: 3600)) { f.results.append($0) }
                f.reply(.created(.acknowledged(lease.claim, retired: false, reason: "Accepted"))); f.reply(.maintained(.changed(lease.claim, mutationAcknowledged: false)))
            } else { lane.submit(.upnpMaintain(.lease(lease), .remove)) { f.results.append($0) }; f.reply(.maintained(.expired)) }
            let e = try XCTUnwrap(lane.unresolvedEvidence.first)
            XCTAssertEqual(e.target, claimOnly ? .upnpClaim(lease.claim) : .upnpLease(lease))
            lane.recover(e.id) { f.results.append($0) }; guard case .upnpMaintain(_, .remove)? = f.operations.last else { return XCTFail("Fresh UPnP inspection missing") }
            f.reply(.maintained(.absent)); XCTAssertTrue(lane.unresolvedEvidence.isEmpty)
        }
    }
    func testWorkflowMatchingRecoveryClearsOnlyBookAndAllowsFreshOpen() throws {
        let f = Fixture(), o = f.workflow(); _ = try f.open(o)
        o.stop { f.outcomes.append($0) }; f.reply(.udp(.failure("Denied", mutationMayHaveOccurred: false, retryAfter: 0)))
        let id = try XCTUnwrap(o.unresolvedEvidence.first?.id); XCTAssertTrue(o.hasUnresolvedState)
        o.recover(id) { f.outcomes.append($0) }; f.reply(.udp(.removed(retired: false)))
        XCTAssertFalse(o.hasUnresolvedState); XCTAssertTrue(o.unresolvedEvidence.isEmpty); XCTAssertNil(o.current)
        o.open(internalPort: 47830, lifetime: 3600) { f.outcomes.append($0) }; guard case .capability? = f.operations.last else { return XCTFail("Recovered workflow stayed blocked") }
        o.stop { f.outcomes.append($0) }; f.reply(.capability(.cancelled))
    }
    func testWorkflowUnknownCreationRemainsBlockedWithoutGuessedHandle() throws {
        let f = Fixture(), o = f.workflow(); o.open(internalPort: 47830, lifetime: 3600) { f.outcomes.append($0) }
        f.reply(.capability(.selected(.natPmp(f.route, externalAddress: "203.0.113.7", epoch: 100))))
        f.reply(.udp(.timedOut(mutationMayHaveOccurred: true))); let id = try XCTUnwrap(o.unresolvedEvidence.first?.id)
        let n = f.operations.count; o.recover(id) { f.outcomes.append($0) }; o.wake { f.outcomes.append($0) }
        XCTAssertEqual(f.operations.count, n); XCTAssertTrue(o.hasUnresolvedState)
    }
    func testWorkflowNewestOpenWaitsForRecoveryProofThenRechecksCapability() throws {
        let f = Fixture(), o = f.workflow(); _ = try f.open(o)
        o.stop { f.outcomes.append($0) }; f.reply(.udp(.expired)); let id = try XCTUnwrap(o.unresolvedEvidence.first?.id)
        o.recover(id) { f.outcomes.append($0) }; o.open(internalPort: 47831, lifetime: 3600) { f.outcomes.append($0) }
        XCTAssertEqual(f.operations.count, 4); f.reply(.udp(.removed(retired: true)))
        guard case .capability? = f.operations.last else { return XCTFail("Newest open did not wait for proof") }; XCTAssertFalse(o.hasUnresolvedState)
        o.stop { f.outcomes.append($0) }; f.reply(.capability(.cancelled))
    }
    func testWorkflowFailedRecoveryNeverRearmsOrAutomaticallyRetries() throws {
        let f = Fixture(), o = f.workflow(); _ = try f.open(o)
        o.stop { f.outcomes.append($0) }; f.reply(.udp(.expired)); let id = try XCTUnwrap(o.unresolvedEvidence.first?.id)
        o.recover(id) { f.outcomes.append($0) }; f.reply(.udp(.retained(try f.udp(), retired: false)))
        let n = f.operations.count; o.open(internalPort: 47831, lifetime: 3600) { f.outcomes.append($0) }; o.stop { f.outcomes.append($0) }
        XCTAssertEqual(f.operations.count, n); XCTAssertNil(o.current); XCTAssertTrue(o.hasUnresolvedState)
    }
    func testRepeatedShutdownNeverRestartsOrSkipsPendingReceipt() throws {
        let f = Fixture(), o = f.workflow(); _ = try f.open(o)
        o.shutdown { f.outcomes.append($0) }; o.shutdown { f.outcomes.append($0) }
        XCTAssertEqual(f.operations.count, 3); XCTAssertEqual(f.outcomes.count, 2)
        f.reply(.udp(.removed(retired: true))); XCTAssertEqual(f.outcomes.count, 3)
        o.wake { f.outcomes.append($0) }; XCTAssertEqual(f.operations.count, 3)
    }
    func testFullLedgerMalformedRecoveryPreservesEveryPriorTarget() throws {
        let f = Fixture(), lane = f.lane()
        for port: UInt16 in 47830..<47846 { _ = try f.fail(lane, f.udp(port)) }
        let prior = lane.unresolvedEvidence, first = try XCTUnwrap(prior.first)
        lane.recover(first.id) { f.results.append($0) }; f.reply(.maintained(.absent))
        XCTAssertEqual(lane.unresolvedEvidence.count, 17)
        for e in prior { XCTAssertTrue(lane.unresolvedEvidence.contains { $0.id == e.id && $0.target == e.target }) }
        XCTAssertNil(lane.unresolvedEvidence.last?.target)
    }
    func testIsolatedKnownCleanupRecordsTargetWithoutFactoryThenRecoversWhenAllowed() throws {
        let f = Fixture(), lane = f.lane(), lease = try f.udp(); f.allowed = false
        lane.submit(.udp(.remove(lease))) { f.results.append($0) }; XCTAssertTrue(f.operations.isEmpty)
        let e = try XCTUnwrap(lane.unresolvedEvidence.first); XCTAssertEqual(e.target, .udp(lease))
        f.allowed = true; lane.recover(e.id) { f.results.append($0) }; f.reply(.udp(.removed(retired: false)))
        XCTAssertTrue(lane.unresolvedEvidence.isEmpty)
    }
    func testWorkflowLocalChangedClaimClearsOnlyAfterConfirmedFreshAbsence() throws {
        let f = Fixture(), o = f.workflow(), lease = try f.upnp()
        o.open(internalPort: 47830, lifetime: 3600) { f.outcomes.append($0) }; f.reply(.capability(.selected(.upnp(f.route, f.service))))
        f.reply(.created(.granted(lease, retired: false))); let g = try XCTUnwrap(o.current)
        o.renew(g.id, lifetime: 3600) { f.outcomes.append($0) }; f.reply(.maintained(.changed(lease.claim, mutationAcknowledged: false)))
        XCTAssertTrue(o.hasUnresolvedState); o.remove(g.id) { f.outcomes.append($0) }; f.reply(.maintained(.absent))
        XCTAssertFalse(o.hasUnresolvedState); o.open(internalPort: 47830, lifetime: 3600) { f.outcomes.append($0) }
        guard case .capability? = f.operations.last else { return XCTFail("Local claim state did not follow fresh absence") }
        o.stop { f.outcomes.append($0) }; f.reply(.capability(.cancelled))
    }
    func testActualUpnpOwnerReprovesTokenThenConfirmsDeletionReadback() throws {
        let f = Fixture(), lease = try f.upnp(); var step = 0
        let assembly = RouterProtocolOperations(clock: { f.now }, route: { f.route }, udp: { _, _, _, _ in XCTFail("Unexpected UDP"); return .init(tick: {}, cancel: {}) }, discovery: { _, _, _, _ in XCTFail("Unexpected SSDP"); return .init(tick: {}, cancel: {}) }, http: { _, _, _, reply in
            let rows: [RouterHTTPTransport.Outcome] = [.soap(.fault(code: 401, description: "Failure")), .soap(.mapping(.init(internalPort: lease.claim.internalPort, internalClient: f.route.sourceAddress, enabled: true, description: lease.claim.token, leaseSeconds: 100))), .soap(.success(externalAddress: lease.claim.externalAddress)), .soap(.success(externalAddress: nil)), .soap(.fault(code: 714, description: "Absent"))]
            guard rows.indices.contains(step) else { XCTFail("Unexpected actual maintenance stage"); return .init(tick: {}, cancel: {}) }; let row = rows[step]; step += 1; reply(row); return .init(tick: {}, cancel: {})
        })
        let lane = RouterMappingTransactions(allowed: { true }, enabled: { false }, clock: { f.now }, factory: assembly.make)
        lane.submit(.upnpMaintain(.lease(lease), .remove)) { f.results.append($0) }
        let e = try XCTUnwrap(lane.unresolvedEvidence.first); lane.recover(e.id) { f.results.append($0) }
        XCTAssertEqual(step, 5); XCTAssertTrue(lane.unresolvedEvidence.isEmpty); XCTAssertTrue(f.results.last?.receipt.confirmsRemoval == true)
    }
}
