import Foundation

public enum CueEvent: String, CaseIterable {
    case startup, connect, disconnect, recordStart, recordStop, save, profileSwitch
    case profileMenuOpen, update, sendOn, sendOff, receiveOn, receiveOff, dawOn, dawOff
    case hide, show, checkboxOn, checkboxOff, tabSwitch, helpOpen, helpClose
    case pushToTalkOn, pushToTalkOff
    case serverConnect, serverDisconnect

    public var isProfileSetting: Bool {
        switch self {
        case .save, .profileSwitch, .profileMenuOpen, .update, .helpOpen, .helpClose: false
        default: true
        }
    }
    fileprivate var wasProfileSetting: Bool {
        switch self {
        case .connect, .disconnect, .recordStart, .recordStop, .save, .profileSwitch, .profileMenuOpen, .update: true
        default: false
        }
    }
    public static var globalEvents: [CueEvent] { allCases.filter { !$0.isProfileSetting } }
    public static var profileEvents: [CueEvent] { allCases.filter(\.isProfileSetting) }
    public var title: String {
        switch self {
        case .startup: "Startup"
        case .connect: "Peer connected"
        case .disconnect: "Peer disconnected"
        case .recordStart: "Recording started"
        case .recordStop: "Recording stopped"
        case .save: "Profile saved"
        case .profileSwitch: "Profile switched"
        case .profileMenuOpen: "Profile menu opened"
        case .update: "Update available"
        case .sendOn: "Sending turned on"
        case .sendOff: "Sending turned off"
        case .receiveOn: "Receiving turned on"
        case .receiveOff: "Receiving turned off"
        case .dawOn: "DAW plugins allowed"
        case .dawOff: "DAW plugins blocked"
        case .hide: "Window hidden"
        case .show: "Window shown"
        case .checkboxOn: "Checkbox checked"
        case .checkboxOff: "Checkbox unchecked"
        case .tabSwitch: "Tab switched"
        case .helpOpen: "Help opened"
        case .helpClose: "Help closed"
        case .pushToTalkOn: "Push to talk started"
        case .pushToTalkOff: "Push to talk stopped"
        case .serverConnect: "Server connected"
        case .serverDisconnect: "Server disconnected"
        }
    }
    public var filenameBase: String {
        switch self {
        case .startup: "start up"
        case .connect: "connect"
        case .disconnect: "disconnect"
        case .recordStart: "record start"
        case .recordStop: "record stop"
        case .save: "save"
        case .profileSwitch: "profile"
        case .profileMenuOpen: "profile menu open"
        case .update: "update"
        case .sendOn, .dawOn: "send on"
        case .sendOff, .dawOff: "send off"
        case .receiveOn: "recieve on" // Match the shipped Windows asset spelling.
        case .receiveOff: "recieve off"
        case .hide: "minimise"
        case .show: "maximise"
        case .checkboxOn: "check"
        case .checkboxOff: "uncheck"
        case .tabSwitch: "tab switch"
        case .helpOpen: "help open"
        case .helpClose: "help close"
        case .pushToTalkOn: "push talk on"
        case .pushToTalkOff: "push talk off"
        case .serverConnect: "server connect"
        case .serverDisconnect: "server disconnect"
        }
    }
    /// When the sound plays, for the message about a sound file that cannot be found (Windows CheckForMissingEnabledCues).
    public var whenText: String {
        switch self {
        case .startup: "RemSound opens"
        case .connect: "a peer connects"
        case .disconnect: "a peer disconnects"
        case .recordStart: "you start recording"
        case .recordStop: "you stop recording"
        case .save: "you save a profile"
        case .profileSwitch: "you switch profile"
        case .profileMenuOpen: "the quick profile menu opens"
        case .update: "an update is about to install"
        case .sendOn: "you turn sending on"
        case .sendOff: "you turn sending off"
        case .receiveOn: "you turn receiving on"
        case .receiveOff: "you turn receiving off"
        case .dawOn: "you allow DAW plugins"
        case .dawOff: "you block DAW plugins"
        case .hide: "RemSound's window is hidden"
        case .show: "RemSound's window is shown"
        case .checkboxOn: "you tick a box"
        case .checkboxOff: "you untick a box"
        case .tabSwitch: "you switch tabs"
        case .helpOpen: "help opens"
        case .helpClose: "help closes"
        case .pushToTalkOn: "you start talking with the push to talk key"
        case .pushToTalkOff: "you stop talking with the push to talk key"
        case .serverConnect: "you connect to a server"
        case .serverDisconnect: "you disconnect from a server"
        }
    }
}

public struct CueConfiguration: Codable, Equatable {
    public var enabled: Bool
    public var customPath: String?
    public var builtInName: String?
    public init(enabled: Bool = true, customPath: String? = nil, builtInName: String? = nil) {
        self.enabled = enabled
        self.customPath = customPath
        self.builtInName = builtInName
    }
}

/// UI-thread cue choices; playback takes a snapshot and reads only the thread-safe mute setting.
public final class CuePreferences {
    public static let schemaVersion = 2
    public static let muteSettingKey = "muteAllAudioCues"
    private let settings: SettingsStore
    private let legacyMachine: [String: CueConfiguration]
    private let legacyKeyboardClicks: Bool
    private static let legacyKeyboardClicksKey = "legacyKeyboardClicksV1"
    public private(set) var profileConfigurations: [String: CueConfiguration]
    public private(set) var keyboardClicksEnabled = true
    public func setKeyboardClicksEnabled(_ enabled: Bool) {
        keyboardClicksEnabled = enabled
        persistProfile()
    }
    // Silent/headless runtime eligibility is additionally enforced by the app at the device boundary.
    public var automaticKeyboardClicksEnabled: Bool { keyboardClicksEnabled && !muteAllCues }
    public private(set) var globalConfigurations: [String: CueConfiguration]
    private var globalsInitialized: Bool
    private static let currentProfileKey = "activeProfileAudioCuesV2"
    private static let globalsKey = "globalAudioCues"
    private static let legacySnapshotKey = "legacyAudioCueConfigurations"
    private struct ProfileState: Codable {
        var version: Int
        var configurations: [String: CueConfiguration]
        var keyboardClicks: Bool?
    }
    public var muteAllCues: Bool { settings.bool(forKey: Self.muteSettingKey) }
    public func setMuteAllCues(_ muted: Bool) { settings.set(muted, forKey: Self.muteSettingKey) }

    public init(settings: SettingsStore) {
        self.settings = settings
        if let frozen = settings.object(forKey: Self.legacyKeyboardClicksKey) as? Bool {
            legacyKeyboardClicks = frozen
        } else {
            // Freeze once so editing one profile cannot change an unopened older profile's migration.
            legacyKeyboardClicks = (settings.object(forKey: "enableKeyboardClicks") as? Bool) ?? true
            settings.set(legacyKeyboardClicks, forKey: Self.legacyKeyboardClicksKey)
        }
        if let data = settings.data(forKey: Self.legacySnapshotKey),
            let frozen = try? JSONDecoder().decode([String: CueConfiguration].self, from: data) {
            legacyMachine = frozen
        } else {
            let flags = settings.data(forKey: "legacyAudioCueEnabled")
                .flatMap { try? JSONDecoder().decode([String: Bool].self, from: $0) } ?? [:]
            // Freeze once, including filenames/custom paths, before any profile or global edit.
            let snapshot = Dictionary(uniqueKeysWithValues: CueEvent.allCases.map { event in
                let name = settings.string(forKey: "cueSound.\(event.rawValue)")
                var value = CueConfiguration(enabled: flags[event.rawValue] ?? (name != "Off"))
                if !event.wasProfileSetting, let data = settings.data(forKey: "audioCue.\(event.rawValue)"),
                    let saved = try? JSONDecoder().decode(CueConfiguration.self, from: data) { value = saved }
                value.builtInName = name == "Off" ? nil : name
                return (event.rawValue, value)
            })
            legacyMachine = snapshot
            settings.set(try? JSONEncoder().encode(snapshot), forKey: Self.legacySnapshotKey)
        }
        let oldActive = settings.data(forKey: "activeProfileAudioCues")
            .flatMap { try? JSONDecoder().decode([String: CueConfiguration].self, from: $0) }
        let oldValues = Self.legacyValues(oldActive, machine: legacyMachine)
        let current = settings.data(forKey: Self.currentProfileKey)
            .flatMap { try? JSONDecoder().decode(ProfileState.self, from: $0) }
        let active = current.flatMap { $0.version == Self.schemaVersion ? $0.configurations : nil } ?? oldValues
        profileConfigurations = Self.values(active, events: CueEvent.profileEvents)
        keyboardClicksEnabled = current.flatMap {
            $0.version == Self.schemaVersion ? $0.keyboardClicks : nil
        } ?? legacyKeyboardClicks
        let globals = settings.data(forKey: Self.globalsKey)
            .flatMap { try? JSONDecoder().decode([String: CueConfiguration].self, from: $0) }
        globalsInitialized = globals != nil
        globalConfigurations = Self.values(globals ?? oldValues, events: CueEvent.globalEvents)
    }

    private static func values(_ saved: [String: CueConfiguration], events: [CueEvent]) -> [String: CueConfiguration] {
        Dictionary(uniqueKeysWithValues: events.map { ($0.rawValue, saved[$0.rawValue] ?? CueConfiguration()) })
    }
    private static func legacyValues(_ saved: [String: CueConfiguration]?,
        machine: [String: CueConfiguration]) -> [String: CueConfiguration] {
        Dictionary(uniqueKeysWithValues: CueEvent.allCases.map { event in
            let old = machine[event.rawValue] ?? CueConfiguration()
            var value = old
            if event.wasProfileSetting, let saved { value = saved[event.rawValue] ?? CueConfiguration() }
            value.builtInName = value.builtInName ?? old.builtInName
            return (event.rawValue, value)
        })
    }
    public func loadProfile(_ configurations: [String: CueConfiguration]?, schemaVersion: Int = CuePreferences.schemaVersion,
        keyboardClicks: Bool? = nil) {
        let isLegacy = configurations == nil || schemaVersion < Self.schemaVersion
        let migrated = isLegacy ? Self.legacyValues(configurations, machine: legacyMachine) : configurations ?? [:]
        if !globalsInitialized {
            if isLegacy { globalConfigurations = Self.values(migrated, events: CueEvent.globalEvents) }
            persistGlobals()
        }
        profileConfigurations = Self.values(migrated, events: CueEvent.profileEvents)
        keyboardClicksEnabled = keyboardClicks ?? legacyKeyboardClicks
        persistProfile()
    }
    public func configuration(for event: CueEvent) -> CueConfiguration {
        (event.isProfileSetting ? profileConfigurations : globalConfigurations)[event.rawValue] ?? CueConfiguration()
    }
    private func set(_ configuration: CueConfiguration, for event: CueEvent) {
        if event.isProfileSetting {
            profileConfigurations[event.rawValue] = configuration
            persistProfile()
        } else {
            globalConfigurations[event.rawValue] = configuration
            persistGlobals()
        }
    }
    private func persistProfile() {
        settings.set(try? JSONEncoder().encode(ProfileState(version: Self.schemaVersion,
            configurations: profileConfigurations, keyboardClicks: keyboardClicksEnabled)), forKey: Self.currentProfileKey)
    }
    private func persistGlobals() {
        globalsInitialized = true
        settings.set(try? JSONEncoder().encode(globalConfigurations), forKey: Self.globalsKey)
        // Existing native plugin readers consume these two explicit Help snapshots.
        for event in [CueEvent.helpOpen, .helpClose] {
            let value = configuration(for: event)
            settings.set(try? JSONEncoder().encode(value), forKey: "audioCue.\(event.rawValue)")
            settings.set(value.builtInName, forKey: "cueSound.\(event.rawValue)")
        }
    }
    public func setEnabled(_ enabled: Bool, for event: CueEvent) {
        var value = configuration(for: event)
        value.enabled = enabled
        set(value, for: event)
    }
    public func chooseBuiltIn(_ name: String, for event: CueEvent) {
        set(CueConfiguration(builtInName: name), for: event)
    }
    public func chooseCustomFile(_ path: String, for event: CueEvent) {
        var value = configuration(for: event)
        value.enabled = true
        value.customPath = path
        set(value, for: event)
    }
    public func applyControl(_ selection: CueControlSelection, variants: [String]) -> Bool {
        switch selection.choice {
        case "on": setEnabled(true, for: selection.event)
        case "off": setEnabled(false, for: selection.event)
        default:
            guard variants.contains(selection.choice) else { return false }
            chooseBuiltIn(selection.choice, for: selection.event)
        }
        return true
    }
    public func builtInSelection(for event: CueEvent, variants: [String]) -> String? {
        let saved = configuration(for: event).builtInName ?? ""
        return variants.first { $0.caseInsensitiveCompare(saved) == .orderedSame } ?? variants.first
    }
    public func playbackCandidates(for event: CueEvent, variants: [String], directory: URL?) -> [URL] {
        let value = configuration(for: event)
        guard value.enabled else { return [] }
        var urls = [URL]()
        if let path = value.customPath, (path as NSString).isAbsolutePath {
            urls.append(URL(fileURLWithPath: path))
        }
        if let directory, let name = builtInSelection(for: event, variants: variants) {
            urls.append(directory.appendingPathComponent(name))
        }
        return urls
    }
}
