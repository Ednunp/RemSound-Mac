import Foundation

public struct ControlRequest: Codable {
    public let version: Int
    public let id: UUID
    public let action: String
    public let arguments: [String: String]
    public private(set) var deadlineUptimeNanoseconds: UInt64 = 0

    public init(action: String, arguments: [String: String] = [:]) {
        version = 1
        id = UUID()
        self.action = action
        self.arguments = arguments
    }
    func bounded(until deadline: UInt64) -> ControlRequest {
        var copy = self
        copy.deadlineUptimeNanoseconds = deadline
        return copy
    }
}

public struct ControlReply: Codable {
    public enum Status: String, Codable { case ok, error, waiting }
    public let id: UUID
    public let status: Status
    public let message: String
    public let state: [String: String]

    public init(request: ControlRequest, status: Status, message: String, state: [String: String] = [:]) {
        id = request.id
        self.status = status
        self.message = message
        self.state = state
    }
}

/// Stable Mac actions deliberately avoid reflection, shell execution and arbitrary settings access.
public struct ControlCommand {
    public enum Action: String, CaseIterable {
        case help, status, start, stop, show, quit, devices, password, name, peer, receive, daw
        case inputSend = "input-send", systemSend = "system-send", macOutput = "mac-output"
        case inputSelect = "input-select", outputSelect = "output-select", systemSelect = "system-select"
        case packetSize = "packet-size"
        case cue, cueList = "cue-list", cueMute = "cue-mute"
        case codec, jitter, smoothness, artifact, autoTune = "auto-tune", autoTuneInterval = "auto-tune-interval"
        case autoTuneLowestDelay = "auto-tune-lowest-delay"
        case pluginInstall = "plugin-install", pluginRemove = "plugin-remove", pluginShaping = "plugin-shaping"
        case serverConnect = "server-connect", serverDisconnect = "server-disconnect", selfMonitor = "self-monitor"
        case inputPair = "input-pair", outputPair = "output-pair", systemPair = "system-pair", systemAll = "system-all"
        case profileList = "profile-list", profileSave = "profile-save", profileSaveAs = "profile-save-as"
        case profileOpen = "profile-open", profileNew = "profile-new", profileRename = "profile-rename", profileLock = "profile-lock"
        case recording, recordingSource = "recording-source", recordingFormat = "recording-format"
        case recordingChannels = "recording-channels", recordingSplit = "recording-split"
        case recordingBypass = "recording-bypass"
        case flacCompression = "flac-compression"
        case metronomeToggle = "metronome-toggle", metronomeTempo = "metronome-tempo", metronomeMaster = "metronome-master"
        case metronomeSignature = "metronome-signature", metronomeVolume = "metronome-volume", metronomeSound = "metronome-sound"
        case metronomeWhenAsked = "metronome-when-asked"
        case metronomeHear = "metronome-hear", metronomeRecord = "metronome-record"
    }
    public let action: Action
    public let arguments: [String: String]
    public var enabled: Bool { arguments["value"] == "on" }

    public init(_ request: ControlRequest) throws {
        guard request.version == 1, let action = Action(rawValue: request.action) else {
            throw RuntimeConfigurationError.invalidControlCommand
        }
        let arguments = request.arguments
        let keys = Set(arguments.keys)
        func text(_ key: String, maximum: Int, empty: Bool = false) -> Bool {
            guard let value = arguments[key], value.utf8.count <= maximum, empty || !value.isEmpty else { return false }
            return !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        func integer(_ key: String = "value", in range: ClosedRange<Int>) -> Bool {
            guard let value = arguments[key], let number = Int(value) else { return false }
            return String(number) == value && range.contains(number)
        }
        let valid: Bool
        switch action {
        case .inputSend, .systemSend, .receive, .daw, .macOutput, .autoTune, .selfMonitor, .systemAll, .profileLock,
            .recording, .recordingSplit, .recordingBypass, .metronomeMaster, .cueMute, .metronomeRecord, .autoTuneLowestDelay,
            .pluginShaping:
            valid = keys == ["value"] && ["on", "off"].contains(arguments["value"] ?? "")
        case .inputSelect, .outputSelect, .systemSelect:
            valid = keys == ["value", "device"] && ["on", "off"].contains(arguments["value"] ?? "")
                && text("device", maximum: 512, empty: true)
        case .inputPair, .outputPair, .systemPair:
            valid = keys == ["value", "device", "pair"] && ["on", "off"].contains(arguments["value"] ?? "")
                && text("device", maximum: 512) && integer("pair", in: 0...Int.max)
        case .serverConnect:
            valid = keys == ["value"] && text("value", maximum: 512)
                && !(arguments["value"]?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        case .password: valid = keys == ["password"] && text("password", maximum: 4096)
        case .name: valid = keys == ["value"] && text("value", maximum: 96)
        case .peer: valid = keys == ["value"] && text("value", maximum: 255, empty: true)
        case .packetSize: valid = keys == ["value"] && ["standard", "small"].contains(arguments["value"] ?? "")
        case .cue:
            valid = keys == ["value"] && (try? CueControlSelection(arguments["value"] ?? "")) != nil
        case .codec: valid = keys == ["value"] && ["pcm", "opusBroadcast", "opusLive"].contains(arguments["value"] ?? "")
        // Syntax bounds protect dispatch; the app also requires an actual advertised menu choice.
        case .jitter: valid = keys == ["value"] && integer(in: 2...200)
        case .smoothness: valid = keys == ["value"] && integer(in: 1...10)
        case .artifact: valid = keys == ["value"] && ["noise", "click"].contains(arguments["value"] ?? "")
        case .autoTuneInterval: valid = keys == ["value"] && integer(in: 1...30)
        case .profileSaveAs, .profileRename:
            valid = keys == ["value"] && text("value", maximum: 320)
                && !(arguments["value"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                && (arguments["value"]?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0) <= 80
        case .profileOpen:
            valid = keys == ["value"] && text("value", maximum: 36)
                && UUID(uuidString: arguments["value"] ?? "")?.uuidString.lowercased() == arguments["value"]?.lowercased()
        case .recordingSource:
            valid = keys == ["value"] && ["both", "sent", "received"].contains(arguments["value"] ?? "")
        case .recordingChannels:
            valid = keys == ["value"] && ["mono", "stereo"].contains(arguments["value"] ?? "")
        case .flacCompression:
            valid = keys == ["value"] && integer(in: 0...8)
        case .recordingFormat:
            valid = keys == ["value"] && ["wav16", "wav24", "wavFloat", "flac16", "flac24",
                "opus96", "opus128", "opus192", "opus256", "mp3128", "mp3192", "mp3256", "mp3320"].contains(arguments["value"] ?? "")
        case .metronomeTempo: valid = keys == ["value"] && integer(in: 30...300)
        case .metronomeVolume: valid = keys == ["value"] && integer(in: 0...100)
        case .metronomeSignature: valid = keys == ["value"] && text("value", maximum: 32)
        case .metronomeSound: valid = keys == ["value"] && text("value", maximum: 64)
        case .metronomeWhenAsked:
            valid = keys == ["value"] && ["ask", "accept", "decline"].contains(arguments["value"] ?? "")
        case .metronomeHear:
            valid = keys == ["value"] && ["remsound", "daw"].contains(arguments["value"] ?? "")
        default: valid = keys.isEmpty
        }
        guard valid else { throw RuntimeConfigurationError.invalidControlCommand }
        self.action = action
        self.arguments = arguments
    }
    public static var help: String {
        "Actions: help, status, devices, start, stop, show, quit; name/peer --value text; "
            + "input-send/system-send/receive/daw/mac-output --value on|off; "
            + "input-select/output-select/system-select --device UID --value on|off; "
            + "codec --value pcm|opusBroadcast|opusLive; packet-size --value standard|small; jitter --value milliseconds; smoothness --value 1..10 (default 3); artifact --value noise|click (default noise); "
            + "auto-tune --value on|off; auto-tune-interval --value seconds (advertised choices only); "
            + "auto-tune-lowest-delay --value on|off; plugin-install; plugin-remove (an isolated run uses its own folder); "
            + "plugin-shaping --value on|off (pan and EQ in DAW plugin audio); "
            + "server-connect --value address; server-disconnect; self-monitor/system-all --value on|off; "
            + "input-pair/output-pair/system-pair --device UID --pair zero-based-index --value on|off; "
            + "profile-list, profile-save, profile-new; profile-save-as/profile-rename --value title; "
            + "profile-open --value UUID; profile-lock --value on|off; "
            + "recording/recording-split/recording-bypass --value on|off; recording-source --value both|sent|received; "
            + "recording-format --value wav16|wav24|wavFloat|flac16|flac24|opus96|opus128|opus192|opus256|mp3128|mp3192|mp3256|mp3320; "
            + "recording-channels --value mono|stereo; metronome-toggle; metronome-tempo --value 30..300; "
            + "flac-compression --value 0..8 (default 5); "
            + "cue-list; cue --value event:on|off|advertised-bundled-filename.wav (use the event IDs from cue-list); "
            + "cue-mute --value on|off (Turn all audio cues off, for every profile; previews remain available); "
            + "metronome-master --value on|off; metronome-signature/metronome-volume/metronome-sound --value menu-choice; "
            + "metronome-when-asked --value ask|accept|decline; "
            + "metronome-hear --value remsound|daw; metronome-record --value on|off (the click in RemSound's recordings); "
            + "password reads one bounded UTF-8 line from piped standard input."
    }
}

#if canImport(Darwin)
import Darwin

public enum ControlPasswordInput {
    /// Read without terminal echo or argv exposure, with a bounded wait even when a pipe never closes.
    public static func read(descriptor: Int32 = STDIN_FILENO, timeout: TimeInterval = 3) throws -> String {
        guard isatty(descriptor) == 0, timeout.isFinite else { throw RuntimeConfigurationError.invalidControlCommand }
        let deadline = ControlTransport.deadline(timeout)
        var data = Data()
        while true {
            try ControlTransport.wait(descriptor, events: Int16(POLLIN | POLLHUP), until: deadline)
            var bytes = [UInt8](repeating: 0, count: 512)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw RuntimeConfigurationError.invalidControlCommand }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= 4098 else { throw RuntimeConfigurationError.invalidControlCommand }
            if let newline = data.firstIndex(of: 10) {
                guard newline == data.index(before: data.endIndex) else { throw RuntimeConfigurationError.invalidControlCommand }
                data.removeLast()
                if data.last == 13 { data.removeLast() }
                break
            }
        }
        guard let value = String(data: data, encoding: .utf8) else { throw RuntimeConfigurationError.invalidControlCommand }
        _ = try ControlCommand(ControlRequest(action: "password", arguments: ["password": value]))
        return value
    }
}
#endif
