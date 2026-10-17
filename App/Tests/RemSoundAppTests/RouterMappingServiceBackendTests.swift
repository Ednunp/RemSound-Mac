import Foundation
import XCTest
import RemSoundRuntime
@testable import RemSoundCore
@testable import RemSoundApp

@MainActor
final class RouterMappingServiceBackendTests: XCTestCase {
    @MainActor private final class Fixture {
        struct Call { let kind: String; let id: UUID?; let port: UInt16?; let duration: UInt32?; let reply: RouterMappingServiceCalls.Reply }
        var calls: [Call] = [], cancels: [Int] = [], now: TimeInterval = 10
        func call(_ kind: String, _ id: UUID? = nil, _ port: UInt16? = nil, _ duration: UInt32? = nil, _ reply: @escaping RouterMappingServiceCalls.Reply) -> RouterMappingServiceCalls.Cancel {
            let index = calls.count; calls.append(.init(kind: kind, id: id, port: port, duration: duration, reply: reply)); cancels.append(0)
            return { self.cancels[index] += 1; return self.cancels[index] == 1 }
        }
        func backend() -> RouterMappingServiceBackend {
            .init(calls: .init(enable: { self.call("enable", nil, nil, nil, $0) },
                              open: { self.call("open", nil, $0, $1, $2) },
                              renew: { self.call("renew", $0, nil, $1, $2) },
                              remove: { self.call("remove", $0, nil, nil, $1) },
                              stop: { self.call("stop", nil, nil, nil, $0) },
                              shutdown: { self.call("shutdown", nil, nil, nil, $0) }), clock: { self.now })
        }
        func mapping(_ id: UUID = UUID(), expires: TimeInterval = 120, observed: TimeInterval = 10) -> RouterMappingService.Mapping {
            .init(id: id, externalAddress: "203.0.113.7", externalPort: 49321, observedAtUptime: observed, expiresAtUptime: expires, epochChanged: true)
        }
        func receipt(_ outcome: RouterMappingService.Outcome = .ready, mapping: RouterMappingService.Mapping? = nil,
                     enabled: Bool = true, closed: Bool = false, unresolved: Bool = false, retry: TimeInterval? = nil) -> RouterMappingService.Receipt {
            .init(requestID: UUID(), outcome: outcome, snapshot: .init(enabled: enabled, closed: closed, mapping: mapping,
                observedAtUptime: now, retryNotBeforeUptime: retry, hasUnresolvedState: unresolved, unresolved: []))
        }
        func reply(_ index: Int, _ value: RouterMappingService.Receipt) { guard calls.indices.contains(index) else { return XCTFail("Missing adapter call") }; calls[index].reply(value) }
    }
    private func settle() async { for _ in 0..<12 { await Task.yield() } }
    private func opened(_ f: Fixture, _ b: RouterMappingServiceBackend) async throws -> RouterMappingLease {
        var result: Result<RouterMappingLease?, Error>?
        _ = b.open(port: 47830, leaseSeconds: 3600) { result = $0 }
        f.reply(0, f.receipt()); await settle()
        let m = f.mapping(); f.reply(1, f.receipt(.mapped(m), mapping: m)); await settle()
        return try XCTUnwrap(try result?.get())
    }
    func testInvalidRequestsRefuseBeforeAnyServiceCall() {
        let f = Fixture(), b = f.backend()
        for (port, duration) in [(UInt16(0), 3600), (47830, 0), (47830, -1), (47830, 604801)] {
            var result: Result<RouterMappingLease?, Error>?
            _ = b.open(port: port, leaseSeconds: duration) { result = $0 }
            XCTAssertThrowsError(try result?.get()); XCTAssertNotNil(result)
        }
        XCTAssertTrue(f.calls.isEmpty)
    }
    func testEnableMustAcknowledgeBeforeHourOpening() async {
        let f = Fixture(), b = f.backend(); var callbacks = 0
        _ = b.open(port: 47830, leaseSeconds: 3600) { _ in callbacks += 1 }
        XCTAssertEqual(f.calls.map(\.kind), ["enable"]); f.reply(0, f.receipt()); await settle()
        XCTAssertEqual(f.calls.map(\.kind), ["enable", "open"]); XCTAssertEqual(f.calls.last?.port, 47830)
        XCTAssertEqual(f.calls.last?.duration, 3600); XCTAssertEqual(callbacks, 0)
        f.reply(1, f.receipt(.unavailable)); await settle(); XCTAssertEqual(callbacks, 1)
    }
    func testRejectedEnableNeverOpensOrInventsEndpoint() async {
        let f = Fixture(), b = f.backend(); var result: Result<RouterMappingLease?, Error>?
        _ = b.open(port: 47830, leaseSeconds: 3600) { result = $0 }
        f.reply(0, f.receipt(.refused, enabled: false)); await settle()
        XCTAssertEqual(f.calls.count, 1); XCTAssertThrowsError(try result?.get()); XCTAssertNotNil(result)
    }
    func testDelayedMappingDeliveryUsesRemainingDeadline() async throws {
        let f = Fixture(), b = f.backend(), lease = try await opened(f, b)
        XCTAssertEqual(lease.validFor, 110); f.now = 119; XCTAssertEqual(lease.validFor, 1)
        f.now = 120; XCTAssertEqual(lease.validFor, 0); f.now = 9; XCTAssertEqual(lease.validFor, 0)
        XCTAssertEqual(lease.externalPort, 49321); XCTAssertEqual(lease.externalAddress, "203.0.113.7")
    }
    func testExpiredReceiptCannotPublishMappedLease() async {
        let f = Fixture(), b = f.backend(); var result: Result<RouterMappingLease?, Error>?
        _ = b.open(port: 47830, leaseSeconds: 3600) { result = $0 }; f.reply(0, f.receipt()); await settle()
        let m = f.mapping(expires: 10); f.reply(1, f.receipt(.mapped(m), mapping: m)); await settle()
        XCTAssertThrowsError(try result?.get()); XCTAssertNotNil(result)
    }
    func testClosedUnresolvedDisabledAndMismatchedSnapshotsRefuseMapping() async {
        for variant in 0..<4 {
            let f = Fixture(), b = f.backend(); var result: Result<RouterMappingLease?, Error>?
            _ = b.open(port: 47830, leaseSeconds: 3600) { result = $0 }; f.reply(0, f.receipt()); await settle()
            let m = f.mapping(); f.reply(1, f.receipt(.mapped(m), mapping: variant == 3 ? f.mapping() : m,
                enabled: variant != 2, closed: variant == 0, unresolved: variant == 1)); await settle()
            XCTAssertThrowsError(try result?.get()); XCTAssertNotNil(result)
        }
    }
    func testNoRouterIsNilOnlyForCleanUnavailableReceipt() async throws {
        let f = Fixture(), b = f.backend(); var result: Result<RouterMappingLease?, Error>?
        _ = b.open(port: 47830, leaseSeconds: 3600) { result = $0 }; f.reply(0, f.receipt()); await settle()
        f.reply(1, f.receipt(.unavailable)); await settle(); XCTAssertNil(try result?.get()); XCTAssertNotNil(result)
    }
    func testRetryDeadlineAndUnresolvedFailureArePreserved() async {
        let f = Fixture(), b = f.backend(); var captured: RouterMappingServiceError?
        _ = b.open(port: 47830, leaseSeconds: 3600) { if case .failure(let error) = $0 { captured = error as? RouterMappingServiceError } }
        f.reply(0, f.receipt()); await settle(); f.reply(1, f.receipt(.failed("PCP retry later"), unresolved: true, retry: 1810)); await settle()
        XCTAssertEqual(captured?.retryNotBeforeUptime, 1810); XCTAssertEqual(captured?.requiresRecovery, true)
        XCTAssertEqual(captured?.localizedDescription, "PCP retry later")
    }
    func testQueuedCancellationNeverIssuesAnotherEnable() async {
        let f = Fixture(), b = f.backend(); var second = 0
        _ = b.open(port: 47830, leaseSeconds: 3600) { _ in }
        let cancel = b.open(port: 47830, leaseSeconds: 3600) { _ in second += 1 }; cancel(); cancel()
        f.reply(0, f.receipt(.refused)); await settle()
        XCTAssertEqual(f.calls.count, 1); XCTAssertEqual(second, 1)
    }
    func testEnableCancellationWaitsReceiptAndDoesNotOpen() async {
        let f = Fixture(), b = f.backend(); var done = 0
        let cancel = b.open(port: 47830, leaseSeconds: 3600) { _ in done += 1 }; cancel(); cancel()
        XCTAssertEqual(f.cancels, [1]); XCTAssertEqual(done, 0)
        f.reply(0, f.receipt()); await settle(); XCTAssertEqual(f.calls.count, 1); XCTAssertEqual(done, 1)
    }
    func testCancellationAfterCoreCompletionRetiresLateHandleBeforeReplacement() async {
        let f = Fixture(), b = f.backend(); var done = 0
        let cancel = b.open(port: 47830, leaseSeconds: 3600) { _ in done += 1 }
        f.reply(0, f.receipt()); await settle(); cancel()
        _ = b.open(port: 47830, leaseSeconds: 3600) { _ in }
        let m = f.mapping(); f.reply(1, f.receipt(.mapped(m), mapping: m)); await settle()
        XCTAssertEqual(f.calls.map(\.kind), ["enable", "open", "remove"]); XCTAssertEqual(f.calls.last?.id, m.id); XCTAssertEqual(done, 0)
        f.reply(2, f.receipt(.removed)); await settle(); XCTAssertEqual(done, 1); XCTAssertEqual(f.calls.last?.kind, "enable")
    }
    func testCompletedCancellationCannotDeleteCurrentLease() async throws {
        let f = Fixture(), b = f.backend(); var result: Result<RouterMappingLease?, Error>?
        let cancel = b.open(port: 47830, leaseSeconds: 3600) { result = $0 }; f.reply(0, f.receipt()); await settle()
        let m = f.mapping(); f.reply(1, f.receipt(.mapped(m), mapping: m)); await settle(); cancel(); cancel()
        XCTAssertEqual(f.calls.count, 2); XCTAssertEqual(try result?.get()?.validFor, 110)
    }
    func testRemovalQuiescencePrecedesNextOpening() async throws {
        let f = Fixture(), b = f.backend(), lease = try await opened(f, b)
        lease.remove(); lease.remove(); _ = b.open(port: 47830, leaseSeconds: 3600) { _ in }
        XCTAssertEqual(f.calls.map(\.kind), ["enable", "open", "remove"]); XCTAssertEqual(lease.validFor, 0)
        f.reply(2, f.receipt(.removed)); await settle(); XCTAssertEqual(f.calls.last?.kind, "enable")
    }
    func testFailedCleanupKeepsSameServiceAndTruthfulLaterRefusal() async throws {
        let f = Fixture(), b = f.backend(), lease = try await opened(f, b); lease.remove()
        f.reply(2, f.receipt(.blocked("matching recovery needed"), unresolved: true)); await settle()
        var result: Result<RouterMappingLease?, Error>?
        _ = b.open(port: 47830, leaseSeconds: 3600) { result = $0 }
        f.reply(3, f.receipt(.ready, unresolved: true)); await settle()
        XCTAssertEqual(f.calls.map(\.kind), ["enable", "open", "remove", "enable"])
        XCTAssertThrowsError(try result?.get()); XCTAssertNotNil(result)
    }
    func testRenewalConsumesUpdatedDeadlineAndOriginalIdentifier() async throws {
        let f = Fixture(), b = f.backend(), lease = try await opened(f, b)
        var duration: TimeInterval?; _ = lease.renew { if case .success(let value) = $0 { duration = value } }
        let id = try XCTUnwrap(f.calls.last?.id); f.now = 30
        let m = f.mapping(id, expires: 80, observed: 20); f.reply(2, f.receipt(.mapped(m), mapping: m)); await settle()
        XCTAssertEqual(duration, 50); f.now = 70; XCTAssertEqual(lease.validFor, 10)
        XCTAssertEqual(f.calls.last?.duration, 3600)
    }
    func testRenewalDifferentIdentifierInvalidatesLocalLeaseWithoutDeletingAnotherHandle() async throws {
        let f = Fixture(), b = f.backend(), lease = try await opened(f, b); var failed = false
        _ = lease.renew { if case .failure = $0 { failed = true } }
        let m = f.mapping(); f.reply(2, f.receipt(.mapped(m), mapping: m)); await settle()
        XCTAssertTrue(failed); XCTAssertEqual(lease.validFor, 0); XCTAssertEqual(f.calls.count, 3)
    }
    func testRetiredLeaseCannotRenewOrRestartExpiry() async throws {
        let f = Fixture(), b = f.backend(), lease = try await opened(f, b); lease.remove()
        f.reply(2, f.receipt(.removed)); await settle(); var failed = false
        _ = lease.renew { if case .failure = $0 { failed = true } }; XCTAssertTrue(failed); XCTAssertEqual(f.calls.count, 3)
        XCTAssertEqual(lease.validFor, 0)
    }
    func testShutdownCancelsWaitsAndClosesExactlyOnce() async {
        let f = Fixture(), b = f.backend(); var done = 0
        _ = b.open(port: 47830, leaseSeconds: 3600) { _ in }; b.shutdown { _ in done += 1 }; b.shutdown { _ in done += 1 }
        XCTAssertEqual(f.calls.count, 1); XCTAssertEqual(f.cancels, [1]); f.reply(0, f.receipt(.cancelled)); await settle()
        XCTAssertEqual(f.calls.map(\.kind), ["enable", "shutdown"]); XCTAssertEqual(done, 0)
        f.reply(1, f.receipt(.ready, enabled: false, closed: true)); await settle(); XCTAssertEqual(done, 2)
        var refused = false; _ = b.open(port: 47830, leaseSeconds: 3600) { if case .failure = $0 { refused = true } }
        XCTAssertTrue(refused); XCTAssertEqual(f.calls.count, 2)
    }
    func testBackendReleaseRetainsPendingReceiptThroughShutdown() async {
        let f = Fixture(); var b: RouterMappingServiceBackend? = f.backend(); weak var released = b
        var done = 0; _ = b?.open(port: 47830, leaseSeconds: 3600) { _ in done += 1 }; b = nil
        XCTAssertNil(released); XCTAssertEqual(f.cancels, [1]); f.reply(0, f.receipt(.cancelled)); await settle()
        XCTAssertEqual(done, 1); XCTAssertEqual(f.calls.last?.kind, "shutdown")
        f.reply(1, f.receipt(.ready, enabled: false, closed: true)); await settle()
    }
    func testOffConstructionMakesNoCallsAndShutdownResultReportsUnresolved() async {
        let f = Fixture(), b = f.backend(); XCTAssertTrue(f.calls.isEmpty); var error: RouterMappingServiceError?
        b.shutdown { if case .failure(let failure) = $0 { error = failure as? RouterMappingServiceError } }
        f.reply(0, f.receipt(.failed("cleanup unresolved"), enabled: false, closed: true, unresolved: true)); await settle()
        XCTAssertEqual(error?.requiresRecovery, true); XCTAssertEqual(error?.localizedDescription, "cleanup unresolved")
    }

    func testDuplicateEnableReceiptCannotStartTwoOpens() async {
        let f = Fixture(), b = f.backend(); var done = 0
        _ = b.open(port: 47830, leaseSeconds: 3600) { _ in done += 1 }
        f.reply(0, f.receipt()); f.reply(0, f.receipt()); await settle()
        XCTAssertEqual(f.calls.map(\.kind), ["enable", "open"])
        f.reply(1, f.receipt(.unavailable)); await settle(); XCTAssertEqual(done, 1)
    }
    func testDuplicateMappedReceiptDoesNotPublishOrDeleteTwice() async {
        let f = Fixture(), b = f.backend(); var done = 0
        let cancel = b.open(port: 47830, leaseSeconds: 3600) { _ in done += 1 }
        f.reply(0, f.receipt()); await settle(); cancel()
        let m = f.mapping(); let receipt = f.receipt(.mapped(m), mapping: m)
        f.reply(1, receipt); f.reply(1, receipt); await settle()
        XCTAssertEqual(f.calls.map(\.kind), ["enable", "open", "remove"]); XCTAssertEqual(done, 0)
        f.reply(2, f.receipt(.removed)); await settle(); XCTAssertEqual(done, 1)
    }
    func testCancelledRenewalLateGrantWaitsExactCleanupAndInvalidatesLease() async throws {
        let f = Fixture(), b = f.backend(), lease = try await opened(f, b); var done = 0
        let cancel = lease.renew { _ in done += 1 }; let id = try XCTUnwrap(f.calls.last?.id); cancel()
        let m = f.mapping(id, expires: 200); f.reply(2, f.receipt(.mapped(m), mapping: m)); await settle()
        XCTAssertEqual(f.calls.map(\.kind), ["enable", "open", "renew", "remove"])
        XCTAssertEqual(f.calls.last?.id, id); XCTAssertEqual(done, 0); XCTAssertEqual(lease.validFor, 0)
        f.reply(3, f.receipt(.removed)); await settle(); XCTAssertEqual(done, 1)
    }
    func testCancelledRenewalCoreCleanupReceiptCannotLeaveLiveLease() async throws {
        let f = Fixture(), b = f.backend(), lease = try await opened(f, b); var done = 0
        let cancel = lease.renew { _ in done += 1 }; cancel(); f.reply(2, f.receipt(.cancelled)); await settle()
        XCTAssertEqual(done, 1); XCTAssertEqual(lease.validFor, 0); XCTAssertEqual(f.calls.count, 3)
    }
    func testRemoveWhileRenewingWaitsRenewalReceiptAndReportsNoLateSuccess() async throws {
        let f = Fixture(), b = f.backend(), lease = try await opened(f, b); var succeeded = false
        _ = lease.renew { if case .success = $0 { succeeded = true } }; let id = try XCTUnwrap(f.calls.last?.id)
        lease.remove(); XCTAssertEqual(f.calls.count, 3)
        let m = f.mapping(id, expires: 200); f.reply(2, f.receipt(.mapped(m), mapping: m)); await settle()
        XCTAssertFalse(succeeded); XCTAssertEqual(f.calls.last?.kind, "remove"); XCTAssertEqual(lease.validFor, 0)
        f.reply(3, f.receipt(.removed)); await settle()
    }
    func testUnresolvedRenewalRetiresLocalLeaseWithoutInventingDeletion() async throws {
        let f = Fixture(), b = f.backend(), lease = try await opened(f, b); var captured: RouterMappingServiceError?
        _ = lease.renew { if case .failure(let error) = $0 { captured = error as? RouterMappingServiceError } }
        f.reply(2, f.receipt(.failed("renewal uncertain"), unresolved: true, retry: 1810)); await settle()
        XCTAssertEqual(lease.validFor, 0); XCTAssertEqual(captured?.retryNotBeforeUptime, 1810)
        XCTAssertEqual(captured?.requiresRecovery, true); XCTAssertEqual(f.calls.count, 3)
    }
    func testPublicNativeIsolatedFacadeRefusesThroughActualAdapterOnMain() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]!).appendingPathComponent("router-adapter-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try RuntimeConfiguration(options: LaunchOptions.parse(["--config-dir", root.path, "--headless", "--silent"]))
        let service = RouterMappingService(configuration: runtime), b = RouterMappingServiceBackend(service: service)
        let done = expectation(description: "native isolated refusal")
        _ = b.open(port: 47830, leaseSeconds: 3600) { result in
            XCTAssertTrue(Thread.isMainThread); if case .success = result { XCTFail("Expected isolated refusal") }; done.fulfill()
        }
        await fulfillment(of: [done], timeout: 3)
        let closed = expectation(description: "native facade shutdown")
        b.shutdown { result in XCTAssertTrue(Thread.isMainThread); if case .failure(let error) = result { XCTFail(error.localizedDescription) }; closed.fulfill() }
        await fulfillment(of: [closed], timeout: 3)
    }
    func testBackgroundValueReplyIsMarshalledToMainActor() async {
        let f = Fixture(), b = f.backend(), done = expectation(description: "main value delivery")
        _ = b.open(port: 47830, leaseSeconds: 3600) { _ in XCTAssertTrue(Thread.isMainThread); done.fulfill() }
        let reply = f.calls[0].reply, value = f.receipt(.refused)
        DispatchQueue.global().async { reply(value) }
        await fulfillment(of: [done], timeout: 3); XCTAssertEqual(f.calls.count, 1)
    }

    func testCancelledRenewalWithQueuedRemovalDeletesOnceAfterQuiescence() async throws {
        let f = Fixture(), b = f.backend(), lease = try await opened(f, b); var done = 0
        let cancel = lease.renew { _ in done += 1 }; let id = try XCTUnwrap(f.calls.last?.id)
        lease.remove(); cancel(); let m = f.mapping(id, expires: 200)
        f.reply(2, f.receipt(.mapped(m), mapping: m)); await settle()
        XCTAssertEqual(f.calls.map(\.kind), ["enable", "open", "renew", "remove"]); XCTAssertEqual(done, 0)
        f.reply(3, f.receipt(.removed)); await settle(); XCTAssertEqual(done, 1); XCTAssertEqual(f.calls.count, 4)
        lease.remove(); XCTAssertEqual(f.calls.count, 4)
    }
    func testRealFacadeMockProtocolChainUsesOneBookAndMainLeaseCallbacks() async throws {
        let route = RouterGatewayRoute(gateway: Endpoint("192.0.2.1", 5351), sourceAddress: "192.0.2.10", interface: "fixture")
        var raw: RouterUDPMapping.Outcome?
        let creator = RouterUDPMapping(intent: .create(.natPmp(route, externalAddress: "203.0.113.7", epoch: 100), internalPort: 47830, lifetime: 3600),
            permitted: { true }, clock: { 0 }, exchange: { _, route, reply in
                reply(.response(.init(resultCode: 0, internalPort: 47830, externalPort: 49321, lifetime: 120, epoch: 100, externalAddress: nil), route)); return {}
            }, completion: { raw = $0 }); creator.start()
        guard case let .granted(rawLease, _, _)? = raw else { return XCTFail("Missing mock protocol lease") }
        let queue = DispatchQueue(label: "router.adapter.core.fixture"), key = DispatchSpecificKey<Int>()
        queue.setSpecific(key: key, value: 1); var commands: [String] = []
        let service = RouterMappingService(queue: queue, callbackQueue: .main, allowed: { true }, clock: { 10 }, factory: { operation, gate, reply in
            XCTAssertEqual(DispatchQueue.getSpecific(key: key), 1); XCTAssertTrue(gate())
            switch operation {
            case .capability: commands.append("capability"); reply(.capability(.selected(.natPmp(route, externalAddress: "203.0.113.7", epoch: 100))))
            case .udp(.create): commands.append("create"); reply(.udp(.granted(rawLease, retired: false, epochChanged: false)))
            case .udp(.renew): commands.append("renew"); reply(.udp(.granted(rawLease, retired: false, epochChanged: true)))
            case .udp(.remove): commands.append("remove"); reply(.udp(.removed(retired: false)))
            default: XCTFail("Unexpected adapter command"); reply(.refused)
            }
            return .init(tick: {}, cancel: {})
        })
        let b = RouterMappingServiceBackend(service: service, clock: { 10 }), opened = expectation(description: "actual Core open")
        var lease: RouterMappingLease?
        _ = b.open(port: 47830, leaseSeconds: 3600) { result in
            XCTAssertTrue(Thread.isMainThread); if case .success(let value) = result { lease = value } else { XCTFail("Core open failed") }; opened.fulfill()
        }
        await fulfillment(of: [opened], timeout: 3); let first = try XCTUnwrap(lease); XCTAssertEqual(first.validFor, 110)
        let renewed = expectation(description: "actual Core renew")
        _ = first.renew { result in XCTAssertTrue(Thread.isMainThread); if case .success(let duration) = result { XCTAssertEqual(duration, 110) } else { XCTFail("Core renew failed") }; renewed.fulfill() }
        await fulfillment(of: [renewed], timeout: 3)
        first.remove(); let replaced = expectation(description: "replacement follows exact Core removal")
        _ = b.open(port: 47830, leaseSeconds: 3600) { result in if case .failure = result { XCTFail("Replacement failed") }; replaced.fulfill() }
        await fulfillment(of: [replaced], timeout: 3)
        XCTAssertEqual(queue.sync { commands }, ["capability", "create", "renew", "remove", "capability", "create"])
        let closed = expectation(description: "actual Core shutdown")
        b.shutdown { result in if case .failure = result { XCTFail("Core shutdown failed") }; closed.fulfill() }
        await fulfillment(of: [closed], timeout: 3); XCTAssertEqual(queue.sync { commands.last }, "remove")
    }

    func testAlreadyRetiredHandleRemovalWaitsFreshSerializedStopProof() async throws {
        let f = Fixture(), b = f.backend(), lease = try await opened(f, b)
        lease.remove(); f.reply(2, f.receipt(.refused)); await settle()
        _ = b.open(port: 47830, leaseSeconds: 3600) { _ in }
        XCTAssertEqual(f.calls.map(\.kind), ["enable", "open", "remove", "stop"])
        f.reply(3, f.receipt(.ready)); await settle(); XCTAssertEqual(f.calls.last?.kind, "enable")
        XCTAssertEqual(lease.validFor, 0)
    }
    func testRefusedDeletionWithUnresolvedStateNeverAttemptsStopOrClaimsAbsent() async throws {
        let f = Fixture(), b = f.backend(), lease = try await opened(f, b)
        lease.remove(); f.reply(2, f.receipt(.refused, unresolved: true)); await settle()
        XCTAssertEqual(f.calls.map(\.kind), ["enable", "open", "remove"]); XCTAssertEqual(lease.validFor, 0)
        _ = b.open(port: 47830, leaseSeconds: 3600) { _ in }; f.reply(3, f.receipt(.ready, unresolved: true)); await settle()
        XCTAssertEqual(f.calls.count, 4)
    }
}
