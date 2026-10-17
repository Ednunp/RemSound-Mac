import Foundation
import XCTest
@testable import RemSoundCore

final class RouterProtocolOperationsTests: XCTestCase {
    private final class Fixture {
        var now: TimeInterval = 0, allowed = true, enabled = true, routeCalls = 0
        let route = RouterGatewayRoute(gateway: Endpoint("192.0.2.1", 5351), sourceAddress: "192.0.2.10", interface: "fixture")
        var service: UPnPRouterService { .init(kind: .ip2, controlURL: URL(string: "http://192.0.2.1/control")!, gatewayAddress: "192.0.2.1") }
        let token = "RemSound-fixture-0123456789", nonce = Data(0..<12)
        var udpRequests: [RouterUDPExchange.Request] = [], udpCallbacks: [(RouterUDPExchange.Outcome) -> Void] = []
        var httpRequests: [RouterHTTPTransport.Request] = [], httpCallbacks: [(RouterHTTPTransport.Outcome) -> Void] = []
        var discoveryCallbacks: [(RouterDiscovery.Outcome) -> Void] = [], budgets: [TimeInterval] = []
        var udpCloses: [Int] = [], httpCloses: [Int] = [], discoveryCloses: [Int] = [], trace: [String] = []
        var onUDP: ((Int) -> Void)?, onHTTP: ((Int) -> Void)?, onUdpTick: (() -> Void)?
        var results: [RouterMappingTransactions.Result] = [], receipts: [RouterMappingTransactions.Receipt] = []
        func assembly() -> RouterProtocolOperations {
            RouterProtocolOperations(clock: { self.now }, route: { self.routeCalls += 1; return self.route },
                udp: { request, route, gate, reply in
                    XCTAssertEqual(route, self.route); XCTAssertTrue(gate())
                    let i = self.udpRequests.count; self.udpRequests.append(request); self.udpCallbacks.append(reply); self.udpCloses.append(0); self.trace.append("udp\(i)"); self.onUDP?(i)
                    return .init(tick: { self.onUdpTick?() }, cancel: { self.udpCloses[i] += 1; self.trace.append("close-udp\(i)") })
                }, discovery: { route, budget, gate, reply in
                    XCTAssertEqual(route, self.route); XCTAssertTrue(gate()); self.budgets.append(budget)
                    let i = self.discoveryCallbacks.count; self.discoveryCallbacks.append(reply); self.discoveryCloses.append(0); self.trace.append("discovery\(i)")
                    return .init(tick: {}, cancel: { self.discoveryCloses[i] += 1 })
                }, http: { request, budget, gate, reply in
                    XCTAssertTrue(gate()); self.budgets.append(budget)
                    let i = self.httpRequests.count; self.httpRequests.append(request); self.httpCallbacks.append(reply); self.httpCloses.append(0); self.trace.append("http\(i)"); self.onHTTP?(i)
                    return .init(tick: {}, cancel: { self.httpCloses[i] += 1; self.trace.append("close-http\(i)") })
                }, nonce: { self.nonce }, token: { self.token })
        }
        func lane(_ assembly: RouterProtocolOperations) -> RouterMappingTransactions {
            RouterMappingTransactions(allowed: { self.allowed }, enabled: { self.enabled }, clock: { self.now }, factory: assembly.make)
        }
        func udp(_ value: RouterUDPExchange.Outcome, index: Int? = nil) {
            let i = index ?? udpCallbacks.count - 1; guard udpCallbacks.indices.contains(i) else { XCTFail("Missing UDP callback"); return }; udpCallbacks[i](value)
        }
        func http(_ value: RouterHTTPTransport.Outcome, index: Int? = nil) {
            let i = index ?? httpCallbacks.count - 1; guard httpCallbacks.indices.contains(i) else { XCTFail("Missing HTTP callback"); return }; httpCallbacks[i](value)
        }
        func discovery(_ value: RouterDiscovery.Outcome) {
            guard let reply = discoveryCallbacks.last else { return XCTFail("Missing discovery callback") }; reply(value)
        }
        func reply(code: UInt16 = 0, port: UInt16 = 0, externalPort: UInt16 = 0, lifetime: UInt32 = 0, address: String? = nil) -> RouterUDPExchange.Outcome {
            .response(.init(resultCode: code, internalPort: port, externalPort: externalPort, lifetime: lifetime, epoch: 100, externalAddress: address), route)
        }
        func mapping(lifetime: UInt32 = 120, token: String? = nil) -> UPnPPortMapping {
            .init(internalPort: 47830, internalClient: "192.0.2.10", enabled: true, description: token ?? self.token, leaseSeconds: lifetime)
        }
        var natCreate: RouterMappingTransactions.Operation { .udp(.create(.natPmp(route, externalAddress: "203.0.113.7", epoch: 100), internalPort: 47830, lifetime: 3600)) }
        var upnpCreate: RouterMappingTransactions.Operation { .upnpCreate(route, service, internalPort: 47830, lifetime: 3600) }
        func finishUpnpCreate() {
            http(.soap(.fault(code: 714, description: "Absent"))); http(.soap(.success(externalAddress: "203.0.113.7")))
            http(.soap(.success(externalAddress: nil))); http(.soap(.mapping(mapping())))
        }
        func upnpLease(_ lane: RouterMappingTransactions) throws -> UPnPMappingCreation.Lease {
            lane.submit(upnpCreate) { self.results.append($0) }; finishUpnpCreate()
            guard case .created(.granted(let lease, _))? = results.last?.receipt else { throw NSError(domain: "Missing assembled UPnP grant", code: 1) }; return lease
        }
        func udpLease(_ lane: RouterMappingTransactions) throws -> RouterUDPMapping.Lease {
            lane.submit(natCreate) { self.results.append($0) }; udp(reply(port: 47830, externalPort: 49321, lifetime: 120))
            guard case .udp(.granted(let lease, _, _))? = results.last?.receipt else { throw NSError(domain: "Missing assembled UDP grant", code: 1) }; return lease
        }
    }
    func testRefusalPrecedesRouteAndEveryRawFactory() {
        let f = Fixture(), assembly = f.assembly(), control = assembly.make(.capability, { false }) { f.receipts.append($0) }
        control.tick(); control.cancel(); XCTAssertEqual(f.receipts, [.refused]); XCTAssertEqual(f.routeCalls, 0); XCTAssertTrue(f.udpRequests.isEmpty); XCTAssertTrue(f.httpRequests.isEmpty)
    }
    func testActualPcpCapabilityThenCreatePreservesNonceGrantAndExpiry() {
        let f = Fixture(), assembly = f.assembly(), lane = f.lane(assembly)
        lane.submit(.capability) { result in
            guard !result.retired, case .capability(.selected(let selection)) = result.receipt else { return XCTFail("PCP capability missing") }
            lane.submit(.udp(.create(selection, internalPort: 47830, lifetime: 3600))) { f.results.append($0) }
        }
        f.udp(f.reply()); guard case .pcpMap(let nonce, let port, _, let life, _)? = f.udpRequests.last else { return XCTFail("PCP map not constructed") }
        XCTAssertEqual(nonce, f.nonce); XCTAssertEqual(port, 47830); XCTAssertEqual(life, 3600)
        f.now = 1; f.udp(f.reply(port: 47830, externalPort: 49321, lifetime: 120, address: "203.0.113.7"))
        guard case .udp(.granted(let lease, retired: false, epochChanged: false))? = f.results.first?.receipt else { return XCTFail("Mapped PCP grant missing") }
        XCTAssertEqual(lease.validUntil, 120); XCTAssertEqual(lease.externalPort, 49321); XCTAssertEqual(lease.nonce, f.nonce); XCTAssertEqual(f.udpCloses, [1, 1])
    }
    func testSynchronousCapabilityFallbackWaitsForRawFactoryReturn() {
        let f = Fixture(), assembly = f.assembly(); f.onUDP = { i in
            guard i == 0 else { return }; f.udp(f.reply(code: 1), index: 0); XCTAssertEqual(f.udpRequests.count, 1); XCTAssertTrue(f.receipts.isEmpty)
        }
        let control = assembly.make(.capability, { true }) { f.receipts.append($0) }; f.onUDP = nil
        XCTAssertEqual(f.trace.prefix(3), ["udp0", "close-udp0", "udp1"])
        f.udp(f.reply(address: "203.0.113.7")); XCTAssertEqual(f.receipts, [.capability(.selected(.natPmp(f.route, externalAddress: "203.0.113.7", epoch: 100)))]); control.cancel()
    }
    func testActualUpnpCapabilityFallbackSelectsTypedService() {
        let f = Fixture(), assembly = f.assembly(), control = assembly.make(.capability, { true }) { f.receipts.append($0) }
        f.udp(f.reply(code: 1)); f.udp(f.reply(code: 1)); f.discovery(.found(URL(string: "http://192.0.2.1/description.xml")!))
        XCTAssertNil(f.httpRequests.last?.action); f.http(.description([f.service])); XCTAssertEqual(f.receipts, [.capability(.selected(.upnp(f.route, f.service)))])
        XCTAssertEqual(f.udpCloses, [1, 1]); XCTAssertEqual(f.discoveryCloses, [1]); XCTAssertEqual(f.httpCloses, [1]); control.cancel()
    }
    func testActualUpnpPreflightAddAndReadbackProducePrivateLease() throws {
        let f = Fixture(), assembly = f.assembly(), lane = f.lane(assembly), lease = try f.upnpLease(lane)
        XCTAssertEqual(f.httpRequests.map(\.action), [.specificMapping, .externalIP, .add, .specificMapping]); XCTAssertEqual(lease.claim.token, f.token); XCTAssertEqual(lease.validUntil, 120); XCTAssertEqual(f.httpCloses, [1, 1, 1, 1])
    }
    func testOccupiedPreflightCannotConstructAdd() {
        let f = Fixture(), assembly = f.assembly(), lane = f.lane(assembly); lane.submit(f.upnpCreate) { f.results.append($0) }; f.http(.soap(.mapping(f.mapping(token: "Manual"))))
        XCTAssertEqual(f.httpRequests.count, 1); XCTAssertEqual(f.results.first?.receipt, .created(.occupied))
    }
    func testActualNatRenewAndRemoveRetainOriginalGrantedTuple() throws {
        let f = Fixture(), assembly = f.assembly(), lane = f.lane(assembly), lease = try f.udpLease(lane)
        f.now = 2; lane.submit(.udp(.renew(lease, lifetime: 3600))) { f.results.append($0) }
        guard case .natMap(let port, let external, let lifetime)? = f.udpRequests.last else { return XCTFail("Renewal missing") }; XCTAssertEqual(port, 47830); XCTAssertEqual(external, 49321); XCTAssertEqual(lifetime, 3600)
        f.udp(f.reply(port: 47830, externalPort: 49321, lifetime: 90)); guard case .udp(.granted(let renewed, _, _))? = f.results.last?.receipt else { return XCTFail("Renewal receipt missing") }
        lane.submit(.udp(.remove(renewed))) { f.results.append($0) }; guard case .natMap(let deletePort, let suggestion, let zero)? = f.udpRequests.last else { return XCTFail("Delete missing") }
        XCTAssertEqual(deletePort, 47830); XCTAssertEqual(suggestion, 0); XCTAssertEqual(zero, 0); f.udp(f.reply(port: 47830)); XCTAssertEqual(f.results.last?.receipt, .udp(.removed(retired: false)))
    }
    func testActualUpnpRenewThenVerifiedRemoval() throws {
        let f = Fixture(), assembly = f.assembly(), lane = f.lane(assembly), lease = try f.upnpLease(lane)
        f.now = 2; lane.submit(.upnpMaintain(.lease(lease), .renew(lifetime: 3600))) { f.results.append($0) }
        f.http(.soap(.mapping(f.mapping()))); f.http(.soap(.success(externalAddress: "203.0.113.7"))); f.http(.soap(.success(externalAddress: nil))); f.http(.soap(.mapping(f.mapping(lifetime: 90))))
        guard case .maintained(.renewed(let renewed, _))? = f.results.last?.receipt else { return XCTFail("Actual renewal missing") }; XCTAssertEqual(renewed.validUntil, 92)
        lane.submit(.upnpMaintain(.lease(renewed), .remove)) { f.results.append($0) }
        f.http(.soap(.mapping(f.mapping()))); f.http(.soap(.success(externalAddress: "203.0.113.7"))); f.http(.soap(.success(externalAddress: nil))); f.http(.soap(.fault(code: 714, description: "Absent")))
        XCTAssertEqual(f.results.last?.receipt, .maintained(.removed)); XCTAssertTrue(f.httpCloses.allSatisfy { $0 == 1 })
    }
    func testCancelDuringAcceptedAddReturnsClaimThenLaneCleansBeforeCompletion() {
        let f = Fixture(), assembly = f.assembly(), lane = f.lane(assembly), id = lane.submit(f.upnpCreate) { f.results.append($0) }
        f.http(.soap(.fault(code: 714, description: "Absent"))); f.http(.soap(.success(externalAddress: "203.0.113.7"))); lane.cancel(id)
        XCTAssertTrue(f.results.isEmpty); XCTAssertEqual(f.httpCloses, [1, 1, 1]); f.http(.soap(.success(externalAddress: nil)))
        XCTAssertEqual(f.httpRequests.map(\.action), [.specificMapping, .externalIP, .add, .specificMapping]); XCTAssertTrue(f.results.isEmpty)
        f.http(.soap(.mapping(f.mapping()))); f.http(.soap(.success(externalAddress: "203.0.113.7"))); f.http(.soap(.success(externalAddress: nil))); f.http(.soap(.fault(code: 714, description: "Absent")))
        guard case .created(.acknowledged(_, retired: true, _))? = f.results.first?.receipt else { return XCTFail("Accepted claim lost") }; XCTAssertEqual(f.results.first?.cleanup, .maintained(.removed)); XCTAssertTrue(f.httpCloses.allSatisfy { $0 == 1 })
    }
    func testLateUdpGrantIsExactlyDeletedBeforeQueuedMapStarts() {
        let f = Fixture(), assembly = f.assembly(), lane = f.lane(assembly), id = lane.submit(f.natCreate) { f.results.append($0) }
        lane.submit(f.natCreate) { f.results.append($0) }; lane.cancel(id); f.udp(f.reply(port: 47830, externalPort: 49321, lifetime: 120))
        guard case .natMap(_, let suggestion, let zero)? = f.udpRequests.last else { return XCTFail("Late grant cleanup missing") }; XCTAssertEqual(suggestion, 0); XCTAssertEqual(zero, 0); XCTAssertEqual(f.udpRequests.count, 2)
        f.udp(f.reply(port: 47830)); XCTAssertEqual(f.udpRequests.count, 3); XCTAssertEqual(f.results.first?.cleanup, .udp(.removed(retired: false)))
        lane.shutdown(); f.udp(.cancelled(mutationMayHaveOccurred: false))
    }
    func testLostAddReplyUsesFreshClaimProofAndDoesNotGuessDelete() {
        let f = Fixture(), assembly = f.assembly(), lane = f.lane(assembly); lane.submit(f.upnpCreate) { f.results.append($0) }
        f.http(.soap(.fault(code: 714, description: "Absent"))); f.http(.soap(.success(externalAddress: "203.0.113.7"))); f.http(.failure("Lost", mutationMayHaveOccurred: true))
        XCTAssertEqual(f.httpRequests.last?.action, .specificMapping); f.http(.soap(.mapping(f.mapping(token: "Replacement"))))
        guard case .created(.uncertain)? = f.results.first?.receipt else { return XCTFail("Lost Add was hidden") }; guard case .maintained(.changed)? = f.results.first?.cleanup else { return XCTFail("Replacement proof lost") }
        XCTAssertFalse(f.httpRequests.contains { $0.action == .delete }); lane.submit(f.natCreate) { f.results.append($0) }; XCTAssertTrue(f.udpRequests.isEmpty)
    }
    func testCancellationWaitsForRawReceiptBeforeCapabilityFallback() {
        let f = Fixture(), assembly = f.assembly(), control = assembly.make(.capability, { f.enabled }) { f.receipts.append($0) }
        f.now = 2; control.tick(); XCTAssertEqual(f.udpRequests.count, 1); XCTAssertEqual(f.udpCloses, [1]); XCTAssertTrue(f.receipts.isEmpty)
        f.udp(.cancelled(mutationMayHaveOccurred: false)); XCTAssertEqual(f.udpRequests.count, 2); control.cancel(); f.udp(.cancelled(mutationMayHaveOccurred: false)); XCTAssertEqual(f.receipts, [.capability(.cancelled)])
    }
    func testPermissionLossBetweenStagesPreventsNextRawConstruction() {
        let f = Fixture(), assembly = f.assembly(), control = assembly.make(.capability, { f.enabled }) { f.receipts.append($0) }
        f.enabled = false; f.udp(f.reply(code: 1)); XCTAssertEqual(f.udpRequests.count, 1); XCTAssertEqual(f.receipts, [.capability(.refused)]); control.cancel()
    }
    func testDuplicateRawCallbacksCannotRepeatAddOrCompletion() {
        let f = Fixture(), assembly = f.assembly(), lane = f.lane(assembly); lane.submit(f.upnpCreate) { f.results.append($0) }
        f.http(.soap(.fault(code: 714, description: "Absent")), index: 0); f.http(.soap(.fault(code: 714, description: "Duplicate")), index: 0)
        XCTAssertEqual(f.httpRequests.count, 2); f.http(.soap(.success(externalAddress: "203.0.113.7"))); f.http(.soap(.success(externalAddress: nil))); f.http(.soap(.mapping(f.mapping())))
        f.http(.soap(.mapping(f.mapping())), index: 3); XCTAssertEqual(f.results.count, 1); XCTAssertEqual(f.httpRequests.count, 4)
    }
    func testOwnerReleaseStillDrivesAcceptedClaimCleanupWithRetainedControl() {
        let f = Fixture(), assembly = f.assembly(); var lane: RouterMappingTransactions? = f.lane(assembly); lane?.submit(f.upnpCreate) { f.results.append($0) }
        f.http(.soap(.fault(code: 714, description: "Absent"))); f.http(.soap(.success(externalAddress: "203.0.113.7"))); weak var released = lane; lane = nil
        XCTAssertNil(released); f.http(.soap(.success(externalAddress: nil))); XCTAssertEqual(f.httpRequests.last?.action, .specificMapping); f.http(.soap(.fault(code: 714, description: "Absent")))
        XCTAssertEqual(f.results.first?.cleanup, .maintained(.absent))
    }
    func testDisabledChoiceStillAllowsOnlyKnownCleanupAfterLateGrant() {
        let f = Fixture(), assembly = f.assembly(), lane = f.lane(assembly), id = lane.submit(f.natCreate) { f.results.append($0) }
        f.enabled = false; lane.cancel(id); f.udp(f.reply(port: 47830, externalPort: 49321, lifetime: 120)); XCTAssertEqual(f.udpRequests.count, 2)
        f.udp(f.reply(port: 47830)); XCTAssertEqual(f.results.first?.cleanup, .udp(.removed(retired: false)))
    }
    func testBudgetsRemainFiniteAcrossActualUpnpStages() {
        let f = Fixture(), assembly = f.assembly(), lane = f.lane(assembly); lane.submit(f.upnpCreate) { f.results.append($0) }
        f.now = 1; f.http(.soap(.fault(code: 714, description: "Absent"))); f.now = 2; f.http(.soap(.success(externalAddress: "203.0.113.7"))); f.now = 3; f.http(.soap(.success(externalAddress: nil))); f.now = 4; f.http(.soap(.mapping(f.mapping())))
        XCTAssertEqual(f.budgets, [8, 7, 6, 5]); guard case .created(.granted(let lease, _))? = f.results.first?.receipt else { return XCTFail("Budgeted actual grant missing") }; XCTAssertEqual(lease.validUntil, 122)
    }
    func testLostInitialUdpReplyNeverConstructsFallbackOrBlindRetry() {
        let f = Fixture(), assembly = f.assembly(), lane = f.lane(assembly); lane.submit(f.natCreate) { f.results.append($0) }; f.udp(.timedOut(mutationMayHaveOccurred: true))
        lane.submit(f.natCreate) { f.results.append($0) }; XCTAssertEqual(f.udpRequests.count, 1); XCTAssertTrue(f.httpRequests.isEmpty); guard case .blocked? = f.results.last?.receipt else { return XCTFail("Lost mutation retried") }
    }
    func testActualPcpErrorLifetimeIsPreserved() {
        let f = Fixture(), assembly = f.assembly(), control = assembly.make(.capability, { true }) { f.receipts.append($0) }
        f.udp(f.reply(code: 13, lifetime: 1810)); XCTAssertEqual(f.receipts, [.capability(.failure("Router capability refused (code 13).", retryAfter: 1810))]); control.cancel()
    }
    func testShutdownDuringRawFactoryCannotAdvanceToAnotherStage() {
        let f = Fixture(), assembly = f.assembly(), lane = f.lane(assembly)
        f.onHTTP = { index in
            guard index == 0 else { return }; lane.shutdown(); f.http(.soap(.fault(code: 714, description: "Absent")), index: 0)
        }
        lane.submit(f.upnpCreate) { f.results.append($0) }; f.onHTTP = nil
        XCTAssertEqual(f.httpRequests.count, 1)
        if f.httpRequests.count > 1 { f.http(.failure("Retired fixture", mutationMayHaveOccurred: false)) }
        XCTAssertEqual(f.results.count, 1); XCTAssertTrue(f.results.first?.retired == true)
    }
    func testDroppingLastControlCancelsAndRetainsReceiptUntilQuiescence() {
        let f = Fixture(), assembly = f.assembly(); var control: RouterMappingTransactions.Control? = assembly.make(.capability, { true }) { f.receipts.append($0) }
        XCTAssertNotNil(control); control = nil; XCTAssertEqual(f.udpCloses, [1]); XCTAssertTrue(f.receipts.isEmpty)
        f.udp(.cancelled(mutationMayHaveOccurred: false)); XCTAssertEqual(f.receipts, [.capability(.cancelled)])
    }
    func testRawTickDeliveryFlowsThroughActualOwnerOnlyOnce() {
        let f = Fixture(), assembly = f.assembly(), control = assembly.make(.capability, { true }) { f.receipts.append($0) }
        f.onUdpTick = { f.udp(f.reply()) }; control.tick(); control.tick(); f.onUdpTick = nil
        XCTAssertEqual(f.receipts, [.capability(.selected(.pcp(f.route, epoch: 100)))]); XCTAssertEqual(f.udpCloses, [1])
    }
}
