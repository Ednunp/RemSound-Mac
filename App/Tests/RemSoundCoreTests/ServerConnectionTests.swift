import Foundation
import XCTest
@testable import RemSoundCore

final class ServerConnectionTests: XCTestCase {
    private final class LookupFixture {
        private let lock = NSLock()
        private var replies: [(String?) -> Void] = []
        private var cancellations = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return replies.count }
        var cancelled: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
        func lookup(_ host: String, reply: @escaping (String?) -> Void) -> () -> Void {
            lock.lock(); replies.append(reply); lock.unlock()
            return { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.cancellations += 1; self.lock.unlock()
            }
        }
        func complete(_ index: Int, address: String?) {
            lock.lock()
            let reply = replies.indices.contains(index) ? replies[index] : nil
            lock.unlock()
            reply?(address)
        }
    }

    func testStoppedOrDisconnectedSessionCannotJoinAfterDelayedDNS() throws {
        let relay = try UDP(port: 0, loopback: true)
        let fixture = LookupFixture()
        let session = Session(testPeerPort: relay.boundPort, serverLookup: fixture.lookup)
        defer { session.shutdown() }
        let started = expectation(description: "isolated session starts")
        session.onChange = { view in
            guard view.running else { return }
            session.onChange = nil
            started.fulfill()
        }
        session.start(password: "isolated resolver test", peerAddress: "", send: false,
            receive: false, plugins: false, name: "Test")
        wait(for: [started], timeout: 3)
        session.connectServer("first.invalid:\(relay.boundPort)")
        _ = session.testPorts // Fence the real Session owner after requesting DNS.
        XCTAssertEqual(fixture.count, 1)
        session.disconnectServer()
        _ = session.testPorts
        XCTAssertEqual(fixture.cancelled, 1)
        fixture.complete(0, address: "127.0.0.1")
        _ = session.testPorts
        XCTAssertNil(relay.receive(), "Cancelled DNS must not emit a relay join")
        session.connectServer("second.invalid:\(relay.boundPort)")
        _ = session.testPorts
        session.stop()
        _ = session.testPorts
        XCTAssertEqual(fixture.cancelled, 2)
        fixture.complete(1, address: "127.0.0.1")
        _ = session.testPorts
        XCTAssertNil(relay.receive(), "Stopped session must not emit a relay join")
    }

    func testReplacementCancelsOldLookupAndRetainsTypedHostnameAndPort() throws {
        let first = try UDP(port: 0, loopback: true)
        let second = try UDP(port: 0, loopback: true)
        let fixture = LookupFixture()
        let session = Session(testPeerPort: first.boundPort, serverLookup: fixture.lookup)
        defer { session.shutdown() }
        let started = expectation(description: "replacement session starts")
        session.onChange = { view in
            guard view.running else { return }
            session.onChange = nil
            started.fulfill()
        }
        session.start(password: "isolated replacement test", peerAddress: "", send: false,
            receive: false, plugins: false, name: "Test")
        wait(for: [started], timeout: 3)
        session.connectServer("old.invalid:\(first.boundPort)")
        session.connectServer("new.invalid:\(second.boundPort)")
        _ = session.testPorts
        XCTAssertEqual(fixture.count, 2)
        XCTAssertEqual(fixture.cancelled, 1)
        let joined = expectation(description: "only current typed server receives join")
        var fulfilled = false
        session.onJamChange = { view in
            guard !fulfilled, view.serverStatus.hasPrefix("Join request sent") else { return }
            fulfilled = true
            XCTAssertEqual(view.server, "new.invalid:\(second.boundPort)")
            joined.fulfill()
        }
        fixture.complete(0, address: "127.0.0.1")
        fixture.complete(1, address: "127.0.0.1")
        wait(for: [joined], timeout: 3)
        XCTAssertNil(first.receive(), "Old DNS completion must never contact its relay")
        // The main-thread status callback can precede delivery to a nonblocking UDP receiver.
        let deadline = Date().addingTimeInterval(3)
        var packet = second.receive()
        while packet == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            packet = second.receive()
        }
        XCTAssertNotNil(packet, "Current completion must use the selected port")
        XCTAssertNil(first.receive(), "Old DNS completion must not arrive during the current join")
    }
}
