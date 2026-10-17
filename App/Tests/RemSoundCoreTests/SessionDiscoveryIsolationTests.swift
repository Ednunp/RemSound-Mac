import Foundation
import XCTest
@testable import RemSoundCore

final class SessionDiscoveryIsolationTests: XCTestCase {
    func testIsolatedStartupAndStopNeverAdvertiseToNormalDiscovery() throws {
        let lock = NSLock()
        var announcements = 0
        // Intercept every discovery send, including a faulty one, before any LAN packet can escape.
        let session = Session(testPeerPort: 0, announcementSender: { _, _ in
            lock.lock(); announcements += 1; lock.unlock()
        })
        defer { session.shutdown() }
        let started = expectation(description: "isolated session starts")
        session.onChange = { view in
            guard view.running else { return }
            session.onChange = nil
            started.fulfill()
        }
        session.start(password: "isolated discovery test", peerAddress: "", send: false,
            receive: false, plugins: false, name: "Discovery test")
        wait(for: [started], timeout: 3)
        let ports = session.testPorts
        XCTAssertNotEqual(ports.audio, 0)
        XCTAssertNotEqual(ports.audio, Wire.audioPort)
        XCTAssertNotEqual(ports.discovery, 0)
        XCTAssertNotEqual(ports.discovery, Wire.discoveryPort)
        let elapsed = expectation(description: "two discovery deadlines elapse")
        DispatchQueue.main.asyncAfter(deadline: .now() + Wire.discoveryInterval + 0.2) { elapsed.fulfill() }
        wait(for: [elapsed], timeout: 3)
        session.shutdown()
        lock.lock(); let observed = announcements; lock.unlock()
        XCTAssertEqual(observed, 0, "A silent test must not create peer cues in the normal app")
    }
}
