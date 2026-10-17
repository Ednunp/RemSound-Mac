import Foundation
import XCTest
@testable import RemSoundCore

final class RouterUDPMappingTests: XCTestCase {
    private final class Fixture {
        var now: TimeInterval = 0, permitted = true, nonceCalls = 0, cancels = 0
        var nonce: Data? = Data(0..<12)
        let route = RouterGatewayRoute(gateway: Endpoint("192.0.2.1", 5351), sourceAddress: "192.0.2.10", interface: "fixture")
        var requests: [RouterUDPExchange.Request] = [], callbacks: [(RouterUDPExchange.Outcome) -> Void] = [], results: [RouterUDPMapping.Outcome] = []
        var sync = false
        func operation(_ intent: RouterUDPMapping.Intent? = nil) -> RouterUDPMapping {
            RouterUDPMapping(intent: intent ?? .create(.pcp(route, epoch: 90), internalPort: 47830, lifetime: 3600), permitted: { self.permitted }, clock: { self.now }, nonce: { self.nonceCalls += 1; return self.nonce }, exchange: { request, route, completion in
                XCTAssertEqual(route, self.route); self.requests.append(request); self.callbacks.append(completion)
                if self.sync { completion(.response(self.reply(), route)) }
                return { self.cancels += 1 }
            }, completion: { self.results.append($0) })
        }
        func deliver(_ value: RouterUDPExchange.Outcome, index: Int = 0) {
            guard callbacks.indices.contains(index) else { XCTFail("Expected mapping exchange callback"); return }; callbacks[index](value)
        }
        func reply(code: UInt16 = 0, lifetime: UInt32 = 120, port: UInt16 = 47830, external: UInt16 = 49321, address: String? = "203.0.113.7", epoch: UInt32 = 90) -> RouterMappingReply {
            .init(resultCode: code, internalPort: port, externalPort: external, lifetime: lifetime, epoch: epoch, externalAddress: address)
        }
        func lease(nat: Bool = false) throws -> RouterUDPMapping.Lease {
            let intent: RouterUDPMapping.Intent = .create(nat ? .natPmp(route, externalAddress: "203.0.113.7", epoch: 90) : .pcp(route, epoch: 90), internalPort: 47830, lifetime: 3600)
            let operation = operation(intent); operation.start(); deliver(.response(reply(address: nat ? nil : "203.0.113.7"), route))
            let first = try XCTUnwrap(results.first)
            guard case .granted(let lease, retired: false, _) = first else { throw NSError(domain: "Expected mapping grant", code: 1) }
            requests.removeAll(); callbacks.removeAll(); results.removeAll(); cancels = 0; return lease
        }
    }
    func testOffRefusesBeforeNonceOrExchange() {
        let f = Fixture(); f.permitted = false; let operation = f.operation(); operation.start(); operation.cancel()
        XCTAssertEqual(f.results, [.refused]); XCTAssertEqual(f.nonceCalls, 0); XCTAssertTrue(f.requests.isEmpty)
    }
    func testInvalidPortLifetimeRouteAndUpnpDoNotConstructUdp() {
        let f = Fixture()
        let bad = RouterGatewayRoute(gateway: Endpoint("router.invalid", 5351), sourceAddress: f.route.sourceAddress, interface: "fixture")
        let service = UPnPRouterService(kind: .ip2, controlURL: URL(string: "http://192.0.2.1/control")!, gatewayAddress: "192.0.2.1")
        for intent: RouterUDPMapping.Intent in [.create(.pcp(f.route, epoch: 90), internalPort: 0, lifetime: 3600), .create(.pcp(f.route, epoch: 90), internalPort: 47830, lifetime: 0), .create(.pcp(bad, epoch: 90), internalPort: 47830, lifetime: 3600), .create(.upnp(f.route, service), internalPort: 47830, lifetime: 3600)] {
            let operation = f.operation(intent); operation.start()
            guard case .failure? = f.results.last else { XCTFail("Invalid request must fail"); continue }
        }
        XCTAssertTrue(f.requests.isEmpty); XCTAssertEqual(f.nonceCalls, 0)
    }
    func testNativeNonceIsTwelveBytesAndIndependent() throws {
        let a = try XCTUnwrap(RouterUDPMapping.secureNonce()), b = try XCTUnwrap(RouterUDPMapping.secureNonce())
        XCTAssertEqual(a.count, 12); XCTAssertEqual(b.count, 12); XCTAssertNotEqual(a, b)
    }
    func testPcpCreateUsesOneNonceAndPortScopedMap() {
        let f = Fixture(), operation = f.operation(); operation.start(); operation.start(); operation.tick()
        guard case .pcpMap(let nonce, let port, let external, let lifetime, let address)? = f.requests.first else { return XCTFail("Expected MAP") }
        XCTAssertEqual(nonce, f.nonce); XCTAssertEqual(port, 47830); XCTAssertEqual(external, 47830); XCTAssertEqual(lifetime, 3600); XCTAssertNil(address); XCTAssertEqual(f.nonceCalls, 1)
        f.deliver(.response(f.reply(), f.route)); XCTAssertEqual(f.cancels, 1)
    }
    func testActualGrantPortLifetimeAndRouteAreKept() {
        let f = Fixture(), operation = f.operation(); operation.start(); f.deliver(.response(f.reply(), f.route))
        guard case .granted(let lease, retired: false, epochChanged: false)? = f.results.first else { return XCTFail("Expected grant") }
        XCTAssertEqual(lease.externalPort, 49321); XCTAssertEqual(lease.lifetime, 120); XCTAssertEqual(lease.externalAddress, "203.0.113.7"); XCTAssertEqual(lease.route, f.route); XCTAssertEqual(lease.nonce, f.nonce)
    }
    func testNatGrantUsesCapabilityAddressAndActualPort() {
        let f = Fixture(), operation = f.operation(.create(.natPmp(f.route, externalAddress: "203.0.113.7", epoch: 90), internalPort: 47830, lifetime: 3600))
        operation.start(); f.deliver(.response(f.reply(address: nil), f.route))
        guard case .granted(let lease, _, _)? = f.results.first else { return XCTFail("Expected NAT grant") }
        XCTAssertEqual(lease.kind, .natPmp); XCTAssertNil(lease.nonce); XCTAssertEqual(lease.externalAddress, "203.0.113.7"); XCTAssertEqual(f.nonceCalls, 0)
    }
    func testPcpRenewalAndRemovalKeepOriginalNonceAndGrantedEndpoint() throws {
        let f = Fixture(), lease = try f.lease(); f.nonce = Data(repeating: 99, count: 12)
        let renew = f.operation(.renew(lease, lifetime: 3600)); renew.start()
        guard case .pcpMap(let nonce, let port, let external, let lifetime, let address)? = f.requests.first else { return XCTFail("Expected renewal") }
        XCTAssertEqual(nonce, lease.nonce); XCTAssertEqual(port, lease.internalPort); XCTAssertEqual(external, lease.externalPort); XCTAssertEqual(lifetime, 3600); XCTAssertEqual(address, lease.externalAddress)
        f.deliver(.response(f.reply(lifetime: 600), f.route)); f.requests.removeAll(); f.callbacks.removeAll(); f.results.removeAll()
        let remove = f.operation(.remove(lease)); remove.start()
        guard case .pcpMap(let deletionNonce, let deletionPort, let deletionExternal, let deletionLifetime, let deletionAddress)? = f.requests.first else { return XCTFail("Expected exact deletion") }
        XCTAssertEqual(deletionNonce, lease.nonce); XCTAssertEqual(deletionPort, 47830); XCTAssertEqual(deletionExternal, 49321); XCTAssertEqual(deletionLifetime, 0); XCTAssertEqual(deletionAddress, lease.externalAddress); XCTAssertEqual(f.nonceCalls, 1)
        f.deliver(.response(f.reply(lifetime: 0, external: 0), f.route)); XCTAssertEqual(f.results, [.removed(retired: false)])
    }
    func testNatRenewalUsesGrantedPortAndDeletionNeverUsesPortZeroInternally() throws {
        let f = Fixture(), lease = try f.lease(nat: true)
        let renewal = f.operation(.renew(lease, lifetime: 3600)); renewal.start()
        guard case .natMap(let port, let external, let lifetime)? = f.requests.first else { return XCTFail("Expected NAT renewal") }
        XCTAssertEqual(port, 47830); XCTAssertEqual(external, 49321); XCTAssertEqual(lifetime, 3600)
        f.deliver(.response(f.reply(address: nil), f.route)); f.requests.removeAll(); f.callbacks.removeAll(); f.results.removeAll()
        let remove = f.operation(.remove(lease)); remove.start()
        guard case .natMap(let deletionPort, let suggestion, let zero)? = f.requests.first else { return XCTFail("Expected scoped NAT removal") }
        XCTAssertEqual(deletionPort, 47830); XCTAssertEqual(suggestion, 0); XCTAssertEqual(zero, 0)
        f.deliver(.response(f.reply(lifetime: 0, external: 0, address: nil), f.route)); XCTAssertEqual(f.results, [.removed(retired: false)])
    }
    func testCancelledCreationReturnsLateGrantAfterQuiescence() {
        let f = Fixture(), operation = f.operation(); operation.start(); operation.cancel(); operation.cancel()
        XCTAssertTrue(f.results.isEmpty); XCTAssertEqual(f.cancels, 1)
        f.deliver(.lateResponse(f.reply(), f.route))
        guard case .granted(let lease, retired: true, _)? = f.results.first else { return XCTFail("Retired grant must reach exact cleanup owner") }
        XCTAssertEqual(lease.externalPort, 49321); XCTAssertEqual(f.cancels, 1)
    }
    func testDeadlineWaitsForReceiptAndReturnsCreatedLease() {
        let f = Fixture(), operation = f.operation(); operation.start(); f.now = 8; operation.tick(); operation.tick()
        XCTAssertTrue(f.results.isEmpty); XCTAssertEqual(f.cancels, 1); f.deliver(.lateResponse(f.reply(), f.route))
        guard case .granted(_, retired: true, _)? = f.results.first else { return XCTFail("Deadline cannot discard a created lease") }
    }
    func testCancelledLostMutationIsNotClaimedRolledBack() {
        let f = Fixture(), operation = f.operation(); operation.start(); operation.cancel(); f.deliver(.cancelled(mutationMayHaveOccurred: true))
        XCTAssertEqual(f.results, [.cancelled(mutationMayHaveOccurred: true)]); XCTAssertEqual(f.requests.count, 1)
    }
    func testDisableDuringMutationReturnsExactLateLease() {
        let f = Fixture(), operation = f.operation(); operation.start(); f.permitted = false; operation.tick(); f.deliver(.response(f.reply(), f.route))
        guard case .granted(_, retired: true, _)? = f.results.first else { return XCTFail("Permission loss cannot drop an existing grant") }
    }
    func testWrongRoutePortAndMalformedGrantCannotBecomeOwned() {
        let f = Fixture()
        let other = RouterGatewayRoute(gateway: Endpoint("192.0.2.2", 5351), sourceAddress: "192.0.2.10", interface: "fixture")
        for (reply, route) in [(f.reply(), other), (f.reply(port: 47831), f.route), (f.reply(lifetime: 0), f.route), (f.reply(external: 0), f.route), (f.reply(address: "router.invalid"), f.route)] {
            f.results.removeAll(); f.callbacks.removeAll(); let operation = f.operation(); operation.start(); f.deliver(.response(reply, route))
            guard case .failure(_, mutationMayHaveOccurred: true, _)? = f.results.first else { XCTFail("Unmatched grant must remain uncertain"); continue }
        }
    }
    func testProtocolRefusalAndBackoffDoNotTriggerAnotherMappingProtocol() {
        for (code, life, retry): (UInt16, UInt32, TimeInterval) in [(2, 0, 1800), (8, 120, 120), (13, 0, 1800), (65535, 0, 1800)] {
            let f = Fixture(), operation = f.operation(); operation.start(); f.deliver(.response(f.reply(code: code, lifetime: life, external: 0, address: nil), f.route))
            guard case .failure(_, mutationMayHaveOccurred: false, retryAfter: let value)? = f.results.first else { XCTFail("Explicit refusal must fail truthfully"); continue }; XCTAssertEqual(value, retry); XCTAssertEqual(f.requests.count, 1)
        }
    }
    func testMaxLifetimeReportsExistingMappingWithoutDeletableLease() {
        let f = Fixture(), operation = f.operation(); operation.start(); f.deliver(.response(f.reply(lifetime: UInt32.max), f.route))
        XCTAssertEqual(f.results, [.existingMapping(externalAddress: "203.0.113.7", externalPort: 49321)])
    }
    func testManualMappingDeletionRefusalNeverReportsRemoved() throws {
        let f = Fixture(), lease = try f.lease(nat: true), operation = f.operation(.remove(lease)); operation.start(); f.deliver(.response(f.reply(code: 2, lifetime: 0, external: 0, address: nil), f.route))
        guard case .failure(_, mutationMayHaveOccurred: false, _)? = f.results.first else { return XCTFail("Manual mapping refusal must preserve truthful result") }
    }
    func testPcpDeleteMayRetainOutboundLifetimeAndMustNotReportRemoved() throws {
        let f = Fixture(), lease = try f.lease(), operation = f.operation(.remove(lease)); operation.start(); f.deliver(.response(f.reply(lifetime: 30), f.route))
        guard case .retained(let stillActive, retired: false)? = f.results.first else { return XCTFail("Positive deletion lifetime remains active") }
        XCTAssertEqual(stillActive.lifetime, 30); XCTAssertEqual(stillActive.nonce, lease.nonce)
    }
    func testZeroLifetimeDeletionReceiptIsDistinctFromLiveGrant() throws {
        let f = Fixture(), lease = try f.lease(), operation = f.operation(.remove(lease)); operation.start(); f.deliver(.response(f.reply(lifetime: 0, external: 0), f.route))
        XCTAssertEqual(f.results, [.removed(retired: false)])
    }
    func testPcpEpochBackwardToleranceAndDriftUseProtocolFormula() throws {
        let f = Fixture(), lease = try f.lease()
        XCTAssertFalse(lease.epochChanged(to: 89, at: 0)); XCTAssertTrue(lease.epochChanged(to: 88, at: 0))
        XCTAssertFalse(lease.epochChanged(to: 122, at: 30)); XCTAssertTrue(lease.epochChanged(to: 150, at: 30))
        XCTAssertTrue(lease.epochChanged(to: 0, at: 60)); XCTAssertTrue(lease.epochChanged(to: 90, at: .nan))
    }
    func testNatEpochConservativeSevenEighthsAndTwoSecondTolerance() throws {
        let f = Fixture(), lease = try f.lease(nat: true)
        XCTAssertFalse(lease.epochChanged(to: 96, at: 8)); XCTAssertTrue(lease.epochChanged(to: 94, at: 8)); XCTAssertTrue(lease.epochChanged(to: 1, at: 8))
    }
    func testDeallocationStillDeliversLateGrantForCleanup() {
        let f = Fixture(); var operation: RouterUDPMapping? = f.operation(); operation?.start(); weak var released = operation; operation = nil
        XCTAssertNil(released); XCTAssertEqual(f.cancels, 1); f.deliver(.lateResponse(f.reply(), f.route))
        guard case .granted(_, retired: true, _)? = f.results.first else { return XCTFail("Releasing owner cannot drop its side effect") }
    }
    func testSynchronousResultCleansReturnedCancellationResource() {
        let f = Fixture(); f.sync = true; let operation = f.operation(); operation.start(); operation.cancel()
        XCTAssertEqual(f.results.count, 1); XCTAssertEqual(f.cancels, 1)
    }
    func testNonceFailureOrWrongLengthRefusesBeforeExchange() {
        for nonce: Data? in [nil, Data(repeating: 0, count: 11), Data(repeating: 0, count: 13)] {
            let f = Fixture(); f.nonce = nonce; let operation = f.operation(); operation.start(); XCTAssertTrue(f.requests.isEmpty)
            guard case .failure(_, mutationMayHaveOccurred: false, _)? = f.results.first else { XCTFail("Nonce failure must not send"); continue }
        }
    }
    func testStopDuringFactoryRetiresReturnedResourceAndWaitsForActualResult() {
        let f = Fixture(); weak var live: RouterUDPMapping?
        let operation = RouterUDPMapping(intent: .create(.pcp(f.route, epoch: 90), internalPort: 47830, lifetime: 3600), permitted: { true }, clock: { f.now }, nonce: { f.nonce }, exchange: { _, _, completion in f.callbacks.append(completion); live?.cancel(); return { f.cancels += 1 } }, completion: { f.results.append($0) })
        live = operation; operation.start(); XCTAssertEqual(f.cancels, 1); XCTAssertTrue(f.results.isEmpty)
        f.deliver(.lateResponse(f.reply(), f.route)); guard case .granted(_, retired: true, _)? = f.results.first else { return XCTFail("Factory race lost grant") }
    }
    func testPermissionOrDeadlineChangedDuringNoncePreparationCannotSend() {
        for expire in [false, true] {
            let f = Fixture(); let operation = RouterUDPMapping(intent: .create(.pcp(f.route, epoch: 90), internalPort: 47830, lifetime: 3600), permitted: { f.permitted }, clock: { f.now }, nonce: { if expire { f.now = 8 } else { f.permitted = false }; return f.nonce }, exchange: { _, _, _ in XCTFail("Obsolete prepared request sent"); return {} }, completion: { f.results.append($0) })
            operation.start(); XCTAssertEqual(f.results.count, 1)
        }
    }
    func testDelayedReceiptUsesConservativeLifetimeWithoutChangingEpochClock() {
        let f = Fixture(), operation = f.operation(); operation.start(); f.now = 2; f.deliver(.response(f.reply(), f.route))
        guard case .granted(let lease, _, _)? = f.results.first else { return XCTFail("Expected grant") }
        XCTAssertEqual(lease.validUntil, 120); XCTAssertEqual(lease.obtainedAt, 2)
    }
    func testStaleLeaseCannotDeleteNewerRuleAfterItsLocalExpiry() throws {
        for nat in [false, true] {
            let f = Fixture(), lease = try f.lease(nat: nat); f.now = 120
            let operation = f.operation(.remove(lease)); operation.start()
            XCTAssertEqual(f.results, [.expired]); XCTAssertTrue(f.requests.isEmpty)
        }
    }
    func testExpiredRenewalRequiresFreshSelectionInsteadOfTouchingUnknownState() throws {
        let f = Fixture(), lease = try f.lease(nat: true); f.now = 121
        let operation = f.operation(.renew(lease, lifetime: 3600)); operation.start()
        XCTAssertEqual(f.results, [.expired]); XCTAssertTrue(f.requests.isEmpty)
    }
    func testDuplicateReceiptsDeliverOneGrantAndNeverResend() {
        let f = Fixture(), operation = f.operation(); operation.start(); let result = RouterUDPExchange.Outcome.response(f.reply(), f.route)
        f.deliver(result); f.deliver(result); operation.tick(); XCTAssertEqual(f.results.count, 1); XCTAssertEqual(f.requests.count, 1); XCTAssertEqual(f.cancels, 1)
    }
}
