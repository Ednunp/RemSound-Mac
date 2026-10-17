import XCTest
@testable import RemSoundCore

final class SessionPushToTalkReceiptTests: XCTestCase {
    private func fixture() throws -> (UDP, Session) {
        let peer = try UDP(port: 0, loopback: true), session = Session(testPeerPort: peer.boundPort)
        addTeardownBlock { withExtendedLifetime(peer) { session.shutdown() } }; return (peer, session)
    }
    private func settings() -> PushToTalkSettings { var s = PushToTalkSettings(); s.enabled = true; return s }
    func testStartReceiptIsOnMainAfterMatchingPublishedView() throws {
        let (peer, session) = try fixture(); _ = peer
        let done = expectation(description: "actual start completion"), wanted = settings(); var view: SessionView?
        session.onChange = { view = $0 }
        session.start(password: "isolated receipt", peerAddress: "", send: false, receive: false, plugins: false, name: "Test", pushToTalk: wanted) { result in
            XCTAssertTrue(Thread.isMainThread); XCTAssertTrue(result?.running == true)
            XCTAssertEqual(result?.settings, wanted); XCTAssertEqual(result?.generation, view?.pushToTalkKeyGeneration)
            XCTAssertTrue(view?.running == true); done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }
    func testFailedStartCompletesOnceWithNilAfterStoppedPublishedView() throws {
        let (peer, session) = try fixture(); _ = peer
        let done = expectation(description: "actual failed start receipt"); done.assertForOverFulfill = true
        var view: SessionView?
        session.onChange = { view = $0 }
        session.start(password: "", peerAddress: "", send: false, receive: false, plugins: false, name: "Test", pushToTalk: settings()) { result in
            XCTAssertTrue(Thread.isMainThread); XCTAssertNil(result); XCTAssertEqual(view?.running, false); done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }
    func testStoppedOptionsCompleteOnceWithFailureWithoutPublishingRunning() throws {
        let (peer, session) = try fixture(); _ = peer
        let done = expectation(description: "stopped request completion"); done.assertForOverFulfill = true
        session.setAudioOptions(send: false, receive: false, plugins: false, pushToTalk: settings()) { result in
            XCTAssertTrue(Thread.isMainThread); XCTAssertNil(result); done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }
    func testQueuedUpdatesCarryTheirOwnAppliedChoicesAndEpochNotLaterWorkerState() throws {
        let (peer, session) = try fixture(); _ = peer
        session.start(password: "isolated receipt", peerAddress: "", send: false, receive: false, plugins: false, name: "Test", pushToTalk: settings())
        _ = session.testPushToTalkGeneration()
        var second = settings(); second.doubleTapSpeed = .slow
        var third = settings(); third.levelDb = -61
        let done = expectation(description: "two specific completions"); done.expectedFulfillmentCount = 2
        var receipts: [PushToTalkWorkerReceipt?] = []
        for s in [second, third] {
            session.setAudioOptions(send: false, receive: false, plugins: false, pushToTalk: s) { result in receipts.append(result); done.fulfill() }
        }
        let final = session.testPushToTalkGeneration(); wait(for: [done], timeout: 3)
        XCTAssertEqual(receipts.count, 2); XCTAssertEqual(receipts[0]?.settings, second); XCTAssertEqual(receipts[1]?.settings, third)
        XCTAssertNotEqual(receipts[0]?.generation, receipts[1]?.generation); XCTAssertEqual(receipts[1]?.generation, final)
    }
    func testUnchangedOptionsStillAcknowledgeCurrentEpochWithoutRetiringIt() throws {
        let (peer, session) = try fixture(); _ = peer
        session.start(password: "isolated receipt", peerAddress: "", send: false, receive: false, plugins: false, name: "Test", pushToTalk: settings())
        let current = session.testPushToTalkGeneration(), done = expectation(description: "unchanged completion")
        session.setAudioOptions(send: false, receive: false, plugins: false, pushToTalk: settings()) { result in
            XCTAssertEqual(result?.generation, current); XCTAssertEqual(result?.settings, self.settings()); done.fulfill()
        }
        wait(for: [done], timeout: 3); XCTAssertEqual(session.testPushToTalkGeneration(), current)
    }
}
