import Foundation
import XCTest
import RemSoundJam
@testable import RemSoundCore

final class WebSessionAudioTests: XCTestCase {
    private final class Sink: WebAudioHandoff.Sink {
        var blocks = [WebAudioHandoff.Block](), closed = 0
        func consume(_ block: WebAudioHandoff.Block, discontinuity: Bool, completion: @escaping (Bool) -> Void) {
            blocks.append(block); completion(true)
        }
        func close(completion: @escaping () -> Void) { closed += 1; completion() }
    }
    private final class Fixture {
        let queue = DispatchQueue(label: "test.web.session.source"), sink = Sink()
        let binding = WebAudioHandoff.Binding(request: UUID(), network: .init(port: 49200, generation: UUID()))
        var service: WebAudioHandoff.Service!, producer: WebAudioHandoff.Producer!, source: WebSessionAudio!
        var replies = [Bool]()
        init() {
            source = WebSessionAudio(queue: queue)
            service = WebAudioHandoff.Service(queue: queue, isolated: false, permitted: { true }, factory: { [sink] _, _ in sink })
            queue.sync { XCTAssertTrue(service.open(binding) { self.producer = $0 }) }
            drain(); XCTAssertNotNil(producer)
        }
        func drain() { for _ in 0..<12 { queue.sync {} } }
        @discardableResult func request() -> Bool { source.request(producer) { self.replies.append($0) } }
        func apply(_ running: Bool = true, _ network: SessionNetworkBinding? = nil) { queue.sync { source.apply(running: running, binding: network ?? binding.network) } }
        func start() { XCTAssertTrue(request()); apply(); XCTAssertEqual(replies, [true]) }
        func cleanup() { source.revoke(); queue.sync { _ = service.shutdown() }; drain(); producer = nil; service = nil; drain() }
    }
    func testMatchingRunningBindingAdmitsOnePostGateCapture() {
        let f = Fixture(); defer { f.cleanup() }; f.start()
        f.queue.sync { XCTAssertTrue(f.source.hasDestination); XCTAssertTrue(f.source.capture([0.25, -0.25], lane: .inputCapture)) }
        f.drain(); XCTAssertEqual(f.sink.blocks.count, 1); XCTAssertEqual(f.sink.blocks.first?.samples, [0.25, -0.25])
    }
    func testStoppedBindingRefusesAndRetiresProducer() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.request()); f.apply(false)
        XCTAssertEqual(f.replies, [false]); XCTAssertFalse(f.producer.offer([1, 1], lane: .mixed)); f.drain(); XCTAssertEqual(f.sink.closed, 1)
    }
    func testDifferentSocketGenerationRefusesEvenSamePort() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.request())
        f.apply(true, .init(port: f.binding.network.port, generation: UUID())); XCTAssertEqual(f.replies, [false])
        XCTAssertFalse(f.producer.offer([1, 1], lane: .mixed))
    }
    func testDifferentBoundPortRefusesEvenSameGeneration() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.request())
        f.apply(true, .init(port: 49201, generation: f.binding.network.generation)); XCTAssertEqual(f.replies, [false])
    }
    func testMissingBindingNeverMeansDefaultPort() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.request())
        f.queue.sync { f.source.apply(running: true, binding: nil) }; XCTAssertEqual(f.replies, [false])
    }
    func testRevokePendingFencesQueuedApplyAndDoesNotRepeatCompletion() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.request()); f.source.revoke(); f.apply(); f.apply()
        XCTAssertEqual(f.replies, [false]); XCTAssertFalse(f.producer.offer([1, 1], lane: .mixed))
    }
    func testRevokeActiveImmediatelyFencesOffersBeforeWorkerRetirement() {
        let f = Fixture(); defer { f.cleanup() }; f.start(); f.source.revoke()
        XCTAssertFalse(f.producer.offer([1, 1], lane: .mixed))
        f.queue.sync { XCTAssertFalse(f.source.hasDestination); XCTAssertFalse(f.source.capture([1, 1], lane: .inputCapture)) }
        XCTAssertEqual(f.replies, [true])
    }
    func testCaptureAndSystemKeepExistingWireRoutesWithoutInventingPluginMix() {
        let f = Fixture(); defer { f.cleanup() }; f.start()
        f.queue.sync {
            XCTAssertTrue(f.source.capture([0.1, 0.1], lane: .inputCapture))
            XCTAssertTrue(f.source.capture([0.2, 0.2], lane: .systemCapture))
            XCTAssertFalse(f.source.capture([0.3, 0.3], lane: .plugin))
        }
        f.drain(); XCTAssertEqual(f.sink.blocks.map(\.lane), [.wasapi, .asio])
    }
    func testForeignWorkerCannotConsumeOrApply() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.request()); f.source.apply(running: true, binding: f.binding.network)
        XCTAssertTrue(f.replies.isEmpty); f.apply(); XCTAssertEqual(f.replies, [true])
        XCTAssertFalse(f.source.capture([1, 1], lane: .inputCapture)); XCTAssertFalse(f.source.hasDestination)
    }
    func testOneQueuedRegistrationBoundsAdmissionAndRefusalHasNoCallback() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.request())
        var calls = 0; XCTAssertFalse(f.source.request(f.producer) { _ in calls += 1 }); f.apply()
        XCTAssertEqual(calls, 0); XCTAssertEqual(f.replies, [true]); XCTAssertTrue(f.producer.offer([1, 1], lane: .mixed))
    }
    func testInvalidBlockDoesNotDetachLiveRegistration() {
        let f = Fixture(); defer { f.cleanup() }; f.start()
        f.queue.sync { XCTAssertFalse(f.source.capture([.nan, 0], lane: .inputCapture)); XCTAssertTrue(f.source.hasDestination) }
        f.queue.sync { XCTAssertTrue(f.source.capture([0, 0], lane: .inputCapture)) }; f.drain(); XCTAssertEqual(f.sink.blocks.count, 1)
    }
    func testReleaseRevokesOnlyThisProducer() {
        let f = Fixture(); defer { f.cleanup() }; f.start(); f.source = nil
        XCTAssertFalse(f.producer.offer([1, 1], lane: .mixed)); f.source = WebSessionAudio(queue: f.queue)
    }
    func testAlreadyRetiredProducerIsNotInstalledOrPromisedAReceipt() {
        let f = Fixture(); defer { f.cleanup() }; _ = f.producer.retire()
        XCTAssertFalse(f.request()); f.apply(); XCTAssertTrue(f.replies.isEmpty)
        f.queue.sync { XCTAssertFalse(f.source.hasDestination) }
    }
    func testRetirementBetweenRequestAndWorkerApplyRefusesOnce() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.request()); _ = f.producer.retire(); f.apply()
        XCTAssertEqual(f.replies, [false]); f.queue.sync { XCTAssertFalse(f.source.hasDestination) }
    }
    func testDestinationStopsImmediatelyWhenPersistentHandoffStops() {
        let f = Fixture(); defer { f.cleanup() }; f.start(); _ = f.service.stop()
        f.queue.sync { XCTAssertFalse(f.source.hasDestination); XCTAssertFalse(f.source.capture([1, 1], lane: .systemCapture)) }
    }
    func testRevokedQueuedRequestRetainsOneWorkerCreditUntilConsumed() {
        let f = Fixture(), next = Fixture(); defer { f.cleanup(); next.cleanup() }; XCTAssertTrue(f.request()); f.source.revoke()
        var replies = [Bool]()
        XCTAssertFalse(f.source.request(next.producer) { replies.append($0) })
        XCTAssertEqual(f.replies, [false]); XCTAssertTrue(replies.isEmpty)
        f.apply(); XCTAssertTrue(f.source.request(next.producer) { replies.append($0) })
        f.apply(true, next.binding.network); XCTAssertEqual(replies, [true]); XCTAssertEqual(f.replies, [false])
    }
    func testAppliedReplyMayRevokeWithoutDeadlockOrFutureSamples() {
        let f = Fixture(); defer { f.cleanup() }
        XCTAssertTrue(f.source.request(f.producer) { applied in XCTAssertTrue(applied); f.source.revoke() }); f.apply()
        f.queue.sync { XCTAssertFalse(f.source.hasDestination); XCTAssertFalse(f.source.capture([1, 1], lane: .inputCapture)) }
    }
    func testActualStoppedSessionRejectsAttachmentOnMainWithoutOpeningPorts() {
        let f = Fixture(); defer { f.cleanup() }; let session = Session(testPeerPort: 49200)
        let done = expectation(description: "stopped attachment refusal")
        XCTAssertTrue(session.attachWebAudio(f.producer) { applied in
            XCTAssertTrue(Thread.isMainThread); XCTAssertFalse(applied); done.fulfill()
        })
        wait(for: [done], timeout: 2); XCTAssertEqual(session.testPorts.audio, 0); XCTAssertEqual(session.testPorts.bridge, 0)
        XCTAssertFalse(f.producer.offer([1, 1], lane: .mixed)); session.shutdown()
    }
    private func pluginKey(_ instance: UInt32 = 1, port: UInt16 = 49301) -> WebSessionAudio.PluginKey {
        WebSessionAudio.PluginKey(instance: instance, endpoint: Endpoint("127.0.0.1", port), visit: UUID())!
    }
    func testPluginSingleSourceKeepsOriginalSamplesOnMixedLane() {
        let f = Fixture(); defer { f.cleanup() }; f.start(); let key = pluginKey()
        f.queue.sync { XCTAssertTrue(f.source.plugin([0.3, -0.4], from: key, now: 1)) }
        f.drain(); XCTAssertEqual(f.sink.blocks.map(\.lane), [.mixed]); XCTAssertEqual(f.sink.blocks.first?.samples, [0.3, -0.4])
    }
    func testPluginSecondaryOffersDoNotConcatenateIndependentClocks() {
        let f = Fixture(); defer { f.cleanup() }; f.start(); let first = pluginKey(), second = pluginKey(2)
        f.queue.sync {
            XCTAssertTrue(f.source.plugin(Array(repeating: 0.1, count: 480), from: first, now: 1))
            for i in 1...4 { XCTAssertTrue(f.source.plugin(Array(repeating: 0.2, count: 480), from: second, now: 1 + Double(i) / 1000)) }
            XCTAssertTrue(f.source.plugin(Array(repeating: 0.1, count: 480), from: first, now: 1.005))
        }
        f.drain(); XCTAssertEqual(f.sink.blocks.count, 2)
        if let last = f.sink.blocks.last { XCTAssertEqual(last.samples.count, 480); XCTAssertEqual(last.samples.first ?? -1, 0.3, accuracy: 0.0001) }
    }
    func testPluginGoodbyeRetiresDriverAndDiscardsSecondaryBacklog() {
        let f = Fixture(); defer { f.cleanup() }; f.start(); let a = pluginKey(), b = pluginKey(2)
        f.queue.sync {
            XCTAssertTrue(f.source.plugin([1, 1], from: a, now: 1))
            XCTAssertTrue(f.source.plugin(Array(repeating: 0.7, count: 1920), from: b, now: 1.001))
            f.source.retirePlugin(a)
            XCTAssertTrue(f.source.plugin([0.2, 0.3], from: b, now: 1.002))
        }
        f.drain(); XCTAssertEqual(f.sink.blocks.count, 2); XCTAssertEqual(f.sink.blocks.last?.samples, [0.2, 0.3])
    }
    func testPluginRevokeAndHandoffStopFenceBeforeQueuedMix() {
        let f = Fixture(); defer { f.cleanup() }; f.start(); let a = pluginKey()
        f.source.revoke(); f.queue.sync { XCTAssertFalse(f.source.plugin([1, 1], from: a, now: 1)) }; f.drain()
        XCTAssertTrue(f.sink.blocks.isEmpty)
        let g = Fixture(); defer { g.cleanup() }; g.start(); _ = g.service.stop()
        g.queue.sync { XCTAssertFalse(g.source.plugin([1, 1], from: a, now: 1)) }; g.drain(); XCTAssertTrue(g.sink.blocks.isEmpty)
    }
    func testPluginForeignWorkerAndUnboundedKeysCannotAdmit() {
        let f = Fixture(); defer { f.cleanup() }; f.start(); let a = pluginKey()
        XCTAssertFalse(f.source.plugin([1, 1], from: a, now: 1))
        XCTAssertNil(WebSessionAudio.PluginKey(instance: 1, endpoint: Endpoint("localhost", 49301), visit: UUID()))
        XCTAssertNil(WebSessionAudio.PluginKey(instance: 1, endpoint: Endpoint("127.0.0.1", 0), visit: UUID()))
        f.queue.sync {
            XCTAssertFalse(f.source.plugin([.nan, 1], from: a, now: 1))
            XCTAssertFalse(f.source.plugin(Array(repeating: 0, count: 8194), from: a, now: 1))
            XCTAssertTrue(f.source.plugin([0.2, 0.2], from: a, now: 1))
        }
        f.drain(); XCTAssertEqual(f.sink.blocks.count, 1)
    }
    func testPluginInstanceVisitReplacementCannotRetireNewDriver() {
        let f = Fixture(); defer { f.cleanup() }; f.start(); let old = pluginKey(), next = pluginKey()
        f.queue.sync {
            XCTAssertTrue(f.source.plugin([1, 1], from: old, now: 1)); f.source.retirePlugin(old)
            XCTAssertTrue(f.source.plugin([0.3, 0.3], from: next, now: 1.001)); f.source.retirePlugin(old)
            XCTAssertTrue(f.source.plugin([0.4, 0.4], from: next, now: 1.002))
        }
        f.drain(); XCTAssertEqual(f.sink.blocks.count, 3); XCTAssertEqual(f.sink.blocks.last?.samples, [0.4, 0.4])
    }

    func testPluginFreshAcceptedSourceVisitStartsWithFreshClockAndNoSecondaryBacklog() {
        let f = Fixture(), next = Fixture(); defer { f.cleanup(); next.cleanup() }; f.start(); let a = pluginKey(), b = pluginKey(2)
        f.queue.sync {
            XCTAssertTrue(f.source.plugin([0.1, 0.1], from: a, now: 100))
            XCTAssertTrue(f.source.plugin(Array(repeating: 0.9, count: 1920), from: b, now: 100.001))
        }
        f.source.revoke(); f.drain(); XCTAssertTrue(f.source.request(next.producer) { XCTAssertTrue($0) })
        f.apply(true, next.binding.network)
        f.queue.sync { XCTAssertTrue(f.source.plugin([0.2, 0.2], from: a, now: 0)) }
        next.drain(); XCTAssertEqual(next.sink.blocks.count, 1); XCTAssertEqual(next.sink.blocks.first?.samples, [0.2, 0.2])
    }
    func testPluginInvalidClockRetiresSourceAndCannotFallBackToCapture() {
        let f = Fixture(); defer { f.cleanup() }; f.start(); let a = pluginKey()
        f.queue.sync {
            XCTAssertTrue(f.source.plugin([0.1, 0.1], from: a, now: 1))
            XCTAssertFalse(f.source.plugin([0.1, 0.1], from: a, now: 0))
            XCTAssertFalse(f.source.hasDestination); XCTAssertFalse(f.source.capture([0.1, 0.1], lane: .inputCapture))
        }
        XCTAssertFalse(f.producer.isActive)
    }
    func testPluginQuotaRefusesExtraIdentityWithoutGrowingOrClosingLiveDriver() {
        let f = Fixture(); defer { f.cleanup() }; f.start(); let keys = (0...64).map { pluginKey(UInt32($0)) }
        f.queue.sync {
            for key in keys.prefix(64) { XCTAssertTrue(f.source.plugin([0.1, 0.1], from: key, now: 1)) }
            for _ in 0..<100 { XCTAssertFalse(f.source.plugin([0.1, 0.1], from: keys[64], now: 1)) }
            XCTAssertTrue(f.source.plugin([0.1, 0.1], from: keys[0], now: 1.001)); XCTAssertTrue(f.source.hasDestination)
        }
        f.drain(); XCTAssertEqual(f.sink.blocks.count, 2)
    }

    func testAddressSourceObservationRequiresExactInstalledRequestAndWorker() {
        let f=Fixture();defer{f.cleanup()};XCTAssertFalse(f.source.matches(f.binding))
        f.queue.sync {XCTAssertFalse(f.source.matches(f.binding))};f.start()
        f.queue.sync {
            XCTAssertTrue(f.source.matches(f.binding))
            XCTAssertFalse(f.source.matches(.init(request:UUID(),network:f.binding.network)))
            XCTAssertFalse(f.source.matches(.init(request:f.binding.request,network:.init(port:f.binding.network.port,generation:UUID()))))
        }
        XCTAssertFalse(f.source.matches(f.binding));f.source.revoke()
        f.queue.sync {XCTAssertFalse(f.source.matches(f.binding))}
    }
    func testAddressObservationRefusesRetiredProducerBeforeSourceRemoval() {
        let f=Fixture();defer{f.cleanup()};f.start();_ = f.producer.retire()
        f.queue.sync {XCTAssertFalse(f.source.matches(f.binding))}
    }
    func testActualStoppedSessionAddressObservationHasNoNativeFallback() {
        let f=Fixture();defer{f.cleanup()};let session=Session(testPeerPort:49200)
        let done=expectation(description:"stopped source address observation")
        XCTAssertTrue(session.observeWebAudioBinding(f.binding) {binding in XCTAssertNil(binding);done.fulfill()})
        wait(for:[done],timeout:2);XCTAssertEqual(session.testPorts.audio,0);XCTAssertEqual(session.testPorts.bridge,0)
        let closed=expectation(description:"stopped Session retirement");session.shutdown {closed.fulfill()};wait(for:[closed],timeout:2)
    }

    func testAddressPermissionIsThreadSafeButPendingIsNotInstalled(){let f=Fixture();defer{f.cleanup()};XCTAssertFalse(f.source.permitsAddressQuery(f.binding));XCTAssertTrue(f.request());XCTAssertFalse(f.source.permitsAddressQuery(f.binding));f.apply();XCTAssertTrue(f.source.permitsAddressQuery(f.binding))}
    func testAddressPermissionRejectsForeignRequestAndSocketEpoch(){let f=Fixture();defer{f.cleanup()};f.start();XCTAssertTrue(f.source.permitsAddressQuery(f.binding));XCTAssertFalse(f.source.permitsAddressQuery(.init(request:UUID(),network:f.binding.network)));XCTAssertFalse(f.source.permitsAddressQuery(.init(request:f.binding.request,network:.init(port:f.binding.network.port,generation:UUID()))))}
    func testAddressPermissionRevokesBeforeQueuedWorkerWork(){let f=Fixture();defer{f.cleanup()};f.start();XCTAssertTrue(f.source.permitsAddressQuery(f.binding));f.source.revoke();XCTAssertFalse(f.source.permitsAddressQuery(f.binding));f.queue.sync{XCTAssertFalse(f.source.permitsAddressQuery(f.binding))}}
    func testAddressPermissionRejectsRetiredProducerBeforeSourceRemoval(){let f=Fixture();defer{f.cleanup()};f.start();XCTAssertTrue(f.source.permitsAddressQuery(f.binding));_ = f.producer.retire();XCTAssertFalse(f.source.permitsAddressQuery(f.binding))}

}
