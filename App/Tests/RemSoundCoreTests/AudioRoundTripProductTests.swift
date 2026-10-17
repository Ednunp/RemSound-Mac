import Foundation
import XCTest
@testable import RemSoundCore

final class AudioRoundTripProductTests: XCTestCase {
    func testNamedPCMUsesActualSessionWireDecoderAndRetainsHardwareGap() throws {
        try check("Audio round-trip (PCM)")
    }
    func testNamedOpusUsesActualSessionWireDecoderAndRetainsHardwareGap() throws {
        try check("Audio round-trip (Opus)")
    }
    func testMissingFixturePermissionRefusesBeforeAnySessionOrSocketFactory() throws {
        let old = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]
        defer { if let old { setenv("REMSOUND_TEST_ROOT", old, 1) } }
        unsetenv("REMSOUND_TEST_ROOT")
        for name in ["Audio round-trip (PCM)", "Audio round-trip (Opus)"] {
            let report = ProductTestPack.run(pack: .full, only: name)
            let step = try XCTUnwrap(report.steps.first)
            XCTAssertEqual(step.assertions, 0)
            XCTAssertEqual(step.status, "UNVERIFIED")
            XCTAssertEqual(step.failures.first, "isolated-audio-fixture-root-required")
            XCTAssertEqual(report.exitCode, 1)
        }
    }
    func testPublicOrSymlinkFixtureRootRefusesWithoutCreatingChildren() throws {
        let old = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        defer { setenv("REMSOUND_TEST_ROOT", old, 1) }
        let root = URL(fileURLWithPath: old).appendingPathComponent("audio-root-refusal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let link = root.appendingPathComponent("alias")
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("REMSOUND_TEST_ROOT", root.path, 1)
        var step = ProductTestPack.checkAudioRoundTrip(opus: false)
        XCTAssertEqual(step.status, "FAIL"); XCTAssertEqual(step.assertions, 1)
        XCTAssertTrue(step.failures.contains("audio.fixture-root-refused"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        setenv("REMSOUND_TEST_ROOT", link.path, 1)
        step = ProductTestPack.checkAudioRoundTrip(opus: true)
        XCTAssertEqual(step.status, "FAIL"); XCTAssertEqual(step.assertions, 1)
        XCTAssertTrue(step.failures.contains("audio.fixture-root-refused"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["alias"])
    }
    private func check(_ name: String) throws {
        let report = ProductTestPack.run(pack: .feature, only: name, budget: 8)
        let step = try XCTUnwrap(report.steps.first)
        XCTAssertEqual(report.selection, name)
        XCTAssertEqual(report.termination, "completed")
        XCTAssertEqual(step.name, name)
        XCTAssertEqual(step.status, "UNVERIFIED")
        XCTAssertGreaterThanOrEqual(step.assertions, 16)
        XCTAssertEqual(step.failures, ["native-output-capture-and-device-clock-acceptance-unverified"])
        XCTAssertEqual(report.exitCode, 1)
    }
}
