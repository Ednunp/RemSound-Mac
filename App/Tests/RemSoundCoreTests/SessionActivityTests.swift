import Foundation
import XCTest
@testable import RemSoundCore

final class SessionActivityTests: XCTestCase {
    func testBalancedIdempotentLifetimeAllowsSystemAndDisplaySleep() {
        var began = 0, ended = 0
        let token = NSObject()
        var activity: SessionActivity? = SessionActivity(begin: { options, _ in
            XCTAssertEqual(options, .userInitiatedAllowingIdleSystemSleep)
            XCTAssertFalse(options.contains(.idleSystemSleepDisabled))
            XCTAssertFalse(options.contains(.idleDisplaySleepDisabled))
            began += 1
            return token
        }, end: { received in
            XCTAssertTrue(received === token)
            ended += 1
        })
        for _ in 0..<100 {
            activity?.start()
            activity?.start()
            activity?.stop()
            activity?.stop()
        }
        activity?.start()
        activity = nil
        XCTAssertEqual(began, 101)
        XCTAssertEqual(ended, began)
    }

    func testSessionRestartAndAsynchronousShutdownBalanceActivity() throws {
        var began = 0, ended = 0
        let activity = SessionActivity(begin: { _, _ in began += 1; return NSObject() },
            end: { _ in ended += 1 })
        let listener = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: listener.boundPort, activity: activity)
        defer { session.shutdown() }
        for index in 1...3 {
            let alias = "Private activity \(index)"
            let started = expectation(description: "started \(index)")
            session.onChange = { view in
                guard view.peers.contains(where: { $0.name == alias }) else { return }
                session.onChange = nil
                XCTAssertTrue(view.running)
                XCTAssertEqual(began, index)
                XCTAssertEqual(ended, index - 1)
                started.fulfill()
            }
            session.start(password: "private activity fixture", peerAddress: "127.0.0.1",
                send: false, receive: false, plugins: false, name: "Private activity fixture",
                peerAliases: ["127.0.0.1": alias])
            wait(for: [started], timeout: 3)
        }
        let stopped = expectation(description: "asynchronous shutdown")
        session.shutdown { stopped.fulfill() }
        wait(for: [stopped], timeout: 3)
        XCTAssertEqual(ended, began)
        session.shutdown()
        XCTAssertEqual(ended, began)
    }
}
