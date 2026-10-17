import Foundation
import RemSoundRuntime
import RemSoundJam

public struct ConnectionProfile: Codable, Equatable {
    public let id: UUID
    /// nil follows this computer; false is an explicit profile choice.
    public var enableLogs: Bool?
    public var title: String
    public var displayName: String
    public var manualPeerAddress: String
    public var selectedPeerAddresses: [String]
    public var lockPeerAddresses: Bool
    public var sendInput: Bool
    public var sendSystemAudio: Bool
    public var receiveAudio: Bool
    public var monitorInApp: Bool
    public var inputDeviceUID: String
    public var inputDeviceUIDs: [String]
    public var inputChannelPairs: [String: [Int]]
    public var outputDeviceUID: String
    public var outputDeviceUIDs: [String]
    public var outputChannelPairs: [String: [Int]]
    // Retained only to decode profiles saved before multiple-output capture.
    public var systemCaptureDeviceUID: String
    // nil means All Mac outputs; an empty list means no outputs selected.
    public var systemCaptureDeviceUIDs: [String]?
    public var systemCaptureChannelPairs: [String: [Int]]
    public var sendCodec: SendCodec
    public var sendPacketSize: SendPacketSize
    public var receiveJitterMs: Int
    public var receiveSmoothness: Int
    public var receiveArtifact: ConcealmentArtifact
    public var receiveAutoTune: Bool
    public var receiveAutoTuneInterval: Int
    /// Windows' "Lowest-delay auto-tune, accepting a rare dropout". Off in a new profile.
    public var receiveLowestDelay = false
    public var recordingSource: RecordingSource
    public var recordingFormat: RecordingFormat
    public var recordingChannels: RecordingChannels
    public var splitRecording: Bool
    public var recordingBypassShaping: Bool
    public var flacCompression: Int
    public var recordingsDirectory: String
    public var peerMixes: [String: PeerMix]
    public var peerAliases: [String: String]
    public var allowPlugins: Bool
    public var reconnectOnOpen: Bool
    /// The server this profile uses, as typed, and whether to connect to it at start (Windows' RelayServer and
    /// RelayConnectOnStart). The people ticked there are kept with the other peers in selectedPeerAddresses.
    public var server = ""
    public var serverConnectOnStart = false
    /// The metronome's settings (Windows MetronomeSettings, per profile). nil: saved before they were kept here.
    public var metronome: MetronomeChoices?
    public static let defaultMetronomeVolume = 70
    public var metronomeVolume: Int = defaultMetronomeVolume {
        didSet { metronomeVolume = min(100, max(0, metronomeVolume)) }
    }
    /// Remote volume and mute: this profile's listening volume (0...100) and receive mute, and whether peers may change
    /// them (Windows' Volume, Muted and AcceptRemoteVolumeCommands; off unless ticked).
    public var listeningVolume: Int
    public var receiveMuted: Bool
    public var acceptRemoteVolumeCommands: Bool
    /// "Enable volume, pan and EQ for all peers" (Windows' EnableAllPeerShaping; off in a new profile).
    public var enableAllPeerShaping: Bool
    /// Mac system audio from chosen applications instead of whole outputs, and which (bundle IDs) - Windows'
    /// WasapiSendMode and SelectedSendApplications. The choice is kept while whole outputs are sent.
    public var systemAudioFromApplications: Bool
    public var systemAudioApplications: [String]
    public var readOnly: Bool
    // nil identifies an older profile whose machine-wide Off choices must be migrated.
    public var audioCues: [String: CueConfiguration]?
    public var audioCueSchemaVersion: Int
    public var pushToTalk: PushToTalkSettings = .init()
    // nil identifies profiles saved before the typing choice; migration uses the frozen machine default.
    public var keyboardClicks: Bool?
    /// Browser choices only. Its password belongs to a separate Keychain account, never this profile.
    public var browserListenerEnabled = false
    public var browserListenerAutoStart = false

    public init(
        id: UUID = UUID(), title: String, displayName: String, manualPeerAddress: String,
        selectedPeerAddresses: [String], lockPeerAddresses: Bool = false, sendInput: Bool, receiveAudio: Bool,
        sendSystemAudio: Bool = false,
        allowPlugins: Bool, reconnectOnOpen: Bool, monitorInApp: Bool = true,
        inputDeviceUID: String = "", inputDeviceUIDs: [String]? = nil,
        inputChannelPairs: [String: [Int]] = [:],
        outputDeviceUID: String = "",
        outputDeviceUIDs: [String]? = nil,
        outputChannelPairs: [String: [Int]] = [:],
        systemCaptureDeviceUID: String = "", systemCaptureDeviceUIDs: [String]? = nil,
        systemCaptureChannelPairs: [String: [Int]] = [:],
        sendCodec: SendCodec = .opusLive, sendPacketSize: SendPacketSize = .standard,
        receiveJitterMs: Int = ReceiveBuffer.legacyDefaultMs,
        receiveSmoothness: Int = BufferSmoothness.defaultLevel,
        receiveArtifact: ConcealmentArtifact = .defaultChoice,
        receiveAutoTune: Bool = false,
        receiveAutoTuneInterval: Int = ReceiveBuffer.defaultAutoTuneInterval,
        recordingSource: RecordingSource = .both, recordingFormat: RecordingFormat = .wav24,
        recordingChannels: RecordingChannels = .stereo,
        splitRecording: Bool = false, recordingBypassShaping: Bool = false,
        flacCompression: Int = FLACCompression.defaultLevel,
        recordingsDirectory: String = "",
        peerMixes: [String: PeerMix] = [:],
        peerAliases: [String: String] = [:],
        listeningVolume: Int = 100, receiveMuted: Bool = false, acceptRemoteVolumeCommands: Bool = false,
        enableAllPeerShaping: Bool = false,
        systemAudioFromApplications: Bool = false, systemAudioApplications: [String] = [],
        readOnly: Bool = false, audioCues: [String: CueConfiguration]? = [:],
        audioCueSchemaVersion: Int = CuePreferences.schemaVersion, keyboardClicks: Bool? = true, pushToTalk: PushToTalkSettings = .init(),
        browserListenerEnabled: Bool = false, browserListenerAutoStart: Bool = false,
        metronomeVolume: Int = Self.defaultMetronomeVolume, enableLogs: Bool? = nil,
        server: String = "", serverConnectOnStart: Bool = false, metronome: MetronomeChoices? = MetronomeChoices(),
        receiveLowestDelay: Bool = false
    ) {
        self.receiveLowestDelay = receiveLowestDelay
        self.enableLogs = enableLogs
        self.server = server
        self.serverConnectOnStart = serverConnectOnStart
        self.metronome = metronome
        self.id = id
        self.title = title
        self.displayName = displayName
        self.manualPeerAddress = manualPeerAddress
        self.selectedPeerAddresses = selectedPeerAddresses
        self.lockPeerAddresses = lockPeerAddresses
        self.sendInput = sendInput
        self.sendSystemAudio = sendSystemAudio
        self.receiveAudio = receiveAudio
        self.monitorInApp = monitorInApp
        self.inputDeviceUIDs = inputDeviceUIDs ?? [inputDeviceUID]
        self.inputChannelPairs = inputChannelPairs
        self.inputDeviceUID = self.inputDeviceUIDs.first ?? ""
        self.outputDeviceUIDs = outputDeviceUIDs ?? [outputDeviceUID]
        self.outputDeviceUID = self.outputDeviceUIDs.first ?? ""
        self.outputChannelPairs = outputChannelPairs
        self.systemCaptureDeviceUID = ""
        self.systemCaptureDeviceUIDs = systemCaptureDeviceUIDs
            ?? (systemCaptureDeviceUID.isEmpty ? nil : [systemCaptureDeviceUID])
        self.systemCaptureChannelPairs = systemCaptureChannelPairs
        self.sendCodec = sendCodec
        self.sendPacketSize = sendPacketSize
        self.receiveJitterMs = ReceiveBuffer.clamped(receiveJitterMs)
        self.receiveSmoothness = BufferSmoothness.clamped(receiveSmoothness)
        self.receiveArtifact = receiveArtifact
        self.receiveAutoTune = receiveAutoTune
        self.receiveAutoTuneInterval = ReceiveBuffer.validAutoTuneInterval(
            receiveAutoTuneInterval)
        self.recordingSource = recordingSource
        self.recordingFormat = recordingFormat
        self.recordingChannels = recordingChannels
        self.splitRecording = splitRecording
        self.recordingBypassShaping = recordingBypassShaping
        self.flacCompression = FLACCompression.clamped(flacCompression)
        self.recordingsDirectory = recordingsDirectory
        self.peerMixes = peerMixes
        self.peerAliases = peerAliases
        self.allowPlugins = allowPlugins
        self.reconnectOnOpen = reconnectOnOpen
        self.metronomeVolume = min(100, max(0, metronomeVolume))
        self.listeningVolume = min(100, max(0, listeningVolume))
        self.receiveMuted = receiveMuted
        self.acceptRemoteVolumeCommands = acceptRemoteVolumeCommands
        self.enableAllPeerShaping = enableAllPeerShaping
        self.systemAudioFromApplications = systemAudioFromApplications
        self.systemAudioApplications = systemAudioApplications
        self.readOnly = readOnly
        self.audioCues = audioCues
        self.audioCueSchemaVersion = audioCueSchemaVersion
        self.keyboardClicks = keyboardClicks
        self.pushToTalk = pushToTalk
        self.browserListenerEnabled = browserListenerEnabled
        self.browserListenerAutoStart = browserListenerAutoStart
    }

    private enum CodingKeys: String, CodingKey {
        case enableLogs
        case id, title, displayName, manualPeerAddress, selectedPeerAddresses, lockPeerAddresses
        case sendInput, receiveAudio, monitorInApp, inputDeviceUID, inputDeviceUIDs,
            inputChannelPairs, outputDeviceUID, outputDeviceUIDs, outputChannelPairs
        case systemCaptureDeviceUID, systemCaptureDeviceUIDs, systemCaptureChannelPairs
        case sendSystemAudio
        case sendCodec, sendPacketSize, receiveJitterMs, receiveSmoothness, receiveArtifact, receiveAutoTune, receiveAutoTuneInterval
        case recordingSource, recordingsDirectory
        case recordingFormat
        case recordingChannels
        case splitRecording, recordingBypassShaping
        case flacCompression
        case peerMixes
        case peerAliases
        case allowPlugins, reconnectOnOpen, readOnly, audioCues, audioCueSchemaVersion, keyboardClicks
        case listeningVolume, receiveMuted, acceptRemoteVolumeCommands, metronomeVolume
        case enableAllPeerShaping
        case systemAudioFromApplications, systemAudioApplications, pushToTalk
        case browserListenerEnabled, browserListenerAutoStart
        case server, serverConnectOnStart, metronome, receiveLowestDelay
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enableLogs = try values.decodeIfPresent(Bool.self, forKey: .enableLogs)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        displayName = try values.decode(String.self, forKey: .displayName)
        manualPeerAddress = try values.decode(String.self, forKey: .manualPeerAddress)
        selectedPeerAddresses = try values.decode([String].self, forKey: .selectedPeerAddresses)
        lockPeerAddresses = try values.decodeIfPresent(Bool.self, forKey: .lockPeerAddresses) ?? false
        sendInput = try values.decode(Bool.self, forKey: .sendInput)
        sendSystemAudio = try values.decodeIfPresent(Bool.self, forKey: .sendSystemAudio) ?? false
        receiveAudio = try values.decode(Bool.self, forKey: .receiveAudio)
        monitorInApp = try values.decodeIfPresent(Bool.self, forKey: .monitorInApp) ?? true
        inputDeviceUID = try values.decodeIfPresent(String.self, forKey: .inputDeviceUID) ?? ""
        inputDeviceUIDs = try values.decodeIfPresent([String].self,
            forKey: .inputDeviceUIDs) ?? [inputDeviceUID]
        inputChannelPairs = try values.decodeIfPresent([String: [Int]].self,
            forKey: .inputChannelPairs) ?? [:]
        outputDeviceUID = try values.decodeIfPresent(String.self, forKey: .outputDeviceUID) ?? ""
        outputDeviceUIDs = try values.decodeIfPresent([String].self,
            forKey: .outputDeviceUIDs) ?? [outputDeviceUID]
        outputChannelPairs = try values.decodeIfPresent([String: [Int]].self,
            forKey: .outputChannelPairs) ?? [:]
        let legacyCaptureUID = try values.decodeIfPresent(String.self,
            forKey: .systemCaptureDeviceUID) ?? ""
        systemCaptureDeviceUID = ""
        systemCaptureDeviceUIDs = values.contains(.systemCaptureDeviceUIDs)
            ? try values.decode([String].self, forKey: .systemCaptureDeviceUIDs)
            : (legacyCaptureUID.isEmpty ? nil : [legacyCaptureUID])
        systemCaptureChannelPairs = try values.decodeIfPresent([String: [Int]].self,
            forKey: .systemCaptureChannelPairs) ?? [:]
        sendCodec = try values.decodeIfPresent(SendCodec.self, forKey: .sendCodec) ?? .pcm
        sendPacketSize = try values.decodeIfPresent(SendPacketSize.self, forKey: .sendPacketSize) ?? .standard
        receiveJitterMs = ReceiveBuffer.clamped(try values.decodeIfPresent(Int.self,
            forKey: .receiveJitterMs) ?? ReceiveBuffer.legacyDefaultMs)
        receiveSmoothness = BufferSmoothness.clamped(try values.decodeIfPresent(Int.self,
            forKey: .receiveSmoothness) ?? BufferSmoothness.defaultLevel)
        receiveArtifact = try values.decodeIfPresent(ConcealmentArtifact.self,
            forKey: .receiveArtifact) ?? .defaultChoice
        receiveAutoTune = try values.decodeIfPresent(Bool.self,
            forKey: .receiveAutoTune) ?? false
        receiveAutoTuneInterval = ReceiveBuffer.validAutoTuneInterval(
            try values.decodeIfPresent(Int.self, forKey: .receiveAutoTuneInterval)
                ?? ReceiveBuffer.defaultAutoTuneInterval)
        recordingSource = try values.decodeIfPresent(RecordingSource.self, forKey: .recordingSource) ?? .both
        recordingFormat = try values.decodeIfPresent(RecordingFormat.self, forKey: .recordingFormat) ?? .wav24
        recordingChannels = try values.decodeIfPresent(RecordingChannels.self,
            forKey: .recordingChannels) ?? .stereo
        splitRecording = try values.decodeIfPresent(Bool.self, forKey: .splitRecording) ?? false
        recordingBypassShaping = try values.decodeIfPresent(Bool.self, forKey: .recordingBypassShaping) ?? false
        flacCompression = FLACCompression.clamped(try values.decodeIfPresent(Int.self,
            forKey: .flacCompression) ?? FLACCompression.defaultLevel)
        recordingsDirectory = try values.decodeIfPresent(String.self, forKey: .recordingsDirectory) ?? ""
        peerMixes = try values.decodeIfPresent([String: PeerMix].self, forKey: .peerMixes) ?? [:]
        peerAliases = try values.decodeIfPresent([String: String].self, forKey: .peerAliases) ?? [:]
        allowPlugins = try values.decode(Bool.self, forKey: .allowPlugins)
        reconnectOnOpen = try values.decode(Bool.self, forKey: .reconnectOnOpen)
        readOnly = try values.decode(Bool.self, forKey: .readOnly)
        keyboardClicks = try values.decodeIfPresent(Bool.self, forKey: .keyboardClicks)
        pushToTalk = try values.decodeIfPresent(PushToTalkSettings.self, forKey: .pushToTalk) ?? .init()
        browserListenerEnabled = try values.decodeIfPresent(Bool.self, forKey: .browserListenerEnabled) ?? false
        browserListenerAutoStart = try values.decodeIfPresent(Bool.self, forKey: .browserListenerAutoStart) ?? false
        server = try values.decodeIfPresent(String.self, forKey: .server) ?? ""
        serverConnectOnStart = try values.decodeIfPresent(Bool.self, forKey: .serverConnectOnStart) ?? false
        metronome = try values.decodeIfPresent(MetronomeChoices.self, forKey: .metronome)
        receiveLowestDelay = try values.decodeIfPresent(Bool.self, forKey: .receiveLowestDelay) ?? false
        audioCues = try values.decodeIfPresent([String: CueConfiguration].self, forKey: .audioCues)
        audioCueSchemaVersion = try values.decodeIfPresent(Int.self, forKey: .audioCueSchemaVersion) ?? 0
        guard (0...CuePreferences.schemaVersion).contains(audioCueSchemaVersion) else {
            throw DecodingError.dataCorruptedError(forKey: .audioCueSchemaVersion, in: values,
                debugDescription: "Unsupported audio cue profile version")
        }
        metronomeVolume = min(100, max(0, try values.decodeIfPresent(Int.self, forKey: .metronomeVolume) ?? Self.defaultMetronomeVolume))
        listeningVolume = min(100, max(0, try values.decodeIfPresent(Int.self, forKey: .listeningVolume) ?? 100))
        receiveMuted = try values.decodeIfPresent(Bool.self, forKey: .receiveMuted) ?? false
        acceptRemoteVolumeCommands = try values.decodeIfPresent(Bool.self, forKey: .acceptRemoteVolumeCommands) ?? false
        // Saved before the master switch: on if any peer was being shaped, so nobody's sound changes.
        enableAllPeerShaping = try values.decodeIfPresent(Bool.self, forKey: .enableAllPeerShaping)
            ?? PeerMix.masterSwitchForOldProfile(peerMixes)
        systemAudioFromApplications = try values.decodeIfPresent(Bool.self, forKey: .systemAudioFromApplications) ?? false
        systemAudioApplications = try values.decodeIfPresent([String].self, forKey: .systemAudioApplications) ?? []
    }
}

public enum ProfileStoreError: LocalizedError {
    case invalidTitle
    case duplicateTitle
    case invalidProfile

    public var errorDescription: String? {
        switch self {
        case .invalidTitle: "Enter a profile name of up to 80 characters."
        case .duplicateTitle: "A profile with this name already exists."
        case .invalidProfile: "The profile file is invalid or incomplete."
        }
    }
}

public enum RecentProfileHistory {
    public static let limit = 5

    public static func opening(_ id: UUID, in recent: [UUID]) -> [UUID] {
        Array(([id] + recent.filter { $0 != id }).prefix(limit))
    }
}

public final class ProfileStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        // The folder chosen in Preferences, so the command line lists the profiles the app uses.
        RuntimeConfiguration.chosenProfilesDirectory(SettingsStore(defaults: .standard))
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RemSound/Profiles", isDirectory: true)
    }

    private func file(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: false)
            .appendingPathExtension("json")
    }

    /// Every profile that can be read. One that cannot - damaged, or not named for its own id - is left alone on disk and
    /// out of the list (`unreadable()` names them): it used to take every other profile with it, so Open Profile and
    /// every save failed (Windows' ProfileSafety: an unreadable profile is never opened blank or saved over).
    public func list() throws -> [ConnectionProfile] {
        try readAll().profiles
    }

    /// The profile files that could not be read.
    public func unreadable() -> [URL] {
        (try? readAll().unreadable) ?? []
    }

    private func readAll() throws -> (profiles: [ConnectionProfile], unreadable: [URL]) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([], []) }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var profiles: [ConnectionProfile] = [], unreadable: [URL] = []
        for url in urls where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                let profile = try? JSONDecoder().decode(ConnectionProfile.self, from: data),
                url.lastPathComponent == file(for: profile.id).lastPathComponent
            else {
                unreadable.append(url)
                continue
            }
            profiles.append(profile)
        }
        return (profiles.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }, unreadable)
    }

    public func load(id: UUID) throws -> ConnectionProfile {
        let profile = try JSONDecoder().decode(
            ConnectionProfile.self, from: Data(contentsOf: file(for: id)))
        guard profile.id == id else { throw ProfileStoreError.invalidProfile }
        return profile
    }

    public func save(_ profile: ConnectionProfile) throws {
        let title = profile.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 80 else { throw ProfileStoreError.invalidTitle }
        let other = try list().first {
            $0.id != profile.id && $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame
        }
        guard other == nil else { throw ProfileStoreError.duplicateTitle }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var normalised = profile
        normalised.title = title
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = file(for: profile.id)
        try encoder.encode(normalised).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func delete(id: UUID) throws {
        let url = file(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
