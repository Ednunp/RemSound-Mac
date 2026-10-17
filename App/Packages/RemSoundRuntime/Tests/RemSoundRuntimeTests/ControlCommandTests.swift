import XCTest
@testable import RemSoundRuntime
#if canImport(Darwin)
import Darwin
#endif

final class ControlCommandTests: XCTestCase {
    func testArtifactRequiresAnExplicitAdvertisedChoice() throws {
        for value in ["noise", "click"] {
            XCTAssertNoThrow(try LaunchOptions.parse(["--config-dir", "/private/control",
                "--control", "artifact", "--value", value]))
        }
        for value in ["", "Noise", "Click", "noiseBurst", "2", "3", "click ", "click\n"] {
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "artifact", arguments: ["value": value])))
        }
        XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "artifact")))
        XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "artifact",
            arguments: ["value": "noise", "device": "arbitrary"])))
        XCTAssertTrue(ControlCommand.help.contains("artifact --value noise|click"))
    }
    func testSmoothnessRequiresACanonicalIntegerChoice() throws {
        for level in 1...10 {
            XCTAssertNoThrow(try LaunchOptions.parse(["--config-dir", "/private/control",
                "--control", "smoothness", "--value", String(level)]))
        }
        for value in ["", "0", "11", "+3", "03", "3.0", "3\n"] {
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "smoothness", arguments: ["value": value])))
        }
        XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "smoothness")))
        XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "smoothness",
            arguments: ["value": "3", "device": "arbitrary"])))
    }
    func testPacketSizeRequiresAnExplicitAdvertisedChoice() throws {
        for value in ["standard", "small"] {
            XCTAssertNoThrow(try LaunchOptions.parse(["--config-dir", "/private/control",
                "--control", "packet-size", "--value", value]))
        }
        for value in ["", "Small", "tight", "120", "small\n"] {
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "packet-size", arguments: ["value": value])))
        }
        XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "packet-size")))
        XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "packet-size",
            arguments: ["value": "small", "device": "arbitrary"])))
    }
    func testMP3RecordingCommandsAcceptOnlySupportedBitrates() throws {
        for value in ["mp3128", "mp3192", "mp3256", "mp3320"] {
            XCTAssertNoThrow(try LaunchOptions.parse(["--config-dir", "/private/control",
                "--control", "recording-format", "--value", value]))
        }
        for value in ["mp3", "mp3127", "mp3129", "mp3321", "mp3128\n"] {
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "recording-format",
                arguments: ["value": value])))
        }
    }
    func testRecordingCommandsRequireEnumeratedChoicesAndExplicitState() throws {
        for (action, values) in [
            ("recording", ["on", "off"]), ("recording-split", ["on", "off"]),
            ("recording-source", ["both", "sent", "received"]),
            ("recording-channels", ["mono", "stereo"]),
            ("recording-format", ["wav16", "wav24", "wavFloat", "flac16", "flac24", "opus96", "opus128", "opus192", "opus256"])
        ] {
            for value in values {
                XCTAssertNoThrow(try LaunchOptions.parse(["--config-dir", "/private/control",
                    "--control", action, "--value", value]))
            }
            for value in ["", "true", "../record.wav", "custom", "on\n"] {
                XCTAssertThrowsError(try ControlCommand(ControlRequest(action: action, arguments: ["value": value])))
            }
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: action)))
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: action,
                arguments: ["value": values[0], "path": "/arbitrary"])))
        }
    }
    func testMetronomeCommandsBoundTempoAndMenuArguments() throws {
        XCTAssertNoThrow(try ControlCommand(ControlRequest(action: "metronome-toggle")))
        XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "metronome-toggle", arguments: ["value": "on"])))
        for (action, good, bad) in [
            ("metronome-tempo", "120", ["29", "301", "+120", "0120", "120.0"]),
            ("metronome-volume", "70", ["-1", "101", "70.0", "+70"]),
            ("metronome-master", "off", ["", "true"]),
            ("metronome-when-asked", "ask", ["", "automatic", "shell"]),
            ("metronome-hear", "daw", ["", "DAW", "plugin"]),
            ("metronome-record", "on", ["", "true", "yes"]),
            ("metronome-signature", "6/8", ["", "6/8\n", String(repeating: "x", count: 33)]),
            ("metronome-sound", "Click", ["", "Click\n", String(repeating: "x", count: 65)])
        ] {
            XCTAssertNoThrow(try ControlCommand(ControlRequest(action: action, arguments: ["value": good])))
            for value in bad {
                XCTAssertThrowsError(try ControlCommand(ControlRequest(action: action, arguments: ["value": value])))
            }
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: action)))
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: action,
                arguments: ["value": good, "device": "arbitrary"])))
        }
    }
    func testProfileCommandsAcceptOnlyExplicitTitlesAndProfileIdentifiers() throws {
        let id = UUID().uuidString
        for action in ["profile-list", "profile-save", "profile-new"] {
            XCTAssertNoThrow(try ControlCommand(ControlRequest(action: action)))
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: action, arguments: ["value": id])))
        }
        for action in ["profile-save-as", "profile-rename"] {
            for title in ["Presentation", "  Café setup  ", String(repeating: "é", count: 80)] {
                XCTAssertNoThrow(try LaunchOptions.parse(["--config-dir", "/private/control",
                    "--control", action, "--value", title]))
            }
            for title in ["", "   ", "name\nnext", String(repeating: "é", count: 81)] {
                XCTAssertThrowsError(try ControlCommand(ControlRequest(action: action, arguments: ["value": title])))
            }
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: action)))
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: action,
                arguments: ["value": "Presentation", "device": "arbitrary"])))
        }
        for value in [id, id.lowercased()] {
            XCTAssertNoThrow(try ControlCommand(ControlRequest(action: "profile-open", arguments: ["value": value])))
        }
        for value in ["", "Presentation", "/tmp/profile.json", "../profile", id.replacingOccurrences(of: "-", with: "")] {
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "profile-open", arguments: ["value": value])))
        }
        for value in ["on", "off"] {
            XCTAssertNoThrow(try ControlCommand(ControlRequest(action: "profile-lock", arguments: ["value": value])))
        }
        XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "profile-lock", arguments: ["value": "true"])))
    }
    func testServerAndChannelCommandsRequireExplicitBoundedArguments() throws {
        XCTAssertNoThrow(try ControlCommand(ControlRequest(action: "server-connect", arguments: ["value": "127.0.0.1:21500"])))
        XCTAssertNoThrow(try ControlCommand(ControlRequest(action: "server-disconnect")))
        for value in ["", "   ", "host\nnext", String(repeating: "a", count: 513)] {
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "server-connect", arguments: ["value": value])))
        }
        for action in ["self-monitor", "system-all"] {
            XCTAssertNoThrow(try ControlCommand(ControlRequest(action: action, arguments: ["value": "off"])))
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: action, arguments: ["value": "true"])))
        }
        for action in ["input-pair", "output-pair", "system-pair"] {
            let args = ["--config-dir", "/private/control", "--control", action, "--device", "interface", "--pair", "1", "--value", "on"]
            let parsed = try LaunchOptions.parse(args)
            XCTAssertEqual(parsed.controlRequest?.arguments, ["device": "interface", "pair": "1", "value": "on"])
            for pair in ["", "-1", "+1", "01", "1.0", String(repeating: "9", count: 30)] {
                XCTAssertThrowsError(try ControlCommand(ControlRequest(action: action, arguments: ["device": "interface", "pair": pair, "value": "on"])))
            }
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: action, arguments: ["device": "", "pair": "0", "value": "on"])))
            XCTAssertThrowsError(try LaunchOptions.parse(args + ["--pair", "0"]))
        }
        XCTAssertThrowsError(try LaunchOptions.parse(["--config-dir", "/private/control", "--pair", "1"]))
        XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "server-disconnect", arguments: ["value": "host"])))
    }
    func testAudioTuningCommandsValidateValuesBeforeDispatch() throws {
        for value in ["pcm", "opusBroadcast", "opusLive"] {
            XCTAssertNoThrow(try ControlCommand(ControlRequest(action: "codec", arguments: ["value": value])))
        }
        for (action, good, bad) in [
            ("codec", "pcm", ["", "shell", "PCM"]),
            ("jitter", "10", ["", "1", "201", "10.0", "+10", "010"]),
            ("auto-tune", "on", ["", "true", "ON"]),
            ("auto-tune-interval", "5", ["", "0", "31", "5.0", "+5", "05"])
        ] {
            XCTAssertNoThrow(try LaunchOptions.parse(["--config-dir", "/private/control", "--control", action, "--value", good]))
            for value in bad {
                XCTAssertThrowsError(try ControlCommand(ControlRequest(action: action, arguments: ["value": value])))
            }
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: action)))
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: action, arguments: ["value": good, "device": "arbitrary"])))
        }
    }
    func testControlLaunchRequiresIsolationAndRefusesAmbiguousOrSecretArguments() throws {
        let parsed = try LaunchOptions.parse(["--config-dir", "/private/control", "--control", "receive", "--value", "on"])
        XCTAssertEqual(parsed.controlRequest?.action, "receive")
        XCTAssertEqual(parsed.controlRequest?.arguments, ["value": "on"])
        XCTAssertFalse(parsed.headless)
        for args in [["--headless"], ["--control", "status"],
            ["--config-dir", "/private/control", "--headless", "--control", "status"],
            ["--config-dir", "/private/control", "--control", "password", "--value", "test-secret"],
            ["--config-dir", "/private/control", "--value", "on"],
            ["--config-dir", "/private/control", "--control", "status", "--check-accessibility"],
            ["--config-dir", "/private/control", "--control", "status", "--value", "on"]] {
            XCTAssertThrowsError(try LaunchOptions.parse(args))
        }
    }

    func testCommandSchemaRefusesUnknownActionsKeysAndInvalidValues() throws {
        for action in ["help", "status", "start", "stop", "show", "quit", "devices"] {
            XCTAssertNoThrow(try ControlCommand(ControlRequest(action: action)))
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: action, arguments: ["value": "on"])))
        }
        for action in ["input-send", "system-send", "receive", "daw", "mac-output"] {
            XCTAssertNoThrow(try ControlCommand(ControlRequest(action: action, arguments: ["value": "on"])))
            XCTAssertNoThrow(try ControlCommand(ControlRequest(action: action, arguments: ["value": "off"])))
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: action, arguments: ["value": "maybe"])))
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: action, arguments: ["value": "on", "extra": "x"])))
        }
        for request in [ControlRequest(action: "shell"), ControlRequest(action: "password"),
            ControlRequest(action: "name", arguments: ["value": "bad\nname"]),
            ControlRequest(action: "peer", arguments: ["value": String(repeating: "x", count: 256)]),
            ControlRequest(action: "password", arguments: ["password": "bad\0value"])] {
            XCTAssertThrowsError(try ControlCommand(request))
        }
        XCTAssertNoThrow(try ControlCommand(ControlRequest(action: "password", arguments: ["password": "dummy password"])))
    }

    func testRecordingBypassUsesStrictBooleanCommandSchema() throws {
        for value in ["on", "off"] {
            let command = try ControlCommand(ControlRequest(action: "recording-bypass", arguments: ["value": value]))
            XCTAssertEqual(command.action, .recordingBypass)
            XCTAssertEqual(command.enabled, value == "on")
        }
        for arguments in [["value": "true"], ["value": "1"], ["value": "on", "path": "/tmp/audio.wav"], [:]] {
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "recording-bypass", arguments: arguments)))
        }
        XCTAssertTrue(ControlCommand.help.contains("recording-bypass"))
    }

    func testFLACCompressionRequiresBoundedLevelAndNoExtraKeys() throws {
        for level in 0...8 {
            XCTAssertEqual(try ControlCommand(ControlRequest(action: "flac-compression",
                arguments: ["value": String(level)])).action, .flacCompression)
        }
        for value in ["", "-1", "9", "5.0", "on", "999999999999999999999999999999"] {
            XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "flac-compression", arguments: ["value": value])))
        }
        XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "flac-compression", arguments: [:])))
        XCTAssertThrowsError(try ControlCommand(ControlRequest(action: "flac-compression", arguments: ["value": "5", "extra": "x"])))
    }

    func testHeadlessHandoffKeepsIsolationAndExplicitSilence() throws {
        let base = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        for explicitSilence in [false, true] {
            let root = base.appendingPathComponent(String(UUID().uuidString.prefix(8)))
            defer { try? FileManager.default.removeItem(at: root) }
            let flags = ["--headless", "--config-dir", root.path] + (explicitSilence ? ["--silent"] : [])
            let context = try RuntimeConfiguration(options: LaunchOptions.parse(flags))
            XCTAssertTrue(context.isHeadless)
            XCTAssertTrue(context.silent)
            XCTAssertEqual(context.controlSocketURL, root.appendingPathComponent("control.sock"))
            context.handOverToGUI()
            XCTAssertFalse(context.isHeadless)
            XCTAssertEqual(context.silent, explicitSilence)
            XCTAssertTrue(context.isIsolated)
            XCTAssertFalse(context.allowsKeychain)
            XCTAssertFalse(context.allowsUpdates)
            XCTAssertFalse(context.allowsGlobalHotkeys)
        }
    }

#if canImport(Darwin)
    private func input(_ data: Data, timeout: TimeInterval = 0.1) throws -> String {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { close(descriptors[0]) }
        data.withUnsafeBytes { bytes in _ = write(descriptors[1], bytes.baseAddress, bytes.count) }
        close(descriptors[1])
        return try ControlPasswordInput.read(descriptor: descriptors[0], timeout: timeout)
    }
    func testPasswordInputReadsOneBoundedUTF8LineWithoutChangingDescriptorFlags() throws {
        XCTAssertEqual(try input(Data("dummy password\r\n".utf8)), "dummy password")
        XCTAssertEqual(try input(Data("héllo".utf8)), "héllo")
        XCTAssertThrowsError(try input(Data([0xFF])))
        XCTAssertThrowsError(try input(Data("bad\0value".utf8)))
        XCTAssertThrowsError(try input(Data("first\nsecond".utf8)))
        XCTAssertThrowsError(try input(Data()))
        XCTAssertThrowsError(try input(Data(repeating: 65, count: 4097)))
    }
    func testPasswordInputStallTimesOutWithoutLeakingDescriptors() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        let before = fcntl(descriptors[0], F_GETFL)
        let began = Date()
        XCTAssertThrowsError(try ControlPasswordInput.read(descriptor: descriptors[0], timeout: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.3)
        XCTAssertEqual(fcntl(descriptors[0], F_GETFL), before)
    }
#endif
}
