import Foundation
import XCTest
@testable import RemSoundCore

final class SessionNetworkBindingTests: XCTestCase {
    private func fixture() throws -> (UDP, Session) {
        let peer = try UDP(port: 0, loopback: true), session = Session(testPeerPort: peer.boundPort)
        addTeardownBlock { withExtendedLifetime(peer) { session.shutdown() } }; return (peer, session)
    }
    private func start(_ session: Session) throws -> SessionNetworkBinding {
        let done = expectation(description: "request-specific bound socket")
        var binding: SessionNetworkBinding?
        session.start(password: "isolated network binding", peerAddress: "", send: false, receive: false,
            plugins: false, name: "Test", networkCompletion: { value in binding = value; done.fulfill() })
        wait(for: [done], timeout: 3); return try XCTUnwrap(binding)
    }
    func testStartReceiptOnMainMatchesPublishedLiveSocketAndActualPort() throws {
        let (peer, session) = try fixture(); _ = peer; var view: SessionView?
        session.onChange = { view = $0 }
        let done = expectation(description: "main binding proof")
        session.start(password: "isolated binding", peerAddress: "", send: false, receive: false, plugins: false, name: "Test",
            networkCompletion: { binding in
                XCTAssertTrue(Thread.isMainThread); XCTAssertNotNil(binding); XCTAssertEqual(view?.running, true)
                XCTAssertEqual(binding, view?.networkBinding); XCTAssertEqual(binding?.port, session.testPorts.audio)
                XCTAssertNotEqual(binding?.port, 0); XCTAssertNotEqual(binding?.port, 47830); done.fulfill()
            })
        wait(for: [done], timeout: 3)
    }
    func testFailedStartCompletesOnceWithNilAndStoppedSnapshot() throws {
        let (peer, session) = try fixture(); _ = peer; var view: SessionView?
        session.onChange = { view = $0 }
        let done = expectation(description: "failed binding request"); done.assertForOverFulfill = true
        session.start(password: "", peerAddress: "", send: false, receive: false, plugins: false, name: "Test",
            networkCompletion: { binding in
                XCTAssertTrue(Thread.isMainThread); XCTAssertNil(binding); XCTAssertNil(view?.networkBinding)
                XCTAssertEqual(view?.running, false); XCTAssertEqual(session.testPorts.audio, 0); done.fulfill()
            })
        wait(for: [done], timeout: 3)
    }
    func testRestartReceiptsRetainRequestSpecificSocketGenerations() throws {
        let (peer, session) = try fixture(); _ = peer
        let done = expectation(description: "two immutable binding receipts"); done.expectedFulfillmentCount = 2
        var bindings: [SessionNetworkBinding?] = [], latest: SessionView?
        session.onChange = { latest = $0 }
        for _ in 0..<2 {
            session.start(password: "isolated binding", peerAddress: "", send: false, receive: false, plugins: false, name: "Test",
                networkCompletion: { binding in bindings.append(binding); done.fulfill() })
        }
        let port = session.testPorts.audio // Worker barrier; main callbacks have not been read yet.
        wait(for: [done], timeout: 3); XCTAssertEqual(bindings.count, 2)
        let first = try XCTUnwrap(bindings.first ?? nil), second = try XCTUnwrap(bindings.last ?? nil)
        XCTAssertNotEqual(first.generation, second.generation); XCTAssertEqual(second.port, port)
        XCTAssertEqual(second, latest?.networkBinding); XCTAssertEqual(latest?.status, "Running. Select the same peer on both computers.")
    }
    func testStopPublishesNoBindingAndClosesOwnedSocket() throws {
        let (peer, session) = try fixture(); _ = peer; _ = try start(session)
        let done = expectation(description: "binding retired")
        session.onChange = { view in
            guard !view.running else { return }; session.onChange = nil
            XCTAssertNil(view.networkBinding); XCTAssertEqual(session.testPorts.audio, 0); done.fulfill()
        }
        session.stop(); wait(for: [done], timeout: 3)
    }
    func testAudioAndKeySettingEpochChangesDoNotInventSocketGeneration() throws {
        let (peer, session) = try fixture(); _ = peer; let first = try start(session)
        let done = expectation(description: "unrelated worker options"), oldKey = session.testPushToTalkGeneration()
        var latest: SessionView?; session.onChange = { latest = $0 }
        var settings = PushToTalkSettings(); settings.enabled = true
        session.setAudioOptions(send: false, receive: false, plugins: false, pushToTalk: settings) { receipt in
            XCTAssertNotEqual(receipt?.generation, oldKey); XCTAssertEqual(latest?.networkBinding, first)
            XCTAssertEqual(session.testPorts.audio, first.port); done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }
    func testLegacyTrailingPushToTalkCompletionStillUsesItsOriginalContract() throws {
        let (peer, session) = try fixture(); _ = peer; let done = expectation(description: "legacy trailing closure")
        session.start(password: "isolated legacy callback", peerAddress: "", send: false, receive: false, plugins: false, name: "Test") { receipt in
            XCTAssertTrue(receipt?.running == true); XCTAssertEqual(receipt?.settings, PushToTalkSettings())
            XCTAssertNotNil(receipt?.generation); done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }
    func testAsyncShutdownPublishesNilBindingBeforeTerminalCallback() throws {
        let (peer, session) = try fixture(); _ = peer; let first = try start(session); var latest: SessionView?
        session.onChange = { latest = $0 }; let done = expectation(description: "terminal network retirement")
        session.shutdown {
            XCTAssertTrue(Thread.isMainThread); XCTAssertNil(latest?.networkBinding); XCTAssertEqual(latest?.running, false)
            XCTAssertEqual(session.testPorts.audio, 0)
            do { let rebound = try UDP(port: first.port, loopback: true); XCTAssertEqual(rebound.boundPort, first.port) }
            catch { XCTFail("Owned spare socket was not available after shutdown: \(error)") }; done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }
}
