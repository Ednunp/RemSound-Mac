import Foundation
import RemSoundRuntime
import XCTest
@testable import RemSoundCore

final class RouterNativeOperationsTests: XCTestCase {
    private final class Transport: RouterUDPTransport {
        var localAddress: String? = "192.0.2.10", incoming: [(Data, Endpoint)] = []
        var closes = 0, sends = 0
        var onSend: ((Data, Endpoint) -> Void)?
        func send(_ data: Data, to: Endpoint) -> Bool { sends += 1; onSend?(data, to); return true }
        func receive() -> (Data, Endpoint)? { incoming.isEmpty ? nil : incoming.removeFirst() }
        func close() { closes += 1 }
    }
    private final class Fixture {
        let queue = DispatchQueue(label: "router.native.fixture"), key = DispatchSpecificKey<Int>()
        var now: TimeInterval = 0, allowed = true, permitted = true, routeCalls = 0
        let route = RouterGatewayRoute(gateway: Endpoint("192.0.2.1", 5351), sourceAddress: "192.0.2.10", interface: "fixture")
        var service: UPnPRouterService { .init(kind: .ip2, controlURL: URL(string: "http://192.0.2.1/control")!, gatewayAddress: "192.0.2.1") }
        var sockets: [Transport] = [], discoverySockets: [Transport] = []
        var pulses: [() -> Void] = [], timerStops: [Int] = [], httpCancels: [Int] = []
        var httpReplies: [(RouterHTTPTransport.Outcome) -> Void] = [], httpBudgets: [TimeInterval] = []
        var results: [RouterMappingTransactions.Receipt] = [], wrongQueue = 0
        var autoUDP = true, syncHTTP: [RouterHTTPTransport.Outcome] = [], onSchedule: (() -> Void)?, onUDPFactory: (() -> Void)?, onRoute: (() -> Void)?, onHTTPFactory: (() -> Void)?
        var routeOverride: RouterGatewayRoute?
        init() { queue.setSpecific(key: key, value: 1) }
        func checkQueue() { if DispatchQueue.getSpecific(key: key) != 1 { wrongQueue += 1 } }
        func owner() -> RouterNativeOperations {
            .init(queue: queue, allowed: { self.allowed }, clock: { self.checkQueue(); return self.now }, route: { self.checkQueue(); self.routeCalls += 1; self.onRoute?(); return self.routeOverride ?? self.route }, udpTransport: { _ in
                self.checkQueue(); let t = Transport(); self.sockets.append(t); self.onUDPFactory?()
                t.onSend = { data, endpoint in
                    guard self.autoUDP else { return }
                    let reply: Data
                    if data.first == 2 { reply = Data([0,128,0,1,0,0,0,7]) }
                    else if data.count == 2 { reply = Data([0,128,0,0,0,0,0,7,203,0,113,7]) }
                    else {
                        var b = Data([0,129,0,0,0,0,0,7]); b.append(data[4..<6]); b.append(data[6..<8]); b.append(data[8..<12]); reply = b
                    }
                    t.incoming.append((reply, endpoint))
                }; return t
            }, discoveryTransport: { _, _ in self.checkQueue(); let t = Transport(); self.discoverySockets.append(t); return t }, http: { _, budget, gate, reply in
                self.checkQueue(); XCTAssertTrue(gate()); let i = self.httpReplies.count
                self.httpReplies.append(reply); self.httpBudgets.append(budget); self.httpCancels.append(0)
                self.onHTTPFactory?()
                if !self.syncHTTP.isEmpty { reply(self.syncHTTP.removeFirst()) }
                return { self.checkQueue(); self.httpCancels[i] += 1 }
            }, schedule: { _, interval, pulse in
                self.checkQueue(); XCTAssertEqual(interval, 0.02); let i = self.pulses.count
                self.pulses.append(pulse); self.timerStops.append(0); self.onSchedule?()
                return { self.checkQueue(); self.timerStops[i] += 1 }
            }, nonce: { Data(repeating: 7, count: 12) }, token: { "RemSound-fixture-0123456789" })
        }
        func make(_ owner: RouterNativeOperations, _ operation: RouterMappingTransactions.Operation = .capability) -> RouterMappingTransactions.Control {
            queue.sync { owner.make(operation, { self.permitted }) { self.checkQueue(); self.results.append($0) } }
        }
        func fire(_ i: Int = 0) { queue.sync { if pulses.indices.contains(i) { pulses[i]() } else { XCTFail("Missing driver") } } }
        func flush() { for _ in 0..<8 { queue.sync {} } }
        func http(_ value: RouterHTTPTransport.Outcome, _ i: Int? = nil) {
            queue.sync { let i = i ?? httpReplies.count - 1; guard httpReplies.indices.contains(i) else { return XCTFail("Missing HTTP stage") }; httpReplies[i](value) }; flush()
        }
        var create: RouterMappingTransactions.Operation { .upnpCreate(route, service, internalPort: 47830, lifetime: 3600) }
        var udpCreate: RouterMappingTransactions.Operation { .udp(.create(.natPmp(route, externalAddress: "203.0.113.7", epoch: 7), internalPort: 47830, lifetime: 3600)) }
    }
    func testOffAndIsolationRefuseBeforeEveryFactoryAndDriver() {
        for isolated in [false, true] {
            let f = Fixture(); if isolated { f.allowed = false } else { f.permitted = false }; let o = f.owner(), c = f.make(o)
            c.cancel(); f.flush(); XCTAssertEqual(f.results, [.refused]); XCTAssertEqual(f.routeCalls, 0); XCTAssertTrue(f.sockets.isEmpty); XCTAssertTrue(f.httpReplies.isEmpty); XCTAssertTrue(f.pulses.isEmpty)
        }
    }
    func testNativeConvenienceDefaultIsolationRefusesWithoutProbe() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]!).appendingPathComponent("router-driver-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try RuntimeConfiguration(options: LaunchOptions.parse(["--config-dir", root.path, "--headless", "--silent"]))
        let queue = DispatchQueue(label: "router.native.refusal"); let o = RouterNativeOperations(runtime: runtime, queue: queue); var replies: [RouterMappingTransactions.Receipt] = []
        let c = queue.sync { o.make(.capability, { true }) { replies.append($0) } }; queue.sync { c.cancel() }
        XCTAssertEqual(replies, [.refused])
    }
    func testActualUDPOwnersUseSelectedRouteAndFiniteDriverThenClose() {
        let f = Fixture(), o = f.owner(), c = f.make(o)
        for _ in 0..<4 { f.fire() }
        XCTAssertEqual(f.sockets.count, 2); XCTAssertEqual(f.sockets.map(\.closes), [1,1]); XCTAssertEqual(f.results.count, 1); XCTAssertEqual(f.timerStops, [1]); XCTAssertEqual(f.wrongQueue, 0)
        guard case .capability(.selected(.natPmp(let route, _, _)))? = f.results.first else { return XCTFail("Actual capability owners did not select NAT") }; XCTAssertEqual(route, f.route)
        c.tick(); c.cancel(); f.flush(); XCTAssertEqual(f.results.count, 1)
    }
    func testActualUDPGrantReturnsConservativeReceiptAndNoIdleDriver() {
        let f = Fixture(), o = f.owner(), c = f.make(o, f.udpCreate); f.fire()
        guard case .udp(.granted(let lease, _, _))? = f.results.first else { return XCTFail("Actual UDP grant missing") }
        XCTAssertEqual(lease.validUntil, 3600); XCTAssertEqual(lease.internalPort, 47830); XCTAssertEqual(f.timerStops, [1]); XCTAssertEqual(f.sockets.first?.closes, 1)
        c.cancel(); f.flush()
    }
    func testHTTPForeignCallbacksAreMarshalledToOwnerQueue() {
        let f = Fixture(), o = f.owner(), c = f.make(o, f.create)
        let reply = f.queue.sync { f.httpReplies.first }
        guard let reply else { return XCTFail("No HTTP request") }
        let delivered = expectation(description: "foreign callback")
        DispatchQueue.global().async { reply(.soap(.fault(code: 714, description: "Absent"))); delivered.fulfill() }
        wait(for: [delivered], timeout: 3); f.flush()
        XCTAssertEqual(f.httpReplies.count, 2); XCTAssertEqual(f.wrongQueue, 0)
        c.cancel(); f.flush(); f.http(.failure("Cancelled", mutationMayHaveOccurred: false)); XCTAssertEqual(f.results.count, 1)
    }
    func testSynchronousHTTPReceiptsWaitForReturnedCancellationResource() {
        let f = Fixture(); f.syncHTTP = [.soap(.fault(code: 714, description: "Absent")), .soap(.success(externalAddress: "203.0.113.7")), .soap(.success(externalAddress: nil)), .soap(.mapping(.init(internalPort: 47830, internalClient: "192.0.2.10", enabled: true, description: "RemSound-fixture-0123456789", leaseSeconds: 120)))]
        let o = f.owner(), c = f.make(o, f.create); f.flush()
        XCTAssertEqual(f.httpReplies.count, 4); XCTAssertEqual(f.httpCancels, [1,1,1,1]); XCTAssertEqual(f.results.count, 1); XCTAssertEqual(f.timerStops, [1]); XCTAssertEqual(f.wrongQueue, 0)
        c.cancel(); f.flush()
    }
    func testDeadlineStopsDriverWhileWaitingForHTTPQuiescence() {
        let f = Fixture(), o = f.owner(), c = f.make(o, f.create)
        f.queue.sync { f.now = 8 }; f.fire(); XCTAssertEqual(f.timerStops, [1]); XCTAssertEqual(f.httpCancels, [1]); XCTAssertTrue(f.results.isEmpty)
        f.fire(); f.http(.failure("Deadline", mutationMayHaveOccurred: false)); XCTAssertEqual(f.results.count, 1); XCTAssertEqual(f.timerStops, [1])
        c.cancel(); f.flush()
    }
    func testLastControlReleaseCancelsButKeepsLateReceipt() {
        let f = Fixture(), o = f.owner(); var c: RouterMappingTransactions.Control? = f.make(o, f.create)
        c = nil; f.flush(); XCTAssertNil(c); XCTAssertEqual(f.timerStops, [1]); XCTAssertEqual(f.httpCancels, [1]); XCTAssertTrue(f.results.isEmpty)
        f.http(.soap(.fault(code: 714, description: "Absent"))); XCTAssertEqual(f.results.count, 1)
    }
    func testControlCopiesRetainVisitUntilLastRelease() {
        let f = Fixture(), o = f.owner(); var first: RouterMappingTransactions.Control? = f.make(o, f.create), second = first
        first = nil; f.flush(); XCTAssertEqual(f.httpCancels, [0]); XCTAssertNotNil(second)
        second = nil; f.flush(); XCTAssertEqual(f.httpCancels, [1]); f.http(.failure("Cancelled", mutationMayHaveOccurred: false))
    }
    func testDuplicateAndObsoleteHTTPReceiptsCannotStartAnotherStage() {
        let f = Fixture(), o = f.owner(), c = f.make(o, f.create)
        f.http(.soap(.fault(code: 714, description: "Absent")), 0); XCTAssertEqual(f.httpReplies.count, 2)
        f.http(.soap(.fault(code: 714, description: "Absent")), 0); XCTAssertEqual(f.httpReplies.count, 2)
        c.cancel(); f.flush(); f.http(.failure("Cancelled", mutationMayHaveOccurred: false), 1)
        f.http(.soap(.success(externalAddress: "203.0.113.7")), 1); XCTAssertEqual(f.results.count, 1); XCTAssertEqual(f.httpReplies.count, 2)
    }
    func testCancelFromForeignThreadRetiresExactResourcesOnOwner() {
        let f = Fixture(), o = f.owner(), c = f.make(o, f.create); c.cancel(); c.cancel(); f.flush()
        XCTAssertEqual(f.httpCancels, [1]); XCTAssertEqual(f.timerStops, [1]); XCTAssertEqual(f.wrongQueue, 0)
        f.http(.failure("Cancelled", mutationMayHaveOccurred: false)); XCTAssertEqual(f.results.count, 1)
    }
    func testInvalidAndBackwardClockCancelWithoutMoreConstruction() {
        for now: TimeInterval in [.nan, -1] {
            let f = Fixture(), o = f.owner(), c = f.make(o, f.create); f.queue.sync { f.now = now }; f.fire()
            XCTAssertEqual(f.httpCancels, [1]); XCTAssertEqual(f.timerStops, [1]); XCTAssertEqual(f.httpReplies.count, 1)
            f.http(.failure("Clock", mutationMayHaveOccurred: false)); XCTAssertEqual(f.results.count, 1); c.cancel(); f.flush()
        }
        let f = Fixture(); f.now = .nan; let o = f.owner(), c = f.make(o)
        XCTAssertTrue(f.pulses.isEmpty); XCTAssertEqual(f.routeCalls, 0); XCTAssertEqual(f.results.count, 1); c.cancel(); f.flush()
    }
    func testDisablingPermissionCancelsDriverAndRefusesNextVisit() {
        let f = Fixture(), o = f.owner(), c = f.make(o, f.create); f.queue.sync { f.permitted = false }; f.fire()
        XCTAssertEqual(f.timerStops, [1]); f.http(.failure("Disabled", mutationMayHaveOccurred: false))
        let next = f.make(o); XCTAssertEqual(f.httpReplies.count, 1); XCTAssertEqual(f.pulses.count, 1); XCTAssertEqual(f.results.last, .refused)
        c.cancel(); next.cancel(); f.flush()
    }
    func testSchedulerImmediateDeadlineRetiresReturnedTimerOnce() {
        let f = Fixture(); f.onSchedule = { f.now = 8; f.pulses.last?() }
        let o = f.owner(), c = f.make(o, f.create)
        XCTAssertEqual(f.timerStops, [1]); XCTAssertEqual(f.httpCancels, [1]); XCTAssertTrue(f.results.isEmpty)
        f.http(.failure("Expired", mutationMayHaveOccurred: false)); XCTAssertEqual(f.timerStops, [1]); c.cancel(); f.flush()
    }
    func testWrapperReleaseWhileControlExistsKeepsRequestAndCleanup() {
        let f = Fixture(); var o: RouterNativeOperations? = f.owner(); let c = f.make(o!, f.create)
        o = nil; XCTAssertEqual(f.httpCancels, [0]); c.cancel(); f.flush(); XCTAssertEqual(f.httpCancels, [1]); f.http(.failure("Cancelled", mutationMayHaveOccurred: false)); XCTAssertEqual(f.results.count, 1)
    }
    func testLateAcceptedAddRetainsClaimAfterCancelAndNoDriverRestarts() {
        let f = Fixture(), o = f.owner(), c = f.make(o, f.create)
        f.http(.soap(.fault(code: 714, description: "Absent"))); f.http(.soap(.success(externalAddress: "203.0.113.7")))
        XCTAssertEqual(f.httpReplies.count, 3); c.cancel(); f.flush(); f.http(.soap(.success(externalAddress: nil)))
        guard case .created(.acknowledged(let claim, let retired, _))? = f.results.first else { return XCTFail("Late accepted Add claim lost") }
        XCTAssertTrue(retired); XCTAssertEqual(claim.token, "RemSound-fixture-0123456789"); XCTAssertEqual(f.httpReplies.count, 3); XCTAssertEqual(f.timerStops, [1])
    }
    func testActualDiscoveryOwnerIsDrivenAndClosedOnCancellation() {
        let f = Fixture(); f.autoUDP = false; let o = f.owner(), c = f.make(o)
        f.queue.sync { f.now = 2 }; f.fire(); f.queue.sync { f.now = 4 }; f.fire()
        XCTAssertEqual(f.discoverySockets.count, 1); XCTAssertEqual(f.discoverySockets.first?.sends, 1)
        c.cancel(); f.flush(); XCTAssertEqual(f.discoverySockets.first?.closes, 1); XCTAssertEqual(f.results.count, 1); XCTAssertEqual(f.timerStops, [1])
    }
    func testSynchronousRefusalNeverConstructsScheduler() {
        let f = Fixture(), o = f.owner()
        let invalid: RouterMappingTransactions.Operation = .udp(.create(.pcp(f.route, epoch: 1), internalPort: 0, lifetime: 3600))
        let c = f.make(o, invalid); XCTAssertTrue(f.sockets.isEmpty); XCTAssertTrue(f.pulses.isEmpty); XCTAssertEqual(f.results.count, 1); c.cancel(); f.flush()
    }
    func testRouteWorkConsumingDeadlineCannotConstructHTTPOrTimer() {
        let f = Fixture(); f.onRoute = { f.now = 8 }; let o = f.owner(), c = f.make(o, f.create)
        XCTAssertTrue(f.httpReplies.isEmpty); XCTAssertTrue(f.pulses.isEmpty); XCTAssertEqual(f.results.count, 1)
        c.cancel(); f.flush()
    }
    func testDisableInsideRawFactoryRefusesSchedulerButKeepsQuiescentReceipt() {
        let f = Fixture(); f.onHTTPFactory = { f.permitted = false }; let o = f.owner(), c = f.make(o, f.create)
        XCTAssertTrue(f.pulses.isEmpty); XCTAssertEqual(f.httpCancels, [1]); XCTAssertTrue(f.results.isEmpty)
        f.http(.failure("Disabled", mutationMayHaveOccurred: false)); XCTAssertEqual(f.results.count, 1); c.cancel(); f.flush()
    }
    func testDisableDuringSchedulerFactoryRetiresReturnedDriverImmediately() {
        let f = Fixture(); f.onSchedule = { f.permitted = false }; let o = f.owner(), c = f.make(o, f.create)
        XCTAssertEqual(f.timerStops, [1]); XCTAssertEqual(f.httpCancels, [1]); f.http(.failure("Disabled", mutationMayHaveOccurred: false)); c.cancel(); f.flush()
    }
    func testQueuedCancelBeforeStartConstructsNothing() {
        let f = Fixture(), o = f.owner(), entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        f.queue.async { entered.signal(); _ = released.wait(timeout: .now() + 3) }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        let c = o.make(.capability, { true }) { f.checkQueue(); f.results.append($0) }; c.cancel(); released.signal(); f.flush()
        XCTAssertEqual(f.results, [.cancelled]); XCTAssertEqual(f.routeCalls, 0); XCTAssertTrue(f.pulses.isEmpty)
    }
    func testChangedSelectedRouteRefusesBeforeSocketFactory() {
        let f = Fixture(); f.routeOverride = .init(gateway: Endpoint("192.0.2.2", 5351), sourceAddress: "192.0.2.10", interface: "fixture")
        let o = f.owner(), c = f.make(o, f.udpCreate)
        XCTAssertTrue(f.sockets.isEmpty); XCTAssertTrue(f.pulses.isEmpty); XCTAssertEqual(f.results.count, 1); c.cancel(); f.flush()
    }
    func testRealFiniteDispatchDriverReleasesReceiptStateWithMockSocket() {
        final class Clock { var now: TimeInterval = 0 }
        let queue = DispatchQueue(label: "router.native.finite-timer"), route = RouterGatewayRoute(gateway: Endpoint("192.0.2.1", 5351), sourceAddress: "192.0.2.10", interface: "fixture")
        var clock: Clock? = Clock(); weak var retiredClock = clock; let socket = Transport()
        socket.onSend = { _, endpoint in socket.incoming.append((Data([0,129,0,0,0,0,0,7,0xba,0xd6,0xba,0xd6,0,0,14,16]), endpoint)) }
        let done = expectation(description: "finite actual driver")
        var o: RouterNativeOperations? = RouterNativeOperations(queue: queue, allowed: { true }, clock: { [clock = clock!] in clock.now }, route: { route }, udpTransport: { _ in socket }, discoveryTransport: { _, _ in XCTFail("Unexpected discovery"); return socket }, http: { _, _, _, _ in XCTFail("Unexpected HTTP"); return {} }, schedule: nil)
        var c: RouterMappingTransactions.Control? = queue.sync { o?.make(.udp(.create(.natPmp(route, externalAddress: "203.0.113.7", epoch: 7), internalPort: 47830, lifetime: 3600)), { true }) { _ in done.fulfill() } }
        clock = nil; wait(for: [done], timeout: 3)
        queue.sync { c = nil; o = nil }; queue.sync {}
        XCTAssertNil(c); XCTAssertNil(retiredClock); XCTAssertEqual(socket.closes, 1)
        socket.onSend = nil
    }
    func testActualWorkflowLaneAndNativeAssemblyMapThenRemoveWithMockSockets() throws {
        let f = Fixture(), native = f.owner()
        let workflow = f.queue.sync { RouterMappingWorkflow(allowed: { f.allowed }, enabled: { f.permitted }, clock: { f.now }, factory: native.make) }
        var outcomes: [RouterMappingWorkflow.Outcome] = []
        f.queue.sync { workflow.open(internalPort: 47830, lifetime: 3600) { f.checkQueue(); outcomes.append($0) } }
        f.fire(); f.fire(); f.fire(1)
        let grant = try f.queue.sync { try XCTUnwrap(workflow.current) }; XCTAssertEqual(grant.externalPort, 47830)
        f.queue.sync { workflow.stop { f.checkQueue(); outcomes.append($0) } }; f.fire(2)
        f.queue.sync { XCTAssertNil(workflow.current); XCTAssertFalse(workflow.hasUnresolvedState); XCTAssertEqual(outcomes.count, 2) }
        XCTAssertEqual(f.timerStops, [1,1,1]); XCTAssertEqual(f.sockets.map(\.closes), [1,1,1,1]); XCTAssertEqual(f.wrongQueue, 0)
    }
}
