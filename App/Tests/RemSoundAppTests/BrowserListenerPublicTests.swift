import Foundation
import XCTest
import RemSoundCore
import RemSoundRuntime

final class BrowserListenerPublicTests: XCTestCase {
    private func sendable<T: Sendable>(_ value: T) -> T { value }
    func testOrdinaryCoreImportExposesOnlyValueOptionsAndStatus() {
        let value = sendable(BrowserListenerOptions())
        XCTAssertFalse(value.enabled); XCTAssertFalse(value.autoStart)
    }
    func testPublicIsolatedConstructionPrepareAndShutdownWithoutStartingSession() throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]))
            .appendingPathComponent("public-browser-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try RuntimeConfiguration(options: LaunchOptions.parse(["--config-dir", root.path, "--headless", "--silent"]))
        let session = Session(configuration: runtime)
        let service = BrowserListenerService(runtime: runtime, session: session)
        let ready = expectation(description: "old listener resources retired"), closed = expectation(description: "listener shutdown"), sessionClosed = expectation(description: "stopped Session cleanup")
        let request = UUID()
        XCTAssertTrue(service.prepareStart(request) { XCTAssertTrue($0); ready.fulfill() }); wait(for: [ready], timeout: 2)
        XCTAssertFalse(service.activate(request, binding: .init(port: 49211, generation: UUID()), options: .init(enabled: true), password: "synthetic"))
        let status = sendable(service.status); XCTAssertEqual(status.state, .off); XCTAssertNil(status.boundPort); XCTAssertFalse(status.sourceAttached)
        XCTAssertTrue(service.shutdown { closed.fulfill() }); session.shutdown { sessionClosed.fulfill() }
        wait(for: [closed, sessionClosed], timeout: 2); XCTAssertEqual(service.status.state, .closed)
    }
}
