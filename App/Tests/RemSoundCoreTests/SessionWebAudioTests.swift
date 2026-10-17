import Foundation
import RemSoundJam
import XCTest
@testable import RemSoundCore

final class SessionWebAudioTests: XCTestCase {
    private final class Sink: WebAudioHandoff.Sink {
        var blocks = [WebAudioHandoff.Block](), closes = 0
        func consume(_ block: WebAudioHandoff.Block, discontinuity: Bool, completion: @escaping (Bool) -> Void) {
            blocks.append(block); completion(true)
        }
        func close(completion: @escaping () -> Void) { closes += 1; completion() }
    }
    private final class Fixture {
        let queue = DispatchQueue(label: "test.session.browser.sink"), sink = Sink(), peer: UDP, session: Session
        var service: WebAudioHandoff.Service!, producer: WebAudioHandoff.Producer?, binding: SessionNetworkBinding?
        var settings = PushToTalkSettings()
        init(push: Bool = false) throws {
            peer = try UDP(port: 0, loopback: true); session = Session(testPeerPort: peer.boundPort, testCapturePushDriven: push)
            service = WebAudioHandoff.Service(queue: queue, isolated: false, permitted: { true }, factory: { [sink] _, _ in sink })
        }
        var samples: [Float] { queue.sync { sink.blocks.flatMap(\.samples) } }
        var lanes: [WebAudio.Lane] { queue.sync { sink.blocks.map(\.lane) } }
        func cleanup() {
            session.revokeWebAudio()
            let sessionDone = XCTestExpectation(description: "Session native consumers retired")
            let sinkDone = XCTestExpectation(description: "bounded source retired")
            session.shutdown { sessionDone.fulfill() }
            queue.sync { XCTAssertTrue(service.shutdown { sinkDone.fulfill() }) }
            XCTAssertEqual(XCTWaiter.wait(for: [sessionDone, sinkDone], timeout: 3), .completed)
            producer = nil; service = nil
            XCTAssertEqual(session.testPorts.audio, 0); XCTAssertEqual(session.testPorts.discovery, 0); XCTAssertEqual(session.testPorts.bridge, 0)
        }
    }
    private func start(_ f: Fixture, peer: Bool = false, system: Bool = false) throws {
        let done = expectation(description: "owned isolated Session socket")
        f.session.start(password: "synthetic web capture", peerAddress: peer ? "127.0.0.1" : "", send: true,
            receive: false, plugins: false, name: "Test", systemAudio: system, sendPacketSize: .small,
            pushToTalk: f.settings, networkCompletion: { f.binding = $0; done.fulfill() })
        wait(for: [done], timeout: 3); let binding = try XCTUnwrap(f.binding)
        XCTAssertNotEqual(binding.port, 0); XCTAssertNotEqual(binding.port, 47830); XCTAssertEqual(f.session.testPorts.bridge, 0)
    }
    private func attach(_ f: Fixture) throws {
        let done = expectation(description: "actual worker registration")
        let binding = try XCTUnwrap(f.binding)
        f.queue.sync { XCTAssertTrue(f.service.open(.init(request: UUID(), network: binding)) { f.producer = $0 }) }
        for _ in 0..<12 { f.queue.sync {} }
        let producer = try XCTUnwrap(f.producer)
        XCTAssertTrue(f.session.attachWebAudio(producer) { value in
            XCTAssertTrue(Thread.isMainThread); XCTAssertTrue(value); done.fulfill()
        })
        wait(for: [done], timeout: 3)
    }
    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let end = ProcessInfo.processInfo.systemUptime + 2
        while !condition(), ProcessInfo.processInfo.systemUptime < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    func testIsolatedSessionBindsOnlyOwnedLoopbackSockets() throws {
        let f = try Fixture(); defer { f.cleanup() }; try start(f)
        XCTAssertEqual(f.session.testWebBoundAddresses(), ["127.0.0.1", "127.0.0.1"])
    }
    func testBrowserOnlyInputFeedsWithoutUDPSelectionAndExactlyOnce() throws {
        let f = try Fixture(); defer { f.cleanup() }; try start(f); try attach(f)
        f.session.testCapture([Float](repeating: 0.25, count: 960)); until { f.samples.count >= 960 }
        XCTAssertEqual(f.samples, [Float](repeating: 0.25, count: 960)); XCTAssertEqual(Set(f.lanes), [.wasapi])
    }
    func testPostPTTFadeReachesBrowserRatherThanUngatedCapture() throws {
        let f = try Fixture(); defer { f.cleanup() }; f.settings.enabled = true; f.settings.bypassForRecording = true
        try start(f); try attach(f); f.session.testCapture([Float](repeating: 0.25, count: 960)); until { f.samples.count >= 960 }
        XCTAssertEqual(f.samples.first ?? -1, 0.25 * 239 / 240, accuracy: 0.00001); XCTAssertEqual(f.samples.last, 0)
    }
    func testSystemAndInputUseTheirActualDistinctSourceRoutes() throws {
        let f = try Fixture(); defer { f.cleanup() }; try start(f, system: true); try attach(f)
        f.session.testCapture([Float](repeating: 0.1, count: 960)); until { f.samples.count >= 960 }
        f.session.testSystemCapture([Float](repeating: 0.2, count: 960)); until { f.samples.count >= 1920 }
        XCTAssertEqual(Set(f.lanes), [.wasapi, .asio]); XCTAssertEqual(f.samples.count, 1920)
    }
    func testApplicationCaptureReplacementRevokesBeforeReconfiguration() throws {
        let f = try Fixture(); defer { f.cleanup() }; try start(f, system: true); try attach(f)
        f.session.setSendApplications(["synthetic.browser.application"])
        XCTAssertFalse(try XCTUnwrap(f.producer).isActive)
        f.session.testSystemCapture([Float](repeating: 0.3, count: 960)); XCTAssertTrue(f.samples.isEmpty)
    }
    func testAudioOptionsRevokeAndDoNotReattachByMatchingOldBinding() throws {
        let f = try Fixture(); defer { f.cleanup() }; try start(f); try attach(f)
        f.session.setAudioOptions(send: true, receive: false, plugins: false, sendPacketSize: .small)
        XCTAssertFalse(try XCTUnwrap(f.producer).isActive)
        f.session.testCapture([Float](repeating: 0.2, count: 960)); XCTAssertTrue(f.samples.isEmpty)
    }
    func testPendingStopAndRestartImmediatelyRevokeAndChangeSocketVisit() throws {
        let f = try Fixture(); defer { f.cleanup() }; try start(f); try attach(f)
        let old = try XCTUnwrap(f.binding); f.session.stop(); XCTAssertFalse(try XCTUnwrap(f.producer).isActive)
        try start(f); XCTAssertNotEqual(f.binding?.generation, old.generation)
        let refused = expectation(description: "old source not reattached")
        XCTAssertFalse(f.session.attachWebAudio(try XCTUnwrap(f.producer)) { _ in refused.fulfill() })
        refused.isInverted = true; wait(for: [refused], timeout: 0.03)
    }
    func testBrowserOnlyCaptureWakeRefreshPreservesRegisteredDestination() throws {
        let f = try Fixture(push: true); defer { f.cleanup() }; try start(f); try attach(f)
        XCTAssertEqual(f.session.testWebCaptureWakeSignalAfterRefresh(frames: 120), 1)
        f.session.revokeWebAudio()
        XCTAssertEqual(f.session.testWebCaptureWakeSignalAfterRefresh(frames: 120), 0)
    }
    func testCustomFanoutDoesNotDoubleFeedBrowser() throws {
        let f = try Fixture(push: true); defer { f.cleanup() }; f.session.setJamulusStyle(true)
        try start(f, peer: true); try attach(f)
        var capable = Data([0]); capable.put(UInt64(1)); capable.append(JamulusStyle.labFlagCanDecode)
        XCTAssertTrue(f.peer.send(Wire.packet(.heartbeat, payload: capable), to: Endpoint("127.0.0.1", try XCTUnwrap(f.binding).port)))
        until { f.session.testWebCustomTargetCount() == 1 }
        for block in 1...15 {
            f.session.testCapture([Float](repeating: 0.125, count: JamulusStyle.frames * 2))
            until { f.samples.count >= JamulusStyle.frames * 2 * block }
        }
        XCTAssertEqual(f.samples.count, JamulusStyle.frames * 2 * 15)
        XCTAssertEqual(Set(f.lanes), [.wasapi])
        func packets(_ peer: UDP) -> [Wire.Packet] {
            var result = [Wire.Packet]()
            for _ in 0..<256 { guard let (data, _) = peer.receive() else { break }; if let packet = Wire.parse(data) { result.append(packet) } }
            return result
        }
        let customPackets = packets(f.peer)
        XCTAssertEqual(customPackets.filter { $0.kind == .audio }.count, 15)
        XCTAssertTrue(customPackets.contains { $0.kind == .format && StreamFormat.parse($0.payload)?.codec == StreamFormat.Codec.opusCustom.rawValue })
    }
    private func hello(_ f: Fixture, _ instance: UInt32) {
        var pid = Data(); pid.put(UInt32(12345))
        f.session.testWebBridgePacket(Bridge.encode(.hello, instance: instance, payload: pid), from: Endpoint("127.0.0.1", f.peer.boundPort))
    }
    private func plugin(_ f: Fixture, _ instance: UInt32, _ value: Float, frames: Int = 240) {
        var data = Data(); for _ in 0..<frames * 2 { data.put(value.bitPattern) }
        f.session.testWebBridgePacket(Bridge.encode(.trackAudio, instance: instance, payload: data), from: Endpoint("127.0.0.1", f.peer.boundPort))
    }
    func testPluginBrowserOnlyOriginalWorkerBlockFeedsExactlyOnce() throws {
        let f = try Fixture(); defer { f.cleanup() }; try start(f); try attach(f); hello(f, 1)
        plugin(f, 1, 0.25); until { f.samples.count == 480 }
        XCTAssertEqual(f.samples, Array(repeating: 0.25, count: 480)); XCTAssertEqual(Set(f.lanes), [.mixed])
    }
    func testPluginBrowserUsesPostPTTGateWithoutChangingInput() throws {
        let f = try Fixture(); defer { f.cleanup() }; f.settings.enabled = true; f.settings.bypassForRecording = true
        try start(f); try attach(f); hello(f, 1); plugin(f, 1, 0.25, frames: 480); until { f.samples.count == 960 }
        XCTAssertEqual(f.samples.first ?? -1, 0.25 * 239 / 240, accuracy: 0.00001); XCTAssertEqual(f.samples.last, 0)
    }
    func testPluginSamePIDInstancesUseIndependentClockQueuesAndDriverLength() throws {
        let f = try Fixture(); defer { f.cleanup() }; try start(f); try attach(f); hello(f, 1); hello(f, 2)
        plugin(f, 1, 0.1); until { f.samples.count == 480 }
        plugin(f, 2, 0.2, frames: 960); XCTAssertEqual(f.samples.count, 480)
        plugin(f, 1, 0.1); until { f.samples.count == 960 }
        XCTAssertEqual(f.samples.last ?? -1, 0.3, accuracy: 0.0001)
    }
    func testPluginGoodbyeAndSameInstanceRejoinDoNotReplayOldBacklog() throws {
        let f = try Fixture(); defer { f.cleanup() }; try start(f); try attach(f); hello(f, 1); hello(f, 2)
        plugin(f, 1, 0.1); until { f.samples.count == 480 }; plugin(f, 2, 0.8, frames: 960)
        f.session.testWebBridgePacket(Bridge.encode(.goodbye, instance: 1), from: Endpoint("127.0.0.1", f.peer.boundPort))
        plugin(f, 2, 0.3); until { f.samples.count == 960 }; XCTAssertEqual(f.samples.last, 0.3)
        hello(f, 1); plugin(f, 1, 0.9); XCTAssertEqual(f.samples.count, 960)
    }
    func testPluginPendingOptionsRevokeBeforeFollowingWorkerBlock() throws {
        let f = try Fixture(); defer { f.cleanup() }; try start(f); try attach(f); hello(f, 1)
        f.session.setAudioOptions(send: true, receive: false, plugins: false, sendPacketSize: .small)
        XCTAssertFalse(try XCTUnwrap(f.producer).isActive); plugin(f, 1, 0.25); XCTAssertTrue(f.samples.isEmpty)
    }

    func testPluginAttachmentNeverPublishesPreRegistrationPartialPacket() throws {
        let f = try Fixture(); defer { f.cleanup() }; try start(f); hello(f, 1)
        let frames = SendPacketSize.small.frames(for: .pcm)
        plugin(f, 1, 0.9, frames: 1); try attach(f)
        plugin(f, 1, 0.2, frames: frames - 1)
        plugin(f, 1, 0.3, frames: frames); until { f.samples.count >= frames * 2 }
        XCTAssertEqual(f.samples, Array(repeating: 0.3, count: frames * 2))
    }

}
