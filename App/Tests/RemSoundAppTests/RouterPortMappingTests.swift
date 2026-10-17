import Foundation
import XCTest
@testable import RemSoundApp

@MainActor
final class RouterPortMappingTests: XCTestCase {
    private struct Refused: LocalizedError { var errorDescription: String? { "Fixture router rejected mapping." } }
    private final class Lease: RouterMappingLease {
        var externalAddress: String? = "203.0.113.7"
        var externalPort: UInt16 = 47830
        var validFor: TimeInterval = 3600
        var renewals: [(Result<TimeInterval, Error>) -> Void] = []
        var cancels = 0, removals = 0
        func renew(_ completion: @escaping (Result<TimeInterval, Error>) -> Void) -> () -> Void {
            renewals.append(completion); return { self.cancels += 1 }
        }
        func remove(_ completion: @escaping (Result<Void, Error>) -> Void) { removals += 1; completion(.success(())) }
    }
    private final class Backend: RouterMappingBackend {
        func shutdown(_ completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
        struct Call { let port: UInt16; let duration: Int; let reply: (Result<RouterMappingLease?, Error>) -> Void }
        var calls: [Call] = []
        var cancels = 0
        var synchronousLease: Lease?
        var onCancel: (() -> Void)?
        func open(port: UInt16, leaseSeconds: Int, completion: @escaping (Result<RouterMappingLease?, Error>) -> Void) -> () -> Void {
            calls.append(.init(port: port, duration: leaseSeconds, reply: completion))
            if let synchronousLease { completion(.success(synchronousLease)) }
            return { self.cancels += 1; let action = self.onCancel; self.onCancel = nil; action?() }
        }
    }
    @MainActor private final class Fixture {
        var time: TimeInterval = 0, permitted = true
        var factories = 0
        let backend = Backend()
        func owner() -> RouterPortMapping {
            RouterPortMapping(permitted: { self.permitted }, clock: { self.time }, makeBackend: { self.factories += 1; return self.backend })
        }
    }
    private func opened(_ fixture: Fixture, _ proposed: Lease? = nil) -> (RouterPortMapping, Lease) {
        let lease = proposed ?? Lease()
        let owner = fixture.owner(); owner.setEnabled(true)
        XCTAssertEqual(fixture.backend.calls.count, 1)
        fixture.backend.calls.first?.reply(.success(lease))
        return (owner, lease)
    }
    func testOffAndIsolatedNeverConstructBackend() {
        let f = Fixture(), owner = f.owner(); defer { owner.shutdown() }
        owner.tick(); owner.refresh(); owner.setEnabled(false)
        XCTAssertEqual(f.factories, 0); XCTAssertEqual(owner.state.status, .disabled)
        f.permitted = false; owner.setEnabled(true); f.time = 10000; owner.tick(); owner.refresh()
        XCTAssertEqual(f.factories, 0); XCTAssertEqual(owner.state.status, .disabled)
    }
    func testExplicitEnableRequestsAudioPortHourLeaseAndCoalesces() {
        let f = Fixture(), owner = f.owner(); defer { owner.shutdown() }
        owner.setEnabled(true); owner.setEnabled(true); owner.tick()
        XCTAssertEqual(f.backend.calls.count, 1); XCTAssertEqual(f.backend.calls.first?.port, 47830)
        XCTAssertEqual(f.backend.calls.first?.duration, 3600); XCTAssertEqual(owner.state.status, .searching)
    }
    func testMappingReportsActualExternalEndpointAndOnlyChangedFacts() {
        let f = Fixture(), owner = f.owner(), lease = Lease(); lease.externalPort = 49321
        var states: [RouterMappingState] = []; owner.onChange = { states.append($0) }
        defer { owner.shutdown() }; owner.setEnabled(true); f.backend.calls.first?.reply(.success(lease))
        XCTAssertEqual(owner.state.status, .mapped); XCTAssertEqual(owner.state.externalAddress, "203.0.113.7")
        XCTAssertEqual(owner.state.externalPort, 49321); owner.tick(); owner.setEnabled(true)
        XCTAssertEqual(states.count, 2)
    }
    func testCgnatBoundariesDoNotTreatEveryPrivateOrIPv6AddressAsCgnat() {
        for address in ["100.64.0.0", "100.127.255.255"] { XCTAssertTrue(RouterPortMapping.isCgnatAddress(address)) }
        for address in ["100.63.255.255", "100.128.0.0", "101.64.0.0", "192.168.0.1", "::1", "100.64.0.999", "100.64", "100.064.0.1"] { XCTAssertFalse(RouterPortMapping.isCgnatAddress(address), address) }
        let f = Fixture(), lease = Lease(); lease.externalAddress = "100.100.0.1"
        let (owner, _) = opened(f, lease); defer { owner.shutdown() }; XCTAssertEqual(owner.state.status, .cgnatDetected)
    }
    func testNoRouterCompletesAndRetriesOnlyAtFifteenMinutes() {
        let f = Fixture(), owner = f.owner(); defer { owner.shutdown() }; owner.setEnabled(true)
        f.backend.calls.first?.reply(.success(nil)); XCTAssertEqual(owner.state.status, .noRouterFound)
        f.time = 899; owner.tick(); XCTAssertEqual(f.backend.calls.count, 1)
        f.time = 900; owner.tick(); XCTAssertEqual(f.backend.calls.count, 2); XCTAssertEqual(owner.state.status, .searching)
    }
    func testDiscoveryDeadlineCancelsOnceAndWaitsForQuiescenceBeforeRetry() {
        let f = Fixture(), owner = f.owner(); defer { owner.shutdown() }; owner.setEnabled(true)
        f.time = 7.999; owner.tick(); XCTAssertEqual(f.backend.cancels, 0)
        f.time = 8; owner.tick(); XCTAssertEqual(f.backend.cancels, 1); XCTAssertEqual(owner.state.status, .noRouterFound)
        f.time = 1000; owner.tick(); owner.tick(); XCTAssertEqual(f.backend.cancels, 1); XCTAssertEqual(f.backend.calls.count, 1)
        f.backend.calls.first?.reply(.success(nil)); owner.tick(); XCTAssertEqual(f.backend.calls.count, 2)
    }
    func testRefusalNeverClaimsAnEndpoint() {
        let f = Fixture(), owner = f.owner(); defer { owner.shutdown() }; owner.setEnabled(true)
        f.backend.calls.first?.reply(.failure(Refused()))
        XCTAssertEqual(owner.state.status, .mappingFailed); XCTAssertNil(owner.state.externalAddress); XCTAssertNil(owner.state.externalPort)
        XCTAssertEqual(owner.state.lastError, "Fixture router rejected mapping.")
    }
    func testRenewsBeforeHourLeaseExpiresAndCoalescesTicks() {
        let f = Fixture(), (owner, lease) = opened(f); defer { owner.shutdown() }
        f.time = 899; owner.tick(); XCTAssertEqual(lease.renewals.count, 0)
        f.time = 900; owner.tick(); owner.tick(); XCTAssertEqual(lease.renewals.count, 1)
        lease.renewals.first?(.success(3600)); f.time = 1799; owner.tick(); XCTAssertEqual(lease.renewals.count, 1)
        f.time = 1800; owner.tick(); XCTAssertEqual(lease.renewals.count, 2)
    }
    func testRefusedRenewalRetiresOldLeaseAndWaitsDefaultRetry() {
        let f = Fixture(), (owner, lease) = opened(f); defer { owner.shutdown() }
        var states: [RouterMappingStatus] = []; owner.onChange = { states.append($0.status) }
        f.time = 900; owner.tick(); lease.renewals.first?(.failure(Refused()))
        XCTAssertEqual(lease.removals, 1); XCTAssertEqual(f.backend.calls.count, 1)
        XCTAssertTrue(states.contains(.mappingFailed)); XCTAssertEqual(owner.state.status, .mappingFailed); XCTAssertNil(owner.state.externalAddress)
        f.time = 1800; owner.tick(); XCTAssertEqual(f.backend.calls.count, 2)
    }
    func testLateInitialSuccessAfterDisableIsRemoved() {
        let f = Fixture(), owner = f.owner(), lease = Lease(); defer { owner.shutdown() }
        owner.setEnabled(true); owner.setEnabled(false); f.backend.calls.first?.reply(.success(lease))
        XCTAssertEqual(lease.removals, 1); XCTAssertEqual(owner.state.status, .disabled)
        f.time = 2000; owner.tick(); XCTAssertEqual(f.backend.calls.count, 1)
    }
    func testDisableDuringRenewalRemovesLateSuccessAgain() {
        let f = Fixture(), (owner, lease) = opened(f); defer { owner.shutdown() }
        f.time = 900; owner.tick(); owner.setEnabled(false)
        XCTAssertEqual(lease.removals, 1); XCTAssertEqual(lease.cancels, 1)
        lease.renewals.first?(.success(3600)); XCTAssertEqual(lease.removals, 2)
        lease.renewals.first?(.success(3600)); XCTAssertEqual(lease.removals, 2)
        XCTAssertEqual(owner.state.status, .disabled); XCTAssertEqual(f.backend.calls.count, 1)
    }
    func testDisableDuringFailedRenewalCannotRestart() {
        let f = Fixture(), (owner, lease) = opened(f); defer { owner.shutdown() }
        f.time = 900; owner.tick(); owner.setEnabled(false); lease.renewals.first?(.failure(Refused()))
        XCTAssertEqual(owner.state.status, .disabled); XCTAssertEqual(f.backend.calls.count, 1); XCTAssertEqual(lease.removals, 1)
    }
    func testWakeRefreshWaitsForRetiredRenewalBeforeReopening() {
        let f = Fixture(), (owner, lease) = opened(f); defer { owner.shutdown() }
        f.time = 900; owner.tick(); owner.refresh(); owner.refresh()
        XCTAssertEqual(f.backend.calls.count, 1); XCTAssertEqual(lease.removals, 1)
        lease.renewals.first?(.success(3600)); XCTAssertEqual(lease.removals, 2); XCTAssertEqual(f.backend.calls.count, 2)
        let newLease = Lease(); f.backend.calls.last?.reply(.success(newLease)); XCTAssertEqual(owner.state.status, .mapped)
        lease.renewals.first?(.success(3600)); XCTAssertEqual(newLease.removals, 0)
    }
    func testChangedPortWaitsForOldInitialMappingCleanup() {
        let f = Fixture(), owner = f.owner(), old = Lease(); defer { owner.shutdown() }
        owner.setEnabled(true); owner.setEnabled(true, port: 49222); XCTAssertEqual(f.backend.calls.count, 1)
        f.backend.calls.first?.reply(.success(old)); XCTAssertEqual(old.removals, 1)
        XCTAssertEqual(f.backend.calls.count, 2); XCTAssertEqual(f.backend.calls.last?.port, 49222)
    }
    func testShortGrantRenewalAndExpiryNeverKeepFalseMappedStatus() {
        let f = Fixture(), lease = Lease(); lease.validFor = 4
        let (owner, _) = opened(f, lease); defer { owner.shutdown() }
        f.time = 2; owner.tick(); XCTAssertEqual(lease.renewals.count, 1)
        f.time = 4; owner.tick(); XCTAssertEqual(owner.state.status, .mappingFailed); XCTAssertNil(owner.state.externalPort)
        XCTAssertEqual(lease.removals, 1); lease.renewals.first?(.success(4)); XCTAssertEqual(lease.removals, 2)
    }
    func testShutdownAndReleaseCleanLateLeaseAndRejectRestart() {
        let f = Fixture(), late = Lease(); var owner: RouterPortMapping? = f.owner()
        owner?.setEnabled(true); owner?.shutdown(); owner?.shutdown(); owner?.setEnabled(true); owner = nil
        f.backend.calls.first?.reply(.success(late)); XCTAssertEqual(late.removals, 1)
        XCTAssertEqual(f.backend.calls.count, 1); XCTAssertEqual(f.backend.cancels, 1)
    }
    func testSynchronousBackendAndDuplicateReplyPreserveCurrentLease() {
        let f = Fixture(), lease = Lease(); f.backend.synchronousLease = lease
        let owner = f.owner(); owner.setEnabled(true); defer { owner.shutdown() }
        XCTAssertEqual(owner.state.status, .mapped); XCTAssertEqual(f.backend.cancels, 1)
        f.backend.calls.first?.reply(.success(lease)); XCTAssertEqual(lease.removals, 0)
        owner.setEnabled(false); XCTAssertEqual(lease.removals, 1)
    }
    func testPermissionRetirementAndInvalidPortNeverConstructAnotherBackend() {
        let f = Fixture(), (owner, lease) = opened(f); defer { owner.shutdown() }
        f.permitted = false; owner.tick(); XCTAssertEqual(lease.removals, 1); XCTAssertEqual(owner.state.status, .disabled)
        owner.setEnabled(true, port: 0); owner.tick(); XCTAssertEqual(f.factories, 1)
    }
    func testSynchronousCancellationDuringPortSwitchPreservesNewLease() {
        let f = Fixture(), owner = f.owner(), old = Lease(), current = Lease(); current.externalPort = 49222
        defer { owner.shutdown() }; owner.setEnabled(true)
        f.backend.synchronousLease = current
        f.backend.onCancel = { f.backend.calls.first?.reply(.success(old)) }
        owner.setEnabled(true, port: 49222)
        XCTAssertEqual(old.removals, 1); XCTAssertEqual(current.removals, 0)
        XCTAssertEqual(f.backend.calls.count, 2); XCTAssertEqual(owner.state.status, .mapped)
        XCTAssertEqual(owner.state.externalPort, 49222)
    }
    func testReentrantDisableOnSearchingRefusesBeforeFactoryAndCanReenable() {
        let f = Fixture(), owner = f.owner(); defer { owner.shutdown() }
        owner.onChange = { state in if state.status == .searching { owner.setEnabled(false) } }
        owner.setEnabled(true); XCTAssertEqual(f.factories, 0); XCTAssertEqual(owner.state.status, .disabled)
        owner.onChange = nil; owner.setEnabled(true); XCTAssertEqual(f.factories, 1)
    }
    func testBadGrantedLifetimeRetiresLeaseWithoutClaimingSuccess() {
        for duration in [0.0, -1, Double.infinity, Double.nan] {
            let f = Fixture(), lease = Lease(); lease.validFor = duration
            let (owner, _) = opened(f, lease)
            XCTAssertEqual(owner.state.status, .mappingFailed); XCTAssertEqual(lease.removals, 1); XCTAssertNil(owner.state.externalPort)
            owner.shutdown()
        }
    }
    func testReleaseWithoutExplicitShutdownStillCleansLateInitialMapping() {
        let f = Fixture(), late = Lease(); var owner: RouterPortMapping? = f.owner()
        weak var released = owner
        owner?.setEnabled(true); owner = nil
        XCTAssertNil(released); XCTAssertEqual(f.backend.cancels, 1)
        f.backend.calls.first?.reply(.success(late)); XCTAssertEqual(late.removals, 1)
    }
}
