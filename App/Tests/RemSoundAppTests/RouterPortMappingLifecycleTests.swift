import Foundation
import XCTest
import RemSoundRuntime
@testable import RemSoundCore
@testable import RemSoundApp

@MainActor
final class RouterPortMappingLifecycleTests: XCTestCase {
    private struct Refused: LocalizedError { var errorDescription: String? { "Fixture removal failed." } }
    @MainActor private final class Lease: RouterMappingLease {
        var externalAddress: String? = "203.0.113.7", externalPort: UInt16 = 49321
        var validFor: TimeInterval = 3600, expiresAtUptime: TimeInterval?
        var removals: [(Result<Void, Error>) -> Void] = [], renewals: [(Result<TimeInterval, Error>) -> Void] = []
        var cancels = 0
        func renew(_ completion: @escaping (Result<TimeInterval, Error>) -> Void) -> () -> Void {
            renewals.append(completion); return { self.cancels += 1 }
        }
        func remove(_ completion: @escaping (Result<Void, Error>) -> Void) { removals.append(completion) }
    }
    @MainActor private final class Backend: RouterMappingBackend {
        var ports: [UInt16] = [], replies: [(Result<RouterMappingLease?, Error>) -> Void] = []
        var shutdowns = 0, cancels = 0
        func open(port: UInt16, leaseSeconds: Int, completion: @escaping (Result<RouterMappingLease?, Error>) -> Void) -> () -> Void {
            XCTAssertEqual(leaseSeconds, 3600); ports.append(port); replies.append(completion); return { self.cancels += 1 }
        }
        func shutdown(_ completion: @escaping (Result<Void, Error>) -> Void) { shutdowns += 1; completion(.success(())) }
    }
    @MainActor private final class Fixture {
        var now: TimeInterval = 0, permitted = true, factories = 0
        let backend = Backend()
        func owner() -> RouterPortMapping { .init(permitted: { self.permitted }, clock: { self.now }, makeBackend: { self.factories += 1; return self.backend }) }
        func opened() -> (RouterPortMapping, Lease) {
            let o = owner(), lease = Lease(); o.setEnabled(true); backend.replies.first?(.success(lease)); return (o, lease)
        }
        func error(retry: TimeInterval? = nil, unresolved: Bool = false, closed: Bool = false) -> Error {
            let r = RouterMappingService.Receipt(requestID: UUID(), outcome: .failed("Fixture protocol failure"), snapshot: .init(enabled: true,
                closed: closed, mapping: nil, observedAtUptime: now, retryNotBeforeUptime: retry, hasUnresolvedState: unresolved, unresolved: []))
            return RouterMappingServiceError("Fixture protocol failure", receipt: r)
        }
    }
    func testPortSwitchWaitsRemovalReceipt() {
        let f = Fixture(), (o, lease) = f.opened(); defer { o.shutdown() }
        o.setEnabled(true, port: 49222); o.tick(); o.refresh()
        XCTAssertEqual(lease.removals.count, 1); XCTAssertEqual(f.backend.ports, [47830])
        lease.removals.first?(.success(())); XCTAssertEqual(f.backend.ports, [47830, 49222]); XCTAssertEqual(f.factories, 1)
    }
    func testLateInitialGrantDeletionPrecedesReplacement() {
        let f = Fixture(), o = f.owner(), lease = Lease(); defer { o.shutdown() }
        o.setEnabled(true); o.setEnabled(true, port: 49222); f.backend.replies.first?(.success(lease))
        XCTAssertEqual(f.backend.ports.count, 1); XCTAssertEqual(lease.removals.count, 1)
        lease.removals.first?(.success(())); XCTAssertEqual(f.backend.ports, [47830, 49222])
    }
    func testLateRenewalDeletionIsSerializedAfterInitialDeletion() {
        let f = Fixture(), (o, lease) = f.opened(); defer { o.shutdown() }
        f.now = 900; o.tick(); o.refresh(); lease.renewals.first?(.success(3600))
        XCTAssertEqual(lease.removals.count, 1); XCTAssertEqual(f.backend.ports.count, 1)
        lease.removals[0](.success(())); XCTAssertEqual(lease.removals.count, 2); XCTAssertEqual(f.backend.ports.count, 1)
        lease.removals[1](.success(())); XCTAssertEqual(f.backend.ports.count, 2)
    }
    func testFailedRemovalBlocksWakeToggleAndAutomaticReplacement() {
        let f = Fixture(), (o, lease) = f.opened(); defer { o.shutdown() }
        o.refresh(); lease.removals.first?(.failure(Refused())); f.now = 50000
        o.tick(); o.refresh(); o.setEnabled(false); o.setEnabled(true)
        XCTAssertEqual(f.backend.ports.count, 1); XCTAssertEqual(o.state.status, .mappingFailed); XCTAssertNil(o.state.externalPort)
        XCTAssertEqual(lease.removals.count, 1)
    }
    func testPCPRetryDeadlineSurvivesRemovalDelayAndTicks() {
        let f = Fixture(), (o, lease) = f.opened(); defer { o.shutdown() }
        f.now = 900; o.tick(); lease.renewals.first?(.failure(f.error(retry: 1810)))
        XCTAssertEqual(f.backend.ports.count, 1); XCTAssertEqual(lease.removals.count, 1)
        f.now = 1000; lease.removals.first?(.success(())); o.tick(); o.refresh()
        XCTAssertEqual(f.backend.ports.count, 1); f.now = 1809; o.tick(); XCTAssertEqual(f.backend.ports.count, 1)
        f.now = 1810; o.tick(); XCTAssertEqual(f.backend.ports.count, 2); XCTAssertEqual(f.factories, 1)
    }
    func testShortProtocolBackoffIsNotReplacedWithFifteenMinutes() {
        let f = Fixture(), o = f.owner(); defer { o.shutdown() }; o.setEnabled(true)
        f.backend.replies.first?(.failure(f.error(retry: 30))); f.now = 29; o.tick(); XCTAssertEqual(f.backend.ports.count, 1)
        f.now = 30; o.tick(); XCTAssertEqual(f.backend.ports.count, 2); XCTAssertEqual(f.factories, 1)
    }
    func testUnresolvedAndClosedServiceFailuresNeverRetryOrRecreate() {
        for closed in [false, true] {
            let f = Fixture(), o = f.owner(); defer { o.shutdown() }; o.setEnabled(true)
            f.backend.replies.first?(.failure(f.error(unresolved: !closed, closed: closed)))
            f.now = 50000; o.tick(); o.refresh(); o.setEnabled(false); o.setEnabled(true)
            XCTAssertEqual(f.backend.ports.count, 1); XCTAssertEqual(f.factories, 1); XCTAssertEqual(o.state.status, .mappingFailed)
        }
    }
    func testInitialBackwardAndNonfiniteClocksRefuseBeforeFactory() {
        for now in [-1.0, Double.nan, Double.infinity] {
            let f = Fixture(); f.now = now; let o = f.owner(); defer { o.shutdown() }; o.setEnabled(true)
            XCTAssertEqual(f.factories, 0); XCTAssertEqual(o.state.status, .mappingFailed)
        }
    }
    func testBackwardClockDuringLeaseRetiresAndCannotResetOnWake() {
        let f = Fixture(), (o, lease) = f.opened(); defer { o.shutdown() }; f.now = 10; o.tick(); f.now = 9; o.tick()
        XCTAssertEqual(lease.removals.count, 1); XCTAssertEqual(o.state.status, .mappingFailed)
        lease.removals.first?(.success(())); f.now = 10000; o.refresh(); o.tick(); XCTAssertEqual(f.backend.ports.count, 1)
    }
    func testAbsoluteExpiryCannotRestartFromDelayedDelivery() {
        let f = Fixture(), o = f.owner(), lease = Lease(); lease.expiresAtUptime = 120; defer { o.shutdown() }
        o.setEnabled(true); f.now = 100; f.backend.replies.first?(.success(lease))
        f.now = 110; o.tick(); XCTAssertEqual(lease.renewals.count, 1)
        f.now = 120; o.tick(); XCTAssertEqual(o.state.status, .mappingFailed); XCTAssertEqual(lease.removals.count, 1)
    }
    func testInvalidAbsoluteGrantCannotPublishMappedState() {
        for expiry in [0.0, Double.nan, Double.infinity] {
            let f = Fixture(), o = f.owner(), lease = Lease(); lease.expiresAtUptime = expiry; defer { o.shutdown() }
            o.setEnabled(true); f.backend.replies.first?(.success(lease)); XCTAssertEqual(o.state.status, .mappingFailed)
            XCTAssertEqual(lease.removals.count, 1); XCTAssertNil(o.state.externalPort)
        }
    }
    func testDuplicateRemovalReceiptCannotReopenTwice() {
        let f = Fixture(), (o, lease) = f.opened(); defer { o.shutdown() }; o.refresh()
        lease.removals.first?(.success(())); lease.removals.first?(.success(())); XCTAssertEqual(f.backend.ports.count, 2)
        XCTAssertEqual(f.factories, 1)
    }
    func testShutdownUsesExistingBackendOnceAndNeverConstructsWhenOff() {
        let f = Fixture(), o = f.owner(); o.shutdown(); XCTAssertEqual(f.factories, 0); XCTAssertEqual(f.backend.shutdowns, 0)
        let g = Fixture(), p = g.owner(); p.setEnabled(true); p.shutdown(); p.shutdown(); XCTAssertEqual(g.backend.shutdowns, 1)
    }
    func testReleaseKeepsQueuedLateRenewalDeletionAlive() {
        let f = Fixture(); var o: RouterPortMapping?; let lease: Lease
        (o, lease) = f.opened(); f.now = 900; o?.tick(); o?.refresh(); lease.renewals.first?(.success(3600)); o = nil
        XCTAssertEqual(lease.removals.count, 1); lease.removals.first?(.success(()))
        XCTAssertEqual(lease.removals.count, 2); lease.removals.last?(.success(())); XCTAssertEqual(f.backend.shutdowns, 1)
    }
    func testRenewalGenericFailureWaitsDeletionThenDefaultRetry() {
        let f = Fixture(), (o, lease) = f.opened(); defer { o.shutdown() }; f.now = 900; o.tick()
        lease.renewals.first?(.failure(Refused())); XCTAssertEqual(f.backend.ports.count, 1)
        lease.removals.first?(.success(())); f.now = 1799; o.tick(); XCTAssertEqual(f.backend.ports.count, 1)
        f.now = 1800; o.tick(); XCTAssertEqual(f.backend.ports.count, 2)
    }
    func testDisableWhileCleanupPendingCannotReopenOnReceipt() {
        let f = Fixture(), (o, lease) = f.opened(); defer { o.shutdown() }; o.refresh(); o.setEnabled(false)
        lease.removals.first?(.success(())); f.now = 10000; o.tick(); XCTAssertEqual(f.backend.ports.count, 1)
        XCTAssertEqual(o.state.status, .disabled)
    }

    private final class Clock {
        private let lock = NSLock(); private var time: TimeInterval = 10
        var now: TimeInterval { get { lock.lock(); defer { lock.unlock() }; return time } set { lock.lock(); time = newValue; lock.unlock() } }
    }
    func testActualOwnerAdapterCoreCancelledRenewalCanRefreshAfterConfirmedCleanup() async throws {
        let clock = Clock(), queue = DispatchQueue(label: "router.owner.core.fixture")
        let route = RouterGatewayRoute(gateway: Endpoint("192.0.2.1", 5351), sourceAddress: "192.0.2.10", interface: "fixture")
        var raw: RouterUDPMapping.Outcome?
        let creator = RouterUDPMapping(intent: .create(.natPmp(route, externalAddress: "203.0.113.7", epoch: 100), internalPort: 47830, lifetime: 3600), permitted: { true }, clock: { 0 }, exchange: { _, route, reply in
            reply(.response(.init(resultCode: 0, internalPort: 47830, externalPort: 49321, lifetime: 3600, epoch: 100, externalAddress: nil), route)); return {}
        }, completion: { raw = $0 }); creator.start()
        guard case let .granted(lease, _, _)? = raw else { return XCTFail("Missing isolated lease") }
        var commands: [String] = [], waitingRenewal: ((RouterMappingTransactions.Receipt) -> Void)?
        let service = RouterMappingService(queue: queue, callbackQueue: .main, allowed: { true }, clock: { clock.now }, factory: { operation, gate, reply in
            XCTAssertTrue(gate())
            switch operation {
            case .capability: commands.append("capability"); reply(.capability(.selected(.natPmp(route, externalAddress: "203.0.113.7", epoch: 100))))
            case .udp(.create): commands.append("create"); reply(.udp(.granted(lease, retired: false, epochChanged: false)))
            case .udp(.renew): commands.append("renew"); waitingRenewal = reply
            case .udp(.remove): commands.append("remove"); reply(.udp(.removed(retired: false)))
            default: XCTFail("Unexpected protocol command"); reply(.refused)
            }
            return .init(tick: {}, cancel: {
                if case .udp(.renew) = operation { let reply = waitingRenewal; waitingRenewal = nil; reply?(.udp(.cancelled(mutationMayHaveOccurred: false))) }
            })
        })
        let adapter = RouterMappingServiceBackend(service: service, clock: { clock.now })
        var factories = 0; let o = RouterPortMapping(permitted: { true }, clock: { clock.now }, makeBackend: { factories += 1; return adapter })
        let first = expectation(description: "initial owner mapping")
        o.onChange = { if $0.status == .mapped { first.fulfill() } }; o.setEnabled(true)
        await fulfillment(of: [first], timeout: 3); clock.now = 910; o.tick(); queue.sync {}
        XCTAssertEqual(queue.sync { commands.last }, "renew")
        let refreshed = expectation(description: "owner refreshed after actual cancelled renewal cleanup")
        o.onChange = { if $0.status == .mapped { refreshed.fulfill() } }; o.refresh()
        await fulfillment(of: [refreshed], timeout: 3)
        XCTAssertEqual(o.state.status, .mapped); XCTAssertEqual(factories, 1)
        XCTAssertEqual(queue.sync { commands }, ["capability", "create", "renew", "remove", "capability", "create"])
        let closed = expectation(description: "actual owner teardown")
        o.shutdown(); adapter.shutdown { _ in closed.fulfill() }; await fulfillment(of: [closed], timeout: 3)
    }
    func testActualIsolatedFacadeOwnerRefusesWithoutNativeProbeAndStops() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]!).appendingPathComponent("router-owner-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try RuntimeConfiguration(options: LaunchOptions.parse(["--config-dir", root.path, "--silent", "--headless"]))
        let adapter = RouterMappingServiceBackend(service: .init(configuration: runtime))
        let o = RouterPortMapping(permitted: { true }, makeBackend: { adapter }), refused = expectation(description: "actual isolated owner")
        o.onChange = { if $0.status == .mappingFailed { refused.fulfill() } }; o.setEnabled(true)
        await fulfillment(of: [refused], timeout: 3); XCTAssertNil(o.state.externalPort)
        let closed = expectation(description: "isolated owner closed")
        o.onChange = nil; o.shutdown(); adapter.shutdown { _ in closed.fulfill() }; await fulfillment(of: [closed], timeout: 3)
    }
    func testInvalidClockDuringRenewalCannotPublishSuccessOrConcurrentDeletion() {
        let f = Fixture(), (o, lease) = f.opened(); defer { o.shutdown() }; f.now = 900; o.tick(); f.now = .nan
        lease.renewals.first?(.success(3600)); XCTAssertEqual(o.state.status, .mappingFailed); XCTAssertNil(o.state.externalPort)
        XCTAssertEqual(lease.removals.count, 1); lease.removals.first?(.success(())); f.now = 10000; o.tick()
        XCTAssertEqual(f.backend.ports.count, 1)
    }
}
