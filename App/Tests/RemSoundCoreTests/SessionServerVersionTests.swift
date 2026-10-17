import Foundation
import XCTest
import RemSoundJam
@testable import RemSoundCore

final class SessionServerVersionTests: XCTestCase {
    private final class Probe {
        private let lock = NSLock()
        private var replies: [(ServerVersionProbe.Result) -> Void] = []
        private var cancellations = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return replies.count }
        var cancelled: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
        func start(_ endpoint: Endpoint, _ reply: @escaping (ServerVersionProbe.Result) -> Void) -> () -> Void {
            lock.lock(); replies.append(reply); lock.unlock()
            return { self.lock.lock(); self.cancellations += 1; self.lock.unlock() }
        }
        func answer(_ index: Int = 0, version: String? = "server-v2.16", answered: Bool = true, full: Bool = false) {
            lock.lock(); let reply = replies.indices.contains(index) ? replies[index] : nil; lock.unlock()
            reply?(.init(answered: answered, version: version, roundTripMs: nil, full: full))
        }
    }
    private func fixture(_ relay: UDP, _ probe: Probe, startup: Bool = false, warnings: Bool = true) -> Session {
        let session = Session(testPeerPort: relay.boundPort, serverProbe: probe.start,
            latestServerRelease: { reply in reply("server-v2.17"); return {} }, serverVersionWarnings: warnings)
        addTeardownBlock { session.shutdown() }
        let started = expectation(description: "request start receipt")
        session.start(password: "isolated version fixture", peerAddress: "", send: false, receive: false,
            plugins: false, name: "Test", serverAddress: startup ? "127.0.0.1:\(relay.boundPort)" : nil,
            completion: { receipt in XCTAssertEqual(receipt?.running, true); started.fulfill() })
        wait(for: [started], timeout: 3)
        return session
    }
    private func fence(_ session: Session) { _ = session.testPorts }
    private func waitProbes(_ session: Session, _ probe: Probe, count: Int) {
        let until = Date().addingTimeInterval(1)
        while probe.count < count && Date() < until { fence(session); Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertEqual(probe.count, count, "wait for actual resolver callback and probe registration")
    }
    private func waitJoin(_ relay: UDP) throws -> (Data, Endpoint) {
        let until = Date().addingTimeInterval(2)
        while Date() < until {
            if let (data, ep) = relay.receive(), data.count > 5, data[5] == 6 { return (data, ep) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        throw NSError(domain: "no current join", code: 1)
    }
    func testOldServerIsNotJoinedBeforeCancel() throws {
        let relay = try UDP(port: 0, loopback: true), probe = Probe(), session = fixture(relay, probe)
        let warning = expectation(description: "before-connection warning")
        session.onServerVersionWarning = { details, answer in
            XCTAssertTrue(Thread.isMainThread); XCTAssertTrue(details.beforeConnecting); XCTAssertTrue(details.isCurrent())
            XCTAssertEqual(details.version, "server-v2.16"); XCTAssertEqual(details.latestReleased, "server-v2.17")
            XCTAssertNil(relay.receive()); answer(false); warning.fulfill()
        }
        session.connectServer("127.0.0.1:\(relay.boundPort)"); waitProbes(session, probe, count: 1)
        XCTAssertEqual(probe.count, 1); XCTAssertNil(relay.receive())
        probe.answer(); wait(for: [warning], timeout: 1); fence(session)
        XCTAssertNil(relay.receive())
    }
    func testConnectAnywayAndDuplicateDecisionOnlyJoinOnce() throws {
        let relay = try UDP(port: 0, loopback: true), probe = Probe(), session = fixture(relay, probe)
        let warning = expectation(description: "explicit consent")
        session.onServerVersionWarning = { details, answer in
            answer(true); answer(false); warning.fulfill()
        }
        session.connectServer("127.0.0.1:\(relay.boundPort)"); waitProbes(session, probe, count: 1); probe.answer()
        wait(for: [warning], timeout: 1)
        _ = try waitJoin(relay); fence(session)
        let bytes = relay.receive()?.0
        XCTAssertFalse(bytes?.count ?? 0 > 5 && bytes?[5] == 9, "duplicate Cancel cannot retire accepted connection")
    }
    func testCurrentServerSkipsWarningAndRetainsOriginalEntry() throws {
        let relay = try UDP(port: 0, loopback: true), probe = Probe(), session = fixture(relay, probe)
        var warnings = 0; session.onServerVersionWarning = { _, _ in warnings += 1 }
        let ready = expectation(description: "checked current join")
        session.onJamChange = { v in if v.serverStatus.hasPrefix("Join request sent") { XCTAssertEqual(v.server, "127.0.0.1:\(relay.boundPort)"); session.onJamChange = nil; ready.fulfill() } }
        session.connectServer(" 127.0.0.1:\(relay.boundPort) "); waitProbes(session, probe, count: 1); probe.answer(version: "server-v2.17")
        wait(for: [ready], timeout: 1); XCTAssertEqual(warnings, 0); _ = try waitJoin(relay)
    }
    func testServerReplacementAndStopCancelPendingProbeAndRejectLateReceipt() throws {
        let first = try UDP(port: 0, loopback: true), second = try UDP(port: 0, loopback: true), probe = Probe(), session = fixture(first, probe)
        session.connectServer("127.0.0.1:\(first.boundPort)"); waitProbes(session, probe, count: 1)
        session.connectServer("127.0.0.1:\(second.boundPort)"); waitProbes(session, probe, count: 2)
        XCTAssertEqual(probe.count, 2); XCTAssertEqual(probe.cancelled, 1)
        probe.answer(0, version: "server-v2.17"); fence(session); XCTAssertNil(first.receive()); XCTAssertNil(second.receive())
        session.stop(); fence(session); XCTAssertEqual(probe.cancelled, 2)
        probe.answer(1, version: "server-v2.17"); fence(session)
        XCTAssertNil(first.receive()); XCTAssertNil(second.receive())
    }
    func testStartupUsesSameGateAndStopRetiresQueuedMainWarning() throws {
        let relay = try UDP(port: 0, loopback: true), probe = Probe(), session = fixture(relay, probe, startup: true)
        let warning = expectation(description: "startup gate")
        var saved: ((Bool) -> Void)?, current: (() -> Bool)?
        session.onServerVersionWarning = { details, answer in current = details.isCurrent; saved = answer; warning.fulfill() }
        waitProbes(session, probe, count: 1); XCTAssertNil(relay.receive())
        probe.answer(); wait(for: [warning], timeout: 1)
        session.stop(); fence(session); XCTAssertEqual(current?(), false)
        saved?(true); fence(session); XCTAssertNil(relay.receive())
    }
    func testSilentIsolationConnectsWithoutCallingNativeWarning() throws {
        let relay = try UDP(port: 0, loopback: true), probe = Probe(), session = fixture(relay, probe, warnings: false)
        var warned = 0; session.onServerVersionWarning = { _, _ in warned += 1 }
        session.connectServer("127.0.0.1:\(relay.boundPort)"); waitProbes(session, probe, count: 1); probe.answer()
        _ = try waitJoin(relay); XCTAssertEqual(warned, 0)
    }
    func testNoAnswerJoinsAndLateOldStatusCanLeaveCurrentServer() throws {
        let relay = try UDP(port: 0, loopback: true), probe = Probe(), session = fixture(relay, probe)
        let late = expectation(description: "late warning"), left = expectation(description: "actual late Cancel departure")
        var warningDelivered = false, departureDelivered = false
        session.onJamChange = { view in
            if warningDelivered, !departureDelivered, view.server.isEmpty {
                departureDelivered = true; XCTAssertFalse(view.connected); XCTAssertNil(view.serverDetails); left.fulfill()
            }
        }
        session.onServerVersionWarning = { details, answer in
            XCTAssertFalse(details.beforeConnecting); warningDelivered = true; answer(false); late.fulfill()
        }
        session.connectServer("127.0.0.1:\(relay.boundPort)"); waitProbes(session, probe, count: 1); probe.answer(version: nil, answered: false)
        let (_, ep) = try waitJoin(relay)
        let packet: (UInt8, [UInt8]) -> Data = { Data(JamWire.header($0, version: 2) + [UInt8](repeating: 0, count: 16) + $1) }
        _ = relay.send(packet(7, [0, 0]), to: ep)
        let version = Array("server-v2.16".utf8)
        _ = relay.send(packet(14, [1, UInt8(version.count)] + version + [UInt8](repeating: 0, count: 24)), to: ep)
        wait(for: [late, left], timeout: 2); fence(session)
    }
    func testStopBeforeMainDeliverySuppressesObsoleteQuestion() throws {
        let relay = try UDP(port: 0, loopback: true), probe = Probe(), session = fixture(relay, probe)
        var questions = 0; session.onServerVersionWarning = { _, _ in questions += 1 }
        session.connectServer("127.0.0.1:\(relay.boundPort)"); waitProbes(session, probe, count: 1)
        probe.answer(); fence(session); session.stop(); fence(session)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(questions, 0); XCTAssertNil(relay.receive())
    }
    func testDelayedReleaseReceiptAfterStopCannotJoinOrWarn() throws {
        let relay = try UDP(port: 0, loopback: true), probe = Probe(), session = fixture(relay, probe)
        var release: ((String?) -> Void)?, cancelled = 0, questions = 0
        session.fetchServerRelease = { reply in release = reply; return { cancelled += 1 } }
        session.onServerVersionWarning = { _, _ in questions += 1 }
        session.connectServer("127.0.0.1:\(relay.boundPort)"); waitProbes(session, probe, count: 1); probe.answer(version: "server-v2.17"); fence(session)
        XCTAssertNotNil(release); XCTAssertNil(relay.receive())
        session.stop(); fence(session); XCTAssertEqual(cancelled, 1)
        release?("server-v2.99"); fence(session)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(questions, 0); XCTAssertNil(relay.receive())
    }

    func testRequiredWarningWithoutAHandlerDoesNotSilentlyJoin() throws {
        let relay = try UDP(port: 0, loopback: true), probe = Probe(), session = fixture(relay, probe)
        let refused = expectation(description: "missing required warning handler is a refusal")
        var delivered = false
        session.onJamChange = { view in
            if !delivered, view.serverStatus.hasPrefix("Not connected:") { delivered = true; refused.fulfill() }
        }
        session.connectServer("127.0.0.1:\(relay.boundPort)"); waitProbes(session, probe, count: 1); probe.answer()
        wait(for: [refused], timeout: 1); fence(session); XCTAssertNil(relay.receive())
    }
    func testKnownOlderProbeImmediatelyReachesStatusWhenConnectedAnyway() throws {
        let relay = try UDP(port: 0, loopback: true), probe = Probe(), session = fixture(relay, probe, warnings: false)
        session.connectServer("127.0.0.1:\(relay.boundPort)"); waitProbes(session, probe, count: 1); probe.answer(version: nil)
        let (_, ep) = try waitJoin(relay)
        let shown = expectation(description: "known older status without an eight-second wait")
        var delivered = false
        session.onJamChange = { view in
            if !delivered, view.serverDetails?.contains("older than server-v2.16") == true { delivered = true; shown.fulfill() }
        }
        _ = relay.send(Data(JamWire.header(7, version: 2) + [UInt8](repeating: 0, count: 16) + [0, 0]), to: ep)
        wait(for: [shown], timeout: 1)
    }

    func testLaterStatusSupersedesInitialKnownOlderProbe() throws {
        let relay = try UDP(port: 0, loopback: true), probe = Probe(), session = fixture(relay, probe, warnings: false)
        session.connectServer("127.0.0.1:\(relay.boundPort)"); waitProbes(session, probe, count: 1); probe.answer(version: nil)
        let (_, ep) = try waitJoin(relay)
        let old = expectation(description: "initial older status"), updated = expectation(description: "late modern status supersedes probe")
        var oldSeen = false, newSeen = false
        session.onJamChange = { view in
            if !oldSeen, view.serverDetails?.contains("older than server-v2.16") == true { oldSeen = true; old.fulfill() }
            if !newSeen, view.serverDetails?.contains("Server version server-v2.17.") == true {
                newSeen = true; XCTAssertFalse(view.serverDetails?.contains("older than server-v2.16") == true); updated.fulfill()
            }
        }
        let header: (UInt8) -> [UInt8] = { JamWire.header($0, version: 2) + [UInt8](repeating: 0, count: 16) }
        _ = relay.send(Data(header(7) + [0, 0]), to: ep); wait(for: [old], timeout: 1)
        let version = Array("server-v2.17".utf8)
        _ = relay.send(Data(header(14) + [1, UInt8(version.count)] + version + [UInt8](repeating: 0, count: 24)), to: ep)
        wait(for: [updated], timeout: 2)
    }

}
