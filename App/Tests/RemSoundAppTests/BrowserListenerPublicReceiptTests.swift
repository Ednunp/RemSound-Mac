import Foundation
import RemSoundCore
import RemSoundRuntime
import XCTest

final class BrowserListenerPublicReceiptTests: XCTestCase {
    func testOrdinaryAppImportUsesOnlySendableReceiptValues() {
        func sendable<T: Sendable>(_ value: T) -> T { value }
        let values = sendable([BrowserListenerActivationResult.listening(port: 49121), .unavailable, .cancelled])
        XCTAssertEqual(values.count, 3)
        guard case .listening(let port) = values[0] else { return XCTFail("Missing typed local receipt") }
        XCTAssertEqual(port, 49121)
    }
    func testPublicIsolatedServiceRefusesCompletionBeforeResources() throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]))
            .appendingPathComponent("public-receipt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try RuntimeConfiguration(options: LaunchOptions.parse(["--config-dir", root.path, "--headless", "--silent"]))
        let session = Session(), service = BrowserListenerService(runtime: runtime, session: session)
        let ready = expectation(description: "prepare actual isolated service"), closed = expectation(description: "browser retired"), sessionClosed = expectation(description: "Session retired")
        let request = UUID(); XCTAssertTrue(service.prepareStart(request) { XCTAssertTrue($0); ready.fulfill() }); wait(for: [ready], timeout: 2)
        var callback = false
        XCTAssertFalse(service.refreshAddress { _ in callback = true })
        XCTAssertFalse(service.reviewPublicAccess { _ in callback = true })
        XCTAssertFalse(service.turnOnPublicAccess { _ in callback = true })
        service.cancelAddressRefresh()
        let copy: (BrowserListenerAddress, @escaping (String?) -> Void) -> Bool = service.copyAddress
        _ = copy
        XCTAssertFalse(service.activate(request, binding: .init(port: 49121, generation: UUID()), options: .init(enabled: true), password: "synthetic") { _ in callback = true })
        XCTAssertTrue(service.shutdown { closed.fulfill() }); wait(for: [closed], timeout: 2)
        XCTAssertFalse(callback); XCTAssertNil(service.status.boundPort); XCTAssertFalse(service.status.sourceAttached)
        session.shutdown { sessionClosed.fulfill() }; wait(for: [sessionClosed], timeout: 2)
    }
    func testOrdinaryAppImportUsesScopedSendableAddressResults() {
        func sendable<T: Sendable>(_ value:T)->T {value}
        let values=sendable([BrowserListenerAddressResult.unknown,.unavailable,.cancelled])
        XCTAssertEqual(values,[.unknown,.unavailable,.cancelled])
        // Configured receipts have no public initializer or arbitrary URL input.
        func display(_ receipt:BrowserListenerAddress)->String {sendable(receipt).urlString}
        _ = display
    }

    func testOrdinaryImportUsesReadonlyReviewValuesAndScopedMethod() {
        func sendable<T:Sendable>(_ value:T)->T {value}
        let values=sendable([BrowserListenerFunnelReviewResult.empty,.matching(publiclyAllowed:false),.matching(publiclyAllowed:true),.conflict,.unknown,.unavailable,.cancelled])
        XCTAssertEqual(values.count,7)
        func review(_ service:BrowserListenerService) {XCTAssertFalse(service.reviewPublicAccess{_ in XCTFail("No callback on isolated refusal")})}
        _ = review
    }



}
