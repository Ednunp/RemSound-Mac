import Foundation
import XCTest
@testable import RemSoundRuntime

final class CloseLaunchTests: XCTestCase {
    func testAliasesProduceExistingQuitRequestWithoutRuntimeOptions() throws {
        for flag in ["--close", "--quit", "--CLOSE", "--QUIT"] {
            let options = try LaunchOptions.parse([flag, "--config-dir", "/private/close-fixture"])
            let request = try XCTUnwrap(options.controlRequest)
            XCTAssertEqual(request.action, "quit")
            XCTAssertTrue(request.arguments.isEmpty)
            XCTAssertEqual(try ControlCommand(request).action, .quit)
            XCTAssertNil(options.report)
            XCTAssertFalse(options.headless)
            XCTAssertNil(options.startup.profileName)
            XCTAssertTrue(options.startup.connectPeers.isEmpty)
        }
    }
    func testCloseRequiresExplicitRootWithoutEnvironmentFallback() {
        for flag in ["--close", "--quit"] {
            XCTAssertThrowsError(try LaunchOptions.parse([flag], environment: ["REMSOUND_CONFIG_DIR": "/private/ignored"])) { error in
                guard case RuntimeConfigurationError.controlRequiresIsolation = error else { return XCTFail("Wrong isolation error") }
            }
        }
    }
    func testCloseRejectsEveryMixedModeInEitherOrder() {
        let modes = [["--control", "quit"], ["--close"], ["--quit"], ["--version"], ["--profiles"], ["--devices"], ["--profile", "Studio"], ["--connect", "127.0.0.1:47831"], ["--tray"], ["--headless"], ["--check-accessibility"]]
        for mode in modes {
            for arguments in [["--close"] + mode, mode + ["--close"]] {
                XCTAssertThrowsError(try LaunchOptions.parse(arguments + ["--config-dir", "/private/close-fixture"], environment: ["REMSOUND_ALLOW_VISIBLE_UI_TESTS": "1"]))
            }
        }
    }
    func testCloseRejectsControlArgumentsAndUnsafeRootSyntax() {
        for pair in [["--value", "anything"], ["--device", "input"], ["--pair", "1"]] {
            XCTAssertThrowsError(try LaunchOptions.parse(["--quit"] + pair + ["--config-dir", "/private/close-fixture"]))
        }
        for root in ["relative", "/"] {
            XCTAssertThrowsError(try LaunchOptions.parse(["--quit", "--config-dir", root]))
        }
    }
    func testHelpAndSilentClosePreserveExistingClientSemantics() throws {
        XCTAssertTrue(try LaunchOptions.parse(["--quit", "--help"]).help)
        let options = try LaunchOptions.parse(["--config-dir", "/private/close-fixture", "--silent", "--quit"])
        XCTAssertTrue(options.silent)
        XCTAssertEqual(options.controlRequest?.action, "quit")
    }

    #if canImport(Darwin)
    func testOwnedClientPreservesGracefulWaitingAndFailureReceipts() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let root = URL(fileURLWithPath: base).appendingPathComponent(String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("control.sock")
        for status in [ControlReply.Status.ok, .waiting, .error] {
            let server = LocalControlServer(socketURL: url) { request in
                XCTAssertEqual(request.action, "quit")
                XCTAssertTrue(request.arguments.isEmpty)
                return ControlReply(request: request, status: status, message: "Graceful reply retained", state: ["running": "false"])
            }
            try server.start()
            defer { XCTAssertTrue(server.stop()) }
            let request = try XCTUnwrap(LaunchOptions.parse(["--close", "--config-dir", root.path]).controlRequest)
            let reply = try LocalControlClient.send(request, to: url)
            XCTAssertEqual(reply.id, request.id)
            XCTAssertEqual(reply.status, status)
            XCTAssertEqual(reply.message, "Graceful reply retained")
            XCTAssertTrue(server.stop())
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertThrowsError(try LocalControlClient.send(ControlRequest(action: "quit"), to: url))
    }
    #endif
}
