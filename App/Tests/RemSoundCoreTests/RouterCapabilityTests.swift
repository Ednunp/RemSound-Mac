import Foundation
import XCTest
import RemSoundRuntime
@testable import RemSoundCore

final class RouterCapabilityTests: XCTestCase {
    private final class Replies<Value> {
        private var values: [(Value) -> Void] = []
        var count: Int { values.count }
        var isEmpty: Bool { values.isEmpty }
        func append(_ reply: @escaping (Value) -> Void) { values.append(reply) }
        subscript(index: Int) -> (Value) -> Void {
            guard values.indices.contains(index) else { XCTFail("Expected request callback at index \(index)"); return { _ in } }
            return values[index]
        }
    }
    private final class Fixture {
        var now: TimeInterval = 0, permitted = true, routeCalls = 0
        var route: RouterGatewayRoute? = .init(gateway: Endpoint("192.0.2.1", 5351), sourceAddress: "192.0.2.10", interface: "fixture")
        var udpRequests: [RouterUDPExchange.Request] = [], udpReplies = Replies<RouterUDPExchange.Outcome>(), udpCancels = 0
        var discoveries = Replies<URL?>(), discoveryCancels = 0
        var httpReplies = Replies<RouterHTTPTransport.Outcome>(), httpCancels = 0, httpBudgets: [TimeInterval] = []
        var results: [RouterCapability.Outcome] = [], synchronous = false
        var selectedRoute: RouterGatewayRoute { route! }
        var service: UPnPRouterService { .init(kind: .ip2, controlURL: URL(string: "http://192.0.2.1/control")!, gatewayAddress: "192.0.2.1") }
        func owner() -> RouterCapability {
            RouterCapability(permitted: { self.permitted }, clock: { self.now }, route: { self.routeCalls += 1; return self.route }, udp: { request, route, completion in
                XCTAssertEqual(route, self.selectedRoute); XCTAssertFalse(request.mutates)
                self.udpRequests.append(request); self.udpReplies.append(completion)
                if self.synchronous { completion(.response(self.reply(), route)) }
                return { self.udpCancels += 1 }
            }, discover: { route, budget, completion in
                XCTAssertEqual(route, self.selectedRoute); XCTAssertGreaterThan(budget, 0)
                self.discoveries.append(completion); return { self.discoveryCancels += 1 }
            }, http: { _, budget, completion in
                self.httpBudgets.append(budget); self.httpReplies.append(completion); return { self.httpCancels += 1 }
            }, completion: { self.results.append($0) })
        }
        func reply(code: UInt16 = 0, address: String? = nil, lifetime: UInt32 = 0) -> RouterMappingReply {
            .init(resultCode: code, internalPort: 0, externalPort: 0, lifetime: lifetime, epoch: 90, externalAddress: address)
        }
        func pcpUnsupported() { udpReplies[0](.response(reply(code: 1), selectedRoute)) }
        func natUnsupported() { udpReplies[1](.response(reply(code: 1), selectedRoute)) }
        func toDescription() {
            pcpUnsupported(); natUnsupported(); discoveries[0](URL(string: "http://192.0.2.1/description"))
        }
    }
    func testOffRefusesBeforeAnyRouteOrTransportFactory() {
        let f = Fixture(); f.permitted = false; let owner = f.owner(); owner.start(); owner.tick(); owner.cancel()
        XCTAssertEqual(f.results, [.refused]); XCTAssertEqual(f.routeCalls, 0); XCTAssertTrue(f.udpRequests.isEmpty)
    }
    func testIsolatedNativeConfigurationRefusesBeforeInjectedFactories() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]!).appendingPathComponent("capability-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try RuntimeConfiguration(options: LaunchOptions.parse(["--config-dir", root.path, "--headless", "--silent"]))
        let f = Fixture()
        let owner = RouterCapability(configuration: config, enabled: { true }, route: { XCTFail("Isolated route lookup"); return f.route }, udp: { _, _, _ in XCTFail("Isolated UDP"); return {} }, discover: { _, _, _ in XCTFail("Isolated discovery"); return {} }, http: { _, _, _ in XCTFail("Isolated HTTP"); return {} }, completion: { f.results.append($0) })
        owner.start(); XCTAssertEqual(f.results, [.refused])
    }
    func testPcpCapabilityUsesOnlyNonMutatingAnnounceAndReturnsEpoch() {
        let f = Fixture(), owner = f.owner(); owner.start(); owner.start()
        XCTAssertEqual(f.udpRequests.count, 1)
        guard case .pcpAnnounce? = f.udpRequests.first else { return XCTFail("Expected capability request") }
        f.udpReplies[0](.response(f.reply(), f.selectedRoute)); owner.tick()
        XCTAssertEqual(f.results, [.selected(.pcp(f.selectedRoute, epoch: 90))]); XCTAssertEqual(f.udpCancels, 1)
    }
    func testExplicitVersionRefusalQueriesNatAddressBeforeAnyMapping() {
        let f = Fixture(), owner = f.owner(); owner.start(); f.pcpUnsupported()
        XCTAssertEqual(f.udpRequests.count, 2)
        guard case .natAddress? = f.udpRequests.dropFirst().first else { return XCTFail("Expected NAT address query") }
        f.udpReplies[1](.response(f.reply(address: "203.0.113.7"), f.selectedRoute))
        XCTAssertEqual(f.results, [.selected(.natPmp(f.selectedRoute, externalAddress: "203.0.113.7", epoch: 90))]); XCTAssertEqual(f.udpCancels, 2)
    }
    func testNoUdpCapabilityUsesSelectedGatewayDiscoveryAndTypedDescription() {
        let f = Fixture(), owner = f.owner(); owner.start(); f.toDescription()
        f.httpReplies[0](.description([f.service]))
        XCTAssertEqual(f.results, [.selected(.upnp(f.selectedRoute, f.service))]); XCTAssertEqual(f.discoveryCancels, 1); XCTAssertEqual(f.httpCancels, 1)
    }
    func testStageTimeoutWaitsForCancellationCompletionBeforeFallback() {
        let f = Fixture(), owner = f.owner(); owner.start(); f.now = 2; owner.tick(); owner.tick()
        XCTAssertEqual(f.udpCancels, 1); XCTAssertEqual(f.udpRequests.count, 1); XCTAssertTrue(f.results.isEmpty)
        f.udpReplies[0](.cancelled(mutationMayHaveOccurred: false))
        XCTAssertEqual(f.udpRequests.count, 2)
        f.now = 4; owner.tick(); XCTAssertEqual(f.udpRequests.count, 2); XCTAssertTrue(f.discoveries.isEmpty)
        f.udpReplies[1](.cancelled(mutationMayHaveOccurred: false)); XCTAssertEqual(f.discoveries.count, 1)
    }
    func testOverallDeadlineRetiresAndNeverRestartsAfterQuiescence() {
        let f = Fixture(), owner = f.owner(); owner.start(); f.now = 8; owner.tick()
        XCTAssertTrue(f.results.isEmpty); XCTAssertEqual(f.udpCancels, 1)
        f.udpReplies[0](.cancelled(mutationMayHaveOccurred: false)); owner.tick()
        XCTAssertEqual(f.results, [.unavailable]); XCTAssertEqual(f.udpRequests.count, 1)
    }
    func testStopWaitsAndLateCapabilityCannotStartAnotherProtocol() {
        let f = Fixture(), owner = f.owner(); owner.start(); owner.cancel(); owner.cancel()
        XCTAssertEqual(f.udpCancels, 1); XCTAssertTrue(f.results.isEmpty)
        f.udpReplies[0](.lateResponse(f.reply(), f.selectedRoute)); owner.start()
        XCTAssertEqual(f.results, [.cancelled]); XCTAssertEqual(f.udpRequests.count, 1)
    }
    func testPermissionRetirementSuppressesLateDescription() {
        let f = Fixture(), owner = f.owner(); owner.start(); f.toDescription(); f.permitted = false; owner.tick()
        XCTAssertEqual(f.httpCancels, 1); XCTAssertTrue(f.results.isEmpty)
        f.httpReplies[0](.description([f.service])); XCTAssertEqual(f.results, [.refused])
    }
    func testWrongReplyRouteCannotSelectProtocol() {
        let f = Fixture(), owner = f.owner(); owner.start()
        let other = RouterGatewayRoute(gateway: Endpoint("192.0.2.2", 5351), sourceAddress: "192.0.2.10", interface: "fixture")
        f.udpReplies[0](.response(f.reply(), other))
        guard case .failure? = f.results.first else { return XCTFail("Wrong gateway must fail closed") }
        XCTAssertEqual(f.results.count, 1); XCTAssertEqual(f.udpRequests.count, 1)
    }
    func testUncertainOrMutatingInjectedResultNeverFallsBack() {
        for outcome: RouterUDPExchange.Outcome in [.timedOut(mutationMayHaveOccurred: true), .failed("lost", mutationMayHaveOccurred: true), .cancelled(mutationMayHaveOccurred: true)] {
            let f = Fixture(), owner = f.owner(); owner.start(); f.udpReplies[0](outcome)
            guard case .failure? = f.results.first else { XCTFail("Uncertainty must stop protocol selection"); continue }
            XCTAssertEqual(f.udpRequests.count, 1); XCTAssertTrue(f.discoveries.isEmpty)
        }
    }
    func testNonMutatingNoReplyCanFallBackAndKeepsOneVisitRoute() {
        let f = Fixture(), owner = f.owner(); owner.start(); f.udpReplies[0](.timedOut(mutationMayHaveOccurred: false))
        f.udpReplies[1](.unavailable); XCTAssertEqual(f.discoveries.count, 1); XCTAssertEqual(f.routeCalls, 1)
        f.discoveries[0](nil); XCTAssertEqual(f.results, [.unavailable])
    }
    func testAuthorizationFailureStopsInsteadOfTryingOtherProtocols() {
        let f = Fixture(), owner = f.owner(); owner.start(); f.udpReplies[0](.response(f.reply(code: 2, lifetime: 1800), f.selectedRoute))
        XCTAssertEqual(f.udpRequests.count, 1)
        guard case .failure(_, retryAfter: 1800)? = f.results.first else { return XCTFail("Authorization refusal needs backoff") }
    }
    func testShortAndExplicitPcpErrorLifetimesRemainTruthful() {
        for (code, lifetime, expected): (UInt16, UInt32, TimeInterval) in [(7, 0, 30), (8, 120, 120), (3, 0, 1800)] {
            let f = Fixture(), owner = f.owner(); owner.start(); f.udpReplies[0](.response(f.reply(code: code, lifetime: lifetime), f.selectedRoute))
            guard case .failure(_, let retry)? = f.results.first else { XCTFail("Expected finite failure"); continue }; XCTAssertEqual(retry, expected)
        }
    }
    func testPcpExcessiveRemotePeersUsesLongBackoff() {
        let f = Fixture(), owner = f.owner(); owner.start(); f.udpReplies[0](.response(f.reply(code: 13), f.selectedRoute))
        guard case .failure(_, retryAfter: 1800)? = f.results.first else { return XCTFail("RFC6887 excessive remote peers is a long-lifetime error") }
    }
    func testMissingInvalidRouteAndChangesDuringLookupRefuseBeforeFactories() {
        let f = Fixture(); f.route = nil; let owner = f.owner(); owner.start(); XCTAssertEqual(f.results, [.unavailable]); XCTAssertTrue(f.udpRequests.isEmpty)
        let g = Fixture(); let other = RouterCapability(permitted: { g.permitted }, clock: { g.now }, route: { g.permitted = false; return g.route }, udp: { _, _, _ in XCTFail("Retired route must not send"); return {} }, discover: { _, _, _ in XCTFail(); return {} }, http: { _, _, _ in XCTFail(); return {} }, completion: { g.results.append($0) })
        other.start(); XCTAssertEqual(g.results, [.refused])
    }
    func testDiscoveryUrlCannotEscapeSelectedGateway() {
        for text in ["http://192.0.2.2/x", "http://router.invalid/x", "http://u@192.0.2.1/x", "http://192.0.2.1/x#part"] {
            let f = Fixture(), owner = f.owner(); owner.start(); f.pcpUnsupported(); f.natUnsupported(); f.discoveries[0](URL(string: text))
            XCTAssertTrue(f.httpReplies.isEmpty); XCTAssertEqual(f.results, [.unavailable])
        }
    }
    func testDescriptionServiceOriginPriorityAndRemainingBudget() {
        let f = Fixture(), owner = f.owner(); owner.start(); f.now = 1; f.pcpUnsupported(); f.now = 3; f.natUnsupported(); f.now = 5; f.discoveries[0](URL(string: "http://192.0.2.1/x"))
        XCTAssertEqual(f.httpBudgets, [3])
        let foreign = UPnPRouterService(kind: .ip2, controlURL: URL(string: "http://192.0.2.2/control")!, gatewayAddress: "192.0.2.1")
        let lower = UPnPRouterService(kind: .ppp1, controlURL: f.service.controlURL, gatewayAddress: "192.0.2.1")
        f.httpReplies[0](.description([foreign, lower, f.service]))
        XCTAssertEqual(f.results, [.selected(.upnp(f.selectedRoute, f.service))])
    }
    func testDuplicateAndPreviousStageCallbacksAreIgnored() {
        let f = Fixture(), owner = f.owner(); owner.start(); f.pcpUnsupported(); f.udpReplies[0](.response(f.reply(), f.selectedRoute))
        XCTAssertTrue(f.results.isEmpty); XCTAssertEqual(f.udpRequests.count, 2)
        let answer = RouterUDPExchange.Outcome.response(f.reply(address: "203.0.113.7"), f.selectedRoute)
        f.udpReplies[1](answer); f.udpReplies[1](answer); XCTAssertEqual(f.results.count, 1); XCTAssertEqual(f.udpCancels, 2)
    }
    func testSynchronousReplyCleansReturnedCancellationExactlyOnce() {
        let f = Fixture(); f.synchronous = true; let owner = f.owner(); owner.start(); owner.cancel()
        XCTAssertEqual(f.results, [.selected(.pcp(f.selectedRoute, epoch: 90))]); XCTAssertEqual(f.udpCancels, 1)
    }
    func testInvalidAndBackwardsClockFailWithoutInventingCompletion() {
        let f = Fixture(); f.now = .nan; let owner = f.owner(); owner.start()
        guard case .failure? = f.results.first else { return XCTFail("Invalid initial clock must fail") }
        XCTAssertEqual(f.routeCalls, 0)
        let g = Fixture(); g.now = 5; let active = g.owner(); active.start(); g.now = 4; active.tick()
        XCTAssertTrue(g.results.isEmpty); XCTAssertEqual(g.udpCancels, 1)
        g.udpReplies[0](.cancelled(mutationMayHaveOccurred: false))
        guard case .failure? = g.results.first else { return XCTFail("Clock retirement must wait for its receipt") }
        XCTAssertEqual(g.udpRequests.count, 1)
    }
    func testRouteWorkCannotConsumeDeadlineThenConstructTransport() {
        let f = Fixture()
        let owner = RouterCapability(permitted: { true }, clock: { f.now }, route: { f.now = 8; return f.route }, udp: { _, _, _ in XCTFail("Deadline passed during route work"); return {} }, discover: { _, _, _ in XCTFail(); return {} }, http: { _, _, _ in XCTFail(); return {} }, completion: { f.results.append($0) })
        owner.start(); XCTAssertEqual(f.results, [.unavailable])
    }
    func testDiscoveryTimeoutWaitsForExactCloseAndLateUrlCannotStartHttp() {
        let f = Fixture(), owner = f.owner(); owner.start(); f.pcpUnsupported(); f.natUnsupported(); f.now = 2; owner.tick(); owner.tick()
        XCTAssertEqual(f.discoveryCancels, 1); XCTAssertTrue(f.results.isEmpty)
        f.discoveries[0](URL(string: "http://192.0.2.1/late"))
        XCTAssertEqual(f.results, [.unavailable]); XCTAssertTrue(f.httpReplies.isEmpty)
    }
    func testStopInsideFactoryRetiresReturnedResourceAndWaitsForReceipt() {
        let f = Fixture(); weak var live: RouterCapability?
        let owner = RouterCapability(permitted: { true }, clock: { f.now }, route: { f.route }, udp: { _, _, completion in
            f.udpReplies.append(completion); live?.cancel(); return { f.udpCancels += 1 }
        }, discover: { _, _, _ in XCTFail("Stopped factory must not discover"); return {} }, http: { _, _, _ in XCTFail(); return {} }, completion: { f.results.append($0) })
        live = owner; owner.start(); XCTAssertEqual(f.udpCancels, 1); XCTAssertTrue(f.results.isEmpty)
        f.udpReplies[0](.lateResponse(f.reply(), f.selectedRoute)); XCTAssertEqual(f.results, [.cancelled]); XCTAssertEqual(f.udpCancels, 1)
    }
    func testDeallocationStillReportsQuiescenceWithoutStartingFallback() {
        let f = Fixture(); var owner: RouterCapability? = f.owner(); owner?.start(); weak var weakOwner = owner; owner = nil
        XCTAssertNil(weakOwner); XCTAssertEqual(f.udpCancels, 1)
        f.udpReplies[0](.lateResponse(f.reply(), f.selectedRoute)); XCTAssertEqual(f.results, [.cancelled]); XCTAssertEqual(f.udpRequests.count, 1)
    }
}
