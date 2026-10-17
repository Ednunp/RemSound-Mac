import Foundation
import XCTest
@testable import RemSoundCore

final class UPnPMappingMaintenanceTests: XCTestCase {
    private final class Fixture {
        var now: TimeInterval = 2, permitted = true, cancels = 0
        let route = RouterGatewayRoute(gateway: Endpoint("192.0.2.1", 5351), sourceAddress: "192.0.2.10", interface: "fixture")
        var service: UPnPRouterService { .init(kind: .ip2, controlURL: URL(string: "http://192.0.2.1/control")!, gatewayAddress: "192.0.2.1") }
        let token = "RemSound-fixture-0123456789"
        var requests: [RouterHTTPTransport.Request] = [], budgets: [TimeInterval] = []
        var callbacks: [(RouterHTTPTransport.Outcome) -> Void] = [], results: [UPnPMappingMaintenance.Outcome] = []
        func lease() throws -> UPnPMappingCreation.Lease {
            var result: UPnPMappingCreation.Outcome?
            // Drive the real creation owner, rather than widening opaque lease constructors.
            var stage = 0
            let actual = UPnPMappingCreation(route: route, service: service, internalPort: 47830, lifetime: 3600, permitted: { true }, clock: { 0 }, token: { self.token }, http: { _, _, reply in
                let replies: [RouterHTTPTransport.Outcome] = [.soap(.fault(code: 714, description: "No entry")), .soap(.success(externalAddress: "203.0.113.7")), .soap(.success(externalAddress: nil)), .soap(.mapping(self.mapping()))]
                guard replies.indices.contains(stage) else { XCTFail("Unexpected creation request"); return {} }
                let next = replies[stage]; stage += 1; reply(next); return {}
            }, completion: { result = $0 })
            actual.start()
            guard case .granted(let lease, _)? = result else { throw NSError(domain: "Missing creation receipt", code: 1) }
            return lease
        }
        func operation(_ action: UPnPMappingMaintenance.Action = .remove, claimOnly: Bool = false) throws -> UPnPMappingMaintenance {
            let lease = try lease()
            let factory: RouterCapability.HTTPFactory = { request, budget, reply in self.requests.append(request); self.budgets.append(budget); self.callbacks.append(reply); return { self.cancels += 1 } }
            if claimOnly { return UPnPMappingMaintenance(claim: lease.claim, permitted: { self.permitted }, clock: { self.now }, http: factory, completion: { self.results.append($0) }) }
            return UPnPMappingMaintenance(lease: lease, action: action, permitted: { self.permitted }, clock: { self.now }, http: factory, completion: { self.results.append($0) })
        }
        func reply(_ result: RouterHTTPTransport.Outcome, index: Int? = nil) {
            let i = index ?? callbacks.count - 1; guard callbacks.indices.contains(i) else { XCTFail("Missing HTTP callback"); return }; callbacks[i](result)
        }
        func mapping(token: String? = nil, port: UInt16 = 47830, client: String = "192.0.2.10", enabled: Bool = true, lifetime: UInt32 = 120) -> UPnPPortMapping {
            .init(internalPort: port, internalClient: client, enabled: enabled, description: token ?? self.token, leaseSeconds: lifetime)
        }
        func toMutation() { reply(.soap(.mapping(mapping()))); reply(.soap(.success(externalAddress: "203.0.113.7"))) }
    }
    func testOffRefusesBeforeHttp() throws {
        let f = Fixture(); f.permitted = false; let op = try f.operation(); op.start()
        XCTAssertEqual(f.results, [.refused]); XCTAssertTrue(f.requests.isEmpty)
    }
    func testExpiredLeaseRefusesBeforeHttp() throws {
        let f = Fixture(); f.now = 120; let op = try f.operation(); op.start()
        XCTAssertEqual(f.results, [.expired]); XCTAssertTrue(f.requests.isEmpty)
    }
    func testInvalidRenewalLifetimeRefusesBeforeHttp() throws {
        for lifetime: UInt32 in [0, 604801] {
            let f = Fixture(), op = try f.operation(.renew(lifetime: lifetime)); op.start()
            XCTAssertTrue(f.requests.isEmpty); guard case .failure? = f.results.first else { XCTFail("Invalid renewal accepted"); continue }
        }
    }
    func testAbsentPreflightDoesNotMutate() throws {
        let f = Fixture(), op = try f.operation(); op.start(); f.reply(.soap(.fault(code: 714, description: "Absent")))
        XCTAssertEqual(f.results, [.absent]); XCTAssertEqual(f.requests.map(\.action), [.specificMapping])
    }
    func testReplacementAndDisabledPermanentRulesNeverMutate() throws {
        for entry in [Fixture().mapping(token: "Other"), Fixture().mapping(token: " RemSound-fixture-0123456789"), Fixture().mapping(port: 47831), Fixture().mapping(client: "192.0.2.11"), Fixture().mapping(enabled: false), Fixture().mapping(lifetime: 0), Fixture().mapping(lifetime: UInt32.max)] {
            let f = Fixture(), op = try f.operation(); op.start(); f.reply(.soap(.mapping(entry)))
            XCTAssertEqual(f.requests.count, 1); guard case .changed(_, mutationAcknowledged: false)? = f.results.first else { XCTFail("Unknown or permanent rule was accepted"); continue }
        }
    }
    func testPreflightFailureCannotReachDelete() throws {
        let f = Fixture(), op = try f.operation(); op.start(); f.reply(.soap(.fault(code: 606, description: "Denied")))
        XCTAssertEqual(f.requests.count, 1); guard case .retained(_, mutationAcknowledged: false, _)? = f.results.first else { return XCTFail("Failure lost claim") }
    }
    func testDeleteReprovesExactTupleAndConfirmsAbsence() throws {
        let f = Fixture(), op = try f.operation(); op.start(); f.toMutation()
        XCTAssertEqual(f.requests.map(\.action), [.specificMapping, .externalIP, .delete])
        let body = f.requests.last?.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
        XCTAssertTrue(body.contains("<NewExternalPort>47830</NewExternalPort><NewProtocol>UDP</NewProtocol>"))
        f.reply(.soap(.success(externalAddress: nil))); XCTAssertTrue(f.results.isEmpty)
        f.reply(.soap(.fault(code: 714, description: "Absent"))); XCTAssertEqual(f.results, [.removed]); XCTAssertEqual(f.cancels, 4)
    }
    func testDeleteAcknowledgmentWithSameReadbackIsRetained() throws {
        let f = Fixture(), op = try f.operation(); op.start(); f.toMutation(); f.reply(.soap(.success(externalAddress: nil))); f.reply(.soap(.mapping(f.mapping())))
        guard case .retained(_, mutationAcknowledged: true, _)? = f.results.first else { return XCTFail("Rule still exists") }
    }
    func testDeleteAcknowledgmentWithReplacementReadbackDoesNotDeleteAgain() throws {
        let f = Fixture(), op = try f.operation(); op.start(); f.toMutation(); f.reply(.soap(.success(externalAddress: nil))); f.reply(.soap(.mapping(f.mapping(token: "Replacement"))))
        guard case .changed(_, mutationAcknowledged: true)? = f.results.first else { return XCTFail("Replacement not reported") }
        XCTAssertEqual(f.requests.count, 4)
    }
    func testDeleteFaultIsRetainedAndNotReportedRemoved() throws {
        let f = Fixture(), op = try f.operation(); op.start(); f.toMutation(); f.reply(.soap(.fault(code: 606, description: "Denied")))
        guard case .retained(_, mutationAcknowledged: false, _)? = f.results.first else { return XCTFail("Deletion refusal falsely succeeded") }
        XCTAssertEqual(f.requests.count, 3)
    }
    func testLostDeleteRemainsUncertainWithoutRetry() throws {
        let f = Fixture(), op = try f.operation(); op.start(); f.toMutation(); f.reply(.failure("Lost", mutationMayHaveOccurred: true))
        guard case .uncertain(let claim, _)? = f.results.first else { return XCTFail("Lost deletion falsely confirmed") }
        XCTAssertEqual(claim.token, f.token); XCTAssertEqual(f.requests.count, 3)
    }
    func testDeleteReadbackFailureRetainsAcknowledgedClaim() throws {
        let f = Fixture(), op = try f.operation(); op.start(); f.toMutation(); f.reply(.soap(.success(externalAddress: nil))); f.reply(.failure("Readback lost", mutationMayHaveOccurred: false))
        guard case .retained(_, mutationAcknowledged: true, _)? = f.results.first else { return XCTFail("Unknown removal must retain receipt") }
    }
    func testRenewalKeepsTokenAndUsesActualGrantFromRequestStart() throws {
        let f = Fixture(), op = try f.operation(.renew(lifetime: 3600)); op.start(); f.now = 3; f.toMutation()
        let body = f.requests.last?.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
        XCTAssertTrue(body.contains("<NewPortMappingDescription>\(f.token)</NewPortMappingDescription>"))
        f.now = 4; f.reply(.soap(.success(externalAddress: nil))); f.now = 5; f.reply(.soap(.mapping(f.mapping(lifetime: 60))))
        guard case .renewed(let lease, retired: false)? = f.results.first else { return XCTFail("Renewal missing") }
        XCTAssertEqual(lease.validUntil, 63); XCTAssertEqual(lease.claim.requestStarted, 3); XCTAssertEqual(lease.lifetime, 60); XCTAssertEqual(lease.claim.externalAddress, "203.0.113.7")
    }
    func testRenewalDoesNotAcceptPermanentOrChangedReadback() throws {
        for entry in [Fixture().mapping(lifetime: 0), Fixture().mapping(token: "Replacement")] {
            let f = Fixture(), op = try f.operation(.renew(lifetime: 3600)); op.start(); f.toMutation(); f.reply(.soap(.success(externalAddress: nil))); f.reply(.soap(.mapping(entry)))
            guard case .retained(_, mutationAcknowledged: true, _)? = f.results.first else { XCTFail("Unverified renewal lease accepted"); continue }
        }
    }
    func testCancelledRenewalAcknowledgmentRetainsNewClaim() throws {
        let f = Fixture(), op = try f.operation(.renew(lifetime: 3600)); op.start(); f.now = 3; f.toMutation(); op.cancel(); XCTAssertTrue(f.results.isEmpty)
        f.reply(.soap(.success(externalAddress: nil)))
        guard case .retained(let claim, mutationAcknowledged: true, _)? = f.results.first else { return XCTFail("Late accepted renewal disappeared") }
        XCTAssertEqual(claim.requestStarted, 3); XCTAssertEqual(f.requests.count, 3)
    }
    func testCancelledDeleteAcknowledgmentDoesNotClaimVerifiedRemoval() throws {
        let f = Fixture(), op = try f.operation(); op.start(); f.toMutation(); op.cancel(); f.reply(.soap(.success(externalAddress: nil)))
        guard case .retained(_, mutationAcknowledged: true, _)? = f.results.first else { return XCTFail("Cancelled unverified removal lost acknowledgment") }
        XCTAssertEqual(f.requests.count, 3)
    }
    func testCancellationDuringReadbackCanStillConfirmRemoval() throws {
        let f = Fixture(), op = try f.operation(); op.start(); f.toMutation(); f.reply(.soap(.success(externalAddress: nil))); op.cancel()
        f.reply(.soap(.fault(code: 714, description: "Absent"))); XCTAssertEqual(f.results, [.removed])
    }
    func testCancellationDuringReadbackKeepsVerifiedRetiredRenewal() throws {
        let f = Fixture(), op = try f.operation(.renew(lifetime: 3600)); op.start(); f.toMutation(); f.reply(.soap(.success(externalAddress: nil))); op.cancel()
        f.reply(.soap(.mapping(f.mapping())))
        guard case .renewed(_, retired: true)? = f.results.first else { return XCTFail("Late verified lease missing") }
    }
    func testClaimCleanupAlwaysReprovesOwnership() throws {
        let f = Fixture(), op = try f.operation(claimOnly: true); op.start(); f.reply(.soap(.mapping(f.mapping(token: "Manual"))))
        guard case .changed(_, mutationAcknowledged: false)? = f.results.first else { return XCTFail("Claim blindly deleted") }
        XCTAssertEqual(f.requests.count, 1)
    }
    func testClaimCleanupCanRemoveMatchingFiniteRule() throws {
        let f = Fixture(), op = try f.operation(claimOnly: true); op.start(); f.toMutation(); f.reply(.soap(.success(externalAddress: nil))); f.reply(.soap(.fault(code: 714, description: "Absent")))
        XCTAssertEqual(f.results, [.removed])
    }
    func testExpiredClaimCleanupCannotProbeOrDelete() throws {
        let f = Fixture(); f.now = 3600; let op = try f.operation(claimOnly: true); op.start()
        XCTAssertEqual(f.results, [.expired]); XCTAssertTrue(f.requests.isEmpty)
    }
    func testLeaseExpiryDuringPreflightRefusesMutation() throws {
        let f = Fixture(); f.now = 119; let op = try f.operation(); op.start(); f.now = 120; f.reply(.soap(.mapping(f.mapping())))
        XCTAssertEqual(f.results, [.expired]); XCTAssertEqual(f.requests.count, 1)
    }
    func testCancelBeforePreflightReceiptWaitsForQuiescence() throws {
        let f = Fixture(), op = try f.operation(); op.start(); op.cancel(); op.cancel(); XCTAssertTrue(f.results.isEmpty); XCTAssertEqual(f.cancels, 1)
        f.reply(.soap(.mapping(f.mapping()))); XCTAssertEqual(f.results, [.cancelled]); XCTAssertEqual(f.requests.count, 1)
    }
    func testPermissionAndDeadlineRetirePendingWorkOnce() throws {
        for deadline in [false, true] {
            let f = Fixture(), op = try f.operation(); op.start()
            if deadline { f.now = 10 } else { f.permitted = false }; op.tick(); op.tick()
            XCTAssertTrue(f.results.isEmpty); XCTAssertEqual(f.cancels, 1); f.reply(.soap(.mapping(f.mapping())))
            XCTAssertEqual(f.results, [deadline ? .timedOut : .refused]); XCTAssertEqual(f.requests.count, 1)
        }
    }
    func testRemainingBudgetAndDuplicateReceiptsCannotRepeatMutation() throws {
        let f = Fixture(), op = try f.operation(); op.start(); f.now = 4; f.toMutation(); f.reply(.soap(.mapping(f.mapping())), index: 0)
        XCTAssertEqual(f.requests.count, 3); XCTAssertEqual(f.budgets, [8, 6, 6])
        f.reply(.soap(.mapping(f.mapping())), index: 0); XCTAssertEqual(f.requests.count, 3)
        f.reply(.soap(.success(externalAddress: nil)), index: 2); f.reply(.soap(.success(externalAddress: nil)), index: 2)
        XCTAssertEqual(f.requests.count, 4); f.reply(.soap(.fault(code: 714, description: "Absent"))); XCTAssertEqual(f.results, [.removed])
    }
    func testOwnerReleaseWaitsAndRetainsLateMutation() throws {
        let f = Fixture(); var op: UPnPMappingMaintenance? = try f.operation(); op?.start(); f.toMutation(); weak var released = op; op = nil
        XCTAssertNil(released); XCTAssertTrue(f.results.isEmpty); f.reply(.soap(.success(externalAddress: nil)))
        guard case .retained(_, mutationAcknowledged: true, _)? = f.results.first else { return XCTFail("Owner release lost mutation") }
    }
    func testSynchronousPreflightCleansExactReturnedResource() throws {
        let f = Fixture(), lease = try f.lease()
        let op = UPnPMappingMaintenance(lease: lease, action: .remove, permitted: { true }, clock: { f.now }, http: { _, _, reply in reply(.soap(.fault(code: 714, description: "Absent"))); return { f.cancels += 1 } }, completion: { f.results.append($0) })
        op.start(); XCTAssertEqual(f.results, [.absent]); XCTAssertEqual(f.cancels, 1)
    }
    func testNonfiniteOrBackwardClockNeverMutates() throws {
        let f = Fixture(), op = try f.operation(); op.start(); f.now = 1; f.reply(.soap(.mapping(f.mapping())))
        XCTAssertEqual(f.requests.count, 1); guard case .failure? = f.results.first else { return XCTFail("Backward clock accepted") }
    }
    func testChangedExternalAddressCannotRenewOrDeleteOldTuple() throws {
        for action: UPnPMappingMaintenance.Action in [.remove, .renew(lifetime: 3600)] {
            let f = Fixture(), op = try f.operation(action); op.start(); f.reply(.soap(.mapping(f.mapping())))
            f.reply(.soap(.success(externalAddress: "203.0.113.8")))
            XCTAssertEqual(f.requests.map(\.action), [.specificMapping, .externalIP])
            guard case .changed(_, mutationAcknowledged: false)? = f.results.first else { XCTFail("Changed WAN tuple mutated"); continue }
        }
    }
    func testExpiryAfterOwnershipReadCannotReachMutation() throws {
        let f = Fixture(); f.now = 119; let op = try f.operation(); op.start(); f.reply(.soap(.mapping(f.mapping())))
        f.now = 120; f.reply(.soap(.success(externalAddress: "203.0.113.7")))
        XCTAssertEqual(f.results, [.expired]); XCTAssertEqual(f.requests.count, 2)
    }
    func testRenewalReadbackAfterActualExpiryDoesNotReturnLiveLease() throws {
        let f = Fixture(), op = try f.operation(.renew(lifetime: 3600)); op.start(); f.toMutation(); f.reply(.soap(.success(externalAddress: nil)))
        f.now = 4; f.reply(.soap(.mapping(f.mapping(lifetime: 1))))
        guard case .retained(_, mutationAcknowledged: true, _)? = f.results.first else { return XCTFail("Expired renewal exposed as live lease") }
    }
    func testLostRenewalReturnsNewAttemptClaim() throws {
        let f = Fixture(), op = try f.operation(.renew(lifetime: 3600)); op.start(); f.now = 3; f.toMutation()
        f.reply(.failure("Lost", mutationMayHaveOccurred: true))
        guard case .uncertain(let claim, _)? = f.results.first else { return XCTFail("Lost renewal receipt disappeared") }
        XCTAssertEqual(claim.requestStarted, 3); XCTAssertEqual(claim.token, f.token); XCTAssertEqual(f.requests.count, 3)
    }
    func testDeadlineDuringMutationPreservesAcknowledgedClaim() throws {
        let f = Fixture(), op = try f.operation(); op.start(); f.toMutation(); f.now = 10; op.tick()
        XCTAssertTrue(f.results.isEmpty); f.reply(.soap(.success(externalAddress: nil)))
        guard case .retained(_, mutationAcknowledged: true, _)? = f.results.first else { return XCTFail("Deadline lost accepted Delete") }
        XCTAssertEqual(f.requests.count, 3)
    }
    func testClaimCleanupAbsenceDoesNotIssueDelete() throws {
        let f = Fixture(), op = try f.operation(claimOnly: true); op.start(); f.reply(.soap(.fault(code: 714, description: "Absent")))
        XCTAssertEqual(f.results, [.absent]); XCTAssertEqual(f.requests.count, 1)
    }
    func testReentrantFactoryCancelWaitsForReceiptAndCleansReturnedResource() throws {
        let f = Fixture(), lease = try f.lease(); var op: UPnPMappingMaintenance?
        op = UPnPMappingMaintenance(lease: lease, action: .remove, permitted: { true }, clock: { f.now }, http: { _, _, reply in
            f.callbacks.append(reply); op?.cancel(); return { f.cancels += 1 }
        }, completion: { f.results.append($0) })
        op?.start(); XCTAssertEqual(f.cancels, 1); XCTAssertTrue(f.results.isEmpty)
        f.reply(.soap(.fault(code: 714, description: "Absent"))); XCTAssertEqual(f.results, [.cancelled]); XCTAssertEqual(f.cancels, 1)
        op = nil
    }
    func testNonfiniteInitialClockRefusesBeforeHttp() throws {
        let f = Fixture(); f.now = .nan; let op = try f.operation(); op.start()
        XCTAssertTrue(f.requests.isEmpty); guard case .failure? = f.results.first else { return XCTFail("Invalid clock accepted") }
    }
}
