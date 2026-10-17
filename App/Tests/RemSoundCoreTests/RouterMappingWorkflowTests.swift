import Foundation
import XCTest
@testable import RemSoundCore

final class RouterMappingWorkflowTests: XCTestCase {
    private final class Fixture {
        var now: TimeInterval = 2, allowed = true, enabled = true
        let route = RouterGatewayRoute(gateway: Endpoint("192.0.2.1", 5351), sourceAddress: "192.0.2.10", interface: "fixture")
        var operations: [RouterMappingTransactions.Operation] = []
        var callbacks: [(RouterMappingTransactions.Receipt) -> Void] = [], cancels: [Int] = []
        var results: [RouterMappingWorkflow.Outcome] = [], onFactory: ((Int) -> Void)?
        var service: UPnPRouterService { .init(kind: .ip2, controlURL: URL(string: "http://192.0.2.1/control")!, gatewayAddress: "192.0.2.1") }
        func owner() -> RouterMappingWorkflow {
            .init(allowed: { self.allowed }, enabled: { self.enabled }, clock: { self.now }, factory: { operation, gate, reply in
                XCTAssertTrue(gate()); let i = self.operations.count
                self.operations.append(operation); self.callbacks.append(reply); self.cancels.append(0); self.onFactory?(i)
                return .init(tick: {}, cancel: { self.cancels[i] += 1 })
            })
        }
        func reply(_ r: RouterMappingTransactions.Receipt, _ i: Int? = nil) {
            let i = i ?? callbacks.count - 1
            guard callbacks.indices.contains(i) else { return XCTFail("Missing workflow operation") }; callbacks[i](r)
        }
        func select(_ i: Int? = nil) { reply(.capability(.selected(.natPmp(route, externalAddress: "203.0.113.7", epoch: 100))), i) }
        func udpLease(_ duration: UInt32 = 120) throws -> RouterUDPMapping.Lease {
            var result: RouterUDPMapping.Outcome?
            let op = RouterUDPMapping(intent: .create(.natPmp(route, externalAddress: "203.0.113.7", epoch: 100), internalPort: 47830, lifetime: 3600), permitted: { true }, clock: { 0 }, exchange: { _, route, reply in
                reply(.response(.init(resultCode: 0, internalPort: 47830, externalPort: 49321, lifetime: duration, epoch: 100, externalAddress: nil), route)); return {}
            }, completion: { result = $0 }); op.start()
            guard case .granted(let lease, _, _)? = result else { throw NSError(domain: "Missing private lease", code: 1) }; return lease
        }
        func upnpLease() throws -> UPnPMappingCreation.Lease {
            var result: UPnPMappingCreation.Outcome?, stage = 0
            let op = UPnPMappingCreation(route: route, service: service, internalPort: 47830, lifetime: 3600, permitted: { true }, clock: { 0 }, token: { "RemSound-fixture-0123456789" }, http: { _, _, reply in
                let rows: [RouterHTTPTransport.Outcome] = [.soap(.fault(code: 714, description: "Absent")), .soap(.success(externalAddress: "203.0.113.7")), .soap(.success(externalAddress: nil)), .soap(.mapping(.init(internalPort: 47830, internalClient: "192.0.2.10", enabled: true, description: "RemSound-fixture-0123456789", leaseSeconds: 120)))]
                guard rows.indices.contains(stage) else { XCTFail("Unexpected creation stage"); return {} }; let row = rows[stage]; stage += 1; reply(row); return {}
            }, completion: { result = $0 }); op.start()
            guard case .granted(let lease, _)? = result else { throw NSError(domain: "Missing private UPnP lease", code: 1) }; return lease
        }
        func open(_ owner: RouterMappingWorkflow) throws -> RouterMappingWorkflow.Grant {
            owner.open(internalPort: 47830, lifetime: 3600) { self.results.append($0) }; select(); reply(.udp(.granted(try udpLease(), retired: false, epochChanged: false)))
            return try XCTUnwrap(owner.current)
        }
    }
    func testOffIsolationAndInvalidInputConstructNothing() {
        for mode in 0..<3 {
            let f = Fixture(); if mode == 0 { f.enabled = false }; if mode == 1 { f.allowed = false }; let o = f.owner()
            o.open(internalPort: mode == 2 ? 0 : 47830, lifetime: 3600) { f.results.append($0) }
            XCTAssertTrue(f.operations.isEmpty); XCTAssertEqual(f.results.count, 1); XCTAssertNil(o.current)
        }
    }
    func testCurrentGrantUsesActualTupleAndConservativeValidity() throws {
        let f = Fixture(), o = f.owner(); let g = try f.open(o)
        XCTAssertEqual(g.externalAddress, "203.0.113.7"); XCTAssertEqual(g.externalPort, 49321)
        XCTAssertEqual(g.remainingLifetime(at: 6), 114); XCTAssertEqual(g.remainingLifetime(at: -1), 0)
        XCTAssertEqual(g.remainingLifetime(at: .nan), 0); XCTAssertEqual(g.remainingLifetime(at: 121), 0)
        XCTAssertEqual(f.results.count, 1)
    }
    func testNewestOpenWaitsForOldCapabilityQuiescence() {
        let f = Fixture(), o = f.owner(); o.open(internalPort: 47830, lifetime: 3600) { f.results.append($0) }
        o.open(internalPort: 47831, lifetime: 3600) { f.results.append($0) }
        XCTAssertEqual(f.operations.count, 1); XCTAssertTrue(f.results.isEmpty); XCTAssertEqual(f.cancels, [1])
        f.select(0); XCTAssertEqual(f.operations.count, 2)
        guard case .capability? = f.operations.last else { return XCTFail("Old selection started a mapping") }
        XCTAssertEqual(f.results.count, 1); o.stop { f.results.append($0) }; f.reply(.capability(.cancelled))
    }
    func testOnlyNewestQueuedRequestSurvives() {
        let f = Fixture(), o = f.owner(); o.open(internalPort: 47830, lifetime: 3600) { f.results.append($0) }
        o.open(internalPort: 47831, lifetime: 3600) { f.results.append($0) }
        o.open(internalPort: 47832, lifetime: 3600) { f.results.append($0) }
        XCTAssertEqual(f.results.count, 1); f.reply(.capability(.cancelled), 0); f.select()
        guard case .udp(.create(_, let port, _))? = f.operations.last else { return XCTFail("Newest request did not create") }; XCTAssertEqual(port, 47832)
        o.stop { f.results.append($0) }; f.reply(.udp(.cancelled(mutationMayHaveOccurred: false)))
    }
    func testReplacementRemovesExactOldLeaseBeforeCapability() throws {
        let f = Fixture(), o = f.owner(), g = try f.open(o)
        o.open(internalPort: 47831, lifetime: 3600) { f.results.append($0) }
        guard case .udp(.remove(let lease))? = f.operations.last else { return XCTFail("Replacement skipped owned cleanup") }
        XCTAssertEqual(lease.externalPort, g.externalPort); XCTAssertEqual(f.operations.count, 3)
        f.reply(.udp(.removed(retired: false))); XCTAssertNil(o.current)
        guard case .capability? = f.operations.last else { return XCTFail("Replacement did not wait for cleanup") }
        o.stop { f.results.append($0) }; f.reply(.capability(.cancelled))
    }
    func testLateGrantIsCleanedBeforeNewestOpen() throws {
        let f = Fixture(), o = f.owner(); o.open(internalPort: 47830, lifetime: 3600) { f.results.append($0) }; f.select()
        o.open(internalPort: 47831, lifetime: 3600) { f.results.append($0) }; f.reply(.udp(.granted(try f.udpLease(), retired: true, epochChanged: false)))
        XCTAssertNil(o.current); XCTAssertTrue(f.results.isEmpty)
        guard case .udp(.remove)? = f.operations.last else { return XCTFail("Late grant lost") }
        f.reply(.udp(.removed(retired: false))); XCTAssertEqual(f.results.count, 1)
        guard case .capability? = f.operations.last else { return XCTFail("Next request preceded cleanup") }
        o.stop { f.results.append($0) }; f.reply(.capability(.cancelled))
    }
    func testFailedLateCleanupKeepsOpaqueEvidenceAndBlocksReplacement() throws {
        let f = Fixture(), o = f.owner(); o.open(internalPort: 47830, lifetime: 3600) { f.results.append($0) }; f.select()
        o.open(internalPort: 47831, lifetime: 3600) { f.results.append($0) }; let lease = try f.udpLease()
        f.reply(.udp(.granted(lease, retired: true, epochChanged: false))); f.reply(.udp(.retained(lease, retired: false)))
        XCTAssertTrue(o.hasUnresolvedState); XCTAssertNil(o.current); XCTAssertEqual(f.operations.count, 3); XCTAssertEqual(f.results.count, 2)
        o.open(internalPort: 47832, lifetime: 3600) { f.results.append($0) }; XCTAssertEqual(f.operations.count, 3)
    }
    func testRemoveRejectsOldHandleAndCannotDeleteReplacement() throws {
        let f = Fixture(), o = f.owner(), g = try f.open(o)
        o.remove(g.id) { f.results.append($0) }; f.reply(.udp(.removed(retired: false)))
        let second = try f.open(o); XCTAssertNotEqual(g.id, second.id); let n = f.operations.count
        o.remove(g.id) { f.results.append($0) }; XCTAssertEqual(f.operations.count, n); XCTAssertEqual(o.current?.id, second.id)
    }
    func testRenewKeepsHandlePreservesEpochAndDoesNotRestartLifetime() throws {
        let f = Fixture(), o = f.owner(), g = try f.open(o)
        o.renew(g.id, lifetime: 3600) { f.results.append($0) }
        guard case .udp(.renew(let lease, _))? = f.operations.last else { return XCTFail("Renewal skipped private lease") }
        f.now = 6; f.reply(.udp(.granted(lease, retired: false, epochChanged: true)))
        XCTAssertEqual(o.current?.id, g.id); XCTAssertEqual(o.current?.remainingLifetime(at: 6), 114)
        guard case .mapped(let updated, let receipt)? = f.results.last else { return XCTFail("Renewal lost receipt") }
        XCTAssertTrue(updated.epochChanged); XCTAssertEqual(receipt.receipt, .udp(.granted(lease, retired: false, epochChanged: true)))
    }
    func testBackoffHonorsCapabilityAndRenewalErrorLifetime() throws {
        let f = Fixture(), o = f.owner(); o.open(internalPort: 47830, lifetime: 3600) { f.results.append($0) }
        f.reply(.capability(.failure("Quota", retryAfter: 1810))); XCTAssertEqual(o.retryNotBefore, 1812)
        o.open(internalPort: 47830, lifetime: 3600) { f.results.append($0) }; XCTAssertEqual(f.operations.count, 1)
        f.now = 1812; o.open(internalPort: 47830, lifetime: 3600) { f.results.append($0) }; XCTAssertEqual(f.operations.count, 2)
        o.stop { f.results.append($0) }; f.reply(.capability(.cancelled))
        let f2 = Fixture(), o2 = f2.owner(), g = try f2.open(o2)
        o2.renew(g.id, lifetime: 3600) { f2.results.append($0) }; f2.reply(.udp(.failure("Quota", mutationMayHaveOccurred: false, retryAfter: 1800)))
        XCTAssertEqual(o2.retryNotBefore, 1802); XCTAssertEqual(o2.current?.id, g.id)
        o2.renew(g.id, lifetime: 3600) { f2.results.append($0) }; XCTAssertEqual(f2.operations.count, 3)
    }
    func testDisableAllowsExactStopCleanupButIsolationRefuses() throws {
        let f = Fixture(), o = f.owner(); _ = try f.open(o); f.enabled = false
        o.stop { f.results.append($0) }; XCTAssertEqual(f.operations.count, 3); f.reply(.udp(.removed(retired: false))); XCTAssertNil(o.current)
        let f2 = Fixture(), o2 = f2.owner(); _ = try f2.open(o2); f2.allowed = false
        o2.stop { f2.results.append($0) }; XCTAssertEqual(f2.operations.count, 2); XCTAssertTrue(o2.hasUnresolvedState)
    }
    func testWakeCleansOldLeaseAndRechecksCapability() throws {
        let f = Fixture(), o = f.owner(); _ = try f.open(o)
        o.wake { f.results.append($0) }; guard case .udp(.remove)? = f.operations.last else { return XCTFail("Wake skipped cleanup") }
        f.reply(.udp(.removed(retired: false))); guard case .capability? = f.operations.last else { return XCTFail("Wake reused old capability") }
        o.stop { f.results.append($0) }; f.reply(.capability(.cancelled))
    }
    func testStopDoesNotAutoRepeatFailedRemovalAndExpiryIsNotAbsence() throws {
        let f = Fixture(), o = f.owner(); _ = try f.open(o)
        o.stop { f.results.append($0) }; f.reply(.udp(.expired)); XCTAssertTrue(o.hasUnresolvedState); XCTAssertNil(o.current)
        let n = f.operations.count; o.stop { f.results.append($0) }; XCTAssertEqual(f.operations.count, n)
    }
    func testUpnpOwnedRenewalAndRemovalUseOriginalBook() throws {
        let f = Fixture(), o = f.owner(), lease = try f.upnpLease()
        o.open(internalPort: 47830, lifetime: 3600) { f.results.append($0) }; f.reply(.capability(.selected(.upnp(f.route, f.service))))
        guard case .upnpCreate? = f.operations.last else { return XCTFail("Wrong protocol") }; f.reply(.created(.granted(lease, retired: false)))
        let g = try XCTUnwrap(o.current); o.renew(g.id, lifetime: 3600) { f.results.append($0) }
        guard case .upnpMaintain(.lease(let actual), .renew)? = f.operations.last else { return XCTFail("Missing renewal") }; XCTAssertEqual(actual, lease)
        f.reply(.maintained(.renewed(lease, retired: false))); o.remove(g.id) { f.results.append($0) }; f.reply(.maintained(.absent)); XCTAssertNil(o.current)
    }
    func testUncertainUpnpCleanupFailurePreservesClaimWithoutBlindReopen() throws {
        let f = Fixture(), o = f.owner(), lease = try f.upnpLease()
        o.open(internalPort: 47830, lifetime: 3600) { f.results.append($0) }; f.reply(.capability(.selected(.upnp(f.route, f.service))))
        f.reply(.created(.uncertain(lease.claim, reason: "Lost"))); f.reply(.maintained(.changed(lease.claim, mutationAcknowledged: false)))
        XCTAssertTrue(o.hasUnresolvedState); XCTAssertNil(o.current); let n = f.operations.count
        o.wake { f.results.append($0) }; XCTAssertEqual(f.operations.count, n)
    }
    func testShutdownAndOwnerReleaseRetainLateCleanupReceipts() throws {
        for release in [false, true] {
            let f = Fixture(); var o: RouterMappingWorkflow? = f.owner(); o?.open(internalPort: 47830, lifetime: 3600) { f.results.append($0) }; f.select()
            if release { weak var weakOwner = o; o = nil; XCTAssertNil(weakOwner) } else { o?.shutdown { f.results.append($0) } }
            f.reply(.udp(.granted(try f.udpLease(), retired: true, epochChanged: false))); XCTAssertTrue(f.results.isEmpty)
            f.reply(.udp(.removed(retired: false))); XCTAssertEqual(f.results.count, release ? 1 : 2)
            o?.open(internalPort: 47830, lifetime: 3600) { f.results.append($0) }; XCTAssertEqual(f.operations.count, 3)
        }
    }
    func testDuplicateAndSynchronousReceiptsDoNotRepeatStages() {
        let f = Fixture(), o = f.owner(); f.onFactory = { i in f.reply(.capability(.unavailable), i) }
        o.open(internalPort: 47830, lifetime: 3600) { f.results.append($0) }; XCTAssertEqual(f.results.count, 1)
        f.reply(.capability(.selected(.pcp(f.route, epoch: 1))), 0); XCTAssertEqual(f.operations.count, 1); XCTAssertNil(o.current)
    }
    func testReentrantStopDuringFactoryNeverMapsOldSelection() {
        let f = Fixture(), o = f.owner(); f.onFactory = { i in if i == 0 { o.stop { f.results.append($0) }; f.select(i) } }
        o.open(internalPort: 47830, lifetime: 3600) { f.results.append($0) }
        XCTAssertEqual(f.operations.count, 1); XCTAssertEqual(f.results.count, 2); XCTAssertNil(o.current)
    }
    func testFailedStopDoesNotAutoRetryRemovalOrHideUncertainty() throws {
        let f = Fixture(), o = f.owner(); _ = try f.open(o)
        o.stop { f.results.append($0) }; f.reply(.udp(.failure("Deletion denied", mutationMayHaveOccurred: false, retryAfter: 30)))
        XCTAssertTrue(o.hasUnresolvedState); XCTAssertNil(o.current)
        let n = f.operations.count; o.stop { f.results.append($0) }; XCTAssertEqual(f.operations.count, n)
        o.open(internalPort: 47830, lifetime: 3600) { f.results.append($0) }; XCTAssertEqual(f.operations.count, n)
    }
    func testRetirementDuringActualRawFactoryBlocksNextProtocolStage() {
        let f = Fixture(); var packets = 0, o: RouterMappingWorkflow!
        let assembly = RouterProtocolOperations(clock: { f.now }, route: { f.route }, udp: { _, route, _, reply in
            packets += 1
            if packets == 1 { o.stop { f.results.append($0) } }
            reply(.response(.init(resultCode: 0, internalPort: 0, externalPort: 0, lifetime: 0, epoch: 100, externalAddress: nil), route))
            return .init(tick: {}, cancel: {})
        }, discovery: { _, _, _, reply in reply(.unavailable); return .init(tick: {}, cancel: {}) }, http: { _, _, _, _ in XCTFail("Unexpected HTTP"); return .init(tick: {}, cancel: {}) })
        o = RouterMappingWorkflow(allowed: { true }, enabled: { true }, clock: { f.now }, factory: assembly.make)
        o.open(internalPort: 47830, lifetime: 3600) { f.results.append($0) }
        XCTAssertEqual(packets, 1); XCTAssertEqual(f.results.count, 2); XCTAssertNil(o.current)
    }
    func testInvalidClockAndStaleRenewalRefuseBeforeConstruction() throws {
        let f = Fixture(), o = f.owner(); f.now = .nan
        o.open(internalPort: 47830, lifetime: 3600) { f.results.append($0) }; XCTAssertTrue(f.operations.isEmpty)
        f.now = 2; _ = try f.open(o); let n = f.operations.count
        o.renew(UUID(), lifetime: 3600) { f.results.append($0) }; XCTAssertEqual(f.operations.count, n)
    }
    func testMismatchedCapabilityReceiptKeepsLaneEvidenceBlocked() throws {
        let f = Fixture(), o = f.owner(); o.open(internalPort: 47830, lifetime: 3600) { f.results.append($0) }
        f.reply(.udp(.granted(try f.udpLease(), retired: false, epochChanged: false)))
        XCTAssertTrue(o.hasUnresolvedState); XCTAssertNil(o.current)
        o.open(internalPort: 47830, lifetime: 3600) { f.results.append($0) }; XCTAssertEqual(f.operations.count, 1)
    }
    func testAlreadyExpiredGrantCannotBePublishedAsMapped() throws {
        let f = Fixture(), o = f.owner(); o.open(internalPort: 47830, lifetime: 3600) { f.results.append($0) }; f.select()
        f.reply(.udp(.granted(try f.udpLease(1), retired: false, epochChanged: false)))
        XCTAssertNil(o.current); XCTAssertTrue(o.hasUnresolvedState)
        guard case .finished? = f.results.last else { return XCTFail("Expired receipt was published as mapped") }
    }
    func testActualProtocolAssemblyExecutesFiniteCapabilityMapAndRemove() {
        let f = Fixture(); var packets = 0
        let assembly = RouterProtocolOperations(clock: { f.now }, route: { f.route }, udp: { request, route, _, reply in
            packets += 1
            let lifetime: UInt32 = packets == 2 ? 3600 : 0
            if packets == 1 { reply(.response(.init(resultCode: 0, internalPort: 0, externalPort: 0, lifetime: 0, epoch: 100, externalAddress: nil), route)) }
            else { reply(.response(.init(resultCode: 0, internalPort: 47830, externalPort: packets == 2 ? 49321 : 0, lifetime: lifetime, epoch: 100, externalAddress: "203.0.113.7"), route)) }
            return .init(tick: {}, cancel: {})
        }, discovery: { _, _, _, _ in XCTFail("Unexpected discovery"); return .init(tick: {}, cancel: {}) }, http: { _, _, _, _ in XCTFail("Unexpected HTTP"); return .init(tick: {}, cancel: {}) }, nonce: { Data(repeating: 7, count: 12) })
        let o = RouterMappingWorkflow(allowed: { true }, enabled: { true }, clock: { f.now }, factory: assembly.make)
        o.open(internalPort: 47830, lifetime: 3600) { f.results.append($0) }; XCTAssertEqual(packets, 2)
        guard let g = o.current else { return XCTFail("Actual owners did not map") }
        o.remove(g.id) { f.results.append($0) }; XCTAssertEqual(packets, 3); XCTAssertNil(o.current); XCTAssertEqual(f.results.count, 2)
    }
}
