import Foundation
import CryptoKit
import Network
import RemSoundRuntime
import XCTest
@testable import RemSoundCore

final class BrowserListenerServiceTests: XCTestCase {
    private final class Listener: WebRoom.Listener {
        var hold = false, closes = 0, failure: (() -> Void)?, receipt: (() -> Void)?
        var offer: ((WebRoom.Incoming) -> Bool)?
        func start(offer: @escaping (WebRoom.Incoming) -> Bool, failed: @escaping () -> Void) { self.offer = offer; failure = failed }
        func close(completion: @escaping () -> Void) { closes += 1; receipt = completion; if !hold { retire() } }
        func retire() { let callback = receipt; receipt = nil; callback?() }
    }
    private final class Fixture {
        let queue = DispatchQueue(label: "test.browser.facade"), listener = Listener(), request = UUID()
        let binding = SessionNetworkBinding(port: 49211, generation: UUID())
        var service: BrowserListenerService!, actual: SessionNetworkBinding?, bound: ((UInt16) -> Void)?
        var observeReply: ((SessionNetworkBinding?) -> Void)?, attachReply: ((Bool) -> Void)?, producer: WebAudioHandoff.Producer?
        var holdObservation = false, holdAttachment = false, observeAccept = true, attachAccept = true
        var pages = 0, credentials = 0, factories = 0, observations = 0, revokes = 0, attachments = 0
        var missingPage = false, missingCredential = false, pageHook: (() -> Void)?, credentialHook: (() -> Void)?, listenerHook: (() -> Void)?
        init(isolated: Bool = false) {
            actual = binding
            let deps = WebBrowserDependencies(observe: { [weak self] callback in
                guard let self else { return false }; observations += 1; observeReply = callback
                if !holdObservation { callback(actual) }; return observeAccept
            }, revoke: { [weak self] in self?.revokes += 1 }, attach: { [weak self] producer, callback in
                guard let self else { return false }; attachments += 1; self.producer = producer; attachReply = callback
                if !holdAttachment { callback(true) }; return attachAccept
            }, page: { [weak self] in
                guard let self else { return nil }; pages += 1; pageHook?(); return missingPage ? nil : Data("fixed".utf8)
            }, credential: { [weak self] password in
                guard let self else { return nil }; credentials += 1; credentialHook?()
                return missingCredential ? nil : WebAuthentication.Credential.make(password: password, salt: Data(repeating: 0, count: 16), derive: { _, _ in Data(repeating: 1, count: 32) })
            }, listener: { [weak self] _, _, bound in
                guard let self else { return nil }; factories += 1; self.bound = bound; listenerHook?(); return listener
            }, clock: { 100 }, admissionSchedule: { _ in { _, _ in {} } }, peerSchedule: { _ in { _, _ in {} } })
            service = BrowserListenerService(queue: queue, isolated: isolated, dependencies: deps)
        }
        func drain() { for _ in 0..<48 { queue.sync {} } }
        @discardableResult func prepare(_ id: UUID? = nil) -> Bool {
            var answer = false; let admitted = service.prepareStart(id ?? request) { answer = $0 }; drain(); return admitted && answer
        }
        @discardableResult func activate(_ id: UUID? = nil, binding: SessionNetworkBinding? = nil, options: BrowserListenerOptions = .init(enabled: true)) -> Bool {
            let result = service.activate(id ?? request, binding: binding ?? self.binding, options: options, password: "synthetic"); drain(); return result
        }
        func cleanup() {
            _ = service?.shutdown {}; queue.sync { observeReply?(actual); attachReply?(false); listener.hold = false; listener.retire() }; drain(); service = nil; producer = nil; drain()
        }
    }
    func testAudioPreparationOffAndIsolatedNeverLoadsCredentialsOrStartsListener() {
        for isolated in [false,true] {let f=Fixture(isolated:isolated);defer{f.cleanup()};var result=[Bool]()
            XCTAssertTrue(f.service.prepareAudioTransition(UUID()){result.append($0)});f.drain();XCTAssertEqual(result,[true])
            XCTAssertEqual(f.pages+f.credentials+f.factories+f.observations,0)
            XCTAssertFalse(f.service.attachAudio(UUID(),binding:f.binding){_ in XCTFail("No owned listener")})
        }
    }
    func testAudioAttachObservationAndFullCoreShutdownBothRetainCredit() {
        let f=Fixture();defer{f.cleanup()};XCTAssertTrue(f.prepare());XCTAssertTrue(f.activate());f.bound?(47841);f.drain()
        let request=UUID();var prepared=false;XCTAssertTrue(f.service.prepareAudioTransition(request){prepared=$0});f.drain();XCTAssertTrue(prepared)
        f.holdObservation=true;var attached=[Bool](),closed=0
        XCTAssertTrue(f.service.attachAudio(request,binding:f.binding){attached.append($0)});f.drain()
        XCTAssertTrue(f.service.shutdown{closed += 1});f.drain();XCTAssertEqual(closed,0);XCTAssertTrue(attached.isEmpty)
        f.observeReply?(f.binding);f.observeReply?(nil);f.drain();XCTAssertEqual(attached,[false]);XCTAssertEqual(closed,1)
        XCTAssertEqual(f.pages,1);XCTAssertEqual(f.credentials,1);XCTAssertEqual(f.factories,1)
    }
    func testAudioAttachRejectsChangedWorkerObservationBeforeSourceFactory() {
        let f=Fixture();defer{f.cleanup()};XCTAssertTrue(f.prepare());XCTAssertTrue(f.activate());f.bound?(47841);f.drain()
        let request=UUID();var prepared=false;XCTAssertTrue(f.service.prepareAudioTransition(request){prepared=$0});f.drain();XCTAssertTrue(prepared)
        f.actual = .init(port:f.binding.port,generation:UUID());var attached=[Bool]()
        XCTAssertTrue(f.service.attachAudio(request,binding:f.binding){attached.append($0)});f.drain()
        XCTAssertEqual(attached,[false]);XCTAssertEqual(f.attachments,1);XCTAssertEqual(f.service.status.state,.unavailable)
    }
    func testAudioPreparationRetainsCreditThroughItsRawResultCallback() {
        let f=Fixture();defer{f.cleanup()};XCTAssertTrue(f.prepare());XCTAssertTrue(f.activate());f.bound?(47841);f.drain()
        let request=UUID();var callbackReturned=false,closed=0
        XCTAssertTrue(f.service.prepareAudioTransition(request){accepted in
            XCTAssertTrue(accepted);XCTAssertFalse(f.producer?.isActive ?? true)
            XCTAssertFalse(f.service.prepareAudioTransition(UUID()){_ in XCTFail("Reentrant second source operation")})
            XCTAssertFalse(f.service.attachAudio(request,binding:f.binding){_ in XCTFail("Reentrant borrowed source authority")})
            XCTAssertTrue(f.service.shutdown{XCTAssertTrue(callbackReturned);closed += 1})
            XCTAssertEqual(closed,0);callbackReturned=true
        })
        f.drain();XCTAssertTrue(callbackReturned);XCTAssertEqual(closed,1);XCTAssertEqual(f.service.status.state,.closed)
    }
    func testDefaultOptionsAreOffAndAutoStartDoesNotImplyEnabled() {
        XCTAssertEqual(BrowserListenerOptions(), .init(enabled: false, autoStart: false))
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.prepare()); XCTAssertFalse(f.activate(options: .init(autoStart: true)))
        XCTAssertEqual(f.pages, 0); XCTAssertEqual(f.observations, 0); XCTAssertEqual(f.factories, 0)
    }
    func testIsolatedRefusesBeforeAllSensitiveFactories() {
        let f = Fixture(isolated: true); defer { f.cleanup() }; XCTAssertTrue(f.prepare()); XCTAssertFalse(f.activate())
        XCTAssertEqual(f.pages + f.credentials + f.factories + f.observations, 0)
    }
    func testUnpreparedStaleZeroPortAndOversizedPasswordRefuseBeforeQueueWork() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertFalse(f.activate()); XCTAssertTrue(f.prepare())
        XCTAssertFalse(f.activate(UUID())); XCTAssertFalse(f.activate(binding: .init(port: 0, generation: UUID())))
        XCTAssertFalse(f.service.activate(f.request, binding: f.binding, options: .init(enabled: true), password: String(repeating: "é", count: 513)))
        XCTAssertFalse(f.service.activate(f.request, binding: f.binding, options: .init(enabled: true), password: ""))
        XCTAssertEqual(f.observations + f.pages + f.credentials + f.factories, 0)
    }
    func testActualRunningBindingMustMatchBeforePageOrCredential() {
        for wrong in [nil, SessionNetworkBinding(port: 49211, generation: UUID())] {
            let f = Fixture(); defer { f.cleanup() }; f.actual = wrong; XCTAssertTrue(f.prepare()); XCTAssertTrue(f.activate())
            XCTAssertEqual(f.pages + f.credentials + f.factories, 0); XCTAssertEqual(f.service.status.state, .unavailable)
        }
    }
    func testListeningRequiresBothBoundAndWorkerAttachmentReceipts() {
        let f = Fixture(); defer { f.cleanup() }; f.holdAttachment = true; XCTAssertTrue(f.prepare()); XCTAssertTrue(f.activate())
        XCTAssertEqual(f.factories, 1); XCTAssertEqual(f.attachments, 1); XCTAssertEqual(f.service.status.state, .starting)
        f.bound?(47841); f.drain(); XCTAssertEqual(f.service.status.boundPort, 47841); XCTAssertFalse(f.service.status.sourceAttached)
        f.attachReply?(true); f.drain(); XCTAssertEqual(f.service.status.state, .listening); XCTAssertTrue(f.service.status.sourceAttached)
    }
    func testAttachmentAloneIsNotListeningAndFalseAdmissionCannotBeOverridden() {
        let f = Fixture(); defer { f.cleanup() }; f.attachAccept = false; XCTAssertTrue(f.prepare()); XCTAssertTrue(f.activate())
        f.bound?(47841); f.drain(); XCTAssertEqual(f.service.status.state, .unavailable); XCTAssertFalse(f.producer?.isActive ?? true)
    }
    func testMissingPageOrCredentialPreventsNativeFactoryAndRetires() {
        for page in [true, false] {
            let f = Fixture(); defer { f.cleanup() }; f.missingPage = page; f.missingCredential = !page
            XCTAssertTrue(f.prepare()); XCTAssertTrue(f.activate()); XCTAssertEqual(f.factories, 0); XCTAssertEqual(f.attachments, 0)
            XCTAssertEqual(f.credentials, page ? 0 : 1); XCTAssertEqual(f.service.status.state, .unavailable)
        }
    }
    func testStopReentrantDuringPageOrCredentialPreventsListener() {
        for page in [true, false] {
            let f = Fixture(); defer { f.cleanup() }; let hook = { _ = f.service.stop {} }
            if page { f.pageHook = hook } else { f.credentialHook = hook }
            XCTAssertTrue(f.prepare()); XCTAssertTrue(f.activate()); XCTAssertEqual(f.factories, 0); XCTAssertEqual(f.service.status.state, .off)
        }
    }
    func testStopImmediatelyRevokesProducerAndWaitsListenerPlusAttachment() {
        let f = Fixture(); defer { f.cleanup() }; f.holdAttachment = true; XCTAssertTrue(f.prepare()); XCTAssertTrue(f.activate())
        f.queue.sync { f.listener.hold = true }; var done = 0
        XCTAssertTrue(f.service.stop { done += 1 }); XCTAssertFalse(f.producer?.isActive ?? true); f.drain(); XCTAssertEqual(done, 0)
        f.queue.sync { f.listener.retire() }; f.drain(); XCTAssertEqual(done, 0)
        f.attachReply?(true); f.drain(); XCTAssertEqual(done, 1); XCTAssertEqual(f.service.status.state, .off)
    }
    func testPendingObservationIsPartOfStopBarrierAndNoLateSecretWork() {
        let f = Fixture(); defer { f.cleanup() }; f.holdObservation = true; XCTAssertTrue(f.prepare()); XCTAssertTrue(f.activate())
        var done = 0; XCTAssertTrue(f.service.stop { done += 1 }); f.drain(); XCTAssertEqual(done, 0)
        f.observeReply?(f.binding); f.drain(); XCTAssertEqual(done, 1); XCTAssertEqual(f.pages + f.credentials + f.factories, 0)
    }
    func testOnlyNewestPrepareCanStartAfterExactOldRetirement() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.prepare()); XCTAssertTrue(f.activate())
        f.queue.sync { f.listener.hold = true }; let old = UUID(), latest = UUID(); var replies = [Bool]()
        XCTAssertTrue(f.service.prepareStart(old) { replies.append($0) }); XCTAssertTrue(f.service.prepareStart(latest) { replies.append($0) })
        f.drain(); XCTAssertEqual(replies, []); XCTAssertFalse(f.activate(latest))
        f.queue.sync { f.listener.retire() }; f.drain(); XCTAssertEqual(replies, [false, true]); XCTAssertFalse(f.activate(old)); XCTAssertTrue(f.activate(latest))
    }
    func testSinglePendingActivationBoundsSecretAndObservationWork() {
        let f = Fixture(); defer { f.cleanup() }; f.holdObservation = true; XCTAssertTrue(f.prepare()); XCTAssertTrue(f.activate())
        for _ in 0..<1000 { XCTAssertFalse(f.service.activate(f.request, binding: f.binding, options: .init(enabled: true), password: "synthetic")) }
        f.drain(); XCTAssertEqual(f.observations, 1); XCTAssertEqual(f.pages, 0)
    }
    func testBoundedCoalescedWaitersRefuseWithoutCallback() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.prepare()); XCTAssertTrue(f.activate()); f.queue.sync { f.listener.hold = true }
        var done = 0; for _ in 0..<16 { XCTAssertTrue(f.service.stop { done += 1 }) }
        XCTAssertFalse(f.service.stop { done += 1000 }); f.drain(); XCTAssertEqual(done, 0)
        f.queue.sync { f.listener.retire() }; f.drain(); XCTAssertEqual(done, 16)
    }
    func testNativeFailureImmediatelyRevokesAndWaitsExactReceipt() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.prepare()); XCTAssertTrue(f.activate()); f.bound?(47841); f.drain()
        f.queue.sync { f.listener.hold = true; f.listener.failure?() }; f.drain()
        XCTAssertFalse(f.producer?.isActive ?? true); XCTAssertEqual(f.service.status.state, .unavailable); XCTAssertTrue(f.service.status.retiring)
        var done = 0; XCTAssertTrue(f.service.stop { done += 1 }); f.drain(); XCTAssertEqual(done, 0)
        f.queue.sync { f.listener.retire() }; f.drain(); XCTAssertEqual(done, 1)
    }
    func testShutdownPermanentAndCallbacksRunOnUtilityOwner() {
        let f = Fixture(); defer { f.cleanup() }; let key = DispatchSpecificKey<Int>(); f.queue.setSpecific(key: key, value: 1); var done = 0
        XCTAssertTrue(f.service.shutdown { XCTAssertEqual(DispatchQueue.getSpecific(key: key), 1); done += 1 }); f.drain()
        XCTAssertEqual(done, 1); XCTAssertEqual(f.service.status.state, .closed); XCTAssertFalse(f.prepare()); XCTAssertFalse(f.activate())
    }
    func testReleaseRevokesAndRetainsCleanupUntilNativeReceipt() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.prepare()); XCTAssertTrue(f.activate()); f.queue.sync { f.listener.hold = true }
        f.service = nil; f.drain(); XCTAssertFalse(f.producer?.isActive ?? true); XCTAssertEqual(f.listener.closes, 1)
        f.queue.sync { f.listener.retire() }; f.drain()
    }
    func testReentrantListenerFactoryStopWaitsReturnedResourceReceipt() {
        let f = Fixture(); defer { f.cleanup() }; var done = 0
        f.listener.hold = true; f.listenerHook = { XCTAssertTrue(f.service.stop { done += 1 }) }
        XCTAssertTrue(f.prepare()); XCTAssertTrue(f.activate()); XCTAssertEqual(done, 0); XCTAssertTrue(f.service.status.retiring)
        XCTAssertEqual(f.listener.closes, 1); f.queue.sync { f.listener.retire() }; f.drain(); XCTAssertEqual(done, 1)
    }
    func testFirstForeignObservationAndAttachmentReceiptsWin() {
        let f = Fixture(); defer { f.cleanup() }; f.holdObservation = true; f.holdAttachment = true
        XCTAssertTrue(f.prepare()); XCTAssertTrue(f.activate()); let observed = f.observeReply
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { observed?(f.binding); observed?(nil); done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success); f.drain(); XCTAssertEqual(f.factories, 1)
        let attached = f.attachReply
        DispatchQueue.global().async { attached?(true); attached?(false); done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success); f.drain(); XCTAssertTrue(f.service.status.sourceAttached)
    }
    func testRefusedObservationCannotBeOverriddenByInlinePositiveReceipt() {
        let f = Fixture(); defer { f.cleanup() }; f.observeAccept = false; XCTAssertTrue(f.prepare()); XCTAssertTrue(f.activate())
        XCTAssertEqual(f.factories + f.pages + f.attachments, 0); XCTAssertEqual(f.service.status.state, .unavailable)
    }
    func testLateOldBoundAndAttachCannotChangeNewVisit() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.prepare()); XCTAssertTrue(f.activate())
        let bound = f.bound, attached = f.attachReply; XCTAssertTrue(f.service.stop {}); f.drain()
        let next = UUID(); XCTAssertTrue(f.prepare(next)); XCTAssertTrue(f.activate(next))
        bound?(47842); attached?(false); f.drain(); XCTAssertNil(f.service.status.boundPort); XCTAssertTrue(f.service.status.sourceAttached)
        f.bound?(47841); f.drain(); XCTAssertEqual(f.service.status.state, .listening)
    }
    func testRepeatedCallerRequestUUIDStillOnlyCompletesNewestPrepare() {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.prepare()); XCTAssertTrue(f.activate()); f.listener.hold = true
        var replies = [Bool]()
        XCTAssertTrue(f.service.prepareStart(f.request) { replies.append($0) }); XCTAssertTrue(f.service.prepareStart(f.request) { replies.append($0) })
        f.queue.sync { f.listener.retire() }; f.drain(); XCTAssertEqual(replies, [false, true])
    }
    private final class Incoming: WebRoom.Incoming {
        final class Transport: WebConnection.Transport {
            var read: ((WebConnection.Read) -> Void)?, writes = [Data]()
            func read(maximum: Int, completion: @escaping (WebConnection.Read) -> Void) { read = completion }
            func write(_ data: Data, completion: @escaping (Int?) -> Void) { writes.append(data); completion(data.count) }
            func close(completion: @escaping () -> Void) { let reply = read; read = nil; reply?(.end); completion() }
        }
        let raw = Transport()
        func transport(permitted: @escaping () -> Bool) -> WebConnection.Transport? { raw }
        func close(completion: @escaping () -> Void) { raw.close(completion: completion) }
    }
    func testFacadeAutoStartReachesActualChallengeAndWelcome() throws {
        let f = Fixture(); defer { f.cleanup() }; XCTAssertTrue(f.prepare()); XCTAssertTrue(f.activate(options: .init(enabled: true, autoStart: true)))
        let child = Incoming()
        f.queue.sync { XCTAssertTrue(f.listener.offer?(child) ?? false) }; f.drain()
        f.queue.sync { child.raw.read?(.bytes(Data("GET /listen HTTP/1.1\r\nHost: 127.0.0.1:47840\r\nOrigin: http://127.0.0.1:47840\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n".utf8))) }; f.drain()
        func object(_ frame: Data) throws -> [String: Any] {
            let reader = WebSocketPackets.Reader(fromClient: false)
            guard case .text(let bytes) = reader.feed(frame).event else { XCTFail("Missing actual protocol text receipt"); return [:] }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        }
        var frames = [Data](); f.queue.sync { frames = child.raw.writes }
        guard frames.count >= 2 else { return XCTFail("Missing challenge") }
        let challenge = try object(frames[1]); XCTAssertEqual(challenge["autoStart"] as? Bool, true)
        let nonce = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(challenge["nonce"] as? String)))
        let proof = Data(HMAC<SHA256>.authenticationCode(for: nonce, using: SymmetricKey(data: Data(repeating: 1, count: 32))))
        let answer = try JSONSerialization.data(withJSONObject: ["response": proof.base64EncodedString(), "codec": "pcm"])
        XCTAssertLessThan(answer.count, 126)
        f.queue.sync { child.raw.read?(.bytes(Data([0x81, 0x80 | UInt8(answer.count), 0, 0, 0, 0]) + answer)) }; f.drain()
        f.queue.sync { frames = child.raw.writes }
        guard frames.count >= 3 else { return XCTFail("Missing welcome") }
        let welcome = try object(frames[2]); XCTAssertEqual(welcome["type"] as? String, "welcome"); XCTAssertEqual(welcome["autoStart"] as? Bool, true)
    }
    func testActualStoppedSessionObservationReturnsNilOnWorkerWithoutStartingResources() throws {
        let session = Session(testPeerPort: 1)
        let observed = expectation(description: "actual stopped network observation"), closed = expectation(description: "stopped Session closed")
        XCTAssertTrue(session.observeWebNetworkBinding { binding in XCTAssertNil(binding); XCTAssertFalse(Thread.isMainThread); observed.fulfill() })
        wait(for: [observed], timeout: 2); XCTAssertEqual(session.testPorts.audio, 0); XCTAssertEqual(session.testPorts.bridge, 0)
        session.shutdown { closed.fulfill() }; wait(for: [closed], timeout: 2)
    }
    func testOwnedEphemeralNativePageWithActualSessionAdapterAndFullRetirement() throws {
        let peer = try UDP(port: 0, loopback: true), session = Session(testPeerPort: peer.boundPort)
        let queue = DispatchQueue(label: "test.browser.facade.owned.native")
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]))
            .appendingPathComponent("browser-native-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try RuntimeConfiguration(options: LaunchOptions.parse(["--config-dir", root.path, "--headless", "--silent"]))
        let started = expectation(description: "owned Session socket"), prepared = expectation(description: "source/Room ready for new visit")
        let received = expectation(description: "exact shared page received"), clientClosed = expectation(description: "owned client cancelled")
        let listenerClosed = expectation(description: "facade listener/child/source/attachment retired"), sessionClosed = expectation(description: "Session timers/sockets retired")
        var binding: SessionNetworkBinding?
        session.start(password: "synthetic", peerAddress: "", send: false, receive: false, plugins: false, name: "Test", networkCompletion: { binding = $0; started.fulfill() })
        wait(for: [started], timeout: 3); let actual = try XCTUnwrap(binding)
        var deps = WebBrowserDependencies.native(runtime, session)
        let page = try XCTUnwrap(WebListenerPage.load()); var connection: NWConnection?, bytes = Data(), complete = false
        // Explicit owned-test assembly; the normal isolated constructor remains refused.
        deps.admissionSchedule = { WebNativeTransport.schedule(permitted: $0) }
        deps.peerSchedule = { WebNativeListener.nativeSchedule(permitted: $0) }
        deps.listener = { queue, permission, bound in
            WebNativeListener.ownedLoopback(queue: queue, permitted: permission, bound: { port in
                XCTAssertNotEqual(port, WebNativeListener.defaultPort); bound(port)
                let client = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp); connection = client
                client.stateUpdateHandler = { state in switch state {
                case .ready:
                    client.send(content: Data("GET / HTTP/1.1\r\nHost: 127.0.0.1:47840\r\n\r\n".utf8), completion: .contentProcessed { XCTAssertNil($0) })
                    func read() {
                        client.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, end, error in
                            guard !complete else { return }; XCTAssertNil(error)
                            if let data { bytes.append(data) }; XCTAssertLessThanOrEqual(bytes.count, 65536)
                            if end {
                                complete = true
                                let split = bytes.range(of: Data("\r\n\r\n".utf8)); XCTAssertNotNil(split)
                                if let split { XCTAssertEqual(Data(bytes.suffix(from: split.upperBound)), page) }
                                XCTAssertTrue(String(decoding: bytes.prefix(16), as: UTF8.self).hasPrefix("HTTP/1.1 200 "))
                                received.fulfill(); client.cancel()
                            } else { read() }
                        }
                    }; read()
                case .cancelled: clientClosed.fulfill()
                case .failed(let error): if !complete { XCTFail("Owned page failed before full receipt: \(error)") }; client.cancel()
                default: break
                } }; client.start(queue: queue)
            })
        }
        let service = BrowserListenerService(queue: queue, isolated: false, dependencies: deps), request = UUID()
        XCTAssertTrue(service.prepareStart(request) { XCTAssertTrue($0); prepared.fulfill() }); wait(for: [prepared], timeout: 2)
        let configured = expectation(description: "actual bind and Session attachment receipt")
        var configurationPort: UInt16?
        XCTAssertTrue(service.activate(request, binding: actual, options: .init(enabled: true), password: "synthetic") { result in
            guard case .listening(let port) = result else { return XCTFail("Native configuration did not complete") }
            configurationPort = port; configured.fulfill()
        })
        wait(for: [configured, received, clientClosed], timeout: 5)
        XCTAssertEqual(service.status.boundPort, configurationPort)
        XCTAssertEqual(service.status.state, .listening); XCTAssertTrue(service.status.sourceAttached)
        XCTAssertTrue(service.shutdown { listenerClosed.fulfill() }); wait(for: [listenerClosed], timeout: 3)
        session.shutdown { sessionClosed.fulfill() }; wait(for: [sessionClosed], timeout: 3)
        queue.sync { connection?.stateUpdateHandler = nil; connection = nil }
        XCTAssertEqual(session.testPorts.audio, 0); XCTAssertEqual(session.testPorts.discovery, 0); XCTAssertEqual(session.testPorts.bridge, 0)
        XCTAssertEqual(service.status.state, .closed)
    }
    func testStoppedActivationNeedsActualNilObservationAndRealBindButNoAudioAttachment() {
        let f=Fixture();defer{f.cleanup()};f.actual=nil;XCTAssertTrue(f.prepare());var results=[BrowserListenerActivationResult]()
        XCTAssertTrue(f.service.activateStopped(f.request,options:.init(enabled:true),password:"synthetic"){results.append($0)})
        f.drain();XCTAssertEqual(f.factories,1);XCTAssertEqual(f.attachments,0);XCTAssertNil(f.producer)
        XCTAssertEqual(f.service.status.state,.starting);XCTAssertTrue(results.isEmpty)
        f.bound?(0);f.drain();XCTAssertTrue(results.isEmpty)
        f.bound?(49292);f.drain();XCTAssertEqual(results,[.listening(port:49292)]);XCTAssertFalse(f.service.status.sourceAttached)
        XCTAssertEqual(f.service.status.state,.listening);f.bound?(49292);f.drain();XCTAssertEqual(results.count,1)
        var address:BrowserListenerAddressResult?;XCTAssertTrue(f.service.refreshAddress {address=$0});f.drain();XCTAssertEqual(address,.unavailable);XCTAssertFalse(f.service.status.sourceAttached)
    }
    func testStoppedActivationCannotRelabelARunningSessionBeforeSensitiveFactories() {
        let f=Fixture();defer{f.cleanup()};XCTAssertTrue(f.prepare());var result:BrowserListenerActivationResult?
        XCTAssertTrue(f.service.activateStopped(f.request,options:.init(enabled:true),password:"synthetic"){result=$0});f.drain()
        XCTAssertEqual(result,.unavailable);XCTAssertEqual(f.pages+f.credentials+f.factories+f.attachments,0)
    }
    func testStoppedActivationIsolationOffStaleAndSecretBoundsRefuseBeforeObservation() {
        for isolated in [true,false] {
            let f=Fixture(isolated:isolated);defer{f.cleanup()};f.actual=nil;XCTAssertTrue(f.prepare())
            func refused(_ id:UUID,_ options:BrowserListenerOptions,_ password:String) {
                XCTAssertFalse(f.service.activateStopped(id,options:options,password:password){_ in XCTFail("Refused callback")})
            }
            refused(UUID(),.init(enabled:true),"synthetic");refused(f.request,.init(),"synthetic")
            refused(f.request,.init(enabled:true),"");refused(f.request,.init(enabled:true),String(repeating:"é",count:513))
            if isolated {refused(f.request,.init(enabled:true),"synthetic")}
            f.drain();XCTAssertEqual(f.observations+f.pages+f.credentials+f.factories,0)
        }
    }
    func testStoppedCancelWaitsRawObservationAndNeverBorrowsAnObsoleteSecret() {
        let f=Fixture();defer{f.cleanup()};f.actual=nil;f.holdObservation=true;XCTAssertTrue(f.prepare())
        var result:BrowserListenerActivationResult?,closed=false
        XCTAssertTrue(f.service.activateStopped(f.request,options:.init(enabled:true),password:"synthetic"){result=$0});f.drain()
        XCTAssertTrue(f.service.shutdown{closed=true});f.drain();XCTAssertFalse(closed);XCTAssertNil(result)
        f.observeReply?(nil);f.drain();XCTAssertTrue(closed);XCTAssertEqual(result,.cancelled)
        XCTAssertEqual(f.pages+f.credentials+f.factories+f.attachments,0)
    }
    func testStoppedBindFailureWaitsActualRoomRetirement() {
        let f=Fixture();defer{f.cleanup()};f.actual=nil;XCTAssertTrue(f.prepare());var result:BrowserListenerActivationResult?
        XCTAssertTrue(f.service.activateStopped(f.request,options:.init(enabled:true),password:"synthetic"){result=$0});f.drain()
        f.queue.sync{f.listener.hold=true;f.listener.failure?()};f.drain();XCTAssertNil(result)
        XCTAssertTrue(f.service.status.retiring);XCTAssertEqual(f.attachments,0)
        f.queue.sync{f.listener.retire()};f.drain();XCTAssertEqual(result,.unavailable);XCTAssertFalse(f.service.status.retiring)
    }
    func testStoppedReentrantCredentialStopCannotConstructNativeListener() {
        let f=Fixture();defer{f.cleanup()};f.actual=nil;XCTAssertTrue(f.prepare());var result:BrowserListenerActivationResult?
        f.credentialHook={_=f.service.stop{}}
        XCTAssertTrue(f.service.activateStopped(f.request,options:.init(enabled:true),password:"synthetic"){result=$0});f.drain()
        XCTAssertEqual(result,.cancelled);XCTAssertEqual(f.factories+f.attachments,0)
    }

}
