import Foundation
import XCTest
@testable import RemSoundCore

final class UPnPMappingCreationTests: XCTestCase {
    private final class Fixture {
        var now: TimeInterval = 0, permitted = true, tokenCalls = 0, cancels = 0
        var token: String? = "RemSound-fixture-0123456789"
        let route = RouterGatewayRoute(gateway: Endpoint("192.0.2.1", 5351), sourceAddress: "192.0.2.10", interface: "fixture")
        var service: UPnPRouterService { .init(kind: .ip2, controlURL: URL(string: "http://192.0.2.1/control")!, gatewayAddress: "192.0.2.1") }
        var requests: [RouterHTTPTransport.Request] = [], budgets: [TimeInterval] = []
        var callbacks: [(RouterHTTPTransport.Outcome) -> Void] = [], results: [UPnPMappingCreation.Outcome] = []
        func operation(port: UInt16 = 47830, lifetime: UInt32 = 3600) -> UPnPMappingCreation {
            UPnPMappingCreation(route: route, service: service, internalPort: port, lifetime: lifetime, permitted: { self.permitted }, clock: { self.now }, token: { self.tokenCalls += 1; return self.token }, http: { request, budget, completion in self.requests.append(request); self.budgets.append(budget); self.callbacks.append(completion); return { self.cancels += 1 } }, completion: { self.results.append($0) })
        }
        func reply(_ value: RouterHTTPTransport.Outcome, index: Int? = nil) {
            let index = index ?? (callbacks.count - 1)
            guard callbacks.indices.contains(index) else { XCTFail("Expected HTTP callback"); return }; callbacks[index](value)
        }
        func toAdd() {
            reply(.soap(.fault(code: 714, description: "No entry")))
            reply(.soap(.success(externalAddress: "203.0.113.7")))
        }
        func mapping(token: String? = nil, port: UInt16 = 47830, client: String = "192.0.2.10", enabled: Bool = true, lifetime: UInt32 = 120) -> UPnPPortMapping {
            .init(internalPort: port, internalClient: client, enabled: enabled, description: token ?? self.token ?? "", leaseSeconds: lifetime)
        }
    }
    func testOffRefusesBeforeTokenOrHttpFactory() {
        let f = Fixture(); f.permitted = false; let operation = f.operation(); operation.start(); operation.cancel()
        XCTAssertEqual(f.results, [.refused]); XCTAssertTrue(f.requests.isEmpty); XCTAssertEqual(f.tokenCalls, 0)
    }
    func testInvalidPortLifetimeAndTokenNeverConstructHttp() {
        for (port, life): (UInt16, UInt32) in [(0, 3600), (47830, 0), (47830, 604801)] {
            let f = Fixture(), operation = f.operation(port: port, lifetime: life); operation.start()
            XCTAssertTrue(f.requests.isEmpty); guard case .failure? = f.results.first else { XCTFail("Invalid request must fail"); continue }
        }
        for token: String? in [nil, "", "manual", "RemSound-<bad>", String(repeating: "x", count: 65)] {
            let f = Fixture(); f.token = token; let operation = f.operation(); operation.start(); XCTAssertTrue(f.requests.isEmpty)
            guard case .failure? = f.results.first else { XCTFail("Invalid generated token must fail"); continue }
        }
    }
    func testForeignServiceIsRejectedBeforeFactory() {
        let f = Fixture(), foreign = UPnPRouterService(kind: .ip2, controlURL: URL(string: "http://192.0.2.2/control")!, gatewayAddress: "192.0.2.1")
        let operation = UPnPMappingCreation(route: f.route, service: foreign, internalPort: 47830, lifetime: 3600, permitted: { true }, clock: { f.now }, http: { _, _, _ in XCTFail("Foreign URL sent"); return {} }, completion: { f.results.append($0) })
        operation.start(); guard case .failure? = f.results.first else { return XCTFail("Wrong origin must fail") }
    }
    func testNativeTokenHasBoundedUniqueRandomSuffix() throws {
        let a = try XCTUnwrap(UPnPMappingCreation.secureToken()), b = try XCTUnwrap(UPnPMappingCreation.secureToken())
        XCTAssertTrue(a.hasPrefix("RemSound-")); XCTAssertEqual(a.count, 33); XCTAssertNotEqual(a, b)
    }
    func testCreationOrderAndTokenPropagationUseExactUdpTuple() {
        let f = Fixture(), operation = f.operation(); operation.start(); operation.start(); f.toAdd()
        XCTAssertEqual(f.requests.map(\.action), [.specificMapping, .externalIP, .add])
        let body = f.requests.last?.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
        XCTAssertTrue(body.contains("<NewInternalPort>47830</NewInternalPort><NewInternalClient>192.0.2.10</NewInternalClient>"))
        XCTAssertTrue(body.contains("<NewPortMappingDescription>\(f.token!)</NewPortMappingDescription>")); XCTAssertTrue(body.contains("<NewLeaseDuration>3600</NewLeaseDuration>")); XCTAssertEqual(f.tokenCalls, 1)
    }
    func testEveryExistingRuleRefusesAddIncludingMatchingClientAndRemSoundLabel() {
        for label in ["Manual rule", "RemSound audio", "RemSound-fixture-0123456789"] {
            let f = Fixture(), operation = f.operation(); operation.start(); f.reply(.soap(.mapping(f.mapping(token: label))))
            XCTAssertEqual(f.results, [.occupied]); XCTAssertEqual(f.requests.map(\.action), [.specificMapping])
        }
    }
    func testOnly714PermitsCreationAndOtherFaultsFailClosed() {
        for code: UInt16 in [401, 606, 718, 725] {
            let f = Fixture(), operation = f.operation(); operation.start(); f.reply(.soap(.fault(code: code, description: "Refused")))
            XCTAssertEqual(f.requests.count, 1); guard case .failure? = f.results.first else { XCTFail("Refusal must fail closed"); continue }
        }
    }
    func testInvalidExternalAddressCannotReachAdd() {
        let f = Fixture(), operation = f.operation(); operation.start(); f.reply(.soap(.fault(code: 714, description: "No entry"))); f.reply(.soap(.success(externalAddress: "router.invalid")))
        XCTAssertEqual(f.requests.count, 2); guard case .failure? = f.results.first else { return XCTFail("Invalid address must fail") }
    }
    func testMatchingReadbackReturnsActualGrantAndConservativeExpiry() {
        let f = Fixture(), operation = f.operation(); operation.start(); f.now = 1; f.toAdd(); f.now = 2; f.reply(.soap(.success(externalAddress: nil))); f.now = 3; f.reply(.soap(.mapping(f.mapping())))
        guard case .granted(let lease, retired: false)? = f.results.first else { return XCTFail("Expected verified grant") }
        XCTAssertEqual(lease.lifetime, 120); XCTAssertEqual(lease.validUntil, 121); XCTAssertEqual(lease.claim.token, f.token); XCTAssertEqual(lease.claim.externalPort, 47830); XCTAssertEqual(lease.claim.externalAddress, "203.0.113.7"); XCTAssertEqual(f.cancels, 4)
    }
    func testChangedOrPermanentReadbackKeepsAcknowledgedClaimWithoutLease() {
        for mapping in [Fixture().mapping(token: "Replacement"), Fixture().mapping(port: 47831), Fixture().mapping(client: "192.0.2.11"), Fixture().mapping(enabled: false), Fixture().mapping(lifetime: 0), Fixture().mapping(lifetime: UInt32.max)] {
            let f = Fixture(), operation = f.operation(); operation.start(); f.toAdd(); f.reply(.soap(.success(externalAddress: nil))); f.reply(.soap(.mapping(mapping)))
            guard case .acknowledged(let claim, retired: false, _)? = f.results.first else { XCTFail("Unverified or changed rule cannot become lease"); continue }
            XCTAssertEqual(claim.token, f.token); XCTAssertEqual(f.requests.count, 4)
        }
    }
    func testReadbackFailureAfterAcceptedAddDoesNotLoseCleanupClaim() {
        let f = Fixture(), operation = f.operation(); operation.start(); f.toAdd(); f.reply(.soap(.success(externalAddress: nil))); f.reply(.failure("Readback lost", mutationMayHaveOccurred: false))
        guard case .acknowledged(let claim, _, _)? = f.results.first else { return XCTFail("Acknowledged Add must retain exact claim") }
        XCTAssertEqual(claim.internalPort, 47830); XCTAssertEqual(claim.token, f.token)
    }
    func testCancelledAddAcknowledgmentReturnsClaimAndDoesNotStartReadback() {
        let f = Fixture(), operation = f.operation(); operation.start(); f.toAdd(); operation.cancel(); operation.cancel()
        XCTAssertTrue(f.results.isEmpty); XCTAssertEqual(f.cancels, 3); f.reply(.soap(.success(externalAddress: nil)))
        guard case .acknowledged(_, retired: true, _)? = f.results.first else { return XCTFail("Late accepted Add must reach cleanup owner") }
        XCTAssertEqual(f.requests.count, 3)
    }
    func testLostAddReplyRemainsUncertainAndNeverStartsAnotherMutation() {
        let f = Fixture(), operation = f.operation(); operation.start(); f.toAdd(); operation.cancel(); f.reply(.failure("Lost Add", mutationMayHaveOccurred: true))
        guard case .uncertain(let claim, _)? = f.results.first else { return XCTFail("Lost Add must remain uncertain") }
        XCTAssertEqual(claim.token, f.token); XCTAssertEqual(f.requests.count, 3)
    }
    func testPreflightCancelWaitsForCloseThenNoAdd() {
        let f = Fixture(), operation = f.operation(); operation.start(); operation.cancel(); XCTAssertTrue(f.results.isEmpty); XCTAssertEqual(f.cancels, 1)
        f.reply(.soap(.fault(code: 714, description: "No entry"))); XCTAssertEqual(f.results, [.cancelled]); XCTAssertEqual(f.requests.count, 1)
    }
    func testPermissionLossDuringReadbackReturnsRetiredVerifiedLease() {
        let f = Fixture(), operation = f.operation(); operation.start(); f.toAdd(); f.reply(.soap(.success(externalAddress: nil))); f.permitted = false; operation.tick(); f.reply(.soap(.mapping(f.mapping())))
        guard case .granted(_, retired: true)? = f.results.first else { return XCTFail("Verified late state must survive permission retirement") }
    }
    func testOverallDeadlineSharesRemainingHttpBudgetAndRetainsLateAdd() {
        let f = Fixture(), operation = f.operation(); operation.start(); f.now = 2; f.reply(.soap(.fault(code: 714, description: "No entry"))); f.now = 3; f.reply(.soap(.success(externalAddress: "203.0.113.7")))
        XCTAssertEqual(f.budgets, [8, 6, 5]); f.now = 8; operation.tick(); XCTAssertTrue(f.results.isEmpty); f.reply(.soap(.success(externalAddress: nil)))
        guard case .acknowledged(_, retired: true, _)? = f.results.first else { return XCTFail("Expired operation must retain known mutation") }
    }
    func testDuplicateAndPreviousStageResponsesCannotAdvanceOrRepeatAdd() {
        let f = Fixture(), operation = f.operation(); operation.start(); f.toAdd(); f.reply(.soap(.fault(code: 714, description: "Old callback")), index: 0)
        XCTAssertEqual(f.requests.count, 3); f.reply(.soap(.success(externalAddress: nil)), index: 2); f.reply(.soap(.success(externalAddress: nil)), index: 2)
        XCTAssertEqual(f.requests.count, 4); f.reply(.soap(.mapping(f.mapping()))); XCTAssertEqual(f.results.count, 1)
    }
    func testReleaseDuringAddStillReturnsAcceptedClaimAfterQuiescence() {
        let f = Fixture(); var operation: UPnPMappingCreation? = f.operation(); operation?.start(); f.toAdd(); weak var released = operation; operation = nil
        XCTAssertNil(released); XCTAssertEqual(f.cancels, 3); f.reply(.soap(.success(externalAddress: nil)))
        guard case .acknowledged(_, retired: true, _)? = f.results.first else { return XCTFail("Released owner lost mutation") }
    }
    func testSynchronousPreflightResponseCleansReturnedResource() {
        let f = Fixture(), operation = UPnPMappingCreation(route: f.route, service: f.service, internalPort: 47830, lifetime: 3600, permitted: { true }, clock: { f.now }, token: { f.token }, http: { _, _, reply in reply(.soap(.mapping(f.mapping()))); return { f.cancels += 1 } }, completion: { f.results.append($0) })
        operation.start(); XCTAssertEqual(f.results, [.occupied]); XCTAssertEqual(f.cancels, 1)
    }
    func testNoPermanentFallbackOnLegacyAddRefusal() {
        let f = Fixture(), operation = f.operation(); operation.start(); f.toAdd(); f.reply(.soap(.fault(code: 725, description: "OnlyPermanentLeasesSupported")))
        guard case .failure? = f.results.first else { return XCTFail("Permanent-only router must be refused") }
        XCTAssertEqual(f.requests.count, 3)
    }
    func testPermissionChangedDuringTokenPreparationCannotSend() {
        let f = Fixture(), operation = UPnPMappingCreation(route: f.route, service: f.service, internalPort: 47830, lifetime: 3600, permitted: { f.permitted }, clock: { f.now }, token: { f.permitted = false; return f.token }, http: { _, _, _ in XCTFail("Retired prepared request sent"); return {} }, completion: { f.results.append($0) })
        operation.start(); XCTAssertEqual(f.results, [.refused])
    }
    func testAddNeverStartsIfPreflightConsumesOverallDeadline() {
        let f = Fixture(), operation = f.operation(); operation.start(); f.now = 8; f.reply(.soap(.fault(code: 714, description: "No entry")))
        XCTAssertEqual(f.results, [.timedOut]); XCTAssertEqual(f.requests.count, 1)
    }
}
