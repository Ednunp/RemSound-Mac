import Foundation
import XCTest
@testable import RemSoundCore

final class WebServiceLifecycleTests: XCTestCase {
    private final class Listener: WebRoom.Listener {
        var starts = 0, closes = 0, hold = false
        var failure: (() -> Void)?
        var receipt: (() -> Void)?, offer: ((WebRoom.Incoming) -> Bool)?
        func start(offer: @escaping (WebRoom.Incoming) -> Bool, failed: @escaping () -> Void) { starts += 1; self.offer = offer; failure = failed }
        func close(completion: @escaping () -> Void) { closes += 1; receipt = completion; if !hold { retire() } }
        func retire() { let callback = receipt; receipt = nil; callback?() }
    }
    private final class Sink: WebAudioHandoff.Sink {
        var closes = 0, hold = false, receipt: (() -> Void)?
        func consume(_ block: WebAudioHandoff.Block, discontinuity: Bool, completion: @escaping (Bool) -> Void) { completion(true) }
        func close(completion: @escaping () -> Void) { closes += 1; receipt = completion; if !hold { retire() } }
        func retire() { let callback = receipt; receipt = nil; callback?() }
    }
    private final class Fixture {
        let queue = DispatchQueue(label: "test.web.exclusive.lifetime"), listener = Listener(), sink = Sink()
        let binding = WebAudioHandoff.Binding(request: UUID(), network: .init(port: 49210, generation: UUID()))
        let credential = WebAuthentication.Credential.make(password: "synthetic", salt: Data(repeating: 0, count: 16), derive: { _, _ in Data(repeating: 1, count: 32) })!
        var room: WebRoom.Service!, handoff: WebAudioHandoff.Service!, service: WebServiceLifecycle!
        var enabled = true, matches = true, configs = 0, factories = 0, revoked = 0, attaches = 0
        var sourceReturns = true, accept = true, answer: Bool? = true, reply: ((Bool) -> Void)?, producer: WebAudioHandoff.Producer?
        var configHook: (() -> Void)?, attachHook: (() -> Void)?, sourceHook: (() -> Void)?
        init(isolated: Bool = false, enabled: Bool = true, roomSink: Bool = false) {
            self.enabled = enabled
            room = WebRoom.Service(queue: queue, isolated: isolated, permitted: { [weak self] in self?.enabled ?? false }, listener: { [weak self] _ in self?.factories += 1; return self?.listener }, clock: { 100 }, schedule: { _, _ in {} }, peerSchedule: { _, _ in {} }, retiring: { [weak self] in _ = self?.service?.stop() })
            handoff = WebAudioHandoff.Service(queue: queue, isolated: isolated, permitted: { [weak self] in self?.enabled ?? false }, factory: { [weak self] _, gate in
                guard let self else { return nil }
                self.sourceHook?(); guard self.sourceReturns else { return nil }; return roomSink ? WebAudioHandoff.roomSink(self.room, permitted: gate) : self.sink
            })
            service = WebServiceLifecycle(queue: queue, isolated: isolated, permitted: { [weak self] in self?.enabled ?? false }, room: room, handoff: handoff,
                matches: { [weak self] value in self?.matches == true && value == self?.binding }, revoke: { [weak self] in self?.revoked += 1 }, attach: { [weak self] producer, completion in
                    guard let self else { return false }; self.attaches += 1; self.producer = producer; self.reply = completion
                    self.attachHook?(); if let answer = self.answer { completion(answer) }; return self.accept
                })
        }
        func on(_ body: () -> Void) { queue.sync(execute: body) }
        func drain() { for _ in 0..<32 { queue.sync {} } }
        @discardableResult func start() -> Bool { var result = false; on { result = service.start(binding) { [self] in configs += 1; configHook?(); return .init(credential: credential, page: Data("fixed".utf8), policy: .init(hosts: ["example.test"], origins: []), source: "fixed") } }; drain(); return result }
        var state: WebServiceLifecycle.State? { var value: WebServiceLifecycle.State?; on { value = service.snapshot?.state }; return value }
        func cleanup() { _ = service?.shutdown(); on { if let reply { self.reply = nil; reply(false) }; sink.hold = false; listener.hold = false; sink.retire(); listener.retire() }; drain(); service = nil; producer = nil; on { _ = handoff.shutdown(); _ = room.shutdown() }; drain() }
    }
    func testAudioDetachWaitsAdmittedAttachReturnWithoutClosingRoom() {
        let f=Fixture(roomSink:true);defer{f.cleanup()};f.answer=nil;XCTAssertTrue(f.start());let old=f.producer;var replies=[Bool]()
        f.on {XCTAssertTrue(f.service.detachAudio{replies.append($0)})};f.drain()
        XCTAssertTrue(replies.isEmpty);XCTAssertFalse(old?.isActive ?? true);XCTAssertEqual(f.listener.closes,0)
        f.on {f.reply?(true)};f.drain();XCTAssertEqual(replies,[true]);XCTAssertEqual(f.state,.running)
        f.on {XCTAssertNil(f.service.snapshot?.binding);XCTAssertEqual(f.room.snapshot?.state,.running)}
        XCTAssertEqual(f.listener.closes,0)
    }
    func testAudioDetachFullShutdownStillJoinsOldAttachmentAndRoom() {
        let f=Fixture(roomSink:true);defer{f.cleanup()};f.answer=nil;XCTAssertTrue(f.start());var detached=[Bool](),closed=0
        f.on {XCTAssertTrue(f.service.detachAudio{detached.append($0)})};f.drain();XCTAssertTrue(f.service.shutdown{closed += 1});f.drain()
        XCTAssertEqual(closed,0);XCTAssertTrue(detached.isEmpty);XCTAssertEqual(f.listener.closes,1)
        f.on {f.reply?(true)};f.drain();XCTAssertEqual(detached,[false]);XCTAssertEqual(closed,1);XCTAssertEqual(f.state,.closed)
    }
    func testReattachedWorkerCallbackRemainsPartOfFullShutdown() {
        let f=Fixture(roomSink:true);defer{f.cleanup()};XCTAssertTrue(f.start());var detached=false
        f.on {XCTAssertTrue(f.service.detachAudio{detached=$0})};f.drain();XCTAssertTrue(detached)
        f.answer=nil;var attached=[Bool](),closed=0
        f.on {XCTAssertTrue(f.service.attachAudio(f.binding){attached.append($0)})};f.drain()
        XCTAssertTrue(f.service.shutdown{closed += 1});f.drain();XCTAssertEqual(closed,0);XCTAssertTrue(attached.isEmpty)
        f.on {f.reply?(false)};f.drain();XCTAssertEqual(attached,[false]);XCTAssertEqual(closed,1)
    }
    func testAudioDetachReservesOneBoundedCallbackAndForeignOwnerRefuses() {
        let f=Fixture();defer{f.cleanup()};f.answer=nil;XCTAssertTrue(f.start())
        XCTAssertFalse(f.service.detachAudio{_ in XCTFail("Foreign owner callback")})
        XCTAssertFalse(f.service.attachAudio(f.binding){_ in XCTFail("Foreign owner callback")})
        f.on {
            XCTAssertTrue(f.service.detachAudio{XCTAssertTrue($0)})
            for _ in 0..<100 {XCTAssertFalse(f.service.detachAudio{_ in XCTFail("Duplicate callback")})}
        }
        f.on {f.reply?(true)};f.drain();XCTAssertEqual(f.listener.closes,0)
    }
    func testOffAndIsolatedDoNotConstructConfigurationOrListener() {
        for f in [Fixture(enabled: false), Fixture(isolated: true)] { defer { f.cleanup() }; XCTAssertFalse(f.start()); XCTAssertEqual(f.configs, 0); XCTAssertEqual(f.factories, 0); XCTAssertEqual(f.attaches, 0) }
    }
    func testMatchingVisitUsesActualRoomAndHandoffThenWaitsAttachReceipt() {
        let f = Fixture(); defer { f.cleanup() }; f.answer = nil; XCTAssertTrue(f.start()); XCTAssertEqual(f.state, .starting)
        XCTAssertEqual(f.factories, 1); XCTAssertEqual(f.attaches, 1); f.on { f.reply?(true) }; f.drain(); XCTAssertEqual(f.state, .running)
    }
    func testStaleRunningObservationRefusesBeforeCredentialAndListener() {
        let f = Fixture(); defer { f.cleanup() }; f.matches = false; XCTAssertFalse(f.start()); XCTAssertEqual(f.configs, 0); XCTAssertEqual(f.factories, 0)
    }
    func testStopImmediatelyRevokesAndWaitsBothIndependentResourceReceipts() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.start()); f.on { f.listener.hold = true; f.sink.hold = true }; var done = 0
        XCTAssertTrue(f.service.stop { done += 1 }); XCTAssertFalse(f.producer?.isActive ?? true); f.drain(); XCTAssertEqual(done, 0); XCTAssertEqual(f.state, .stopping)
        f.on { f.listener.retire() }; f.drain(); XCTAssertEqual(done, 0)
        f.on { f.sink.retire() }; f.drain(); XCTAssertEqual(done, 1); XCTAssertEqual(f.state, .off)
    }
    func testStopWaitsLateAdmittedSessionAttachmentCallback() {
        let f = Fixture(); defer { f.cleanup() }; f.answer = nil; XCTAssertTrue(f.start()); var done = 0
        XCTAssertTrue(f.service.stop { done += 1 }); f.drain(); XCTAssertEqual(done, 0); XCTAssertEqual(f.state, .stopping)
        f.on { f.reply?(true); f.reply?(false) }; f.drain(); XCTAssertEqual(done, 1); XCTAssertEqual(f.state, .off); XCTAssertFalse(f.producer?.isActive ?? true)
    }
    func testRefusedAttachmentCannotBeMadeRunningByItsEarlyCallback() {
        let f = Fixture(); defer { f.cleanup() }; f.accept = false; XCTAssertTrue(f.start()); XCTAssertEqual(f.state, .off); XCTAssertFalse(f.producer?.isActive ?? true)
    }
    func testNegativeAttachmentReceiptRetiresRoomAndSource() {
        let f = Fixture(); defer { f.cleanup() }; f.answer = false; XCTAssertTrue(f.start()); XCTAssertEqual(f.state, .off); XCTAssertEqual(f.listener.closes, 1); XCTAssertEqual(f.sink.closes, 1)
    }
    func testReentrantConfigurationStopPreventsNativeFactory() {
        let f = Fixture(); defer { f.cleanup() }; f.configHook = { _ = f.service.stop() }; XCTAssertFalse(f.start()); f.drain(); XCTAssertEqual(f.factories, 0); XCTAssertEqual(f.attaches, 0); XCTAssertEqual(f.state, .off)
    }
    func testReentrantAttachStopWaitsRawReturnAndThenRetires() {
        let f = Fixture(); defer { f.cleanup() }; var done = 0; f.attachHook = { XCTAssertTrue(f.service.stop { done += 1 }); XCTAssertEqual(done, 0) }
        XCTAssertTrue(f.start()); f.drain(); XCTAssertEqual(done, 1); XCTAssertEqual(f.state, .off)
    }
    func testReplacementIsRefusedUntilOldRoomCloseThenUsesFreshSource() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.start()); let old = f.producer; f.on { f.listener.hold = true }
        XCTAssertTrue(f.service.stop()); f.drain(); XCTAssertFalse(f.start()); XCTAssertEqual(f.factories, 1)
        f.on { f.listener.hold = false; f.listener.retire() }; f.drain(); XCTAssertTrue(f.start()); XCTAssertEqual(f.state, .running); XCTAssertFalse(old?.isActive ?? true); XCTAssertTrue(f.producer?.isActive ?? false)
    }
    func testShutdownIsPermanentAndCallbacksRunOnOwner() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.start()); let key = DispatchSpecificKey<Int>(); f.queue.setSpecific(key: key, value: 1); var done = 0
        XCTAssertTrue(f.service.shutdown { XCTAssertEqual(DispatchQueue.getSpecific(key: key), 1); done += 1 }); f.drain(); XCTAssertEqual(done, 1); XCTAssertEqual(f.state, .closed); XCTAssertFalse(f.start())
    }
    func testBoundedWaitersRefuseWithoutCallbackAndNoReceiptIsInvented() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.start()); f.on { f.listener.hold = true }; var done = 0
        for _ in 0..<16 { XCTAssertTrue(f.service.stop { done += 1 }) }; XCTAssertFalse(f.service.stop { done += 1000 }); f.drain(); XCTAssertEqual(done, 0)
        f.on { f.listener.retire() }; f.drain(); XCTAssertEqual(done, 16)
    }
    func testForeignOwnerCannotStartOrReadMutableStatus() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertFalse(f.service.start(f.binding) { XCTFail("Foreign configuration"); return nil }); XCTAssertNil(f.service.snapshot); XCTAssertEqual(f.factories, 0)
    }
    func testWrapperReleaseStopsPersistentResourcesAfterExactRetirement() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.start()); f.on { f.listener.hold = true }; f.service = nil; f.drain()
        XCTAssertFalse(f.producer?.isActive ?? true); f.on { XCTAssertEqual(f.listener.closes, 1); f.listener.retire() }; f.drain()
        f.on { XCTAssertEqual(f.room.snapshot?.state, .closed); XCTAssertEqual(f.handoff.snapshot?.shutdown, true) }
    }
    func testActualRoomSinkSourceClosesBeforeFullRoomReceipt() {
        let f = Fixture(roomSink: true); defer { f.cleanup() }; XCTAssertTrue(f.start()); XCTAssertEqual(f.state, .running)
        XCTAssertTrue(f.producer?.offer([0.2, -0.2], lane: .mixed) ?? false); f.drain(); f.on { f.listener.hold = true }; var done = 0
        XCTAssertTrue(f.service.stop { done += 1 }); f.drain(); f.on { XCTAssertEqual(f.handoff.snapshot?.binding, nil) }; XCTAssertEqual(done, 0)
        f.on { f.listener.retire() }; f.drain(); XCTAssertEqual(done, 1)
    }
    func testReentrantLateSourceFactoryRetiresReturnedSinkBeforeReplacement() {
        let f = Fixture(); defer { f.cleanup() }; f.sink.hold = true
        f.sourceHook = { _ = f.service.stop() }; XCTAssertTrue(f.start()); XCTAssertEqual(f.attaches, 0); XCTAssertEqual(f.sink.closes, 1)
        XCTAssertEqual(f.state, .stopping); XCTAssertFalse(f.start()); f.on { f.sink.retire() }; f.drain(); XCTAssertEqual(f.state, .off)
    }
    func testDisabledDuringConfigurationCannotCreateListener() {
        let f = Fixture(); defer { f.cleanup() }; f.configHook = { f.enabled = false }; XCTAssertFalse(f.start()); XCTAssertEqual(f.factories, 0); XCTAssertEqual(f.attaches, 0)
    }
    func testFirstForeignAttachmentCallbackWinsAndMarshalsToOwner() {
        let f = Fixture(); defer { f.cleanup() }; f.answer = nil; XCTAssertTrue(f.start()); let reply = f.reply
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { reply?(false); reply?(true); done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success); f.drain(); XCTAssertEqual(f.state, .off); XCTAssertFalse(f.producer?.isActive ?? true)
    }
    func testDuplicateOldCallbackCannotMutateReplacement() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.start()); let old = f.reply
        XCTAssertTrue(f.service.stop()); f.drain(); XCTAssertTrue(f.start()); let current = f.producer
        f.on { old?(false); old?(true) }; f.drain(); XCTAssertEqual(f.state, .running); XCTAssertTrue(current?.isActive ?? false)
    }
    func testRepeatedStopCoalescesWithoutUnboundedOwnerCommands() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.start())
        let entered = DispatchSemaphore(value: 0), leave = DispatchSemaphore(value: 0)
        f.queue.async { entered.signal(); _ = leave.wait(timeout: .now() + 2) }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        for _ in 0..<1000 { XCTAssertTrue(f.service.stop()) }; XCTAssertEqual(f.revoked, 1); leave.signal(); f.drain()
        XCTAssertEqual(f.listener.closes, 1); XCTAssertEqual(f.sink.closes, 1); XCTAssertEqual(f.state, .off)
    }
    func testReceiptCallbackMayStartOnlyAfterBothOwnersHaveRetired() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.start()); var restarted = false
        XCTAssertTrue(f.service.stop { restarted = f.service.start(f.binding) { .init(credential: f.credential, page: Data("fixed".utf8), policy: .init(hosts: ["example.test"], origins: []), source: "fixed") } })
        f.drain(); XCTAssertTrue(restarted); XCTAssertEqual(f.state, .running); XCTAssertEqual(f.factories, 2)
    }

    func testNilSourceFactoryRetiresStartedRoomWithoutInventingAttachment() {
        let f = Fixture(); defer { f.cleanup() }; f.sourceReturns = false; XCTAssertTrue(f.start())
        XCTAssertEqual(f.attaches, 0); XCTAssertEqual(f.state, .off); XCTAssertEqual(f.listener.closes, 1); XCTAssertEqual(f.sink.closes, 0)
    }
    func testChangedStartObservationBeforeAttachReceiptCannotPublishRunning() {
        let f = Fixture(); defer { f.cleanup() }; f.answer = nil; XCTAssertTrue(f.start()); f.matches = false
        f.on { f.reply?(true) }; f.drain(); XCTAssertEqual(f.state, .off); XCTAssertFalse(f.producer?.isActive ?? true)
    }
    func testZeroPortCannotConstructConfiguration() {
        let f = Fixture(); defer { f.cleanup() }; f.on {
            XCTAssertFalse(f.service.start(.init(request: f.binding.request, network: .init(port: 0, generation: f.binding.network.generation))) { XCTFail("Zero-port configuration"); return nil })
        }; XCTAssertEqual(f.factories, 0); XCTAssertEqual(f.state, .off)
    }
    private final class RefusedChild: WebRoom.Incoming {
        var closes = 0, receipt: (() -> Void)?
        func transport(permitted: @escaping () -> Bool) -> WebConnection.Transport? { nil }
        func close(completion: @escaping () -> Void) { closes += 1; receipt = completion }
    }
    func testActualRoomRefusedChildStillBlocksExclusiveRetirement() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.start()); let child = RefusedChild()
        f.on { XCTAssertTrue(f.listener.offer?(child) ?? false) }; f.drain(); XCTAssertEqual(child.closes, 1)
        var done = 0; XCTAssertTrue(f.service.stop { done += 1 }); f.drain(); XCTAssertEqual(done, 0); XCTAssertEqual(f.state, .stopping)
        f.on { child.receipt?() }; f.drain(); XCTAssertEqual(done, 1); XCTAssertEqual(f.state, .off)
    }

    func testNativeRoomFailureImmediatelyFencesSourceButStillWaitsRealReceipts() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());f.on {f.listener.hold=true;f.sink.hold=true;f.listener.failure?();XCTAssertFalse(f.producer?.isActive ?? true)}
        f.drain();XCTAssertEqual(f.state,.stopping);f.on {f.listener.retire()};f.drain();XCTAssertEqual(f.state,.stopping)
        f.on {f.sink.retire()};f.drain();XCTAssertEqual(f.state,.off)
    }

}
