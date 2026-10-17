import Foundation
import XCTest
@testable import RemSoundRuntime

final class CueControlTests: XCTestCase {
    func testCueCommandsRejectUnknownEventsPathsAndExtraArguments() throws {
        for value in ["connect:off", "dawOn:on", "helpOpen:help open 1.wav"] {
            let request = try LaunchOptions.parse(["--config-dir", "/private/control", "--control", "cue", "--value", value]).controlRequest!
            XCTAssertEqual(request.action, "cue")
            XCTAssertNoThrow(try CueControlSelection(value))
        }
        for value in ["connect", "unknown:on", "connect:ON", "connect:", "connect:/private/cue.wav", "connect:../cue.wav", "connect:bad\\cue.wav", "connect:bad\n.wav", "connect:a:b.wav"] {
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "cue", arguments: ["value": value])))
        }
        XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "cue")))
        XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "cue", arguments: ["value": "connect:on", "extra": "x"])))
        XCTAssertNoThrow(try ControlCommand(ControlRequest(action: "cue-list")))
        XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "cue-list", arguments: ["value": "connect"])))
        XCTAssertTrue(ControlCommand.help.contains("cue-list"))
        XCTAssertTrue(ControlCommand.help.contains("cue --value"))
    }

    func testNamedMachineMuteCommandAllowsOnlyAnExplicitOnOrOff() throws {
        for value in ["on", "off"] {
            let request = try XCTUnwrap(LaunchOptions.parse(["--config-dir", "/private/control", "--control",
                "cue-mute", "--value", value]).controlRequest)
            let command = try ControlCommand(request)
            XCTAssertEqual(command.action, .cueMute)
            XCTAssertEqual(command.enabled, value == "on")
        }
        for arguments in [[:], ["value": "ON"], ["value": "toggle"], ["value": "on", "event": "connect"]] {
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "cue-mute", arguments: arguments)))
        }
        XCTAssertTrue(ControlCommand.help.contains("Turn all audio cues off"))
    }

    func testActualCueSelectionPreservesCustomFilesAndWindowsScopes() throws {
        let testRoot = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"],
            "Set REMSOUND_TEST_ROOT to an isolated disposable test directory.")
        let root = URL(fileURLWithPath: testRoot)
            .appendingPathComponent("cue-control-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.plist")
        let cues = CuePreferences(settings: try SettingsStore(file: file))
        let variants = ["connect 1.wav", "connect 2.wav"]
        cues.chooseCustomFile("/private/retained.wav", for: .connect)
        XCTAssertTrue(cues.applyControl(try CueControlSelection("connect:off"), variants: variants))
        XCTAssertFalse(cues.configuration(for: .connect).enabled)
        XCTAssertEqual(cues.configuration(for: .connect).customPath, "/private/retained.wav")
        XCTAssertTrue(cues.applyControl(try CueControlSelection("connect:on"), variants: variants))
        XCTAssertTrue(cues.configuration(for: .connect).enabled)
        XCTAssertEqual(cues.configuration(for: .connect).customPath, "/private/retained.wav")
        let before = cues.profileConfigurations
        XCTAssertFalse(cues.applyControl(try CueControlSelection("connect:missing.wav"), variants: variants))
        XCTAssertEqual(cues.profileConfigurations, before)
        XCTAssertTrue(cues.applyControl(try CueControlSelection("connect:connect 2.wav"), variants: variants))
        XCTAssertNil(cues.configuration(for: .connect).customPath)
        XCTAssertEqual(cues.builtInSelection(for: .connect, variants: variants), "connect 2.wav")
        XCTAssertTrue(cues.applyControl(try CueControlSelection("dawOn:off"), variants: []))
        XCTAssertNotNil(cues.profileConfigurations["dawOn"])
        let restarted = CuePreferences(settings: try SettingsStore(file: file))
        XCTAssertFalse(restarted.configuration(for: .dawOn).enabled)
        XCTAssertEqual(restarted.builtInSelection(for: .connect, variants: variants), "connect 2.wav")
        XCTAssertTrue(restarted.applyControl(try CueControlSelection("connect:off"), variants: variants))
        let savedProfile = restarted.profileConfigurations
        restarted.loadProfile([:])
        XCTAssertTrue(restarted.configuration(for: .connect).enabled)
        restarted.loadProfile(savedProfile)
        XCTAssertFalse(restarted.configuration(for: .connect).enabled)
        XCTAssertFalse(restarted.configuration(for: .dawOn).enabled)
    }
}
