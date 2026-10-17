import Foundation
import XCTest
@testable import RemSoundCore

final class SessionBrowserMutationTests: XCTestCase {
    func testStoppedApplicationsReceiptIsNilOnMainWithoutStartingResources() {
        let session = Session(testPeerPort: 1), receipt = expectation(description: "stopped source receipt"), closed = expectation(description: "stopped cleanup")
        session.setSendApplications(["synthetic.application"]) { value in XCTAssertTrue(Thread.isMainThread); XCTAssertNil(value); receipt.fulfill() }
        wait(for:[receipt],timeout:0.2); session.shutdown { closed.fulfill() }; wait(for:[closed],timeout:2)
        XCTAssertEqual(session.testPorts.audio,0); XCTAssertEqual(session.testPorts.discovery,0); XCTAssertEqual(session.testPorts.bridge,0)
    }
    func testRunningAndUnchangedApplicationsBothReturnActualWorkerReceipt() throws {
        let peer = try UDP(port:0,loopback:true), session = Session(testPeerPort:peer.boundPort)
        let started = expectation(description:"owned source visit"); var binding:SessionNetworkBinding?
        session.start(password:"synthetic",peerAddress:"",send:false,receive:false,plugins:false,name:"Test",networkCompletion:{binding=$0;started.fulfill()})
        wait(for:[started],timeout:2); XCTAssertNotNil(binding)
        for _ in 0..<2 {
            let receipt=expectation(description:"applied source choice")
            session.setSendApplications(["synthetic.application"]) { value in XCTAssertTrue(Thread.isMainThread); XCTAssertEqual(value?.running,true); receipt.fulfill() }
            wait(for:[receipt],timeout:0.2)
        }
        let closed=expectation(description:"Session retired");session.shutdown {closed.fulfill()};wait(for:[closed],timeout:2)
        XCTAssertEqual(session.testPorts.audio,0);XCTAssertEqual(session.testPorts.discovery,0);XCTAssertEqual(session.testPorts.bridge,0)
    }
    func testShutdownApplicationsReceiptCannotClaimRunning() {
        let session=Session(testPeerPort:1),closed=expectation(description:"closed"),receipt=expectation(description:"post-shutdown refusal")
        session.shutdown {closed.fulfill()};wait(for:[closed],timeout:2)
        session.setSendApplications(nil) {value in XCTAssertNil(value);receipt.fulfill()};wait(for:[receipt],timeout:0.2)
    }
}
