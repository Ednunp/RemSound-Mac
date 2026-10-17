import AppKit
import XCTest
import RemSoundRuntime
@testable import RemSoundApp

@MainActor final class ApplicationLifecycleTests: XCTestCase {
    func testQuitLeavesTheEventLoopAvailableUntilActualCleanupCompletes() throws {
        let base = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]))
        let root = base.appendingPathComponent("quit-lifecycle-" + UUID().uuidString)
        try AppRuntime.prepare(LaunchOptions.parse(["--silent", "--config-dir", root.path]))
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(AppDelegate.quitLifecycleRegressionFailures(), [])
        XCTAssertEqual(AppDelegate.quitProfileRegressionFailures(response: nil), [], "Unchanged profile")
        XCTAssertEqual(AppDelegate.quitProfileRegressionFailures(response: .alertThirdButtonReturn), [], "Cancel")
        XCTAssertEqual(AppDelegate.quitProfileRegressionFailures(response: .alertSecondButtonReturn), [], "Discard")
        XCTAssertEqual(AppDelegate.quitProfileRegressionFailures(response: .alertFirstButtonReturn), [], "Save")
    }
}
