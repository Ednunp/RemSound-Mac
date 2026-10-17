import Foundation
import RemSoundRuntime
import XCTest
@testable import RemSoundCore

final class RouterMappingServiceTests: XCTestCase {
    private final class Fixture {
        let owner = DispatchQueue(label: "router.service.fixture"), callbacks = DispatchQueue(label: "router.service.receipts")
        let ownerKey = DispatchSpecificKey<Int>(), callbackKey = DispatchSpecificKey<Int>()
        let route = RouterGatewayRoute(gateway: Endpoint("192.0.2.1", 5351), sourceAddress: "192.0.2.10", interface: "fixture")
        var now: TimeInterval = 2, allowed = true, wrongOwner = 0, wrongCallback = 0
        var operations: [RouterMappingTransactions.Operation] = [], replies: [(RouterMappingTransactions.Receipt) -> Void] = [], gates: [() -> Bool] = [], cancels: [Int] = []
        var receipts: [RouterMappingService.Receipt] = []
        var onFactory: ((Int) -> Void)?
        var onClock: (() -> Void)?
        init() { owner.setSpecific(key: ownerKey, value: 1); callbacks.setSpecific(key: callbackKey, value: 1) }
        var factory: RouterMappingTransactions.Factory {
            { operation, gate, reply in
                if DispatchQueue.getSpecific(key: self.ownerKey) != 1 { self.wrongOwner += 1 }
                XCTAssertTrue(gate()); let i = self.operations.count
                self.operations.append(operation); self.replies.append(reply); self.gates.append(gate); self.cancels.append(0); self.onFactory?(i)
                return .init(tick: {}, cancel: { self.cancels[i] += 1 })
            }
        }
        func service() -> RouterMappingService {
            .init(queue: owner, callbackQueue: callbacks, allowed: { self.allowed }, clock: { self.onClock?(); return self.now }, factory: factory)
        }
        func receive(_ value: RouterMappingService.Receipt) {
            if DispatchQueue.getSpecific(key: callbackKey) != 1 { wrongCallback += 1 }; receipts.append(value)
        }
        func flush() { for _ in 0..<3 { owner.sync {}; callbacks.sync {} } }
        func reply(_ value: RouterMappingTransactions.Receipt, _ i: Int? = nil) {
            owner.sync { let i = i ?? replies.count - 1; guard replies.indices.contains(i) else { return XCTFail("Missing service operation") }; replies[i](value) }; flush()
        }
        func enable(_ s: RouterMappingService) { s.setEnabled(true, completion: receive); flush() }
        func select() { reply(.capability(.selected(.natPmp(route, externalAddress: "203.0.113.7", epoch: 100)))) }
        func lease() throws -> RouterUDPMapping.Lease {
            var result: RouterUDPMapping.Outcome?
            let o = RouterUDPMapping(intent: .create(.natPmp(route, externalAddress: "203.0.113.7", epoch: 100), internalPort: 47830, lifetime: 3600), permitted: { true }, clock: { 0 }, exchange: { _, route, reply in
                reply(.response(.init(resultCode: 0, internalPort: 47830, externalPort: 49321, lifetime: 120, epoch: 100, externalAddress: nil), route)); return {}
            }, completion: { result = $0 }); o.start()
            guard case .granted(let lease, _, _)? = result else { throw NSError(domain: "Missing lease", code: 1) }; return lease
        }
        func open(_ s: RouterMappingService) throws -> (RouterMappingService.Request, RouterMappingService.Mapping) {
            enable(s); let request = s.open(port: 47830, completion: receive); flush(); select(); reply(.udp(.granted(try lease(), retired: false, epochChanged: false)))
            return (request, try XCTUnwrap(receipts.last?.snapshot.mapping))
        }
    }
    func testDefaultOffAndExplicitChoiceWithoutOpeningConstructNothing() {
        let f = Fixture(), s = f.service(); s.open(port: 47830, completion: f.receive); f.flush()
        XCTAssertTrue(f.operations.isEmpty); XCTAssertEqual(f.receipts.first?.outcome, .refused)
        f.enable(s); XCTAssertTrue(f.operations.isEmpty); XCTAssertTrue(f.receipts.last?.snapshot.enabled == true)
        s.setEnabled(false, completion: f.receive); f.flush(); XCTAssertFalse(f.receipts.last?.snapshot.enabled ?? true)
    }
    func testOwnerAndCallbackQueuesReceiveImmutableValueOnlyGrant() throws {
        let f = Fixture(), s = f.service(), (request, mapping) = try f.open(s)
        XCTAssertEqual(f.receipts.last?.requestID, request.id); XCTAssertEqual(mapping.externalAddress, "203.0.113.7"); XCTAssertEqual(mapping.externalPort, 49321)
        XCTAssertEqual(mapping.expiresAtUptime, 120); XCTAssertEqual(mapping.remainingLifetime(at: 6), 114); XCTAssertEqual(mapping.remainingLifetime(at: -1), 0)
        XCTAssertEqual(f.wrongOwner, 0); XCTAssertEqual(f.wrongCallback, 0)
    }
    func testQueuedCancelledRequestCannotConstructAfterEnable() {
        let f = Fixture(), s = f.service(); f.enable(s)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        f.owner.async { entered.signal(); _ = release.wait(timeout: .now() + 3) }; XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        let request = s.open(port: 47830, completion: f.receive); request.cancel(); release.signal(); f.flush()
        XCTAssertTrue(f.operations.isEmpty); XCTAssertEqual(f.receipts.last?.requestID, request.id); XCTAssertEqual(f.receipts.last?.outcome, .cancelled)
    }
    func testCancelledActiveRequestWaitsForQuiescentReceipt() {
        let f = Fixture(), s = f.service(); f.enable(s); let r = s.open(port: 47830, completion: f.receive); f.flush()
        r.cancel(); r.cancel(); f.flush(); XCTAssertEqual(f.cancels, [1]); XCTAssertEqual(f.receipts.count, 1)
        f.reply(.capability(.cancelled)); XCTAssertEqual(f.receipts.count, 2); XCTAssertEqual(f.receipts.last?.outcome, .cancelled)
    }
    func testCompletedTicketCancellationCannotDeleteItsMappingOrNewestWork() throws {
        let f = Fixture(), s = f.service(), (ticket, mapping) = try f.open(s), n = f.operations.count
        XCTAssertFalse(ticket.cancel()); f.flush(); XCTAssertEqual(f.operations.count, n)
        s.snapshot(completion: f.receive); f.flush(); XCTAssertEqual(f.receipts.last?.snapshot.mapping?.id, mapping.id)
    }
    func testNewestOpeningRequestRetiresOldAndReportsOnce() {
        let f = Fixture(), s = f.service(); f.enable(s)
        let old = s.open(port: 47830, completion: f.receive); f.flush(); let newest = s.open(port: 47831, completion: f.receive); f.flush()
        f.reply(.capability(.selected(.natPmp(f.route, externalAddress: "203.0.113.7", epoch: 100))), 0)
        XCTAssertEqual(f.operations.count, 2); guard case .capability? = f.operations.last else { return XCTFail("Old request started mapping") }
        XCTAssertEqual(f.receipts.last?.requestID, old.id); XCTAssertEqual(f.receipts.last?.outcome, .cancelled)
        newest.cancel(); f.flush(); f.reply(.capability(.cancelled))
    }
    func testLateGrantIsCleanedBeforeCancelledCallbackAndNextOpen() throws {
        let f = Fixture(), s = f.service(); f.enable(s); let old = s.open(port: 47830, completion: f.receive); f.flush(); f.select()
        old.cancel(); f.flush(); f.reply(.udp(.granted(try f.lease(), retired: true, epochChanged: false)))
        XCTAssertEqual(f.receipts.count, 1); guard case .udp(.remove)? = f.operations.last else { return XCTFail("Late cleanup missing") }
        f.reply(.udp(.removed(retired: false))); XCTAssertEqual(f.receipts.last?.outcome, .cancelled); XCTAssertNil(f.receipts.last?.snapshot.mapping)
    }
    func testDisableStopsOwnedMappingWithoutNewFactoryAndWaitsForRemoval() throws {
        let f = Fixture(), s = f.service(); _ = try f.open(s)
        let disabled = s.setEnabled(false, completion: f.receive); f.flush()
        guard case .udp(.remove)? = f.operations.last else { return XCTFail("Disable did not remove owned mapping") }
        XCTAssertEqual(f.receipts.count, 2); f.reply(.udp(.removed(retired: false)))
        XCTAssertEqual(f.receipts.last?.requestID, disabled.id); XCTAssertEqual(f.receipts.last?.outcome, .removed); XCTAssertFalse(f.receipts.last?.snapshot.enabled ?? true)
        s.open(port: 47830, completion: f.receive); f.flush(); XCTAssertEqual(f.operations.count, 3)
    }
    func testRenewKeepsIdentifierAndAbsoluteDeadlineAndEpoch() throws {
        let f = Fixture(), s = f.service(), (_, mapping) = try f.open(s)
        s.renew(mapping.id, completion: f.receive); f.flush(); f.owner.sync { f.now = 6 }; f.reply(.udp(.granted(try f.lease(), retired: false, epochChanged: true)))
        let renewed = try XCTUnwrap(f.receipts.last?.snapshot.mapping); XCTAssertEqual(renewed.id, mapping.id); XCTAssertEqual(renewed.expiresAtUptime, 120); XCTAssertTrue(renewed.epochChanged)
        XCTAssertEqual(renewed.remainingLifetime(at: 20), 100)
    }
    func testPCPBackoffIsAbsoluteAndNotRestartedByCallbackDelay() {
        let f = Fixture(), s = f.service(); f.enable(s); s.open(port: 47830, completion: f.receive); f.flush()
        f.reply(.capability(.failure("Quota", retryAfter: 1800))); XCTAssertEqual(f.receipts.last?.snapshot.retryNotBeforeUptime, 1802)
        s.open(port: 47830, completion: f.receive); f.flush(); XCTAssertEqual(f.operations.count, 1)
    }
    func testMatchingRecoveryExposesOnlyIDsAndClearsSameBook() throws {
        let f = Fixture(), s = f.service(); _ = try f.open(s); s.stop(completion: f.receive); f.flush(); f.reply(.udp(.expired))
        let evidence = try XCTUnwrap(f.receipts.last?.snapshot.unresolved.first); XCTAssertTrue(evidence.canRecover)
        s.recover(evidence.id, completion: f.receive); f.flush(); f.reply(.udp(.removed(retired: false)))
        XCTAssertEqual(f.receipts.last?.outcome, .removed); XCTAssertFalse(f.receipts.last?.snapshot.hasUnresolvedState ?? true); XCTAssertTrue(f.receipts.last?.snapshot.unresolved.isEmpty == true)
    }
    func testUnknownCreationStaysBlockedWithoutForgedCleanup() throws {
        let f = Fixture(), s = f.service(); f.enable(s); s.open(port: 47830, completion: f.receive); f.flush(); f.select(); f.reply(.udp(.timedOut(mutationMayHaveOccurred: true)))
        let e = try XCTUnwrap(f.receipts.last?.snapshot.unresolved.first); XCTAssertFalse(e.canRecover)
        let n = f.operations.count; s.recover(e.id, completion: f.receive); s.open(port: 47830, completion: f.receive); f.flush(); XCTAssertEqual(f.operations.count, n)
    }
    func testStaleMappingIdentifierCannotRemoveReplacement() throws {
        let f = Fixture(), s = f.service(), (_, mapping) = try f.open(s)
        s.remove(mapping.id, completion: f.receive); f.flush(); f.reply(.udp(.removed(retired: false)))
        let (_, second) = try f.open(s), n = f.operations.count
        s.remove(mapping.id, completion: f.receive); f.flush(); XCTAssertEqual(f.operations.count, n); XCTAssertEqual(f.receipts.last?.snapshot.mapping?.id, second.id)
    }
    func testWakeRechecksCapabilityOnlyAfterExactOldCleanup() throws {
        let f = Fixture(), s = f.service(); _ = try f.open(s); let wake = s.wake(completion: f.receive); f.flush()
        guard case .udp(.remove)? = f.operations.last else { return XCTFail("Wake skipped cleanup") }
        f.reply(.udp(.removed(retired: false))); guard case .capability? = f.operations.last else { return XCTFail("Wake did not recheck") }
        wake.cancel(); f.flush(); f.reply(.capability(.cancelled))
    }
    func testShutdownWaitsForExactRemovalAndRejectsFurtherConstruction() throws {
        let f = Fixture(), s = f.service(); _ = try f.open(s); let close = s.shutdown(completion: f.receive); f.flush()
        XCTAssertEqual(f.receipts.count, 2); f.reply(.udp(.removed(retired: false))); XCTAssertEqual(f.receipts.last?.requestID, close.id); XCTAssertTrue(f.receipts.last?.snapshot.closed == true)
        let n = f.operations.count; s.open(port: 47830, completion: f.receive); s.setEnabled(true, completion: f.receive); f.flush(); XCTAssertEqual(f.operations.count, n)
    }
    func testWrapperReleaseRetainsLateCleanupAndCallback() throws {
        let f = Fixture(); var s: RouterMappingService? = f.service(); f.enable(s!); s?.open(port: 47830, completion: f.receive); f.flush(); f.select()
        weak var weakService = s; s = nil; f.flush(); XCTAssertNil(weakService)
        f.reply(.udp(.granted(try f.lease(), retired: true, epochChanged: false))); XCTAssertEqual(f.receipts.count, 1)
        f.reply(.udp(.removed(retired: false))); XCTAssertEqual(f.receipts.last?.outcome, .cancelled); XCTAssertTrue(f.receipts.last?.snapshot.closed == true)
    }
    func testSnapshotIsQueueOwnedAndDoesNotCancelActiveRequest() {
        let f = Fixture(), s = f.service(); f.enable(s); let open = s.open(port: 47830, completion: f.receive); f.flush()
        s.snapshot(completion: f.receive); f.flush(); XCTAssertEqual(f.cancels, [0]); XCTAssertEqual(f.operations.count, 1); XCTAssertEqual(f.receipts.last?.outcome, .ready)
        open.cancel(); f.flush(); f.reply(.capability(.cancelled))
    }
    func testSynchronousFactoryReceiptAndReentrantCancelRemainSingle() {
        let f = Fixture(), s = f.service(); f.enable(s)
        f.onFactory = { i in f.replies[i](.capability(.unavailable)) }
        let r = s.open(port: 47830, completion: f.receive); f.flush(); r.cancel(); f.flush()
        XCTAssertEqual(f.receipts.count, 2); XCTAssertEqual(f.receipts.last?.outcome, .unavailable); XCTAssertEqual(f.cancels, [1])
    }
    func testPublicNativeIsolationAndMainCallbackWithoutProbe() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]!).appendingPathComponent("router-service-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try RuntimeConfiguration(options: LaunchOptions.parse(["--config-dir", root.path, "--headless","--silent"]))
        let s = RouterMappingService(configuration: runtime), enabled = expectation(description: "native enable"), done = expectation(description: "isolated native refusal")
        s.setEnabled(true) { _ in XCTAssertTrue(Thread.isMainThread); enabled.fulfill() }; wait(for: [enabled], timeout: 3)
        s.open(port: 47830) { r in XCTAssertTrue(Thread.isMainThread); XCTAssertEqual(r.outcome, .refused); done.fulfill() }; wait(for: [done], timeout: 3)
        let closed = expectation(description: "closed"); s.shutdown { _ in closed.fulfill() }; wait(for: [closed], timeout: 3)
    }
    func testInvalidRequestAndMalformedClockCannotConstructRawFactory() {
        let f = Fixture(), s = f.service(); f.enable(s); s.open(port: 0, completion: f.receive); f.flush(); XCTAssertTrue(f.operations.isEmpty)
        f.owner.sync { f.now = .nan }; s.open(port: 47830, completion: f.receive); f.flush(); XCTAssertTrue(f.operations.isEmpty)
    }
    func testAdmittedCancellationAroundCompletionClockNeverPublishesLiveGrant() throws {
        // Sweep a finite clock boundary window, using cancel's actual admission
        // result rather than assuming which internal clock read wins the race.
        for boundary in 1...9 {
            let f = Fixture(), s = f.service(); f.enable(s)
            let request = s.open(port: 47830, completion: f.receive); f.flush(); f.select()
            var calls = 0, admitted: Bool?
            f.owner.sync { f.onClock = { calls += 1; if calls == boundary { admitted = request.cancel() } } }
            f.reply(.udp(.granted(try f.lease(), retired: false, epochChanged: false)))
            if case .udp(.remove)? = f.operations.last { f.reply(.udp(.removed(retired: false))) }
            if admitted == true {
                XCTAssertEqual(f.receipts.last?.outcome, .cancelled, "Admitted cancellation published a live mapping")
                XCTAssertNil(f.receipts.last?.snapshot.mapping)
            }
            f.owner.sync { f.onClock = nil }
        }
    }
    func testCallbackQueueDelayDoesNotExtendGrantOrAllowCompletedCancellation() throws {
        let f = Fixture(), s = f.service(); f.enable(s)
        let request = s.open(port: 47830, completion: f.receive); f.flush(); f.select()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        f.callbacks.async { entered.signal(); _ = release.wait(timeout: .now()+3) }; XCTAssertEqual(entered.wait(timeout: .now()+3), .success)
        let lease = try f.lease()
        f.owner.sync { guard let reply = f.replies.last else { XCTFail("Missing grant callback"); return }; reply(.udp(.granted(lease, retired: false, epochChanged: false))) }
        XCTAssertFalse(request.cancel()); f.owner.sync { f.now = 20 }; release.signal(); f.flush()
        let mapping = try XCTUnwrap(f.receipts.last?.snapshot.mapping); XCTAssertEqual(mapping.expiresAtUptime, 120); XCTAssertEqual(mapping.remainingLifetime(at: 20), 100)
    }
    func testWinningCancelCannotInterruptItsOwnCompletionCleanup() throws {
        for boundary in 1...3 {
            let f = Fixture(), s = f.service(); f.enable(s); let request = s.open(port: 47830, completion: f.receive); f.flush(); f.select()
            var reads = 0, admitted = false
            f.owner.sync { f.onClock = { reads += 1; if reads == boundary { admitted = request.cancel() } } }
            f.reply(.udp(.granted(try f.lease(), retired: false, epochChanged: false)))
            XCTAssertTrue(admitted); guard case .udp(.remove)? = f.operations.last else { return XCTFail("Owned cleanup missing") }
            XCTAssertEqual(f.cancels.last, 0, "Queued cancellation interrupted its exact restoration")
            f.reply(.udp(.removed(retired: false))); XCTAssertEqual(f.receipts.last?.outcome, .cancelled)
            f.owner.sync { f.onClock = nil }
        }
    }
    func testPublicFailureTextIsBoundedAndSingleLineWithoutRawReceipt() {
        let f = Fixture(), s = f.service(); f.enable(s); s.open(port: 47830, completion: f.receive); f.flush()
        let text = "Quota\n\u{2028}\u{0000}" + String(repeating: "x", count: 4096)
        f.reply(.capability(.failure(text, retryAfter: 1800)))
        guard case .failed(let reason)? = f.receipts.last?.outcome else { return XCTFail("Public failure missing") }
        XCTAssertLessThanOrEqual(reason.unicodeScalars.count, 256); XCTAssertFalse(reason.contains("\n")); XCTAssertFalse(reason.contains("\u{2028}")); XCTAssertFalse(reason.contains("\u{0000}"))
        XCTAssertEqual(f.receipts.last?.snapshot.retryNotBeforeUptime, 1802)
    }
}
