import AVFoundation

import AppKit
import Carbon
import ApplicationServices
import Carbon
import SwiftUI

import RemSoundCore
import RemSoundJam
import RemSoundRuntime
import ServiceManagement
import UniformTypeIdentifiers

private func isNavigationTab(_ event: NSEvent) -> Bool {
    event.keyCode == 48
        && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
}

private func hasKeyboardFocus(_ view: NSView, in window: NSWindow) -> Bool {
    guard let responder = window.firstResponder else { return false }
    if responder === view { return true }
    if view is NSTabView { return false }
    if let focusedView = responder as? NSView, focusedView.isDescendant(of: view) {
        return true
    }
    return (view as? NSTextField)?.currentEditor() === responder
}

private func accessibilityTreeContains(_ root: Any, _ target: NSView,
    visited: inout Set<ObjectIdentifier>) -> Bool {
    guard let element = root as? NSAccessibilityProtocol else { return false }
    let object = element as AnyObject
    if object === target { return true }
    if let control = target as? NSControl, let cell = control.cell,
        object === cell { return true }
    guard visited.insert(ObjectIdentifier(object)).inserted else { return false }
    for child in element.accessibilityChildren() ?? [] {
        if accessibilityTreeContains(child, target, visited: &visited) { return true }
    }
    return false
}
private func accessibilityOutline(_ root: Any, depth: Int = 0) -> String {
    guard depth < 5, let element = root as? NSAccessibilityProtocol else {
        return String(describing: type(of: root))
    }
    let head = "\(String(describing: type(of: root))) role=\(String(describing: element.accessibilityRole())) label=\(element.accessibilityLabel() ?? "")"
    let children = (element.accessibilityChildren() ?? []).prefix(10)
    return ([head] + children.map {
        String(repeating: "  ", count: depth + 1) + accessibilityOutline($0, depth: depth + 1)
    }).joined(separator: "\n")
}

final class PeerTable: NSTableView {
    var toggle: (() -> Void)?
    var rename: (() -> Void)?
    var peerMenu: NSMenu?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_F2) {
            rename?()
            return
        }
        if event.charactersIgnoringModifiers == " " {
            toggle?()
            return
        }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        guard clicked >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        return peerMenu
    }
}
final class CaptureSelectionTable: NSTableView {
    var toggle: ((Int) -> Void)?
    /// Delete (or forward delete) on a row: the remembered applications list forgets it.
    var delete: ((Int) -> Void)?
    var tabForward: (() -> Void)?
    var tabBackward: (() -> Void)?
    var clickTogglesRow = true
    override func keyDown(with event: NSEvent) {
        if isNavigationTab(event) {
            if event.modifierFlags.contains(.shift) { tabBackward?() }
            else { tabForward?() }
            return
        }
        if event.charactersIgnoringModifiers == " ", selectedRow >= 0 {
            toggle?(selectedRow)
            return
        }
        if let delete, selectedRow >= 0, event.specialKey == .delete || event.specialKey == .deleteForward {
            delete(selectedRow)
            return
        }
        super.keyDown(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        if clickTogglesRow && clicked >= 0 { toggle?(clicked) }
    }
}
final class CaptureTabPopUpButton: NSPopUpButton {
    var tabForward: (() -> Void)?
    var tabBackward: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if isNavigationTab(event) {
            if event.modifierFlags.contains(.shift) { tabBackward?() }
            else { tabForward?() }
            return
        }
        super.keyDown(with: event)
    }
}
enum SystemOutputSelection {
    // nil means All, while an empty list means that no outputs are selected.
    static func toggle(row: Int, current: [String]?, available: [String]) -> [String]? {
        guard row >= 0, row <= available.count else { return current }
        if row == 0 { return current == nil ? [] : nil }
        var selected = Set(current ?? available)
        let uid = available[row - 1]
        if selected.contains(uid) { selected.remove(uid) }
        else { selected.insert(uid) }
        return selected.count == available.count
            ? nil : available.filter { selected.contains($0) }
    }
}
enum AudioInputSelection {
    static func toggle(row: Int, current: [String], available: [String]) -> [String] {
        guard available.indices.contains(row) else { return current }
        let uid = available[row]
        if uid.isEmpty { return current == [""] ? [] : [""] }
        var selected = Set(current.filter { !$0.isEmpty })
        if selected.contains(uid) { selected.remove(uid) }
        else { selected.insert(uid) }
        return available.filter { selected.contains($0) }
    }
}
enum PlaybackPairSelection {
    static func toggle(uid: String, pair: Int, devices: [String],
        pairs: [String: [Int]], available: [String]) -> (devices: [String], pairs: [String: [Int]]) {
        guard let row = available.firstIndex(of: uid), !uid.isEmpty else {
            return (devices, pairs)
        }
        let wasSelected = devices.contains(uid)
        var selected = wasSelected ? pairs[uid] ?? [0] : []
        if selected.contains(pair) { selected.removeAll { $0 == pair } }
        else { selected.append(pair); selected.sort() }
        var updatedDevices = devices
        var updatedPairs = pairs
        if selected.isEmpty {
            updatedDevices.removeAll { $0 == uid }
            updatedPairs[uid] = nil
        } else {
            if !wasSelected {
                updatedDevices = AudioInputSelection.toggle(row: row,
                    current: devices, available: available)
            }
            updatedPairs[uid] = selected
        }
        return (updatedDevices, updatedPairs)
    }
}
enum CaptureSendState {
    static func afterSelection(previouslyEmpty: Bool, nowEmpty: Bool,
        sending: Bool, resumePending: Bool) -> (sending: Bool, resumePending: Bool) {
        if nowEmpty { return (false, sending || resumePending) }
        if previouslyEmpty { return (true, false) }
        return (sending, false)
    }
}
enum PlaybackMonitoringState {
    static func afterSelection(wasChecked: Bool, isChecked: Bool,
        hasOutputs: Bool, monitoring: Bool) -> Bool {
        if !hasOutputs { return false }
        if !wasChecked && isChecked { return true }
        return monitoring
    }
}
final class KeyboardTabView: NSTabView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func keyDown(with event: NSEvent) {
        let offset: Int
        switch event.specialKey {
        case .leftArrow: offset = -1
        case .rightArrow: offset = 1
        default:
            super.keyDown(with: event)
            return
        }
        cycle(offset)
    }

    /// The next or previous section, the strip taking the focus so the new tab is read (Windows: Ctrl+Tab and
    /// Ctrl+Shift+Tab from anywhere in the window, and the arrows on the strip).
    func cycle(_ offset: Int) {
        guard let selectedTabViewItem,
            let index = tabViewItems.firstIndex(of: selectedTabViewItem),
            !tabViewItems.isEmpty else { return }
        selectTabViewItem(at: (index + offset + tabViewItems.count) % tabViewItems.count)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
}
final class FocusableStatusField: NSTextField {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
}
final class KeyboardWindow: NSWindow {
    var moveTabFocus: ((Bool) -> Bool)?
    var contextHelp: ((Bool) -> Void)?
    var dialogKey: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if resetFocusedSlider(for: event) { return true }
        if dialogKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func resetFocusedSlider(for event: NSEvent) -> Bool {
        (firstResponder as? ResettableSlider)?.resetIfRequested(by: event) == true
    }

    /// The window's section tabs, for Control-Tab from anywhere in it.
    weak var sectionTabs: KeyboardTabView?

    override func sendEvent(_ event: NSEvent) {
        if resetFocusedSlider(for: event) { return }
        if dialogKey?(event) == true { return }
        let tabModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Tab), tabModifiers.contains(.control),
           !tabModifiers.contains(.command), !tabModifiers.contains(.option), let sectionTabs {
            sectionTabs.cycle(tabModifiers.contains(.shift) ? -1 : 1)
            makeFirstResponder(sectionTabs)
            return
        }
        let helpModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.type == .keyDown, event.keyCode == UInt16(kVK_F1),
            helpModifiers.isEmpty || helpModifiers == .shift, let contextHelp {
            contextHelp(helpModifiers == .shift)
            return
        }
        if event.type == .keyDown, isNavigationTab(event),
            moveTabFocus?(event.modifierFlags.contains(.shift)) == true { return }
        super.sendEvent(event)
    }
}
struct RecentMenuProfile: Identifiable {
    let id: UUID
    let title: String
}

enum RemSoundMenuAction {
    case about, help, contextHelp, preferences, openLogs, showWindow, toggleLaunchAtLogin, checkForUpdates, namedPeers
    case forgetSavedPassword, connectivityTab, audioTab, profileTab, mixTab
    case newProfile, saveProfile, saveProfileAs, openProfile, quickProfileSwitch, renameProfile
    case deleteProfile, toggleProfileLock, toggleRecording, profilePasswords
    case installPlugins, removePlugins, togglePluginShaping
    case changeRecordingsFolder, openRecordingsFolder
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSTabViewDelegate, HotkeyCaptureFieldDelegate, NSAlertDelegate, ObservableObject {
    @Published private(set) var recentMenuProfiles = [RecentMenuProfile]()
    @Published private(set) var menuProfileReadOnly = false
    /// The DAW Plugin menu: whether the plugins are installed (Install reads Reinstall then), and pan and EQ into the DAW.
    @Published private(set) var menuPluginsInstalled = false
    @Published private(set) var menuPluginShaping = AppRuntime.settings.object(forKey: AppDelegate.pluginShapingKey) as? Bool ?? true
    static let pluginShapingKey = "RemSoundApplyShapingToPlugin"
    @Published private(set) var menuLaunchAtLogin = false
    private var window: KeyboardWindow!
    private var preferencesWindow: KeyboardWindow?
    private var namedPeersWindow: NamedPeersWindow?
    private var focusedHelpWindow: FocusedHelpWindowController?
    private var manualReader: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    private var quickProfileWindow: QuickProfileSwitchWindowController?
    private var quickProfileReturnsToMenuBar = false
    private var preferencesControlOrder = [NSView]()
    private let preferencesTabs = KeyboardTabView()
    private var generalPreferencesOrder = [NSView]()
    private var permissionsControlOrder = [NSView]()
    private let microphonePermissionStatus = FocusableStatusField(wrappingLabelWithString: "Microphone: checking access.")
    private let systemAudioPermissionStatus = FocusableStatusField(wrappingLabelWithString: "System audio: not checked yet.")
    private let inputSendingStatus = FocusableStatusField(wrappingLabelWithString: "Input sending: checking.")
    private let microphonePermissionButton = NSButton(title: "Request microphone access", target: nil, action: nil)
    private let microphoneSettingsButton = NSButton(title: "Open Microphone settings", target: nil, action: nil)
    private let systemAudioPermissionButton = NSButton(title: "Check system audio access", target: nil, action: nil)
    private let systemAudioSettingsButton = NSButton(title: "Open Screen & System Audio Recording settings", target: nil, action: nil)
    private let enableInputSendingButton = NSButton(title: "Turn on selected input sending", target: nil, action: nil)
    private let refreshPermissionsButton = NSButton(title: "Refresh permission status", target: nil, action: nil)
    private var microphoneAccessCallbacks = [(Bool) -> Void]()
    private var systemAudioAccessCallbacks = [(Bool) -> Void]()
    private var systemAudioAccessAvailable = false
    private let hotkeys = GlobalHotkeyManager()
    private let updates = UpdateService()
    private var pendingUpdate: (stage: URL, version: String, helper: URL)?
    private var terminationRequest: UUID?
    private var terminationReady = false
    private var quitProfileConfirmation: UUID?
    private var routerControls: RouterMappingControls?
    private var sessionStartRequest: UUID?
    private static let sessionShutdownTimeout: TimeInterval = 20
    private var hotkeyBindings = [GlobalHotkeyAction: HotkeyDescriptor]()
    private let showHideHotkey = HotkeyCaptureField()
    private let sendingHotkey = HotkeyCaptureField()
    private let receivingHotkey = HotkeyCaptureField()
    private let dawHotkey = HotkeyCaptureField()
    private let remoteVolumeUpHotkey = HotkeyCaptureField(), remoteVolumeDownHotkey = HotkeyCaptureField(),
        remoteMuteHotkey = HotkeyCaptureField(), remoteSystemUpHotkey = HotkeyCaptureField(),
        remoteSystemDownHotkey = HotkeyCaptureField(), remoteSystemMuteHotkey = HotkeyCaptureField()
    private let allShapingHotkey = HotkeyCaptureField()
    private let quickProfileHotkey = HotkeyCaptureField()
    private let localVolumeUpHotkey = HotkeyCaptureField(), localVolumeDownHotkey = HotkeyCaptureField(),
        recordingHotkey = HotkeyCaptureField(), speakStatusHotkey = HotkeyCaptureField(),
        metronomeHotkey = HotkeyCaptureField(), metronomeTempoUpHotkey = HotkeyCaptureField(),
        metronomeTempoDownHotkey = HotkeyCaptureField(), metronomeVolumeUpHotkey = HotkeyCaptureField(),
        metronomeVolumeDownHotkey = HotkeyCaptureField(), hearMyselfHotkey = HotkeyCaptureField(),
        muteReceivedHotkey = HotkeyCaptureField()
    /// Every global shortcut row in Preferences and its action, in the order they are listed.
    private var shortcutFieldActions: [(HotkeyCaptureField, GlobalHotkeyAction)] = []
    private var lastSpeakStatusPress = Date.distantPast
    private let pushToTalkHotkey = HotkeyCaptureField()
    private let pushToTalkKeyStatus = NSTextField(labelWithString: "")
    private var hotkeyResumeInput = false
    private var hotkeyResumeSystem = false
    private let tabs = KeyboardTabView()
    private var tabFirstControls = [NSView]()
    /// Preferences' appearance, startup, profiles-folder, list and log choices (Windows PreferencesDialog).
    private let preferencesExtras = PreferencesExtras()
    /// Cues already reported missing this run: each is said once (Windows ReportMissingCueSound).
    private var reportedMissingCues = Set<CueEvent>()
    /// The main window's four tabs as built, in their usual order, so they can be reordered or the Pan / EQ tab hidden.
    private var mainTabItems: [NSTabViewItem] = []
    private let session = Session(configuration: AppRuntime.configuration)
    /// The browser listener itself, for its list of browsers (the window shows it; the log keeps it, as Windows does).
    private var browserService: BrowserListenerService?
    private var loggedBrowsers: [Int: (key: String, at: TimeInterval)] = [:]
    private lazy var browserListener: BrowserSessionOwner = {
        let service = BrowserListenerService(runtime: AppRuntime.configuration, session: session)
        browserService = service
        let owner = BrowserSessionOwner(backend: service)
        owner.onFailure = { [weak self] in
            self?.recordStartup("Browser listener cleanup could not be confirmed; dependent changes remain fenced.")
            self?.announce("The browser listener did not close properly. Stop RemSound and start it again to clear it.")
        }
        owner.onListenerFailure = { [weak self] in
            self?.recordStartup("Browser listener became unavailable; source revoked and cleanup requested.")
            self?.announce("Browser listener is unavailable. Cleanup was requested; retry requires an explicit new choice.")
        }
        owner.onConfigurationInvalidated = { [weak self] in self?.invalidateBrowserProfileEditing() }
        owner.onAudioConfigurationInvalidated = { [weak self] in self?.invalidateBrowserProfileEditing(preservingListener:true) }
        return owner
    }()
    #if DEBUG
    private var browserStopSubmissions = 0, browserShutdownSubmissions = 0, browserSourceReceipts = 0
    private var browserStartSubmissionProbe: (() -> Void)?
    #endif
    private var controlServer: LocalControlServer?
    private var controlView: SessionView?
    private var draftLoggingBaseline: Bool?
    private var nativeProductFixture = false
    private var profileLoggingModalCancel = false
    private var profileLoggingChoice: Bool?
    private var effectiveLoggingEnabled = AppRuntime.configuration.diagnosticLoggingEnabled
    /// The DAW plugins log only while RemSound's logs are on (Windows: the plugin reads the app's choice). They look for
    /// this marker in the logs folder; nil until the first check.
    private var pluginLogMarkerShown: Bool?
    private let enableLogs = NSButton(checkboxWithTitle: "Enable diagnostic logs for this profile", target: nil, action: nil)
    private let uiObservations = UIResponsivenessMonitor(
        logURL: AppRuntime.configuration.logsDirectory.appendingPathComponent("Responsiveness.log"),
        enabled: AppRuntime.configuration.diagnosticLoggingEnabled)
    private var pendingUIEffects = [ResponsivenessDiagnostics.Operation: (id: UUID, matches: (SessionView) -> Bool)]()
    private var hideObservation: UUID?
    private func beginUIObservation(_ operation: ResponsivenessDiagnostics.Operation,
                                    matches: ((SessionView) -> Bool)? = nil) -> UUID {
        if let previous = pendingUIEffects.removeValue(forKey: operation) {
            uiObservations.finish(previous.id, outcome: .superseded)
        }
        let id = uiObservations.begin(operation)
        if let matches { pendingUIEffects[operation] = (id, matches) }
        return id
    }
    private func observeUIEffects(_ view: SessionView) {
        for (operation, request) in pendingUIEffects where request.matches(view) {
            uiObservations.finish(request.id)
            pendingUIEffects.removeValue(forKey: operation)
        }
    }
    /// The Server and Metronome menus and the Server window (JamController.swift).
    let jam = JamController()
    private var passwordStore = AppRuntime.passwordStore()
    private let profileStore = ProfileStore(directory: AppRuntime.configuration.profilesDirectory)
    private var browserOptions = BrowserListenerOptions()
    private var browserProfileRevision = UUID()
    private var browserProfileTransaction: BrowserProfileTransaction?
    private var browserProfileRemoval: BrowserProfileRemoval?, browserRemovalID: UUID?
    private var browserRemovalPreparing=false, browserProfilePromptRetiring=false
    private var profileModalActive=false, profileModalEpoch=UUID()
    private struct ProfileStopContext {
        let id:UUID,revision:UUID,source:UUID,passwordEpoch:UUID
        let profile:ConnectionProfile?,draft:UUID?,form:ConnectionProfile
        let profiles:ObjectIdentifier,passwordStore:ObjectIdentifier
    }
    private var profileStopContext:ProfileStopContext?,profileStopDispatch:UUID?
    private var browserListenerWindow: BrowserListenerWindow?
    private var browserWindowRequest: UUID?
    private let browserListenerButton=NSButton(title:"Browser listener…",target:nil,action:nil)
    private var browserWorkingChoice: (account: UUID, scope: UUID, choice: BrowserListenerChoice)?
    private var browserEffectiveChoice: (scope: UUID, choice: BrowserListenerChoice)?
    #if DEBUG
    private var browserCredentialExecutor: BrowserCredentialAccess.Executor?
    private var browserRemovalFileProbe: ((UUID) throws -> Void)?
    private var profileModalProbe: ((NSAlert) -> NSApplication.ModalResponse)?
    private var browserBeforeSessionShutdownProbe: (() -> Void)?
    private var terminationCompletedForTesting: (() -> Void)?
    #endif
    private var activeProfile: ConnectionProfile?
    private var draftProfileID: UUID?
    private let statusRecentProfilesMenu = NSMenu(title: "Recent Profiles")
    private var statusItem: NSStatusItem!
    private let statusSummary = NSMenuItem(title: "Stopped", action: nil, keyEquivalent: "")
    private let statusStart = NSMenuItem(title: "Start", action: nil, keyEquivalent: "")
    private let statusStop = NSMenuItem(title: "Stop", action: nil, keyEquivalent: "")
    private let statusSend = NSMenuItem(title: "Send selected audio input", action: nil, keyEquivalent: "")
    private let statusSystem = NSMenuItem(title: "Send Mac system audio", action: nil, keyEquivalent: "")
    private let statusReceive = NSMenuItem(title: "Receive peer audio for app and DAW", action: nil, keyEquivalent: "")
    private let statusMonitor = NSMenuItem(title: "Play received audio through Mac output", action: nil, keyEquivalent: "")
    private let statusRecord = NSMenuItem(title: "Start recording", action: nil, keyEquivalent: "")
    private let loginAtStartup = NSButton(
        checkboxWithTitle: "Launch RemSound at login", target: nil, action: nil)
    private let checkUpdates = NSButton(
        checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
    private let installUpdates = NSButton(
        checkboxWithTitle: "Install verified updates automatically", target: nil, action: nil)
    // The rest of Windows' update choices: how often to look in the background, a time range for automatic installs,
    // and what's new after an update.
    private let updateFrequency = NSPopUpButton()
    private let updateWindowEnabled = NSButton(
        checkboxWithTitle: "Only install automatic updates between these times", target: nil, action: nil)
    private let updateWindowStart = NSPopUpButton(), updateWindowEnd = NSPopUpButton()
    private let showWhatsNew = NSButton(checkboxWithTitle: "Show what's new after an update", target: nil, action: nil)
    private let peer = NSTextField(string: ""), name = NSTextField(string: "RemSound Mac"),
        password = NSSecureTextField(string: "")
    private let send = NSButton(checkboxWithTitle: "Send selected audio input", target: nil, action: nil)
    private let systemAudio = NSButton(checkboxWithTitle: "Send Mac system audio", target: nil, action: nil)
    private let receive = NSButton(
        checkboxWithTitle: "Receive peer audio for app and DAW", target: nil, action: nil)
    private let monitor = NSButton(
        checkboxWithTitle: "Play received audio through Mac output", target: nil, action: nil)
    private let plugins = NSButton(
        checkboxWithTitle: "Allow DAW plugins on this Mac", target: nil, action: nil)
    private let metronomeVolume = ResettableSlider.metronomeVolume()
    private var applyingMetronomeVolumeAction = false
    /// Remote volume and mute: this Mac's listening volume and receive mute (a peer may change them only with
    /// acceptRemoteVolume ticked, in Preferences).
    private let listeningVolume = ResettableSlider.volume()
    private let receiveMute = NSButton(checkboxWithTitle: "Mute received audio", target: nil, action: nil)
    private let acceptRemoteVolume = NSButton(
        checkboxWithTitle: "Accept remote volume commands from peers", target: nil, action: nil)
    /// What happens when somebody ticks you (Windows Preferences, Connectivity): Ask me each time, Automatically, Manual.
    private let acceptConnectionsLabel = NSTextField(labelWithString: "Accept connections from other peers")
    private let acceptConnections = NSPopUpButton()
    private let inputTable = CaptureSelectionTable()
    private var inputChoices = [(uid: String, name: String)]()
    private var selectedInputUIDs = [""]
    private let inputPairTable = CaptureSelectionTable()
    private var inputPairChoices = [(uid: String, name: String, pair: Int)]()
    private var selectedInputChannelPairs = [String: [Int]]()
    private var resumeInputSendingWhenSelected = false
    private let outputTable = CaptureSelectionTable()
    private var outputChoices = [(uid: String, name: String)]()
    private var selectedOutputUIDs = [""]
    private let outputPairTable = CaptureSelectionTable()
    private var outputPairChoices = [(uid: String, name: String, pair: Int)]()
    private var selectedOutputChannelPairs = [String: [Int]]()
    private let systemOutputTable = CaptureSelectionTable()
    private var systemOutputs = [(uid: String, name: String)]()
    private var selectedCaptureUIDs: [String]?
    private let systemOutputPairTable = CaptureSelectionTable()
    private var systemOutputPairChoices = [(uid: String, name: String, pair: Int)]()
    private var selectedCaptureChannelPairs = [String: [Int]]()
    private var resumeSystemSendingWhenSelected = false
    /// Sending chosen applications' sound instead of whole outputs (Windows' "Send specific applications"): the mode,
    /// the two lists, the applications chosen (bundle IDs) - remembered machine-wide once chosen, as on Windows.
    private let systemAudioMode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let activeAppsTable = CaptureSelectionTable()
    private let rememberedAppsTable = CaptureSelectionTable()
    private var activeApps = [AudioApp](), rememberedApps = [AudioApp]()
    private var chosenApplications = AppRuntime.settings.stringArray(forKey: "systemAudioApplications") ?? []
    private var outputCaptureViews = [NSView](), applicationCaptureViews = [NSView]()
    private var applicationListTimer: Timer?
    private var sendingApplications: Bool { systemAudioMode.indexOfSelectedItem == 1 }
    private var systemAudioAccessChecked = false
    private let codec = NSPopUpButton(frame: .zero, pullsDown: false)
    private let packetSize = NSPopUpButton(frame: .zero, pullsDown: false)
    private let recordingSource = NSPopUpButton(frame: .zero, pullsDown: false)
    private let receiveJitter = NSPopUpButton(frame: .zero, pullsDown: false)
    private let receiveSmoothness = NSPopUpButton(frame: .zero, pullsDown: false)
    private let receiveArtifact = NSPopUpButton(frame: .zero, pullsDown: false)
    private let receiveAutoTune = NSButton(
        checkboxWithTitle: "Continuous auto-tune receive jitter buffer", target: nil, action: nil)
    private let receiveAutoTuneInterval = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Windows' "Lowest-delay auto-tune, accepting a rare dropout": with auto-tune on, the dropout tuner instead.
    private let receiveLowestDelay = NSButton(
        checkboxWithTitle: "Lowest-delay auto-tune, accepting a rare dropout", target: nil, action: nil)
    private let receiveLatencyStatus = FocusableStatusField(wrappingLabelWithString: "")
    private let selfMonitoringButton = NSButton(title: "Unmute myself to test round trip", target: nil, action: nil)
    private let selfMonitoringStatus = FocusableStatusField(wrappingLabelWithString: "Self-monitoring off.")
    private var networkRTT = "not measured"
    private let recordingFormat = NSPopUpButton(frame: .zero, pullsDown: false)
    private let flacCompression = NSPopUpButton(frame: .zero, pullsDown: false)
    private let recordingChannels = NSPopUpButton(frame: .zero, pullsDown: false)
    private let splitRecording = NSButton(checkboxWithTitle: "Split recording into peer tracks",
        target: nil, action: nil)
    private let recordingBypassShaping = NSButton(checkboxWithTitle: "Bypass pan and EQ when recording",
        target: nil, action: nil)
    private let recordingButton = NSButton(title: "Start recording", target: nil, action: nil)
    private let refreshDevices = NSButton(title: "Refresh audio devices", target: nil, action: nil)
    /// Windows' "Peer details" box: what is known about the highlighted peer, read-only, kept current but never
    /// rewritten while it has the focus.
    private let peerDetails = FocusableStatusField(wrappingLabelWithString: PeerDetailsText.nothingHighlighted)
    private var peerDetailsTimer: Timer?
    /// Windows' Connection status box: who you are connected to and how, the traffic, and RemSound's CPU and memory.
    private let connectionStatus = FocusableStatusField(wrappingLabelWithString: "Not connected to any peer.")
    /// The Total latency figures on show, kept until they move 3 ms (Windows' rule).
    private var shownLatencyFigures: TotalLatencyText.Figures?
    /// Windows' "Uncheck all inputs and outputs on all soundcards": every device list emptied at once, silently.
    private let uncheckAllDevices = NSButton(title: "Uncheck all inputs and outputs", target: nil, action: nil)
    private let remember = NSButton(
        checkboxWithTitle: "Remember password in Mac Keychain", target: nil, action: nil)
    private let reconnect = NSButton(
        checkboxWithTitle: "Reconnect automatically when RemSound opens", target: nil, action: nil)
    private lazy var typingPlayer: TypingSoundPlayer = {
        let playback = DispatchQueue(label: "org.remsound.typing", qos: .userInitiated)
        return TypingSoundPlayer(configuration: AppRuntime.configuration, preferences: CueSounds.shared.preferences,
            enqueue: { playback.async(execute: $0) },
            load: { TypingAudioCache.bundled(directory: Bundle.main.resourceURL?.appendingPathComponent("default sounds", isDirectory: true)) },
            makeOutput: { try TypingAudioOutput(cache: $0) }, flush: { playback.sync {} })
    }()
    private lazy var typingMonitor = TypingEventMonitor(configuration: AppRuntime.configuration,
        preferences: CueSounds.shared.preferences, onCharacter: { [weak self] in self?.typingPlayer.play(password: $0) })
    private var typingFeedbackStarted = false
    private lazy var cuePane: CuePreferencesPane = {
        let pane = CuePreferencesPane(cues: .shared)
        pane.onKeyboardClicksChanged = { [weak self] in self?.refreshTypingFeedback() }
        return pane
    }()
    private var cueMute: NSButton { cuePane.mute }
    private var cueChoice: NSPopUpButton { cuePane.choice }
    private var cueBrowse: NSButton { cuePane.browse }
    private var cuePreview: NSButton { cuePane.play }
    private var cueCustomFiles: [CueEvent: String] {
        get { cuePane.customFiles }
        set { cuePane.customFiles = newValue }
    }
    private let autoSaveInterval = NSPopUpButton(frame: .zero, pullsDown: false)
    private var autoSaveTimer: Timer?
    private var selectedAudioTab: Int?
    private let start = NSButton(title: "Start", target: nil, action: nil),
        stop = NSButton(title: "Stop", target: nil, action: nil),
        toggle = NSButton(title: "Select or deselect highlighted peer", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "Stopped. No audio is being sent.")
    private let profileNotice = NSTextField(wrappingLabelWithString: "No saved profile is active.")
    private let intro = NSTextField(
        wrappingLabelWithString:
            "Use the same shared password on both computers. Start, then select each other in the peer list. Sending stays off until you enable it."
    )
    private let profileIntro = NSTextField(
        wrappingLabelWithString: "Recording and profile commands. Audio settings are on Audio I/O.")
    private let recordingsFolderButton = NSButton(title: "Change recordings folder…", target: nil, action: nil)
    private let openProfileButton = NSButton(title: "Open Profile…", target: nil, action: nil)
    private let saveProfileButton = NSButton(title: "Save Profile", target: nil, action: nil)
    private let saveAsProfileButton = NSButton(title: "Save Profile As…", target: nil, action: nil)
    private let table = PeerTable()
    private let mixPeer = NSPopUpButton(frame: .zero, pullsDown: false)
    private let peerMixEnabled = NSButton(checkboxWithTitle: "Shape selected peer", target: nil, action: nil)
    private let peerVolume = ResettableSlider.volume()
    private let peerPan = ResettableSlider.pan()
    /// Windows' per-peer shaping: the master switch, the EQ mode, twelve graphic sliders (three shown for the simple EQ;
    /// 0 to 100, 50 flat), and the parametric EQ's Add band, bands list and Delete band; and Set peer EQ to default.
    private let allPeerShaping = NSButton(
        checkboxWithTitle: "Enable volume, pan and EQ for all peers", target: nil, action: nil)
    private let eqMode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let eqBandSliders = (0..<12).map { _ in ResettableSlider.equalizerBand() }
    private let eqBandLabels = (0..<12).map { _ in NSTextField(labelWithString: "") }
    private var eqBandRows = [NSStackView]()
    private let addBandButton = NSButton(title: "Add band…", target: nil, action: nil)
    private let bandList = BandListTable()
    private let bandListScroll = NSScrollView()
    private let bandsLabel = NSTextField(labelWithString: "Bands")
    private let deleteBandButton = NSButton(title: "Delete band", target: nil, action: nil)
    private let resetPeerEq = NSButton(title: "Set peer EQ to default", target: nil, action: nil)
    private let pushToTalkKeys = PushToTalkKeyController()
    private var playPushToTalkCue: (CueEvent) -> Void = { CueSounds.shared.play($0) }
    private var pushToTalkSettings = PushToTalkSettings()
    private var pushToTalkSettingsUnreadable = false
    private var pushToTalkWindow: PushToTalkSettingsWindow?
    private var pushToTalkPreview: PushToTalkPreview?
    private var makePushToTalkPreview: (() -> PushToTalkPreview)?
    private let pushToTalkButton = NSButton(title: "Push to talk settings…", target: nil, action: nil)
    private var pushToTalkClosing = false
    private var pushToTalkSubmittedStartRequest: UUID?
    private var pushToTalkInput: PushToTalkInputOwner?
    private var pushToTalkCaptureFields = Set<ObjectIdentifier>()
    private var pushToTalkFocusObservers: [NSObjectProtocol] = []
    private var peerMixes: [String: PeerMix] =
        (try? JSONDecoder().decode([String: PeerMix].self,
            from: AppRuntime.settings.data(forKey: "peerMixes") ?? Data())) ?? [:]
    private var peerAliases: [String: String] =
        AppRuntime.settings.dictionary(forKey: "peerAliases") as? [String: String] ?? [:]
    private var rows: [PeerView] = []
    private var rememberedPeerEntries: [String] = []
    private let connectivityPeers = ConnectivityPeerControls()
    private var running = false
    private var connectedPeerCount = 0
    private var chooseProfileAfterStop = false
    private var recentProfileAfterStop: ConnectionProfile?
    private var accessibilitySessionStartRequests = 0
    private func recordStartup(_ message: String) {
        guard effectiveLoggingEnabled else { return }
        let directory = AppRuntime.configuration.logsDirectory
        let url = directory.appendingPathComponent("Startup.log")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
                size.intValue > 32768 {
                try Data().write(to: url, options: .atomic)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
            try handle.write(contentsOf: Data(
                "\(ISO8601DateFormatter().string(from: Date())) RemSound \(version): \(message)\n".utf8))
        } catch {}
    }
    private func closeSettingsPlaceholder() {
        for candidate in NSApp.windows where candidate.isVisible
            && candidate !== window
            && candidate !== preferencesWindow
            && candidate !== statusItem.button?.window
            && candidate.frame.width < 300
            && candidate.frame.height < 150 {
            recordStartup("Closing redundant startup window (\(Int(candidate.frame.width)) by \(Int(candidate.frame.height))).")
            candidate.close()
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = browserListener
        // A wake is a line in the log, and named in the reason of a disconnect soon after (Windows 6.2.3).
        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                              queue: .main) { [weak self] _ in self?.session.noteWake() }
        let accessibilityCheck = CommandLine.arguments.contains("--check-accessibility")
        NSApp.setActivationPolicy(AppRuntime.configuration.isHeadless || startupHidden ? .accessory : .regular)
        if !nativeProductFixture { configureStatusItem() }
        refreshRecentProfileMenus()
        refreshLoginItem()
        window = KeyboardWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "RemSound Mac"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 520)
        window.sectionTabs = tabs
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
        ])
        func sectionStack() -> NSStackView {
            let view = NSStackView()
            view.orientation = .vertical
            view.alignment = .leading
            view.spacing = 8
            view.translatesAutoresizingMaskIntoConstraints = false
            return view
        }
        routerControls = RouterMappingControls(configuration: AppRuntime.configuration)
        let connectivityStack = sectionStack()
        let audioStack = sectionStack()
        let profileStack = sectionStack()
        let mixStack = sectionStack()
        var stack = connectivityStack
        stack.addArrangedSubview(intro)
        intro.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        func field(_ label: String, _ control: NSTextField, _ help: String) {
            let text = NSTextField(labelWithString: label)
            control.setAccessibilityLabel(label)
            control.setAccessibilityHelp(help)
            let line = NSStackView(views: [text, control])
            line.orientation = .horizontal
            text.widthAnchor.constraint(equalToConstant: 190).isActive = true
            stack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        name.stringValue = AppRuntime.settings.string(forKey: "displayName") ?? "RemSound Mac"
        peer.stringValue = AppRuntime.settings.string(forKey: "peerAddress") ?? ""
        field("Your name", name, "Name announced to peers on your local network.")
        field(
            "Peer IPv4 address or host", peer,
            "Optional. This peer is selected when you start. Leave blank to use discovery.")
        field(
            "Shared password", password,
            "Required. Stored only in Mac Keychain when Remember password is checked; never saved in your DAW project.")
        remember.state = AppRuntime.settings.object(forKey: "rememberPassword") == nil
            || AppRuntime.settings.bool(forKey: "rememberPassword") ? .on : .off
        remember.setAccessibilityHelp("Uncheck to remove the saved password from Mac Keychain immediately.")
        remember.target = self
        remember.action = #selector(rememberChanged)
        reconnect.state = AppRuntime.settings.bool(forKey: "reconnectOnOpen") ? .on : .off
        reconnect.setAccessibilityHelp(
            "Start automatically when RemSound opens. Requires a saved password and restores your saved sending and receiving choices.")
        reconnect.target = self
        reconnect.action = #selector(reconnectChanged)
        stack = audioStack
        for (button, key, hint) in [
            (send, "i", "Command-I. Sends the chosen microphone or line input, not system playback. You may also send system audio at the same time."),
            (systemAudio, "u", "Command-U. Sends Mac app playback to peers independently of the selected input and DAW plugin. First use requires System Audio Recording permission. RemSound excludes its own playback."),
            (receive, "r", "Command-R. Allows incoming peer audio to reach this Mac and its DAW plugins."),
            (plugins, "d", "Command-D. Allows DAW plugins to connect over loopback only."),
        ] {
            button.keyEquivalent = key
            button.keyEquivalentModifierMask = .command
            button.setAccessibilityHelp(hint)
            button.target = self
            button.action = #selector(audioCheckboxChanged(_:))
        }
        send.state = AppRuntime.settings.bool(forKey: "sendInput") ? .on : .off
        systemAudio.state = AppRuntime.settings.bool(forKey: "sendSystemAudio") ? .on : .off
        receive.state = AppRuntime.settings.object(forKey: "receiveAudio") == nil
            || AppRuntime.settings.bool(forKey: "receiveAudio") ? .on : .off
        monitor.state = AppRuntime.settings.object(forKey: "monitorInApp") == nil
            || AppRuntime.settings.bool(forKey: "monitorInApp") ? .on : .off
        monitor.setAccessibilityHelp(
            "Command-L. Controls the Mac app output separately from the Receive switch in each DAW plugin. Turn this off for DAW-only listening.")
        monitor.keyEquivalent = "l"
        monitor.keyEquivalentModifierMask = .command
        monitor.target = self
        monitor.action = #selector(audioCheckboxChanged(_:))
        plugins.state = AppRuntime.settings.object(forKey: "allowPlugins") == nil
            || AppRuntime.settings.bool(forKey: "allowPlugins") ? .on : .off
        let outputHeading = NSTextField(labelWithString:
            "Mac playback outputs — Space checks or unchecks")
        let outputColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("playbackOutput"))
        outputColumn.title = "Mac playback output selection"
        outputColumn.width = 620
        outputTable.addTableColumn(outputColumn)
        outputTable.headerView = nil
        outputTable.dataSource = self
        outputTable.delegate = self
        outputTable.setAccessibilityLabel("Mac playback outputs")
        outputTable.setAccessibilityHelp(
            "Choose one or more output cards for received audio. System default follows Mac output changes and cannot be combined with named cards. DAW plugin output remains controlled by its host.")
        outputTable.toggle = { [weak self] row in self?.togglePlaybackOutput(row) }
        let outputScroll = NSScrollView()
        outputScroll.documentView = outputTable
        outputScroll.hasVerticalScroller = true
        outputScroll.borderType = .bezelBorder
        outputScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        let outputPairHeading = NSTextField(labelWithString:
            "Mac playback output pairs — Space checks or unchecks")
        let outputPairColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("outputPair"))
        outputPairColumn.title = "Mac playback channel pairs"
        outputPairColumn.width = 620
        outputPairTable.addTableColumn(outputPairColumn)
        outputPairTable.headerView = nil
        outputPairTable.dataSource = self
        outputPairTable.delegate = self
        outputPairTable.setAccessibilityLabel("Mac playback output channel pairs")
        outputPairTable.setAccessibilityHelp(
            "Multichannel cards only. Use Up and Down to hear each channel pair and checked state. Space changes the highlighted pair. Checking a pair selects its card; unchecking its last pair deselects the card.")
        outputPairTable.toggle = { [weak self] row in self?.toggleOutputPair(row) }
        let outputPairScroll = NSScrollView()
        outputPairScroll.documentView = outputPairTable
        outputPairScroll.hasVerticalScroller = true
        outputPairScroll.borderType = .bezelBorder
        outputPairScroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
        let inputHeading = NSTextField(labelWithString: "Audio inputs to send — Space checks or unchecks")
        let inputColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("audioInput"))
        inputColumn.title = "Audio input selection"
        inputColumn.width = 620
        inputTable.addTableColumn(inputColumn)
        inputTable.headerView = nil
        inputTable.dataSource = self
        inputTable.delegate = self
        inputTable.setAccessibilityLabel("Audio inputs to send")
        inputTable.setAccessibilityHelp(
            "Use Up and Down to hear each input and whether it is checked. Space changes the highlighted row. System default follows Mac input changes and cannot be combined with named inputs.")
        inputTable.toggle = { [weak self] row in self?.toggleAudioInput(row) }
        let inputScroll = NSScrollView()
        inputScroll.documentView = inputTable
        inputScroll.hasVerticalScroller = true
        inputScroll.borderType = .bezelBorder
        inputScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        let pairHeading = NSTextField(labelWithString:
            "Professional interface input pairs — Space checks or unchecks")
        let pairColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("inputPair"))
        pairColumn.title = "Interface input channel pairs"
        pairColumn.width = 620
        inputPairTable.addTableColumn(pairColumn)
        inputPairTable.headerView = nil
        inputPairTable.dataSource = self
        inputPairTable.delegate = self
        inputPairTable.setAccessibilityLabel("Professional interface input channel pairs")
        inputPairTable.setAccessibilityHelp(
            "Use Up and Down to hear each stereo pair and its checked state. Space changes the highlighted pair. Checking a pair also selects its interface.")
        inputPairTable.toggle = { [weak self] row in self?.toggleInputPair(row) }
        let pairScroll = NSScrollView()
        pairScroll.documentView = inputPairTable
        pairScroll.hasVerticalScroller = true
        pairScroll.borderType = .bezelBorder
        pairScroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
        let captureHeading = NSTextField(labelWithString: "System capture outputs — Space checks or unchecks")
        let captureColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("systemOutput"))
        captureColumn.title = "System output selection"
        captureColumn.width = 620
        systemOutputTable.addTableColumn(captureColumn)
        systemOutputTable.headerView = nil
        systemOutputTable.dataSource = self
        systemOutputTable.delegate = self
        systemOutputTable.setAccessibilityLabel("System capture outputs")
        systemOutputTable.setAccessibilityHelp(
            "Use Up and Down to hear each output and whether it is checked. Space changes the highlighted row. All system outputs is first and includes new arrivals.")
        systemOutputTable.clickTogglesRow = false
        systemOutputTable.toggle = { [weak self] row in self?.toggleSystemOutput(row) }
        let captureScroll = NSScrollView()
        captureScroll.documentView = systemOutputTable
        captureScroll.hasVerticalScroller = true
        captureScroll.borderType = .bezelBorder
        captureScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        let capturePairHeading = NSTextField(labelWithString:
            "System capture output pairs — Space checks or unchecks")
        let capturePairColumn = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("systemOutputPair"))
        capturePairColumn.title = "System capture channel pairs"
        capturePairColumn.width = 620
        systemOutputPairTable.addTableColumn(capturePairColumn)
        systemOutputPairTable.headerView = nil
        systemOutputPairTable.dataSource = self
        systemOutputPairTable.delegate = self
        systemOutputPairTable.setAccessibilityLabel("System capture output channel pairs")
        systemOutputPairTable.setAccessibilityHelp(
            "Multichannel cards only. Up and Down read each pair and checked state. Space changes the pair; checking one selects its output card.")
        systemOutputPairTable.toggle = { [weak self] row in self?.toggleSystemOutputPair(row) }
        let capturePairScroll = NSScrollView()
        capturePairScroll.documentView = systemOutputPairTable
        capturePairScroll.hasVerticalScroller = true
        capturePairScroll.borderType = .bezelBorder
        capturePairScroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
        let systemModeLabel = NSTextField(labelWithString: "How to send Mac system audio")
        systemModeLabel.widthAnchor.constraint(equalToConstant: 240).isActive = true
        systemAudioMode.setAccessibilityLabel("How to send Mac system audio")
        systemAudioMode.setAccessibilityHelp(
            "Whole outputs sends everything the chosen outputs play. Specific applications sends only the applications ticked below, from their first sound.")
        systemAudioMode.addItems(withTitles: ["Send whole outputs", "Send specific applications"])
        systemAudioMode.selectItem(at: AppRuntime.settings.bool(forKey: "systemAudioFromApplications") ? 1 : 0)
        systemAudioMode.target = self
        systemAudioMode.action = #selector(systemAudioModeChanged)
        let systemModeRow = NSStackView(views: [systemModeLabel, systemAudioMode])
        systemModeRow.orientation = .horizontal
        func applicationTable(_ table: CaptureSelectionTable, _ name: String, _ help: String) -> NSScrollView {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
            column.title = name
            column.width = 620
            table.addTableColumn(column)
            table.headerView = nil
            table.dataSource = self
            table.delegate = self
            table.setAccessibilityLabel(name)
            table.setAccessibilityHelp(help)
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
            return scroll
        }
        let activeAppsHeading = NSTextField(labelWithString: "Currently active applications — Space checks or unchecks")
        let activeAppsScroll = applicationTable(activeAppsTable, "Currently active applications",
            "Applications with sound on this Mac now, then any you chose that is not running. Up and Down read each and whether it is ticked; Space ticks or unticks it.")
        activeAppsTable.toggle = { [weak self] row in self?.toggleApplication(row, remembered: false) }
        let rememberedAppsHeading = NSTextField(labelWithString: "Remembered applications — Space checks or unchecks, Delete forgets")
        let rememberedAppsScroll = applicationTable(rememberedAppsTable, "Remembered applications",
            "Applications chosen on this Mac before and not chosen now. Space ticks one to send it again; Delete forgets it.")
        rememberedAppsTable.toggle = { [weak self] row in self?.toggleApplication(row, remembered: true) }
        rememberedAppsTable.delete = { [weak self] row in self?.forgetApplication(row) }
        outputCaptureViews = [captureHeading, captureScroll, capturePairHeading, capturePairScroll]
        applicationCaptureViews = [activeAppsHeading, activeAppsScroll, rememberedAppsHeading, rememberedAppsScroll]
        let codecLabel = NSTextField(labelWithString: "Sending codec")
        codecLabel.widthAnchor.constraint(equalToConstant: 190).isActive = true
        codec.setAccessibilityLabel("Sending codec")
        codec.setAccessibilityHelp("Choose lossless PCM or Opus compression. Changes also apply to DAW sends and saved profiles.")
        for choice in SendCodec.allCases {
            codec.addItem(withTitle: choice.label)
            codec.lastItem?.representedObject = choice.rawValue
        }
        let savedCodec = AppRuntime.settings.string(forKey: "sendCodec") ?? SendCodec.opusLive.rawValue
        codec.selectItem(withTitle: SendCodec(rawValue: savedCodec)?.label ?? SendCodec.pcm.label)
        codec.target = self
        codec.action = #selector(audioOptionsChanged)
        let codecRow = NSStackView(views: [codecLabel, codec])
        codecRow.orientation = .horizontal
        let packetLabel = NSTextField(labelWithString: "Sending packet size")
        packetLabel.widthAnchor.constraint(equalToConstant: 190).isActive = true
        packetSize.setAccessibilityLabel("Sending packet size")
        packetSize.setAccessibilityHelp("Standard sends PCM in 233-sample packets and broadcast Opus in 20-millisecond packets. Small uses 120 samples or 10 milliseconds on a stable local network, with more packets per second. Live Opus and custom mode keep their existing minimal sizes. Applies to input, system audio and DAW sends; saved in profiles.")
        for choice in SendPacketSize.allCases {
            packetSize.addItem(withTitle: choice.label)
            packetSize.lastItem?.representedObject = choice.rawValue
        }
        do { pushToTalkSettings = try PushToTalkPreferences.load(from: AppRuntime.settings) }
        catch {
            pushToTalkSettings = .init()
            pushToTalkSettingsUnreadable = true
            recordStartup("Saved push-to-talk settings are unreadable; using disabled defaults without overwriting them.")
        }
        let savedPacketSize = AppRuntime.settings.string(forKey: "sendPacketSize") ?? ""
        packetSize.selectItem(withTitle: (SendPacketSize(rawValue: savedPacketSize) ?? .standard).label)
        packetSize.target = self
        packetSize.action = #selector(audioOptionsChanged)
        let packetRow = NSStackView(views: [packetLabel, packetSize])
        packetRow.orientation = .horizontal
        selectedInputUIDs = AppRuntime.settings.stringArray(forKey: "inputDeviceUIDs")
            ?? [AppRuntime.settings.string(forKey: "inputDeviceUID") ?? ""]
        selectedInputChannelPairs = AppRuntime.settings.dictionary(
            forKey: "inputChannelPairs") as? [String: [Int]] ?? [:]
        selectedOutputUIDs = AppRuntime.settings.stringArray(forKey: "outputDeviceUIDs")
            ?? [AppRuntime.settings.string(forKey: "outputDeviceUID") ?? ""]
        selectedOutputChannelPairs = AppRuntime.settings.dictionary(
            forKey: "outputChannelPairs") as? [String: [Int]] ?? [:]
        selectedCaptureUIDs = AppRuntime.settings.array(forKey: "systemCaptureDeviceUIDs") as? [String]
        selectedCaptureChannelPairs = AppRuntime.settings.dictionary(
            forKey: "systemCaptureChannelPairs") as? [String: [Int]] ?? [:]
        if selectedCaptureUIDs == nil,
            let legacy = AppRuntime.settings.string(forKey: "systemCaptureDeviceUID"),
            !legacy.isEmpty { selectedCaptureUIDs = [legacy] }
        populateDeviceChoices(inputUIDs: selectedInputUIDs,
            outputUIDs: selectedOutputUIDs,
            systemCaptureUIDs: selectedCaptureUIDs)
        if selectedInputUIDs.isEmpty { send.state = .off }
        if selectedCaptureUIDs?.isEmpty == true { systemAudio.state = .off }
        if selectedOutputUIDs.isEmpty { monitor.state = .off }
        refreshDevices.target = self
        refreshDevices.action = #selector(refreshAudioDevices)
        uncheckAllDevices.target = self
        uncheckAllDevices.action = #selector(uncheckAllDevicesPressed)
        uncheckAllDevices.setAccessibilityLabel(uncheckAllDevices.title)
        uncheckAllDevices.setAccessibilityHelp("Untick every input, output and system-audio output at once. Sending and monitoring stop until you tick a device again.")
        let receiveHeading = NSTextField(labelWithString: "Audio receive parameters")
        let jitterLabel = NSTextField(labelWithString: "Audio jitter buffer in milliseconds")
        jitterLabel.widthAnchor.constraint(equalToConstant: 240).isActive = true
        receiveJitter.setAccessibilityLabel("Audio jitter buffer in milliseconds")
        receiveJitter.setAccessibilityHelp(
            "Receive-side buffer target for each peer stream. Lower values reduce delay but may click on an uneven network. Changes briefly rebuffer live streams.")
        for milliseconds in ReceiveBuffer.choicesMs {
            receiveJitter.addItem(withTitle: "\(milliseconds) milliseconds")
            receiveJitter.lastItem?.representedObject = milliseconds
        }
        let savedJitter = AppRuntime.settings.integer(forKey: "receiveJitterMs")
        let initialJitter = savedJitter == 0 ? ReceiveBuffer.legacyDefaultMs : savedJitter
        receiveJitter.selectItem(withTitle:
            "\(ReceiveBuffer.clamped(initialJitter)) milliseconds")
        receiveJitter.target = self
        receiveJitter.action = #selector(receiveJitterChanged)
        let jitterRow = NSStackView(views: [jitterLabel, receiveJitter])
        jitterRow.orientation = .horizontal
        let smoothnessLabel = NSTextField(labelWithString: "Buffer smoothness")
        smoothnessLabel.widthAnchor.constraint(equalToConstant: 240).isActive = true
        receiveSmoothness.setAccessibilityLabel("Buffer smoothness")
        receiveSmoothness.setAccessibilityHelp(
            "Controls excess receive-buffer trimming. One gives the tightest delay with frequent clicks; three is the default with brief clicks. Ten disables excess-buffer trimming and may allow longer delay. Clock correction, auto-tune and the safety cap stay active. Saved with this profile.")
        for level in BufferSmoothness.choices.reversed() {
            let detail = level == 10 ? "No excess-buffer trimming, longest delay"
                : level == 3 ? "Default, brief clicks" : level == 1 ? "Tightest delay, frequent clicks" : ""
            receiveSmoothness.addItem(withTitle: detail.isEmpty ? String(level) : "\(level): \(detail)")
            receiveSmoothness.lastItem?.representedObject = level
        }
        let initialSmoothness = AppRuntime.settings.object(forKey: "receiveSmoothness") == nil
            ? BufferSmoothness.defaultLevel : BufferSmoothness.clamped(AppRuntime.settings.integer(forKey: "receiveSmoothness"))
        selectReceiveSmoothness(initialSmoothness)
        receiveSmoothness.target = self
        receiveSmoothness.action = #selector(receiveSmoothnessChanged)
        let smoothnessRow = NSStackView(views: [smoothnessLabel, receiveSmoothness])
        smoothnessRow.orientation = .horizontal
        let artifactLabel = NSTextField(labelWithString: "Receive gap sound")
        artifactLabel.widthAnchor.constraint(equalToConstant: 240).isActive = true
        receiveArtifact.setAccessibilityLabel("Receive gap sound")
        receiveArtifact.setAccessibilityHelp(
            "Chooses the sound during a brief receive underrun. Noise burst is the default: a short noise cue on an empty read, followed by a fade when real audio returns. Click uses silence with no fade. Partial reads retain real audio. This does not repair lost packets or change the jitter target. Saved with this profile.")
        for choice in ConcealmentArtifact.allCases {
            receiveArtifact.addItem(withTitle: choice.label)
            receiveArtifact.lastItem?.representedObject = choice.rawValue
        }
        let initialArtifact = AppRuntime.settings.object(forKey: "receiveArtifact") == nil
            ? ConcealmentArtifact.defaultChoice : ConcealmentArtifact.migrated(AppRuntime.settings.integer(forKey: "receiveArtifact"))
        selectReceiveArtifact(initialArtifact)
        receiveArtifact.target = self
        receiveArtifact.action = #selector(receiveArtifactChanged)
        let artifactRow = NSStackView(views: [artifactLabel, receiveArtifact])
        artifactRow.orientation = .horizontal
        receiveAutoTune.state = AppRuntime.settings.bool(forKey: "receiveAutoTune")
            ? .on : .off
        receiveAutoTune.setAccessibilityHelp(
            "Windows' auto-tune. It measures what the network and this Mac need - the worst gaps between packets and between mixes, a lone spike ignored - and raises the buffer to that at once when it runs short. On a clean network it comes down on evidence, then a few milliseconds at a time, never back to a depth that ran short. Off, the buffer stays where you set it.")
        receiveAutoTune.target = self
        receiveAutoTune.action = #selector(receiveAutoTuneChanged)
        let autoIntervalLabel = NSTextField(labelWithString: "Auto-tune interval")
        autoIntervalLabel.widthAnchor.constraint(equalToConstant: 240).isActive = true
        receiveAutoTuneInterval.setAccessibilityLabel("Auto-tune interval")
        receiveAutoTuneInterval.setAccessibilityHelp(
            "How often the auto-tune decides: 3, 5, 10, 15, or 30 seconds. The lowest-delay auto-tune looks every second.")
        for seconds in ReceiveBuffer.autoTuneIntervals {
            receiveAutoTuneInterval.addItem(withTitle: "\(seconds) seconds")
            receiveAutoTuneInterval.lastItem?.representedObject = seconds
        }
        let savedInterval = ReceiveBuffer.validAutoTuneInterval(
            AppRuntime.settings.integer(forKey: "receiveAutoTuneInterval"))
        receiveAutoTuneInterval.selectItem(withTitle: "\(savedInterval) seconds")
        receiveAutoTuneInterval.target = self
        receiveAutoTuneInterval.action = #selector(receiveAutoTuneChanged)
        let autoIntervalRow = NSStackView(views: [autoIntervalLabel, receiveAutoTuneInterval])
        autoIntervalRow.orientation = .horizontal
        receiveLowestDelay.state = AppRuntime.settings.bool(forKey: "receiveLowestDelay") ? .on : .off
        receiveLowestDelay.setAccessibilityLabel(receiveLowestDelay.title)
        receiveLowestDelay.setAccessibilityHelp("With auto-tune on: runs the buffer as thin as it can, counting audible gaps - up a little after three in a second or four in twenty, down a millisecond after quiet seconds. Off, the usual auto-tune.")
        receiveLowestDelay.target = self
        receiveLowestDelay.action = #selector(receiveLowestDelayChanged)
        receiveLatencyStatus.isSelectable = true
        selfMonitoringButton.target = self
        selfMonitoringButton.action = #selector(toggleSelfMonitoring)
        selfMonitoringButton.setAccessibilityHelp("Hear your own sent audio after its round trip through the connected server. Use headphones and avoid capturing RemSound's output. Press again to mute yourself. The test turns off if no audio returns for five seconds, and when you leave the server.")
        selfMonitoringStatus.isSelectable = true
        selfMonitoringStatus.setAccessibilityLabel(selfMonitoringStatus.stringValue)
        refreshReceiveLatencyStatus()
        let listeningLabel = NSTextField(labelWithString: "Master volume for received audio")
        listeningLabel.widthAnchor.constraint(equalToConstant: 240).isActive = true
        listeningVolume.setAccessibilityLabel("Master volume for received audio")
        listeningVolume.setAccessibilityHelp(
            "How loud peers play through this Mac's outputs, from zero to one hundred percent. Use arrow keys to adjust; Return resets to one hundred percent. Recordings of received audio follow it; DAW plugins and the metronome do not. A peer can move it only if Accept remote volume commands from peers is on in Preferences.")
        listeningVolume.integerValue = AppRuntime.settings.object(forKey: "listeningVolume") == nil
            ? 100 : AppRuntime.settings.integer(forKey: "listeningVolume")
        listeningVolume.target = self
        listeningVolume.action = #selector(listeningChanged)
        listeningVolume.logReset = { [weak self] previous, value in
            self?.session.note("Master received volume: Return reset \(previous) to \(value) percent.")
        }
        listeningVolume.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let listeningRow = NSStackView(views: [listeningLabel, listeningVolume])
        listeningRow.orientation = .horizontal
        receiveMute.state = AppRuntime.settings.bool(forKey: "receiveMuted") ? .on : .off
        receiveMute.setAccessibilityHelp(
            "Silences received audio on this Mac's outputs without stopping it; DAW plugins still receive. A peer can switch it only if Accept remote volume commands from peers is on in Preferences.")
        receiveMute.target = self
        receiveMute.action = #selector(listeningChanged)
        for view in [codecRow, packetRow, send, inputHeading, inputScroll, pairHeading, pairScroll,
            systemAudio, systemModeRow, captureHeading, captureScroll, capturePairHeading, capturePairScroll,
            activeAppsHeading, activeAppsScroll, rememberedAppsHeading, rememberedAppsScroll,
            receive, receiveHeading, jitterRow, smoothnessRow, artifactRow, receiveAutoTune, autoIntervalRow, receiveLowestDelay,
            receiveLatencyStatus, selfMonitoringButton, selfMonitoringStatus, monitor, listeningRow, receiveMute, outputHeading, outputScroll, outputPairHeading,
            outputPairScroll, plugins, refreshDevices, uncheckAllDevices] as [NSView] {
            stack.addArrangedSubview(view)
        }
        showSystemAudioMode()
        for view in [codecRow, packetRow, inputScroll, pairScroll, captureScroll, capturePairScroll, activeAppsScroll, rememberedAppsScroll,
            jitterRow, smoothnessRow, artifactRow, autoIntervalRow, receiveLatencyStatus, selfMonitoringStatus, outputScroll,
            outputPairScroll] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack = profileStack
        stack.addArrangedSubview(profileIntro)
        profileIntro.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let recordingLabel = NSTextField(labelWithString: "Recording source")
        recordingLabel.widthAnchor.constraint(equalToConstant: 190).isActive = true
        recordingSource.setAccessibilityLabel("Recording source")
        recordingSource.setAccessibilityHelp("Choose sent, received, or both audio directions for the next recording.")
        for source in RecordingSource.allCases {
            recordingSource.addItem(withTitle: source.label)
            recordingSource.lastItem?.representedObject = source.rawValue
        }
        let savedRecordingSource = RecordingSource(rawValue:
            AppRuntime.settings.string(forKey: "recordingSource") ?? "") ?? .both
        recordingSource.selectItem(withTitle: savedRecordingSource.label)
        recordingSource.target = self
        recordingSource.action = #selector(recordingSourceChanged)
        let recordingRow = NSStackView(views: [recordingLabel, recordingSource])
        recordingRow.orientation = .horizontal
        stack.addArrangedSubview(recordingRow)
        recordingRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let formatLabel = NSTextField(labelWithString: "Recording format")
        formatLabel.widthAnchor.constraint(equalToConstant: 190).isActive = true
        recordingFormat.setAccessibilityLabel("Recording format")
        recordingFormat.setAccessibilityHelp("Choose 48 kHz WAV, lossless FLAC, MP3 at 128, 192, 256 or 320 kbps, or Ogg Opus at 96, 128, 192 or 256 kbps for the next recording. MP3 uses constant bitrate; 320 kbps is Windows’ usual choice.")
        for choice in RecordingFormat.allCases {
            recordingFormat.addItem(withTitle: choice.label)
            recordingFormat.lastItem?.representedObject = choice.rawValue
        }
        let savedFormat = RecordingFormat(rawValue:
            AppRuntime.settings.string(forKey: "recordingFormat") ?? "") ?? .wav24
        recordingFormat.selectItem(withTitle: savedFormat.label)
        recordingFormat.target = self
        recordingFormat.action = #selector(recordingSourceChanged)
        let formatRow = NSStackView(views: [formatLabel, recordingFormat])
        formatRow.orientation = .horizontal
        stack.addArrangedSubview(formatRow)
        formatRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let compressionLabel = NSTextField(labelWithString: "FLAC compression")
        compressionLabel.widthAnchor.constraint(equalToConstant: 190).isActive = true
        flacCompression.setAccessibilityLabel("FLAC compression")
        flacCompression.setAccessibilityHelp("For FLAC recordings: 0 is fastest, 8 makes smaller files, and 5 is the default. All levels are lossless; 16- or 24-bit depth is chosen separately in Recording format. Saved in the profile; takes effect on the next recording.")
        for level in 0...FLACCompression.maximumLevel {
            let suffix = level == 0 ? " — fastest" : level == 5 ? " — default" : level == 8 ? " — smallest" : ""
            flacCompression.addItem(withTitle: "\(level)\(suffix)")
            flacCompression.lastItem?.representedObject = level
        }
        let savedCompression = AppRuntime.settings.object(forKey: "flacCompression") as? Int ?? FLACCompression.defaultLevel
        flacCompression.selectItem(at: FLACCompression.clamped(savedCompression))
        flacCompression.isEnabled = savedFormat.fileExtension == "flac"
        flacCompression.target = self
        flacCompression.action = #selector(recordingSourceChanged)
        let compressionRow = NSStackView(views: [compressionLabel, flacCompression])
        compressionRow.orientation = .horizontal
        stack.addArrangedSubview(compressionRow)
        compressionRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let channelsLabel = NSTextField(labelWithString: "Recording channels")
        channelsLabel.widthAnchor.constraint(equalToConstant: 190).isActive = true
        recordingChannels.setAccessibilityLabel("Recording channels")
        recordingChannels.setAccessibilityHelp("Stereo keeps left and right separate. Mono mixes left and right equally into one channel.")
        for choice in RecordingChannels.allCases {
            recordingChannels.addItem(withTitle: choice.label)
            recordingChannels.lastItem?.representedObject = choice.rawValue
        }
        let savedChannels = RecordingChannels(rawValue:
            AppRuntime.settings.string(forKey: "recordingChannels") ?? "") ?? .stereo
        recordingChannels.selectItem(withTitle: savedChannels.label)
        recordingChannels.target = self
        recordingChannels.action = #selector(recordingSourceChanged)
        let channelsRow = NSStackView(views: [channelsLabel, recordingChannels])
        channelsRow.orientation = .horizontal
        stack.addArrangedSubview(channelsRow)
        channelsRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        splitRecording.state = AppRuntime.settings.bool(forKey: "splitRecording") ? .on : .off
        splitRecording.setAccessibilityHelp("Make a folder with one file for each currently selected peer and a separate local send file. New peers after recording starts are not added.")
        splitRecording.target = self
        splitRecording.action = #selector(recordingSourceChanged)
        stack.addArrangedSubview(splitRecording)
        recordingBypassShaping.state = AppRuntime.settings.bool(forKey: "recordingBypassShaping") ? .on : .off
        recordingBypassShaping.setAccessibilityHelp("Record received audio before peer volume, pan and EQ, and before mixed listening volume or mute. Live listening and DAW audio keep their shaping. Applies to mixed and split files; changes take effect on the next recording. Saved in the current profile.")
        recordingBypassShaping.target = self
        recordingBypassShaping.action = #selector(recordingBypassChanged)
        stack.addArrangedSubview(recordingBypassShaping)
        recordingButton.setAccessibilityHelp("Command-E. Start or stop a 48 kHz recording in your chosen recordings folder.")
        recordingButton.target = self
        recordingButton.action = #selector(toggleRecording)
        stack.addArrangedSubview(recordingButton)
        recordingsFolderButton.target = self
        recordingsFolderButton.action = #selector(changeRecordingsFolder)
        stack.addArrangedSubview(recordingsFolderButton)
        openProfileButton.target = self; openProfileButton.action = #selector(openProfile)
        saveProfileButton.target = self; saveProfileButton.action = #selector(saveProfile)
        saveAsProfileButton.target = self; saveAsProfileButton.action = #selector(saveProfileAs)
        profileNotice.isSelectable = true
        profileNotice.setAccessibilityLabel("Profile status")
        stack.addArrangedSubview(profileNotice)
        profileNotice.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let profileActions = NSStackView(views: [openProfileButton, saveProfileButton,
            saveAsProfileButton])
        profileActions.orientation = .horizontal
        stack.addArrangedSubview(profileActions)
        stack = connectivityStack
        start.target = self
        start.action = #selector(startSession)
        start.setAccessibilityHelp("Start the current profile's audio and networking, restoring its selected peers. Server Connect also starts RemSound if needed.")
        start.keyEquivalent = "\r"
        stop.target = self
        stop.action = #selector(stopSession)
        stop.setAccessibilityHelp("Stop audio and networking, including ordinary peer and server connections. Server Disconnect leaves only the server.")
        stop.keyEquivalent = "."
        stop.keyEquivalentModifierMask = .command
        stop.isEnabled = false
        let actions = NSStackView(views: [start, stop])
        stack.addArrangedSubview(actions)
        let heading = NSTextField(labelWithString: "Peers — arrows move; Space selects or deselects")
        stack.addArrangedSubview(heading)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("peer"))
        column.title = "Peer, selection, connection"
        column.width = 700
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Peers")
        table.setAccessibilityHelp(
            "Use arrow keys to hear peers. Space selects or deselects the highlighted peer. F2 renames it; a context menu also offers Rename Peer.")
        table.toggle = { [weak self] in self?.togglePeer() }
        table.rename = { [weak self] in self?.renameHighlightedPeer() }
        let peerMenu = NSMenu(title: "Peer")
        peerMenu.addItem(withTitle: "Rename Peer…",
            action: #selector(renameHighlightedPeer), keyEquivalent: "").target = self
        peerMenu.addItem(withTitle: "Manage Named Peers…", action: #selector(showNamedPeers), keyEquivalent: "").target = self
        table.peerMenu = peerMenu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        toggle.target = self
        toggle.action = #selector(togglePeer)
        toggle.keyEquivalent = "t"
        toggle.keyEquivalentModifierMask = .command
        stack.addArrangedSubview(toggle)
        let peerDetailsLabel = NSTextField(labelWithString: "Peer details")
        peerDetailsLabel.identifier = NSUserInterfaceItemIdentifier("help-main-peerdetails")
        peerDetails.isSelectable = true
        peerDetails.setAccessibilityLabel("Peer details")
        peerDetails.setAccessibilityHelp("What is known about the highlighted peer: its name, address, how long it has been connected, the link, what it sends and whether it hears you.")
        stack.addArrangedSubview(peerDetailsLabel)
        stack.addArrangedSubview(peerDetails)
        peerDetails.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let connectionStatusLabel = NSTextField(labelWithString: "Connection status")
        connectionStatusLabel.identifier = NSUserInterfaceItemIdentifier("help-main-connectionstatus")
        connectionStatus.isSelectable = true
        connectionStatus.setAccessibilityLabel("Connection status")
        connectionStatus.setAccessibilityHelp("Who you are connected to and how, for how long, the traffic in and out, and RemSound's CPU and memory. The speak status key reads it.")
        stack.addArrangedSubview(connectionStatusLabel)
        stack.addArrangedSubview(connectionStatus)
        connectionStatus.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        peerDetailsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPeerDetails()
                self?.refreshConnectionStatus()
                self?.logBrowsers()
                self?.syncPluginLogMarker()
                if self?.window.isVisible == true { self?.refreshReceiveLatencyStatus() }
            }
        }
        connectivityPeers.onAdd = { [weak self] entry, reply in
            guard let self else { reply(.notRunning); return }
            self.session.addPeer(entry, completion: reply)
        }
        connectivityPeers.onCancel = { [weak self] in self?.session.cancelAddingPeer() }
        connectivityPeers.onForget = { [weak self] entry, reply in
            guard let self else { reply(false); return }
            self.session.forgetRememberedPeer(entry, completion: reply)
        }
        connectivityPeers.onClear = { [weak self] reply in
            guard let self else { reply(false); return }
            self.session.clearRememberedPeers(completion: reply)
        }
        connectivityPeers.onLock = { [weak self] locked in
            guard let self else { return }
            if PeerAddressLockChoice.save(locked, settings: AppRuntime.settings) {
                self.session.setLockPeerAddresses(locked)
            } else {
                self.connectivityPeers.refresh(entries: self.rememberedPeerEntries, running: self.running,
                    locked: AppRuntime.settings.bool(forKey: "lockPeerAddresses"))
                self.announce("Could not save the peer address-lock choice.")
            }
        }
        connectivityPeers.onNotice = { [weak self] message in self?.announce(message) }
        rememberedPeerEntries = RememberedPeerPreferences(settings: AppRuntime.settings).entries
        connectivityPeers.refresh(entries: rememberedPeerEntries, running: false,
            locked: AppRuntime.settings.bool(forKey: "lockPeerAddresses"))
        stack.addArrangedSubview(connectivityPeers.view)
        connectivityPeers.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if let routerControls {
            stack.addArrangedSubview(routerControls.view)
            routerControls.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        // Exercise the exact Root/window adapter only in disposable fixtures until
        // saved-profile removal also joins dedicated browser credential cleanup.
        do {
            browserListenerButton.target=self;browserListenerButton.action = #selector(showBrowserListener)
            browserListenerButton.setAccessibilityLabel("Browser listener")
            browserListenerButton.setAccessibilityHelp("Edit browser listening for this profile. Choices may be staged without starting a listener. The browser password is separate from the audio connection password.")
            stack.addArrangedSubview(browserListenerButton)
        }
        stack = mixStack
        allPeerShaping.state = (AppRuntime.settings.object(forKey: "enableAllPeerShaping") == nil
            ? PeerMix.masterSwitchForOldProfile(peerMixes)
            : AppRuntime.settings.bool(forKey: "enableAllPeerShaping")) ? .on : .off
        allPeerShaping.setAccessibilityHelp(
            "Off by default. When on, each peer's volume, pan and EQ below are heard, for every peer whose own Shape selected peer box is checked. When off, everyone plays untouched and the settings are kept.")
        allPeerShaping.target = self
        allPeerShaping.action = #selector(allPeerShapingChanged)
        stack.addArrangedSubview(allPeerShaping)
        let mixPeerLabel = NSTextField(labelWithString: "Peer to shape")
        mixPeer.setAccessibilityLabel("Peer to shape")
        mixPeer.setAccessibilityHelp(
            "Choose a peer for volume, pan and equalizer. This follows the highlighted peer in Connectivity.")
        mixPeer.target = self
        mixPeer.action = #selector(mixPeerChanged)
        let mixPeerRow = NSStackView(views: [mixPeerLabel, mixPeer])
        mixPeerRow.orientation = .horizontal
        mixPeerLabel.widthAnchor.constraint(equalToConstant: 140).isActive = true
        stack.addArrangedSubview(mixPeerRow)
        peerMixEnabled.setAccessibilityHelp("Shape this peer: its volume, pan and EQ are heard while Enable volume, pan and EQ for all peers is on. Unchecked, it plays untouched and keeps its settings. Saved in the current profile.")
        peerMixEnabled.target = self
        peerMixEnabled.action = #selector(peerMixChanged)
        peerVolume.setAccessibilityHelp("Volume for the highlighted peer, from zero to one hundred percent. Use arrow keys to adjust; Return resets to one hundred percent.")
        peerVolume.target = self
        peerVolume.action = #selector(peerMixChanged)
        peerVolume.logReset = { [weak self] previous, value in
            self?.session.note("Selected peer volume: Return reset \(previous) to \(value) percent.")
        }
        peerPan.setAccessibilityHelp("Pan for the highlighted peer, from full left through centre to full right. Use arrow keys to adjust; Return resets to centre.")
        peerPan.target = self
        peerPan.action = #selector(peerMixChanged)
        peerPan.logReset = { [weak self] previous, value in
            self?.session.note("Selected peer pan: Return reset \(previous) to \(value).")
        }
        let peerMixRow = NSStackView(views: [peerMixEnabled, peerVolume, peerPan])
        peerMixRow.orientation = .horizontal
        peerMixRow.spacing = 12
        peerVolume.widthAnchor.constraint(equalToConstant: 140).isActive = true
        peerPan.widthAnchor.constraint(equalToConstant: 140).isActive = true
        stack.addArrangedSubview(peerMixRow)
        let eqModeLabel = NSTextField(labelWithString: "EQ mode")
        eqModeLabel.widthAnchor.constraint(equalToConstant: 140).isActive = true
        eqMode.setAccessibilityLabel("EQ mode")
        eqMode.setAccessibilityHelp("Each EQ keeps its own settings; only the one chosen here is heard for this peer.")
        for mode in PeerEqMode.allCases {
            eqMode.addItem(withTitle: mode.title)
            eqMode.lastItem?.representedObject = mode.rawValue
        }
        eqMode.target = self
        eqMode.action = #selector(eqModeChanged)
        let eqModeRow = NSStackView(views: [eqModeLabel, eqMode])
        eqModeRow.orientation = .horizontal
        stack.addArrangedSubview(eqModeRow)
        for (label, slider) in zip(eqBandLabels, eqBandSliders) {
            slider.target = self
            slider.action = #selector(eqBandChanged(_:))
            slider.logReset = { [weak self, weak slider] previous, value in
                self?.session.note("\(slider?.accessibilityLabel() ?? "EQ band"): Return reset \(previous) to \(value).")
            }
            slider.numberOfTickMarks = 5
            slider.setAccessibilityLabel("EQ band")   // named for its band when shown (describeBand)
            slider.setAccessibilityHelp("From minus 12 decibels through flat in the middle to plus 12, for the highlighted peer. Use arrow keys to adjust; Return resets to flat.")
            slider.widthAnchor.constraint(equalToConstant: 300).isActive = true
            label.widthAnchor.constraint(equalToConstant: 140).isActive = true
            let row = NSStackView(views: [label, slider])
            row.orientation = .horizontal
            eqBandRows.append(row)
            stack.addArrangedSubview(row)
        }
        addBandButton.setAccessibilityHelp("Add a boost or cut across a range of frequencies, up to 16 bands. You hear it as you type.")
        addBandButton.target = self
        addBandButton.action = #selector(addBandPressed)
        bandList.setAccessibilityLabel("Bands, left and right arrow change the selected band's gain")
        bandList.setAccessibilityHelp("Bass to treble. Left and Right move the selected bands half a decibel; Delete removes them.")
        bandList.nudge = { [weak self] indices, step in self?.nudgeBands(indices, by: step) }
        bandList.delete = { [weak self] indices in self?.deleteBands(indices) }
        bandListScroll.documentView = bandList
        bandListScroll.hasVerticalScroller = true
        bandListScroll.borderType = .bezelBorder
        bandListScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        bandListScroll.widthAnchor.constraint(equalToConstant: 440).isActive = true
        deleteBandButton.setAccessibilityHelp("Remove the bands selected in the list.")
        deleteBandButton.target = self
        deleteBandButton.action = #selector(deleteBandPressed)
        for view in [addBandButton, bandsLabel, bandListScroll, deleteBandButton] as [NSView] { stack.addArrangedSubview(view) }
        resetPeerEq.setAccessibilityHelp("Flatten all three EQs for the highlighted peer, including its parametric bands. Volume and pan are kept.")
        resetPeerEq.target = self
        resetPeerEq.action = #selector(resetPeerEqPressed)
        stack.addArrangedSubview(resetPeerEq)
        updatePeerMixControls()
        func addTab(_ title: String, _ section: NSStackView) {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            let content = NSView()
            content.setAccessibilityElement(true)
            content.setAccessibilityRole(.group)
            content.setAccessibilityLabel("\(title) controls")
            section.setAccessibilityElement(true)
            section.setAccessibilityRole(.group)
            section.setAccessibilityLabel("\(title) settings")
            if title == "Connectivity" || title == "Audio I/O" || title == "Recording / Profiles" || title == "Pan / EQ" {
                let scroll = NSScrollView()
                scroll.translatesAutoresizingMaskIntoConstraints = false
                scroll.hasVerticalScroller = true
                scroll.setAccessibilityLabel("\(title) settings")
                scroll.documentView = section
                content.addSubview(scroll)
                NSLayoutConstraint.activate([
                    scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                    scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                    scroll.topAnchor.constraint(equalTo: content.topAnchor),
                    scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                    section.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor,
                        constant: 12),
                    section.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor,
                        constant: -24),
                    section.topAnchor.constraint(equalTo: scroll.contentView.topAnchor,
                        constant: 12),
                    section.heightAnchor.constraint(greaterThanOrEqualTo:
                        scroll.contentView.heightAnchor, constant: -24),
                ])
            } else {
                content.addSubview(section)
                NSLayoutConstraint.activate([
                    section.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                    section.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                    section.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
                    section.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -12),
                ])
            }
            item.view = content
            tabs.addTabViewItem(item)
        }
        tabs.setAccessibilityLabel("RemSound sections")
        tabs.setAccessibilityHelp("Tab enters the selected section. Left and Right arrows change sections; Control-Tab and Control-Shift-Tab change them from anywhere in the window.")
        addTab("Connectivity", connectivityStack)
        pushToTalkButton.target = self
        pushToTalkButton.action = #selector(showPushToTalkSettings)
        refreshPushToTalkPresentation()
        pushToTalkButton.setAccessibilityHelp("Edit this profile's push to talk and the separate machine shortcut key. OK applies; Cancel discards.")
        audioStack.addArrangedSubview(pushToTalkButton)
        let metronomeLabel = NSTextField(labelWithString: "Metronome volume")
        metronomeLabel.widthAnchor.constraint(equalToConstant: 240).isActive = true
        metronomeVolume.widthAnchor.constraint(equalToConstant: 200).isActive = true
        metronomeVolume.target = self
        metronomeVolume.action = #selector(metronomeVolumeChanged)
        metronomeVolume.setAccessibilityHelp("Local metronome click volume from zero to one hundred percent. Use arrow keys to adjust; Return resets to seventy percent. This profile remembers it. Received audio volume, cue mute and other people's clicks are independent.")
        metronomeVolume.logReset = { [weak self] previous, value in
            self?.session.note("Metronome volume: Return reset \(previous) to \(value) percent.")
        }
        jam.volumeChanged = { [weak self] in self?.refreshMetronomeVolume() }
        jam.metronomeKeys = { [weak self] in self?.metronomeKeyBindings() ?? [] }
        jam.keepMetronomeKeys = { [weak self] keys in self?.keepMetronomeKeys(keys) }
        refreshMetronomeVolume()
        let metronomeRow = NSStackView(views: [metronomeLabel, metronomeVolume])
        metronomeRow.orientation = .horizontal
        audioStack.addArrangedSubview(metronomeRow)
        addTab("Audio I/O", audioStack)
        addTab("Recording / Profiles", profileStack)
        addTab("Pan / EQ", mixStack)
        root.addArrangedSubview(tabs)
        tabs.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
        status.isSelectable = true
        status.setAccessibilityLabel("Connection status")
        root.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        bindMainContextHelp()
        window.contextHelp = { [weak self, weak owner = window] manual in
            guard let owner else { return }
            self?.contextHelpAction(manual, owner)
        }
        jam.contextHelp = contextHelpAction
        jam.alertHelpDelegate = self
        if nativeProductFixture {
            configurePreferencesWindow()
            return
        }
        loadPushToTalkMachineKey()
        configurePushToTalkInput()
        configurePreferencesWindow()
        installPushToTalkCaptureObservers()
        pushToTalkInput?.setReservedBindings(Array(hotkeyBindings.values))
        updates.onPrepared = { [weak self] stage, version, helper in
            guard let self else { return }
            self.pendingUpdate = (stage, version, helper)
            self.scheduleTermination()
        }
        configureAutoSaveTimer()
        let audioTabOrder: [NSView] = [codec, packetSize, send, inputTable, inputPairTable,
            systemAudio, systemAudioMode, systemOutputTable, systemOutputPairTable, activeAppsTable, rememberedAppsTable, receive,
            receiveJitter, receiveSmoothness, receiveArtifact, receiveAutoTune, receiveAutoTuneInterval, receiveLowestDelay,
            receiveLatencyStatus, selfMonitoringButton, selfMonitoringStatus, monitor, listeningVolume, receiveMute, outputTable, outputPairTable, plugins,
            refreshDevices, uncheckAllDevices, pushToTalkButton, metronomeVolume]
        let controlGroups: [[NSView]] = [
            ([name, peer, password, start, stop, table, peerDetails, toggle, connectionStatus] as [NSView]) + connectivityPeers.keyViews + (routerControls?.keyViews ?? []) + (browserListenerButton.superview == nil ? []:[browserListenerButton]),
            audioTabOrder,
            [recordingSource, recordingFormat, flacCompression, recordingChannels,
                splitRecording, recordingBypassShaping, recordingButton,
                recordingsFolderButton, openProfileButton, saveProfileButton,
                saveAsProfileButton],
            ([allPeerShaping, mixPeer, peerMixEnabled, peerVolume, peerPan, eqMode] as [NSView]) + (eqBandSliders as [NSView])
                + ([addBandButton, bandList, deleteBandButton, resetPeerEq] as [NSView]),
            [remember, reconnect, loginAtStartup],
        ]
        inputTable.tabForward = { [weak self] in
            guard let self else { return }
            self.window.makeFirstResponder(self.inputPairTable)
        }
        inputTable.tabBackward = { [weak self] in
            guard let self else { return }
            self.window.makeFirstResponder(self.send)
        }
        outputPairTable.tabForward = { [weak self] in
            guard let self else { return }
            self.window.makeFirstResponder(self.plugins)
        }
        outputPairTable.tabBackward = { [weak self] in
            guard let self else { return }
            self.window.makeFirstResponder(self.outputTable)
        }
        inputPairTable.tabForward = { [weak self] in
            guard let self else { return }
            self.window.makeFirstResponder(self.systemAudio)
        }
        inputPairTable.tabBackward = { [weak self] in
            guard let self else { return }
            self.window.makeFirstResponder(self.inputTable)
        }
        outputTable.tabForward = { [weak self] in
            guard let self else { return }
            self.window.makeFirstResponder(self.outputPairTable)
        }
        outputTable.tabBackward = { [weak self] in
            guard let self else { return }
            self.window.makeFirstResponder(self.receiveMute)
        }
        systemOutputTable.tabForward = { [weak self] in
            guard let self else { return }
            self.window.makeFirstResponder(self.systemOutputPairTable)
        }
        systemOutputTable.tabBackward = { [weak self] in
            guard let self else { return }
            self.window.makeFirstResponder(self.systemAudio)
        }
        systemOutputPairTable.tabForward = { [weak self] in
            guard let self else { return }
            self.window.makeFirstResponder(self.receive)
        }
        systemOutputPairTable.tabBackward = { [weak self] in
            guard let self else { return }
            self.window.makeFirstResponder(self.systemOutputTable)
        }
        tabFirstControls = [name, codec, recordingSource, allPeerShaping]
        mainTabItems = tabs.tabViewItems
        for (groupIndex, controls) in controlGroups.enumerated() {
            for (i, view) in controls.enumerated() {
                view.nextKeyView = i == controls.count - 1 && groupIndex < 4
                    ? status : controls[(i + 1) % controls.count]
            }
            if groupIndex < tabs.tabViewItems.count {
                tabs.tabViewItems[groupIndex].view?.nextKeyView = controls.first
            }
        }
        status.nextKeyView = tabs
        window.moveTabFocus = { [weak self] backwards in
            guard let self, let selected = self.tabs.selectedTabViewItem,
                let tabIndex = self.tabs.tabViewItems.firstIndex(of: selected),
                tabIndex < self.tabs.tabViewItems.count else { return false }
            // Hidden controls too are passed over: the EQ shows three sliders, twelve, or the parametric list.
            let tabOrder = controlGroups[tabIndex].filter {
                ($0 as? NSControl)?.isEnabled != false && !$0.isHiddenOrHasHiddenAncestor
            }
            guard !tabOrder.isEmpty else { return false }
            let next: NSView
            if hasKeyboardFocus(self.tabs, in: self.window)
                || self.window.firstResponder === self.window {
                next = backwards ? tabOrder[tabOrder.count - 1] : tabOrder[0]
            } else if hasKeyboardFocus(self.status, in: self.window) {
                next = backwards ? tabOrder[tabOrder.count - 1] : self.tabs
            } else if let index = tabOrder.firstIndex(where: {
                hasKeyboardFocus($0, in: self.window)
            }) {
                next = backwards
                    ? (index == 0 ? self.tabs : tabOrder[index - 1])
                    : (index == tabOrder.count - 1 ? self.tabs : tabOrder[index + 1])
            } else {
                return false
            }
            return self.window.makeFirstResponder(next)
        }
        tabs.delegate = self
        window.initialFirstResponder = password
        pushToTalkKeys.sendTalking = { [weak self] talking, generation in
            self?.session.setPushToTalkKeyTalking(talking, generation: generation)
        }
        pushToTalkKeys.onTransition = { [weak self] talking in
            self?.playPushToTalkCue(talking ? .pushToTalkOn : .pushToTalkOff)
        }
        session.onChange = { [weak self] view in self?.update(view) }
        session.onPasswordMismatch = { [weak self] address in self?.warnDifferentPassword(address) }
        session.onDirectPeerMove = { [weak self] old, new in self?.directPeerMoved(from: old, to: new) }
        session.onListeningChange = { [weak self] volume, muted in self?.listeningChangedByPeer(volume: volume, muted: muted) }
        session.setListening(volume: listeningVolume.integerValue, muted: receiveMute.state == .on)
        session.setAcceptRemoteCommands(acceptRemoteVolume.state == .on)
        session.setAllPeerShaping(allPeerShaping.state == .on)
        applyBrowserSafeApplications(sendingApplications ? chosenApplications : nil)
        jam.attach(session: session)
        jam.connectionNoticeLog = { [weak self] text in self?.recordStartup(text) }
        jam.selfMonitoringChanged = { [weak self] on, message in
            guard let self else { return }
            self.selfMonitoringButton.title = on ? "Mute myself" : "Unmute myself to test round trip"
            self.selfMonitoringStatus.stringValue = message
            self.selfMonitoringStatus.setAccessibilityLabel(message)
        }
        jam.connectUsingProfile = { [weak self] entry in self?.beginSessionFromProfile(serverAddress: entry) }
        jam.guiShown = { [weak self] in self?.refreshTypingFeedback() }
        if accessibilityCheck {
            var failures = [String]()
            failures.append(contentsOf: jam.serverAccessibilityFailures())
            let menu = NSApp.mainMenu ?? NSMenu()
            func submenu(_ title: String) -> NSMenu {
                menu.items.first(where: { $0.title == title })?.submenu ?? NSMenu()
            }
            let helpMenu = submenu("Help")
            let focusedHelp = helpMenu.items.first { $0.title == "Help for Focused Control" }
            let manual = helpMenu.items.first { $0.title == "Open RemSound Manual" }
            if focusedHelp?.keyEquivalent != String(UnicodeScalar(NSF1FunctionKey)!)
                || focusedHelp?.keyEquivalentModifierMask != [] {
                failures.append("Focused context help must expose F1 in the standard Help menu")
            }
            if manual?.keyEquivalent != String(UnicodeScalar(NSF1FunctionKey)!)
                || manual?.keyEquivalentModifierMask != .shift {
                failures.append("The external manual must expose Shift-F1 separately from context help")
            }
            let quickSwitch = submenu("Profiles").items.first { $0.title == "Quick Profile Switch…" }
            if quickSwitch?.keyEquivalent != "p"
                || quickSwitch?.keyEquivalentModifierMask != [.command, .shift] {
                failures.append("Quick Profile Switch must expose Command-Shift-P in the standard Profiles menu")
            }
            if !GlobalHotkeyAction.allCases.contains(where: { $0.settingKey == "quickProfileSwitch" }) {
                failures.append("Quick Profile Switch must have its own optional global action")
            }
            if !generalPreferencesOrder.contains(where: { $0.accessibilityLabel() == "Quick profile switch global hotkey" }) {
                failures.append("Preferences must expose the named Quick profile switch shortcut control")
            }
            let appMenu = submenu("RemSound")
            let viewMenu = submenu("View")
            let profileMenu = submenu("Profiles")
            let recordMenu = submenu("Record")
            let connectItem = submenu("Server").items.first(where: { $0.title == jam.serverMenuTitle })
            if connectItem?.keyEquivalent != "k" || connectItem?.keyEquivalentModifierMask != .command {
                failures.append("Connect to Server must expose Command-K in the native menu")
            }
            if menu.items.map(\.title) != ["RemSound", "Edit", "View", "Profiles",
                "Record", "Server", "Jamming", "Metronome", "Window", "Help"] {
                failures.append("SwiftUI main menu must expose standard named sections")
            }
            if tabs.tabViewItems.map(\.label) != ["Connectivity", "Audio I/O",
                "Recording / Profiles", "Pan / EQ"] {
                failures.append("Main tabs must match the Windows section order")
            }
            if !tabs.acceptsFirstResponder || !tabs.canBecomeKeyView {
                failures.append("The tab strip must accept keyboard focus")
            }
            for (index, firstControl) in tabFirstControls.enumerated() {
                tabs.selectTabViewItem(at: index)
                if tabs.nextValidKeyView !== firstControl {
                    failures.append("Tab from the tab strip must enter \(tabs.tabViewItems[index].label)")
                }
            }
            if let tab = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                isARepeat: false, keyCode: 48) {
                if let shiftTab = NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: .shift, timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                    isARepeat: false, keyCode: 48) {
                    for (index, controls) in controlGroups.prefix(4).enumerated() {
                        tabs.selectTabViewItem(at: index)
                        let enabled = controls.filter {
                            ($0 as? NSControl)?.isEnabled != false && !$0.isHiddenOrHasHiddenAncestor
                        }
                        if enabled.isEmpty { continue }
                        window.makeFirstResponder(tabs)
                        for expected in enabled + [tabs] {
                            window.sendEvent(tab)
                            if !hasKeyboardFocus(expected, in: window) {
                                failures.append("\(tabs.tabViewItems[index].label) Tab skips \(expected.accessibilityLabel() ?? String(describing: expected))")
                                break
                            }
                        }
                        window.makeFirstResponder(tabs)
                        for expected in Array(enabled.reversed()) + [tabs] {
                            window.sendEvent(shiftTab)
                            if !hasKeyboardFocus(expected, in: window) {
                                failures.append("\(tabs.tabViewItems[index].label) Shift-Tab skips \(expected.accessibilityLabel() ?? String(describing: expected))")
                                break
                            }
                        }
                        window.makeFirstResponder(nil)
                        window.sendEvent(tab)
                        if !hasKeyboardFocus(enabled[0], in: window) {
                            failures.append("\(tabs.tabViewItems[index].label) Tab cannot recover from window focus")
                        }
                        window.makeFirstResponder(nil)
                        window.sendEvent(shiftTab)
                        if !hasKeyboardFocus(enabled[enabled.count - 1], in: window) {
                            failures.append("\(tabs.tabViewItems[index].label) Shift-Tab cannot recover from window focus")
                        }
                        if !enabled.isEmpty && enabled.count < controls.count {
                            window.makeFirstResponder(tabs)
                            window.sendEvent(shiftTab)
                            if !hasKeyboardFocus(enabled[enabled.count - 1], in: window) {
                                failures.append("\(tabs.tabViewItems[index].label) Shift-Tab lands on a disabled control")
                            }
                        }
                    }
                    let previousConnectivityEnabled = [name.isEnabled, peer.isEnabled,
                        password.isEnabled, start.isEnabled, stop.isEnabled]
                    name.isEnabled = false
                    peer.isEnabled = false
                    password.isEnabled = false
                    start.isEnabled = false
                    stop.isEnabled = true
                    tabs.selectTabViewItem(at: 0)
                    let runningOrder = controlGroups[0].filter {
                        ($0 as? NSControl)?.isEnabled != false
                    }
                    window.makeFirstResponder(tabs)
                    for expected in runningOrder + [tabs] {
                        window.sendEvent(tab)
                        if !hasKeyboardFocus(expected, in: window) {
                            failures.append("Running Connectivity Tab skips \(expected.accessibilityLabel() ?? String(describing: expected))")
                            break
                        }
                    }
                    window.makeFirstResponder(tabs)
                    for expected in Array(runningOrder.reversed()) + [tabs] {
                        window.sendEvent(shiftTab)
                        if !hasKeyboardFocus(expected, in: window) {
                            failures.append("Running Connectivity Shift-Tab skips \(expected.accessibilityLabel() ?? String(describing: expected))")
                            break
                        }
                    }
                    window.makeFirstResponder(nil)
                    window.sendEvent(tab)
                    if !hasKeyboardFocus(runningOrder[0], in: window) {
                        failures.append("Connectivity Tab cannot recover from window focus")
                    }
                    focusTabEntry(peer)
                    if !hasKeyboardFocus(tabs, in: window) {
                        failures.append("Command-1 must focus the tab strip when peer field is disabled")
                    }
                    name.isEnabled = previousConnectivityEnabled[0]
                    peer.isEnabled = previousConnectivityEnabled[1]
                    password.isEnabled = previousConnectivityEnabled[2]
                    start.isEnabled = previousConnectivityEnabled[3]
                    stop.isEnabled = previousConnectivityEnabled[4]
                    let previousRecordingEnabled = recordingButton.isEnabled
                    recordingButton.isEnabled = true
                    tabs.selectTabViewItem(at: 2)
                    let previousCompressionEnabled = flacCompression.isEnabled
                    for compressionEnabled in [false, true] {
                        flacCompression.isEnabled = compressionEnabled
                        let recordingOrder = controlGroups[2].filter {
                            ($0 as? NSControl)?.isEnabled != false && !$0.isHiddenOrHasHiddenAncestor
                        }
                        window.makeFirstResponder(tabs)
                        for expected in recordingOrder + [tabs] {
                            window.sendEvent(tab)
                            if !hasKeyboardFocus(expected, in: window) {
                                failures.append("Running Recording / Profiles Tab skips \(expected.accessibilityLabel() ?? String(describing: expected))")
                                break
                            }
                        }
                        window.makeFirstResponder(tabs)
                        for expected in Array(recordingOrder.reversed()) + [tabs] {
                            window.sendEvent(shiftTab)
                            if !hasKeyboardFocus(expected, in: window) {
                                failures.append("Running Recording / Profiles Shift-Tab skips \(expected.accessibilityLabel() ?? String(describing: expected))")
                                break
                            }
                        }
                    }
                    flacCompression.isEnabled = previousCompressionEnabled
                    recordingButton.isEnabled = previousRecordingEnabled
                    let previousMixEnabled = controlGroups[3].map {
                        ($0 as? NSControl)?.isEnabled ?? true
                    }
                    for control in controlGroups[3] { (control as? NSControl)?.isEnabled = true }
                    func checkVisibleOrder(_ controls: [NSView], label: String) {
                        let visible = controls.filter {
                            ($0 as? NSControl)?.isEnabled != false && !$0.isHiddenOrHasHiddenAncestor
                        }
                        window.makeFirstResponder(tabs)
                        for expected in visible + [tabs] {
                            window.sendEvent(tab)
                            if !hasKeyboardFocus(expected, in: window) {
                                failures.append("\(label) Tab skips \(expected.accessibilityLabel() ?? String(describing: expected))")
                                break
                            }
                        }
                        window.makeFirstResponder(tabs)
                        for expected in Array(visible.reversed()) + [tabs] {
                            window.sendEvent(shiftTab)
                            if !hasKeyboardFocus(expected, in: window) {
                                failures.append("\(label) Shift-Tab skips \(expected.accessibilityLabel() ?? String(describing: expected))")
                                break
                            }
                        }
                    }
                    tabs.selectTabViewItem(at: 3)
                    for mode in PeerEqMode.allCases {
                        var sample = PeerMix()
                        sample.eq.mode = mode
                        sample.eq.parametric = [ParametricBand(startHz: 200, endHz: 2000, gainDb: 3)]
                        updateEqControls(sample, have: true)
                        checkVisibleOrder(controlGroups[3], label: "Active Pan / EQ \(mode.title)")
                    }
                    updatePeerMixControls()
                    for (control, enabled) in zip(controlGroups[3], previousMixEnabled) {
                        (control as? NSControl)?.isEnabled = enabled
                    }
                    tabs.selectTabViewItem(at: 1)
                    let previousCaptureMode = systemAudioMode.indexOfSelectedItem
                    for mode in 0..<systemAudioMode.numberOfItems {
                        systemAudioMode.selectItem(at: mode)
                        showSystemAudioMode()
                        checkVisibleOrder(controlGroups[1], label: "Audio I/O capture mode \(mode)")
                    }
                    systemAudioMode.selectItem(at: previousCaptureMode)
                    showSystemAudioMode()
                } else {
                    failures.append("Could not create Shift-Tab test event")
                }
                if let voiceOverTab = NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [.control, .option], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\t",
                    charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48),
                    isNavigationTab(voiceOverTab) {
                    failures.append("VoiceOver modifier plus Tab must keep its native action")
                }
            } else {
                failures.append("Could not create Tab test event")
            }
            tabs.selectTabViewItem(at: 0)
            if status.nextKeyView !== tabs {
                failures.append("Tab from status must reach the tab strip")
            }
            for (item, controls) in zip(tabs.tabViewItems, controlGroups.prefix(4)) {
                if item.view == nil || controls.contains(where: {
                    !$0.isDescendant(of: item.view!)
                }) {
                    failures.append("A control is outside its named tab: \(item.label)")
                }
                if item.view?.accessibilityRole() != .group
                    || item.view?.accessibilityChildren()?.isEmpty != false {
                    failures.append("VoiceOver cannot enter \(item.label) content")
                }
                if let content = item.view, let first = controls.first {
                    var visited = Set<ObjectIdentifier>()
                    if !accessibilityTreeContains(content, first, visited: &visited) {
                        failures.append("VoiceOver cannot reach \(item.label) first control")
                        print(accessibilityOutline(content))
                    }
                    tabs.selectTabViewItem(item)
                    visited.removeAll()
                    if !accessibilityTreeContains(tabs, first, visited: &visited) {
                        failures.append("VoiceOver tab group omits \(item.label) controls")
                        print(accessibilityOutline(tabs))
                    }
                }
            }
            if !profileNotice.isDescendant(of: tabs.tabViewItems[2].view!) {
                failures.append("Profile status is outside Recording / Profiles")
            }
            if let preferencesContent = preferencesWindow?.contentView {
                for (index, controls) in [generalPreferencesOrder, cuePane.tabOrder,
                    permissionsControlOrder].enumerated() {
                    preferencesTabs.selectTabViewItem(at: index)
                    if controls.contains(where: { !$0.isDescendant(of: preferencesContent) }) {
                        failures.append("A Preferences control is outside \(preferencesTabs.tabViewItems[index].label)")
                    }
                }
            } else {
                failures.append("Preferences window has no content")
            }
            if preferencesTabs.tabViewItems.map(\.label) != ["General", "Audio cues", "Permissions"]
                || !preferencesTabs.acceptsFirstResponder
                || !permissionsControlOrder.contains(where: { $0 === microphonePermissionStatus })
                || !permissionsControlOrder.contains(where: { $0 === inputSendingStatus })
                || !permissionsControlOrder.contains(where: { $0 === microphonePermissionButton })
                || !permissionsControlOrder.contains(where: { $0 === systemAudioPermissionButton })
                || !microphonePermissionStatus.isSelectable
                || !inputSendingStatus.isSelectable {
                failures.append("Preferences must expose keyboard-reachable permission controls")
            }
            if let content = preferencesTabs.tabViewItems.last?.view {
                var visited = Set<ObjectIdentifier>()
                preferencesTabs.selectTabViewItem(at: 2)
                if content.accessibilityRole() != .group
                    || !accessibilityTreeContains(preferencesTabs,
                        microphonePermissionStatus, visited: &visited) {
                    failures.append("VoiceOver cannot reach the Permissions status")
                }
            }
            if let preferencesWindow,
                let tab = NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: 0,
                    windowNumber: preferencesWindow.windowNumber, context: nil,
                    characters: "\t", charactersIgnoringModifiers: "\t",
                    isARepeat: false, keyCode: 48),
                let shiftTab = NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: .shift, timestamp: 0,
                    windowNumber: preferencesWindow.windowNumber, context: nil,
                    characters: "\t", charactersIgnoringModifiers: "\t",
                    isARepeat: false, keyCode: 48) {
                for item in preferencesTabs.tabViewItems {
                    preferencesTabs.selectTabViewItem(item)
                    let enabled = preferencesControlOrder.filter {
                        ($0 as? NSControl)?.isEnabled != false
                    }
                    preferencesWindow.makeFirstResponder(nil)
                    for expected in enabled {
                        preferencesWindow.sendEvent(tab)
                        if !hasKeyboardFocus(expected, in: preferencesWindow) {
                            failures.append("\(item.label) Preferences Tab skips \(expected.accessibilityLabel() ?? String(describing: expected))")
                            break
                        }
                    }
                    preferencesWindow.makeFirstResponder(nil)
                    for expected in enabled.reversed() {
                        preferencesWindow.sendEvent(shiftTab)
                        if !hasKeyboardFocus(expected, in: preferencesWindow) {
                            failures.append("\(item.label) Preferences Shift-Tab skips \(expected.accessibilityLabel() ?? String(describing: expected))")
                            break
                        }
                    }
                }
            }
            if HotkeyDescriptor(keyCode: UInt32(kVK_Tab), modifiers: [.control, .option]).isValid
                || HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_Q), modifiers: [.command]).isValid
                || HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_S), modifiers: []).isValid
                || !HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_Backslash),
                    modifiers: [.control, .option]).isValid {
                failures.append("Global hotkey validation must follow Clipman's Mac rules")
            }
            for control in [name, peer, password] {
                if control.accessibilityLabel()?.isEmpty != false { failures.append("Missing field label") }
            }
            for button in [remember, reconnect, loginAtStartup, send, systemAudio,
                receive, receiveAutoTune, monitor, plugins,
                splitRecording, recordingBypassShaping,
                peerMixEnabled, recordingButton, selfMonitoringButton, start, stop, toggle] {
                let role = button.cell?.accessibilityAttributeValue(.role) as? String
                if button.title.isEmpty || !(role == "AXCheckBox" || role == "AXButton") {
                    failures.append("Missing native button cell role or name: \(String(describing:role))")
                }
            }
            if selfMonitoringButton.title != "Unmute myself to test round trip"
                || selfMonitoringButton.accessibilityHelp()?.isEmpty != false
                || !audioTabOrder.contains(where: { $0 === selfMonitoringButton })
                || !audioTabOrder.contains(where: { $0 === selfMonitoringStatus })
                || selfMonitoringStatus.accessibilityLabel() != "Self-monitoring off." {
                failures.append("Round-trip control and status must be named, helped and keyboard reachable")
            }
            if recordingBypassShaping.accessibilityHelp()?.isEmpty != false
                || !controlGroups[2].contains(where: { $0 === recordingBypassShaping }) {
                failures.append("Recording bypass needs native checkbox, help and forward/reverse tab access")
            }
            if table.accessibilityLabel() != "Peers" { failures.append("Missing peer list label") }
            if flacCompression.accessibilityLabel() != "FLAC compression"
                || flacCompression.accessibilityHelp()?.isEmpty != false
                || flacCompression.itemArray.compactMap({ $0.representedObject as? Int }) != Array(0...8)
                || !controlGroups[2].contains(where: { $0 === flacCompression }) {
                failures.append("FLAC compression needs all lossless levels, help and forward/reverse tab access")
            }
            if mixPeer.accessibilityLabel() != "Peer to shape"
                || mixPeer.accessibilityHelp()?.isEmpty != false {
                failures.append("Pan and EQ peer selector lacks a VoiceOver name or help")
            }
            if systemOutputTable.accessibilityLabel() != "System capture outputs"
                || systemOutputTable.numberOfRows < 1 {
                failures.append("System output table lacks a VoiceOver name or All row")
            }
            if inputTable.accessibilityLabel() != "Audio inputs to send"
                || inputTable.numberOfRows < 1 {
                failures.append("Audio input table lacks a VoiceOver name or default row")
            }
            if outputTable.accessibilityLabel() != "Mac playback outputs"
                || outputTable.numberOfRows < 1 {
                failures.append("Mac playback output table lacks a VoiceOver name or default row")
            }
            if inputTable.tabForward == nil || inputTable.tabBackward == nil
                || outputTable.tabForward == nil || outputTable.tabBackward == nil
                || outputPairTable.tabForward == nil || outputPairTable.tabBackward == nil
                || inputPairTable.tabForward == nil || inputPairTable.tabBackward == nil
                || systemOutputTable.tabForward == nil || systemOutputTable.tabBackward == nil
                || systemOutputPairTable.tabForward == nil
                || systemOutputPairTable.tabBackward == nil {
                failures.append("Capture tables must support Tab and Shift-Tab exit")
            }
            let inputCleared = CaptureSendState.afterSelection(previouslyEmpty: false,
                nowEmpty: true, sending: true, resumePending: false)
            let inputRestored = CaptureSendState.afterSelection(previouslyEmpty: true,
                nowEmpty: false, sending: inputCleared.sending,
                resumePending: inputCleared.resumePending)
            let offBeforeClear = CaptureSendState.afterSelection(previouslyEmpty: false,
                nowEmpty: true, sending: false, resumePending: false)
            let startsOn = CaptureSendState.afterSelection(previouslyEmpty: true,
                nowEmpty: false, sending: offBeforeClear.sending,
                resumePending: offBeforeClear.resumePending)
            if inputCleared.sending || !inputRestored.sending || !startsOn.sending {
                failures.append("Selecting the first audio route must enable its global switch")
            }
            if !PlaybackMonitoringState.afterSelection(wasChecked: false,
                    isChecked: true, hasOutputs: true, monitoring: false)
                || PlaybackMonitoringState.afterSelection(wasChecked: true,
                    isChecked: false, hasOutputs: false, monitoring: true)
                || PlaybackMonitoringState.afterSelection(wasChecked: true,
                    isChecked: false, hasOutputs: true, monitoring: false) {
                failures.append("Mac output must follow checked output routes")
            }
            let inputs = ["", "first", "second", "third"]
            let firstInput = AudioInputSelection.toggle(row: 1, current: [""], available: inputs)
            let twoInputs = AudioInputSelection.toggle(row: 2,
                current: firstInput, available: inputs)
            let defaultInput = AudioInputSelection.toggle(row: 0,
                current: twoInputs, available: inputs)
            if firstInput != ["first"] || twoInputs != ["first", "second"]
                || defaultInput != [""] {
                failures.append("Multiple audio input selection must be independent")
            }
            let firstPlayback = AudioInputSelection.toggle(
                row: 1, current: [""], available: inputs)
            let twoPlaybacks = AudioInputSelection.toggle(
                row: 2, current: firstPlayback, available: inputs)
            if twoPlaybacks != ["first", "second"] {
                failures.append("Multiple Mac playback cards must stay selected independently")
            }
            let clearedPair = PlaybackPairSelection.toggle(uid: "card", pair: 0,
                devices: ["card"], pairs: [:], available: ["", "card"])
            let restoredPair = PlaybackPairSelection.toggle(uid: "card", pair: 1,
                devices: clearedPair.devices, pairs: clearedPair.pairs,
                available: ["", "card"])
            if !clearedPair.devices.isEmpty || clearedPair.pairs["card"] != nil
                || restoredPair.devices != ["card"] || restoredPair.pairs["card"] != [1] {
                failures.append("Clearing the last output pair must deselect its card")
            }
            if outputPairChoices.contains(where: {
                AudioDeviceCatalog.outputChannelPairCount($0.uid) <= 1
            }) {
                failures.append("Stereo-only outputs must not enter the channel-pair table")
            }
            if systemOutputPairChoices.contains(where: {
                AudioDeviceCatalog.systemCaptureRoutes($0.uid).count <= 1
            }) {
                failures.append("Stereo-only outputs must not enter the system capture pair table")
            }
            let outputs = ["first", "second", "third"]
            let oneRemoved = SystemOutputSelection.toggle(row: 2, current: nil, available: outputs)
            let twoRemoved = SystemOutputSelection.toggle(row: 1,
                current: oneRemoved, available: outputs)
            let none = SystemOutputSelection.toggle(row: 3,
                current: twoRemoved, available: outputs)
            if oneRemoved != ["first", "third"] || twoRemoved != ["third"]
                || none != []
                || SystemOutputSelection.toggle(row: 0, current: none, available: outputs) != nil {
                failures.append("All-output and individual checkbox selection must round-trip")
            }
            tabs.selectTabViewItem(at: 1)
            let outputCell = systemOutputTable.view(atColumn: 0, row: 0,
                makeIfNecessary: true) as? NSButton
            if outputCell?.title != "All system outputs"
                || outputCell?.state != (captureOutputSelected(0) ? .on : .off)
                || outputCell?.cell?.accessibilityAttributeValue(.role) as? String != "AXCheckBox"
                || outputCell?.action != #selector(captureCheckboxChanged(_:))
                || outputCell?.target !== self || systemOutputTable.clickTogglesRow {
                failures.append("System output rows must expose native checkbox state")
            }
            if let outputCell {
                if outputCell.superview == nil || outputCell.window !== window {
                    failures.append("System output checkbox is not attached to the Audio I/O window")
                }
            }
            let inputCell = tableView(inputTable,
                viewFor: inputTable.tableColumns.first, row: 0) as? NSTextField
            if inputCell?.stringValue != inputRowLabel(0)
                || inputCell?.accessibilityLabel() != inputCell?.stringValue {
                failures.append("Audio input rows must speak checked state like peer rows")
            }
            let playbackCell = tableView(outputTable,
                viewFor: outputTable.tableColumns.first, row: 0) as? NSTextField
            if playbackCell?.stringValue != outputRowLabel(0)
                || playbackCell?.accessibilityLabel() != playbackCell?.stringValue {
                failures.append("Mac playback output rows must speak checked state")
            }
            if inputPairTable.accessibilityLabel()?.isEmpty != false {
                failures.append("Input channel-pair table lacks a VoiceOver name")
            }
            if outputPairTable.accessibilityLabel() != "Mac playback output channel pairs" {
                failures.append("Output channel-pair table lacks a VoiceOver name")
            }
            if systemOutputPairTable.accessibilityLabel() != "System capture output channel pairs" {
                failures.append("System capture channel-pair table lacks a VoiceOver name")
            }
            if autoSaveInterval.accessibilityLabel() != "Auto-save non-read-only profiles"
                || autoSaveInterval.itemArray.count != 7 {
                failures.append("Writable-profile auto-save interval is missing or unnamed")
            }
            if checkUpdates.accessibilityLabel() != "Check for updates automatically"
                || installUpdates.accessibilityLabel() != "Install verified updates automatically" {
                failures.append("Update preferences are missing VoiceOver names")
            }
            if cuePane.globalList.numberOfRows != CueEvent.globalEvents.count
                || cuePane.profileList.numberOfRows != CueEvent.profileEvents.count
                || cuePane.globalList.accessibilityLabel() != "Global sounds, for every profile"
                || cuePane.profileList.accessibilityLabel() != "Profile sounds" {
                failures.append("Audio cue lists are missing their scopes or VoiceOver names")
            }
            if cueMute.accessibilityLabel() != "Turn all audio cues off"
                || cueMute.accessibilityHelp()?.contains("previews") != true
                || cuePane.tabOrder.first !== cueMute
                || cuePane.tabOrder[1] !== cuePane.globalList
                || cuePane.tabOrder[2] !== cuePane.profileList {
                failures.append("Machine cue mute and global/profile lists must follow the keyboard order")
            }
            let selectedCueEvent = chosenCueEvent
            if cueChoice.accessibilityLabel() != "Choose sound for \(selectedCueEvent.title)"
                || cueChoice.numberOfItems != CueSounds.shared.variants(for: selectedCueEvent).count + 1 + (cueCustomFiles[selectedCueEvent] == nil ? 0 : 1)
                || cueChoice.item(at: 0)?.title != "\(selectedCueEvent.title), (none)" {
                failures.append("Audio cue choices do not identify their event")
            }
            if cueBrowse.accessibilityLabel() != "Browse for \(selectedCueEvent.title) sound"
                || cueBrowse.accessibilityHelp()?.isEmpty != false
                || cueChoice.accessibilityHelp()?.contains("every profile") != true
                || !cuePane.tabOrder.contains(where: { $0 === cueBrowse }) {
                failures.append("Custom cue file workflow lacks accessible scope/help/tab order")
            }
            if AppRuntime.configuration.isIsolated, let preferencesWindow {
                let cues = CueSounds.shared.preferences
                let previousProfileCues = cues.profileConfigurations
                let previousKeyboardClicks = cues.keyboardClicksEnabled
                let previousCustomFiles = cueCustomFiles
                let previousEvent = cuePane.selectedEvent
                let previousTab = preferencesTabs.indexOfTabViewItem(preferencesTabs.selectedTabViewItem!)
                let previousSave = cues.configuration(for: .save).enabled
                let previousMute = cues.muteAllCues
                let testID = UUID()
                let before = profileSnapshot(id: testID, title: "Cue gate", readOnly: false)
                cues.setEnabled(!previousSave, for: .save)
                if profileSnapshot(id: testID, title: "Cue gate", readOnly: false) != before {
                    failures.append("Machine-wide cues must not dirty the profile")
                }
                cues.setEnabled(previousSave, for: .save)
                cuePane.keyboardClicks.performClick(nil)
                if cues.keyboardClicksEnabled == previousKeyboardClicks
                    || profileSnapshot(id: testID, title: "Cue gate", readOnly: false) == before {
                    failures.append("Typing checkbox must apply immediately and dirty the profile snapshot")
                }
                cues.setKeyboardClicksEnabled(previousKeyboardClicks)
                refreshCueChoices()
                if profileSnapshot(id: testID, title: "Cue gate", readOnly: false) != before
                    || cuePane.tabOrder.last !== cuePane.keyboardClicks {
                    failures.append("Typing choice restoration and last keyboard position must remain exact")
                }
                for muted in [true, false] {
                    let request = ControlRequest(action: "cue-mute", arguments: ["value": muted ? "on" : "off"])
                    if let command = try? ControlCommand(request) {
                        let result = performControlCommand(command, request: request)
                        if result.status != .ok || cues.muteAllCues != muted
                            || profileSnapshot(id: testID, title: "Cue gate", readOnly: false) != before {
                            failures.append("Machine cue mute must persist immediately without dirtying the profile")
                        }
                    } else { failures.append("Machine cue mute control command is missing") }
                }
                cueMute.state = previousMute ? .on : .off
                cueMuteChanged()
                preferencesTabs.selectTabViewItem(at: 1)
                cuePane.select(.connect, preview: false)
                cues.chooseCustomFile("/private/missing-cue-gate.wav", for: .connect)
                for enabled in [true, false] {
                    cues.setEnabled(enabled, for: .connect)
                    refreshCueChoices()
                    let expected = enabled ? "Custom" : "Off"
                    if cueChoice.selectedItem?.representedObject as? String != expected
                        || cuePreview.isEnabled != enabled
                        || cueChoice.itemArray.filter({ $0.representedObject as? String == "Custom" }).count != 1
                        || cueChoice.accessibilityHelp()?.contains("current profile") != true {
                        failures.append("Custom cue and Off must retain file, scope and preview state")
                    }
                    for backwards in [false, true] {
                        let order = preferencesControlOrder.filter { ($0 as? NSControl)?.isEnabled != false }
                        let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                            modifierFlags: backwards ? .shift : [], timestamp: 0,
                            windowNumber: preferencesWindow.windowNumber, context: nil,
                            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
                        preferencesWindow.makeFirstResponder(nil)
                        for control in backwards ? Array(order.reversed()) : order {
                            preferencesWindow.sendEvent(event)
                            if !hasKeyboardFocus(control, in: preferencesWindow) {
                                failures.append("Custom/Off cue state disrupts Preferences keyboard traversal")
                                break
                            }
                        }
                    }
                }
                if profileSnapshot(id: testID, title: "Cue gate", readOnly: false) == before {
                    failures.append("Profile cue changes must participate in profile dirty detection")
                }
                func cueControl(_ value: String) -> ControlReply? {
                    let request = ControlRequest(action: "cue", arguments: ["value": value])
                    guard let command = try? ControlCommand(request) else { return nil }
                    return performControlCommand(command, request: request)
                }
                for enabled in [false, true] {
                    let result = cueControl("connect:" + (enabled ? "on" : "off"))
                    if result?.status != .ok || cues.configuration(for: .connect).enabled != enabled
                        || cues.configuration(for: .connect).customPath != "/private/missing-cue-gate.wav" {
                        failures.append("Cue controls must set state and preserve the custom file")
                    }
                }
                if let variant = CueSounds.shared.variants(for: .connect).last {
                    if cueControl("connect:" + variant)?.status != .ok
                        || cues.configuration(for: .connect).customPath != nil
                        || cues.builtInSelection(for: .connect, variants: CueSounds.shared.variants(for: .connect)) != variant {
                        failures.append("Cue controls must apply an advertised built-in selection")
                    }
                }
                let beforeInvalidCue = cues.profileConfigurations
                if cueControl("connect:not-bundled.wav")?.status != .error || cues.profileConfigurations != beforeInvalidCue {
                    failures.append("Cue controls must reject an unadvertised sound without changes")
                }
                let cueListRequest = ControlRequest(action: "cue-list")
                if let command = try? ControlCommand(cueListRequest) {
                    let listing = performControlCommand(command, request: cueListRequest)
                    if listing.status != .ok || listing.state["cue.connect.scope"] != "profile"
                        || listing.state["cue.startup.scope"] != "profile"
                        || listing.state["cue.save.scope"] != "machine"
                        || listing.state.values.contains(where: { $0.contains("/private/missing-cue-gate.wav") }) {
                        failures.append("Cue listing must expose scopes and keep custom paths private")
                    }
                } else { failures.append("Cue listing command is missing") }
                cues.loadProfile(previousProfileCues, keyboardClicks: previousKeyboardClicks)
                cueCustomFiles = previousCustomFiles
                preferencesTabs.selectTabViewItem(at: previousTab)
                cuePane.select(previousEvent, preview: false)
            }
            if Bundle.main.bundleURL.pathExtension == "app",
                CueSounds.shared.variants(for: .connect).count < 2 {
                failures.append("Windows RemSound cue sounds are missing from the app bundle")
            }
            if Bundle.main.bundleURL.pathExtension == "app",
                (CueSounds.shared.variants(for: .dawOn).isEmpty
                    || CueSounds.shared.variants(for: .dawOff).isEmpty) {
                failures.append("DAW toggle cues must use bundled RemSound sounds")
            }
            if !outputPairChoices.isEmpty {
                let pairCell = tableView(outputPairTable,
                    viewFor: outputPairTable.tableColumns.first, row: 0) as? NSTextField
                if pairCell?.stringValue != outputPairRowLabel(0)
                    || pairCell?.accessibilityLabel() != pairCell?.stringValue {
                    failures.append("Output channel-pair rows must speak checked state")
                }
            }
            if !systemOutputPairChoices.isEmpty {
                let pairCell = tableView(systemOutputPairTable,
                    viewFor: systemOutputPairTable.tableColumns.first, row: 0) as? NSTextField
                if pairCell?.stringValue != systemOutputPairRowLabel(0)
                    || pairCell?.accessibilityLabel() != pairCell?.stringValue {
                    failures.append("System capture pair rows must speak checked state")
                }
            }
            if !inputPairChoices.isEmpty {
                let pairCell = tableView(inputPairTable,
                    viewFor: inputPairTable.tableColumns.first, row: 0) as? NSTextField
                if pairCell?.stringValue != inputPairRowLabel(0)
                    || pairCell?.accessibilityLabel() != pairCell?.stringValue {
                    failures.append("Input channel-pair rows must speak checked state")
                }
            }
            for popup in [codec, packetSize, receiveJitter, receiveSmoothness, receiveArtifact, receiveAutoTuneInterval,
                recordingSource, recordingFormat, flacCompression,
                recordingChannels] {
                if popup.accessibilityLabel()?.isEmpty != false || popup.itemArray.isEmpty {
                    failures.append("Audio device selector lacks a name or default choice")
                }
            }
            if receiveArtifact.itemArray.compactMap({ $0.representedObject as? Int }) != [2, 3]
                || receiveArtifact.accessibilityHelp()?.isEmpty != false {
                failures.append("Receive gap sound must expose Noise burst and Click with VoiceOver help")
            }
            if AppRuntime.settings.object(forKey: "receiveArtifact") == nil
                && selectedReceiveArtifact() != .defaultChoice {
                failures.append("Receive gap sound must default to Noise burst")
            }
            if receiveSmoothness.itemArray.compactMap({ $0.representedObject as? Int }) != Array((1...10).reversed())
                || receiveSmoothness.accessibilityHelp()?.isEmpty != false {
                failures.append("Buffer smoothness must expose ten Windows choices and VoiceOver help")
            }
            if AppRuntime.settings.object(forKey: "receiveSmoothness") == nil
                && selectedReceiveSmoothness() != BufferSmoothness.defaultLevel {
                failures.append("Buffer smoothness must default to three")
            }
            if packetSize.numberOfItems != 2 || packetSize.accessibilityHelp()?.isEmpty != false {
                failures.append("Sending packet size must expose both choices and VoiceOver help")
            }
            if AppRuntime.settings.object(forKey: "enableAllPeerShaping") == nil && peerMixes.isEmpty
                && allPeerShaping.state != .off {
                failures.append("Volume, pan and EQ for all peers must default to off")
            }
            if systemAudioMode.numberOfItems != 2 || activeAppsTable.accessibilityLabel() != "Currently active applications"
                || rememberedAppsTable.accessibilityLabel() != "Remembered applications" {
                failures.append("How to send Mac system audio and the two application lists must be named for VoiceOver")
            }
            if eqMode.numberOfItems != 3 || bandList.accessibilityLabel()?.isEmpty != false
                || resetPeerEq.accessibilityHelp()?.isEmpty != false {
                failures.append("The EQ modes, bands list and reset must be named for VoiceOver")
            }
            for slider in [peerVolume, peerPan] + eqBandSliders {
                if slider.accessibilityLabel()?.isEmpty != false
                    || slider.accessibilityHelp()?.isEmpty != false {
                    failures.append("A peer mixer slider lacks a VoiceOver name or help")
                }
            }
            if !status.isSelectable { failures.append("Connection status cannot receive keyboard focus") }
            if listeningVolume.accessibilityLabel()?.isEmpty != false || listeningVolume.accessibilityHelp()?.isEmpty != false
                || receiveMute.accessibilityHelp()?.isEmpty != false || acceptRemoteVolume.accessibilityHelp()?.isEmpty != false {
                failures.append("Listening volume, receive mute and remote commands must have VoiceOver names and help")
            }
            failures.append(contentsOf: sliderResetAccessibilityFailures())
            if AppRuntime.settings.object(forKey: "acceptRemoteVolumeCommands") == nil && acceptRemoteVolume.state != .off {
                failures.append("Remote volume commands must default to off")
            }
            if AppRuntime.settings.data(forKey: "globalHotkeys") == nil
                && [remoteVolumeUpHotkey, remoteVolumeDownHotkey, remoteMuteHotkey, remoteSystemUpHotkey,
                    remoteSystemDownHotkey, remoteSystemMuteHotkey].contains(where: { $0.descriptor != nil }) {
                failures.append("Remote volume hotkeys must be unset by default")
            }
            if !profileNotice.isSelectable || profileNotice.accessibilityLabel() != "Profile status" {
                failures.append("Profile status must be keyboard and VoiceOver accessible")
            }
            if AppRuntime.settings.object(forKey: "sendInput") == nil && send.state != .off {
                failures.append("Sending must default to off")
            }
            if monitor.keyEquivalent != "l"
                || monitor.keyEquivalentModifierMask != .command
                || plugins.keyEquivalent != "d"
                || plugins.keyEquivalentModifierMask != .command
                || systemAudio.keyEquivalent != "u"
                || systemAudio.keyEquivalentModifierMask != .command {
                failures.append("Mac output, DAW and system audio shortcuts must be distinct")
            }
            let saveItem = profileMenu.items.first(where: { $0.title == "Save Profile" })
            let saveAsItem = profileMenu.items.first(where: { $0.title == "Save Profile As…" })
            let openRecordingsItem = recordMenu.items.first(where: {
                $0.title == "Open Recordings Folder"
            })
            if send.keyEquivalent != "i" || send.keyEquivalentModifierMask != .command
                || saveItem?.keyEquivalent != "s" || saveItem?.keyEquivalentModifierMask != .command
                || saveAsItem?.keyEquivalent != "s"
                || saveAsItem?.keyEquivalentModifierMask != [.command, .shift] {
                failures.append("Send, Save Profile and Save Profile As shortcuts must be distinct")
            }
            if openRecordingsItem?.keyEquivalent != "o"
                || openRecordingsItem?.keyEquivalentModifierMask != [.command, .shift] {
                failures.append("Command-Shift-O must open the recordings folder")
            }
            let hide = appMenu.items.first(where: { $0.title == "Hide RemSound" })
            if hide?.keyEquivalent != "h" || hide?.action != #selector(NSApplication.hide(_:)) {
                failures.append("Command-H must invoke the standard Hide RemSound action")
            }
            let preferencesItem = appMenu.items.first(where: { $0.keyEquivalent == "," })
            if preferencesItem?.keyEquivalent != ","
                || preferencesItem?.keyEquivalentModifierMask != .command
                || preferencesWindow?.title != "RemSound Preferences" {
                failures.append("Command-comma must open the named Preferences window")
            }
            let tabTitles = ["Connectivity", "Audio I/O", "Recording / Profiles", "Pan / EQ"]
            if tabTitles.enumerated().contains(where: { index, title in
                !viewMenu.items.contains(where: {
                    $0.title == title && $0.keyEquivalent == String(index + 1)
                        && $0.keyEquivalentModifierMask == .command
                })
            }) {
                failures.append("Command-1 through Command-4 must open the four tabs")
            }
            if applicationShouldTerminateAfterLastWindowClosed(NSApp) {
                failures.append("Closing the window must keep the audio service running")
            }
            if NSApp.activationPolicy() != .accessory {
                failures.append("Closing the window must remove RemSound from Command-Tab")
            }
            _ = NSApp.setActivationPolicy(.regular)
            applicationDidHide(Notification(name: NSApplication.didHideNotification))
            if NSApp.activationPolicy() != .accessory {
                failures.append("Command-H must remove RemSound from Command-Tab")
            }
            _ = NSApp.setActivationPolicy(.regular)
            if statusItem.button?.accessibilityLabel() != "RemSound, stopped" {
                failures.append("Menu bar item must expose RemSound status")
            }
            if statusStart.action != #selector(startSession)
                || statusStop.action != #selector(stopSession) {
                failures.append("Menu bar must expose Start and Stop")
            }
            let requiredProfileActions = [
                "New Profile", "Save Profile", "Save Profile As…", "Open Profile…",
                "Rename Current Profile…", "Delete Current Profile…",
                "Lock Current Profile (Read Only)",
            ]
            if requiredProfileActions.contains(where: { title in
                !profileMenu.items.contains(where: { $0.title == title })
            }) {
                failures.append("Profiles menu is missing a named keyboard-reachable action")
            }
            if profileMenu.items.first(where: { $0.title == "Recent Profiles" })?.submenu == nil
                || statusItem.menu?.items.first(where: {
                    $0.title == "Recent Profiles"
                })?.submenu !== statusRecentProfilesMenu {
                failures.append("Both Profiles menus must expose the Recent Profiles submenu")
            }
            if table.peerMenu?.items.first?.title != "Rename Peer…" || table.rename == nil {
                failures.append("Peer rows must offer Rename Peer and F2")
            }
            updateControlAvailability(true)
            if !send.isEnabled || !receive.isEnabled || !monitor.isEnabled || !plugins.isEnabled {
                failures.append("Audio direction controls must remain available during a session")
            }
            running = true
            connectedPeerCount = 2
            refreshStatusItem()
            let namedPeerSummary = statusItem.button?.accessibilityLabel()
            updateControlAvailability(true)
            if statusItem.button?.accessibilityLabel() != namedPeerSummary {
                failures.append("Menu bar peer count changed during an unrelated control refresh")
            }
            running = false
            connectedPeerCount = 0
            refreshStatusItem()
            failures.append(contentsOf: focusedHelpAccessibilityFailures())
            failures.append(contentsOf: quickProfileAccessibilityFailures())
            if failures.isEmpty {
                print(
                    "Native accessibility structure checks passed: labels, roles, keyboard order, focusable status, safe sending default."
                )
            } else {
                for error in failures { print(error) }
            }
            exit(failures.isEmpty ? 0 : 1)
        }
        uiObservations.start()
        let startupOverridesProfile = prepareStartupSelection()
        if AppRuntime.configuration.isHeadless {
            window.orderOut(nil)
            statusItem.isVisible = true
            // Do not restore a profile's automatic connection until an explicit start command.
            if !startupOverridesProfile { _ = restoreStartProfile() || restoreActiveProfile() }
            if startupOverridesProfile { finishStartupSelection() }
            startTypingFeedback()
            do { try startControlServer() }
            catch {
                FileHandle.standardError.write(Data("RemSound: \(error.localizedDescription)\n".utf8))
                uiObservations.stop()
                session.shutdown()
                exit(2)
            }
            DispatchQueue.main.async { [weak self] in self?.closeSettingsPlaceholder() }
            recordStartup("Isolated headless control ready; session stopped.")
            #if DEBUG
            if ProcessInfo.processInfo.environment["REMSOUND_TEST_BROWSER_PROFILE_CHECK"] == "1" {
                var environment = ProcessInfo.processInfo.environment; environment["REMSOUND_TEST_PEER_MOVE_CHECK"] = "1"
                if HeadlessPeerMoveCheckPolicy.accepts(root: AppRuntime.configuration.root, headless: AppRuntime.configuration.isHeadless,
                    silent: AppRuntime.configuration.silent, environment: environment) {
                    let failures = headlessBrowserProfileFailures()
                    applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                    if failures.isEmpty { print("Headless browser profile check passed.") } else { failures.forEach { print($0) } }
                    exit(failures.isEmpty ? 0 : 1)
                }
            }
            if ProcessInfo.processInfo.environment["REMSOUND_TEST_BROWSER_STAGED_CHECK"] == "1" {
                var environment=ProcessInfo.processInfo.environment;environment["REMSOUND_TEST_PEER_MOVE_CHECK"]="1"
                if HeadlessPeerMoveCheckPolicy.accepts(root:AppRuntime.configuration.root,headless:AppRuntime.configuration.isHeadless,silent:AppRuntime.configuration.silent,environment:environment) {
                    let failures=headlessBrowserStagedFailures()
                    applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification))
                    if failures.isEmpty {print("Headless browser staged check passed.")} else {failures.forEach {print($0)}}
                    exit(failures.isEmpty ? 0:1)
                }
            }
            if ProcessInfo.processInfo.environment["REMSOUND_TEST_PROFILE_ACTION_CHECK"] == "1" {
                var environment=ProcessInfo.processInfo.environment;environment["REMSOUND_TEST_PEER_MOVE_CHECK"]="1"
                if HeadlessPeerMoveCheckPolicy.accepts(root:AppRuntime.configuration.root,headless:AppRuntime.configuration.isHeadless,silent:AppRuntime.configuration.silent,environment:environment) {
                    let failures=headlessProfileActionFailures()
                    applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification))
                    if failures.isEmpty {print("Headless profile action check passed.")} else {failures.forEach {print($0)}}
                    exit(failures.isEmpty ? 0:1)
                }
            }
            if ProcessInfo.processInfo.environment["REMSOUND_TEST_BROWSER_REMOVAL_CHECK"] == "1" {
                var environment=ProcessInfo.processInfo.environment;environment["REMSOUND_TEST_PEER_MOVE_CHECK"]="1"
                if HeadlessPeerMoveCheckPolicy.accepts(root:AppRuntime.configuration.root,headless:AppRuntime.configuration.isHeadless,silent:AppRuntime.configuration.silent,environment:environment) {
                    let failures=headlessBrowserConfirmedRemovalFailures()
                    applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification))
                    if failures.isEmpty {print("Headless browser removal check passed.")} else {failures.forEach {print($0)}}
                    exit(failures.isEmpty ? 0:1)
                }
            }
            if ProcessInfo.processInfo.environment["REMSOUND_TEST_BROWSER_OWNER_CHECK"] == "1" {
                var environment = ProcessInfo.processInfo.environment; environment["REMSOUND_TEST_PEER_MOVE_CHECK"] = "1"
                if HeadlessPeerMoveCheckPolicy.accepts(root: AppRuntime.configuration.root, headless: AppRuntime.configuration.isHeadless,
                    silent: AppRuntime.configuration.silent, environment: environment) {
                    let failures = headlessBrowserOwnerFailures()
                    applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                    if failures.isEmpty { print("Headless browser owner check passed.") } else { failures.forEach { print($0) } }
                    exit(failures.isEmpty ? 0 : 1)
                }
            }
            if ProcessInfo.processInfo.environment["REMSOUND_TEST_STARTUP_CHECK"] == "1" {
                var environment = ProcessInfo.processInfo.environment;environment["REMSOUND_TEST_PEER_MOVE_CHECK"] = "1"
                if HeadlessPeerMoveCheckPolicy.accepts(root:AppRuntime.configuration.root,headless:AppRuntime.configuration.isHeadless,
                    silent:AppRuntime.configuration.silent,environment:environment) {
                    let failures = startupOwnerFailures()
                    applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification))
                    if failures.isEmpty { print("Headless startup owner check passed.") } else { failures.forEach { print($0) } }
                    exit(failures.isEmpty ? 0 : 1)
                }
            }
            if ProcessInfo.processInfo.environment["REMSOUND_TEST_NOTICE_CHECK"] == "1" {
                var environment = ProcessInfo.processInfo.environment; environment["REMSOUND_TEST_PEER_MOVE_CHECK"] = "1"
                if HeadlessPeerMoveCheckPolicy.accepts(root: AppRuntime.configuration.root, headless: AppRuntime.configuration.isHeadless,
                    silent: AppRuntime.configuration.silent, environment: environment) {
                    let failures = jam.serverNoticeOwnerFailures(stop: { self.stopSession() }, profileChange: { self.suspendPushToTalkForProfileChange() })
                    applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                    if failures.isEmpty { print("Headless server notice owner check passed.") }
                    else { failures.forEach { print($0) } }
                    exit(failures.isEmpty ? 0 : 1)
                }
            }
            if ProcessInfo.processInfo.environment["REMSOUND_TEST_ROUTER_CHECK"] == "1" {
                var environment = ProcessInfo.processInfo.environment
                environment["REMSOUND_TEST_PEER_MOVE_CHECK"] = "1"
                if HeadlessPeerMoveCheckPolicy.accepts(root: AppRuntime.configuration.root,
                    headless: AppRuntime.configuration.isHeadless, silent: AppRuntime.configuration.silent, environment: environment) {
                    let failures = headlessRouterCheckFailures()
                    applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                    if failures.isEmpty { print("Headless router owner check passed.") }
                    else { failures.forEach { print($0) } }
                    exit(failures.isEmpty ? 0 : 1)
                }
            }
            if HeadlessPeerMoveCheckPolicy.accepts(root: AppRuntime.configuration.root,
                headless: AppRuntime.configuration.isHeadless, silent: AppRuntime.configuration.silent,
                environment: ProcessInfo.processInfo.environment) {
                let failures = headlessPeerMoveCheckFailures()
                applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                if failures.isEmpty { print("Headless peer-move owner check passed.") }
                else { for failure in failures { print(failure) } }
                exit(failures.isEmpty ? 0 : 1)
            }
            #endif
            return
        }
        window.center()
        PreferencesExtras.applyTheme()
        PreferencesExtras.restoreWindowFrame(window)
        applyMainTabs()
        connectivityPeers.showRememberedList(PreferencesExtras.flag(PreferencesExtras.showRememberedPeersKey, default: true))
        if startupHidden { window.orderOut(nil);statusItem.isVisible = true }
        else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps:true);statusItem.isVisible = false
        }
        DispatchQueue.main.async { [weak self] in self?.closeSettingsPlaceholder() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.closeSettingsPlaceholder()
        }
        recordStartup(startupHidden ? "Main window hidden; applying profile setup." : "Main window opened; applying profile setup.")
        if startupOverridesProfile { finishStartupSelection() }
        else if !restoreStartProfile() && !restoreActiveProfile() {
            recordStartup("No active profile restored; loading default saved password.")
            loadSavedPassword(reconnectAfterLoad:true)
        }
        startTypingFeedback()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.checkPermissionsAtLaunch()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.startupNotices() }
        session.setPluginShaping(menuPluginShaping)
        refreshPluginMenu()
        updates.log = { [weak self] line in self?.session.note(line) }
        updates.installSilently = { [weak self] in
            guard let self else { return false }
            return self.installUpdates.state == .on && !self.running
        }
        updates.scheduleBackgroundChecks()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.updates.showWhatsNewIfJustUpdated() }
        if checkUpdates.state == .on {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.updates.check(.startup) }
        }
    }
    @objc private func startSession() {
        // The accessibility CLI observes requests without starting audio or asking permissions.
        if CommandLine.arguments.contains("--check-accessibility") {
            if AppRuntime.configuration.isIsolated { accessibilitySessionStartRequests += 1 }
            return
        }
        guard terminationRequest == nil else { return }
        beginSessionFromProfile(serverAddress: nil)
    }
    private var startupPlan:StartupLaunchPlan?
    private func prepareStartupSelection() -> Bool {
        let options = AppRuntime.startup
        startupPlan = nil
        guard options.profileName != nil || !options.connectPeers.isEmpty else { return false }
        do {
            let plan = try StartupLaunchPlan.make(options,profiles:{ try self.profileStore.list() })
            if let profile = plan.profile { showProfile(profile,playSwitchCue:false,loadPassword:false) }
            else if plan.blank { resetToBlankProfile(inheritingCues:CueSounds.shared.preferences.profileConfigurations) }
            guard AppRuntime.settings.setValues(["selectedPeerAddresses":plan.selectedPeers]) else {
                throw RuntimeConfigurationError.invalidSettings
            }
            connectivityPeers.refresh(entries:rememberedPeerEntries,running:false,locked:AppRuntime.settings.bool(forKey:"lockPeerAddresses"))
            startupPlan = plan
        } catch {
            let message = "Startup profile could not be selected. " + error.localizedDescription
            recordStartup(message);FileHandle.standardError.write(Data((message + "\n").utf8))
            jam.showConnectionStatus(message)
        }
        return true
    }
    private func finishStartupSelection() {
        guard let plan = startupPlan else { return }
        startupPlan = nil
        loadSavedPassword(reconnectAfterLoad:false) { [weak self] in
            guard let self, self.terminationRequest == nil else { return }
            if plan.startRequested { self.startSession() }
        }
    }
    private let startupRequests = StartupRequestOwner()
    private var startupHidden = AppRuntime.startHidden
    #if DEBUG
    private func startupOwnerFailures() -> [String] {
        var failures:[String] = [], assertions = 0
        func check(_ ok:Bool,_ message:String) { assertions += 1;if !ok { failures.append(message) } }
        let options = AppRuntime.startup
        check(!window.isVisible && !running && start.isEnabled, "Unattended startup must remain hidden and stopped without a password.")
        check(startupHidden, "Explicit minimized/silent startup must retain hidden policy.")
        check(options.connectPeers == ["127.0.0.2:47300"], "Actual bootstrap must deliver the requested numeric peer.")
        check(AppRuntime.settings.stringArray(forKey:"selectedPeerAddresses") == ["127.0.0.2:47300"], "Actual startup must apply working peer choices.")
        if options.profileName != nil {
            check(activeProfile?.title == "Startup fixture", "Explicit named profile must load before normal restore.")
            check(name.stringValue == "Named startup fixture", "Actual profile controls must reflect explicit selection.")
        } else {
            check(activeProfile == nil && peer.stringValue.isEmpty, "Connect without a profile must use the actual blank owner.")
            check(name.stringValue == "RemSound Mac", "Blank startup must not restore previous display name.")
        }
        check(password.stringValue.isEmpty, "Headless startup must not read saved credentials or invent a password.")
        let stopped = startupRequests.begin();stopSession()
        check(!startupRequests.consume(stopped), "Actual Stop must invalidate delayed startup/password callbacks.")
        let changed = startupRequests.begin();suspendPushToTalkForProfileChange()
        check(!startupRequests.consume(changed), "Actual profile transition must invalidate delayed startup callbacks.")
        var routes:[String] = [];let oldRoute = jam.connectUsingProfile
        jam.connectUsingProfile = { routes.append($0) };defer { jam.connectUsingProfile = oldRoute }
        password.stringValue = "private-stopped-fixture";send.state = .off;systemAudio.state = .off
        let request = ControlRequest(action:"server-connect",arguments:["value":"127.0.0.1:47301"])
        do {
            let reply = performControlCommand(try ControlCommand(request),request:request)
            check(reply.status == .waiting && routes == ["127.0.0.1:47301"], "Actual CLI server connect must reach the unattended common notice/profile route.")
            check(AppRuntime.settings.object(forKey:JamController.serverNoticeKey) == nil, "Unattended CLI must not save notice suppression.")
        } catch { failures.append("Control fixture command: " + error.localizedDescription) }
        password.stringValue = ""
        check(!running && sessionStartRequest == nil && !window.isVisible, "Stopped fake route must construct no session or visible window.")
        let oldRemember = remember.state;remember.state = .on
        let store = passwordStore;var completions = 0
        let stopLoad = startupRequests.begin();stopSession()
        completeSavedPasswordLoad(.success("obsolete"),store:store,request:stopLoad,reconnectAfterLoad:false) { completions += 1 }
        check(password.stringValue.isEmpty && completions == 0, "Actual Stop must discard late credential data and startup completion.")
        let profileLoad = startupRequests.begin();suspendPushToTalkForProfileChange()
        completeSavedPasswordLoad(.success("obsolete"),store:store,request:profileLoad,reconnectAfterLoad:false) { completions += 1 }
        check(password.stringValue.isEmpty && completions == 0, "Actual profile transition must discard late credential result.")
        let validLoad = startupRequests.begin()
        completeSavedPasswordLoad(.success("valid"),store:store,request:validLoad,reconnectAfterLoad:false) { completions += 1 }
        check(password.stringValue == "valid" && completions == 1, "Newest matching credential result may fill the current field once.")
        let typedLoad = startupRequests.begin();password.stringValue = "entered"
        completeSavedPasswordLoad(.success("obsolete"),store:store,request:typedLoad,reconnectAfterLoad:false) { completions += 1 }
        check(password.stringValue == "entered" && completions == 1, "User-entered password must suppress delayed automatic startup completion.")
        password.stringValue = ""
        let failedLoad = startupRequests.begin()
        completeSavedPasswordLoad(.failure(NSError(domain:"Startup fixture",code:1)),store:store,request:failedLoad,reconnectAfterLoad:false) { completions += 1 }
        check(password.stringValue.isEmpty && completions == 1 && !window.isVisible, "Failed credential load must stop startup without revealing a window.")
        let quitLoad = startupRequests.begin();terminationRequest = UUID()
        completeSavedPasswordLoad(.success("obsolete"),store:store,request:quitLoad,reconnectAfterLoad:false) { completions += 1 }
        check(password.stringValue.isEmpty && completions == 1, "Termination must refuse an outstanding credential/startup completion.")
        terminationRequest = nil;remember.state = oldRemember
        AppRuntime.configuration.handOverToGUI()
        beginSessionFromProfile(serverAddress:nil)
        check(startupHidden && !window.isVisible && !running, "Missing password must not reveal an explicitly hidden GUI start.")
        if let root = AppRuntime.configuration.root {
            let file = root.appendingPathComponent("settings.plist")
            do {
                let before = try Data(contentsOf:file)
                try FileManager.default.removeItem(at:file);try FileManager.default.createDirectory(at:file,withIntermediateDirectories:false)
                _ = prepareStartupSelection()
                check(startupPlan == nil && !running, "Failed startup peer save must not leave an accepted plan or start a session.")
                try FileManager.default.removeItem(at:file);try before.write(to:file)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            } catch { failures.append("Isolated startup storage fixture: " + error.localizedDescription) }
        }
        print("Headless startup owner assertions: \(assertions).")
        return failures
    }
    #endif

    private func beginSessionFromProfile(serverAddress: String?) {
        guard terminationRequest == nil else { return }
        guard !profileModalActive,!chooseProfileAfterStop,recentProfileAfterStop == nil,profileStopDispatch == nil else {
            announce("Finish the current profile choice before choosing Start.");return
        }
        if let removal=browserProfileRemoval {
            removal.cancel();announce("Profile deletion is still finishing. Choose Start again after cleanup.");return
        }
        startupRequests.invalidate()
        jam.retireServerNotice()
        if running {
            if let serverAddress { session.connectServer(serverAddress) }
            return
        }
        guard start.isEnabled else {
            if serverAddress != nil {
                jam.showConnectionStatus("RemSound is already starting. Wait for it to finish, then choose Connect.")
            }
            return
        }
        if headlessPermissionIssue() != nil { return }
        guard !password.stringValue.isEmpty else {
            recordStartup("Start requested without a password.")
            if serverAddress != nil {
                jam.showConnectionStatus("Enter the shared password on Connectivity, then choose Connect again. The server only lists people using that password.")
            } else { announce("Enter the shared password.") }
            if AppRuntime.configuration.isHeadless || startupHidden { return }
            showWindow()
            window.makeFirstResponder(password)
            return
        }
        let observation = beginUIObservation(.startSession, matches: { $0.running })
        var synchronousFailure = false
        defer {
            uiObservations.handlerReturned(observation)
            if synchronousFailure { uiObservations.finish(observation, outcome: .failed) }
        }
        recordStartup("Starting session with saved or entered password.")
        start.isEnabled = false
        statusStart.isEnabled = false
        if remember.state == .on {
            do { try passwordStore.save(password.stringValue) }
            catch {
                start.isEnabled = true
                statusStart.isEnabled = true
                synchronousFailure = true
                pendingUIEffects.removeValue(forKey: .startSession)
                let message = "Could not remember password in Mac Keychain. \(error.localizedDescription) Uncheck Remember password to start without saving it."
                if serverAddress != nil { jam.showConnectionStatus(message) }
                else { announce(message) }
                return
            }
        }
        let startRequest = UUID()
        sessionStartRequest = startRequest
        routerControls?.beginStart(startRequest)
        let begin = { [weak self] in
            guard let self, self.sessionStartRequest == startRequest,
                self.terminationRequest == nil else { return }
            #if DEBUG
            if AppRuntime.configuration.isIsolated, let probe = self.browserStartSubmissionProbe {
                self.sessionStartRequest = nil; probe(); return
            }
            #endif
            self.sessionStartRequest = nil
            AppRuntime.settings.set(self.name.stringValue, forKey: "displayName")
            AppRuntime.settings.set(self.peer.stringValue, forKey: "peerAddress")
            self.saveAudioOptions()
            let keyRequest = self.pushToTalkInput?.beginRequest(settings: self.pushToTalkSettings)
            self.pushToTalkSubmittedStartRequest = startRequest
            self.session.start(
                password: self.password.stringValue, peerAddress: self.peer.stringValue,
                savedPeerAddresses: AppRuntime.settings.stringArray(forKey: "selectedPeerAddresses") ?? [],
                lockPeerAddresses: AppRuntime.settings.bool(forKey: "lockPeerAddresses"),
                send: self.send.state == .on, receive: self.receive.state == .on,
                monitorInApp: self.monitor.state == .on,
                plugins: self.plugins.state == .on, name: self.name.stringValue,
                systemAudio: self.systemAudio.state == .on,
                inputDeviceUIDs: self.selectedInputUIDs,
                inputChannelPairs: self.selectedInputChannelPairs,
                outputDeviceUIDs: self.selectedOutputUIDs,
                outputChannelPairs: self.selectedOutputChannelPairs,
                systemCaptureDeviceUIDs: self.selectedCaptureUIDs,
                systemCaptureChannelPairs: self.selectedCaptureChannelPairs,
                sendCodec: self.selectedSendCodec(), sendPacketSize: self.selectedSendPacketSize(),
                receiveJitterMs: self.selectedReceiveJitterMs(), receiveSmoothness: self.selectedReceiveSmoothness(),
                receiveArtifact: self.selectedReceiveArtifact(),
                receiveAutoTune: self.receiveAutoTune.state == .on,
                receiveAutoTuneInterval: self.selectedAutoTuneInterval(),
                receiveLowestDelay: self.receiveLowestDelay.state == .on,
                peerMixes: self.peerMixes, peerAliases: self.peerAliases,
                serverAddress: serverAddress,
                profileServer: serverAddress == nil && self.activeProfile?.serverConnectOnStart == true
                    ? self.activeProfile?.server : nil,
                pushToTalk: self.pushToTalkSettings,
                networkCompletion: { [weak self] binding in self?.completeRouterStart(startRequest, binding: binding) }, completion: { [weak self] receipt in
                    self?.completePushToTalkStart(startRequest, keyRequest: keyRequest, receipt: receipt)
                })
            self.announce("Starting RemSound.")
        }
        if let serverAddress {
            jam.showConnectionStatus("Starting RemSound to connect to \(serverAddress). Existing selected peers remain active.")
        }
        let admitted = browserListener.beforeAudioStart(startRequest) { [weak self] prepared in
            guard let self, self.sessionStartRequest == startRequest, self.terminationRequest == nil else { return }
            guard prepared else {
                self.sessionStartRequest = nil; self.start.isEnabled = true; self.statusStart.isEnabled = true
                self.uiObservations.finish(observation, outcome: .failed)
                self.announce("The browser listener did not close properly, so RemSound has not started. Choose Start again.")
                return
            }
            self.ensureMicrophoneAccess { [weak self] allowed in
                guard let self, self.sessionStartRequest == startRequest, self.terminationRequest == nil else { return }
                if !allowed { self.handleDeniedMicrophoneAccess() }
                self.ensureSystemAudioAccess { available in
                    if !available && self.systemAudio.state == .on {
                        self.announce("System audio access could not be verified. Check System Settings, Privacy and Security, Screen and System Audio Recording if capture is silent.")
                    }
                    begin()
                }
            }
        }
        if !admitted {
            sessionStartRequest = nil; start.isEnabled = true; statusStart.isEnabled = true
            uiObservations.finish(observation, outcome: .failed)
            announce("Browser listener is unavailable after shutdown. Restart RemSound before starting a new connection.")
        }
    }
    #if DEBUG
    private func headlessRouterCheckFailures() -> [String] {
        @MainActor final class Lease: RouterMappingLease {
            var externalAddress: String? = "203.0.113.7", externalPort: UInt16 = 49321
            var validFor: TimeInterval = 3600
            var removals: [(Result<Void, Error>) -> Void] = []
            func renew(_ completion: @escaping (Result<TimeInterval, Error>) -> Void) -> () -> Void { completion(.success(3600)); return {} }
            func remove(_ completion: @escaping (Result<Void, Error>) -> Void) { removals.append(completion) }
        }
        @MainActor final class Backend: RouterMappingBackend {
            var ports: [UInt16] = [], replies: [(Result<RouterMappingLease?, Error>) -> Void] = []
            var terminal: [(Result<Void, Error>) -> Void] = []
            func open(port: UInt16, leaseSeconds: Int, completion: @escaping (Result<RouterMappingLease?, Error>) -> Void) -> () -> Void {
                ports.append(port); replies.append(completion); return {}
            }
            func shutdown(_ completion: @escaping (Result<Void, Error>) -> Void) { terminal.append(completion) }
        }
        var failures: [String] = [], assertions = 0
        func check(_ success: Bool, _ message: String) { assertions += 1; if !success { failures.append(message) } }
        guard let original = routerControls, let root = AppRuntime.configuration.root else { return ["Actual root router row missing."] }
        check(original.view.superview != nil, "Actual Connectivity row must be attached.")
        check(original.checkbox.nextValidKeyView === original.status, "Actual native Tab must reach router status.")
        check(original.status.previousValidKeyView === original.checkbox, "Actual Shift-Tab must return to router choice.")
        check(original.status.accessibilityLabel() == "Router port mapping status", "Actual status name must be useful.")
        original.shutdown()
        let backend = Backend(); var factories = 0, ticks: [() -> Void] = [], wakes: [() -> Void] = [], tickStops = 0, wakeStops = 0
        let c = RouterMappingControls(configuration: AppRuntime.configuration, allowed: { true }, clock: { 0 },
            makeBackend: { factories += 1; return backend },
            schedule: { ticks.append($0); return { tickStops += 1 } },
            watchWake: { wakes.append($0); return { wakeStops += 1 } })
        routerControls = c
        let parent = original.view.superview as? NSStackView
        parent?.removeArrangedSubview(original.view); original.view.removeFromSuperview(); parent?.addArrangedSubview(c.view)
        c.checkbox.nextKeyView = c.status; c.status.nextKeyView = c.checkbox
        let dirty = hasUnsavedProfileChanges
        c.checkbox.performClick(nil)
        check(c.enabled && AppRuntime.settings.bool(forKey: RouterMappingControls.settingKey), "Actual checkbox action must persist explicit opt-in.")
        check(hasUnsavedProfileChanges == dirty, "Machine choice must not dirty the profile.")
        check(factories == 0 && ticks.isEmpty && wakes.isEmpty, "Stopped root must not construct router resources.")
        let request = UUID(), binding = SessionNetworkBinding(port: 49123, generation: UUID())
        c.beginStart(request); c.observe(running: true, binding: binding)
        completeRouterStart(UUID(), binding: binding)
        check(factories == 0, "Old root receipt must not open current binding.")
        completeRouterStart(request, binding: binding)
        check(backend.ports == [49123], "Actual root receipt must open only the acknowledged port.")
        check(ticks.count == 1 && wakes.count == 1, "Acknowledged root owns exact tick and wake resources.")
        let lease = Lease(); backend.replies.first?(.success(lease))
        check(c.status.string.contains("49321"), "Actual status must report granted external port.")
        let file = root.appendingPathComponent("settings.plist")
        do {
            let bytes = try Data(contentsOf: file)
            try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            c.checkbox.performClick(nil)
            check(c.enabled && c.checkbox.state == .on, "Actual failed write must restore choice.")
            check(lease.removals.isEmpty && tickStops == 0, "Failed write must preserve actual live mapping and driver.")
            check(c.status.string.contains("Could not save"), "Failed write must be readable.")
            check(window.firstResponder === c.status, "Write error must focus native readable status.")
            try FileManager.default.removeItem(at: file); try bytes.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { failures.append("Isolated storage gate: " + error.localizedDescription) }
        stopSession()
        check(lease.removals.count == 1 && tickStops == 1 && wakeStops == 1, "Actual Stop must immediately retire router before worker Stop.")
        ticks.first?(); wakes.first?(); check(backend.ports.count == 1, "Retired product callbacks must not open again.")
        lease.removals.first?(.success(()))
        let next = UUID(), nextBinding = SessionNetworkBinding(port: 49124, generation: UUID())
        c.beginStart(next); c.observe(running: true, binding: nextBinding); completeRouterStart(next, binding: nextBinding)
        check(backend.ports == [49123, 49124] && factories == 1, "Root replacement must retain one backend.")
        backend.replies.last?(.success(nil)); suspendPushToTalkForProfileChange()
        check(tickStops == 2 && wakeStops == 2, "Actual profile transition must retire exact router drivers.")
        check(c.enabled && AppRuntime.settings.bool(forKey: RouterMappingControls.settingKey), "Profile retirement preserves machine opt-in.")
        let profile = profileSnapshot(id: UUID(), title: "Router fixture", readOnly: false)
        do {
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any]
            check(json?[RouterMappingControls.settingKey] == nil, "Profile serialization must exclude machine router choice.")
            try profileStore.save(profile)
            _ = try profileStore.load(id: profile.id)
            check(AppRuntime.settings.bool(forKey: RouterMappingControls.settingKey), "Profile save/load must not replace machine choice.")
        } catch { failures.append("Isolated profile gate: " + error.localizedDescription) }
        resetToBlankProfile(); check(c.enabled && AppRuntime.settings.bool(forKey: RouterMappingControls.settingKey), "Actual New reset owner preserves machine router choice.")
        let finalRequest = UUID(), finalBinding = SessionNetworkBinding(port: 49125, generation: UUID())
        c.beginStart(finalRequest); c.observe(running: true, binding: finalBinding); completeRouterStart(finalRequest, binding: finalBinding)
        let finalLease = Lease(); backend.replies.last?(.success(finalLease))
        let quitting = UUID(); terminationRequest = quitting; var finished = false
        shutdownRouterThenSession(quitting) { if case .success = $0 { finished = true } }
        let browserLimit = Date().addingTimeInterval(2)
        while finalLease.removals.isEmpty && Date() < browserLimit { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        check(!finished && finalLease.removals.count == 1, "Actual termination chain must await browser then router removal.")
        backend.terminal.first?(.success(())); check(!finished, "Backend receipt cannot skip exact deletion.")
        finalLease.removals.first?(.success(()))
        let limit = Date().addingTimeInterval(2)
        while !finished && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        check(finished, "Actual termination chain must complete Session cleanup after router proof.")
        check(tickStops == 3 && wakeStops == 3, "Termination removes exact wake and timer resources.")
        terminationRequest = nil
        check(!window.isVisible && !running, "Router root gate must remain hidden and audio stopped.")
        print("Headless router owner assertions: \(assertions).")
        return failures
    }
    #endif

    #if DEBUG
    private func headlessBrowserProfileFailures() -> [String] {
        guard AppRuntime.configuration.isIsolated, !running, !window.isVisible,
              (try? profileStore.list().isEmpty) == true else { return ["Browser profile fixture requires empty hidden stopped isolation."] }
        var failures = [String](), assertions = 0
        func check(_ condition: Bool, _ text: String) { assertions += 1; if !condition { failures.append(text) } }
        func pump(_ finished: () -> Bool) {
            let end = Date().addingTimeInterval(3)
            while !finished() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        }
        remember.state = .off
        do {
            let account = UUID().uuidString
            let audioStore = AppRuntime.passwordStore(account: account), browserStore = AppRuntime.passwordStore(account: account, role: .browser)
            try audioStore.save("synthetic audio role")
            check(try browserStore.load() == nil && audioStore !== browserStore, "Actual AppRuntime browser role must never borrow the audio password.")
            try browserStore.save("synthetic browser role"); try browserStore.delete()
            check(try audioStore.load() == "synthetic audio role", "Deleting the actual browser role must preserve audio memory.")
            browserOptions = .init(enabled: true, autoStart: true)
            let preview = profileSnapshot(id: UUID(), title: "Browser", readOnly: false)
            check(preview.browserListenerEnabled && preview.browserListenerAutoStart, "Actual profile snapshot must carry both browser choices.")
            pump {browserListener.profilePersistenceRetired};try persistProfileAs("Browser source")
            guard let original = activeProfile else { return ["Missing saved browser fixture profile."] }
            check(original.browserListenerEnabled && original.browserListenerAutoStart, "Actual Save As must preserve browser choices.")
            check(!hasUnsavedProfileChanges, "Saved browser choices must leave a clean actual profile.")
            browserOptions = .init(autoStart: true)
            check(hasUnsavedProfileChanges, "Actual browser choice changes must dirty a writable profile.")
            try persistCurrentProfile()
            let saved = try profileStore.load(id: original.id)
            check(!saved.browserListenerEnabled && saved.browserListenerAutoStart, "Current save must preserve independent autoStart when disabled.")
            browserOptions = .init(enabled: true)
            showProfile(saved, loadPassword: false)
            check(browserOptions == .init(autoStart: true), "Actual profile loading must restore browser choices without a password query.")
            check(!hasUnsavedProfileChanges, "Loaded browser profile must remain clean.")
            pump {browserListener.profilePersistenceRetired};try persistProfileLock(true)
            let locked = try profileStore.load(id: original.id)
            browserOptions = .init(enabled: true)
            check(!hasUnsavedProfileChanges, "Read-only browser edits follow the existing temporary-choice dirty policy.")
            try persistProfileAs("Browser copy")
            guard let copy = activeProfile else { return ["Missing browser Save As copy."] }
            check(copy.id != locked.id && !copy.readOnly && copy.browserListenerEnabled && !copy.browserListenerAutoStart, "Read-only Save As must copy current browser choices into a separate writable profile.")
            check(try profileStore.load(id: locked.id) == locked, "Save As must leave the locked source profile exact.")
            resetToBlankProfile()
            check(browserOptions == .init(), "Actual New profile must clear both browser choices.")
            let blank = profileSnapshot(id: UUID(), title: "Blank", readOnly: false)
            check(!blank.browserListenerEnabled && !blank.browserListenerAutoStart, "Blank snapshot must keep browser choices off.")
            showProfile(copy, loadPassword: false)
            check(browserOptions == .init(enabled: true), "Reopening the copied profile must restore its independent flags.")
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(copy)) as? [String: Any]
            check(object?.keys.filter { $0.lowercased().contains("password") }.isEmpty == true, "Browser profile persistence must contain no password field.")
            check(!running && !window.isVisible && browserListener.currentVisitTicket == nil, "Profile flags must never activate a stopped browser listener.")
        } catch { failures.append("Isolated browser profile fixture persistence failed.") }
        failures += headlessBrowserWindowFailures()
        failures += headlessBrowserRemovalFactoryFailures()
        failures += headlessBrowserTransactionFailures()
        var browserClosed = false, sessionClosed = false
        check(browserListener.shutdown { if case .success = $0 { browserClosed = true } }, "Browser profile fixture shutdown must be admitted.")
        pump { browserClosed }; check(browserClosed, "Browser profile fixture must await actual source/Room/callback retirement.")
        session.shutdown { sessionClosed = true }; pump { sessionClosed }
        check(sessionClosed, "Browser profile fixture must independently await actual stopped Session cleanup.")
        print("Headless browser profile assertions: \(assertions).")
        return failures
    }
    private func headlessBrowserConfirmedRemovalFailures()->[String] {
        guard AppRuntime.configuration.isIsolated,!running,!window.isVisible,(try? profileStore.list().isEmpty)==true else {return ["Removal fixture requires empty hidden stopped isolation."]}
        var failures=[String](),assertions=0
        func check(_ ok:Bool,_ text:String) {assertions += 1;if !ok {failures.append(text)}}
        func pump(_ done:()->Bool) {let end=Date().addingTimeInterval(3);while !done() && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.001))}}
        var queue=[@Sendable ()->Void]()
        do {
            remember.state = .off;pump {browserListener.profilePersistenceRetired};try persistProfileAs("Removal neighbour")
            guard let neighbour=activeProfile else {return ["Missing neighbour profile."]}
            let neighbourBrowser=AppRuntime.passwordStore(account:neighbour.id.uuidString,role:.browser),neighbourAudio=AppRuntime.passwordStore(account:neighbour.id.uuidString,role:.audio)
            try neighbourBrowser.save("synthetic neighbour browser");try neighbourAudio.save("synthetic neighbour audio")
            try persistProfileAs("Confirmed readonly removal")
            guard var profile=activeProfile else {return ["Missing removal profile."]}
            let browser=AppRuntime.passwordStore(account:profile.id.uuidString,role:.browser),audio=AppRuntime.passwordStore(account:profile.id.uuidString,role:.audio)
            try browser.save("synthetic opened browser");try audio.save("synthetic connection password")
            browserCredentialExecutor={queue.append($0)}
            var opened=false;pump {if !opened {opened=openBrowserListenerWindow(present:false)};return opened}
            pump {!queue.isEmpty};if !queue.isEmpty {queue.removeFirst()()}
            pump {browserListenerWindow != nil};guard let controller=browserListenerWindow else {return failures+["Missing hidden browser window."]}
            check(controller.password.stringValue=="synthetic opened browser","Actual removal fixture must begin with its shown browser value.")
            controller.password.stringValue="synthetic revoked pending save";controller.acceptPressed();pump {!queue.isEmpty}
            check(queue.count==1 && controller.edit.busy,"Actual prompt fixture must first own a pending browser credential save.")
            check(!retireBrowserBeforeProfilePrompt(),"Pending profile action must revoke and refuse before a modal prompt.")
            check(controller.password.stringValue.isEmpty && !window.isVisible,"Pending profile prompts must clear shown browser credentials synchronously.")
            if !queue.isEmpty {queue.removeFirst()()}
            pump {browserProfileTransaction==nil && browserListener.profileContextRetired}
            check(try browser.load()=="synthetic opened browser","Prompt revocation before utility borrowing must preserve the opened credential.")
            check(retireBrowserBeforeProfilePrompt(),"A new explicit profile action may proceed after exact retirement.")
            try persistProfileLock(true);if let locked=activeProfile {profile=locked}
            browserCredentialExecutor={queue.append($0)}
            var result:BrowserProfileRemoval.Outcome?
            check(startConfirmedProfileRemoval(profile) {result=$0},"Confirmed saved readonly removal must use its separate purpose.")
            check(!startConfirmedProfileRemoval(profile),"Actual Root must refuse a second profile deletion.")
            pump {!queue.isEmpty || result != nil};check(queue.count==1 && result==nil,"Actual Root must retain one queued deletion job.")
            check(try profileStore.load(id:profile.id)==profile && browser.load()=="synthetic opened browser" && audio.load()=="synthetic connection password","Removal admission must preserve file and both credential roles.")
            newProfile();openProfile();saveProfileAs();renameProfile();deleteProfile();switchToRecentProfile(neighbour.id)
            check(activeProfile==profile && queue.count==1 && !window.isVisible,"Actual pending profile selectors must refuse before prompting or replacing the account.")
            for request in [ControlRequest(action:"profile-new"),ControlRequest(action:"profile-open",arguments:["value":neighbour.id.uuidString])] {
                if let command=try? ControlCommand(request) {
                    check(performControlCommand(command,request:request).status == .waiting,"Pending profile control must report waiting, never acknowledge an unperformed selection.")
                } else {failures.append("Missing existing profile control command.")}
            }
            do {try persistProfileAs("Forbidden pending replacement");failures.append("Direct Save As must refuse while deletion owns raw work.")} catch {}
            check(try profileStore.list().count==2,"Refused Save As must leave no extra profile file.")
            if !queue.isEmpty {queue.removeFirst()()};check(try profileStore.load(id:profile.id)==profile,"Raw store return alone cannot delete the actual profile file.")
            pump {result != nil};check(result == .removed && activeProfile==nil,"Completed exact removal must reset the actual Root to an unsaved profile.")
            check(try profileStore.list().map(\.id)==[neighbour.id],"Only the confirmed profile file may be removed.")
            check(try browser.load()==nil && audio.load()==nil,"Actual Root removal must delete both sealed profile credential roles.")
            check(try neighbourBrowser.load()=="synthetic neighbour browser" && neighbourAudio.load()=="synthetic neighbour audio","Neighbour credentials must remain exact.")
            check(try profileStore.load(id:neighbour.id)==neighbour,"Neighbour profile must remain exact.")
            pump {browserListener.profileContextRetired};try persistProfileAs("Failed removal")
            guard let failed=activeProfile else {return failures+["Missing failure profile."]}
            let failedBrowser=AppRuntime.passwordStore(account:failed.id.uuidString,role:.browser),failedAudio=AppRuntime.passwordStore(account:failed.id.uuidString,role:.audio)
            try failedBrowser.save("synthetic failure browser");try failedAudio.save("synthetic failure audio")
            var revised=failed;revised.title="Externally revised removal fixture"
            browserRemovalFileProbe={_ in try self.profileStore.save(revised)};result=nil
            check(startConfirmedProfileRemoval(failed) {result=$0},"Actual file-failure removal must be admitted once.")
            pump {!queue.isEmpty};if !queue.isEmpty {queue.removeFirst()()};pump {result != nil}
            check(result == .failed && activeProfile==failed,"Actual profile file failure must not claim complete deletion or reset the Root.")
            check(try profileStore.load(id:failed.id)==revised,"Actual removal must preserve a profile file revised after confirmation.")
            check(try failedBrowser.load()==nil && failedAudio.load()==nil,"File failure must truthfully retain earlier credential deletion effects.")
            browserRemovalFileProbe=nil;try profileStore.save(failed);try failedBrowser.save("synthetic cancelled browser");try failedAudio.save("synthetic cancelled audio");result=nil
            check(startConfirmedProfileRemoval(failed) {result=$0},"Explicit retry may own one fresh removal after failure.")
            pump {!queue.isEmpty};check(queue.count==1,"Actual shutdown fixture must own a queued credential job.")
            var starts=0;password.stringValue="synthetic refused Start";browserStartSubmissionProbe={starts += 1}
            beginSessionFromProfile(serverAddress:nil)
            check(starts==0 && sessionStartRequest==nil && browserProfileRemoval != nil,"Actual Start must cancel deletion and refuse before password saving, permissions or Session submission.")
            var browserClosed=false,sessionClosed=false
            shutdownBrowserProfile {value in if case .success=value {browserClosed=true}}
            RunLoop.main.run(until:Date().addingTimeInterval(0.02));check(!browserClosed && browserProfileRemoval != nil,"Actual Root shutdown must join its admitted deletion operation.")
            if !queue.isEmpty {queue.removeFirst()()};pump {browserClosed}
            check(browserClosed && result == .cancelled && browserProfileRemoval==nil,"Actual full shutdown must wait cancellation/raw/main deletion retirement.")
            check(try failedBrowser.load()=="synthetic cancelled browser" && failedAudio.load()=="synthetic cancelled audio","Cancelled queued removal must borrow neither actual credential role.")
            check(try profileStore.load(id:failed.id)==failed,"Cancelled shutdown removal must preserve its profile file.")
            session.shutdown {sessionClosed=true};pump {sessionClosed};check(sessionClosed,"Actual removal fixture independently waits stopped Session cleanup.")
            check(!running && !window.isVisible && browserListenerWindow==nil,"Actual deletion fixtures must remain hidden and stopped.")
        } catch {failures.append("Isolated actual profile removal fixture failed.")}
        browserCredentialExecutor=nil;browserRemovalFileProbe=nil;browserStartSubmissionProbe=nil
        print("Headless browser confirmed removal assertions: \(assertions).")
        return failures
    }
    private func headlessBrowserStagedFailures()->[String] {
        guard AppRuntime.configuration.isIsolated,!running,!window.isVisible,(try? profileStore.list().isEmpty)==true else {return ["Staged fixture requires empty hidden stopped isolation."]}
        var failures=[String](),assertions=0
        func check(_ ok:Bool,_ text:String) {assertions += 1;if !ok {failures.append(text)}}
        func pump(_ done:()->Bool) {let end=Date().addingTimeInterval(3);while !done() && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.001))}}
        do {
            pump {browserListener.profilePersistenceRetired};remember.state = .off;try persistProfileAs("Staged UI profile")
            guard let profile=activeProfile else {return ["Missing staged profile."]}
            let store=AppRuntime.passwordStore(account:profile.id.uuidString,role:.browser)
            try store.save("synthetic staged opened")
            // This changes only Root/owner observation values, not Session state
            // or an accepted root/worker/native visit. No Session.start is called.
            running=true;let worker=UUID();browserListener.observe(running:true,binding:nil,workerGeneration:worker)
            let admitted=openBrowserListenerWindow(present:false)
            check(admitted,"Running observation without a browser visit must still admit configuration-only editing.")
            if admitted {pump {browserListenerWindow != nil}}
            if let c=browserListenerWindow {
                check(c.addressModel === browserProfileTransaction?.address && c.addressModel != nil,"Actual Root opener must adopt the transaction's scoped address model.")
                check(c.addressResult.stringValue.contains("staged") && c.addressValue.stringValue.isEmpty,"Configuration-only Root must show an unavailable staged address, not guess one.")
                check(!c.turnOnButton.isEnabled && !c.copyAddressButton.isEnabled,"Staged Root must not admit address query or copy.")
                c.refreshAddressPressed();c.copyAddressPressed()
                check(c.addressValue.stringValue.isEmpty && browserListener.currentVisitTicket==nil,"Explicit staged address actions must not invent a native visit or URL.")
                check(c.scopeNote.stringValue.contains("staged") && !c.scopeNote.stringValue.contains("session is stopped"),"Running configuration-only scope must not claim that audio stopped or native listening is available.")
                check(browserProfileTransaction?.ticket.isRunning==false && browserListener.currentVisitTicket==nil,"Actual Root must not invent an accepted native visit for staged editing.")
                check(c.password.stringValue=="synthetic staged opened","Explicit staged open loads only the current dedicated browser account.")
                browserListener.observe(running:true,binding:nil,workerGeneration:worker)
                check(!c.edit.contextInvalidated,"An identical running observation must preserve the exact Root transaction.")
                c.password.stringValue="synthetic staged saved";c.enable.state = .on;c.autoStart.state = .on;c.acceptPressed();pump {c.edit.finished}
                check(c.edit.finished && browserProfileTransaction==nil,"Actual staged acceptance waits preview, credential and Main receipts.")
                check(try store.load()=="synthetic staged saved" && browserOptions == .init(enabled:true,autoStart:true),"Staged acceptance keeps the actual credential and profile flags.")
                check(browserEffectiveChoice?.choice == .empty && browserListener.currentVisitTicket==nil,"Staged persistence cannot be cached as listening.")
                check(openBrowserListenerWindow(present:false),"Explicit staged reopen must use the same persistent owner.")
                pump {browserListenerWindow != nil}
                if let cancelled=browserListenerWindow {
                    cancelled.password.stringValue="synthetic staged discarded";cancelled.commitPassword();cancelled.cancelPressed();pump {cancelled.edit.finished}
                    check(try store.load()=="synthetic staged saved","Staged Cancel must restore the opened dedicated credential.")
                    check(browserOptions == .init(enabled:true,autoStart:true),"Staged Cancel must restore the opened profile flags.")
                }
                check(openBrowserListenerWindow(present:false),"A current staged visit may reopen explicitly before observation changes.")
                pump {browserListenerWindow != nil}
                let lost=browserListenerWindow
                browserListener.observe(running:true,binding:nil,workerGeneration:UUID())
                check(lost?.password.stringValue.isEmpty==true,"Worker observation loss must clear the actual shown password synchronously.")
                pump {browserProfileTransaction==nil}
            }
            running=false;browserListener.observe(running:false,binding:nil,workerGeneration:nil)
            var closed=false,sessionClosed=false;shutdownBrowserProfile {if case .success=$0 {closed=true}};pump {closed}
            session.shutdown {sessionClosed=true};pump {sessionClosed}
            check(closed && sessionClosed && !window.isVisible,"Staged UI fixture waits independent full browser and stopped Session cleanup without presenting a window.")
        } catch {failures.append("Isolated staged Root fixture failed.")}
        running=false;print("Headless browser staged assertions: \(assertions).")
        return failures
    }
    private func headlessProfileActionFailures()->[String] {
        guard AppRuntime.configuration.isIsolated,!running,!window.isVisible,(try? profileStore.list().isEmpty)==true else {return ["Profile action fixture requires empty hidden stopped isolation."]}
        var failures=[String](),assertions=0
        func check(_ ok:Bool,_ message:String) {assertions += 1;if !ok {failures.append(message)}}
        func pump(_ done:()->Bool) {let end=Date().addingTimeInterval(3);while !done() && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.001))}}
        func restore(_ profile:ConnectionProfile) throws {
            profileModalProbe=nil;pump {browserListener.profilePersistenceRetired && browserProfileTransaction==nil}
            try profileStore.save(profile);showProfile(profile,loadPassword:false)
            pump {browserListener.profilePersistenceRetired};browserProfilePromptRetiring=false
        }
        do {
            remember.state = .off;pump {browserListener.profilePersistenceRetired}
            check(browserListener.profilePersistenceRetired,"Profile action fixture must await initial stopped-source retirement.")
            let initialVolume=jam.volume
            profileModalProbe={alert in
                (alert.accessoryView as? NSTextField)?.stringValue="Forbidden unowned form copy"
                if let other=JamController.volumes.first(where:{$0 != self.jam.volume}) {_ = self.jam.setVolume(other)}
                return .alertFirstButtonReturn
            }
            saveProfileAs()
            check(activeProfile==nil && (try? profileStore.list().isEmpty)==true,"A modal with no saved or draft account must still reject changed form values.")
            if let unintended=activeProfile {
                resetToBlankProfile();pump {browserListener.profilePersistenceRetired};try profileStore.delete(id:unintended.id)
            }
            profileModalProbe=nil;_ = jam.setVolume(initialVolume)
            try persistProfileAs("Action source");guard let base=activeProfile else {return ["Missing action source."]}
            pump {browserListener.profilePersistenceRetired}
            profileModalProbe={[weak self] alert in
                (alert.accessoryView as? NSTextField)?.stringValue="Forbidden stale copy"
                self?.invalidateBrowserProfileEditing();return .alertFirstButtonReturn
            }
            saveProfileAs()
            check(activeProfile==base && (try? profileStore.list().count)==1,"Stale Save As must not create a file or replace the current profile.")
            let unintended=activeProfile;try restore(base)
            if let unintended,unintended.id != base.id {try profileStore.delete(id:unintended.id)}

            let audio=AppRuntime.passwordStore(account:base.id.uuidString)
            try audio.save("synthetic explicitly forgotten audio");password.stringValue="synthetic forgotten field"
            profileModalProbe={[weak self] alert in
                (alert.accessoryView as? NSTextField)?.stringValue="Forbidden copy after forget"
                self?.forgetSavedPassword();return .alertFirstButtonReturn
            }
            saveProfileAs()
            check(activeProfile==base && (try? audio.load())==nil && password.stringValue.isEmpty,"Explicit audio-password forgetting must invalidate a pending profile choice without retaining its value.")
            let forgottenCopy=activeProfile;try restore(base)
            if let forgottenCopy,forgottenCopy.id != base.id {try profileStore.delete(id:forgottenCopy.id)}

            var revised=base;revised.title="Externally revised action source"
            profileModalProbe={alert in
                (alert.accessoryView as? NSTextField)?.stringValue="Forbidden stale rename"
                try? self.profileStore.save(revised);return .alertFirstButtonReturn
            }
            renameProfile()
            check((try? profileStore.load(id:base.id))==revised,"Rename must preserve a profile file changed while the modal was pending.")
            try restore(base)

            try persistProfileLock(true);guard let locked=activeProfile else {return failures+["Missing locked fixture."]}
            AppRuntime.settings.set(false,forKey:"suppressReadOnlySaveWarning");name.stringValue="Unsaved locked edit"
            profileModalProbe={[weak self] alert in
                (alert.accessoryView as? NSButton)?.state = .on
                self?.browserListener.suspendSource();return .alertFirstButtonReturn
            }
            check(!saveCurrentProfile(),"Stale read-only warning must not authorize saving.")
            check((try? profileStore.load(id:base.id))==locked && !AppRuntime.settings.bool(forKey:"suppressReadOnlySaveWarning"),"Stale warning must preserve both file and warning preference.")
            AppRuntime.settings.set(false,forKey:"suppressReadOnlySaveWarning");try restore(base)

            try persistProfileAs("Action target");guard let target=activeProfile else {return failures+["Missing target fixture."]};try restore(base)
            profileModalProbe={[weak self] alert in
                if alert.messageText.hasPrefix("Save changes") {return .alertSecondButtonReturn}
                guard let picker=alert.accessoryView as? NSPopUpButton,let index=picker.itemTitles.firstIndex(of:target.title) else {return .alertSecondButtonReturn}
                picker.selectItem(at:index);self?.browserListener.suspendSource();return .alertFirstButtonReturn
            }
            openProfile();check(activeProfile==base,"Stale Open choice must not replace the current profile.");try restore(base)

            var interleaved:ControlReply.Status?;var interleavedName:ControlReply.Status?
            profileModalProbe={alert in
                (alert.accessoryView as? NSTextField)?.stringValue="Accepted own copy"
                let request=ControlRequest(action:"profile-rename",arguments:["value":"Forbidden interleaved rename"])
                if let command=try? ControlCommand(request) {interleaved=self.performControlCommand(command,request:request).status}
                let nameRequest=ControlRequest(action:"name",arguments:["value":"Forbidden interleaved form value"])
                if let command=try? ControlCommand(nameRequest) {interleavedName=self.performControlCommand(command,request:nameRequest).status}
                return .alertFirstButtonReturn
            }
            saveProfileAs();check(interleaved == .waiting,"A modal profile action must refuse concurrent profile control mutation.")
            check((try? profileStore.load(id:base.id))==base,"Concurrent control refusal must preserve the source file.")
            check(interleavedName == .waiting,"A modal profile action must refuse concurrent form control mutation.")
            check(name.stringValue==base.displayName,"Refused concurrent form control must preserve the source form.")
            let accepted=activeProfile;check(accepted?.title=="Accepted own copy","The original current modal may still keep its own accepted Save As.")
            try restore(base);if let accepted,accepted.id != base.id {try profileStore.delete(id:accepted.id)}

            resetToBlankProfile();pump {browserListener.profilePersistenceRetired};name.stringValue="Edited draft"
            var nested=0
            profileModalProbe={alert in
                if alert.messageText=="Save Profile As" {(alert.accessoryView as? NSTextField)?.stringValue="Nested saved draft";nested += 1}
                return .alertFirstButtonReturn
            }
            newProfile()
            let savedDraft=try profileStore.list().first {$0.title=="Nested saved draft"}
            check(nested==1 && savedDraft != nil && activeProfile==nil,"Unsaved Save must complete its own nested Save As before New continues.")
            pump {browserListener.profilePersistenceRetired};try restore(base);if let savedDraft {try profileStore.delete(id:savedDraft.id)}

            resetToBlankProfile();pump {browserListener.profilePersistenceRetired};name.stringValue="Preserve stale draft"
            profileModalProbe={[weak self] alert in
                if alert.messageText=="Save Profile As" {
                    (alert.accessoryView as? NSTextField)?.stringValue="Forbidden nested copy";self?.invalidateBrowserProfileEditing()
                }
                return .alertFirstButtonReturn
            }
            newProfile();let unwanted=try profileStore.list().first {$0.title=="Forbidden nested copy"}
            check(unwanted==nil && activeProfile==nil && name.stringValue=="Preserve stale draft","Stale nested Save As must cancel the outer New without losing the draft.")
            pump {browserListener.profilePersistenceRetired};try restore(base);if let unwanted {try profileStore.delete(id:unwanted.id)}

            profileModalProbe={_ in .alertSecondButtonReturn};let count=try profileStore.list().count
            saveProfileAs();check(activeProfile==base && (try? profileStore.list().count)==count,"Cancel must preserve actual profile identity and files.")
            profileModalProbe=nil

            // Exercise the Stop-owned Main continuation in stopped isolation;
            // this is a UI ownership fixture, not a running/native binding receipt.
            recentProfileAfterStop=target;sealProfileAfterStop();dispatchProfileAfterStop()
            let dispatch=profileStopDispatch;dispatchProfileAfterStop()
            check(dispatch != nil && profileStopDispatch==dispatch,"Repeated stopped observations must coalesce one profile continuation.")
            let blockedRequest=ControlRequest(action:"profile-rename",arguments:["value":"Forbidden pending selection"])
            let blockedCommand=try ControlCommand(blockedRequest)
            check(performControlCommand(blockedCommand,request:blockedRequest).status == .waiting && !beginBrowserProfileEditing {_ in},"Pending Stop selection must refuse profile control and browser editing across its Main queue gap.")
            var premature=false;do {try persistCurrentProfile()} catch {premature=true}
            check(premature && activeProfile==base,"Direct profile persistence must not consume a pending Stop selection.")
            pump {profileStopDispatch==nil};pump {browserListener.profilePersistenceRetired}
            check(activeProfile?.id==target.id && recentProfileAfterStop==nil,"Current Stop continuation must apply its one exact saved target.")
            let appliedRevision=browserProfileRevision;dispatchProfileAfterStop()
            check(browserProfileRevision==appliedRevision,"Repeated stopped observations must not reapply a consumed selection.")
            try restore(base)

            recentProfileAfterStop=target;sealProfileAfterStop();dispatchProfileAfterStop()
            invalidateBrowserProfileEditing();pump {profileStopDispatch==nil}
            check(activeProfile==base && recentProfileAfterStop==nil,"A changed Root revision must discard the queued Stop selection.")
            try restore(base)
            recentProfileAfterStop=target;sealProfileAfterStop();dispatchProfileAfterStop()
            var changedTarget=target;changedTarget.title="Changed pending target";try profileStore.save(changedTarget)
            pump {profileStopDispatch==nil}
            check(activeProfile==base,"A changed target file must not be applied by the queued Stop selection.")
            try profileStore.save(target);try restore(base)
            recentProfileAfterStop=target;sealProfileAfterStop();dispatchProfileAfterStop();stopSession()
            pump {browserListener.profilePersistenceRetired}
            check(activeProfile==base && profileStopDispatch==nil && recentProfileAfterStop==nil,"Explicit Stop must cancel its older pending profile selection.")
            try restore(base)

            var queue=[@Sendable ()->Void]();browserCredentialExecutor={queue.append($0)}
            var admitted=false;pump {if !admitted {admitted=openBrowserListenerWindow(present:false)};return admitted}
            pump {!queue.isEmpty};check(admitted && queue.count==1,"Abandoned action fixture must own one browser credential load.")
            check(!retireBrowserBeforeProfilePrompt(),"A pending browser load must refuse before a profile prompt.")
            if !queue.isEmpty {queue.removeFirst()()};pump {browserProfileTransaction==nil && browserListener.profileContextRetired}
            let reopened=openBrowserListenerWindow(present:false)
            check(reopened,"Explicit browser reopen must reconsider an abandoned prompt after actual cleanup.")
            if !reopened {browserProfilePromptRetiring=false;_ = openBrowserListenerWindow(present:false)}
            pump {!queue.isEmpty};if !queue.isEmpty {queue.removeFirst()()};pump {browserListenerWindow != nil}
            browserListenerWindow?.cancelPressed();pump {browserProfileTransaction==nil};browserCredentialExecutor=nil

            @MainActor final class Backend:BrowserSessionBackend {
                var listenerState:BrowserListenerStatus.State = .off
                var prepares=[(Bool)->Void](),stops=[()->Void](),closes=[()->Void]()
                func prepareStart(_ id:UUID,completion:@escaping(Bool)->Void)->Bool {prepares.append(completion);return true}
                func activate(_ id:UUID,binding:SessionNetworkBinding,options:BrowserListenerOptions,password:String)->Bool {false}
                func activate(_ id:UUID,binding:SessionNetworkBinding,options:BrowserListenerOptions,password:String,completion:@escaping(BrowserListenerActivationResult)->Void)->Bool {false}
                func stop(completion:@escaping()->Void)->Bool {stops.append(completion);return true}
                func shutdown(completion:@escaping()->Void)->Bool {closes.append(completion);return true}
            }
            let original=browserListener,backend=Backend()
            let pending=BrowserSessionOwner(backend:backend);browserListener=pending
            pending.onConfigurationInvalidated={[weak self] in self?.invalidateBrowserProfileEditing()}
            _ = pending.beforeStart(UUID()) {_ in};name.stringValue="Forbidden premature save"
            var refused=false;do {try persistCurrentProfile()} catch {refused=true}
            check(refused && (try? profileStore.load(id:base.id))==base,"Direct profile persistence must wait actual browser retirement.")
            pending.invalidate();backend.prepares.first?(false);pump {backend.stops.count==1};backend.stops.first?();pump {pending.profileContextRetired}
            var mockClosed=false;_ = pending.shutdown {_ in mockClosed=true};backend.closes.first?();pump {mockClosed}
            browserListener=original;try restore(base)

            var browserClosed=false,sessionClosed=false
            shutdownBrowserProfile {if case .success=$0 {browserClosed=true}};pump {browserClosed}
            check(browserClosed,"Profile persistence fixture needs completed permanent browser retirement.")
            name.stringValue="Local save after browser retirement";var kept=true
            do {try persistCurrentProfile()} catch {kept=false}
            check(kept && (try? profileStore.load(id:base.id))?.displayName=="Local save after browser retirement","Completed permanent cleanup must still allow local profile saving in a kept-open App.")
            check(!beginBrowserProfileEditing {_ in},"Permanent cleanup must never reopen browser credential or native authority.")
            session.shutdown {sessionClosed=true};pump {sessionClosed};check(sessionClosed && !running && !window.isVisible,"Profile action fixtures independently close stopped Session without showing a window.")
        } catch {failures.append("Isolated profile action fixture failed.")}
        profileModalProbe=nil;browserCredentialExecutor=nil
        print("Headless profile action assertions: \(assertions).")
        return failures
    }
    private func headlessBrowserWindowFailures() -> [String] {
        guard AppRuntime.configuration.isIsolated, !running, !window.isVisible, let profile=activeProfile else {return ["Root window fixture requires hidden stopped isolation."]}
        var failures=[String](),assertions=0
        func check(_ ok:Bool,_ text:String) {assertions += 1;if !ok {failures.append(text)}}
        func pump(_ done:()->Bool) {let end=Date().addingTimeInterval(3);while !done() && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.001))}}
        func open()->BrowserListenerWindow? {
            var admitted=false;pump {if !admitted {admitted=openBrowserListenerWindow(present:false)};return admitted}
            check(admitted,"Actual Root must admit its hidden browser window opener.")
            guard admitted else {return nil};pump {browserListenerWindow != nil};return browserListenerWindow
        }
        do {
            let store=AppRuntime.passwordStore(account:profile.id.uuidString,role:.browser)
            try store.save("synthetic window opened")
            guard let c=open() else {return failures}
            check(c.edit === browserProfileTransaction?.model,"Actual Root window must adopt the transaction's exact model.")
            check(!window.isVisible && c.window?.isVisible != true && !running,"Actual Root opener fixture must stay hidden and stopped.")
            check(browserListenerButton.target === self && browserListenerButton.action == #selector(showBrowserListener),"Named native button must route through the actual opener.")
            check(browserListenerButton.superview != nil && browserListenerButton.accessibilityLabel()=="Browser listener" && browserListenerButton.accessibilityHelp()?.isEmpty == false,"Root browser button needs a native accessible name, help and layout owner.")
            tabs.selectTabViewItem(at:0);window.makeFirstResponder(browserListenerButton)
            if let key=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:1,windowNumber:0,context:nil,characters:"\t",charactersIgnoringModifiers:"\t",isARepeat:false,keyCode:UInt16(kVK_Tab)) {window.sendEvent(key)}
            check(window.firstResponder === tabs,"Root Connectivity Tab must return from the last button to the section tabs.")
            if let key=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.shift,timestamp:1,windowNumber:0,context:nil,characters:"\t",charactersIgnoringModifiers:"\t",isARepeat:false,keyCode:UInt16(kVK_Tab)) {window.sendEvent(key)}
            check(window.firstResponder === browserListenerButton,"Root Connectivity Shift Tab must reach the browser button through the registered control group.")
            browserListenerButton.performClick(nil)
            check(browserListenerWindow === c,"Repeated actual button action must reuse its existing window without a new credential load.")
            c.password.stringValue="synthetic window saved";c.enable.state = .on;c.acceptPressed();pump {c.edit.finished}
            check(c.edit.finished && browserProfileTransaction==nil && browserListenerWindow==nil,"Window completion must preserve the original Root transaction completion.")
            check(try store.load()=="synthetic window saved","Actual Root adopted window must await its dedicated credential write.")
            guard let cancelled=open() else {return failures};cancelled.password.stringValue="synthetic discarded";cancelled.commitPassword();cancelled.cancelPressed()
            check(cancelled.password.stringValue.isEmpty,"Actual Root Cancel must clear the shown password immediately.")
            pump {cancelled.edit.finished};check(try store.load()=="synthetic window saved","Actual Root Cancel must preserve opened credential persistence.")
            resetToBlankProfile()
            guard let draft=open(),let draftID=draftProfileID else {return failures+["Draft browser window missing."]}
            let draftStore=AppRuntime.passwordStore(account:draftID.uuidString,role:.browser)
            check(draft.scopeNote.stringValue.contains("unsaved profile"),"Draft password lifetime must be explained before editing.")
            draft.password.stringValue="synthetic temporary draft";draft.enable.state = .on;draft.acceptPressed();pump {draft.edit.finished}
            check(draft.edit.finished && browserOptions.enabled,"Unsaved profile must accept temporary browser UI choices.")
            check(try draftStore.load()==nil,"Unsaved draft browser choices must never leave a credential behind.")
            try persistProfileAs("Browser draft lifetime")
            check(activeProfile?.id==draftID,"First Save As must preserve its actual draft identity.")
            check(try draftStore.load()==nil && browserWorkingChoice==nil,"Save As must not silently copy a temporary browser password into storage.")
            guard let saved=open() else {return failures}
            check(saved.password.stringValue.isEmpty,"Saved profile must explicitly acquire its own browser credential.")
            saved.password.stringValue="synthetic saved draft";saved.enable.state = .on;saved.acceptPressed();pump {saved.edit.finished}
            check(try draftStore.load()=="synthetic saved draft","Explicit acceptance in a saved writable profile must persist the browser credential.")
            try persistProfileLock(true)
            guard let readOnly=open() else {return failures};check(readOnly.scopeNote.stringValue.contains("read-only"),"Read-only browser choices must expose their temporary scope.")
            readOnly.password.stringValue="synthetic readonly";readOnly.acceptPressed();pump {readOnly.edit.finished}
            check(try draftStore.load()=="synthetic saved draft","Read-only adopted window must not change stored credentials.")
            guard let lost=open() else {return failures};lost.window?.makeFirstResponder(lost.password);resetToBlankProfile()
            check(lost.password.stringValue.isEmpty && browserListenerWindow==nil && browserWorkingChoice==nil,"External New must clear the actual shown password and Root UI cache synchronously.")
            var queue=[@Sendable ()->Void]();browserCredentialExecutor={queue.append($0)}
            var admitted=false;pump {if !admitted {admitted=openBrowserListenerWindow(present:false)};return admitted}
            check(admitted && queue.count==1 && browserListenerWindow==nil,"Root loading must own exactly one pending credential job before constructing a window.")
            check(!openBrowserListenerWindow(present:false) && queue.count==1,"Repeated pending opens must refuse without another job.")
            resetToBlankProfile();check(browserProfileTransaction != nil && browserWindowRequest==nil,"Context loss must revoke presentation but retain its admitted load credit.")
            if !queue.isEmpty {queue.removeFirst()()};pump {browserProfileTransaction==nil}
            check(browserListenerWindow==nil && browserProfileTransaction==nil,"Late obsolete credential load must never open a replacement window.")
            browserCredentialExecutor=nil;showProfile(profile,loadPassword:false)
        } catch {failures.append("Isolated Root browser window fixture failed.")}
        print("Headless browser window assertions: \(assertions).")
        return failures
    }

    private func headlessBrowserRemovalFactoryFailures() -> [String] {
        guard AppRuntime.configuration.isIsolated, !running, !window.isVisible, let profile=activeProfile else {return ["Removal factory fixture requires hidden stopped isolation."]}
        var failures=[String](),assertions=0
        func check(_ ok:Bool,_ text:String) {assertions += 1;if !ok {failures.append(text)}}
        func pump(_ done:()->Bool) {let end=Date().addingTimeInterval(3);while !done() && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.001))}}
        let account=profile.id, neighbour=UUID(), revision=browserProfileRevision
        let browser=AppRuntime.passwordStore(account:account.uuidString,role:.browser), audio=AppRuntime.passwordStore(account:account.uuidString,role:.audio)
        let otherBrowser=AppRuntime.passwordStore(account:neighbour.uuidString,role:.browser), otherAudio=AppRuntime.passwordStore(account:neighbour.uuidString,role:.audio)
        do {
            try browser.save("synthetic removal browser");try audio.save("synthetic removal audio")
            try otherBrowser.save("synthetic neighbour browser");try otherAudio.save("synthetic neighbour audio")
            var ticket:BrowserSessionOwner.RemovalTicket?, replied=false
            check(browserListener.prepareRemoval(account:account) {ticket=$0;replied=true} != nil,"Actual owner must admit one isolated removal preparation.")
            pump {replied};check(ticket != nil,"Actual removal purpose needs completed Core retirement.")
            guard let ticket else {return failures}
            // The probe verifies the real role/account selector, not Root deletion consent.
            var queue=[@Sendable ()->Void]()
            let access=BrowserCredentialAccess.forRemoval(owner:browserListener,removal:ticket,isCurrent:{[weak self] in self?.activeProfile?.id==account},execute:{queue.append($0)})
            check(access != nil && ticket.account==account,"Actual removal factory must retain its sealed account.")
            check(access?.load {_ in failures.append("Removal must not load.")} == false && access?.save("synthetic refused") {_ in failures.append("Removal must not save.")} == false,"Removal purpose must refuse reading and saving before dispatch.")
            var result:BrowserCredentialAccess.Outcome?
            check(access?.delete {result=$0} == true && queue.count==1,"Actual factory must reserve one bounded credential job.")
            check(try browser.load()=="synthetic removal browser" && audio.load()=="synthetic removal audio","Admission must not perform either store deletion.")
            if !queue.isEmpty {queue.removeFirst()()};pump {result != nil}
            check(result == .stored,"Actual dedicated deletion needs raw return and main delivery.")
            check(try browser.load()==nil && audio.load()==nil,"Actual removal factory must delete both exact account roles.")
            check(try otherBrowser.load()=="synthetic neighbour browser" && otherAudio.load()=="synthetic neighbour audio","Neighbour roles must remain exact.")
            check(try profileStore.load(id:account)==profile,"Credential retirement alone must not delete or mutate the profile file.")
            check(!running && !window.isVisible && browserListener.currentVisitTicket==nil,"Removal purpose must grant no listening or Session authority.")
            check(browserProfileRevision != revision,"Preparation must invalidate the old Root editing revision.")
            access?.invalidate()
        } catch {failures.append("Isolated removal factory probe failed.")}
        print("Headless browser removal factory assertions: \(assertions).")
        return failures
    }

    private func headlessBrowserTransactionFailures() -> [String] {
        var failures = [String](), assertions = 0
        func check(_ value: Bool, _ text: String) { assertions += 1; if !value { failures.append(text) } }
        func pump(_ done: () -> Bool) { let end = Date().addingTimeInterval(3); while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) } }
        guard AppRuntime.configuration.isIsolated, !running, !window.isVisible, let profile = activeProfile else { return ["Root browser transaction fixture requires a stopped isolated profile."] }
        let store = AppRuntime.passwordStore(account: profile.id.uuidString, role: .browser)
        let audio = AppRuntime.passwordStore(account: profile.id.uuidString)
        do {
            try store.save("synthetic opened browser"); try audio.save("synthetic protected audio")
            var opened: BrowserListenerEdit?, openedReply = false
            // The fixture waits the preceding profile's actual Stop. Production
            // callers get a refusal and must choose explicitly, never auto-retry.
            var admitted = false
            pump { if !admitted { admitted = beginBrowserProfileEditing { opened = $0; openedReply = true } }; return admitted }
            check(admitted, "Actual Root must admit stopped configuration without a Session Start.")
            guard admitted else { return failures }
            pump { openedReply }
            check(openedReply && opened?.choice.password == "synthetic opened browser", "Root must load only the sealed actual browser account.")
            check(browserListener.currentVisitTicket == nil && !running && !window.isVisible, "Stopped Root editing must not fabricate listening or show a window.")
            guard let model = opened else { return failures + ["Root model missing."] }
            model.update(.init(options: .init(enabled: true, autoStart: true), password: "synthetic saved browser")); model.accept()
            pump { model.finished }
            check(model.finished && browserProfileTransaction == nil, "Root must await preview and credential receipts before acceptance.")
            check(browserOptions == .init(enabled: true, autoStart: true) && hasUnsavedProfileChanges, "Root accepted choices must update actual profile dirty state.")
            check(try store.load() == "synthetic saved browser" && audio.load() == "synthetic protected audio", "Root browser writes must preserve the separate audio role.")
            check(browserEffectiveChoice?.choice == .empty, "Stopped staging must never be cached as listening.")
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profileSnapshot(id: profile.id, title: profile.title, readOnly: false))) as? [String: Any]
            check(object?.keys.filter { $0.lowercased().contains("password") }.isEmpty == true, "Root browser choices must not put passwords in profile JSON.")
            opened = nil; openedReply = false
            check(beginBrowserProfileEditing { opened = $0; openedReply = true }, "Explicit reopen must use the same persistent owner.")
            pump { openedReply }
            guard let cancelled = opened else { return failures + ["Reopened Root model missing."] }
            cancelled.update(.init(options: .init(), password: "synthetic cancelled")); cancelled.cancel(); pump { cancelled.finished }
            check(cancelled.finished && browserOptions == .init(enabled: true, autoStart: true), "Root Cancel must restore opened choices.")
            check(try store.load() == "synthetic saved browser", "Cancelled Root preview must not persist its password.")
            try persistProfileLock(true)
            opened = nil; openedReply = false
            check(beginBrowserProfileEditing { opened = $0; openedReply = true }, "Read-only configuration must remain editable temporarily.")
            pump { openedReply }
            guard let temporary = opened else { return failures + ["Read-only Root model missing."] }
            temporary.update(.init(options: .init(enabled: true), password: "synthetic temporary browser")); temporary.accept(); pump { temporary.finished }
            check(temporary.finished && browserOptions == .init(enabled: true), "Read-only temporary choices need actual model completion.")
            check(try store.load() == "synthetic saved browser", "Read-only Root acceptance must never write the stored credential.")
            opened = nil; openedReply = false
            check(beginBrowserProfileEditing { opened = $0; openedReply = true }, "Read-only temporary state must support explicit reopen.")
            pump { openedReply }
            check(opened?.choice.password == "synthetic temporary browser", "Current read-only UI choice must stay separate from its saved credential.")
            opened?.cancel(); pump { browserProfileTransaction == nil }
            try persistProfileLock(false)
            var queue = [@Sendable () -> Void]()
            browserCredentialExecutor = { queue.append($0) }
            var staleReply = false, staleModel: BrowserListenerEdit?
            check(beginBrowserProfileEditing { staleModel = $0; staleReply = true }, "Root held-load visit must be admitted.")
            check(queue.count == 1, "Root must queue one bounded credential load.")
            resetToBlankProfile()
            check(!staleReply && browserProfileTransaction != nil, "New profile must retain the old admitted credit until it returns.")
            if !queue.isEmpty { queue.removeFirst()() }; pump { staleReply }
            check(staleReply && staleModel == nil && browserProfileTransaction == nil, "Old-account load must never reach a replacement Root profile.")
            check(browserOptions == .init() && browserWorkingChoice == nil, "New profile must clear temporary browser state immediately.")
            check(try store.load() == "synthetic saved browser", "Revoked old-account work must preserve its fixed credential.")
            browserCredentialExecutor = nil
            try persistProfileAs("Browser termination")
            // Test the Root termination path with a real model's queued commit,
            // not merely the lower credential owner's shutdown receipt.
            var finalModel: BrowserListenerEdit?, finalReply = false
            pump { if !finalReply && finalModel == nil { _ = beginBrowserProfileEditing { finalModel = $0; finalReply = true } }; return finalReply }
            guard let finalModel else { return failures + ["Final stopped Root model missing."] }
            browserCredentialExecutor = { queue.append($0) }
            // Existing access captured its executor at open; reopen explicitly.
            finalModel.cancel(); pump { browserProfileTransaction == nil }
            var held: BrowserListenerEdit?, heldReply = false
            check(beginBrowserProfileEditing { held = $0; heldReply = true }, "Held Root commit visit must be admitted.")
            if !queue.isEmpty { queue.removeFirst()() }; pump { heldReply }
            guard let held else { return failures + ["Held Root model missing."] }
            held.update(.init(options: .init(enabled: true), password: "synthetic pending browser")); held.accept(); pump { !queue.isEmpty }
            let request = UUID(); terminationRequest = request; var closed = false
            browserBeforeSessionShutdownProbe = {
                check(self.browserProfileTransaction == nil && held.finished, "Actual Session shutdown must follow the queued editor completion, not just Core shutdown.")
            }
            shutdownRouterThenSession(request) { if case .success = $0 { closed = true } }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            check(!closed && browserProfileTransaction != nil && !queue.isEmpty, "Root termination must join raw credential return and the model completion.")
            if !queue.isEmpty { queue.removeFirst()() }; pump { closed }
            check(closed && held.finished && browserProfileTransaction == nil, "Actual Root termination must retire model, source, Room and Session before completion.")
            check(!running && !window.isVisible, "Transaction checks must remain stopped and hidden.")
            browserBeforeSessionShutdownProbe = nil
            browserCredentialExecutor = nil; terminationRequest = nil
        } catch { failures.append("Isolated Root browser transaction persistence failed.") }
        print("Headless browser transaction assertions: \(assertions).")
        return failures
    }

    private func headlessBrowserOwnerFailures() -> [String] {
        @MainActor final class Backend: BrowserSessionBackend {
        var listenerState: BrowserListenerStatus.State = .off
            var prepares = [(Bool) -> Void](), stops = [() -> Void](), closes = [() -> Void](), activations = 0
            func prepareStart(_ request: UUID, completion: @escaping (Bool) -> Void) -> Bool { prepares.append(completion); return true }
            func stop(completion: @escaping () -> Void) -> Bool { stops.append(completion); return true }
            func shutdown(completion: @escaping () -> Void) -> Bool { closes.append(completion); return true }
            func activate(_ request: UUID, binding: SessionNetworkBinding, options: BrowserListenerOptions, password: String) -> Bool { activations += 1; return true }
        func activate(_ request: UUID, binding: SessionNetworkBinding, options: BrowserListenerOptions, password: String, completion: @escaping (BrowserListenerActivationResult) -> Void) -> Bool { false }
        }
        var failures = [String](), assertions = 0
        func check(_ condition: Bool, _ message: String) { assertions += 1; if !condition { failures.append(message) } }
        func pump(_ condition: () -> Bool) {
            let limit = Date().addingTimeInterval(2)
            while !condition() && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        }
        guard AppRuntime.configuration.isIsolated, !running, !window.isVisible else { return ["Browser root fixture requires stopped hidden isolation."] }
        let original = browserListener; var originalClosed = false
        _ = original.shutdown { if case .success = $0 { originalClosed = true } }; pump { originalClosed }
        guard originalClosed else { return ["Default-off browser owner did not retire."] }
        let backend = Backend(), owner = BrowserSessionOwner(backend: backend)
        browserListener = owner
        defer { browserListener = original; terminationRequest = nil; sessionStartRequest = nil; browserStartSubmissionProbe = nil }
        let binding = SessionNetworkBinding(port: 49211, generation: UUID())
        let worker = PushToTalkWorkerReceipt(settings: .init(), running: true, generation: UUID())
        var submitted = 0
        browserStartSubmissionProbe = { submitted += 1 }
        password.stringValue = "synthetic root submission"; remember.state = .off
        send.state = .off; systemAudio.state = .off; receive.state = .off; monitor.state = .off; plugins.state = .off
        start.isEnabled = true
        beginSessionFromProfile(serverAddress: nil)
        check(submitted == 0 && backend.prepares.count == 1, "Actual root Start must await browser preparation before permissions/submission.")
        guard let request = sessionStartRequest else { return failures + ["Actual root request missing."] }
        backend.prepares.first?(true); pump { submitted == 1 }
        check(submitted == 1, "Actual root Start must submit only after the matching browser receipt.")
        owner.observe(running: true, binding: binding, workerGeneration: worker.generation)
        pushToTalkSubmittedStartRequest = request
        completePushToTalkStart(request, keyRequest: nil, receipt: worker)
        completeRouterStart(request, binding: binding)
        check(owner.activate(options: .init(enabled: true), password: "synthetic fixture"), "Actual root network receipt must reach browser owner.")
        // The root is observed running, while the actual isolated Session remains stopped.
        // This exercises the real setter and its nil receipt without constructing device audio.
        running = true
        let sourceReceipts = browserSourceReceipts
        audioOptionsChanged()
        backend.stops.last?(); pump { browserSourceReceipts == sourceReceipts + 1 }
        check(browserSourceReceipts == sourceReceipts + 1, "Actual audio-option completion must reach the root browser owner.")
        pump { !owner.hasPendingSourceWork }
        check(!owner.hasPendingSourceWork, "Actual audio-option worker callback must retire its browser source credit.")
        check(owner.currentVisitTicket == nil, "A stopped Session nil receipt cannot certify running renewal.")
        running = false
        let stops = browserStopSubmissions
        let beforeStop = backend.stops.count
        stopSession()
        check(browserStopSubmissions == stops && backend.stops.count == beforeStop + 1, "Actual Stop must fence before Session mutation.")
        backend.stops.last?(); pump { browserStopSubmissions == stops + 1 }
        check(browserStopSubmissions == stops + 1, "Actual Stop must reach Session only after browser receipt.")
        suspendPushToTalkForProfileChange()
        check(backend.stops.count == beforeStop + 2 && sessionStartRequest == nil, "Actual profile transition must retire browser request first.")
        backend.stops.last?(); RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        refreshPermissionsPressed()
        check(backend.stops.count == beforeStop + 3, "Actual permission refresh must retire browser eligibility.")
        backend.stops.last?(); RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        let shutdowns = browserShutdownSubmissions, quitting = UUID(); terminationRequest = quitting; var finished = false
        shutdownRouterThenSession(quitting) { if case .success = $0 { finished = true } }
        check(backend.closes.count == 1 && browserShutdownSubmissions == shutdowns && !finished, "Actual termination must await exact browser barrier before router/Session.")
        terminationRequest = nil
        backend.closes.first?(); RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        check(browserShutdownSubmissions == shutdowns && !finished, "Late receipt from abandoned termination must not shut down Session.")
        let retry = UUID(); terminationRequest = retry
        shutdownRouterThenSession(retry) { if case .success = $0 { finished = true } }; pump { finished }
        check(finished && browserShutdownSubmissions == shutdowns + 1, "Fresh termination must use real prior browser retirement then router/Session receipts.")
        check(backend.activations == 1 && !window.isVisible && !running, "Fixture must use only mock activation with hidden stopped Session.")
        print("Headless browser owner assertions: \(assertions).")
        return failures
    }
    #endif

    private func completeRouterStart(_ request: UUID, binding: SessionNetworkBinding?) {
        guard terminationRequest == nil else { return }
        browserListener.acknowledgeStart(request, binding: binding)
        routerControls?.acknowledge(request, binding: binding)
    }
    private func completePushToTalkStart(_ request: UUID, keyRequest: UUID?, receipt: PushToTalkWorkerReceipt?) {
        guard pushToTalkSubmittedStartRequest == request, terminationRequest == nil, !pushToTalkClosing else { return }
        pushToTalkSubmittedStartRequest = nil
        if browserListener.needsAudioResume(request),!browserSourcePermitted {_ = browserListener.suspendForPermission()}
        browserListener.acknowledgeWorker(request, receipt: receipt)
        guard let keyRequest else { return }
        if pushToTalkInput?.isCurrent(keyRequest) == true {
            pushToTalkInput?.acknowledge(keyRequest, receipt: receipt)
        } else if receipt?.running == true, running {
            // Choices edited after worker submission need their own update receipt before keys can arm.
            audioOptionsChanged()
        }
    }
    private func checkPermissionsAtLaunch() {
        guard !startupHidden, !AppRuntime.configuration.isIsolated else { return }
        recordStartup("Microphone authorization \(AVCaptureDevice.authorizationStatus(for: .audio)); \(selectedInputUIDs.count) selected inputs; input sending \(send.state == .on ? "on" : "off").")
        ensureMicrophoneAccess { [weak self] _ in
            self?.ensureSystemAudioAccess { _ in }
        }
    }
    private func ensureMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if AppRuntime.configuration.isHeadless || startupHidden {
            completion(send.state != .on || status == .authorized)
            return
        }
        guard status == .notDetermined else {
            completion(status == .authorized)
            refreshPermissionStatus()
            return
        }
        microphoneAccessCallbacks.append(completion)
        guard microphoneAccessCallbacks.count == 1 else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self else { return }
                let callbacks = self.microphoneAccessCallbacks
                self.microphoneAccessCallbacks.removeAll()
                self.refreshPermissionStatus()
                callbacks.forEach { $0(allowed) }
            }
        }
    }
    private func ensureSystemAudioAccess(force: Bool = false,
        _ completion: @escaping (Bool) -> Void) {
        if AppRuntime.configuration.isHeadless || startupHidden {
            completion(systemAudio.state != .on || (systemAudioAccessChecked && systemAudioAccessAvailable))
            return
        }
        if systemAudioAccessChecked && !force {
            completion(systemAudioAccessAvailable)
            return
        }
        systemAudioAccessCallbacks.append(completion)
        guard systemAudioAccessCallbacks.count == 1 else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let available = Session.requestSystemAudioAccess()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.systemAudioAccessChecked = true
                self.systemAudioAccessAvailable = available
                let callbacks = self.systemAudioAccessCallbacks
                self.systemAudioAccessCallbacks.removeAll()
                self.refreshPermissionStatus()
                callbacks.forEach { $0(available) }
            }
        }
    }
    private func handleDeniedMicrophoneAccess() {
        guard send.state == .on else { return }
        send.state = .off
        announce("Microphone access was denied. Input sending is off. Allow RemSound in System Settings, Privacy and Security, Microphone.")
    }
    @objc private func stopSession() {
        let replacesProfile=chooseProfileAfterStop || recentProfileAfterStop != nil || profileStopDispatch != nil || browserProfilePromptRetiring || profileModalActive
        cancelProfileAfterStop();startupRequests.invalidate()
        let observation = beginUIObservation(.stopSession, matches: { !$0.running })
        defer { uiObservations.handlerReturned(observation) }
        pushToTalkInput?.invalidate()
        sessionStartRequest = nil
        pushToTalkSubmittedStartRequest = nil
        routerControls?.invalidate()
        jam.retireServerNotice()
        if replacesProfile {stopSessionAfterBrowserRetirement()}
        else {browserListener.performAudioStop { [weak self] in self?.submitStoppedAudioSession() }}
    }
    private func submitStoppedAudioSession() {
        guard terminationRequest == nil else {return}
        #if DEBUG
        if AppRuntime.configuration.isIsolated {browserStopSubmissions += 1}
        #endif
        session.stop()
    }
    private func applyBrowserSafeApplications(_ applications: [String]?) {
        browserListener.performSource(.applications) { [weak self] complete in
            guard let self, self.terminationRequest == nil else { complete(nil, false); return }
            self.session.setSendApplications(applications) { [weak self] receipt in
                complete(receipt, self?.browserSourcePermitted == true)
            }
        }
    }
    private func stopSessionAfterBrowserRetirement() {
        browserListener.perform(.stopSession) { [weak self] in
            guard let self, self.terminationRequest == nil else { return }
            #if DEBUG
            if AppRuntime.configuration.isIsolated { self.browserStopSubmissions += 1 }
            #endif
            self.session.stop()
        }
    }
    @objc private func toggleSelfMonitoring() { jam.toggleSelfMonitoring() }
    private func selectedRecordingSource() -> RecordingSource {
        RecordingSource(rawValue: recordingSource.selectedItem?.representedObject as? String ?? "") ?? .both
    }
    private func selectedReceiveArtifact() -> ConcealmentArtifact {
        ConcealmentArtifact.migrated(receiveArtifact.selectedItem?.representedObject as? Int
            ?? ConcealmentArtifact.defaultChoice.rawValue)
    }
    private func selectReceiveArtifact(_ choice: ConcealmentArtifact) {
        if let index = receiveArtifact.itemArray.firstIndex(where: {
            ($0.representedObject as? Int) == choice.rawValue
        }) { receiveArtifact.selectItem(at: index) }
    }
    private func selectedReceiveSmoothness() -> Int {
        BufferSmoothness.clamped(receiveSmoothness.selectedItem?.representedObject as? Int
            ?? BufferSmoothness.defaultLevel)
    }
    private func selectReceiveSmoothness(_ level: Int) {
        if let index = receiveSmoothness.itemArray.firstIndex(where: {
            ($0.representedObject as? Int) == BufferSmoothness.clamped(level)
        }) { receiveSmoothness.selectItem(at: index) }
    }
    private func selectedReceiveJitterMs() -> Int {
        ReceiveBuffer.clamped(receiveJitter.selectedItem?.representedObject as? Int
            ?? ReceiveBuffer.legacyDefaultMs)
    }
    private func selectedAutoTuneInterval() -> Int {
        ReceiveBuffer.validAutoTuneInterval(
            receiveAutoTuneInterval.selectedItem?.representedObject as? Int
                ?? ReceiveBuffer.defaultAutoTuneInterval)
    }
    /// The Total latency box (Windows FormatMeasuredLatency): the jitter buffer, what the hardware adds, and the one-way
    /// total from the quickest complete path in. Kept still while it has the focus.
    private func refreshReceiveLatencyStatus() {
        let setMs = selectedReceiveJitterMs()
        session.latencyJourneys { [weak self] journeys, receiving in
            guard let self else { return }
            if let responder = self.window.firstResponder,
               responder === self.receiveLatencyStatus || responder === self.receiveLatencyStatus.currentEditor() { return }
            let figures = receiving ? TotalLatencyText.steady(shown: self.shownLatencyFigures,
                new: TotalLatencyText.figures(setMs: setMs, journeys: journeys)) : nil
            self.shownLatencyFigures = figures
            let text = "Total latency: " + TotalLatencyText.text(setMs: setMs, receiving: receiving, figures: figures)
            guard self.receiveLatencyStatus.stringValue != text else { return }
            self.receiveLatencyStatus.stringValue = text
            self.receiveLatencyStatus.setAccessibilityLabel(text)
        }
    }
    @objc private func receiveArtifactChanged() {
        let choice = selectedReceiveArtifact()
        let observation = beginUIObservation(.receiveArtifact, matches: { $0.receiveArtifact == choice })
        defer { uiObservations.handlerReturned(observation) }
        AppRuntime.settings.set(choice.rawValue, forKey: "receiveArtifact")
        session.setReceiveArtifact(choice)
        announce("Receive gap sound set to \(choice.label).")
    }
    @objc private func receiveSmoothnessChanged() {
        let level = selectedReceiveSmoothness()
        let observation = beginUIObservation(.receiveSmoothness, matches: { $0.receiveSmoothness == level })
        defer { uiObservations.handlerReturned(observation) }
        AppRuntime.settings.set(level, forKey: "receiveSmoothness")
        session.setReceiveSmoothness(level)
        announce("Receive buffer smoothness set to \(level).")
    }
    @objc private func receiveJitterChanged() {
        let milliseconds = selectedReceiveJitterMs()
        let observation = beginUIObservation(.jitterBuffer, matches: { $0.receiveJitterMs == milliseconds })
        defer { uiObservations.handlerReturned(observation) }
        AppRuntime.settings.set(milliseconds, forKey: "receiveJitterMs")
        session.setReceiveJitterMs(milliseconds)
        refreshReceiveLatencyStatus()
        announce("Receive jitter buffer set to \(milliseconds) milliseconds.")
    }
    @objc private func receiveLowestDelayChanged() {
        let on = receiveLowestDelay.state == .on
        AppRuntime.settings.set(on, forKey: "receiveLowestDelay")
        session.setReceiveLowestDelay(on)
    }
    @objc private func receiveAutoTuneChanged() {
        let enabled = receiveAutoTune.state == .on
        let interval = selectedAutoTuneInterval()
        AppRuntime.settings.set(enabled, forKey: "receiveAutoTune")
        AppRuntime.settings.set(interval, forKey: "receiveAutoTuneInterval")
        session.setReceiveAutoTune(enabled, interval: interval)
        refreshReceiveLatencyStatus()
        announce("Receive auto-tune \(enabled ? "on" : "off"); checks every \(interval) seconds.")
    }
    private func selectedRecordingFormat() -> RecordingFormat {
        RecordingFormat(rawValue: recordingFormat.selectedItem?.representedObject as? String ?? "") ?? .wav24
    }
    private func selectedRecordingChannels() -> RecordingChannels {
        RecordingChannels(rawValue: recordingChannels.selectedItem?.representedObject as? String ?? "") ?? .stereo
    }
    private func selectedFLACCompression() -> Int {
        FLACCompression.clamped(flacCompression.selectedItem?.representedObject as? Int ?? FLACCompression.defaultLevel)
    }
    private func recordingsFolder() -> URL {
        if AppRuntime.configuration.isIsolated { return AppRuntime.configuration.recordingsDirectory }
        if let path = AppRuntime.settings.string(forKey: "recordingsDirectory"), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return AppRuntime.configuration.recordingsDirectory
    }
    @objc private func recordingBypassChanged() {
        CueSounds.shared.play(recordingBypassShaping.state == .on ? .checkboxOn : .checkboxOff)
        recordingSourceChanged()
    }
    @objc private func recordingSourceChanged() {
        AppRuntime.settings.set(selectedRecordingSource().rawValue, forKey: "recordingSource")
        AppRuntime.settings.set(selectedRecordingFormat().rawValue, forKey: "recordingFormat")
        AppRuntime.settings.set(selectedRecordingChannels().rawValue, forKey: "recordingChannels")
        AppRuntime.settings.set(splitRecording.state == .on, forKey: "splitRecording")
        AppRuntime.settings.set(recordingBypassShaping.state == .on, forKey: "recordingBypassShaping")
        AppRuntime.settings.set(selectedFLACCompression(), forKey: "flacCompression")
        flacCompression.isEnabled = selectedRecordingFormat().fileExtension == "flac"
    }
    @objc private func toggleRecording() {
        if recordingButton.title == "Stop recording" { session.stopRecording(); return }
        guard running else { announce("Start RemSound before recording."); return }
        do { try beginRecording() }
        catch { announce("Could not create recordings folder: \(error.localizedDescription)") }
    }
    private func beginRecording() throws {
        let date = Date()
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.dateFormat = "HH-mm-ss"
        let folder = recordingsFolder().appendingPathComponent(day.string(from: date), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Windows' names (RecordingController): the start time and this computer's name, or "multi track" for a folder of
        // tracks.
        let basename = "\(time.string(from: date)) RemSound recording"
        let destination = splitRecording.state == .on
            ? folder.appendingPathComponent(basename + " multi track", isDirectory: true)
            : folder.appendingPathComponent(basename + " \(Session.recordingMachineName()).\(selectedRecordingFormat().fileExtension)")
        session.startRecording(url: destination, source: selectedRecordingSource(),
            format: selectedRecordingFormat(), channels: selectedRecordingChannels(),
            split: splitRecording.state == .on, bypassShaping: recordingBypassShaping.state == .on,
            flacCompression: selectedFLACCompression())
    }
    @objc private func changeRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose RemSound Recordings Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Folder"
        panel.directoryURL = recordingsFolder()
        if panel.runModal() == .OK, let url = panel.url {
            AppRuntime.settings.set(url.path, forKey: "recordingsDirectory")
            announce("Recordings folder set to \(url.path).")
        }
    }
    @objc private func openRecordingsFolder() {
        let url = recordingsFolder()
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch { announce("Could not open recordings folder: \(error.localizedDescription)") }
    }
    private func refreshPushToTalkPresentation() {
        let title = "Push to talk settings, currently " + (pushToTalkSettings.enabled ? "enabled" : "disabled")
        if pushToTalkButton.title != title {
            pushToTalkButton.title = title
            pushToTalkButton.setAccessibilityLabel(title)
        }
    }
    private func loadPushToTalkMachineKey() {
        do { pushToTalkKeys.replaceBinding(try PushToTalkKeyPreferences.load(from: AppRuntime.settings)) }
        catch { recordStartup("Saved push-to-talk key is unreadable; preserved until an explicit key edit.") }
    }
    @objc private func showBrowserListener() {
        if AppRuntime.configuration.isHeadless {
            #if DEBUG
            if AppRuntime.configuration.isIsolated {_=openBrowserListenerWindow(present:false)}
            #endif
            return
        }
        _=openBrowserListenerWindow(present:true)
    }
    @discardableResult private func openBrowserListenerWindow(present:Bool)->Bool {
        guard terminationRequest==nil else {return false}
        if let existing=browserListenerWindow {
            guard !existing.edit.contextInvalidated,!existing.edit.finished else {return false}
            if present {AppRuntime.configuration.handOverToGUI();existing.showWindow(nil);existing.window?.makeKeyAndOrderFront(nil)}
            return true
        }
        guard browserWindowRequest==nil,browserProfileTransaction==nil else {
            announce("Browser choices are waiting for an earlier operation. No new password load was started.");return false
        }
        let request=UUID();browserWindowRequest=request
        recordStartup("Browser listener choices requested for the current profile.")
        announce("Loading browser listener choices for this profile.")
        let admitted=beginBrowserProfileEditing { [weak self] edit in
            guard let self,self.browserWindowRequest==request else {return}
            guard let edit,let transaction=self.browserProfileTransaction else {
                self.browserWindowRequest=nil
                self.announce("Browser choices could not be opened for the current profile. No window was opened.");return
            }
            let persistence:BrowserListenerWindow.Persistence=self.activeProfile==nil ? .draft:(transaction.ticket.allowsPersistence ? .profile:.readOnly)
            let visit:BrowserListenerWindow.Visit=transaction.ticket.isRunning ? .running:(transaction.ticket.allowsStoppedListening ? .stoppedListening:(transaction.ticket.isStagedWhileRunning ? .stagedRunning:.stopped))
            guard let controller=BrowserListenerWindow(edit:edit,visit:visit,persistence:persistence,contextHelp:self.contextHelpAction,address:transaction.address,didEnd:{ [weak self] result,kept in
                guard let self,self.browserListenerWindow?.edit === edit else {return}
                let current=self.browserWindowRequest==request
                self.browserListenerWindow=nil;self.browserWindowRequest=nil
                guard current,self.terminationRequest==nil else {return}
                switch result {
                case .accepted:
                    self.recordStartup("Browser choices accepted after completed preview and persistence receipts.")
                    if visit == .stoppedListening {
                        self.announce(kept?.options.enabled == true ? "Browser listening is set up. It starts when you start RemSound.":"Browser choices kept. Browser listening is off.")
                    } else if visit == .running {
                        self.announce(kept?.options.enabled == true ? "Browser listening is on. Open the page in your browser to listen.":"Browser choices kept. Browser listening is off.")
                    } else {
                        self.announce("Browser choices kept. They take effect when you start RemSound.")
                    }
                case .cancelled:self.announce("Opened browser choices restored.")
                case .invalidated:self.announce("Browser window closed because its profile or permission context changed.")
                }
                if present {self.window.makeFirstResponder(self.browserListenerButton)}
            }) else {
                self.browserWindowRequest=nil;transaction.invalidate()
                self.announce("The current browser choices could not be presented. Cleanup was requested.");return
            }
            self.browserListenerWindow=controller
            if let service=self.browserService { controller.describeBrowsers = { reply in service.describeBrowsers(reply: reply) } }
            if present {AppRuntime.configuration.handOverToGUI();controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)}
        }
        if !admitted {
            if browserWindowRequest==request {browserWindowRequest=nil}
            announce("Browser editing is not ready while earlier cleanup or a session change is pending. No new password load was started.")
        }
        return admitted
    }
    private func invalidateBrowserProfileEditing(preservingListener:Bool=false) {
        browserProfileRevision = UUID();browserWindowRequest=nil
        if !browserRemovalPreparing {browserProfileRemoval?.cancel()}
        browserWorkingChoice=nil
        // The one bounded effective UI choice remains in this unchanged profile
        // credential context. The old window and its displayed secret are revoked.
        if preservingListener,let value=browserEffectiveChoice {browserEffectiveChoice=(browserListener.sourceScope,value.choice)}
        else {browserEffectiveChoice=nil}
        // Retain the transaction until its admitted storage and queued model
        // callbacks return; invalidity alone is not a retirement receipt.
        browserProfileTransaction?.invalidate()
    }
    private func beginBrowserProfileEditing(completion: @escaping (BrowserListenerEdit?) -> Void) -> Bool {
        guard !profileModalActive,!chooseProfileAfterStop,recentProfileAfterStop == nil,profileStopDispatch == nil,
              terminationRequest == nil,browserProfileRemoval == nil,browserProfileTransaction == nil else {return false}
        if browserProfilePromptRetiring {
            guard browserListener.profileContextRetired else {return false}
            browserProfilePromptRetiring=false
        }
        browserListener.refreshFailure()
        // Explicit open creates a draft account if needed. It does not copy an
        // audio credential or activate a listener merely from saved flags.
        if activeProfile == nil && draftProfileID == nil { draftProfileID = UUID() }
        guard let account = activeProfile?.id ?? draftProfileID else { return false }
        let readOnly = activeProfile?.readOnly == true, draft = activeProfile == nil, revision = browserProfileRevision
        // An unsaved account has no durable profile owner. Keep its browser secret
        // in the bounded UI visit, so New/discard needs no orphan Keychain deletion.
        let persistenceReadOnly = readOnly || draft
        let request = sessionStartRequest, wasRunning = running, scope = browserListener.sourceScope
        if browserWorkingChoice?.account != account || browserWorkingChoice?.scope != scope { browserWorkingChoice = nil }
        if browserEffectiveChoice?.scope != scope { browserEffectiveChoice = nil }
        let current: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.terminationRequest == nil && self.browserProfileRevision == revision
                && (self.activeProfile?.id ?? self.draftProfileID) == account
                && (self.activeProfile?.readOnly == true) == readOnly && (self.activeProfile == nil) == draft
                && self.running == wasRunning && self.sessionStartRequest == request
                && self.browserListener.isCurrentSourceScope(scope)
        }
        guard current(), let ticket = browserListener.beginConfiguration(.init(account: account, revision: revision, readOnly: persistenceReadOnly)) else { return false }
        // A running observation alone grants configuration-only editing. Native
        // activation still needs the owner's distinct accepted running ticket.
        guard current(), !ticket.isRunning || wasRunning, wasRunning || request == nil else {
            browserListener.endConfiguration(ticket); return false
        }
        var execute: BrowserCredentialAccess.Executor?
        #if DEBUG
        if AppRuntime.configuration.isIsolated { execute = browserCredentialExecutor }
        #endif
        guard let access = BrowserCredentialAccess.forConfiguration(owner: browserListener, configuration: ticket, isCurrent: current, execute: execute) else {
            browserListener.endConfiguration(ticket); return false
        }
        let transaction = BrowserProfileTransaction(owner: browserListener, ticket: ticket, access: access,
            options: browserOptions, effectiveOpened: wasRunning || ticket.allowsStoppedListening ? (browserEffectiveChoice?.choice ?? .empty) : .empty,
            temporaryPassword: persistenceReadOnly ? browserWorkingChoice?.choice.password : nil, isCurrent: current,
            commitMetadata: { [weak self] options in
                guard let self, current() else { return false }
                self.browserOptions = options; self.refreshProfileNotice(); return current()
            })
        transaction.onEffective = { [weak self] choice in
            guard current() else { return }; self?.browserEffectiveChoice = (scope, choice)
        }
        transaction.onEnd = { [weak self, weak transaction] result, value in
            guard let self, let transaction, self.browserProfileTransaction === transaction else { return }
            if current(), result == .accepted, let value { self.browserWorkingChoice = (account, scope, value) }
            if !current() { self.browserWorkingChoice=nil;if self.browserEffectiveChoice?.scope == scope {self.browserEffectiveChoice=nil} }
            self.browserProfileTransaction = nil
        }
        browserProfileTransaction = transaction
        return transaction.open { model in completion(current() ? model : nil) }
    }
    private func shutdownBrowserProfile(completion: @escaping (Result<Void, Error>) -> Void) {
        var modelClosed = browserProfileTransaction == nil, removalClosed = browserProfileRemoval == nil, removalFailed=false
        var coreResult: Result<Void, Error>?, delivered = false
        let finish = {
            guard !delivered, modelClosed, removalClosed, let result = coreResult else { return }
            delivered = true; completion(removalFailed ? .failure(BrowserSessionOwner.Failure.retirementRefused):result)
        }
        if let transaction = browserProfileTransaction {
            guard transaction.close(completion: { modelClosed = true; finish() }) else {
                completion(.failure(BrowserSessionOwner.Failure.retirementRefused)); return
            }
        }
        if let removal=browserProfileRemoval {
            guard removal.close(completion:{result in removalClosed=true;removalFailed=result == .failed;finish()}) else {
                completion(.failure(BrowserSessionOwner.Failure.retirementRefused));return
            }
        }
        let admitted = browserListener.shutdown { result in coreResult = result; finish() }
        if !admitted { coreResult = .failure(BrowserSessionOwner.Failure.retirementRefused); finish() }
    }
    // A modal profile prompt cannot keep a shown browser password or run ahead
    // of admitted storage/Room cleanup. Retry is a new explicit user action.
    private func retireBrowserBeforeProfilePrompt() -> Bool {
        guard !profileModalActive,!chooseProfileAfterStop,recentProfileAfterStop == nil,profileStopDispatch == nil,
              terminationRequest == nil,browserProfileRemoval == nil else {
            announce("Wait for the current profile confirmation, deletion or shutdown to finish.");return false
        }
        invalidateBrowserProfileEditing()
        if !browserProfilePromptRetiring && (browserProfileTransaction != nil || !browserListener.profilePersistenceRetired) {
            browserProfilePromptRetiring=true;browserListener.invalidate(discardMutations:true)
        }
        guard browserProfileTransaction == nil,browserListener.profilePersistenceRetired else {
            announce("Browser editing was closed. Wait for cleanup, then choose the profile action again.");return false
        }
        browserProfilePromptRetiring=false;return true
    }
    @discardableResult private func startConfirmedProfileRemoval(_ profile:ConnectionProfile,
        completion:((BrowserProfileRemoval.Outcome)->Void)?=nil)->Bool {
        guard terminationRequest == nil,!running,sessionStartRequest == nil,browserProfileRemoval == nil,
              activeProfile==profile,(try? profileStore.load(id:profile.id))==profile else {return false}
        let id=UUID(),storeID=ObjectIdentifier(profileStore),audioID=ObjectIdentifier(passwordStore)
        let oldModel=browserProfileTransaction
        let removal=BrowserProfileRemoval(owner:browserListener,account:profile.id,closeEditor:{reply in
            guard let oldModel else {reply();return true};return oldModel.close(completion:reply)
        },seal:{[weak self] in
            guard let self,terminationRequest == nil,!running,sessionStartRequest == nil,
                  activeProfile==profile,browserRemovalID==id else {return nil}
            let revision=browserProfileRevision,scope=browserListener.sourceScope
            return {[weak self] in
                guard let self else {return false}
                return terminationRequest == nil && !running && sessionStartRequest == nil
                    && activeProfile==profile && browserRemovalID==id && browserProfileRevision==revision
                    && ObjectIdentifier(profileStore)==storeID && ObjectIdentifier(passwordStore)==audioID
                    && browserListener.isCurrentSourceScope(scope)
            }
        },access:{[weak self] ticket,current in
            guard let self else {return nil};var execute:BrowserCredentialAccess.Executor?
            #if DEBUG
            if AppRuntime.configuration.isIsolated {execute=browserCredentialExecutor}
            #endif
            return BrowserCredentialAccess.forRemoval(owner:browserListener,removal:ticket,isCurrent:current,execute:execute)
        },removeFile:{[weak self] in
            guard let self,activeProfile==profile,browserRemovalID==id,terminationRequest == nil,!running else {throw ProfileStoreError.invalidProfile}
            #if DEBUG
            if AppRuntime.configuration.isIsolated {try browserRemovalFileProbe?(profile.id)}
            #endif
            guard try profileStore.load(id:profile.id)==profile else {throw ProfileStoreError.invalidProfile}
            try profileStore.delete(id:profile.id)
            AppRuntime.settings.set(recentProfileIDs.filter {$0 != profile.id}.map(\.uuidString),forKey:"recentProfileIDs")
        })
        browserRemovalID=id;browserProfileRemoval=removal;browserRemovalPreparing=true
        let admitted=removal.start {[weak self] result in
            guard let self,browserRemovalID==id else {return}
            browserProfileRemoval=nil;browserRemovalID=nil
            switch result {
            case .removed:
                refreshRecentProfileMenus();resetToBlankProfile()
                announce("Profile \(profile.title) and its saved connection and browser passwords deleted. A blank unsaved profile is ready.")
            case .cancelled:announce("Profile deletion was cancelled because its context changed. Some saved passwords may already have been removed.")
            case .failed:announce("Profile deletion could not be completed. Some saved passwords may already have been removed. Check this profile before trying again.")
            }
            completion?(result)
        }
        browserRemovalPreparing=false
        if !admitted {browserProfileRemoval=nil;browserRemovalID=nil}
        return admitted
    }
    private func suspendPushToTalkForProfileChange(browserContextAlreadyRetired:Bool=false) {
        if !browserContextAlreadyRetired {browserListener.invalidate(discardMutations:true)}
        startupRequests.invalidate()
        jam.retireServerNotice()
        routerControls?.invalidate()
        sessionStartRequest = nil
        pushToTalkSubmittedStartRequest = nil
        pushToTalkInput?.invalidate()
        pushToTalkKeys.retireNativeEvents()
        // Discard a working window rather than committing its choices into another profile.
        pushToTalkWindow?.close()
    }
    private func refreshPushToTalkCaptureState(windowKey: Bool? = nil) {
        pushToTalkInput?.setCapture(editorOpen: pushToTalkWindow != nil,
            fieldFocused: !pushToTalkCaptureFields.isEmpty,
            windowKey: windowKey ?? (preferencesWindow?.isKeyWindow == true))
    }
    private func configurePushToTalkInput(backend: PushToTalkRegistrationBackend? = nil, permitted: Bool? = nil) {
        guard pushToTalkInput == nil, !pushToTalkClosing else { return }
        // An injected backend is only used by the stopped isolated owner fixture.
        if backend != nil { precondition(AppRuntime.configuration.isIsolated) }
        let allowed = backend == nil
            ? AppRuntime.configuration.allowsGlobalHotkeys && !AppRuntime.configuration.silent
            : permitted == true
        let owner = PushToTalkInputOwner(keys: pushToTalkKeys, settings: pushToTalkSettings,
            backend: backend ?? CoreGraphicsPushToTalkBackend(configuration: AppRuntime.configuration), permitted: allowed)
        owner.onFailure = { [weak self] message in
            guard let self, !self.pushToTalkClosing else { return }
            self.recordStartup("Push-to-talk listener failed; key input is inactive.")
            self.pushToTalkKeyStatus.stringValue = "Push-to-talk key is inactive. " + message
            self.announce("Push-to-talk key is inactive. " + message)
        }
        pushToTalkInput = owner
    }
    private func installPushToTalkCaptureObservers() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            pushToTalkFocusObservers.append(NotificationCenter.default.addObserver(forName: name,
                object: preferencesWindow, queue: .main) { [weak self] notification in
                let closing = notification.name == NSWindow.willCloseNotification
                MainActor.assumeIsolated { self?.refreshPushToTalkCaptureState(windowKey: closing ? false : nil) }
            })
        }
    }
    private func makePushToTalkSettingsWindow() -> PushToTalkSettingsWindow {
        if let existing = pushToTalkWindow { return existing }
        let editor = PushToTalkSettingsWindow(settings: pushToTalkSettings, binding: pushToTalkKeys.binding, contextHelp: contextHelpAction,
            accept: { [weak self] choice in
                guard let self else { return "RemSound is closing." }
                return self.commitPushToTalk(choice)
            },
            didClose: { [weak self] in
                guard let self else { return }
                self.pushToTalkPreview?.shutdown()
                self.pushToTalkPreview = nil
                self.pushToTalkWindow = nil
                self.refreshPushToTalkCaptureState()
            })
        if makePushToTalkPreview != nil { precondition(AppRuntime.configuration.isIsolated) }
        let preview = makePushToTalkPreview?() ?? PushToTalkPreview.native(configuration: AppRuntime.configuration,
            preferences: CueSounds.shared.preferences,
            directory: Bundle.main.resourceURL?.appendingPathComponent("default sounds", isDirectory: true))
        pushToTalkPreview = preview
        preview.onFailure = { [weak editor] in editor?.reportPreviewFailure($0) }
        preview.onStarted = { [weak editor] in editor?.clearPreviewFailure() }
        editor.previewDoubleTap = { [weak self, weak preview] speed in
            self?.recordStartup("Double-tap preview requested: \(speed).")
            preview?.play(speed)
        }
        editor.cancelPreview = { [weak preview] in preview?.stop() }
        pushToTalkWindow = editor
        refreshPushToTalkCaptureState()
        return editor
    }
    @objc private func showPushToTalkSettings() {
        guard !pushToTalkClosing else { return }
        let editor = makePushToTalkSettingsWindow()
        AppRuntime.configuration.handOverToGUI(); editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
    }
    private func commitPushToTalk(_ choice: PushToTalkWindowChoice) -> String? {
        guard !pushToTalkClosing else { return "RemSound is closing." }
        if choice.keyWasEdited,
            choice.binding?.isValidForPushToTalk == false
                || PushToTalkKeyRegistration.conflicts(choice.binding, with: Array(hotkeyBindings.values)) {
            return "That push-to-talk key is invalid or conflicts with another RemSound shortcut. Choose another."
        }
        do {
            var companion: [String: Any?] = [:]
            if choice.keyWasEdited {
                companion[PushToTalkKeyPreferences.settingsKey] = try PushToTalkKeyPreferences.encoded(choice.binding)
            }
            try PushToTalkPreferences.save(choice.settings, to: AppRuntime.settings, additionalValues: companion)
        } catch { return "Push-to-talk choices could not be saved. Previous settings and key are unchanged." }
        // Nothing in memory or native ownership changes until the coherent storage commit succeeds.
        pushToTalkInput?.invalidate()
        if pushToTalkSettings != choice.settings {
            pushToTalkKeys.retireNativeEvents()
        }
        pushToTalkSettings = choice.settings
        pushToTalkSettingsUnreadable = false
        refreshPushToTalkPresentation()
        if choice.keyWasEdited {
            _ = pushToTalkInput?.replaceBinding(choice.binding)
            pushToTalkHotkey.descriptor = pushToTalkKeys.binding
        }
        // The editor pauses key ownership until close; Session applies running profile choices normally.
        audioOptionsChanged()
        return nil
    }
    private var browserSourcePermitted: Bool {
        (send.state != .on || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
            && (systemAudio.state != .on || (systemAudioAccessChecked && systemAudioAccessAvailable))
    }
    @objc private func audioOptionsChanged() {
        _ = browserListener.suspendForPermission()
        let browserScope = browserListener.sourceScope
        let keyRequest = pushToTalkInput?.beginRequest(settings: pushToTalkSettings)
        let observation = beginUIObservation(.audioConfiguration)
        var localStateOnly = false
        defer {
            uiObservations.handlerReturned(observation)
            if localStateOnly { uiObservations.finish(observation, outcome: .localStateOnly) }
        }
        recordStartup("Audio option requested: input sending \(send.state == .on ? "on" : "off"), \(selectedInputUIDs.count) selected inputs, microphone authorization \(AVCaptureDevice.authorizationStatus(for: .audio)).")
        let wasSending = AppRuntime.settings.bool(forKey: "sendInput")
            || AppRuntime.settings.bool(forKey: "sendSystemAudio")
        let wasReceiving = AppRuntime.settings.object(forKey: "receiveAudio") == nil
            || AppRuntime.settings.bool(forKey: "receiveAudio")
        let wasAllowingPlugins = AppRuntime.settings.object(forKey: "allowPlugins") == nil
            || AppRuntime.settings.bool(forKey: "allowPlugins")
        if send.state == .on, selectedInputUIDs.isEmpty {
            send.state = .off
            resumeInputSendingWhenSelected = false
            announce("Choose at least one audio input before turning on input sending.")
        }
        if systemAudio.state == .on, selectedCaptureUIDs?.isEmpty == true {
            systemAudio.state = .off
            resumeSystemSendingWhenSelected = false
            announce("Choose at least one system capture output before turning on system audio sending.")
        }
        if monitor.state == .on, selectedOutputUIDs.isEmpty {
            monitor.state = .off
            announce("Choose at least one Mac playback output before turning on Mac output.")
        }
        let isSending = send.state == .on || systemAudio.state == .on
        if wasSending != isSending { CueSounds.shared.play(isSending ? .sendOn : .sendOff) }
        if wasReceiving != (receive.state == .on) {
            CueSounds.shared.play(receive.state == .on ? .receiveOn : .receiveOff)
        }
        if wasAllowingPlugins != (plugins.state == .on) {
            CueSounds.shared.play(plugins.state == .on ? .dawOn : .dawOff)
        }
        saveAudioOptions()
        refreshPermissionStatus()
        guard running else {
            if let keyRequest { pushToTalkInput?.acknowledge(keyRequest, receipt: nil) }
            localStateOnly = true
            return
        }
        let requestedInputSending = send.state == .on
        let commit: (@escaping (PushToTalkWorkerReceipt?, Bool) -> Void) -> Void = { [weak self] complete in
            guard let self, self.running, self.terminationRequest == nil else { complete(nil, false); return }
            if let keyRequest, self.pushToTalkInput?.isCurrent(keyRequest) != true { complete(nil, false); return }
            let wanted = (receive: self.receive.state == .on, monitor: self.monitor.state == .on,
                plugins: self.plugins.state == .on, system: self.systemAudio.state == .on,
                inputs: self.selectedInputUIDs, inputPairs: self.selectedInputChannelPairs,
                outputs: self.selectedOutputUIDs, outputPairs: self.selectedOutputChannelPairs,
                capture: self.selectedCaptureUIDs, capturePairs: self.selectedCaptureChannelPairs,
                codec: self.selectedSendCodec(), packetSize: self.selectedSendPacketSize(),
                pushToTalk: self.pushToTalkSettings, completion: { [weak self] (receipt: PushToTalkWorkerReceipt?) in
                    #if DEBUG
                    if AppRuntime.configuration.isIsolated { self?.browserSourceReceipts += 1 }
                    #endif
                    complete(receipt, self?.browserSourcePermitted == true)
                    if let keyRequest { self?.pushToTalkInput?.acknowledge(keyRequest, receipt: receipt) }
                })
            self.pendingUIEffects[.audioConfiguration] = (observation, { view in
                view.sendingInput == requestedInputSending && view.receiving == wanted.receive
                    && view.monitoringInApp == wanted.monitor && view.allowingPlugins == wanted.plugins
                    && view.sendingSystemAudio == wanted.system && view.inputDeviceUIDs == wanted.inputs
                    && view.inputChannelPairs == wanted.inputPairs && view.outputDeviceUIDs == wanted.outputs
                    && view.outputChannelPairs == wanted.outputPairs && view.systemCaptureDeviceUIDs == wanted.capture
                    && view.systemCaptureChannelPairs == wanted.capturePairs && view.sendCodec == wanted.codec && view.sendPacketSize == wanted.packetSize && view.pushToTalk == wanted.pushToTalk
            })
            self.session.setAudioOptions(send: requestedInputSending,
                receive: self.receive.state == .on, monitorInApp: self.monitor.state == .on,
                plugins: self.plugins.state == .on,
                systemAudio: self.systemAudio.state == .on,
                inputDeviceUIDs: self.selectedInputUIDs,
                inputChannelPairs: self.selectedInputChannelPairs,
                outputDeviceUIDs: self.selectedOutputUIDs,
                outputChannelPairs: self.selectedOutputChannelPairs,
                systemCaptureDeviceUIDs: self.selectedCaptureUIDs,
                systemCaptureChannelPairs: self.selectedCaptureChannelPairs,
                sendCodec: self.selectedSendCodec(), sendPacketSize: self.selectedSendPacketSize(),
                pushToTalk: self.pushToTalkSettings, completion: wanted.completion)
        }
        let apply = { [weak self] in
            guard let self, self.browserListener.isCurrentSourceScope(browserScope) else { return }
            self.browserListener.performSource(.audioOptions, commit)
        }
        if requestedInputSending && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            ensureMicrophoneAccess { [weak self] allowed in
                guard let self, self.browserListener.isCurrentSourceScope(browserScope) else { return }
                if let keyRequest, self.pushToTalkInput?.isCurrent(keyRequest) != true { return }
                if allowed {
                    self.send.state = .on
                    self.saveAudioOptions()
                    self.refreshPermissionStatus()
                    apply()
                } else {
                    if let keyRequest { self.pushToTalkInput?.acknowledge(keyRequest, receipt: nil) }
                    self.uiObservations.handlerReturned(observation)
                    self.uiObservations.finish(observation, outcome: .failed)
                    self.pendingUIEffects.removeValue(forKey: .audioConfiguration)
                    self.send.state = .off
                    self.saveAudioOptions()
                    self.refreshPermissionStatus()
                    self.refreshStatusItem()
                    self.recordStartup("Input sending rejected: microphone authorization \(AVCaptureDevice.authorizationStatus(for: .audio)).")
                    self.announce("Microphone access is not allowed. Input sending remains off. Check Preferences, Permissions.")
                }
            }
        } else { apply() }
    }
    @objc private func audioCheckboxChanged(_ sender: NSButton) {
        if sender !== plugins {
            CueSounds.shared.play(sender.state == .on ? .checkboxOn : .checkboxOff)
        }
        audioOptionsChanged()
    }
    @objc private func togglePeer() {
        let i = table.selectedRow
        guard rows.indices.contains(i) else { return }
        let selected = !rows[i].selected
        let address = rows[i].address
        let observation = beginUIObservation(.peerSelection, matches: {
            $0.peers.first(where: { $0.address == address })?.selected == selected
        })
        defer { uiObservations.handlerReturned(observation) }
        session.setSelected(address: rows[i].address, selected: selected)
        announceCheckState(selected, in: table)
    }
    private func buildPeerNameAlert(initial: String) -> (NSAlert, NSTextField) {
        let alert = NSAlert()
        alert.messageText = "Rename Peer"
        alert.informativeText = "Enter a name of up to 80 characters. This computer's friendly name applies across profiles. Clear the field to forget the name. Profile files are not changed."
        alert.addButton(withTitle: "Save Name")
        alert.addButton(withTitle: "Cancel")
        // Windows' Rename peer has "Clear custom name": the peer goes back to the name it announces.
        alert.addButton(withTitle: "Clear Custom Name")
        let input = NSTextField(string: initial)
        input.setAccessibilityLabel("Peer name")
        input.setAccessibilityHelp("Clear the text to restore the name announced by this peer.")
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        input.identifier = NSUserInterfaceItemIdentifier("help-dialog-peer-name-input")
        FocusedHelpContent.markAlert(alert, notice: "dialog-peer-name-notice", buttons: ["dialog-peer-name-accept", "dialog-peer-name-cancel", "dialog-peer-name-clear"], helpDelegate: self)
        return (alert, input)
    }
    @objc private func renameHighlightedPeer() {
        guard rows.indices.contains(table.selectedRow) else {
            announce("Highlight a peer before renaming it.")
            return
        }
        let selected = rows[table.selectedRow]
        let (alert, input) = buildPeerNameAlert(initial: session.friendlyNameForPeer(address: selected.address) ?? "")
        let answer = alert.runModal()
        guard answer == .alertFirstButtonReturn || answer == .alertThirdButtonReturn else { return }
        let alias = answer == .alertThirdButtonReturn ? ""
            : String(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        session.setPeerAlias(address: selected.address, alias: alias, expectedDisplayName: selected.name)
    }
    @objc private func showNamedPeers() {
        if let namedPeersWindow { namedPeersWindow.refresh(); namedPeersWindow.present(); return }
        let panel = makeNamedPeersWindow()
        namedPeersWindow = panel
        panel.present()
    }
    private func makeNamedPeersWindow() -> NamedPeersWindow {
        NamedPeersWindow(owner: window, contextHelp: contextHelpAction, alertHelpDelegate: self,
            read: { [weak self] in self?.session.namedPeerRecords },
            rename: { [weak self] record, name in self?.session.renameNamedPeer(record, friendlyName: name) ?? false },
            forget: { [weak self] records in self?.session.forgetNamedPeers(records) ?? false },
            announce: { [weak self] message in self?.announce(message) })
    }
    /// The plugins' marker (Plugin/Source/PluginLog.h): present while logs are on. Only the person's own logs folder;
    /// an isolated run never touches it.
    private func syncPluginLogMarker() {
        guard !AppRuntime.configuration.isIsolated, pluginLogMarkerShown != effectiveLoggingEnabled else { return }
        let marker = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RemSound/.plugin-logging-on")
        if effectiveLoggingEnabled {
            try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: marker.path, contents: Data())
        } else {
            try? FileManager.default.removeItem(at: marker)
        }
        pluginLogMarkerShown = effectiveLoggingEnabled
    }
    /// Into the log when a browser's gaps, catch-ups, drops or reconnects change, and once a minute regardless (Windows
    /// WebListener.LogBrowsers), so how a connection held up can be read afterwards.
    private func logBrowsers() {
        guard let browserService else { return }
        browserService.describeBrowsers { [weak self] lines in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            var seen = Set<Int>()
            for line in lines {
                guard let number = Int(line.dropFirst("Browser ".count).prefix { $0.isNumber }), !line.hasSuffix("just joined.") else { continue }
                seen.insert(number)
                let key = WebBrowsersText.logKey(line)
                if let last = self.loggedBrowsers[number], last.key == key, now - last.at < 60 { continue }
                self.loggedBrowsers[number] = (key, now)
                self.session.note("web listener: " + line.prefix(1).lowercased() + line.dropFirst())
            }
            for number in self.loggedBrowsers.keys where !seen.contains(number) { self.loggedBrowsers.removeValue(forKey: number) }
        }
    }
    /// The Connection status box, once a second; left alone while it has the focus (Windows' rule). It is kept current
    /// while the window is hidden too, for the speak status key.
    private func refreshConnectionStatus() {
        session.connectionStatus { [weak self] text in
            guard let self, self.connectionStatus.stringValue != text else { return }
            if let responder = self.window.firstResponder,
               responder === self.connectionStatus || responder === self.connectionStatus.currentEditor() { return }
            self.connectionStatus.stringValue = text
        }
    }
    /// The details box for the highlighted peer; left alone while it has the focus or the window is hidden.
    private func refreshPeerDetails() {
        guard window.isVisible else { return }
        if let responder = window.firstResponder, responder === peerDetails || responder === peerDetails.currentEditor() { return }
        guard rows.indices.contains(table.selectedRow) else {
            if peerDetails.stringValue != PeerDetailsText.nothingHighlighted { peerDetails.stringValue = PeerDetailsText.nothingHighlighted }
            return
        }
        session.peerDetails(address: rows[table.selectedRow].address) { [weak self] text in
            guard let self, self.peerDetails.stringValue != text else { return }
            if let responder = self.window.firstResponder, responder === self.peerDetails { return }
            self.peerDetails.stringValue = text
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === table else { return }
        refreshPeerDetails()
        if rows.indices.contains(table.selectedRow),
            let item = mixPeer.itemArray.first(where: {
                $0.representedObject as? String == rows[table.selectedRow].address
            }) {
            mixPeer.select(item)
        }
        updatePeerMixControls()
    }
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        if tabView === preferencesTabs {
            let selected = preferencesTabs.selectedTabViewItem
            let controls: [NSView]
            switch selected?.identifier as? String {
            case "audio-cues":
                cuePane.select(.save, preview: false)
                controls = cuePane.tabOrder
            case "permissions": controls = permissionsControlOrder
            default: controls = generalPreferencesOrder
            }
            preferencesControlOrder = [preferencesTabs] + controls
            for (index, control) in preferencesControlOrder.enumerated() {
                control.nextKeyView = preferencesControlOrder[
                    (index + 1) % preferencesControlOrder.count]
            }
            selected?.view?.nextKeyView = controls.first
            refreshPermissionStatus()
            return
        }
        // By name, not place: the tabs can be reordered, and the Pan / EQ tab hidden, in Preferences.
        guard let tabViewItem,
            let index = mainTabItems.firstIndex(of: tabViewItem) ?? tabs.tabViewItems.firstIndex(of: tabViewItem),
            tabFirstControls.indices.contains(index) else { return }
        tabViewItem.view?.nextKeyView = tabFirstControls[index]
        if let selectedAudioTab, selectedAudioTab != index {
            CueSounds.shared.play(.tabSwitch)
        }
        selectedAudioTab = index
    }
    @objc private func mixPeerChanged() {
        guard let address = mixPeer.selectedItem?.representedObject as? String,
            let row = rows.firstIndex(where: { $0.address == address }) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        updatePeerMixControls()
    }
    private func refreshMixPeerChoices() {
        let choicesChanged = mixPeer.itemArray.count != rows.count
            || zip(mixPeer.itemArray, rows).contains { item, peer in
                item.representedObject as? String != peer.address || item.title != peer.name
            }
        guard choicesChanged else { return }
        let previous = mixPeer.selectedItem?.representedObject as? String
        mixPeer.removeAllItems()
        for peer in rows {
            mixPeer.addItem(withTitle: peer.name)
            mixPeer.lastItem?.representedObject = peer.address
        }
        let highlighted = rows.indices.contains(table.selectedRow)
            ? rows[table.selectedRow].address : nil
        if let address = highlighted ?? previous,
            let item = mixPeer.itemArray.first(where: { $0.representedObject as? String == address }) {
            mixPeer.select(item)
        } else if !rows.isEmpty {
            mixPeer.selectItem(at: 0)
        }
        mixPeer.isEnabled = !rows.isEmpty
    }
    private func updatePeerMixControls() {
        let selected = mixPeer.selectedItem?.representedObject as? String
        let mix = selected.flatMap { peerMixes[$0] } ?? PeerMix()
        let have = selected != nil
        for control in ([peerMixEnabled, peerVolume, peerPan, eqMode, resetPeerEq] as [NSControl]) + (eqBandSliders as [NSControl]) {
            control.isEnabled = have
        }
        peerMixEnabled.state = mix.enabled ? .on : .off
        peerVolume.integerValue = mix.volume
        peerPan.integerValue = mix.pan
        peerVolume.setAccessibilityLabel("Selected peer volume, \(mix.volume) percent")
        let panText = mix.pan == 0 ? "centre"
            : mix.pan < 0 ? "left \(-mix.pan) percent" : "right \(mix.pan) percent"
        peerPan.setAccessibilityLabel("Selected peer pan, \(panText)")
        updateEqControls(mix, have: have)
    }
    private func updateEqControls(_ mix: PeerMix, have: Bool) {
        eqMode.selectItem(at: mix.eq.mode.rawValue)
        // The graphic sliders: three (bass, mids, treble) or twelve, named with their gain in words.
        let graphic: [(label: String, hz: Double)] = mix.eq.mode == .advanced12Band ? PeerEqBands.advanced
            : mix.eq.mode == .simple3Band ? PeerEqBands.simple : []
        let gains = mix.eq.mode == .advanced12Band ? mix.eq.advancedDb : mix.eq.simpleDb
        for i in eqBandSliders.indices {
            let shown = i < graphic.count
            if eqBandRows[i].isHidden == shown { eqBandRows[i].isHidden = !shown }
            guard shown else { continue }
            eqBandLabels[i].stringValue = graphic[i].label
            eqBandSliders[i].integerValue = PeerEqBands.slider(db: gains[i])
            describeBand(i, label: graphic[i].label)
        }
        // The parametric EQ: Add band (up to 16), the list, Delete band.
        let parametric = mix.eq.mode == .parametric16Band
        for view in [addBandButton, bandsLabel, bandListScroll, deleteBandButton] as [NSView] where view.isHidden == parametric {
            view.isHidden = !parametric
        }
        let rows = mix.eq.parametricInOrder.map { (index: $0.index, text: $0.band.row) }
        if bandList.rows.map({ $0.text }) != rows.map({ $0.text }) || bandList.rows.map({ $0.index }) != rows.map({ $0.index }) {
            let keep = bandList.selectedRowIndexes
            bandList.rows = rows
            bandList.selectRowIndexes(keep.filteredIndexSet { $0 < rows.count }, byExtendingSelection: false)
        }
        bandList.isEnabled = have
        addBandButton.isEnabled = have && mix.eq.parametric.count < PeerEqBands.parametricMaxBands
        deleteBandButton.isEnabled = have && !mix.eq.parametric.isEmpty
    }
    private func describeBand(_ i: Int, label: String) {
        let words = PeerEqBands.spoken(PeerEqBands.db(slider: eqBandSliders[i].integerValue))
        eqBandSliders[i].setAccessibilityLabel("\(label): \(words.replacingOccurrences(of: " dB", with: " decibels"))")
    }

    /// The opt-in native gate exercises the real actions and profile snapshot in its disposable configuration.
    private func sliderResetAccessibilityFailures() -> [String] {
        guard AppRuntime.configuration.isIsolated, CommandLine.arguments.contains("--check-accessibility") else {
            return ["Slider workflow requires the isolated accessibility gate"]
        }
        var failures: [String] = []
        let previousTab = tabs.selectedTabViewItem
        let previousResponder = window.firstResponder
        let previousVolume = listeningVolume.doubleValue
        let previousMixes = peerMixes
        let previousMenu = mixPeer.menu?.copy() as? NSMenu
        let previousSelection = mixPeer.indexOfSelectedItem
        let savedVolume = AppRuntime.settings.object(forKey: "listeningVolume")
        let savedMute = AppRuntime.settings.object(forKey: "receiveMuted")
        let savedMixes = AppRuntime.settings.object(forKey: "peerMixes")
        defer {
            listeningVolume.doubleValue = previousVolume
            listeningChanged()
            peerMixes = previousMixes
            mixPeer.menu = previousMenu
            if previousSelection >= 0 { mixPeer.selectItem(at: previousSelection) }
            updatePeerMixControls()
            AppRuntime.settings.set(savedVolume, forKey: "listeningVolume")
            AppRuntime.settings.set(savedMute, forKey: "receiveMuted")
            AppRuntime.settings.set(savedMixes, forKey: "peerMixes")
            if let previousTab { tabs.selectTabViewItem(previousTab) }
            window.makeFirstResponder(previousResponder)
        }
        window.makeKeyAndOrderFront(nil)
        func reset(_ slider: ResettableSlider, from: Double, to expected: Double, keypad: Bool = false) {
            slider.doubleValue = from
            guard slider.accessibilityHelp()?.contains("Return") == true,
                slider.cell?.accessibilityRole() == .slider, window.makeFirstResponder(slider) else {
                failures.append("Slider reset lacks native focus, role or context help")
                return
            }
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: keypad ? .numericPad : [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: keypad ? "\u{3}" : "\r", charactersIgnoringModifiers: keypad ? "\u{3}" : "\r",
                isARepeat: false, keyCode: UInt16(keypad ? kVK_ANSI_KeypadEnter : kVK_Return)) else {
                failures.append("Could not construct slider reset event")
                return
            }
            NSApp.sendEvent(event)
            if slider.doubleValue != expected || window.firstResponder !== slider {
                failures.append("Return must reset the focused slider and preserve its focus")
            }
        }
        tabs.selectTabViewItem(at: 1)
        reset(listeningVolume, from: 37, to: 100)
        if AppRuntime.settings.integer(forKey: "listeningVolume") != 100
            || profileSnapshot(id: UUID(), title: "Slider check", readOnly: false).listeningVolume != 100 {
            failures.append("Master volume reset must use its normal settings and profile path")
        }
        let fixturePeer = "isolated-slider-check"
        mixPeer.removeAllItems()
        mixPeer.addItem(withTitle: "Slider check peer")
        mixPeer.lastItem?.representedObject = fixturePeer
        var mix = PeerMix()
        mix.enabled = true
        mix.volume = 37
        mix.pan = -61
        peerMixes[fixturePeer] = mix
        tabs.selectTabViewItem(at: 3)
        updatePeerMixControls()
        reset(peerVolume, from: 37, to: 100)
        reset(peerPan, from: -61, to: 0, keypad: true)
        for mode in [PeerEqMode.simple3Band, .advanced12Band] {
            peerMixes[fixturePeer]?.eq.mode = mode
            if mode == .simple3Band { peerMixes[fixturePeer]?.eq.simpleDb = [3, 3, 3] }
            else { peerMixes[fixturePeer]?.eq.advancedDb = [Float](repeating: 3, count: 12) }
            updatePeerMixControls()
            for index in 0..<(mode == .simple3Band ? 3 : 12) {
                reset(eqBandSliders[index], from: 73, to: 50, keypad: index.isMultiple(of: 2))
            }
            let gains = mode == .simple3Band ? peerMixes[fixturePeer]?.eq.simpleDb : peerMixes[fixturePeer]?.eq.advancedDb
            if gains?.allSatisfy({ $0 == 0 }) != true { failures.append("Each EQ reset must save flat gain") }
        }
        let snapshot = profileSnapshot(id: UUID(), title: "Slider check", readOnly: false)
        let stored = AppRuntime.settings.data(forKey: "peerMixes")
            .flatMap { try? JSONDecoder().decode([String: PeerMix].self, from: $0) }
        if snapshot.peerMixes[fixturePeer]?.volume != 100 || snapshot.peerMixes[fixturePeer]?.pan != 0
            || stored?[fixturePeer] != peerMixes[fixturePeer] {
            failures.append("Peer reset actions must persist their values and retain them in the profile snapshot")
        }
        return failures
    }
    /// The highlighted peer's settings, changed and put where they are heard and saved.
    private func changePeerMix(_ change: (inout PeerMix) -> Void) {
        guard let address = mixPeer.selectedItem?.representedObject as? String else { return }
        var mix = peerMixes[address] ?? PeerMix()
        change(&mix)
        peerMixes[address] = mix
        if let data = try? JSONEncoder().encode(peerMixes) {
            AppRuntime.settings.set(data, forKey: "peerMixes")
        }
        session.setPeerMix(address: address, mix: mix)
        updatePeerMixControls()
    }
    @objc private func peerMixChanged() {
        changePeerMix { mix in
            mix.enabled = peerMixEnabled.state == .on
            mix.volume = min(100, max(0, peerVolume.integerValue))
            mix.pan = min(100, max(-100, peerPan.integerValue))
        }
    }
    @objc private func eqModeChanged() {
        guard let mode = PeerEqMode(rawValue: eqMode.indexOfSelectedItem),
            let address = mixPeer.selectedItem?.representedObject as? String else { return }
        session.note("shaping: EQ mode → \(mode.logName) for \(address)")
        changePeerMix { $0.eq.mode = mode }
    }
    @objc private func eqBandChanged(_ sender: NSSlider) {
        guard let i = eqBandSliders.firstIndex(where: { $0 === sender }) else { return }
        changePeerMix { mix in
            let db = PeerEqBands.db(slider: sender.integerValue)
            if mix.eq.mode == .advanced12Band { mix.eq.advancedDb[i] = db }
            else if mix.eq.mode == .simple3Band, i < mix.eq.simpleDb.count { mix.eq.simpleDb[i] = db }
        }
    }
    @objc private func addBandPressed() {
        guard let address = mixPeer.selectedItem?.representedObject as? String else { return }
        let saved = peerMixes[address] ?? PeerMix()
        guard saved.eq.parametric.count < PeerEqBands.parametricMaxBands else { return }
        // Heard while it is typed: the saved bands and this one; nil puts the saved sound back.
        let band = AddBandDialog.run(helpDelegate: self) { [weak self] band in
            var preview = saved
            preview.eq.mode = .parametric16Band
            if let band { preview.eq.parametric.append(band) }
            self?.session.setPeerMix(address: address, mix: band == nil ? saved : preview)
        }
        guard let band else {
            session.setPeerMix(address: address, mix: saved)
            return
        }
        changePeerMix { $0.eq.parametric.append(band) }
        let count = peerMixes[address]?.eq.parametric.count ?? 0
        session.note("shaping: added parametric band \(Int(band.startHz.rounded()))-\(Int(band.endHz.rounded())) Hz \(PeerEqBands.oneDecimal(band.gainDb)) dB for \(address) (\(count) band(s))")
        window.makeFirstResponder(bandList)
    }
    @objc private func deleteBandPressed() { deleteBands(bandList.selectedIndices) }
    private func deleteBands(_ indices: [Int]) {
        guard !indices.isEmpty, let address = mixPeer.selectedItem?.representedObject as? String else { return }
        let firstRow = bandList.selectedRowIndexes.first ?? 0
        changePeerMix { mix in
            for i in indices.sorted(by: >) where mix.eq.parametric.indices.contains(i) { mix.eq.parametric.remove(at: i) }
        }
        let left = peerMixes[address]?.eq.parametric.count ?? 0
        session.note("shaping: deleted \(indices.count) parametric band(s) for \(address) (\(left) left)")
        // Put the cursor on whatever now holds the first removed row, so it is read out.
        if left > 0 {
            bandList.selectRowIndexes(IndexSet(integer: min(firstRow, left - 1)), byExtendingSelection: false)
            window.makeFirstResponder(bandList)
        } else {
            window.makeFirstResponder(addBandButton)
        }
    }
    private func nudgeBands(_ indices: [Int], by step: Float) {
        changePeerMix { $0.eq.nudge(indices, by: step) }
        let focused = bandList.selectedRow >= 0 && bandList.rows.indices.contains(bandList.selectedRow)
            ? bandList.rows[bandList.selectedRow].index : indices.first
        guard let address = mixPeer.selectedItem?.representedObject as? String, let focused,
            let band = peerMixes[address]?.eq.parametric[focused] else { return }
        bandList.speak(PeerEqBands.spokenPrecise(band.gainDb).replacingOccurrences(of: " dB", with: " decibels"))
    }
    @objc private func resetPeerEqPressed() {
        changePeerMix { $0.eq.reset() }
        announce("Peer EQ set to default.")
    }
    @objc private func allPeerShapingChanged() {
        let on = allPeerShaping.state == .on
        AppRuntime.settings.set(on, forKey: "enableAllPeerShaping")
        session.setAllPeerShaping(on)
        session.note("ui: shaping: master switch → \(on ? "on" : "off") (\(peerMixes.count) peer(s) with saved shaping)")
    }
    private func updateControlAvailability(_ running: Bool) {
        if start.isEnabled == running { start.isEnabled = !running }
        if stop.isEnabled != running { stop.isEnabled = running }
        if recordingButton.isEnabled != running { recordingButton.isEnabled = running }
        if statusRecord.isEnabled != running { statusRecord.isEnabled = running }
        for control in [name, peer, password] where control.isEnabled == running {
            control.isEnabled = !running
        }
        for control in [send, systemAudio, receive, monitor, plugins] where !control.isEnabled {
            control.isEnabled = true
        }
        if statusStart.isEnabled == running { statusStart.isEnabled = !running }
        if statusStop.isEnabled != running { statusStop.isEnabled = running }
    }
    private func update(_ view: SessionView) {
        browserListener.observe(running: view.running, binding: view.networkBinding, workerGeneration: view.pushToTalkKeyGeneration)
        routerControls?.observe(running: view.running, binding: view.networkBinding)
        pushToTalkInput?.observe(settings: view.pushToTalk, running: view.running,
            generation: view.pushToTalkKeyGeneration)
        controlView = view
        let updateObservation = uiObservations.begin(.sessionViewUpdate)
        defer {
            observeUIEffects(view)
            uiObservations.endQuietScope(updateObservation)
        }
        let wasRecording = recordingButton.title == "Stop recording"
        let previousConnectedPeerCount = connectedPeerCount
        running = view.running
        rememberedPeerEntries = view.rememberedPeerEntries
        connectivityPeers.refresh(entries: rememberedPeerEntries, running: view.running,
            locked: AppRuntime.settings.bool(forKey: "lockPeerAddresses"))
        if !view.running {dispatchProfileAfterStop()}
        let recordTitle = view.recording ? "Stop recording" : "Start recording"
        if wasRecording != view.recording {
            CueSounds.shared.play(view.recording ? .recordStart : .recordStop)
        }
        if recordingButton.title != recordTitle { recordingButton.title = recordTitle }
        if statusRecord.title != recordTitle { statusRecord.title = recordTitle }
        updateControlAvailability(view.running)
        if networkRTT != view.networkRTT {
            networkRTT = view.networkRTT
            refreshReceiveLatencyStatus()
        }
        if view.running {
            if selectedReceiveArtifact() != view.receiveArtifact { selectReceiveArtifact(view.receiveArtifact) }
            if selectedReceiveSmoothness() != view.receiveSmoothness { selectReceiveSmoothness(view.receiveSmoothness) }
            if selectedReceiveJitterMs() != view.receiveJitterMs {
                receiveJitter.selectItem(withTitle: "\(view.receiveJitterMs) milliseconds")
                refreshReceiveLatencyStatus()
            }
            send.state = view.sendingInput ? .on : .off
            systemAudio.state = view.sendingSystemAudio ? .on : .off
            receive.state = view.receiving ? .on : .off
            monitor.state = view.monitoringInApp ? .on : .off
            plugins.state = view.allowingPlugins ? .on : .off
            if view.status.hasPrefix("Audio device changed")
                || selectedInputUIDs != view.inputDeviceUIDs
                || selectedInputChannelPairs != view.inputChannelPairs
                || selectedOutputUIDs != view.outputDeviceUIDs
                || selectedOutputChannelPairs != view.outputChannelPairs
                || selectedCaptureUIDs != view.systemCaptureDeviceUIDs
                || selectedCaptureChannelPairs != view.systemCaptureChannelPairs {
                populateDeviceChoices(inputUIDs: view.inputDeviceUIDs,
                    inputChannelPairs: view.inputChannelPairs,
                    outputUIDs: view.outputDeviceUIDs,
                    outputChannelPairs: view.outputChannelPairs,
                    systemCaptureUIDs: view.systemCaptureDeviceUIDs,
                    systemCapturePairs: view.systemCaptureChannelPairs)
            }
            saveAudioOptions()
            refreshPermissionStatus()
            AppRuntime.settings.set(
                view.selectedPeerAddresses, forKey: "selectedPeerAddresses")
        }
        connectedPeerCount = view.peers.filter { $0.selected && $0.status.hasPrefix("Connected") }.count
        if previousConnectedPeerCount != connectedPeerCount {
            CueSounds.shared.play(connectedPeerCount > previousConnectedPeerCount
                ? .connect : .disconnect)
        }
        refreshStatusItem()
        if rows != view.peers {
            let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].address : nil
            let sameRows = rows.map { $0.address } == view.peers.map { $0.address }
            let changed = IndexSet(
                view.peers.indices.filter { !rows.indices.contains($0) || rows[$0] != view.peers[$0] })
            rows = view.peers
            if sameRows {
                // Keep native row objects and focus while rounded status values change.
                for index in changed {
                    if let field=table.view(atColumn:0,row:index,makeIfNecessary:false) as? NSTextField {
                        let peer=rows[index]
                        PeerStatusCell.update(field,name:peer.name,address:peer.address,selected:peer.selected,status:peer.status)
                    }
                }
            } else {
                table.reloadData()
            }
            if let selected, let i = rows.firstIndex(where: { $0.address == selected }) {
                table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
            }
            refreshMixPeerChoices()
            updatePeerMixControls()
        }
        if statusSummary.title != view.status { statusSummary.title = view.status }
        if status.stringValue != view.status {
            if connectivityPeers.handlesOperationStatus(view.status) { status.stringValue = view.status }
            else { announce(view.status) }
        }
    }
    private func announce(_ message: String) {
        status.stringValue = message
        guard !AppRuntime.configuration.silent else { return }
        NSAccessibility.post(
            element: status, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    private func announceCheckState(_ checked: Bool, in table: NSTableView) {
        guard !AppRuntime.configuration.silent else { return }
        let message = checked ? "Checked" : "Unchecked"
        CueSounds.shared.play(checked ? .checkboxOn : .checkboxOff)
        DispatchQueue.main.async {
            NSAccessibility.post(element: table, notification: .announcementRequested,
                userInfo: [.announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === activeAppsTable { return activeApps.count }
        if tableView === rememberedAppsTable { return rememberedApps.count }
        if tableView === inputTable { return inputChoices.count }
        if tableView === inputPairTable { return inputPairChoices.count }
        if tableView === outputTable { return outputChoices.count }
        if tableView === outputPairTable { return outputPairChoices.count }
        if tableView === systemOutputPairTable { return systemOutputPairChoices.count }
        return tableView === systemOutputTable ? systemOutputs.count + 1 : rows.count
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === activeAppsTable {
            return captureTextCell(activeApps[row].row, help: "Space ticks or unticks this application.")
        }
        if tableView === rememberedAppsTable {
            return captureTextCell(rememberedApps[row].row, help: "Space ticks this application to send it again; Delete forgets it.")
        }
        if tableView === inputTable {
            return captureTextCell(inputRowLabel(row), help: inputChoices[row].uid.isEmpty
                ? "Space toggles the default input and clears named inputs."
                : "Space toggles this input without changing other named inputs.")
        }
        if tableView === inputPairTable {
            return captureTextCell(inputPairRowLabel(row), help:
                "Space toggles this stereo input pair. Checking it also selects its interface.")
        }
        if tableView === outputTable {
            return captureTextCell(outputRowLabel(row), help: outputChoices[row].uid.isEmpty
                ? "Space toggles the default output and clears named cards."
                : "Space toggles this output card without changing other named cards.")
        }
        if tableView === outputPairTable {
            return captureTextCell(outputPairRowLabel(row), help:
                "Space toggles Mac app playback on this stereo output pair. Clearing its last pair deselects its card.")
        }
        if tableView === systemOutputTable {
            return systemOutputCell(row: row, help: row == 0
                ? "Space toggles all current and future outputs."
                : "Space toggles this output without changing other selected outputs.")
        }
        if tableView === systemOutputPairTable {
            return captureTextCell(systemOutputPairRowLabel(row), help:
                "Space toggles this stereo capture pair. Clearing its last pair deselects its output card.")
        }
        let p = rows[row]
        return PeerStatusCell.make(name:p.name,address:p.address,selected:p.selected,status:p.status)
    }
    private func captureTextCell(_ text: String, help: String) -> NSTextField {
        let cell = NSTextField(labelWithString: text)
        cell.setAccessibilityLabel(text)
        cell.setAccessibilityHelp(help)
        return cell
    }
    private func systemOutputCell(row: Int, help: String) -> NSButton {
        let title = row == 0 ? "All system outputs" : systemOutputs[row - 1].name
        let button = NSButton(checkboxWithTitle: title,
            target: self, action: #selector(captureCheckboxChanged(_:)))
        button.state = captureOutputSelected(row) ? .on : .off
        button.tag = row
        button.setAccessibilityHelp(help)
        return button
    }
    @objc private func captureCheckboxChanged(_ sender: NSButton) {
        systemOutputTable.toggle?(sender.tag)
    }
    private func captureOutputSelected(_ row: Int) -> Bool {
        if row == 0 { return selectedCaptureUIDs == nil }
        return selectedCaptureUIDs == nil
            || selectedCaptureUIDs?.contains(systemOutputs[row - 1].uid) == true
    }
    private func inputRowLabel(_ row: Int) -> String {
        let choice = inputChoices[row]
        return "\(choice.name), \(selectedInputUIDs.contains(choice.uid) ? "checked" : "unchecked")"
    }
    private func inputPairRowLabel(_ row: Int) -> String {
        let choice = inputPairChoices[row]
        let checked = selectedInputUIDs.contains(choice.uid)
            && (selectedInputChannelPairs[choice.uid] ?? [0]).contains(choice.pair)
        return "\(choice.name), channels \(choice.pair * 2 + 1) and "
            + "\(choice.pair * 2 + 2), \(checked ? "checked" : "unchecked")"
    }
    private func outputPairRowLabel(_ row: Int) -> String {
        let choice = outputPairChoices[row]
        let checked = selectedOutputUIDs.contains(choice.uid)
            && (selectedOutputChannelPairs[choice.uid] ?? [0]).contains(choice.pair)
        return "\(choice.name), channels \(choice.pair * 2 + 1) and "
            + "\(choice.pair * 2 + 2), \(checked ? "checked" : "unchecked")"
    }
    private func systemOutputPairRowLabel(_ row: Int) -> String {
        let choice = systemOutputPairChoices[row]
        let checked = selectedCaptureUIDs?.contains(choice.uid) == true
            && (selectedCaptureChannelPairs[choice.uid] ?? [0]).contains(choice.pair)
        return "\(choice.name), channels \(choice.pair * 2 + 1) and "
            + "\(choice.pair * 2 + 2), \(checked ? "checked" : "unchecked")"
    }
    private func outputRowLabel(_ row: Int) -> String {
        let choice = outputChoices[row]
        return "\(choice.name), \(selectedOutputUIDs.contains(choice.uid) ? "checked" : "unchecked")"
    }
    private func togglePlaybackOutput(_ row: Int) {
        guard outputChoices.indices.contains(row) else { return }
        let uid = outputChoices[row].uid
        let wasChecked = selectedOutputUIDs.contains(uid)
        selectedOutputUIDs = AudioInputSelection.toggle(row: row,
            current: selectedOutputUIDs, available: outputChoices.map(\.uid))
        if !uid.isEmpty && selectedOutputUIDs.contains(uid)
            && selectedOutputChannelPairs[uid]?.isEmpty != false {
            selectedOutputChannelPairs[uid] = [0]
        }
        let wasMonitoring = monitor.state == .on
        let monitoring = PlaybackMonitoringState.afterSelection(wasChecked: wasChecked,
            isChecked: selectedOutputUIDs.contains(uid),
            hasOutputs: !selectedOutputUIDs.isEmpty, monitoring: wasMonitoring)
        monitor.state = monitoring ? .on : .off
        if monitoring != wasMonitoring {
            NSAccessibility.post(element: monitor, notification: .valueChanged)
        }
        updateCaptureRows(outputTable)
        updateCaptureRows(outputPairTable)
        audioOptionsChanged()
        announceCheckState(selectedOutputUIDs.contains(uid), in: outputTable)
    }
    private func toggleOutputPair(_ row: Int) {
        guard outputPairChoices.indices.contains(row) else { return }
        let choice = outputPairChoices[row]
        let wasChecked = selectedOutputUIDs.contains(choice.uid)
            && (selectedOutputChannelPairs[choice.uid] ?? [0]).contains(choice.pair)
        let selection = PlaybackPairSelection.toggle(uid: choice.uid, pair: choice.pair,
            devices: selectedOutputUIDs, pairs: selectedOutputChannelPairs,
            available: outputChoices.map(\.uid))
        selectedOutputUIDs = selection.devices
        selectedOutputChannelPairs = selection.pairs
        let isChecked = selectedOutputUIDs.contains(choice.uid)
            && (selectedOutputChannelPairs[choice.uid] ?? [0]).contains(choice.pair)
        let wasMonitoring = monitor.state == .on
        let monitoring = PlaybackMonitoringState.afterSelection(wasChecked: wasChecked,
            isChecked: isChecked, hasOutputs: !selectedOutputUIDs.isEmpty,
            monitoring: wasMonitoring)
        monitor.state = monitoring ? .on : .off
        if monitoring != wasMonitoring {
            NSAccessibility.post(element: monitor, notification: .valueChanged)
        }
        updateCaptureRows(outputTable)
        updateCaptureRows(outputPairTable)
        audioOptionsChanged()
        announceCheckState(isChecked, in: outputPairTable)
    }
    @objc private func uncheckAllDevicesPressed() {
        // Sending that was on comes back when a device is ticked again, as unticking the last one does.
        resumeInputSendingWhenSelected = resumeInputSendingWhenSelected || send.state == .on
        resumeSystemSendingWhenSelected = resumeSystemSendingWhenSelected || systemAudio.state == .on
        selectedInputUIDs = []; selectedInputChannelPairs = [:]
        selectedOutputUIDs = []; selectedOutputChannelPairs = [:]
        selectedCaptureUIDs = []; selectedCaptureChannelPairs = [:]
        send.state = .off; systemAudio.state = .off; monitor.state = .off
        for table in [inputTable, inputPairTable, outputTable, outputPairTable, systemOutputTable, systemOutputPairTable] {
            updateCaptureRows(table)
        }
        audioOptionsChanged()
        announce("All inputs and outputs unchecked.")
    }
    private func toggleAudioInput(_ row: Int) {
        guard inputChoices.indices.contains(row) else { return }
        let previouslyEmpty = selectedInputUIDs.isEmpty
        selectedInputUIDs = AudioInputSelection.toggle(row: row,
            current: selectedInputUIDs, available: inputChoices.map(\.uid))
        let uid = inputChoices[row].uid
        if !uid.isEmpty && inputPairChoices.contains(where: { $0.uid == uid }) {
            selectedInputChannelPairs[uid] = selectedInputUIDs.contains(uid) ? [0] : nil
        }
        let state = CaptureSendState.afterSelection(previouslyEmpty: previouslyEmpty,
            nowEmpty: selectedInputUIDs.isEmpty, sending: send.state == .on,
            resumePending: resumeInputSendingWhenSelected)
        send.state = state.sending ? .on : .off
        resumeInputSendingWhenSelected = state.resumePending
        updateCaptureRows(inputTable)
        updateCaptureRows(inputPairTable)
        audioOptionsChanged()
        announceCheckState(selectedInputUIDs.contains(inputChoices[row].uid), in: inputTable)
    }
    private func toggleInputPair(_ row: Int) {
        guard inputPairChoices.indices.contains(row) else { return }
        let choice = inputPairChoices[row]
        let previouslyEmpty = selectedInputUIDs.isEmpty
        var pairs = selectedInputUIDs.contains(choice.uid)
            ? selectedInputChannelPairs[choice.uid] ?? [0] : []
        if pairs.contains(choice.pair) { pairs.removeAll { $0 == choice.pair } }
        else { pairs.append(choice.pair); pairs.sort() }
        selectedInputChannelPairs[choice.uid] = pairs.isEmpty ? nil : pairs
        if pairs.isEmpty {
            selectedInputUIDs.removeAll { $0 == choice.uid }
        } else if !selectedInputUIDs.contains(choice.uid) {
            selectedInputUIDs = AudioInputSelection.toggle(
                row: inputChoices.firstIndex(where: { $0.uid == choice.uid }) ?? -1,
                current: selectedInputUIDs, available: inputChoices.map(\.uid))
        }
        let state = CaptureSendState.afterSelection(previouslyEmpty: previouslyEmpty,
            nowEmpty: selectedInputUIDs.isEmpty, sending: send.state == .on,
            resumePending: resumeInputSendingWhenSelected)
        send.state = state.sending ? .on : .off
        resumeInputSendingWhenSelected = state.resumePending
        updateCaptureRows(inputTable)
        updateCaptureRows(inputPairTable)
        audioOptionsChanged()
        announceCheckState(pairs.contains(choice.pair), in: inputPairTable)
    }
    private func systemOutputRowLabel(_ row: Int) -> String {
        let name = row == 0 ? "All system outputs" : systemOutputs[row - 1].name
        return "\(name), \(captureOutputSelected(row) ? "checked" : "unchecked")"
    }
    private func updateCaptureRows(_ table: NSTableView) {
        for row in 0..<table.numberOfRows {
            if table === systemOutputTable {
                guard let button = table.view(atColumn: 0, row: row,
                    makeIfNecessary: false) as? NSButton else { continue }
                button.state = captureOutputSelected(row) ? .on : .off
                continue
            }
            guard let cell = table.view(atColumn: 0, row: row,
                makeIfNecessary: false) as? NSTextField else { continue }
            let text = table === inputTable ? inputRowLabel(row)
                : table === inputPairTable ? inputPairRowLabel(row)
                : table === outputTable ? outputRowLabel(row)
                : table === outputPairTable ? outputPairRowLabel(row)
                : systemOutputPairRowLabel(row)
            cell.stringValue = text
            cell.setAccessibilityLabel(text)
        }
    }
    private func toggleSystemOutput(_ row: Int) {
        guard row >= 0, row < systemOutputTable.numberOfRows else { return }
        let previouslyEmpty = selectedCaptureUIDs?.isEmpty == true
        selectedCaptureUIDs = SystemOutputSelection.toggle(row: row,
            current: selectedCaptureUIDs, available: systemOutputs.map(\.uid))
        if row > 0 {
            let uid = systemOutputs[row - 1].uid
            if selectedCaptureUIDs?.contains(uid) == true {
                selectedCaptureChannelPairs[uid] = [0]
            } else {
                selectedCaptureChannelPairs.removeValue(forKey: uid)
            }
        }
        let state = CaptureSendState.afterSelection(previouslyEmpty: previouslyEmpty,
            nowEmpty: selectedCaptureUIDs?.isEmpty == true, sending: systemAudio.state == .on,
            resumePending: resumeSystemSendingWhenSelected)
        systemAudio.state = state.sending ? .on : .off
        resumeSystemSendingWhenSelected = state.resumePending
        updateCaptureRows(systemOutputTable)
        updateCaptureRows(systemOutputPairTable)
        audioOptionsChanged()
        announceCheckState(captureOutputSelected(row), in: systemOutputTable)
    }
    private func toggleSystemOutputPair(_ row: Int) {
        guard systemOutputPairChoices.indices.contains(row) else { return }
        let choice = systemOutputPairChoices[row]
        let previouslyEmpty = selectedCaptureUIDs?.isEmpty == true
        let selected = selectedCaptureUIDs ?? []
        let selection = PlaybackPairSelection.toggle(uid: choice.uid, pair: choice.pair,
            devices: selected, pairs: selectedCaptureChannelPairs,
            available: systemOutputs.map(\.uid))
        selectedCaptureUIDs = selection.devices
        selectedCaptureChannelPairs = selection.pairs
        let state = CaptureSendState.afterSelection(previouslyEmpty: previouslyEmpty,
            nowEmpty: selectedCaptureUIDs?.isEmpty == true, sending: systemAudio.state == .on,
            resumePending: resumeSystemSendingWhenSelected)
        systemAudio.state = state.sending ? .on : .off
        resumeSystemSendingWhenSelected = state.resumePending
        updateCaptureRows(systemOutputTable)
        updateCaptureRows(systemOutputPairTable)
        audioOptionsChanged()
        let checked = selectedCaptureUIDs?.contains(choice.uid) == true
            && (selectedCaptureChannelPairs[choice.uid] ?? [0]).contains(choice.pair)
        announceCheckState(checked, in: systemOutputPairTable)
    }
    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if nativeProductFixture { statusItem.isVisible = false }
        statusItem.button?.title = "RemSound"
        statusItem.button?.setAccessibilityLabel("RemSound, stopped")
        statusItem.button?.toolTip = "RemSound audio connection"
        statusItem.menu = makeStatusMenu()
    }

    private func makeStatusMenu() -> NSMenu {
        let manual = FocusedHelpContent.bundledManual()
        func mark(_ item: NSMenuItem, _ key: String) -> NSMenuItem {
            FocusedHelpContent.markMenuItem(item, key: key, manual: manual)
        }
        let menu = NSMenu(title: "RemSound")
        mark(menu.addItem(withTitle: "Show RemSound Window", action: #selector(showWindow), keyEquivalent: ""), "tray-show")
            .target = self
        mark(menu.addItem(withTitle: "Preferences…", action: #selector(showPreferences), keyEquivalent: ""), "tray-preferences")
            .target = self
        let recentItem = NSMenuItem(title: "Recent Profiles", action: nil, keyEquivalent: "")
        mark(recentItem, "tray-recent-profiles")
        recentItem.submenu = statusRecentProfilesMenu
        menu.addItem(recentItem)
        statusSummary.isEnabled = false
        menu.addItem(mark(statusSummary, "tray-status"))
        menu.addItem(.separator())
        statusStart.target = self
        statusStart.action = #selector(startSession)
        menu.addItem(mark(statusStart, "tray-start"))
        statusStop.target = self
        statusStop.action = #selector(stopSession)
        statusStop.isEnabled = false
        menu.addItem(mark(statusStop, "tray-stop"))
        menu.addItem(.separator())
        statusSend.target = self
        statusSend.action = #selector(toggleStatusSend)
        menu.addItem(mark(statusSend, "tray-send"))
        statusSystem.target = self
        statusSystem.action = #selector(toggleStatusSystem)
        menu.addItem(mark(statusSystem, "tray-system"))
        statusReceive.target = self
        statusReceive.action = #selector(toggleStatusReceive)
        menu.addItem(mark(statusReceive, "tray-receive"))
        statusMonitor.target = self
        statusMonitor.action = #selector(toggleStatusMonitor)
        menu.addItem(mark(statusMonitor, "tray-monitor"))
        statusRecord.target = self
        statusRecord.action = #selector(toggleRecording)
        statusRecord.isEnabled = false
        menu.addItem(mark(statusRecord, "tray-record"))
        menu.addItem(.separator())
        mark(menu.addItem(withTitle: "Quit RemSound", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""), "tray-quit")
            .target = NSApp
        return menu
    }
    private func saveAudioOptions() {
        AppRuntime.settings.set(send.state == .on, forKey: "sendInput")
        AppRuntime.settings.set(systemAudio.state == .on, forKey: "sendSystemAudio")
        AppRuntime.settings.set(receive.state == .on, forKey: "receiveAudio")
        AppRuntime.settings.set(monitor.state == .on, forKey: "monitorInApp")
        AppRuntime.settings.set(plugins.state == .on, forKey: "allowPlugins")
        AppRuntime.settings.set(selectedInputUIDs, forKey: "inputDeviceUIDs")
        AppRuntime.settings.set(selectedInputChannelPairs, forKey: "inputChannelPairs")
        AppRuntime.settings.set(selectedInputUIDs.first ?? "", forKey: "inputDeviceUID")
        AppRuntime.settings.set(selectedOutputUIDs, forKey: "outputDeviceUIDs")
        AppRuntime.settings.set(selectedOutputUIDs.first ?? "", forKey: "outputDeviceUID")
        AppRuntime.settings.set(selectedOutputChannelPairs, forKey: "outputChannelPairs")
        if let selectedCaptureUIDs {
            AppRuntime.settings.set(selectedCaptureUIDs, forKey: "systemCaptureDeviceUIDs")
        } else {
            AppRuntime.settings.removeObject(forKey: "systemCaptureDeviceUIDs")
        }
        AppRuntime.settings.set(selectedCaptureChannelPairs, forKey: "systemCaptureChannelPairs")
        AppRuntime.settings.set("", forKey: "systemCaptureDeviceUID")
        AppRuntime.settings.set(selectedSendCodec().rawValue, forKey: "sendCodec")
        AppRuntime.settings.set(selectedSendPacketSize().rawValue, forKey: "sendPacketSize")
        AppRuntime.settings.set(selectedReceiveJitterMs(), forKey: "receiveJitterMs")
        AppRuntime.settings.set(selectedReceiveSmoothness(), forKey: "receiveSmoothness")
        AppRuntime.settings.set(selectedReceiveArtifact().rawValue, forKey: "receiveArtifact")
        AppRuntime.settings.set(receiveAutoTune.state == .on, forKey: "receiveAutoTune")
        AppRuntime.settings.set(receiveLowestDelay.state == .on, forKey: "receiveLowestDelay")
        AppRuntime.settings.set(selectedAutoTuneInterval(), forKey: "receiveAutoTuneInterval")
        AppRuntime.settings.set(selectedRecordingSource().rawValue, forKey: "recordingSource")
        AppRuntime.settings.set(selectedRecordingFormat().rawValue, forKey: "recordingFormat")
        AppRuntime.settings.set(selectedRecordingChannels().rawValue, forKey: "recordingChannels")
        AppRuntime.settings.set(splitRecording.state == .on, forKey: "splitRecording")
        AppRuntime.settings.set(recordingBypassShaping.state == .on, forKey: "recordingBypassShaping")
        AppRuntime.settings.set(selectedFLACCompression(), forKey: "flacCompression")
        if !pushToTalkSettingsUnreadable {
            do { try PushToTalkPreferences.save(pushToTalkSettings, to: AppRuntime.settings) }
            catch { recordStartup("Push-to-talk settings persistence failed.") }
        }
    }
    private func selectedSendPacketSize() -> SendPacketSize {
        SendPacketSize(rawValue: packetSize.selectedItem?.representedObject as? String ?? "") ?? .standard
    }
    private func selectedSendCodec() -> SendCodec {
        SendCodec(rawValue: codec.selectedItem?.representedObject as? String ?? "") ?? .pcm
    }
    private func populateDeviceChoices(inputUIDs: [String],
        inputChannelPairs: [String: [Int]]? = nil, outputUIDs: [String],
        outputChannelPairs: [String: [Int]]? = nil,
        systemCaptureUIDs: [String]?, systemCapturePairs: [String: [Int]]? = nil) {
        if nativeProductFixture { return }
        selectedInputUIDs = inputUIDs
        selectedOutputUIDs = outputUIDs
        if let inputChannelPairs { selectedInputChannelPairs = inputChannelPairs }
        if let outputChannelPairs { selectedOutputChannelPairs = outputChannelPairs }
        outputChoices = AudioDeviceCatalog.choices(for: .output).map {
            (uid: $0.uid, name: $0.name)
        }
        for uid in outputUIDs where !outputChoices.contains(where: { $0.uid == uid }) {
            outputChoices.append((uid: uid, name: "Unavailable saved output, \(uid)"))
        }
        outputTable.reloadData()
        if outputTable.selectedRow < 0, outputTable.numberOfRows > 0 {
            outputTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        outputPairChoices = outputChoices.flatMap { choice -> [(uid: String, name: String, pair: Int)] in
            guard !choice.uid.isEmpty else { return [] }
            let count = AudioDeviceCatalog.outputChannelPairCount(choice.uid)
            guard count > 1 else { return [] }
            return (0..<count).map { (uid: choice.uid, name: choice.name, pair: $0) }
        }
        outputPairTable.reloadData()
        if outputPairTable.selectedRow < 0, outputPairTable.numberOfRows > 0 {
            outputPairTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        inputChoices = AudioDeviceCatalog.choices(for: .input).map {
            (uid: $0.uid, name: $0.name)
        }
        for uid in inputUIDs where !inputChoices.contains(where: { $0.uid == uid }) {
            inputChoices.append((uid: uid, name: "Unavailable saved input, \(uid)"))
        }
        inputTable.reloadData()
        if inputTable.selectedRow < 0, inputTable.numberOfRows > 0 {
            inputTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        inputPairChoices = inputChoices.flatMap { choice -> [(uid: String, name: String, pair: Int)] in
            let count = AudioDeviceCatalog.inputChannelPairCount(choice.uid)
            return (0..<count).map { (uid: choice.uid, name: choice.name, pair: $0) }
        }
        inputPairTable.reloadData()
        if inputPairTable.selectedRow < 0, inputPairTable.numberOfRows > 0 {
            inputPairTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        selectedCaptureUIDs = systemCaptureUIDs
        if let systemCapturePairs { selectedCaptureChannelPairs = systemCapturePairs }
        systemOutputs = AudioDeviceCatalog.choices(for: .output).dropFirst().map {
            (uid: $0.uid, name: $0.name)
        }
        for uid in systemCaptureUIDs ?? [] where !systemOutputs.contains(where: { $0.uid == uid }) {
            systemOutputs.append((uid: uid, name: "Unavailable saved output, \(uid)"))
        }
        systemOutputTable.reloadData()
        if systemOutputTable.selectedRow < 0, systemOutputTable.numberOfRows > 0 {
            systemOutputTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        systemOutputPairChoices = systemOutputs.flatMap { choice -> [(uid: String, name: String, pair: Int)] in
            let routes = AudioDeviceCatalog.systemCaptureRoutes(choice.uid)
            guard routes.count > 1 else { return [] }
            return routes.map { (uid: choice.uid, name: choice.name, pair: $0.pair) }
        }
        systemOutputPairTable.reloadData()
        if systemOutputPairTable.selectedRow < 0, systemOutputPairTable.numberOfRows > 0 {
            systemOutputPairTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }
    @objc private func refreshAudioDevices() {
        populateDeviceChoices(inputUIDs: selectedInputUIDs,
            outputUIDs: selectedOutputUIDs,
            systemCaptureUIDs: selectedCaptureUIDs)
        announce("Audio device choices refreshed.")
    }
    private func refreshStatusItem() {
        guard let statusItem else { return }
        if statusSend.state != send.state { statusSend.state = send.state }
        if statusSystem.state != systemAudio.state { statusSystem.state = systemAudio.state }
        if statusReceive.state != receive.state { statusReceive.state = receive.state }
        if statusMonitor.state != monitor.state { statusMonitor.state = monitor.state }
        let summary = running
            ? "RemSound, running, \(connectedPeerCount) connected peers, input sending \(send.state == .on ? "on" : "off"), system audio sending \(systemAudio.state == .on ? "on" : "off"), receiving \(receive.state == .on ? "on" : "off"), DAW plugins \(plugins.state == .on ? "on" : "off")"
            : "RemSound, stopped"
        if statusItem.button?.accessibilityLabel() != summary {
            statusItem.button?.setAccessibilityLabel(summary)
        }
        if statusItem.button?.toolTip != summary { statusItem.button?.toolTip = summary }
    }
    @objc private func toggleStatusSend() {
        send.state = send.state == .on ? .off : .on
        audioOptionsChanged()
        refreshStatusItem()
    }
    @objc private func toggleStatusSystem() {
        systemAudio.state = systemAudio.state == .on ? .off : .on
        audioOptionsChanged()
        refreshStatusItem()
    }
    @objc private func toggleStatusReceive() {
        receive.state = receive.state == .on ? .off : .on
        audioOptionsChanged()
        refreshStatusItem()
    }
    @objc private func toggleStatusMonitor() {
        monitor.state = monitor.state == .on ? .off : .on
        audioOptionsChanged()
        refreshStatusItem()
    }
    @objc private func showWindow() {
        startupHidden = false
        AppRuntime.configuration.handOverToGUI()
        refreshTypingFeedback()
        let observation = beginUIObservation(.showWindow)
        defer {
            uiObservations.handlerReturned(observation)
            uiObservations.finish(observation, outcome: window.isVisible && !NSApp.isHidden ? .effectObserved : .failed)
        }
        let wasHidden = NSApp.isHidden || !window.isVisible
        _ = NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        statusItem.isVisible = false
        if wasHidden { CueSounds.shared.play(.show) }
    }
    private func configurePreferencesWindow() {
        let preferences = KeyboardWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 710),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        preferences.title = "RemSound Preferences"
        preferences.isReleasedWhenClosed = false
        preferencesTabs.setAccessibilityLabel("Preference sections")
        preferencesTabs.setAccessibilityHelp("Use Left and Right arrows, or Command-1 for General, Command-2 for Audio cues and Command-3 for Permissions. Tab enters the selected section.")
        preferencesTabs.translatesAutoresizingMaskIntoConstraints = false
        preferences.contentView!.addSubview(preferencesTabs)
        NSLayoutConstraint.activate([
            preferencesTabs.leadingAnchor.constraint(equalTo: preferences.contentView!.leadingAnchor,
                constant: 20),
            preferencesTabs.trailingAnchor.constraint(equalTo: preferences.contentView!.trailingAnchor,
                constant: -20),
            preferencesTabs.topAnchor.constraint(equalTo: preferences.contentView!.topAnchor,
                constant: 20),
            preferencesTabs.bottomAnchor.constraint(equalTo: preferences.contentView!.bottomAnchor,
                constant: -20),
        ])
        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = "General"
        let generalContent = NSView()
        generalContent.setAccessibilityElement(true)
        generalContent.setAccessibilityRole(.group)
        generalContent.setAccessibilityLabel("General preferences controls")
        generalTab.view = generalContent
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.group)
        stack.setAccessibilityLabel("General preferences settings")
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Scrolled, as Audio I/O is: the remote volume shortcuts made General taller than the window.
        let generalScroll = NSScrollView()
        generalScroll.translatesAutoresizingMaskIntoConstraints = false
        generalScroll.hasVerticalScroller = true
        generalScroll.setAccessibilityLabel("General preferences settings")
        generalScroll.documentView = stack
        generalContent.addSubview(generalScroll)
        NSLayoutConstraint.activate([
            generalScroll.leadingAnchor.constraint(equalTo: generalContent.leadingAnchor),
            generalScroll.trailingAnchor.constraint(equalTo: generalContent.trailingAnchor),
            generalScroll.topAnchor.constraint(equalTo: generalContent.topAnchor),
            generalScroll.bottomAnchor.constraint(equalTo: generalContent.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: generalScroll.contentView.leadingAnchor, constant: 12),
            stack.widthAnchor.constraint(equalTo: generalScroll.contentView.widthAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: generalScroll.contentView.topAnchor, constant: 12),
            stack.heightAnchor.constraint(greaterThanOrEqualTo: generalScroll.contentView.heightAnchor, constant: -24),
        ])
        stack.addArrangedSubview(remember)
        stack.addArrangedSubview(reconnect)
        loginAtStartup.setAccessibilityHelp(
            "Launch RemSound at Mac login. macOS may ask you to approve it in Login Items.")
        loginAtStartup.target = self
        loginAtStartup.action = #selector(toggleLaunchAtLogin)
        stack.addArrangedSubview(loginAtStartup)
        checkUpdates.state = AppRuntime.settings.object(forKey: "checkUpdatesAutomatically") == nil
            || AppRuntime.settings.bool(forKey: "checkUpdatesAutomatically") ? .on : .off
        checkUpdates.setAccessibilityHelp("Check Andre Louis's Mac releases after RemSound opens.")
        checkUpdates.target = self
        checkUpdates.action = #selector(updatePreferencesChanged)
        stack.addArrangedSubview(checkUpdates)
        installUpdates.state = AppRuntime.settings.bool(forKey: "installUpdatesAutomatically")
            ? .on : .off
        installUpdates.setAccessibilityHelp("Download and install a newer Developer ID signed and notarized RemSound app and all three plugins without opening a browser. Save DAW projects before a host restart.")
        installUpdates.target = self
        installUpdates.action = #selector(updatePreferencesChanged)
        stack.addArrangedSubview(installUpdates)
        let frequencyLabel = NSTextField(labelWithString: "Check for updates in the background")
        frequencyLabel.identifier = NSUserInterfaceItemIdentifier("help-dialog-preferences-updatefrequency")
        updateFrequency.removeAllItems()
        updateFrequency.addItems(withTitles: UpdateCheckFrequency.allCases.map(\.title))
        let storedFrequency = (AppRuntime.settings.object(forKey: UpdateCheckFrequency.settingsKey) as? Int)
            .flatMap(UpdateCheckFrequency.init(rawValue:)) ?? .default
        updateFrequency.selectItem(at: UpdateCheckFrequency.allCases.firstIndex(of: storedFrequency) ?? 3)
        updateFrequency.setAccessibilityLabel("Check for updates in the background")
        updateFrequency.setAccessibilityHelp("Never, every hour, every 6 hours or every 24 hours, while RemSound is open. Check for updates automatically is the check when it opens.")
        updateFrequency.target = self
        updateFrequency.action = #selector(updateScheduleChanged)
        stack.addArrangedSubview(frequencyLabel)
        stack.addArrangedSubview(updateFrequency)
        updateWindowEnabled.state = AppRuntime.settings.bool(forKey: UpdateWindow.enabledKey) ? .on : .off
        updateWindowEnabled.setAccessibilityHelp("Off by default. On, an update found automatically outside these times waits until they start, so it never cuts your sound while you use the Mac. A check you ask for is never held back.")
        updateWindowEnabled.target = self
        updateWindowEnabled.action = #selector(updateScheduleChanged)
        stack.addArrangedSubview(updateWindowEnabled)
        let slots = (0..<UpdateWindow.slotsPerDay).map { UpdateWindow.format($0 * UpdateWindow.slotMinutes) }
        for (popup, key, fallback, name) in [(updateWindowStart, UpdateWindow.startKey, UpdateWindow.defaultStart, "Install automatic updates from"),
                                             (updateWindowEnd, UpdateWindow.endKey, UpdateWindow.defaultEnd, "Install automatic updates until")] {
            popup.removeAllItems()
            popup.addItems(withTitles: slots)
            let minutes = AppRuntime.settings.object(forKey: key) as? Int ?? fallback
            popup.selectItem(at: max(0, min(slots.count - 1, minutes / UpdateWindow.slotMinutes)))
            popup.setAccessibilityLabel(name)
            popup.setAccessibilityHelp("Times in fifteen-minute steps. The range may pass midnight; the same start and end mean any time.")
            popup.target = self
            popup.action = #selector(updateScheduleChanged)
        }
        let fromLabel = NSTextField(labelWithString: "From"), untilLabel = NSTextField(labelWithString: "until")
        fromLabel.identifier = NSUserInterfaceItemIdentifier("help-dialog-preferences-updatewindowstart")
        untilLabel.identifier = NSUserInterfaceItemIdentifier("help-dialog-preferences-updatewindowend")
        let windowRow = NSStackView(views: [fromLabel, updateWindowStart, untilLabel, updateWindowEnd])
        windowRow.orientation = .horizontal
        stack.addArrangedSubview(windowRow)
        showWhatsNew.state = AppRuntime.settings.object(forKey: UpdateService.whatsNewKey) as? Bool ?? true ? .on : .off
        showWhatsNew.setAccessibilityHelp("On by default. The first time RemSound opens after an update, it shows what's new in that version.")
        showWhatsNew.target = self
        showWhatsNew.action = #selector(updateScheduleChanged)
        stack.addArrangedSubview(showWhatsNew)
        refreshUpdateWindowControls()
        preferencesExtras.applyTabs = { [weak self] in self?.applyMainTabs() }
        preferencesExtras.applyRememberedPeers = { [weak self] in
            self?.connectivityPeers.showRememberedList(PreferencesExtras.flag(PreferencesExtras.showRememberedPeersKey, default: true))
        }
        preferencesExtras.profiles = { [weak self] in
            ((try? self?.profileStore.list()) ?? []).map { (id: $0.id, title: $0.title) }
        }
        preferencesExtras.clearRememberedServers = { AppRuntime.settings.removeObject(forKey: JamController.rememberedServersKey) }
        preferencesExtras.clearRememberedApplications = { [weak self] in
            self?.rememberedApplications = [:]
            self?.refreshApplicationLists()
        }
        preferencesExtras.note = { [weak self] line in self?.session.note(line) }
        preferencesExtras.writeLogs = { [weak self] in self?.session.writeLogsNow() }
        preferencesExtras.openLog = { [weak self] in
            guard let file = self?.session.currentLog.file else { return false }
            return NSWorkspace.shared.open(file)
        }
        preferencesExtras.openFolder = { [weak self] in
            guard let folder = self?.session.currentLog.folder else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
        preferencesExtras.liveLogStem = { [weak self] in self?.session.currentLog.stem }
        preferencesExtras.announce = { [weak self] text in self?.announce(text) }
        preferencesExtras.addControls(to: stack)
        stack.addArrangedSubview(acceptConnectionsLabel)
        acceptConnections.removeAllItems()
        for mode in AcceptConnections.allCases {
            acceptConnections.addItem(withTitle: mode.title)
            acceptConnections.lastItem?.representedObject = mode.rawValue
        }
        acceptConnections.selectItem(at: AcceptConnections.allCases.firstIndex(of: jam.acceptConnections) ?? 0)
        acceptConnections.setAccessibilityLabel("Accept connections from other peers")
        acceptConnections.setAccessibilityHelp(
            "What happens when somebody on your password ticks you. Ask me each time (the default) asks once with their name and address. Automatically ticks them back at once. Manual leaves it to you. On this Mac, not in the profile.")
        acceptConnections.target = self
        acceptConnections.action = #selector(acceptConnectionsChanged)
        stack.addArrangedSubview(acceptConnections)
        acceptRemoteVolume.state = AppRuntime.settings.bool(forKey: "acceptRemoteVolumeCommands") ? .on : .off
        acceptRemoteVolume.setAccessibilityHelp(
            "Off by default. When on, a ticked peer who knows the shared password can change this Mac's master volume for received audio, mute received audio, and change or mute the Mac's own output volume. Saved in the current profile.")
        acceptRemoteVolume.target = self
        acceptRemoteVolume.action = #selector(acceptRemoteVolumeChanged)
        stack.addArrangedSubview(acceptRemoteVolume)
        enableLogs.state = effectiveLoggingEnabled ? .on : .off
        enableLogs.setAccessibilityLabel(enableLogs.title)
        enableLogs.setAccessibilityHelp("Takes effect immediately for this profile and updates this computer's logging choice. Save Profile keeps it. Changes to a read-only profile remain temporary unless you explicitly save them. New Profile starts with logs off.")
        enableLogs.target = self
        enableLogs.action = #selector(profileLoggingChanged)
        stack.addArrangedSubview(enableLogs)
        let saveLabel = NSTextField(labelWithString: "Auto-save non-read-only profiles")
        saveLabel.identifier = NSUserInterfaceItemIdentifier("help-dialog-preferences-autosaveinterval")
        stack.addArrangedSubview(saveLabel)
        autoSaveInterval.setAccessibilityLabel("Auto-save non-read-only profiles")
        autoSaveInterval.setAccessibilityHelp(
            "Never, or every 2, 5, 10, 15, 20, or 30 minutes. Only changed, saved, writable profiles are saved automatically.")
        for minutes in [0, 2, 5, 10, 15, 20, 30] {
            autoSaveInterval.addItem(withTitle: minutes == 0 ? "Never" : "Every \(minutes) minutes")
            autoSaveInterval.lastItem?.representedObject = minutes
        }
        let savedInterval = AppRuntime.settings.integer(forKey: "autoSaveNonReadOnlyMinutes")
        autoSaveInterval.selectItem(at: autoSaveInterval.itemArray.firstIndex {
            ($0.representedObject as? Int) == savedInterval
        } ?? 0)
        autoSaveInterval.target = self
        autoSaveInterval.action = #selector(autoSaveIntervalChanged)
        stack.addArrangedSubview(autoSaveInterval)
        cueMute.target = self
        cueMute.action = #selector(cueMuteChanged)
        cueChoice.target = self
        cueChoice.action = #selector(cueChoiceChanged)
        cueBrowse.target = self
        cueBrowse.action = #selector(browseCue)
        cuePreview.target = self
        cuePreview.action = #selector(previewCue)
        refreshCueChoices()
        let hotkeyHeading = NSTextField(labelWithString: "Global hotkeys")
        hotkeyHeading.identifier = NSUserInterfaceItemIdentifier("help-dialog-preferences-tab-general")
        stack.addArrangedSubview(hotkeyHeading)
        let stored = AppRuntime.settings.data(forKey: "globalHotkeys")
        let decoded = (try? JSONDecoder().decode([String: HotkeyDescriptor].self,
            from: stored ?? Data())) ?? [:]
        hotkeyBindings = [:]
        for action in GlobalHotkeyAction.allCases {
            if let descriptor = decoded[action.settingKey], descriptor.isValid {
                var proposed = hotkeyBindings
                proposed[action] = descriptor
                if !AppRuntime.configuration.allowsGlobalHotkeys || hotkeys.register(proposed) { hotkeyBindings = proposed }
            }
        }
        let shortcutFields: [(GlobalHotkeyAction, String, HotkeyCaptureField, String)] = [
            (.showOrHide, "Show or hide RemSound", showHideHotkey, "dialog-preferences-showhidehotkey"),
            (.toggleSending, "Start or stop sending", sendingHotkey, "dialog-preferences-sendinghotkey"),
            (.toggleReceiving, "Start or stop receiving", receivingHotkey, "dialog-preferences-receivinghotkey"),
            (.togglePlugins, "Allow or block DAW plugins", dawHotkey, "dialog-preferences-dawhotkey"),
            (.localVolumeUp, "Volume up for received sound on this Mac", localVolumeUpHotkey, "dialog-preferences-localvolumeuphotkey"),
            (.localVolumeDown, "Volume down for received sound on this Mac", localVolumeDownHotkey, "dialog-preferences-localvolumedownhotkey"),
            (.toggleRecording, "Start or stop recording", recordingHotkey, "dialog-preferences-recordinghotkey"),
            (.remoteVolumeUp, "Send remote RemSound volume up to peers", remoteVolumeUpHotkey, "dialog-preferences-remotevolumeuphotkey"),
            (.remoteVolumeDown, "Send remote RemSound volume down to peers", remoteVolumeDownHotkey, "dialog-preferences-remotevolumedownhotkey"),
            (.remoteMuteToggle, "Send remote RemSound receive mute toggle to peers", remoteMuteHotkey, "dialog-preferences-remotemutehotkey"),
            (.remoteSystemVolumeUp, "Send system volume up to peers", remoteSystemUpHotkey, "dialog-preferences-remotesystemuphotkey"),
            (.remoteSystemVolumeDown, "Send system volume down to peers", remoteSystemDownHotkey, "dialog-preferences-remotesystemdownhotkey"),
            (.remoteSystemMuteToggle, "Send system mute toggle to peers", remoteSystemMuteHotkey, "dialog-preferences-remotesystemmutehotkey"),
            (.toggleAllPeerShaping, "Toggle volume, pan and EQ for all peers", allShapingHotkey, "dialog-preferences-allshapinghotkey"),
            (.speakStatus, "Speak the RemSound status from anywhere", speakStatusHotkey, "dialog-preferences-speakstatushotkey"),
            (.metronomeStartStop, "Start or stop the metronome (mute or unmute while following a master)", metronomeHotkey, "dialog-preferences-metronomehotkey"),
            (.metronomeTempoUp, "Metronome tempo up a beat a minute", metronomeTempoUpHotkey, "dialog-preferences-metronometempouphotkey"),
            (.metronomeTempoDown, "Metronome tempo down a beat a minute", metronomeTempoDownHotkey, "dialog-preferences-metronometempodownhotkey"),
            (.metronomeVolumeUp, "Metronome volume up", metronomeVolumeUpHotkey, "dialog-preferences-metronomevolumeuphotkey"),
            (.metronomeVolumeDown, "Metronome volume down", metronomeVolumeDownHotkey, "dialog-preferences-metronomevolumedownhotkey"),
            (.hearMyself, "Unmute or mute myself to test round trip on server", hearMyselfHotkey, "dialog-preferences-hearmyselfhotkey"),
            (.muteReceived, "Mute received audio", muteReceivedHotkey, "dialog-preferences-mutereceivedhotkey"),
            (.quickProfileSwitch, "Quick profile switch", quickProfileHotkey, "dialog-preferences-quickprofilehotkey"),
        ]
        shortcutFieldActions = shortcutFields.map { ($0.2, $0.0) }
        for (action, title, field, helpKey) in shortcutFields {
            field.descriptor = hotkeyBindings[action]
            field.placeholderString = "Unset"
            field.setAccessibilityLabel(title + " global hotkey")
            field.hotkeyDelegate = self
            field.onCaptureFocusChanged = { [weak self, weak field] focused in
                guard let self, let field else { return }
                if focused {
                    self.pushToTalkCaptureFields.insert(ObjectIdentifier(field))
                    self.refreshPushToTalkCaptureState()
                } else {
                    self.pushToTalkCaptureFields.remove(ObjectIdentifier(field))
                    // Coalesce a move between two capture fields before resuming the listener.
                    DispatchQueue.main.async { [weak self] in self?.refreshPushToTalkCaptureState() }
                }
            }
            field.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let label = NSTextField(wrappingLabelWithString: title)   // the remote volume rows are long
            label.identifier = NSUserInterfaceItemIdentifier("help-" + helpKey)
            label.widthAnchor.constraint(equalToConstant: 190).isActive = true
            let row = NSStackView(views: [label, field])
            row.orientation = .horizontal
            stack.addArrangedSubview(row)
        }
        pushToTalkHotkey.captureMode = .pushToTalk
        pushToTalkHotkey.descriptor = pushToTalkKeys.binding
        pushToTalkHotkey.placeholderString = "Unset"
        pushToTalkHotkey.setAccessibilityLabel("Push to talk machine shortcut key")
        pushToTalkHotkey.setAccessibilityHelp("Press a key, with or without modifiers, or Delete to clear. This key is saved on this Mac, independently of profiles. Configure push to talk in Audio I/O, Push to talk settings. Tab moves focus. Key input pauses while choosing any shortcut.")
        pushToTalkHotkey.hotkeyDelegate = self
        pushToTalkHotkey.onCaptureFocusChanged = { [weak self, weak field = pushToTalkHotkey] focused in
            guard let self, let field else { return }
            if focused {
                self.pushToTalkCaptureFields.insert(ObjectIdentifier(field))
                self.refreshPushToTalkCaptureState()
            } else {
                self.pushToTalkCaptureFields.remove(ObjectIdentifier(field))
                DispatchQueue.main.async { [weak self] in self?.refreshPushToTalkCaptureState() }
            }
        }
        pushToTalkHotkey.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let pushToTalkLabel = NSTextField(wrappingLabelWithString: "Push to talk shortcut key")
        pushToTalkLabel.identifier = NSUserInterfaceItemIdentifier("help-dialog-preferences-pushtotalkhotkey")
        pushToTalkLabel.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let pushToTalkRow = NSStackView(views: [pushToTalkLabel, pushToTalkHotkey])
        pushToTalkRow.orientation = .horizontal
        stack.addArrangedSubview(pushToTalkRow)
        pushToTalkKeyStatus.setAccessibilityLabel("Push to talk key result")
        pushToTalkKeyStatus.lineBreakMode = .byWordWrapping
        pushToTalkKeyStatus.maximumNumberOfLines = 0
        stack.addArrangedSubview(pushToTalkKeyStatus)
        dawHotkey.setAccessibilityHelp("Press a valid global shortcut, or Delete to clear it. This shortcut allows or blocks DAW plugin sending and receiving without changing Mac input or system-audio sending.")
        for field in [remoteVolumeUpHotkey, remoteVolumeDownHotkey, remoteMuteHotkey, remoteSystemUpHotkey,
            remoteSystemDownHotkey, remoteSystemMuteHotkey] {
            field.setAccessibilityHelp("Press a valid global shortcut, or Delete to clear it. It sends the command to every peer you send to; it changes nothing on this Mac, and only a peer with Accept remote volume commands from peers on acts on it. Volume shortcuts repeat while held.")
        }
        generalPreferencesOrder = [remember, reconnect, loginAtStartup,
            checkUpdates, installUpdates, updateFrequency, updateWindowEnabled, updateWindowStart, updateWindowEnd, showWhatsNew]
            + preferencesExtras.controlOrder + [
            acceptConnections, acceptRemoteVolume, enableLogs, autoSaveInterval,
            showHideHotkey, sendingHotkey, receivingHotkey, dawHotkey,
            localVolumeUpHotkey, localVolumeDownHotkey, recordingHotkey,
            remoteVolumeUpHotkey, remoteVolumeDownHotkey, remoteMuteHotkey, remoteSystemUpHotkey,
            remoteSystemDownHotkey, remoteSystemMuteHotkey, allShapingHotkey, speakStatusHotkey,
            metronomeHotkey, metronomeTempoUpHotkey, metronomeTempoDownHotkey, metronomeVolumeUpHotkey,
            metronomeVolumeDownHotkey, hearMyselfHotkey, muteReceivedHotkey, quickProfileHotkey, pushToTalkHotkey]
        for field in [localVolumeUpHotkey, localVolumeDownHotkey] {
            field.setAccessibilityHelp("Press a valid global shortcut, or Delete to clear it. It moves the received-sound volume on this Mac five percent. It repeats while held.")
        }
        recordingHotkey.setAccessibilityHelp("Press a valid global shortcut, or Delete to clear it. It starts or stops recording, as the Record button does.")
        speakStatusHotkey.setAccessibilityHelp("Press a valid global shortcut, or Delete to clear it. It speaks RemSound's status from anywhere. Press it twice quickly to copy the status to the clipboard.")
        for field in [metronomeHotkey, metronomeTempoUpHotkey, metronomeTempoDownHotkey, metronomeVolumeUpHotkey, metronomeVolumeDownHotkey] {
            field.setAccessibilityHelp("Press a valid global shortcut, or Delete to clear it. The same key is listed in Metronome settings. Tempo and volume keys repeat while held.")
        }
        hearMyselfHotkey.setAccessibilityHelp("Press a valid global shortcut, or Delete to clear it. It unmutes or mutes your own sound coming back from the server.")
        muteReceivedHotkey.setAccessibilityHelp("Press a valid global shortcut, or Delete to clear it. It mutes or unmutes received audio on this Mac.")
        allShapingHotkey.setAccessibilityHelp("Press a valid global shortcut, or Delete to clear it. It switches Enable volume, pan and EQ for all peers on or off.")
        quickProfileHotkey.setAccessibilityHelp("Press a valid global shortcut, or Delete to clear it. It opens every saved profile, marking the current one. Use arrows and Return to switch, or Escape to cancel. Close other RemSound dialogs first.")
        let permissionsTab = NSTabViewItem(identifier: "permissions")
        permissionsTab.label = "Permissions"
        let permissionsContent = NSView()
        permissionsContent.setAccessibilityElement(true)
        permissionsContent.setAccessibilityRole(.group)
        permissionsContent.setAccessibilityLabel("Permissions preferences controls")
        permissionsTab.view = permissionsContent
        let permissionStack = NSStackView()
        permissionStack.orientation = .vertical
        permissionStack.alignment = .leading
        permissionStack.spacing = 14
        permissionStack.setAccessibilityElement(true)
        permissionStack.setAccessibilityRole(.group)
        permissionStack.setAccessibilityLabel("Permissions preferences settings")
        permissionStack.translatesAutoresizingMaskIntoConstraints = false
        permissionsContent.addSubview(permissionStack)
        NSLayoutConstraint.activate([
            permissionStack.leadingAnchor.constraint(equalTo: permissionsContent.leadingAnchor,
                constant: 12),
            permissionStack.trailingAnchor.constraint(equalTo: permissionsContent.trailingAnchor,
                constant: -12),
            permissionStack.topAnchor.constraint(equalTo: permissionsContent.topAnchor,
                constant: 12),
            permissionStack.bottomAnchor.constraint(lessThanOrEqualTo: permissionsContent.bottomAnchor,
                constant: -12),
        ])
        let explanation = NSTextField(wrappingLabelWithString:
            "macOS asks for each recording permission once. Refresh checks its current state; it does not erase your choice. If access was denied, use System Settings.")
        explanation.identifier = NSUserInterfaceItemIdentifier("help-dialog-preferences-tab-permissions")
        explanation.isSelectable = true
        permissionStack.addArrangedSubview(explanation)
        explanation.widthAnchor.constraint(equalTo: permissionStack.widthAnchor).isActive = true
        for label in [microphonePermissionStatus, systemAudioPermissionStatus,
            inputSendingStatus] {
            label.isSelectable = true
            label.setAccessibilityElement(true)
        }
        microphonePermissionButton.target = self
        microphonePermissionButton.action = #selector(requestMicrophonePermission)
        microphonePermissionButton.setAccessibilityHelp("Ask macOS for microphone access if it has not decided yet. If already allowed or denied, its existing decision is shown.")
        microphoneSettingsButton.target = self
        microphoneSettingsButton.action = #selector(openMicrophoneSettings)
        microphoneSettingsButton.setAccessibilityHelp("Open the macOS Microphone privacy setting to change a previous decision.")
        systemAudioPermissionButton.target = self
        systemAudioPermissionButton.action = #selector(checkSystemAudioPermission)
        systemAudioPermissionButton.setAccessibilityHelp("Try system audio access again. macOS may prompt only if it has not decided yet.")
        systemAudioSettingsButton.target = self
        systemAudioSettingsButton.action = #selector(openSystemAudioSettings)
        systemAudioSettingsButton.setAccessibilityHelp("Open the macOS Screen and System Audio Recording privacy setting.")
        enableInputSendingButton.target = self
        enableInputSendingButton.action = #selector(enableSelectedInputSending)
        enableInputSendingButton.setAccessibilityHelp("Send the inputs selected in Audio I/O to your connected peers. Microphone access alone does not turn on sending.")
        refreshPermissionsButton.target = self
        refreshPermissionsButton.action = #selector(refreshPermissionsPressed)
        refreshPermissionsButton.setAccessibilityHelp("Read current microphone permission and input sending state without changing macOS consent.")
        permissionsControlOrder = [microphonePermissionStatus,
            microphonePermissionButton, microphoneSettingsButton,
            systemAudioPermissionStatus, systemAudioPermissionButton,
            systemAudioSettingsButton, inputSendingStatus,
            enableInputSendingButton, refreshPermissionsButton]
        for control in permissionsControlOrder { permissionStack.addArrangedSubview(control) }
        for label in [microphonePermissionStatus, systemAudioPermissionStatus,
            inputSendingStatus] {
            label.widthAnchor.constraint(equalTo: permissionStack.widthAnchor).isActive = true
        }
        let cuesTab = NSTabViewItem(identifier: "audio-cues")
        cuesTab.label = "Audio cues"
        let cuesContent = NSView()
        cuesTab.view = cuesContent
        cuePane.view.translatesAutoresizingMaskIntoConstraints = false
        cuesContent.addSubview(cuePane.view)
        NSLayoutConstraint.activate([
            cuePane.view.leadingAnchor.constraint(equalTo: cuesContent.leadingAnchor, constant: 12),
            cuePane.view.trailingAnchor.constraint(equalTo: cuesContent.trailingAnchor, constant: -12),
            cuePane.view.topAnchor.constraint(equalTo: cuesContent.topAnchor, constant: 12),
            cuePane.view.bottomAnchor.constraint(lessThanOrEqualTo: cuesContent.bottomAnchor, constant: -12),
        ])
        preferencesTabs.addTabViewItem(generalTab)
        preferencesTabs.addTabViewItem(cuesTab)
        preferencesTabs.addTabViewItem(permissionsTab)
        preferencesTabs.delegate = self
        preferencesTabs.selectTabViewItem(generalTab)
        tabView(preferencesTabs, didSelect: generalTab)
        let helpBindings: [(NSView, String)] = [
            (microphonePermissionStatus, "dialog-preferences-microphonepermissionstatus"),
            (systemAudioPermissionStatus, "dialog-preferences-systemaudiopermissionstatus"),
            (inputSendingStatus, "dialog-preferences-inputsendingstatus"),
            (microphonePermissionButton, "dialog-preferences-microphonepermissionbutton"),
            (microphoneSettingsButton, "dialog-preferences-microphonesettingsbutton"),
            (systemAudioPermissionButton, "dialog-preferences-systemaudiopermissionbutton"),
            (systemAudioSettingsButton, "dialog-preferences-systemaudiosettingsbutton"),
            (enableInputSendingButton, "dialog-preferences-enableinputsendingbutton"),
            (refreshPermissionsButton, "dialog-preferences-refreshpermissionsbutton"),
            (showHideHotkey, "dialog-preferences-showhidehotkey"),
            (sendingHotkey, "dialog-preferences-sendinghotkey"),
            (receivingHotkey, "dialog-preferences-receivinghotkey"),
            (dawHotkey, "dialog-preferences-dawhotkey"),
            (remoteVolumeUpHotkey, "dialog-preferences-remotevolumeuphotkey"),
            (remoteVolumeDownHotkey, "dialog-preferences-remotevolumedownhotkey"),
            (remoteMuteHotkey, "dialog-preferences-remotemutehotkey"),
            (remoteSystemUpHotkey, "dialog-preferences-remotesystemuphotkey"),
            (remoteSystemDownHotkey, "dialog-preferences-remotesystemdownhotkey"),
            (remoteSystemMuteHotkey, "dialog-preferences-remotesystemmutehotkey"),
            (allShapingHotkey, "dialog-preferences-allshapinghotkey"),
            (quickProfileHotkey, "dialog-preferences-quickprofilehotkey"),
            (localVolumeUpHotkey, "dialog-preferences-localvolumeuphotkey"),
            (localVolumeDownHotkey, "dialog-preferences-localvolumedownhotkey"),
            (recordingHotkey, "dialog-preferences-recordinghotkey"),
            (speakStatusHotkey, "dialog-preferences-speakstatushotkey"),
            (metronomeHotkey, "dialog-preferences-metronomehotkey"),
            (metronomeTempoUpHotkey, "dialog-preferences-metronometempouphotkey"),
            (metronomeTempoDownHotkey, "dialog-preferences-metronometempodownhotkey"),
            (metronomeVolumeUpHotkey, "dialog-preferences-metronomevolumeuphotkey"),
            (metronomeVolumeDownHotkey, "dialog-preferences-metronomevolumedownhotkey"),
            (hearMyselfHotkey, "dialog-preferences-hearmyselfhotkey"),
            (muteReceivedHotkey, "dialog-preferences-mutereceivedhotkey"),
            (pushToTalkHotkey, "dialog-preferences-pushtotalkhotkey"),
            (pushToTalkKeyStatus, "dialog-preferences-pushtotalkkeystatus"),
            (enableLogs, "dialog-preferences-enablelogs"),
            (loginAtStartup, "dialog-preferences-loginatstartup"),
            (checkUpdates, "dialog-preferences-checkupdates"),
            (installUpdates, "dialog-preferences-installupdates"),
            (updateFrequency, "dialog-preferences-updatefrequency"),
            (updateWindowEnabled, "dialog-preferences-updatewindow"),
            (updateWindowStart, "dialog-preferences-updatewindowstart"),
            (updateWindowEnd, "dialog-preferences-updatewindowend"),
            (showWhatsNew, "dialog-preferences-showwhatsnew"),
            (acceptConnections, "dialog-preferences-acceptconnections"),
            (acceptConnectionsLabel, "dialog-preferences-acceptconnections"),
            (acceptRemoteVolume, "dialog-preferences-acceptremotevolume"),
            (remember, "dialog-preferences-remember"),
            (reconnect, "dialog-preferences-reconnect"),
            (autoSaveInterval, "dialog-preferences-autosaveinterval"),
        ]
        for (view, key) in helpBindings { view.identifier = NSUserInterfaceItemIdentifier("help-" + key) }
        for (item, key) in zip(preferencesTabs.tabViewItems, ["general", "cues", "permissions"]) {
            item.view?.identifier = NSUserInterfaceItemIdentifier("help-dialog-preferences-tab-" + key)
        }
        preferences.contextHelp = { [weak self, weak preferences] manual in
            guard let preferences else { return }
            self?.contextHelpAction(manual, preferences)
        }
        preferences.moveTabFocus = { [weak self, weak preferences] backwards in
            guard let self, let preferences else { return false }
            let order = self.preferencesControlOrder.filter {
                ($0 as? NSControl)?.isEnabled != false
            }
            guard !order.isEmpty else { return false }
            let current = order.firstIndex { hasKeyboardFocus($0, in: preferences) }
            let index = current.map {
                backwards ? ($0 + order.count - 1) % order.count : ($0 + 1) % order.count
            } ?? (backwards ? order.count - 1 : 0)
            return preferences.makeFirstResponder(order[index])
        }
        hotkeys.handler = { [weak self] action in self?.performGlobalHotkey(action) }
        preferences.initialFirstResponder = preferencesTabs
        preferencesWindow = preferences
        refreshLoginItem()
        refreshCueChoices()
    }
    @objc private func showPreferences() {
        AppRuntime.configuration.handOverToGUI()
        refreshTypingFeedback()
        guard let preferencesWindow else { return }
        refreshLoginItem()
        refreshPermissionStatus()
        _ = NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        preferencesWindow.center()
        preferencesWindow.makeKeyAndOrderFront(nil)
        preferencesWindow.makeFirstResponder(preferencesTabs)
        NSApp.activate(ignoringOtherApps: true)
        statusItem.isVisible = false
    }
    private func refreshPermissionStatus() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphonePermissionStatus.stringValue = "Microphone: allowed by macOS."
        case .notDetermined:
            microphonePermissionStatus.stringValue = "Microphone: not requested yet."
        case .denied:
            microphonePermissionStatus.stringValue = "Microphone: denied. Change this in System Settings."
        case .restricted:
            microphonePermissionStatus.stringValue = "Microphone: restricted by macOS."
        @unknown default:
            microphonePermissionStatus.stringValue = "Microphone: status unavailable."
        }
        if !systemAudioAccessChecked {
            systemAudioPermissionStatus.stringValue = "System audio: access check pending."
        } else {
            systemAudioPermissionStatus.stringValue = systemAudioAccessAvailable
                ? "System audio: access check succeeded."
                : "System audio: access check failed. Check System Settings."
        }
        let inputNames = selectedInputUIDs.map { uid in
            inputChoices.first(where: { $0.uid == uid })?.name
                ?? (uid.isEmpty ? "default input" : uid)
        }
        let selection = inputNames.isEmpty ? "No input selected" : inputNames.joined(separator: ", ")
        inputSendingStatus.stringValue = "Selected inputs: \(selection). Input sending: \(send.state == .on ? "on" : "off")."
        for field in [microphonePermissionStatus, systemAudioPermissionStatus,
            inputSendingStatus] {
            field.setAccessibilityLabel(field.stringValue)
        }
    }
    @objc private func requestMicrophonePermission() {
        let browserTicket = browserListener.suspendForPermission()
        ensureMicrophoneAccess { [weak self] allowed in
            guard let self else { return }
            self.browserListener.completePermission(browserTicket, allowed: allowed && self.browserSourcePermitted)
            self.announce(allowed
                ? "Microphone access is allowed. \(self.send.state == .on ? "Input sending is on." : "Input sending is off; use Turn on selected input sending.")"
                : "Microphone access is not allowed. Open Microphone settings to change this.")
        }
    }
    @objc private func checkSystemAudioPermission() {
        let browserTicket = browserListener.suspendForPermission()
        systemAudioPermissionStatus.stringValue = "System audio: checking access."
        ensureSystemAudioAccess(force: true) { [weak self] available in
            guard let self else { return }
            self.browserListener.completePermission(browserTicket, allowed: available && self.browserSourcePermitted)
            self.announce(available ? "System audio access check succeeded."
                : "System audio access check failed. Open Screen and System Audio Recording settings.")
        }
    }
    private func openPrivacySetting(_ section: String) {
        _ = browserListener.suspendForPermission()
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(section)"),
            NSWorkspace.shared.open(url) else {
            NSWorkspace.shared.open(URL(fileURLWithPath:
                "/System/Applications/System Settings.app"))
            announce("System Settings opened. Go to Privacy and Security to change recording access.")
            return
        }
    }
    @objc private func openMicrophoneSettings() {
        openPrivacySetting("Privacy_Microphone")
    }
    @objc private func openSystemAudioSettings() {
        openPrivacySetting("Privacy_ScreenCapture")
    }
    @objc private func enableSelectedInputSending() {
        let browserTicket = browserListener.suspendForPermission()
        recordStartup("Permissions button requested input sending with \(selectedInputUIDs.count) selected inputs; authorization \(AVCaptureDevice.authorizationStatus(for: .audio)).")
        guard !selectedInputUIDs.isEmpty else {
            announce("Choose an input in Audio I/O first.")
            return
        }
        let browserScope = browserListener.sourceScope
        ensureMicrophoneAccess { [weak self] allowed in
            guard let self, self.browserListener.isCurrentSourceScope(browserScope) else { return }
            self.browserListener.completePermission(browserTicket, allowed: allowed && self.browserSourcePermitted)
            guard allowed else {
                self.announce("Microphone access is not allowed. Open Microphone settings to change this.")
                return
            }
            if self.send.state != .on {
                self.send.state = .on
                CueSounds.shared.play(.checkboxOn)
                self.audioOptionsChanged()
            }
            self.announce("Selected input sending requested. Check Audio I/O for the current state.")
        }
    }
    @objc private func refreshPermissionsPressed() {
        let browserTicket = browserListener.suspendForPermission()
        refreshPermissionStatus()
        browserListener.completePermission(browserTicket, allowed: browserSourcePermitted)
        let keyAllowed = AppRuntime.configuration.allowsGlobalHotkeys && !AppRuntime.configuration.silent && AXIsProcessTrusted()
        pushToTalkInput?.setPermitted(keyAllowed)
        pushToTalkInput?.retry()
        announce("Permission status refreshed. \(microphonePermissionStatus.stringValue) \(inputSendingStatus.stringValue)")
    }
    private func commitPushToTalkMachineKey(_ binding: HotkeyDescriptor?) -> String? {
        guard !pushToTalkClosing, let input = pushToTalkInput else { return "RemSound is closing." }
        guard binding?.isValidForPushToTalk != false,
              !PushToTalkKeyRegistration.conflicts(binding, with: Array(hotkeyBindings.values)) else {
            return "That push-to-talk key is invalid or conflicts with another RemSound shortcut. Choose another."
        }
        do { try PushToTalkKeyPreferences.save(binding, to: AppRuntime.settings) }
        catch { return "Push-to-talk key could not be saved. Previous key is unchanged." }
        // Commit storage before retiring a working key. Disarm before replacement so a later
        // registration failure retains the saved choice and reports inactive input consistently.
        input.invalidate()
        _ = input.replaceBinding(binding)
        audioOptionsChanged()
        return nil
    }
    private func reportPushToTalkKeyRow(_ message: String) {
        pushToTalkKeyStatus.stringValue = message
        guard !AppRuntime.configuration.silent, preferencesWindow?.firstResponder === pushToTalkHotkey else { return }
        NSAccessibility.post(element: pushToTalkHotkey, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    func hotkeyCaptureFieldDidChange(_ field: HotkeyCaptureField) {
        if field === pushToTalkHotkey {
            let error = commitPushToTalkMachineKey(field.descriptor)
            field.descriptor = pushToTalkKeys.binding
            reportPushToTalkKeyRow(error ?? (field.descriptor == nil
                ? "Push-to-talk key cleared."
                : "Push-to-talk key saved. Key input requires enabled key mode and an active connection."))
            return
        }
        guard let action = shortcutFieldActions.first(where: { $0.0 === field })?.1 else { return }
        guard commitGlobalHotkey(action, field.descriptor) else {
            field.descriptor = hotkeyBindings[action]
            let message = "That shortcut is already in use or cannot be registered. Choose another."
            NSAccessibility.post(element: field, notification: .announcementRequested,
                userInfo: [.announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue])
            CueSounds.shared.beep()
            return
        }
    }
    /// One global shortcut set or cleared, from its Preferences row or the Metronome settings window: registered, kept on
    /// this Mac, and shown in its row. False when it is taken or cannot be registered; nothing changes then.
    @discardableResult
    private func commitGlobalHotkey(_ action: GlobalHotkeyAction, _ descriptor: HotkeyDescriptor?) -> Bool {
        var proposed = hotkeyBindings
        proposed[action] = descriptor
        guard !PushToTalkKeyRegistration.conflicts(pushToTalkKeys.binding, with: Array(proposed.values)),
            !AppRuntime.configuration.allowsGlobalHotkeys || hotkeys.register(proposed) else { return false }
        hotkeyBindings = proposed
        if let field = shortcutFieldActions.first(where: { $0.1 == action })?.0, field.descriptor != descriptor {
            field.descriptor = descriptor
        }
        pushToTalkInput?.setReservedBindings(Array(proposed.values))
        let stored = Dictionary(uniqueKeysWithValues: proposed.map {
            ($0.key.settingKey, $0.value)
        })
        if let data = try? JSONEncoder().encode(stored) {
            AppRuntime.settings.set(data, forKey: "globalHotkeys")
        }
        return true
    }
    private func performGlobalHotkey(_ action: GlobalHotkeyAction) {
        switch action {
        case .showOrHide:
            if NSApp.isHidden || !window.isVisible { showWindow() }
            else { NSApp.hide(nil) }
        case .toggleSending:
            if send.state == .on || systemAudio.state == .on {
                hotkeyResumeInput = send.state == .on
                hotkeyResumeSystem = systemAudio.state == .on
                send.state = .off
                systemAudio.state = .off
            } else {
                let canSendInput = !selectedInputUIDs.isEmpty
                let canSendSystem = selectedCaptureUIDs?.isEmpty != true
                guard canSendInput || canSendSystem else {
                    CueSounds.shared.beep()
                    announce("Select an audio input or system capture output before starting Mac audio sending.")
                    return
                }
                send.state = canSendInput &&
                    (hotkeyResumeInput || (!hotkeyResumeInput && !hotkeyResumeSystem))
                    ? .on : .off
                systemAudio.state = canSendSystem &&
                    (hotkeyResumeSystem || (!hotkeyResumeInput && !hotkeyResumeSystem))
                    ? .on : .off
            }
            audioOptionsChanged()
        case .toggleReceiving:
            receive.state = receive.state == .on ? .off : .on
            audioOptionsChanged()
        case .togglePlugins:
            plugins.state = plugins.state == .on ? .off : .on
            audioOptionsChanged()
            refreshStatusItem()
            announce(plugins.state == .on ? "DAW plugins allowed." : "DAW plugins blocked.")
        case .quickProfileSwitch: showQuickProfileSwitch()
        case .remoteVolumeUp: session.sendRemoteControl(.volumeUp)
        case .remoteVolumeDown: session.sendRemoteControl(.volumeDown)
        case .remoteMuteToggle: session.sendRemoteControl(.muteToggle)
        case .remoteSystemVolumeUp: session.sendRemoteControl(.systemVolumeUp)
        case .remoteSystemVolumeDown: session.sendRemoteControl(.systemVolumeDown)
        case .remoteSystemMuteToggle: session.sendRemoteControl(.systemMuteToggle)
        case .toggleAllPeerShaping:
            allPeerShaping.state = allPeerShaping.state == .on ? .off : .on
            allPeerShapingChanged()
            announce(allPeerShaping.state == .on ? "Volume, pan and EQ on for all peers." : "Volume, pan and EQ off for all peers.")
        // Windows' NudgeVolume: five points a press, through the slider's own action so it is kept and applied as usual.
        case .localVolumeUp, .localVolumeDown:
            let step = action == .localVolumeUp ? 5 : -5
            let value = min(100, max(0, listeningVolume.integerValue + step))
            guard value != listeningVolume.integerValue else { return }
            listeningVolume.integerValue = value
            listeningChanged()
        case .toggleRecording: toggleRecording()
        case .speakStatus: speakStatus()
        case .metronomeStartStop: jam.startStop()
        case .metronomeTempoUp, .metronomeTempoDown:
            // While following, the tempo is the master's (Windows StepMetronomeTempo): not taken, only logged.
            guard jam.view.metronomeRole != .follower else {
                session.note("metronome: tempo \(action == .metronomeTempoUp ? "up" : "down") from the hotkey not taken - the tempo is the master's while you follow")
                return
            }
            jam.tempo(action == .metronomeTempoUp ? 1 : -1)
        case .metronomeVolumeUp, .metronomeVolumeDown:
            let value = min(100, max(0, jam.volume + (action == .metronomeVolumeUp ? 5 : -5)))
            if value != jam.volume { _ = jam.setVolume(value) }
        case .hearMyself: jam.toggleSelfMonitoring()
        case .muteReceived:
            receiveMute.state = receiveMute.state == .on ? .off : .on
            listeningChanged()
        }
    }
    /// Speak the status from anywhere (Windows SpeakStatusLine, issue 13); a quick second press copies it to the clipboard
    /// instead, so it can be shared (Andre's suggestion, 2026-06-24).
    private func speakStatus() {
        let now = Date()
        let doublePress = now.timeIntervalSince(lastSpeakStatusPress) <= 0.6
        lastSpeakStatusPress = now
        // Windows reads its status box; the line under it says what RemSound last did.
        var text = [connectionStatus.stringValue, status.stringValue]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
        if text.isEmpty { text = "No status information available." }
        if doublePress {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            announce("RemSound status copied to the clipboard.")
        } else {
            announce(text)
        }
    }
    /// The metronome's five keys for its settings window, and keeping the ones it changed (Windows KeepMetronomeKeys).
    private func metronomeKeyBindings() -> [HotkeyDescriptor?] { GlobalHotkeyAction.metronomeKeys.map { hotkeyBindings[$0] } }
    private func keepMetronomeKeys(_ keys: [HotkeyDescriptor?]) -> String? {
        var refused: [String] = []
        for (action, key) in zip(GlobalHotkeyAction.metronomeKeys, keys) where hotkeyBindings[action] != key {
            if !commitGlobalHotkey(action, key) { refused.append(key?.description ?? "") }
        }
        return refused.isEmpty ? nil : "These shortcuts are already in use or cannot be registered, so they were not kept: \(refused.joined(separator: ", "))."
    }
    @objc private func systemAudioModeChanged() {
        AppRuntime.settings.set(sendingApplications, forKey: "systemAudioFromApplications")
        showSystemAudioMode()
        applyBrowserSafeApplications(sendingApplications ? chosenApplications : nil)
        session.note("ui: system audio send mode → \(sendingApplications ? "applications" : "whole outputs")")
    }
    /// The outputs' lists, or the applications', as the mode says; the applications' kept up to date while shown.
    private func showSystemAudioMode() {
        let applications = sendingApplications
        for view in outputCaptureViews where view.isHidden != applications { view.isHidden = applications }
        for view in applicationCaptureViews where view.isHidden == applications { view.isHidden = !applications }
        applicationListTimer?.invalidate()
        applicationListTimer = nil
        guard applications else { return }
        refreshApplicationLists()
        applicationListTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshApplicationLists() }
        }
    }
    private var rememberedApplications: [String: String] {
        get { AppRuntime.settings.dictionary(forKey: "rememberedApplications") as? [String: String] ?? [:] }
        set { AppRuntime.settings.set(newValue, forKey: "rememberedApplications") }
    }
    private func refreshApplicationLists() {
        let running = NSWorkspace.shared.runningApplications
        var names = rememberedApplications
        for app in running {
            if let id = app.bundleIdentifier, let name = app.localizedName { names[id] = name }
        }
        let lists = AppAudio.lists(processes: AudioProcesses.snapshot().map(\.bundleID),
            apps: Set(running.compactMap(\.bundleIdentifier)), names: names, chosen: chosenApplications,
            remembered: Array(rememberedApplications.keys))
        if lists.active != activeApps {
            activeApps = lists.active
            activeAppsTable.reloadData()
        }
        if lists.remembered != rememberedApps {
            rememberedApps = lists.remembered
            rememberedAppsTable.reloadData()
        }
    }
    private func toggleApplication(_ row: Int, remembered: Bool) {
        let list = remembered ? rememberedApps : activeApps
        guard list.indices.contains(row) else { return }
        let app = list[row]
        chosenApplications = AppAudio.toggled(app.bundleID, in: chosenApplications)
        let chosen = chosenApplications.contains(app.bundleID)
        if chosen { rememberedApplications[app.bundleID] = app.name }
        AppRuntime.settings.set(chosenApplications, forKey: "systemAudioApplications")
        if sendingApplications { applyBrowserSafeApplications(chosenApplications) }
        session.note("ui: send application '\(app.bundleID)' \(chosen ? "ticked" : "unticked") (\(chosenApplications.count) chosen)")
        announceCheckState(chosen, in: remembered ? rememberedAppsTable : activeAppsTable)
        refreshApplicationLists()
    }
    private func forgetApplication(_ row: Int) {
        guard rememberedApps.indices.contains(row) else { return }
        let app = rememberedApps[row]
        rememberedApplications.removeValue(forKey: app.bundleID)
        session.note("ui: remembered application '\(app.bundleID)' deleted from the remembered list")
        announce("\(app.name) forgotten.")
        refreshApplicationLists()
    }
    @objc private func metronomeVolumeChanged() {
        applyingMetronomeVolumeAction = true
        defer { applyingMetronomeVolumeAction = false }
        guard jam.setVolume(metronomeVolume.integerValue, announceFailure: false) else {
            refreshMetronomeVolume()
            announce("The metronome volume could not be saved. Its previous value is retained.")
            return
        }
    }
    private func refreshMetronomeVolume() {
        let label = "Metronome volume: \(jam.volume) percent"
        if metronomeVolume.integerValue != jam.volume { metronomeVolume.integerValue = jam.volume }
        guard metronomeVolume.accessibilityLabel() != label else { return }
        metronomeVolume.setAccessibilityLabel(label)
        // Native adjustment and ResettableSlider already notify their own completed action.
        if !applyingMetronomeVolumeAction, window.firstResponder === metronomeVolume, !AppRuntime.configuration.silent {
            NSAccessibility.post(element: metronomeVolume.cell as Any? ?? metronomeVolume, notification: .valueChanged)
        }
    }
    @objc private func listeningChanged() {
        session.setListening(volume: listeningVolume.integerValue, muted: receiveMute.state == .on)
        AppRuntime.settings.set(listeningVolume.integerValue, forKey: "listeningVolume")
        AppRuntime.settings.set(receiveMute.state == .on, forKey: "receiveMuted")
    }
    /// A peer moved the volume or switched the mute: the controls follow, and are saved with the profile next time (as on
    /// Windows, this alone does not count as a change to save).
    private func listeningChangedByPeer(volume: Int, muted: Bool) {
        listeningVolume.integerValue = volume
        receiveMute.state = muted ? .on : .off
        AppRuntime.settings.set(volume, forKey: "listeningVolume")
        AppRuntime.settings.set(muted, forKey: "receiveMuted")
    }
    private func bindMainContextHelp() {
        let bindings: [(NSView, String)] = [
            (name, "main-name"),
            (peer, "main-peer"),
            (password, "main-password"),
            (start, "main-start"),
            (stop, "main-stop"),
            (table, "main-table"),
            (toggle, "main-toggle"),
            (browserListenerButton, "main-browserlistenerbutton"),
            (codec, "main-codec"),
            (packetSize, "main-packetsize"),
            (send, "main-send"),
            (systemAudio, "main-systemaudio"),
            (receive, "main-receive"),
            (monitor, "main-monitor"),
            (plugins, "main-plugins"),
            (systemAudioMode, "main-systemaudiomode"),
            (inputTable, "main-inputtable"),
            (inputPairTable, "main-inputpairtable"),
            (outputTable, "main-outputtable"),
            (outputPairTable, "main-outputpairtable"),
            (systemOutputTable, "main-systemoutputtable"),
            (systemOutputPairTable, "main-systemoutputpairtable"),
            (activeAppsTable, "main-activeappstable"),
            (rememberedAppsTable, "main-rememberedappstable"),
            (receiveJitter, "main-receivejitter"),
            (receiveSmoothness, "main-receivesmoothness"),
            (receiveArtifact, "main-receiveartifact"),
            (receiveAutoTune, "main-receiveautotune"),
            (receiveAutoTuneInterval, "main-receiveautotuneinterval"),
            (receiveLowestDelay, "main-receivelowestdelay"),
            (receiveLatencyStatus, "main-receivelatencystatus"),
            (selfMonitoringButton, "main-selfmonitoringbutton"),
            (selfMonitoringStatus, "main-selfmonitoringstatus"),
            (listeningVolume, "main-listeningvolume"),
            (receiveMute, "main-receivemute"),
            (refreshDevices, "main-refreshdevices"),
            (peerDetails, "main-peerdetails"),
            (connectionStatus, "main-connectionstatus"),
            (uncheckAllDevices, "main-uncheckalldevices"),
            (pushToTalkButton, "main-pushtotalkbutton"),
            (metronomeVolume, "main-metronomevolume"),
            (recordingSource, "main-recordingsource"),
            (recordingFormat, "main-recordingformat"),
            (flacCompression, "main-flaccompression"),
            (recordingChannels, "main-recordingchannels"),
            (splitRecording, "main-splitrecording"),
            (recordingBypassShaping, "main-recordingbypassshaping"),
            (recordingButton, "main-recordingbutton"),
            (recordingsFolderButton, "main-recordingsfolderbutton"),
            (openProfileButton, "main-openprofilebutton"),
            (saveProfileButton, "main-saveprofilebutton"),
            (saveAsProfileButton, "main-saveasprofilebutton"),
            (profileNotice, "main-profilenotice"),
            (intro, "main-intro"),
            (profileIntro, "main-profileintro"),
            (allPeerShaping, "main-allpeershaping"),
            (mixPeer, "main-mixpeer"),
            (peerMixEnabled, "main-peermixenabled"),
            (peerVolume, "main-peervolume"),
            (peerPan, "main-peerpan"),
            (eqMode, "main-eqmode"),
            (addBandButton, "main-addbandbutton"),
            (bandList, "main-bandlist"),
            (deleteBandButton, "main-deletebandbutton"),
            (resetPeerEq, "main-resetpeereq"),
            (status, "main-status"),
            (connectivityPeers.lockAddresses, "main-connectivity-lockaddresses"),
            (connectivityPeers.entry, "main-connectivity-entry"),
            (connectivityPeers.add, "main-connectivity-add"),
            (connectivityPeers.cancel, "main-connectivity-cancel"),
            (connectivityPeers.remembered, "main-connectivity-remembered"),
            (connectivityPeers.connect, "main-connectivity-connect"),
            (connectivityPeers.forget, "main-connectivity-forget"),
            (connectivityPeers.clear, "main-connectivity-clear"),
        ]
        for (view, key) in bindings { view.identifier = NSUserInterfaceItemIdentifier("help-" + key) }
        for slider in eqBandSliders { slider.identifier = NSUserInterfaceItemIdentifier("help-main-eq-band") }
        if let router = routerControls {
            router.checkbox.identifier = NSUserInterfaceItemIdentifier("help-main-router-checkbox")
            router.status.identifier = NSUserInterfaceItemIdentifier("help-main-router-status")
        }
        for (item, key) in zip(tabs.tabViewItems, ["connectivity", "audio", "profiles", "mix"]) {
            item.view?.identifier = NSUserInterfaceItemIdentifier("help-main-tab-" + key)
        }
    }

    static func contextHelpProductCheck(manual: FocusedHelpContent.Manual) -> (assertions: Int, failures: [String]) {
        guard AppRuntime.configuration.isIsolated, AppRuntime.configuration.isHeadless,
            AppRuntime.configuration.silent else { return (1, ["help.native.scope-refused"]) }
        let owner = AppDelegate()
        // Reuse the existing stopped native UI construction boundary, before device/input/service factories.
        owner.nativeProductFixture = true
        owner.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        var result = NativeContextHelpAudit.inspect(window: owner.window, manual: manual)
        let dialogs = NativeContextHelpAudit.inspectDialogs(factories: owner.dialogFactoriesForAudit(), manual: manual)
        result.assertions += dialogs.assertions; result.failures += dialogs.failures
        let alerts = owner.alertHelpRouteChecks(manual: manual)
        result.assertions += alerts.assertions; result.failures += alerts.failures
        let tray = owner.trayMenuHelpChecks(manual: manual)
        result.assertions += tray.assertions; result.failures += tray.failures
        let routes = owner.dialogHelpRouteChecks(manual: manual)
        result.assertions += routes.assertions; result.failures += routes.failures
        var opens = 0
        func open(_ file: URL) -> Bool { opens += 1; return true }
        let missing = owner.openManual(file: nil, open: open)
        result.assertions += 1
        if missing || opens != 0 || !owner.status.stringValue.contains("manual is missing or unreadable") { result.failures.append("help.native.missing-manual-notice") }
        let file = Bundle.main.url(forResource: "Manual", withExtension: "html")
        let directory = owner.openManual(file: file?.deletingLastPathComponent(), open: open)
        result.assertions += 1
        if directory || opens != 0 { result.failures.append("help.native.directory-not-a-manual") }
        let refused = owner.openManual(file: file, open: { _ in opens += 1; return false })
        result.assertions += 1
        if refused || opens != 1 || !owner.status.stringValue.contains("could not be opened") { result.failures.append("help.native.reader-failure-notice") }
        let accepted = owner.openManual(file: file, open: open)
        result.assertions += 1
        if !accepted || opens != 2 { result.failures.append("help.native.manual-open-dispatch") }
        result.assertions += 1
        if owner.window.contextHelp == nil { result.failures.append("help.native.main-help-key-caller") }
        owner.window.makeFirstResponder(owner.password)
        let captured = FocusedHelpContent.capture(in: owner.window)
        result.assertions += 1
        if captured.text != manual.entry("main-password") || captured.focusedView !== owner.password { result.failures.append("help.native.secure-field-manual-caller") }

        func require(_ value: Bool, _ code: String) { result.assertions += 1; if !value { result.failures.append("help.native." + code) } }
        require(!owner.running && owner.controlServer == nil && owner.sessionStartRequest == nil && owner.autoSaveTimer == nil, "unexpected-work")
        require(!owner.window.isVisible && owner.preferencesWindow?.isVisible == false && owner.statusItem?.isVisible != true, "unexpected-visible-ui")
        var roomClosed = false, sessionClosed = false
        func wait(_ done: () -> Bool) {
            let end = Date().addingTimeInterval(2)
            while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        }
        owner.shutdownBrowserProfile { result in if case .success = result { roomClosed = true } }
        wait { roomClosed }; require(roomClosed, "Room-retirement")
        owner.session.shutdown { sessionClosed = true }
        wait { sessionClosed }; require(sessionClosed, "Session-retirement")
        owner.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        owner.preferencesWindow?.close(); owner.window.close()
        return result
    }

    private func alertHelpRouteChecks(manual: FocusedHelpContent.Manual) -> (assertions: Int, failures: [String]) {
        precondition(nativeProductFixture && AppRuntime.configuration.isIsolated)
        var assertions = 0, failures = [String](), families = 0
        func require(_ value: Bool, _ code: String) { assertions += 1; if !value { failures.append("help.native." + code) } }
        let expected = [
            "AppDelegate.buildPeerNameAlert": "dialog-peer-name-notice",
            "AppDelegate.buildProfileNameAlert": "dialog-profile-name-notice",
            "AppDelegate.buildReadOnlySaveAlert": "dialog-read-only-save-notice",
            "AppDelegate.buildOpenProfileAlert": "dialog-open-profile-notice",
            "NamedPeersWindow.buildRenameAlert": "dialog-named-rename-notice",
            "JamController.buildSoloNotice": "dialog-solo-metronome-notice",
            "JamController.buildSelfMonitoringWarning": "dialog-self-monitor-notice",
            "PeerEqControls.buildAlert": "dialog-eq-band-notice",
        ]
        defer { focusedHelpWindow?.close(); focusedHelpWindow = nil }
        for factory in dialogFactoriesForAudit() {
            do {
                let fixture = try factory.make(); fixture.window.isReleasedWhenClosed = false
                defer { fixture.close() }
                guard let alert = fixture.alert else { continue }
                families += 1
                require(alert.showsHelp, "alert-help-hidden-" + factory.site)
                require(alert.delegate as AnyObject? === self, "alert-help-owner-" + factory.site)
                // Never dispatch AppKit help without our delegate: that would invoke the external Help Viewer.
                guard alert.showsHelp, alert.delegate as AnyObject? === self else { continue }
                let buttons = NativeDialogAudit.liveControls(in: alert.window).compactMap { $0 as? NSButton }.filter { $0.bezelStyle == .helpButton }
                require(buttons.count == 1, "alert-help-button-census-" + factory.site)
                guard let button = buttons.first, let key = expected[factory.site] else { continue }
                let identities = alert.buttons.map(\.identifier), responses = alert.buttons.map(\.keyEquivalent)
                let focus = alert.window.initialFirstResponder
                let suppression = alert.suppressionButton?.state
                require(FocusedHelpContent.key(of: button) == key, "alert-help-button-key-" + factory.site)
                focusedHelpWindow?.close(); focusedHelpWindow = nil
                button.performClick(nil)
                guard let help = focusedHelpWindow else { require(false, "alert-help-no-reader-" + factory.site); continue }
                require(help.textView.string == manual.entry(key), "alert-help-manual-words-" + factory.site)
                require(help.textView.selectedRange() == NSRange(location: 0, length: 0), "alert-help-reader-selection")
                require(!help.textView.string.contains("Synthetic"), "alert-help-private-value")
                require(alert.buttons.map(\.identifier) == identities && alert.buttons.map(\.keyEquivalent) == responses, "alert-help-response-identity")
                require(alert.window.initialFirstResponder === focus, "alert-help-initial-focus")
                require(alert.suppressionButton?.state == suppression, "alert-help-suppression")
                require(NSApp.modalWindow == nil && !alert.window.isVisible && help.window?.isVisible == false, "alert-help-unexpected-modal-or-visibility")
                require(help.window?.worksWhenModal == false, "alert-help-unowned-modal-bypass")
                help.close(); focusedHelpWindow = nil
            } catch { require(false, "alert-help-factory-" + factory.site) }
        }
        require(families == 8, "alert-help-family-census")
        return (assertions, failures)
    }

    private func trayMenuHelpChecks(manual: FocusedHelpContent.Manual) -> (assertions: Int, failures: [String]) {
        precondition(nativeProductFixture && AppRuntime.configuration.isIsolated)
        var assertions = 0, failures = [String](), used = Set<String>()
        func require(_ value: Bool, _ code: String) { assertions += 1; if !value { failures.append("help.native." + code) } }
        let recentBefore = AppRuntime.settings.object(forKey: "recentProfileIDs")
        let oldProfiles = recentMenuProfiles
        var made = [UUID]()
        defer {
            for id in made { try? profileStore.delete(id: id) }
            if let recentBefore { AppRuntime.settings.set(recentBefore, forKey: "recentProfileIDs") }
            else { AppRuntime.settings.removeObject(forKey: "recentProfileIDs") }
            refreshRecentProfileMenus(); recentMenuProfiles = oldProfiles
        }
        AppRuntime.settings.removeObject(forKey: "recentProfileIDs"); refreshRecentProfileMenus()
        let menu = makeStatusMenu()
        func inspect() {
            let result = NativeContextHelpAudit.inspectMenu(menu, manual: manual)
            assertions += result.assertions; failures += result.failures; used.formUnion(result.used)
        }
        inspect()
        require(statusItem == nil, "tray-created-status-item")
        require(statusRecentProfilesMenu.items.count == 1 && !statusRecentProfilesMenu.items[0].isEnabled, "tray-empty-recent-state")
        let items = menu.items
        let actions = items.map(\.action), targets = items.map { $0.target as AnyObject? }
        let states = items.map(\.state), enabled = items.map(\.isEnabled), shortcuts = items.map(\.keyEquivalent)
        do {
            for title in ["Synthetic first private title", "Synthetic second private title"] {
                let profile = profileSnapshot(id: UUID(), title: title, readOnly: false)
                try profileStore.save(profile); made.append(profile.id)
            }
            AppRuntime.settings.set(made.map(\.uuidString), forKey: "recentProfileIDs"); refreshRecentProfileMenus()
            inspect()
            require(statusRecentProfilesMenu.items.count == 2, "tray-recent-item-census")
            for (index, item) in statusRecentProfilesMenu.items.enumerated() {
                require(index < made.count && item.representedObject as? String == made[index].uuidString, "tray-recent-identity")
                require(item.target as AnyObject? === self && item.action == #selector(openRecentProfile(_:)), "tray-recent-action")
                require(item.toolTip?.contains("Synthetic") == false, "tray-private-value-in-help")
            }
            require(menu.items.elementsEqual(items, by: { $0 === $1 }), "tray-static-item-identity")
            require(menu.items.map(\.action) == actions && menu.items.map(\.state) == states && menu.items.map(\.isEnabled) == enabled && menu.items.map(\.keyEquivalent) == shortcuts, "tray-static-behaviour-drift")
            require(zip(menu.items, targets).allSatisfy { $0.target as AnyObject? === $1 }, "tray-static-target-drift")
        } catch { require(false, "tray-profile-fixture") }
        require(Set(manual.entries.keys.filter { $0.hasPrefix("tray-") }) == used, "stale-tray-entry")
        require(statusItem == nil && !running && controlServer == nil && sessionStartRequest == nil, "tray-unexpected-work")
        return (assertions, failures)
    }

    private func dialogHelpRouteChecks(manual: FocusedHelpContent.Manual) -> (assertions: Int, failures: [String]) {
        precondition(nativeProductFixture && AppRuntime.configuration.isIsolated)
        var assertions = 0, failures = [String](), families = 0
        func require(_ value: Bool, _ code: String) { assertions += 1; if !value { failures.append("help.native." + code) } }
        let oldReader = manualReader
        var manualRequests = 0, manualTargetsValid = true
        var requestedKey: String?
        manualReader = { file in
            manualRequests += 1
            let cached = AppRuntime.configuration.root?.appendingPathComponent("Cache/RemSound/Manual", isDirectory: true)
            let valid: Bool
            if let requestedKey, let cached {
                let bundled = Bundle.main.url(forResource: "Manual", withExtension: "html")
                    .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                valid = file == cached.appendingPathComponent("open.html") &&
                    (try? String(contentsOf: file, encoding: .utf8)) == ManualHTML.redirect(to: "README.html", key: requestedKey) &&
                    bundled != nil && (try? String(contentsOf: cached.appendingPathComponent("README.html"), encoding: .utf8)) == bundled
            } else { valid = file == Bundle.main.url(forResource: "Manual", withExtension: "html") }
            manualTargetsValid = manualTargetsValid && valid
            return valid
        }
        defer { manualReader = oldReader; focusedHelpWindow?.close(); focusedHelpWindow = nil }
        let preferred = [
            "AppDelegate.configurePreferencesWindow": "dialog-preferences-showhidehotkey",
            "BrowserListenerWindow.init": "dialog-browser-password",
            "NamedPeersWindow.init": "dialog-named-peers-table",
            "PushToTalkSettingsWindow.init": "dialog-ptt-key",
            "ServerWindowController.init": "dialog-server-address",
            "ServerConnectionNoticeWindow.init": "dialog-server-notice-message",
            "ServerVersionWarningWindow.init": "dialog-server-version-message",
            "MetronomeSettingsWindow.init": "dialog-metronome-tempo",
        ]
        for factory in dialogFactoriesForAudit() {
            do {
                let fixture = try factory.make()
                fixture.window.isReleasedWhenClosed = false
                defer { fixture.close() }
                guard let keyboard = fixture.window as? KeyboardWindow else { continue }
                families += 1
                require(keyboard.contextHelp != nil, "unwired-window-" + factory.site)
                guard keyboard.contextHelp != nil else { continue }
                let controls = NativeDialogAudit.liveControls(in: keyboard)
                guard let key = preferred[factory.site],
                    let target = controls.first(where: { $0 is HotkeyCaptureField && FocusedHelpContent.key(of: $0) == key })
                        ?? controls.first(where: { FocusedHelpContent.key(of: $0) == key }) else {
                    require(false, "route-control-" + factory.site); continue
                }
                require(keyboard.makeFirstResponder(target), "route-focus-" + factory.site)
                let descriptor = (target as? HotkeyCaptureField)?.descriptor
                func f1(_ flags: NSEvent.ModifierFlags) -> NSEvent {
                    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: keyboard.windowNumber, context: nil, characters: String(UnicodeScalar(NSF1FunctionKey)!),
                        charactersIgnoringModifiers: String(UnicodeScalar(NSF1FunctionKey)!), isARepeat: false, keyCode: UInt16(kVK_F1))!
                }
                focusedHelpWindow?.close(); focusedHelpWindow = nil
                keyboard.sendEvent(f1(.function))
                guard let help = focusedHelpWindow else { require(false, "route-no-help-" + factory.site); continue }
                require(help.textView.string == manual.entry(key), "route-manual-words-" + factory.site)
                require(help.textView.selectedRange() == NSRange(location: 0, length: 0), "route-reader-selection-" + factory.site)
                require(help.window?.isVisible == false && !keyboard.isVisible, "route-visible-ui")
                require(FocusedHelpContent.capture(in: keyboard).focusedView === target, "route-owner-focus-" + factory.site)
                let before = manualRequests
                keyboard.sendEvent(f1([.shift, .function]))
                require(manualRequests == before + 1, "route-manual-dispatch-" + factory.site)
                require(focusedHelpWindow === help, "route-manual-retired-help")
                requestedKey = key
                help.manualButton.performClick(nil)
                requestedKey = nil
                require(manualRequests == before + 2, "route-reader-button-" + factory.site)
                require(manualTargetsValid, "route-wrong-manual-target")
                require(focusedHelpWindow === help, "route-reader-button-retired-help")
                keyboard.sendEvent(f1(.function))
                require(focusedHelpWindow === help, "route-repeated-help")
                require((target as? HotkeyCaptureField)?.descriptor == descriptor, "route-shortcut-capture-" + factory.site)
                help.close(); focusedHelpWindow = nil
                require(FocusedHelpContent.capture(in: keyboard).focusedView === target, "route-close-focus-" + factory.site)
            } catch { require(false, "route-factory-" + factory.site) }
        }
        require(families == 8, "window-route-family-census")
        return (assertions, failures)
    }

    static func controlSpecificationsProductCheck() -> (assertions: Int, failures: [String]) {
        guard AppRuntime.configuration.isIsolated, AppRuntime.configuration.isHeadless,
            AppRuntime.configuration.silent else { return (1, ["controls.native.scope-refused"]) }
        let owner = AppDelegate()
        // Reuse the existing stopped native UI construction boundary, before device/input/service factories.
        owner.nativeProductFixture = true
        owner.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        var fields = MainWindowControlAudit.fields(of: owner)
        fields.merge(MainWindowControlAudit.fields(of: owner.connectivityPeers, prefix: "connectivity.")) { first, _ in first }
        if let router = owner.routerControls {
            fields.merge(MainWindowControlAudit.fields(of: router, prefix: "router.")) { first, _ in first }
        }
        var result = MainWindowControlAudit.inspect(window: owner.window, fields: fields)
        func require(_ value: Bool, _ code: String) { result.assertions += 1; if !value { result.failures.append("controls.native." + code) } }
        require(!owner.running && owner.controlServer == nil && owner.sessionStartRequest == nil && owner.autoSaveTimer == nil, "unexpected-work")
        require(!owner.window.isVisible && owner.preferencesWindow?.isVisible == false && owner.statusItem?.isVisible != true, "unexpected-visible-ui")
        var roomClosed = false, sessionClosed = false
        func wait(_ done: () -> Bool) {
            let end = Date().addingTimeInterval(2)
            while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        }
        owner.shutdownBrowserProfile { result in if case .success = result { roomClosed = true } }
        wait { roomClosed }; require(roomClosed, "Room-retirement")
        owner.session.shutdown { sessionClosed = true }
        wait { sessionClosed }; require(sessionClosed, "Session-retirement")
        owner.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        owner.preferencesWindow?.close(); owner.window.close()
        return result
    }

    private func dialogFactoriesForAudit() -> [NativeDialogAudit.Factory] {
        let owner = self
        func fixture(_ controller: NSWindowController, retire: (() -> Void)? = nil) throws -> NativeDialogAudit.Fixture {
            guard let window = controller.window else { throw NativeDialogAudit.Failure.missingWindow }
            return .init(window: window, controller: controller, retire: retire)
        }
        func alertFixture(_ alert: NSAlert, retained: Any? = nil) -> NativeDialogAudit.Fixture {
            alert.layout()
            return .init(window: alert.window, retained: retained, alert: alert)
        }
        func profilesForDialog() throws -> [ConnectionProfile] {
            if try owner.profileStore.list().isEmpty {
                try owner.profileStore.save(.init(title: "Synthetic", displayName: "RemSound Mac", manualPeerAddress: "",
                    selectedPeerAddresses: [], sendInput: false, receiveAudio: false, allowPlugins: true, reconnectOnOpen: false))
            }
            return try owner.profileStore.list()
        }
        return [
            .init(site: "AppDelegate.buildPeerNameAlert", make: { alertFixture(owner.buildPeerNameAlert(initial: "Synthetic").0) }),
            .init(site: "AppDelegate.buildProfileNameAlert", make: { alertFixture(owner.buildProfileNameAlert(message: "Save Profile As", initial: "Synthetic").0) }),
            .init(site: "AppDelegate.buildReadOnlySaveAlert", make: { alertFixture(owner.buildReadOnlySaveAlert(title: "Synthetic").0) }),
            .init(site: "AppDelegate.buildOpenProfileAlert", make: { alertFixture(owner.buildOpenProfileAlert(profiles: try profilesForDialog()).0) }),
            .init(site: "NamedPeersWindow.buildRenameAlert", make: {
                let controller = owner.makeNamedPeersWindow()
                let alert = controller.makeRenameAlert(machine: "Synthetic", initial: "Synthetic").0
                return .init(window: alert.window, controller: controller, alert: alert, retire: { controller.close() })
            }),
            .init(site: "JamController.buildSoloNotice", make: { alertFixture(owner.jam.makeSoloNotice()) }),
            .init(site: "JamController.buildSelfMonitoringWarning", make: { alertFixture(owner.jam.makeSelfMonitoringWarning()) }),
            .init(site: "PeerEqControls.buildAlert", make: { let prompt = AddBandDialog.buildPrompt(preview: { _ in }); return alertFixture(AddBandDialog.buildAlert(prompt: prompt, focus: prompt.start, helpDelegate: owner), retained: prompt) }),
            .init(site: "AppDelegate.configurePreferencesWindow", make: { guard let window = owner.preferencesWindow else { throw NativeDialogAudit.Failure.missingWindow }; return .init(window: window) }),
            .init(site: "FocusedHelpWindow.init", make: { try fixture(FocusedHelpWindowController(content: .init(title: "Help", text: "Synthetic help", focusedView: nil), owner: owner.window, playOpen: {}, playClose: {}, openManual: {})) }),
            .init(site: "QuickProfileSwitchWindow.init", make: { guard let controller = QuickProfileSwitchWindowController(profiles: [.init(id: UUID(), title: "Synthetic", isCurrent: true)], owner: owner.window, playOpen: {}, contextHelp: { _ in }, completed: { _ in }) else { throw NativeDialogAudit.Failure.missingWindow }; return try fixture(controller) }),
            .init(site: "BrowserListenerWindow.init", make: {
                guard let ticket = owner.browserListener.beginConfiguration(.init(account: UUID(), revision: UUID(), readOnly: true)),
                    let edit = BrowserListenerEdit(opened: .empty, isCurrent: { true }, apply: { _, done in done(true); return true }) else { throw NativeDialogAudit.Failure.missingWindow }
                let model = BrowserListenerAddressModel(owner: owner.browserListener, ticket: ticket, isCurrent: { false })
                guard let controller = BrowserListenerWindow(edit: edit, visit: .stopped, persistence: .readOnly, contextHelp: owner.contextHelpAction,
                    address: model, copyAddress: { _ in false }, didEnd: { _, _ in }, announce: { _, _ in }) else {
                    owner.browserListener.endConfiguration(ticket); throw NativeDialogAudit.Failure.missingWindow
                }
                return try fixture(controller, retire: { controller.invalidateContext(); owner.browserListener.endConfiguration(ticket) })
            }),
            .init(site: "NamedPeersWindow.init", make: { try fixture(owner.makeNamedPeersWindow()) }),
            .init(site: "PushToTalkSettingsWindow.init", make: { try fixture(PushToTalkSettingsWindow(settings: .init(), binding: nil, contextHelp: owner.contextHelpAction, accept: { _ in nil }, announce: { _, _ in })) }),
            .init(site: "ServerWindowController.init", make: { try fixture(ServerWindowController(controller: owner.jam)) }),
            .init(site: "MetronomeSettingsWindow.init", make: {
                let controller = MetronomeSettingsWindow(choices: .init(), volume: 70, sounds: ["Click"], master: nil, keys: [],
                    state: { .init(playing: false, following: false, muted: false) }, startStop: {},
                    heardLive: { _, _ in }, loadSound: { _ in nil }, preview: { _, _, _ in },
                    contextHelp: owner.contextHelpAction, finishWith: { _, _, _, _, _ in })
                return try fixture(controller, retire: { controller.cancelPressed() })
            }),
            .init(site: "ServerConnectionNoticeWindow.init", make: { let controller = ServerConnectionNoticeWindow(contextHelp: owner.jam.contextHelp, answer: { _ in }); return try fixture(controller, retire: { controller.retire() }) }),
            .init(site: "ServerVersionWarningWindow.init", make: { let controller = ServerVersionWarningWindow(server: "Synthetic", latestReleased: nil, isCurrent: { true }, contextHelp: owner.jam.contextHelp, browser: { _ in false }, answer: { _ in }); return try fixture(controller, retire: { controller.retire() }) })
        ]
    }

    static func dialogProductCheck(sources: [String: String], controls: Bool) -> (assertions: Int, failures: [String]) {
        guard AppRuntime.configuration.isIsolated, AppRuntime.configuration.isHeadless,
            AppRuntime.configuration.silent else { return (1, ["dialogs.native.scope-refused"]) }
        let owner = AppDelegate(); owner.nativeProductFixture = true
        owner.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let factories = owner.dialogFactoriesForAudit()
        let nonDialogs: [String: Int] = [
            // Main host and old visible-only acceptance hosts are not dialogs. Never invoke the latter here.
            "AppDelegate.applicationDidFinishLaunching": 1, "AppDelegate.quickProfileAccessibilityFailures": 1,
            "AppDelegate.focusedHelpAccessibilityFailures": 1, "AppEntry.body": 1,
            // Platform-owned pickers and message-only NSAlerts correspond to common dialogs/MessageBox.
            // The census refuses this exception if an alert acquires custom fields or a suppression choice.
            "AppDelegate.openProfile": 1, "AppDelegate.confirmProfileChange": 1, "AppDelegate.deleteProfile": 1,
            "AppDelegate.about": 1, "AppDelegate.applicationShouldTerminate": 1, "AppDelegate.finishTermination": 1,
            "AppDelegate.browseCue": 1, "AppDelegate.changeRecordingsFolder": 1, "PeerEqControls.run": 1,
            "JamController.chooseLogFolder": 1, "JamController.ask": 1,
            "UpdateService.confirm": 1, "UpdateService.showAlert": 1, "main.alert": 1
        ]
        var result = NativeDialogAudit.inspect(sources: sources, factories: factories, nonDialogs: nonDialogs, controls: controls)
        func require(_ value: Bool, _ code: String) { result.assertions += 1; if !value { result.failures.append("dialogs.native." + code) } }
        require(!owner.running && owner.controlServer == nil && owner.sessionStartRequest == nil && owner.autoSaveTimer == nil, "unexpected-work")
        require(!owner.window.isVisible && owner.statusItem?.isVisible != true, "unexpected-visible-ui")
        if controls {
            let logs = owner.profileLoggingProductAssertions()
            result.assertions += logs.assertions
            result.failures += logs.failures.map { _ in "dialogs.native.profile-logging-effect" }
        } else {
            var roomClosed = false, sessionClosed = false
            func wait(_ done: () -> Bool) { let end = Date().addingTimeInterval(2); while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) } }
            owner.shutdownBrowserProfile { result in if case .success = result { roomClosed = true } }
            wait { roomClosed }; require(roomClosed, "Room-retirement")
            owner.session.shutdown { sessionClosed = true }
            wait { sessionClosed }; require(sessionClosed, "Session-retirement")
            owner.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            owner.window.close()
        }
        return result
    }

    static func profileLoggingProductCheck() -> (assertions: Int, failures: [String]) {
        guard AppRuntime.configuration.isIsolated, AppRuntime.configuration.isHeadless,
            AppRuntime.configuration.silent else { return (1,["logs.native.scope-refused"]) }
        let owner=AppDelegate()
        owner.nativeProductFixture=true
        owner.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
        return owner.profileLoggingProductAssertions()
    }
    private func profileLoggingProductAssertions() -> (assertions: Int, failures: [String]) {
        guard AppRuntime.configuration.isIsolated, AppRuntime.configuration.isHeadless else { return (1,["logs.native.isolated-headless-required"]) }
        var failures=[String](),checks=0
        func require(_ condition:Bool,_ message:String) {checks += 1;if !condition {failures.append("logs.native.assertion-"+String(checks))}}
        func wait(_ condition:()->Bool) {
            let end=Date().addingTimeInterval(2)
            while !condition() && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.005))}
        }
        func retire() { _ = retireBrowserBeforeProfilePrompt();wait{browserListener.profileContextRetired} }
        func profile(_ title:String,_ choice:Bool?,readOnly:Bool=false)->ConnectionProfile {
            .init(title:title,displayName:"RemSound Mac",manualPeerAddress:"",selectedPeerAddresses:[],sendInput:false,receiveAudio:false,allowPlugins:true,reconnectOnOpen:false,readOnly:readOnly,enableLogs:choice)
        }
        do {
            retire()
            let on=profile("Logs on",true),off=profile("Logs off",false),inherit=profile("Inherited logs",nil)
            for p in [on,off,inherit] {try profileStore.save(p)}
            require(showProfile(on,loadPassword:false,browserContextAlreadyRetired:true),"open on refused")
            require(effectiveLoggingEnabled && session.diagnosticLoggingEnabled && DiagnosticLoggingPreferences.enabled(in:AppRuntime.settings),"explicit on did not reach Root/Session/computer")
            require(profileSnapshot(id:on.id,title:on.title,readOnly:false).enableLogs == true,"on snapshot lost")
            retire();require(showProfile(off,loadPassword:false,browserContextAlreadyRetired:true),"open off refused")
            require(!effectiveLoggingEnabled && !session.diagnosticLoggingEnabled && !DiagnosticLoggingPreferences.enabled(in:AppRuntime.settings),"explicit off did not reach Root/Session/computer")
            retire();require(showProfile(inherit,loadPassword:false,browserContextAlreadyRetired:true),"open inherit refused")
            require(!effectiveLoggingEnabled && profileLoggingChoice == nil,"absent choice changed")
            let before=try Data(contentsOf:AppRuntime.configuration.root!.appendingPathComponent("settings.plist"))
            require(applyProfileLogging(nil),"inherit refresh refused")
            require(try Data(contentsOf:AppRuntime.configuration.root!.appendingPathComponent("settings.plist")) == before,"inherit wrote computer settings")
            enableLogs.state = .on;profileLoggingChanged()
            require(profileLoggingChoice == true && hasUnsavedProfileChanges && effectiveLoggingEnabled && session.diagnosticLoggingEnabled,"preferences not immediate/unsaved")
            require((try profileStore.load(id:inherit.id)).enableLogs == nil,"preferences silently saved profile")
            let file=AppRuntime.configuration.logsDirectory.appendingPathComponent("Latest.log")
            session.note("native profile logging product marker")
            require(session.diagnosticLoggingEnabled,"actual logger write barrier")
            let enabledBytes=try Data(contentsOf:file)
            require(String(decoding:enabledBytes,as:UTF8.self).contains("native profile logging product marker"),"native logger effect missing")
            enableLogs.state = .off;profileLoggingChanged()
            let offBytes=try Data(contentsOf:file)
            session.note("native suppressed product marker")
            let disabled = !session.diagnosticLoggingEnabled
            let suppressedBytes = try Data(contentsOf:file)
            require(disabled && suppressedBytes==offBytes && !effectiveLoggingEnabled,"native off did not suppress")
            enableLogs.state = .on;profileLoggingChanged()
            retire();try persistCurrentProfile()
            require((try profileStore.load(id:inherit.id)).enableLogs == true,"actual Save lost preference")
            require(DiagnosticLoggingPreferences.setEnabled(true,in:AppRuntime.settings),"inherit-on setup refused")
            retire();require(showProfile(inherit,loadPassword:false,browserContextAlreadyRetired:true),"inherit on open refused")
            require(profileLoggingChoice == nil && effectiveLoggingEnabled && session.diagnosticLoggingEnabled,"inherit on ignored")
            let settings=AppRuntime.configuration.root!.appendingPathComponent("settings.plist")
            let computerBytes=try Data(contentsOf:settings)
            try FileManager.default.removeItem(at:settings);try FileManager.default.createDirectory(at:settings,withIntermediateDirectories:false)
            enableLogs.state = .off;profileLoggingChanged()
            require(profileLoggingChoice == nil && effectiveLoggingEnabled && enableLogs.state == .on,"failed machine save changed gate")
            try FileManager.default.removeItem(at:settings)
            guard FileManager.default.createFile(atPath:settings.path,contents:computerBytes,attributes:[.posixPermissions:0o600]) else {throw NSError(domain:"Native logging fixture",code:1)}
            var locked=off;locked.readOnly=true;retire();require(showProfile(locked,loadPassword:false,browserContextAlreadyRetired:true),"read-only open refused")
            enableLogs.state = .on;profileLoggingChanged()
            require(profileLoggingChoice == true && !hasUnsavedProfileChanges && effectiveLoggingEnabled,"read-only temporary choice wrong")
            require((try profileStore.load(id:off.id)).enableLogs == false,"temporary read-only choice wrote profile")
            retire();profileLoggingModalCancel=true
            require(!saveCurrentProfile(),"read-only Save Cancel accepted")
            profileLoggingModalCancel=false
            let cancelledSavedProfile=try profileStore.load(id:off.id)
            require(profileLoggingChoice == true && effectiveLoggingEnabled && cancelledSavedProfile.enableLogs == false,"Save Cancel changed logging or disk")
            profileModalActive=true;enableLogs.state = .off;profileLoggingChanged();profileModalActive=false
            require(profileLoggingChoice == true && effectiveLoggingEnabled && enableLogs.state == .on,"pending-modal choice changed state")
            retire();require(resetToBlankProfile(browserContextAlreadyRetired:true),"New refused")
            require(profileLoggingChoice == false && !effectiveLoggingEnabled && !session.diagnosticLoggingEnabled,"New did not switch logging off")
            retire();try persistProfileAs("New with logs off")
            require((try profileStore.load(id:activeProfile!.id)).enableLogs == false,"New/Save As lost explicit off")
            let open=ControlRequest(action:"profile-open",arguments:["value":on.id.uuidString])
            retire();let opened=performControlCommand(try ControlCommand(open),request:open)
            require(opened.status == .ok && activeProfile?.id == on.id && effectiveLoggingEnabled,"actual control Open lost profile logging")
            enableLogs.state = .off;profileLoggingChanged();retire()
            let current=activeProfile!,target=AppRuntime.configuration.profilesDirectory.appendingPathComponent(current.id.uuidString+".json")
            let disk=try Data(contentsOf:target)
            try FileManager.default.removeItem(at:target);try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false)
            var saveRefused=false
            do {try persistCurrentProfile()} catch {saveRefused=true}
            require(saveRefused && activeProfile == current && profileLoggingChoice == false && !effectiveLoggingEnabled,"failed profile save lost current choice or acknowledged success")
            try FileManager.default.removeItem(at:target)
            guard FileManager.default.createFile(atPath:target.path,contents:disk,attributes:[.posixPermissions:0o600]) else {throw NSError(domain:"Native logging fixture",code:2)}
            if preferencesWindow == nil { configurePreferencesWindow() }
            require(generalPreferencesOrder.contains{$0===enableLogs} && enableLogs.action == #selector(profileLoggingChanged) && !(enableLogs.accessibilityHelp() ?? "").isEmpty,"logging control accessibility/tab/caller missing")
            preferencesWindow?.orderOut(nil)
            let reply=controlState()
            require(reply["diagnostic-logging"] == "false","actual control status stale")
        } catch {failures.append("logs.native.owned-operation-failed-"+String((error as NSError).code))}
        require(!running && controlServer == nil && sessionStartRequest == nil, "native fixture started work")
        require(!window.isVisible && preferencesWindow?.isVisible == false && statusItem?.isVisible != true, "fixture visible")
        var roomClosed=false,sessionClosed=false
        shutdownBrowserProfile { result in if case .success = result { roomClosed=true } }
        wait { roomClosed }
        require(roomClosed, "full Room did not retire")
        session.shutdown { sessionClosed=true }
        wait { sessionClosed }
        require(sessionClosed, "actual Session did not retire")
        applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification))
        preferencesWindow?.close(); window.close()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        return (checks,failures)
    }

    @discardableResult private func applyProfileLogging(_ choice: Bool?) -> Bool {
        guard session.applyDiagnosticLogging(profileChoice: choice) else {
            announce("Could not save this computer's logging choice. The current logging choice was kept.")
            return false
        }
        profileLoggingChoice = choice
        effectiveLoggingEnabled = session.diagnosticLoggingEnabled
        enableLogs.state = effectiveLoggingEnabled ? .on : .off
        uiObservations.setEnabled(effectiveLoggingEnabled)
        return true
    }
    @objc private func profileLoggingChanged() {
        guard !profileModalActive, terminationRequest == nil, browserProfileRemoval == nil,
              applyProfileLogging(enableLogs.state == .on) else {
            enableLogs.state = effectiveLoggingEnabled ? .on : .off
            return
        }
        refreshProfileNotice()
        NSAccessibility.post(element: enableLogs, notification: .valueChanged)
        announce(effectiveLoggingEnabled ? "Diagnostic logs on for this profile." : "Diagnostic logs off for this profile.")
    }
    @objc private func acceptConnectionsChanged() {
        let index = acceptConnections.indexOfSelectedItem
        guard AcceptConnections.allCases.indices.contains(index) else { return }
        jam.setAcceptConnections(AcceptConnections.allCases[index])
    }

    @objc private func acceptRemoteVolumeChanged() {
        AppRuntime.settings.set(acceptRemoteVolume.state == .on, forKey: "acceptRemoteVolumeCommands")
        session.setAcceptRemoteCommands(acceptRemoteVolume.state == .on)
        announce(acceptRemoteVolume.state == .on
            ? "Peers can now change this Mac's volume and mute." : "Remote volume commands are ignored.")
    }
    private var chosenCueEvent: CueEvent {
        cuePane.selectedEvent
    }
    @objc private func cueMuteChanged() {
        let muted = cueMute.state == .on
        CueSounds.shared.setMuteAllCues(muted)
        refreshTypingFeedback()
        recordStartup("All audio cues muted: \(muted).")
        NSAccessibility.post(element: cueMute, notification: .valueChanged)
    }
    private func refreshCueChoices() { cuePane.refresh() }
    @objc private func cueChoiceChanged() {
        guard let name = cueChoice.selectedItem?.representedObject as? String else { return }
        let event = chosenCueEvent
        let cues = CueSounds.shared.preferences
        if name == "Off" { cues.setEnabled(false, for: event) }
        else if name == "Custom", let path = cueCustomFiles[event] {
            cues.chooseCustomFile(path, for: event)
        } else { cues.chooseBuiltIn(name, for: event) }
        recordStartup("Audio cue changed: \(event.rawValue), \(event.isProfileSetting ? "profile" : "machine"), \(name).")
        refreshCueChoices()
        if name != "Off" { previewCue() }
    }
    @objc private func browseCue() {
        guard let preferencesWindow else { return }
        let event = chosenCueEvent
        let panel = NSOpenPanel()
        panel.title = "Choose a WAV file for \(event.title)"
        panel.allowedContentTypes = [.wav]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let path = CueSounds.shared.preferences.configuration(for: event).customPath {
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        let profileID = activeProfile?.id ?? draftProfileID
        recordStartup("Custom audio cue chooser opened: \(event.rawValue).")
        panel.beginSheetModal(for: preferencesWindow) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let valid = (try? AVAudioFile(forReading: url)) != nil
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard !event.isProfileSetting || (self.activeProfile?.id ?? self.draftProfileID) == profileID else {
                        self.recordStartup("Custom audio cue validation discarded after profile change.")
                        return
                    }
                    guard valid else {
                        self.recordStartup("Custom audio cue validation failed: \(event.rawValue).")
                        self.announce("This WAV file could not be opened. Choose another sound.")
                        return
                    }
                    if let name = CueSounds.shared.builtInName(for: url, event: event) {
                        CueSounds.shared.preferences.chooseBuiltIn(name, for: event)
                    } else {
                        CueSounds.shared.preferences.chooseCustomFile(url.path, for: event)
                        self.cueCustomFiles[event] = url.path
                    }
                    self.recordStartup("Custom audio cue choice accepted: \(event.rawValue).")
                    self.refreshCueChoices()
                    CueSounds.shared.play(event, preview: true)
                }
            }
        }
    }
    @objc private func previewCue() {
        CueSounds.shared.play(chosenCueEvent, preview: true) { [weak self] message in
            if let message { self?.announce(message) }
        }
    }
    @objc private func updatePreferencesChanged() {
        AppRuntime.settings.set(checkUpdates.state == .on,
            forKey: "checkUpdatesAutomatically")
        AppRuntime.settings.set(installUpdates.state == .on,
            forKey: "installUpdatesAutomatically")
    }
    @objc private func updateScheduleChanged() {
        let frequency = UpdateCheckFrequency.allCases[max(0, updateFrequency.indexOfSelectedItem)]
        let start = max(0, updateWindowStart.indexOfSelectedItem) * UpdateWindow.slotMinutes
        let end = max(0, updateWindowEnd.indexOfSelectedItem) * UpdateWindow.slotMinutes
        AppRuntime.settings.set(frequency.rawValue, forKey: UpdateCheckFrequency.settingsKey)
        AppRuntime.settings.set(updateWindowEnabled.state == .on, forKey: UpdateWindow.enabledKey)
        AppRuntime.settings.set(start, forKey: UpdateWindow.startKey)
        AppRuntime.settings.set(end, forKey: UpdateWindow.endKey)
        AppRuntime.settings.set(showWhatsNew.state == .on, forKey: UpdateService.whatsNewKey)
        refreshUpdateWindowControls()
        updates.scheduleBackgroundChecks()
    }
    /// The range's times count only while the range is on.
    private func refreshUpdateWindowControls() {
        let on = updateWindowEnabled.state == .on
        updateWindowStart.isEnabled = on
        updateWindowEnd.isEnabled = on
    }
    @objc private func autoSaveIntervalChanged() {
        let minutes = autoSaveInterval.selectedItem?.representedObject as? Int ?? 0
        AppRuntime.settings.set(minutes, forKey: "autoSaveNonReadOnlyMinutes")
        configureAutoSaveTimer()
    }
    private func configureAutoSaveTimer() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
        let minutes = autoSaveInterval.selectedItem?.representedObject as? Int ?? 0
        guard minutes > 0 else { return }
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60),
            repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.autoSaveCurrentProfileIfDue() }
            }
    }
    private func autoSaveCurrentProfileIfDue() {
        guard let saved = activeProfile, !saved.readOnly else { return }
        let updated = profileSnapshot(id: saved.id, title: saved.title, readOnly: false)
        guard updated != saved else { return }
        do {
            try profileStore.save(updated)
            activeProfile = updated
            refreshProfileNotice()
            NSLog("RemSound auto-saved profile %@", saved.title)
        } catch {
            NSLog("RemSound could not auto-save profile: %@", error.localizedDescription)
        }
    }
    private func selectTab(_ index: Int, firstControl: NSView) {
        if preferencesWindow?.isKeyWindow == true {
            guard preferencesTabs.tabViewItems.indices.contains(index) else {
                announce("Preferences has three tabs: General, Audio cues and Permissions.")
                return
            }
            preferencesTabs.selectTabViewItem(at: index)
            preferencesWindow?.makeFirstResponder(preferencesTabs)
            NSAccessibility.post(element: preferencesTabs, notification: .valueChanged)
            return
        }
        showWindow()
        // The section by name: its place depends on the order chosen in Preferences.
        guard mainTabItems.indices.contains(index), let item = Optional(mainTabItems[index]),
              tabs.tabViewItems.contains(item) else {
            if mainTabItems.indices.contains(index) {
                announce("The \(mainTabItems[index].label) tab is hidden. Show it in Preferences, General.")
            } else { tabs.selectTabViewItem(at: index) }
            return
        }
        tabs.selectTabViewItem(item)
        focusTabEntry(firstControl)
    }
    /// The main window's tabs in the order chosen in Preferences, without the Pan / EQ tab when it is hidden there.
    private func applyMainTabs() {
        guard !mainTabItems.isEmpty else { return }
        let showPanEq = PreferencesExtras.flag(PreferencesExtras.showPanEqTabKey, default: true)
        let wanted = PreferencesExtras.storedTabOrder().compactMap { title in
            mainTabItems.first { ($0.identifier as? String) == title }
        }.filter { showPanEq || ($0.identifier as? String) != "Pan / EQ" }
        guard wanted != tabs.tabViewItems else { return }
        let selected = tabs.selectedTabViewItem
        for item in tabs.tabViewItems { tabs.removeTabViewItem(item) }
        for item in wanted { tabs.addTabViewItem(item) }
        if let selected, wanted.contains(selected) { tabs.selectTabViewItem(selected) }
        else if let first = wanted.first { tabs.selectTabViewItem(first) }
    }
    private func focusTabEntry(_ firstControl: NSView) {
        if (firstControl as? NSControl)?.isEnabled != false,
            window.makeFirstResponder(firstControl) { return }
        window.makeFirstResponder(tabs)
    }
    @objc private func showConnectivityTab() { selectTab(0, firstControl: peer) }
    @objc private func showAudioTab() { selectTab(1, firstControl: codec) }
    @objc private func showProfileTab() { selectTab(2, firstControl: recordingSource) }
    @objc private func showMixTab() { selectTab(3, firstControl: mixPeer) }
    @objc private func rememberChanged() {
        profileModalEpoch=UUID()
        guard remember.state == .off else {
            AppRuntime.settings.set(true, forKey: "rememberPassword")
            return
        }
        do {
            try passwordStore.delete()
            AppRuntime.settings.set(false, forKey: "rememberPassword")
            reconnect.state = .off
            AppRuntime.settings.set(false, forKey: "reconnectOnOpen")
            announce("Saved password removed from Mac Keychain. The current session is unchanged.")
        } catch {
            remember.state = .on
            announce("Could not remove saved password. \(error.localizedDescription)")
        }
    }
    @objc private func forgetSavedPassword() {
        profileModalEpoch=UUID()
        do {
            try passwordStore.delete()
            if !running { password.stringValue = "" }
            remember.state = .off
            AppRuntime.settings.set(false, forKey: "rememberPassword")
            reconnect.state = .off
            AppRuntime.settings.set(false, forKey: "reconnectOnOpen")
            announce("Saved password removed from Mac Keychain.")
        } catch { announce("Could not remove saved password. \(error.localizedDescription)") }
    }
    @objc private func reconnectChanged() {
        profileModalEpoch=UUID()
        if reconnect.state == .on && remember.state == .off {
            reconnect.state = .off
            announce("Enable Remember password in Mac Keychain before automatic reconnection.")
            return
        }
        AppRuntime.settings.set(reconnect.state == .on, forKey: "reconnectOnOpen")
        announce(reconnect.state == .on ? "Automatic reconnection enabled for the next launch." : "Automatic reconnection disabled.")
    }
    private func refreshLoginItem() {
        guard AppRuntime.configuration.allowsLoginItem else {
            menuLaunchAtLogin = false
            loginAtStartup.state = .off
            loginAtStartup.isEnabled = false
            return
        }
        let state = SMAppService.mainApp.status
        menuLaunchAtLogin = state == .enabled || state == .requiresApproval
        loginAtStartup.state = menuLaunchAtLogin ? .on : .off
    }
    @objc private func toggleLaunchAtLogin() {
        guard AppRuntime.configuration.allowsLoginItem else { return }
        do {
            if menuLaunchAtLogin { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            refreshLoginItem()
            if SMAppService.mainApp.status == .requiresApproval {
                announce("Launch at Login needs approval in System Settings, General, Login Items.")
            } else {
                announce(menuLaunchAtLogin ? "RemSound will launch at login." : "RemSound will not launch at login.")
            }
        } catch { announce("Could not change Launch at Login. \(error.localizedDescription)") }
    }
    #if DEBUG
    /// Exercises the registered owner callback and real profile paths in an explicit disposable headless run.
    private func headlessPeerMoveCheckFailures() -> [String] {
        var failures: [String] = []
        var assertions = 0
        func check(_ result: Bool, _ message: String) {
            assertions += 1
            if !result { failures.append(message) }
        }
        guard !running, !window.isVisible, activeProfile == nil,
            (try? profileStore.list().isEmpty) == true else {
            return ["Peer-move fixture requires a stopped hidden app with no existing profile."]
        }
        guard let moved = session.onDirectPeerMove else {
            return ["Peer-move owner callback is not registered."]
        }
        let old = "isolated-move-source", fresh = "isolated-move-fresh", explicit = "isolated-move-explicit"
        var sourceMix = PeerMix(volume: 37, pan: -19)
        sourceMix.eq.simpleDb = [3, -2, 1]
        let explicitMix = PeerMix(enabled: false, volume: 81, pan: 13)
        let bookBefore = AppRuntime.settings.dictionary(forKey: "rememberedPeerBook") as? [String: Any]
        do {
            peerMixes = [old: sourceMix, explicit: explicitMix]
            peerAliases = [old: "Fixture source", explicit: "Explicit destination"]
            AppRuntime.settings.set(peerAliases, forKey: "peerAliases")
            AppRuntime.settings.set(try JSONEncoder().encode(peerMixes), forKey: "peerMixes")
            try persistProfileAs("Isolated peer move")
            guard let profile = activeProfile else { return ["Fixture profile save did not create an active profile."] }
            let file = AppRuntime.configuration.profilesDirectory.appendingPathComponent(profile.id.uuidString + ".json")
            let originalBytes = try Data(contentsOf: file)
            check(!hasUnsavedProfileChanges, "Initial saved fixture must be clean.")
            check(try profileStore.load(id: profile.id).peerMixes[old] == sourceMix, "Initial profile must contain source shaping.")
            moved(old, fresh)
            check(peerMixes[fresh] == sourceMix && peerMixes[old] == sourceMix, "Registered callback must carry shaping and retain source.")
            check(peerAliases[fresh] == "Fixture source" && peerAliases[old] == "Fixture source", "Registered callback must carry alias and retain source.")
            let storedMixes = AppRuntime.settings.data(forKey: "peerMixes").flatMap { try? JSONDecoder().decode([String: PeerMix].self, from: $0) }
            check(storedMixes?[fresh] == sourceMix, "Owner must persist moved shaping in settings.")
            check((AppRuntime.settings.dictionary(forKey: "peerAliases") as? [String: String])?[fresh] == "Fixture source", "Owner must persist moved alias in settings.")
            check(hasUnsavedProfileChanges, "Moved settings must mark the saved profile dirty.")
            check(try Data(contentsOf: file) == originalBytes, "Move must not silently overwrite the profile file.")
            moved(old, explicit)
            check(peerMixes[explicit] == explicitMix && peerAliases[explicit] == "Explicit destination", "Move must preserve explicit destination choices.")
            try persistCurrentProfile()
            let loaded = try profileStore.load(id: profile.id)
            check(loaded.peerMixes[fresh] == sourceMix && loaded.peerMixes[old] == sourceMix, "Actual save/load must retain moved and original shaping.")
            check(loaded.peerAliases[fresh] == "Fixture source" && loaded.peerAliases[old] == "Fixture source", "Actual save/load must retain moved and original alias.")
            check(loaded.peerMixes[explicit] == explicitMix && loaded.peerAliases[explicit] == "Explicit destination", "Actual save/load must retain explicit destination choices.")
            check(!hasUnsavedProfileChanges, "Actual profile save must clear dirty state.")
            peerMixes = [:]; peerAliases = [:]
            check(restoreActiveProfile(), "Actual owner must reopen the saved profile.")
            check(peerMixes == loaded.peerMixes && peerAliases == loaded.peerAliases, "Actual profile reopen must restore owner shaping and aliases.")
            check(!hasUnsavedProfileChanges, "Reopened profile must remain clean.")
            let savedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
            check(savedJSON?["rememberedPeerBook"] == nil, "Profile file must not contain machine-wide remembered history.")
            let bookAfter = AppRuntime.settings.dictionary(forKey: "rememberedPeerBook") as? [String: Any]
            check(NSDictionary(dictionary: bookBefore ?? [:]).isEqual(to: bookAfter ?? [:]), "Move/save/reopen must preserve machine-wide remembered history.")
            let stableBytes = try Data(contentsOf: file)
            let keyBefore = AppRuntime.settings.object(forKey: "pushToTalkHotkey") as? String
            var ptt = PushToTalkSettings()
            ptt.enabled = true; ptt.capturePath = .systemAudio; ptt.trigger = .level
            ptt.holdToSpeak = false; ptt.doubleTapSpeed = .fast; ptt.levelDb = -55
            ptt.bypassForRecording = true; ptt.bypassForPlugin = true
            pushToTalkSettings = ptt
            saveAudioOptions()
            check(try PushToTalkPreferences.load(from: AppRuntime.settings) == ptt, "Owner must persist current PTT choices.")
            check(hasUnsavedProfileChanges, "PTT changes must mark the active profile dirty.")
            check(try Data(contentsOf: file) == stableBytes, "PTT edit must not silently overwrite the profile.")
            try persistCurrentProfile()
            let pttSaved = try profileStore.load(id: profile.id)
            check(pttSaved.pushToTalk == ptt, "Actual owner snapshot/save/load must preserve PTT choices.")
            check(!hasUnsavedProfileChanges, "PTT profile save must clear dirty state.")
            pushToTalkSettings = .init()
            check(restoreActiveProfile(), "Actual owner must reopen PTT profile.")
            check(pushToTalkSettings == ptt, "Actual profile load must restore owner PTT choices.")
            check(try PushToTalkPreferences.load(from: AppRuntime.settings) == ptt, "Reopen must preserve stored PTT choices.")
            resetToBlankProfile()
            check(pushToTalkSettings == .init(), "New profile must reset PTT to disabled defaults.")
            check(try PushToTalkPreferences.load(from: AppRuntime.settings) == .init(), "New profile must store disabled PTT defaults.")
            check(activeProfile == nil, "Reset must clear active profile.")
            check(profileSnapshot(id: UUID(), title: "Blank PTT", readOnly: false).pushToTalk == .init(), "Blank snapshot must retain PTT defaults.")
            check((AppRuntime.settings.object(forKey: "pushToTalkHotkey") as? String) == keyBefore, "PTT profile actions must not change the machine key.")
            check(try profileStore.load(id: profile.id).pushToTalk == ptt, "Reset must not rewrite the saved PTT profile.")
            showProfile(pttSaved, playSwitchCue: false)
            check(pushToTalkSettings == ptt, "Actual profile switch must restore PTT.")
            check(!hasUnsavedProfileChanges, "PTT reopen after new profile must remain clean.")
            let editorProfileBytes = try Data(contentsOf: file)
            let keyRaw = AppRuntime.settings.object(forKey: PushToTalkKeyPreferences.settingsKey) as? String
            check(pushToTalkKeys.binding == nil && keyRaw == "isolated-machine-key", "Startup must leave an unreadable key unset and preserve its original bytes.")
            check(pushToTalkHotkey.descriptor == nil, "Startup row must show unreadable book as unset without inventing a default.")
            let beforeCancel = try Data(contentsOf: AppRuntime.configuration.root!.appendingPathComponent("settings.plist"))
            let cancelled = makePushToTalkSettingsWindow()
            cancelled.enable.state = .off; cancelled.controlsChanged(cancelled.enable)
            cancelled.cancel.performClick(nil)
            check(pushToTalkWindow == nil, "Actual root Cancel must release its working window.")
            check(pushToTalkSettings == ptt && pushToTalkKeys.binding == nil, "Actual Cancel must leave owner choices unchanged.")
            check(try Data(contentsOf: AppRuntime.configuration.root!.appendingPathComponent("settings.plist")) == beforeCancel, "Actual Cancel must not write settings.")
            var requested = ptt; requested.levelDb = -61; requested.trigger = .key
            check(commitPushToTalk(.init(settings: requested, binding: nil)) == nil, "Actual root must commit profile choices with an unedited unreadable key.")
            check((AppRuntime.settings.object(forKey: PushToTalkKeyPreferences.settingsKey) as? String) == keyRaw, "Unedited machine book must remain exact.")
            check(pushToTalkKeys.binding == nil && hasUnsavedProfileChanges, "An unedited key stays unset while profile choices become dirty.")
            let key = HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_A), modifiers: [])
            let accepted = makePushToTalkSettingsWindow()
            accepted.key.descriptor = key; accepted.hotkeyCaptureFieldDidChange(accepted.key)
            accepted.ok.performClick(nil)
            check(pushToTalkWindow == nil, "Actual root OK success must close, rather than report a closing error.")
            check(pushToTalkSettings == requested && pushToTalkKeys.binding == key, "Actual OK must install the prepared in-memory choices after saving.")
            check(try PushToTalkPreferences.load(from: AppRuntime.settings) == requested, "Actual root profile choices must reopen.")
            check(try PushToTalkKeyPreferences.load(from: AppRuntime.settings) == key, "Actual root explicit key must reopen in the machine book.")
            check(!pushToTalkKeys.isArmed, "Stopped isolated root must not arm global key input.")
            check(try Data(contentsOf: file) == editorProfileBytes, "Actual editor OK must not overwrite the saved profile file.")
            let settingsFile = AppRuntime.configuration.root!.appendingPathComponent("settings.plist")
            let beforeFailure = try Data(contentsOf: settingsFile)
            var failedChoice = requested; failedChoice.levelDb = -25
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: AppRuntime.configuration.root!.path)
            let failedCommit = commitPushToTalk(.init(settings: failedChoice, binding: nil, keyWasEdited: true))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: AppRuntime.configuration.root!.path)
            check(failedCommit != nil, "Actual root failed coherent storage must report failure.")
            check(pushToTalkSettings == requested && pushToTalkKeys.binding == key, "Failed root write must preserve owner settings and binding.")
            check(try Data(contentsOf: settingsFile) == beforeFailure, "Failed root write must preserve exact prior file.")
            check(try PushToTalkPreferences.load(from: AppRuntime.settings) == requested && PushToTalkKeyPreferences.load(from: AppRuntime.settings) == key, "Failed root write must preserve both cached choices.")
            let oldGeneral = hotkeyBindings
            let conflict = HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_A), modifiers: [.control, .shift])
            hotkeyBindings[.showOrHide] = conflict
            check(commitPushToTalk(.init(settings: failedChoice, binding: conflict, keyWasEdited: true)) != nil, "Actual root must refuse a general shortcut conflict before writes.")
            hotkeyBindings = oldGeneral
            check(try Data(contentsOf: settingsFile) == beforeFailure && pushToTalkKeys.binding == key, "Conflict refusal must preserve storage and current binding.")
            let invalid = HotkeyDescriptor(keyCode: UInt32(kVK_Return), modifiers: [])
            check(commitPushToTalk(.init(settings: failedChoice, binding: invalid, keyWasEdited: true)) != nil, "Actual root must refuse an invalid key before writes.")
            check(try Data(contentsOf: settingsFile) == beforeFailure, "Invalid key must not partially write profile choices.")
            // Clear is explicit even if a future unreadable display also appears unset.
            check(commitPushToTalk(.init(settings: requested, binding: nil, keyWasEdited: true)) == nil, "Actual root explicit clear must commit.")
            check(try pushToTalkKeys.binding == nil && PushToTalkKeyPreferences.load(from: AppRuntime.settings) == nil, "Explicit clear must remove the active key without inventing a default.")
            check(AppRuntime.settings.data(forKey: PushToTalkKeyPreferences.settingsKey) != nil, "Explicit clear must retain a valid versioned machine book.")
            check(commitPushToTalk(.init(settings: requested, binding: key, keyWasEdited: true)) == nil, "Actual root must restore an explicitly selected machine key.")
            try persistCurrentProfile()
            let operational = try profileStore.load(id: profile.id)
            check(operational.pushToTalk == requested && !hasUnsavedProfileChanges, "Actual operational profile save must reopen its PTT choices and clear dirty state.")
            let machineBytes = AppRuntime.settings.data(forKey: PushToTalkKeyPreferences.settingsKey)
            resetToBlankProfile()
            check(pushToTalkSettings == .init() && pushToTalkKeys.binding == key, "Actual New profile resets profile PTT while retaining machine binding.")
            check(AppRuntime.settings.data(forKey: PushToTalkKeyPreferences.settingsKey) == machineBytes, "New profile must preserve the exact machine book.")
            showProfile(operational, playSwitchCue: false)
            check(pushToTalkSettings == requested && pushToTalkKeys.binding == key, "Actual profile reopen must preserve independent machine binding.")
            check(AppRuntime.settings.data(forKey: PushToTalkKeyPreferences.settingsKey) == machineBytes, "Profile reopen must not rewrite the machine book.")
            let profileJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
            check(profileJSON?[PushToTalkKeyPreferences.settingsKey] == nil, "Actual profile file must exclude the machine book.")
            check(pushToTalkWindow == nil && !pushToTalkKeys.isArmed, "Fixture must release its editor and leave key ownership unarmed.")
            // The existing opt-in guard requires a stopped, hidden isolated root. Never register actual input.
            pushToTalkInput?.shutdown(); pushToTalkInput = nil
            let backend = PushToTalkOwnerFixtureBackend()
            configurePushToTalkInput(backend: backend, permitted: true)
            guard let input = pushToTalkInput else { return ["Actual input owner was not created."] }
            defer {
                input.shutdown(); pushToTalkInput = nil
                pushToTalkKeys.replaceBinding(key)
                configurePushToTalkInput()
            }
            let epoch = UUID(), request = input.beginRequest(settings: requested)
            input.observe(settings: requested, running: true, generation: epoch)
            check(!input.isRegistered && backend.calls == 0, "Actual root owner cannot arm from a matching view alone.")
            input.acknowledge(request, receipt: .init(settings: requested, running: true, generation: epoch))
            check(input.isRegistered && backend.calls == 1, "Actual root injected backend must arm after the current request receipt.")
            guard let first = backend.attempts.first else { return ["Fake root registration did not complete."] }
            let press = PushToTalkNativeKeyEvent(keyCode: key.keyCode, modifiers: key.modifiers, down: true, isRepeat: false, milliseconds: 100)
            let release = PushToTalkNativeKeyEvent(keyCode: key.keyCode, modifiers: key.modifiers, down: false, isRepeat: false, milliseconds: 110)
            let secondPress = PushToTalkNativeKeyEvent(keyCode: key.keyCode, modifiers: key.modifiers, down: true, isRepeat: false, milliseconds: 200)
            check(first.receive(press) && first.receive(release) && first.receive(secondPress) && pushToTalkKeys.talking,
                "Actual root Double-only profile needs two distinct presses to latch talking.")
            let rootBeforeFailure = try Data(contentsOf: settingsFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: AppRuntime.configuration.root!.path)
            let failedLiveCommit = commitPushToTalk(.init(settings: failedChoice, binding: nil, keyWasEdited: true))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: AppRuntime.configuration.root!.path)
            check(failedLiveCommit != nil && input.isRegistered && pushToTalkKeys.talking, "Actual root failed write must preserve the prior working fake registration and held state.")
            check(try pushToTalkKeys.binding == key && Data(contentsOf: settingsFile) == rootBeforeFailure, "Failed root write must preserve binding and exact bytes.")
            let oldRequest = input.beginRequest(settings: requested), newest = input.beginRequest(settings: requested), nextEpoch = UUID()
            check(!input.isRegistered && !pushToTalkKeys.talking && first.token.stops == 1, "Pending root changes must immediately retire talking and the exact token.")
            check(!first.receive(press), "Root's old native callback must be fenced before worker acknowledgment.")
            input.observe(settings: requested, running: true, generation: nextEpoch)
            input.acknowledge(oldRequest, receipt: .init(settings: requested, running: true, generation: nextEpoch))
            check(!input.isRegistered && backend.calls == 1, "Root must ignore an obsolete request receipt even for matching settings/epoch.")
            input.acknowledge(newest, receipt: .init(settings: requested, running: true, generation: nextEpoch))
            check(input.isRegistered && backend.calls == 2, "Root must arm only the latest accepted request.")
            let editor = makePushToTalkSettingsWindow()
            check(!input.isRegistered && backend.attempts.last?.token.stops == 1, "Actual root editor must pause native ownership immediately.")
            editor.cancel.performClick(nil)
            check(input.isRegistered && pushToTalkWindow == nil && backend.calls == 3, "Actual editor Cancel restores the existing accepted owner and releases its window.")
            input.setCapture(editorOpen: false, fieldFocused: true, windowKey: true)
            check(!input.isRegistered, "Actual owned listener pauses for a focused key field in the key window.")
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: preferencesWindow)
            check(input.isRegistered, "Actual preferences close observer must release capture pause.")
            input.setPermitted(false)
            check(!input.isRegistered, "Actual permission retirement stops the fake native token.")
            backend.failNext = true; input.setPermitted(true)
            check(!input.isRegistered && input.failure != nil, "Actual native failure must remain unarmed and be reported truthfully.")
            let failedCalls = backend.calls
            for _ in 0..<3 { input.observe(settings: requested, running: true, generation: nextEpoch) }
            check(backend.calls == failedCalls, "Actual root view updates must not retry failed native registration.")
            input.retry()
            check(input.isRegistered && backend.calls == failedCalls + 1, "Actual explicit retry may restore the listener.")
            suspendPushToTalkForProfileChange()
            check(!input.isRegistered && !pushToTalkKeys.talking, "Actual profile retirement must stop native ownership before source changes.")
            let stale = input.beginRequest(settings: requested)
            stopSession()
            input.acknowledge(stale, receipt: .init(settings: requested, running: true, generation: UUID()))
            check(!input.isRegistered && !input.isCurrent(stale), "Actual Stop must cancel queued native request completions.")
            let submitted = UUID(), superseded = input.beginRequest(settings: requested)
            pushToTalkSubmittedStartRequest = submitted
            input.invalidate()
            completePushToTalkStart(UUID(), keyRequest: superseded,
                receipt: .init(settings: requested, running: true, generation: UUID()))
            check(pushToTalkSubmittedStartRequest == submitted && !input.isRegistered,
                "Obsolete submitted-start completion must not acknowledge or retry current choices.")
            // Core remains stopped. A mocked running view exercises the root's update submission, whose stopped worker replies nil.
            running = true
            completePushToTalkStart(submitted, keyRequest: superseded,
                receipt: .init(settings: requested, running: true, generation: UUID()))
            running = false
            check(pushToTalkSubmittedStartRequest == nil && !input.isRegistered,
                "Latest start with edited choices must submit a new options request and stay unarmed until its receipt.")
            check(!input.isCurrent(superseded), "Edited startup choices must not reuse the superseded key request.")
            stopSession()
            check(pushToTalkHotkey.captureMode == .pushToTalk, "Machine key row must allow PTT single-key capture.")
            check(pushToTalkHotkey.accessibilityLabel() == "Push to talk machine shortcut key", "Machine key row must expose its own useful name.")
            check(pushToTalkHotkey.accessibilityHelp()?.contains("Audio I/O") == true, "Machine key row help must locate profile choices.")
            check(generalPreferencesOrder.last === pushToTalkHotkey && quickProfileHotkey.nextKeyView === pushToTalkHotkey, "Machine key row must follow existing shortcuts in the native tab order.")
            check(pushToTalkHotkey.hotkeyDelegate === self && pushToTalkHotkey.onCaptureFocusChanged != nil, "Actual row must use root commit and capture pause callbacks.")
            let rowKey = HotkeyDescriptor(keyCode: 11, modifiers: [])
            let profileBeforeRow = try Data(contentsOf: file)
            let malformedProfile = Data("unreadable profile choices".utf8)
            AppRuntime.settings.set(malformedProfile, forKey: "pushToTalk")
            pushToTalkSettingsUnreadable = true
            pushToTalkHotkey.descriptor = rowKey; hotkeyCaptureFieldDidChange(pushToTalkHotkey)
            check(try PushToTalkKeyPreferences.load(from: AppRuntime.settings) == rowKey && pushToTalkKeys.binding == rowKey, "Actual row must commit one machine key to storage and runtime.")
            check(AppRuntime.settings.data(forKey: "pushToTalk") == malformedProfile && pushToTalkSettingsUnreadable, "Machine-only edit must preserve unreadable profile preferences.")
            check(try Data(contentsOf: file) == profileBeforeRow && !hasUnsavedProfileChanges, "Machine key row must leave saved profile bytes and dirty state unchanged.")
            check(!input.isRegistered, "Machine row edit must remain unarmed until a new worker receipt.")
            let rowEpoch = UUID(), rowRequest = input.beginRequest(settings: requested)
            input.observe(settings: requested, running: true, generation: rowEpoch)
            backend.failNext = true
            input.acknowledge(rowRequest, receipt: .init(settings: requested, running: true, generation: rowEpoch))
            check(try !input.isRegistered && input.failure != nil && pushToTalkKeys.binding == rowKey && PushToTalkKeyPreferences.load(from: AppRuntime.settings) == rowKey, "Native activation failure must report inactive input while retaining the same saved/runtime choice.")
            check(pushToTalkKeyStatus.stringValue.contains("inactive"), "Deferred native failure must update the actual row's result text.")
            let rowFailedCalls = backend.calls
            input.observe(settings: requested, running: true, generation: rowEpoch)
            check(backend.calls == rowFailedCalls, "Row activation failure must not retry on a view tick.")
            input.retry()
            check(input.isRegistered, "An explicit retry may activate the saved machine key.")
            pushToTalkHotkey.onCaptureFocusChanged?(true)
            refreshPushToTalkCaptureState(windowKey: true)
            check(!input.isRegistered && pushToTalkCaptureFields.contains(ObjectIdentifier(pushToTalkHotkey)), "Actual row capture callback must retire native input without losing its capture identity.")
            pushToTalkHotkey.onCaptureFocusChanged?(false)
            refreshPushToTalkCaptureState(windowKey: false)
            check(input.isRegistered && !pushToTalkCaptureFields.contains(ObjectIdentifier(pushToTalkHotkey)), "Actual row release must restore accepted input and remove capture identity.")
            guard let rowAttempt = backend.attempts.last else { return ["Row fixture fake registration missing."] }
            let rowBeforeFailure = try Data(contentsOf: settingsFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: AppRuntime.configuration.root!.path)
            pushToTalkHotkey.descriptor = nil; hotkeyCaptureFieldDidChange(pushToTalkHotkey)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: AppRuntime.configuration.root!.path)
            check(try Data(contentsOf: settingsFile) == rowBeforeFailure && pushToTalkKeys.binding == rowKey && pushToTalkHotkey.descriptor == rowKey, "Failed row save must restore display and preserve exact stored/runtime key.")
            check(input.isRegistered && rowAttempt.token.stops == 0, "Failed row storage must preserve the accepted native owner.")
            check(pushToTalkKeyStatus.stringValue.contains("could not be saved"), "Row persistence error must remain available as text.")
            let reserved = HotkeyDescriptor(keyCode: 10, modifiers: [.control, .option])
            hotkeyBindings[.showOrHide] = reserved
            pushToTalkHotkey.descriptor = reserved.layoutFallbacks.first ?? reserved
            hotkeyCaptureFieldDidChange(pushToTalkHotkey)
            check(try Data(contentsOf: settingsFile) == rowBeforeFailure && pushToTalkHotkey.descriptor == rowKey && pushToTalkKeys.binding == rowKey, "Layout-alias conflict must reject before storage or runtime changes.")
            hotkeyBindings.removeValue(forKey: .showOrHide)
            let obsoleteRowRequest = input.beginRequest(settings: requested)
            pushToTalkHotkey.descriptor = nil; hotkeyCaptureFieldDidChange(pushToTalkHotkey)
            check(try PushToTalkKeyPreferences.load(from: AppRuntime.settings) == nil && pushToTalkKeys.binding == nil && pushToTalkHotkey.descriptor == nil, "Explicit row clear must persist unset without a default.")
            input.acknowledge(obsoleteRowRequest, receipt: .init(settings: requested, running: true, generation: rowEpoch))
            check(!input.isRegistered && !input.isCurrent(obsoleteRowRequest) && !rowAttempt.receive(press), "Accepted machine edit must retire obsolete requests and native callbacks.")
            pushToTalkHotkey.descriptor = key; hotkeyCaptureFieldDidChange(pushToTalkHotkey)
            check(try PushToTalkKeyPreferences.load(from: AppRuntime.settings) == key && pushToTalkKeys.binding == key, "Row must restore the original fixture machine key.")
            pushToTalkSettingsUnreadable = false
            try PushToTalkPreferences.save(requested, to: AppRuntime.settings)
            var cueEvents = [String]()
            let originalPTTCue = playPushToTalkCue
            playPushToTalkCue = { cueEvents.append($0.rawValue) }
            defer { playPushToTalkCue = originalPTTCue }
            var holdSettings = requested; holdSettings.holdToSpeak = true; holdSettings.doubleTapToHold = false
            let cueEpoch = UUID(), cueRequest = input.beginRequest(settings: holdSettings)
            input.observe(settings: holdSettings, running: true, generation: cueEpoch)
            input.acknowledge(cueRequest, receipt: .init(settings: holdSettings, running: true, generation: cueEpoch))
            guard let cueAttempt = backend.attempts.last else { return ["Cue fixture fake registration missing."] }
            let cueDown = PushToTalkNativeKeyEvent(keyCode: key.keyCode, modifiers: key.modifiers, down: true, isRepeat: false, milliseconds: 2000)
            let cueUp = PushToTalkNativeKeyEvent(keyCode: key.keyCode, modifiers: key.modifiers, down: false, isRepeat: false, milliseconds: 2020)
            check(cueAttempt.receive(cueDown) && cueAttempt.receive(cueDown) && cueAttempt.receive(cueUp), "Actual key owner must exercise a real Hold transition pair and repeated down.")
            check(cueEvents == ["pushToTalkOn", "pushToTalkOff"], "Actual App key transition caller must request profile on/off cues exactly once.")
            _ = cueAttempt.receive(cueDown); input.invalidate()
            check(cueEvents == ["pushToTalkOn", "pushToTalkOff", "pushToTalkOn"], "Request retirement must remain silent, with no synthetic off cue.")
            var disabledPTT = requested; disabledPTT.enabled = false
            check(commitPushToTalk(.init(settings: disabledPTT, binding: key)) == nil && pushToTalkButton.title.contains("currently disabled"), "Actual editor commit must expose disabled state through the native button.")
            showProfile(operational, playSwitchCue: false)
            check(pushToTalkButton.title.contains("currently enabled") && pushToTalkButton.accessibilityLabel() == pushToTalkButton.title, "Actual profile load must expose enabled state without changing button identity.")
            resetToBlankProfile()
            check(pushToTalkButton.title.contains("currently disabled"), "Actual New profile must expose disabled state.")
            showProfile(operational, playSwitchCue: false)
            check(cueEvents == ["pushToTalkOn", "pushToTalkOff", "pushToTalkOn"], "Profile/enable retirement must not invent key transition cues.")
            var previewOwners = [PushToTalkPreview](), previewOutputs = [PushToTalkPreviewFixtureOutput]()
            var previewRequests = [PushToTalkDoubleTapSpeed]()
            let originalPreviewFactory = makePushToTalkPreview
            makePushToTalkPreview = {
                let owner = PushToTalkPreview(isAllowed: { !CueSounds.shared.preferences.muteAllCues },
                    prepare: { speed, _, done in previewRequests.append(speed); done(Data(repeating: 0, count: 48)) },
                    makeOutput: { _, _ in let output = PushToTalkPreviewFixtureOutput(); previewOutputs.append(output); return output })
                previewOwners.append(owner); return owner
            }
            defer { makePushToTalkPreview = originalPreviewFactory; pushToTalkWindow?.close() }
            let previewEditor = makePushToTalkSettingsWindow()
            check(previewOwners.count == 1 && previewRequests.isEmpty, "Actual preview owner must be created without previewing on window open.")
            previewEditor.reportPreviewFailure("Previous preview unavailable.")
            previewEditor.speed.selectItem(at: 1); previewEditor.controlsChanged(previewEditor.speed)
            check(previewEditor.status.isHidden, "Actual successful preview must clear its earlier preview error without a focus jump.")
            check(previewRequests == [.medium] && previewOutputs.first?.plays == 1, "Actual native speed action must reach the finite preview owner.")
            previewEditor.trigger.selectItem(at: 1); previewEditor.controlsChanged(previewEditor.trigger)
            previewEditor.controlsChanged(previewEditor.speed)
            check(previewRequests == [.medium], "A disabled speed action must not preview.")
            CueSounds.shared.preferences.setMuteAllCues(true); refreshTypingFeedback()
            check(previewOutputs.allSatisfy { $0.stops == 1 }, "Actual mute refresh must retire preview even before typing feedback starts.")
            CueSounds.shared.preferences.setMuteAllCues(false); refreshTypingFeedback()
            check(previewRequests == [.medium], "Unmuting must not replay an old preview.")
            previewEditor.cancelPressed()
            let previewsAtClose = previewRequests.count
            previewOwners.first?.play(.fast)
            check(pushToTalkPreview == nil && previewRequests.count == previewsAtClose, "Actual Cancel must shut down and release its exact preview owner.")
            let nextPreviewEditor = makePushToTalkSettingsWindow()
            nextPreviewEditor.speed.selectItem(at: 2); nextPreviewEditor.controlsChanged(nextPreviewEditor.speed)
            check(previewOwners.count == 2 && previewOutputs.last?.plays == 1, "Reopening creates a fresh preview owner without reviving the retired one.")
            resetToBlankProfile()
            check(pushToTalkPreview == nil && previewOutputs.allSatisfy { $0.stops == 1 }, "Actual profile change must stop and release every preview resource once.")
            showProfile(operational, playSwitchCue: false)
            let metronomeSavedTab = tabs.selectedTabViewItem, metronomeSavedResponder = window.firstResponder
            tabs.selectTabViewItem(at: 1)
            defer {
                if let metronomeSavedTab { tabs.selectTabViewItem(metronomeSavedTab) }
                window.makeFirstResponder(metronomeSavedResponder)
            }
            check(metronomeVolume.superview != nil && metronomeVolume.cell?.accessibilityRole() == .slider, "Actual metronome volume must be a native control in Audio I/O.")
            check(metronomeVolume.target === self && metronomeVolume.action == #selector(metronomeVolumeChanged), "Actual metronome volume must use its normal owner action.")
            window.makeFirstResponder(pushToTalkButton)
            let metronomeTab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: UInt16(kVK_Tab))!
            let metronomeShiftTab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: UInt16(kVK_Tab))!
            window.sendEvent(metronomeTab)
            check(window.firstResponder === metronomeVolume, "Actual Audio I/O Tab must reach metronome volume after PTT.")
            window.sendEvent(metronomeShiftTab)
            check(hasKeyboardFocus(pushToTalkButton, in: window), "Actual Shift-Tab must return to the same PTT control.")
            window.makeFirstResponder(tabs); window.sendEvent(metronomeShiftTab)
            check(window.firstResponder === metronomeVolume, "Actual reverse section entry must reach the last metronome slider.")
            window.sendEvent(metronomeTab)
            check(hasKeyboardFocus(tabs, in: window), "Actual final Audio I/O Tab must return to the tab strip.")
            check(metronomeVolume.accessibilityHelp()?.contains("Return") == true, "Metronome slider must expose its reset and scope help.")
            check(window.makeFirstResponder(metronomeVolume), "Hidden native metronome slider must accept focus.")
            metronomeVolume.integerValue = 37; metronomeVolume.sendAction(metronomeVolume.action, to: metronomeVolume.target)
            check(jam.volume == 37 && AppRuntime.settings.integer(forKey: JamController.volumeKey) == 37, "Actual continuous action must persist through the existing Jam owner.")
            check(profileSnapshot(id: operational.id, title: operational.title, readOnly: false).metronomeVolume == 37 && hasUnsavedProfileChanges, "Continuous metronome volume must participate in the actual profile snapshot and dirty state.")
            try persistCurrentProfile()
            check(try profileStore.load(id: operational.id).metronomeVolume == 37, "Actual profile file must retain a non-preset volume.")
            jam.setVolume(25)
            check(metronomeVolume.integerValue == 25 && window.firstResponder === metronomeVolume, "Menu preset changes must refresh the same focused slider.")
            check(restoreActiveProfile() && jam.volume == 37 && metronomeVolume.integerValue == 37, "Actual profile reopening must restore the Jam owner and native slider.")
            check(!hasUnsavedProfileChanges, "Reopened metronome volume must not make the profile dirty.")
            for code in [kVK_Return, kVK_ANSI_KeypadEnter] {
                jam.setVolume(37); window.makeFirstResponder(metronomeVolume)
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: code == kVK_Return ? [] : .numericPad,
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: UInt16(code))!
                check(window.performKeyEquivalent(with: event) && jam.volume == 70 && AppRuntime.settings.integer(forKey: JamController.volumeKey) == 70, "Both Enter keys must reset through the real Jam persistence action.")
                check(window.firstResponder === metronomeVolume && metronomeVolume.accessibilityLabel()?.contains("70 percent") == true, "Reset must retain native focus and expose the completed percent.")
            }
            resetToBlankProfile()
            check(jam.volume == 70 && metronomeVolume.integerValue == 70 && profileSnapshot(id: UUID(), title: "Blank", readOnly: false).metronomeVolume == 70, "Actual New profile must restore seventy without affecting the machine key.")
            check(try PushToTalkKeyPreferences.load(from: AppRuntime.settings) == key, "Metronome New profile must retain the separate machine shortcut.")
            check(restoreActiveProfile() == false, "Blank profile must not pretend that the previous profile is still active.")
            showProfile(try profileStore.load(id: operational.id), playSwitchCue: false)
            check(jam.volume == 37 && metronomeVolume.integerValue == 37, "Actual explicit open must restore the saved continuous percent.")
            let metronomeSettingsFile = AppRuntime.configuration.root!.appendingPathComponent("settings.plist")
            let metronomeBackup = metronomeSettingsFile.appendingPathExtension("metronome-backup")
            let fm = FileManager.default
            try fm.moveItem(at: metronomeSettingsFile, to: metronomeBackup)
            try fm.createDirectory(at: metronomeSettingsFile, withIntermediateDirectories: false)
            do {
                defer { try? fm.removeItem(at: metronomeSettingsFile); try? fm.moveItem(at: metronomeBackup, to: metronomeSettingsFile) }
                metronomeVolume.integerValue = 0; metronomeVolume.sendAction(metronomeVolume.action, to: metronomeVolume.target)
                check(jam.volume == 37 && metronomeVolume.integerValue == 37, "Failed metronome storage must roll back displayed and runtime volume.")
                check(AppRuntime.settings.integer(forKey: JamController.volumeKey) == 37 && !hasUnsavedProfileChanges, "Failed metronome storage must preserve cached settings and clean profile.")
                let failedVolumeRequest = ControlRequest(action: "metronome-volume", arguments: ["value": "70"])
                check(performControlCommand(try ControlCommand(failedVolumeRequest), request: failedVolumeRequest).status == .error && jam.volume == 37, "CLI preset storage failure must return an error and retain the accepted volume.")
            }
            let continuousCLIRequest = ControlRequest(action: "metronome-volume", arguments: ["value": "37"])
            check(performControlCommand(try ControlCommand(continuousCLIRequest), request: continuousCLIRequest).status == .error && jam.volume == 37, "Existing CLI must still reject non-advertised menu presets.")
            let presetCLIRequest = ControlRequest(action: "metronome-volume", arguments: ["value": "50"])
            check(performControlCommand(try ControlCommand(presetCLIRequest), request: presetCLIRequest).status == .ok && jam.volume == 50 && metronomeVolume.integerValue == 50, "Existing CLI presets must update the same native owner.")
            jam.setVolume(Int.min)
            check(jam.volume == 0 && metronomeVolume.integerValue == 0, "Jam owner must clamp the lower integer extreme without changing preset contracts.")
            jam.setVolume(Int.max)
            check(jam.volume == 100 && metronomeVolume.integerValue == 100, "Jam owner must clamp the upper integer extreme without changing preset contracts.")
            showProfile(try profileStore.load(id: operational.id), playSwitchCue: false)
            let reopenedMetronomeSettings = try SettingsStore(file: metronomeSettingsFile)
            check(reopenedMetronomeSettings.integer(forKey: JamController.volumeKey) == 37, "Restored settings file must retain the exact accepted percent.")
            check(!window.isVisible && !running, "Metronome root checks must remain stopped and hidden.")
            input.shutdown(); input.shutdown()
            check(backend.attempts.allSatisfy { $0.token.stops == 1 }, "Actual owner shutdown must retire each exact fake token once.")
            check(!running && !window.isVisible && pushToTalkWindow == nil, "Root fixture must remain stopped/hidden without a working editor.")
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Saved fixture profile must remain owner-only.")
            let previousJamView = jam.view
            let rememberedServersBefore = AppRuntime.settings.object(forKey: JamController.rememberedServersKey)
            let deliverServerView = session.onJamChange
            check(deliverServerView != nil, "Actual root must attach the Session server view callback.")
            let firstDetails = "On isolated.example, connected for less than a minute.\nYour round trip to the server: 21 ms."
            let secondDetails = "On isolated.example, connected for less than a minute.\nYour round trip to the server: 43 ms."
            func fixtureServerView(_ details: String) -> JamView {
                JamView(connected: true, server: "isolated.example", serverStatus: "On isolated.example with 0 others.",
                    metronomeRole: .solo, metronomePlaying: false, metronomeLine: "stopped", metronomeBpm: 120,
                    whenAsked: .ask, serverDetails: details)
            }
            deliverServerView?(fixtureServerView(firstDetails))
            check(jam.serverAccessibilityFailures(expectedDetails: firstDetails).isEmpty,
                "Actual root callback must supply native multiline status and both directions of the Server window's tab order.")
            deliverServerView?(fixtureServerView(secondDetails))
            check(jam.serverAccessibilityFailures(expectedDetails: secondDetails).isEmpty,
                "A closed Server window must reopen on new telemetry without a short-status or menu change.")
            deliverServerView?(previousJamView)
            AppRuntime.settings.set(rememberedServersBefore, forKey: JamController.rememberedServersKey)
            check(jam.view.server == previousJamView.server && jam.view.connected == previousJamView.connected,
                "Stopped owner status fixture must retire its synthetic connection.")
            check(jam.serverVersionOwnerFailures(session).isEmpty,
                "Actual stopped owner must register isolated lookup/warning, refuse stale replies and route remembered server Return.")
            check(!running && !window.isVisible && !jam.view.connected && controlView?.recording != true,
                "Fixture must remain stopped, hidden and without server or recording.")
        } catch { failures.append("Peer-move fixture could not complete isolated persistence.") }
        print("Headless peer-move owner assertions: \(assertions).")
        return failures
    }
    #endif
    private func directPeerMoved(from old: String, to new: String) {
        PeerProfileMove.apply(from: old, to: new, mixes: &peerMixes, aliases: &peerAliases,
                              settings: AppRuntime.settings)
        updatePeerMixControls()
    }

    private func profileSnapshot(id: UUID, title: String, readOnly: Bool) -> ConnectionProfile {
        ConnectionProfile(
            id: id, title: title, displayName: name.stringValue,
            manualPeerAddress: peer.stringValue,
            selectedPeerAddresses: AppRuntime.settings.stringArray(forKey: "selectedPeerAddresses") ?? [],
            lockPeerAddresses: AppRuntime.settings.bool(forKey: "lockPeerAddresses"),
            sendInput: send.state == .on, receiveAudio: receive.state == .on,
            sendSystemAudio: systemAudio.state == .on,
            allowPlugins: plugins.state == .on, reconnectOnOpen: reconnect.state == .on,
            monitorInApp: monitor.state == .on,
            inputDeviceUIDs: selectedInputUIDs,
            inputChannelPairs: selectedInputChannelPairs,
            outputDeviceUIDs: selectedOutputUIDs,
            outputChannelPairs: selectedOutputChannelPairs,
            systemCaptureDeviceUIDs: selectedCaptureUIDs,
            systemCaptureChannelPairs: selectedCaptureChannelPairs,
            sendCodec: selectedSendCodec(), sendPacketSize: selectedSendPacketSize(),
            receiveJitterMs: selectedReceiveJitterMs(), receiveSmoothness: selectedReceiveSmoothness(),
            receiveArtifact: selectedReceiveArtifact(),
            receiveAutoTune: receiveAutoTune.state == .on,
            receiveAutoTuneInterval: selectedAutoTuneInterval(),
            recordingSource: selectedRecordingSource(),
            recordingFormat: selectedRecordingFormat(),
            recordingChannels: selectedRecordingChannels(),
            splitRecording: splitRecording.state == .on,
            recordingBypassShaping: recordingBypassShaping.state == .on,
            flacCompression: selectedFLACCompression(),
            recordingsDirectory: AppRuntime.settings.string(forKey: "recordingsDirectory") ?? "",
            peerMixes: peerMixes,
            peerAliases: peerAliases,
            listeningVolume: listeningVolume.integerValue, receiveMuted: receiveMute.state == .on,
            acceptRemoteVolumeCommands: acceptRemoteVolume.state == .on,
            enableAllPeerShaping: allPeerShaping.state == .on,
            systemAudioFromApplications: sendingApplications, systemAudioApplications: chosenApplications,
            readOnly: readOnly, audioCues: CueSounds.shared.preferences.profileConfigurations,
            keyboardClicks: CueSounds.shared.preferences.keyboardClicksEnabled, pushToTalk: pushToTalkSettings,
            browserListenerEnabled: browserOptions.enabled, browserListenerAutoStart: browserOptions.autoStart,
            metronomeVolume: jam.volume, enableLogs: profileLoggingChoice,
            server: serverForProfile.server, serverConnectOnStart: serverForProfile.connectOnStart, metronome: jam.choices,
            receiveLowestDelay: receiveLowestDelay.state == .on)
    }
    /// The server a saved profile keeps (Windows GatherRelayProfile): the one we are on or connecting to, or the profile's
    /// own still being looked for - both connect at start. Running and on none: the person left it. Not running: as it was.
    private var serverForProfile: (server: String, connectOnStart: Bool) {
        let kept = activeProfile?.server ?? ""
        guard running else { return (kept, activeProfile?.serverConnectOnStart == true && !kept.isEmpty) }
        if !jam.view.server.isEmpty { return (jam.view.server, true) }
        if let pending = jam.view.pendingServer { return (pending, true) }
        return (kept, false)
    }
    private func refreshProfileNotice() {
        let text: String
        if let activeProfile {
            text = activeProfile.readOnly
                ? "Current profile: \(activeProfile.title), read only. Device and audio changes are temporary; use Save Profile As to keep them."
                : "Current profile: \(activeProfile.title). Command-S saves changes."
        } else {
            text = "No saved profile is active. Use Save Profile As to keep this setup."
        }
        if profileNotice.stringValue != text { profileNotice.stringValue = text }
    }
    @discardableResult private func showProfile(_ profile: ConnectionProfile, reconnectAfterLoad: Bool = false,
        playSwitchCue: Bool = true, loadPassword: Bool = true,browserContextAlreadyRetired:Bool=false)->Bool {
        guard browserProfileRemoval == nil else {browserProfileRemoval?.cancel();announce("Wait for profile deletion to finish.");return false}
        guard applyProfileLogging(profile.enableLogs) else { return false }
        suspendPushToTalkForProfileChange(browserContextAlreadyRetired:browserContextAlreadyRetired)
        CueSounds.shared.preferences.loadProfile(profile.audioCues, schemaVersion: profile.audioCueSchemaVersion,
            keyboardClicks: profile.keyboardClicks)
        refreshTypingFeedback()
        if playSwitchCue { CueSounds.shared.play(.profileSwitch) }
        var normalizedProfile = profile
        normalizedProfile.audioCues = CueSounds.shared.preferences.profileConfigurations
        normalizedProfile.audioCueSchemaVersion = CuePreferences.schemaVersion
        normalizedProfile.keyboardClicks = CueSounds.shared.preferences.keyboardClicksEnabled
        // A profile saved before it kept the metronome's settings starts from this Mac's old ones, and is not "changed".
        jam.loadProfileMetronome(profile.metronome)
        normalizedProfile.metronome = jam.choices
        activeProfile = normalizedProfile
        browserOptions = .init(enabled: profile.browserListenerEnabled, autoStart: profile.browserListenerAutoStart)
        jam.setVolume(profile.metronomeVolume)
        pushToTalkSettings = profile.pushToTalk
        pushToTalkSettingsUnreadable = false
        refreshPushToTalkPresentation()
        CueSounds.shared.profileOpened()
        cueCustomFiles = [:]
        refreshCueChoices()
        resumeInputSendingWhenSelected = false
        resumeSystemSendingWhenSelected = false
        hotkeyResumeInput = false
        hotkeyResumeSystem = false
        passwordStore = AppRuntime.passwordStore(account: profile.id.uuidString)
        name.stringValue = profile.displayName
        peer.stringValue = profile.manualPeerAddress
        send.state = profile.sendInput ? .on : .off
        systemAudio.state = profile.sendSystemAudio ? .on : .off
        receive.state = profile.receiveAudio ? .on : .off
        monitor.state = profile.monitorInApp ? .on : .off
        populateDeviceChoices(inputUIDs: profile.inputDeviceUIDs,
            inputChannelPairs: profile.inputChannelPairs,
            outputUIDs: profile.outputDeviceUIDs,
            outputChannelPairs: profile.outputChannelPairs,
            systemCaptureUIDs: profile.systemCaptureDeviceUIDs,
            systemCapturePairs: profile.systemCaptureChannelPairs)
        if selectedInputUIDs.isEmpty { send.state = .off }
        if selectedOutputUIDs.isEmpty { monitor.state = .off }
        codec.selectItem(withTitle: profile.sendCodec.label)
        packetSize.selectItem(withTitle: profile.sendPacketSize.label)
        selectReceiveSmoothness(profile.receiveSmoothness)
        selectReceiveArtifact(profile.receiveArtifact)
        receiveJitter.selectItem(withTitle:
            "\(ReceiveBuffer.clamped(profile.receiveJitterMs)) milliseconds")
        receiveAutoTune.state = profile.receiveAutoTune ? .on : .off
        receiveLowestDelay.state = profile.receiveLowestDelay ? .on : .off
        AppRuntime.settings.set(profile.receiveLowestDelay, forKey: "receiveLowestDelay")
        session.setReceiveLowestDelay(profile.receiveLowestDelay)
        receiveAutoTuneInterval.selectItem(withTitle:
            "\(ReceiveBuffer.validAutoTuneInterval(profile.receiveAutoTuneInterval)) seconds")
        refreshReceiveLatencyStatus()
        recordingSource.selectItem(withTitle: profile.recordingSource.label)
        recordingFormat.selectItem(withTitle: profile.recordingFormat.label)
        recordingChannels.selectItem(withTitle: profile.recordingChannels.label)
        splitRecording.state = profile.splitRecording ? .on : .off
        recordingBypassShaping.state = profile.recordingBypassShaping ? .on : .off
        flacCompression.selectItem(at: FLACCompression.clamped(profile.flacCompression))
        flacCompression.isEnabled = profile.recordingFormat.fileExtension == "flac"
        AppRuntime.settings.set(profile.recordingsDirectory, forKey: "recordingsDirectory")
        peerMixes = profile.peerMixes
        peerAliases = profile.peerAliases
        listeningVolume.integerValue = profile.listeningVolume
        receiveMute.state = profile.receiveMuted ? .on : .off
        acceptRemoteVolume.state = profile.acceptRemoteVolumeCommands ? .on : .off
        AppRuntime.settings.set(profile.listeningVolume, forKey: "listeningVolume")
        AppRuntime.settings.set(profile.receiveMuted, forKey: "receiveMuted")
        AppRuntime.settings.set(profile.acceptRemoteVolumeCommands, forKey: "acceptRemoteVolumeCommands")
        session.setListening(volume: profile.listeningVolume, muted: profile.receiveMuted)
        session.setAcceptRemoteCommands(profile.acceptRemoteVolumeCommands)
        allPeerShaping.state = profile.enableAllPeerShaping ? .on : .off
        AppRuntime.settings.set(profile.enableAllPeerShaping, forKey: "enableAllPeerShaping")
        session.setAllPeerShaping(profile.enableAllPeerShaping)
        systemAudioMode.selectItem(at: profile.systemAudioFromApplications ? 1 : 0)
        chosenApplications = profile.systemAudioApplications
        AppRuntime.settings.set(profile.systemAudioFromApplications, forKey: "systemAudioFromApplications")
        AppRuntime.settings.set(chosenApplications, forKey: "systemAudioApplications")
        for id in chosenApplications where rememberedApplications[id] == nil { rememberedApplications[id] = id }
        showSystemAudioMode()
        applyBrowserSafeApplications(profile.systemAudioFromApplications ? chosenApplications : nil)
        AppRuntime.settings.set(peerAliases, forKey: "peerAliases")
        if let data = try? JSONEncoder().encode(peerMixes) {
            AppRuntime.settings.set(data, forKey: "peerMixes")
        }
        updatePeerMixControls()
        plugins.state = profile.allowPlugins ? .on : .off
        reconnect.state = profile.reconnectOnOpen ? .on : .off
        AppRuntime.settings.set(profile.selectedPeerAddresses, forKey: "selectedPeerAddresses")
        AppRuntime.settings.set(profile.lockPeerAddresses, forKey: "lockPeerAddresses")
        connectivityPeers.refresh(entries: rememberedPeerEntries, running: running, locked: profile.lockPeerAddresses)
        AppRuntime.settings.set(profile.id.uuidString, forKey: "activeProfileID")
        AppRuntime.settings.set(profile.reconnectOnOpen, forKey: "reconnectOnOpen")
        saveAudioOptions()
        password.stringValue = ""
        window.title = "RemSound Mac — \(profile.title)\(profile.readOnly ? " (read only)" : "")"
        refreshProfileNotice()
        menuProfileReadOnly = profile.readOnly
        refreshStatusItem()
        recordRecentProfile(profile.id)
        if loadPassword { loadSavedPassword(reconnectAfterLoad:reconnectAfterLoad) }
        if window.isVisible { DispatchQueue.main.async { [weak self] in self?.checkForMissingCues() } }
        return true
    }
    private func loadSavedPassword(reconnectAfterLoad:Bool, completion:(() -> Void)? = nil) {
        let request = startupRequests.begin()
        guard !AppRuntime.configuration.isHeadless, remember.state == .on else {
            recordStartup("Saved-password load skipped for unattended credentials or remembering off.")
            if startupRequests.consume(request), terminationRequest == nil { completion?() }
            return
        }
        recordStartup("Loading saved password from Keychain.")
        let store = passwordStore
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try store.load() }
            DispatchQueue.main.async { [weak self] in
                self?.completeSavedPasswordLoad(result,store:store,request:request,
                    reconnectAfterLoad:reconnectAfterLoad,completion:completion)
            }
        }
    }
    private func completeSavedPasswordLoad(_ result:Result<String?,Error>,store:PasswordStore,request:UUID,
        reconnectAfterLoad:Bool,completion:(() -> Void)? = nil) {
        guard startupRequests.consume(request), terminationRequest == nil,
            passwordStore === store, remember.state == .on else {
            recordStartup("Saved-password load discarded after a request, profile or setting change.")
            return
        }
        switch result {
        case .success(let savedPassword):
            recordStartup("Keychain load completed; item \(savedPassword == nil ? "missing" : "present").")
            guard password.stringValue.isEmpty else { return }
            profileModalEpoch=UUID();password.stringValue = savedPassword ?? ""
            if reconnectAfterLoad && reconnect.state == .on && !password.stringValue.isEmpty { startSession() }
            completion?()
        case .failure(let error):
            recordStartup("Keychain load failed: \(error.localizedDescription)")
            announce("Saved password could not be read from Mac Keychain. \(error.localizedDescription)")
        }
    }
    private var recentProfileIDs: [UUID] {
        (AppRuntime.settings.stringArray(forKey: "recentProfileIDs") ?? [])
            .compactMap(UUID.init(uuidString:))
    }
    private func recordRecentProfile(_ id: UUID) {
        let updated = RecentProfileHistory.opening(id, in: recentProfileIDs)
        AppRuntime.settings.set(updated.map(\.uuidString), forKey: "recentProfileIDs")
        DispatchQueue.main.async { [weak self] in self?.refreshRecentProfileMenus() }
    }
    private func refreshRecentProfileMenus() {
        let profiles = recentProfileIDs.compactMap { try? profileStore.load(id: $0) }
        recentMenuProfiles = profiles.enumerated().map {
            RecentMenuProfile(id: $0.element.id, title: "\($0.offset + 1) \($0.element.title)")
        }
        statusRecentProfilesMenu.removeAllItems()
        if profiles.isEmpty {
            let empty = statusRecentProfilesMenu.addItem(withTitle: "No recent profiles",
                action: nil, keyEquivalent: "")
            empty.isEnabled = false
            FocusedHelpContent.markMenuItem(empty, key: "tray-no-recent-profiles", manual: FocusedHelpContent.bundledManual())
            return
        }
        for (index, profile) in profiles.enumerated() {
            let item = statusRecentProfilesMenu.addItem(
                withTitle: "\(index + 1) \(profile.title)",
                action: #selector(openRecentProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id.uuidString
            FocusedHelpContent.markMenuItem(item, key: "tray-open-recent-profile", manual: FocusedHelpContent.bundledManual())
        }
    }
    @objc private func openRecentProfile(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
            let id = UUID(uuidString: value) else { return }
        switchToRecentProfile(id)
    }
    private var blockingProfileWindow: NSWindow? {
        NSApp.modalWindow ?? NSApp.windows.first {
            $0 !== window && $0.isVisible && $0.canBecomeKey
        }
    }
    private func sealProfileAfterStop() {
        let id=UUID()
        profileStopContext = .init(id:id,revision:browserProfileRevision,source:browserListener.sourceScope,
            passwordEpoch:profileModalEpoch,profile:activeProfile,draft:draftProfileID,
            form:profileSnapshot(id:id,title:activeProfile?.title ?? "",readOnly:activeProfile?.readOnly ?? false),
            profiles:ObjectIdentifier(profileStore),passwordStore:ObjectIdentifier(passwordStore))
    }
    private func cancelProfileAfterStop() {
        profileStopContext=nil;profileStopDispatch=nil;chooseProfileAfterStop=false;recentProfileAfterStop=nil
    }
    private func dispatchProfileAfterStop() {
        guard !running,(chooseProfileAfterStop || recentProfileAfterStop != nil),profileStopDispatch == nil else {return}
        guard let context=profileStopContext else {
            cancelProfileAfterStop();announce("The pending profile choice has no current confirmation. Choose again.");return
        }
        profileStopDispatch=context.id
        // One Stop-owned UI continuation. Native/worker values are expected to
        // change during Stop; profile/source/password identities must not change.
        DispatchQueue.main.async {[weak self] in
            guard let self,profileStopDispatch==context.id else {return}
            let current=terminationRequest == nil && !running && profileStopContext?.id==context.id
                && activeProfile==context.profile && draftProfileID==context.draft
                && browserProfileRevision==context.revision && browserListener.sourceScope==context.source
                && profileModalEpoch==context.passwordEpoch && ObjectIdentifier(profileStore)==context.profiles
                && ObjectIdentifier(passwordStore)==context.passwordStore
                && profileSnapshot(id:context.id,title:activeProfile?.title ?? "",readOnly:activeProfile?.readOnly ?? false)==context.form
            let chooser=chooseProfileAfterStop,target=recentProfileAfterStop
            cancelProfileAfterStop()
            guard current else {announce("The profile context changed while stopping. Choose the profile action again.");return}
            if chooser {openProfile()}
            else if let target {completeRecentProfileSwitch(target)}
        }
    }
    private func completeRecentProfileSwitch(_ profile: ConnectionProfile) {
        defer { finishQuickProfileVisibility() }
        guard (try? profileStore.load(id:profile.id))==profile,prepareProfileMutation(),
              showProfile(profile,reconnectAfterLoad:true,playSwitchCue:false,browserContextAlreadyRetired:true) else {
            announce("The profile could not be opened in the current context. Choose again.");return
        }
        announce("Profile \(profile.title) opened.")
    }
    private func switchToRecentProfile(_ id: UUID) {
        defer { finishQuickProfileVisibility() }
        if activeProfile?.id == id {
            announce("This profile is already open.")
            return
        }
        guard retireBrowserBeforeProfilePrompt() else {return}
        guard recentProfileAfterStop == nil, !chooseProfileAfterStop,
            sessionStartRequest == nil, running || start.isEnabled else {
            announce("Wait for the current connection or profile switch to finish.")
            return
        }
        if let otherWindow = blockingProfileWindow {
            announce("Close the \(otherWindow.title) window first, then switch profile.")
            return
        }
        do {
            let profile = try profileStore.load(id: id)
            guard confirmProfileChange(),(try? profileStore.load(id:id))==profile,clearDiscardedDraftPassword() else {return}
            CueSounds.shared.play(.profileSwitch)
            if running {
                // Resolve the target and any save/cancel choice before stopping live audio.
                recentProfileAfterStop = profile
                pushToTalkInput?.invalidate()
                sessionStartRequest = nil
                pushToTalkSubmittedStartRequest = nil
                routerControls?.invalidate()
                jam.retireServerNotice()
                stopSessionAfterBrowserRetirement();sealProfileAfterStop()
            } else {
                completeRecentProfileSwitch(profile)
            }
        } catch {
            refreshRecentProfileMenus()
            announce("Could not open recent profile. \(error.localizedDescription)")
        }
    }
    private func quickProfileAccessibilityFailures() -> [String] {
        var failures = [String]()
        let first = UUID(), current = UUID(), last = UUID()
        let entries = [QuickProfileEntry(id: first, title: "First profile", isCurrent: false),
            QuickProfileEntry(id: current, title: "Current profile", isCurrent: true),
            QuickProfileEntry(id: last, title: "Last profile", isCurrent: false)]
        let owner = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 280, height: 24))
        field.setAccessibilityLabel("Fixture owner field")
        owner.contentView?.addSubview(field)
        owner.makeKeyAndOrderFront(nil)
        owner.makeFirstResponder(field)
        var opens = 0, choices = [UUID?](), helpRequests = [Bool]()
        func chooser(_ profiles: [QuickProfileEntry] = []) -> QuickProfileSwitchWindowController? {
            QuickProfileSwitchWindowController(profiles: profiles, owner: owner,
                playOpen: { opens += 1 }, contextHelp: { helpRequests.append($0) },
                completed: { choices.append($0) })
        }
        if chooser() != nil || opens != 0 {
            failures.append("An empty quick profile list must not open or play its cue")
        }
        let picker = chooser(entries)!
        func key(_ controller: QuickProfileSwitchWindowController, _ code: UInt16,
            _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil,
                characters: code == UInt16(kVK_Tab) ? "\t" : "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code)!
        }
        picker.present()
        picker.present()
        if opens != 1 || picker.table.numberOfRows != 3 || picker.table.selectedRow != 1
            || picker.window?.firstResponder !== picker.table
            || picker.table.accessibilityLabel() != "Saved profiles"
            || picker.table.accessibilityRole() != .table
            || picker.table.accessibilityHelp()?.contains("Return") != true {
            failures.append("Quick switch must list every profile, mark/focus current and cue once")
        }
        let row = picker.table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTextField
        if row?.stringValue != "Current profile (current)"
            || row?.accessibilityLabel() != "Current profile (current)" {
            failures.append("The current profile must be visible and accessible in its actual row")
        }
        picker.window?.sendEvent(key(picker, UInt16(kVK_Tab)))
        if picker.window?.firstResponder !== picker.closeButton {
            failures.append("Quick switch Tab must reach Close")
        }
        picker.window?.sendEvent(key(picker, UInt16(kVK_Tab), .shift))
        if picker.window?.firstResponder !== picker.table {
            failures.append("Quick switch Shift-Tab must return to the list")
        }
        picker.window?.sendEvent(key(picker, UInt16(kVK_F1)))
        picker.window?.sendEvent(key(picker, UInt16(kVK_F1), .shift))
        if helpRequests != [false, true] {
            failures.append("Quick switch must route its focused help keys without profile changes")
        }
        picker.window?.sendEvent(key(picker, UInt16(kVK_Return)))
        picker.close()
        if choices.count != 1 || choices[0] != nil || field.currentEditor() !== owner.firstResponder {
            failures.append("Choosing current must close once without switching and restore the owner control")
        }
        picker.present()
        picker.table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        picker.window?.sendEvent(key(picker, UInt16(kVK_Escape)))
        if choices.count != 2 || choices[1] != nil || opens != 2 {
            failures.append("Escape must cancel even when another profile is highlighted")
        }
        picker.present()
        picker.window?.sendEvent(key(picker, UInt16(kVK_Return)))
        if choices.count != 3 || choices[2] != last || opens != 3 {
            failures.append("Return must select exactly the highlighted profile UUID")
        }
        picker.present()
        picker.window?.sendEvent(key(picker, UInt16(kVK_ANSI_W), .command))
        if choices.count != 4 || choices[3] != nil {
            failures.append("Command-W must cancel the quick profile window")
        }
        weak var previous: QuickProfileSwitchWindowController?
        for _ in 0..<20 {
            autoreleasepool {
                let repeated = chooser(entries)!
                previous = repeated
                repeated.present()
                repeated.closeButton.performClick(nil)
            }
            if previous != nil {
                failures.append("Closed quick profile controllers must be released during churn")
                break
            }
        }
        if opens != 24 || choices.count != 24 || choices.dropFirst(4).contains(where: { $0 != nil }) {
            failures.append("Quick profile cue/completion must stay balanced over repeated cancel lifetimes")
        }
        owner.close()
        if GlobalHotkeyAction.allCases.map(\.rawValue) != Array(1...12)
            || GlobalHotkeyAction.quickProfileSwitch.settingKey != "quickProfileSwitch"
            || GlobalHotkeyAction.quickProfileSwitch.repeatsWhileHeld
            || quickProfileHotkey.descriptor != nil
            || quickProfileHotkey.accessibilityHelp()?.contains("Escape") != true
            || !generalPreferencesOrder.contains(where: { $0 === quickProfileHotkey }) {
            failures.append("The new global shortcut must be unset, non-repeating and keyboard reachable without renumbering old actions")
        }
        let oldBindings = hotkeyBindings
        if AppRuntime.configuration.allowsGlobalHotkeys {
            failures.append("Quick profile shortcut checks require isolated non-registering configuration")
            return failures
        }
        let shortcut = HotkeyDescriptor(keyCode: UInt32(kVK_F9), modifiers: [.control, .shift])
        quickProfileHotkey.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.control, .shift], timestamp: 0,
            windowNumber: preferencesWindow!.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_F9))!)
        if hotkeyBindings[.quickProfileSwitch] != shortcut
            || hotkeyBindings.filter({ $0.key != .quickProfileSwitch }) != oldBindings {
            failures.append("Quick switch recording must preserve every other shortcut binding")
        }
        quickProfileHotkey.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: preferencesWindow!.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: UInt16(kVK_Delete))!)
        if hotkeyBindings != oldBindings || quickProfileHotkey.descriptor != nil {
            failures.append("Delete must clear only the quick profile shortcut")
        }
        if HotkeyDescriptor(keyCode: UInt32(kVK_F1), modifiers: []).isValid
            || HotkeyDescriptor(keyCode: UInt32(kVK_Tab), modifiers: [.control, .shift]).isValid
            || HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_Q), modifiers: [.command]).isValid {
            failures.append("Quick switch must retain Clipman's function/Tab/system shortcut restrictions")
        }
        failures.append(contentsOf: quickProfileWorkflowFailures())
        return failures
    }

    private func quickProfileWorkflowFailures() -> [String] {
        var failures = [String]()
        guard AppRuntime.configuration.isIsolated else { return ["Quick profile workflows require private configuration"] }
        closeSettingsPlaceholder()
        // The inline fixture runs before SwiftUI's deferred Settings-scene close.
        for placeholder in NSApp.windows where placeholder.title == "RemSound Settings"
            && placeholder !== window && placeholder !== preferencesWindow {
            placeholder.close()
        }
        preferencesWindow?.orderOut(nil)
        window.makeKeyAndOrderFront(nil)
        updateControlAvailability(false)
        let first = profileSnapshot(id: UUID(), title: "Quick fixture first", readOnly: false)
        let second = profileSnapshot(id: UUID(), title: "Quick fixture second", readOnly: false)
        do {
            try profileStore.save(first)
            try profileStore.save(second)
        } catch { return ["Could not create isolated quick profile fixtures"] }
        showProfile(first)
        guard !hasUnsavedProfileChanges else { return ["Quick switch first fixture must start without unsaved changes"] }
        func perform(_ selected: UUID?, cancel: Bool = false, expectedAlert: String? = nil,
            answer: NSApplication.ModalResponse = .alertThirdButtonReturn, global: Bool = false) {
            var observed = false
            let select = Timer(timeInterval: 0.03, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let chooser = self.quickProfileWindow,
                        NSApp.modalWindow === chooser.window else { return }
                    observed = true
                    if let selected, let row = chooser.profiles.firstIndex(where: { $0.id == selected }) {
                        chooser.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    }
                    let code = cancel ? UInt16(kVK_Escape) : UInt16(kVK_Return)
                    chooser.window?.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero,
                        modifierFlags: [], timestamp: 0, windowNumber: chooser.window!.windowNumber,
                        context: nil, characters: "", charactersIgnoringModifiers: "",
                        isARepeat: false, keyCode: code)!)
                }
            }
            let alert = Timer(timeInterval: 0.03, repeats: true) { timer in
                MainActor.assumeIsolated {
                    if let expectedAlert {
                        func labels(in view: NSView) -> [String] {
                            let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
                            return own + view.subviews.flatMap { labels(in: $0) }
                        }
                        let text = NSApp.modalWindow?.contentView.map { labels(in: $0).joined(separator: " ") } ?? ""
                        if text.contains(expectedAlert) {
                            timer.invalidate()
                            NSApp.stopModal(withCode: answer)
                        }
                    }
                }
            }
            let watchdog = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    failures.append("Isolated quick switch did not complete its native modal workflow: expected \(expectedAlert ?? "no warning"), modal \(NSApp.modalWindow?.title ?? "none")")
                    self?.quickProfileWindow?.close()
                    if NSApp.modalWindow != nil { NSApp.abortModal() }
                }
            }
            for timer in [select, alert, watchdog] {
                RunLoop.main.add(timer, forMode: .common)
                RunLoop.main.add(timer, forMode: .modalPanel)
            }
            if global { performGlobalHotkey(.quickProfileSwitch) }
            else { performMenuAction(.quickProfileSwitch) }
            for timer in [select, alert, watchdog] { timer.invalidate() }
            if !observed { failures.append("Quick switch command must open the actual modal all-profile chooser") }
        }
        perform(first.id)
        if activeProfile?.id != first.id { failures.append("Current profile selection must not reload a different setup") }
        perform(second.id, cancel: true)
        if activeProfile?.id != first.id { failures.append("Cancel must preserve the current profile") }
        perform(second.id)
        if activeProfile?.id != second.id || !window.isVisible {
            failures.append("Native quick selection must use the shared recent-profile load path")
        }
        window.orderOut(nil)
        perform(first.id, global: true)
        if activeProfile?.id != first.id || window.isVisible || NSApp.activationPolicy() != .accessory {
            failures.append("A global quick switch must keep the main window in the menu bar")
        }
        window.makeKeyAndOrderFront(nil)
        name.stringValue = "Unsaved quick fixture edit"
        perform(second.id, expectedAlert: "Save changes to Quick fixture first?")
        if activeProfile?.id != first.id || name.stringValue != "Unsaved quick fixture edit" {
            failures.append("Cancelling the writable-profile warning must preserve current unsaved work")
        }
        var locked = first
        locked.readOnly = true
        do { try profileStore.save(locked) } catch { failures.append("Read-only quick fixture save failed") }
        showProfile(locked)
        name.stringValue = "Temporary read-only fixture edit"
        perform(second.id)
        if activeProfile?.id != second.id || (try? profileStore.load(id: locked.id)) != locked {
            failures.append("Quick switch must discard temporary read-only edits without overwriting the profile")
        }
        showPreferences()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let preferencesKeyWindow = NSApp.keyWindow
        let preferencesResponder = preferencesWindow?.firstResponder
        let previous = quickProfileWindow
        performGlobalHotkey(.quickProfileSwitch)
        let beforeBlockedRecent = activeProfile?.id
        switchToRecentProfile(first.id)
        if activeProfile?.id != beforeBlockedRecent || recentProfileAfterStop != nil {
            failures.append("Recent-profile menu choices must also refuse a conflicting Preferences window")
        }
        if quickProfileWindow !== previous || quickProfileWindow?.window?.isVisible == true
            || preferencesWindow?.isVisible != true || preferencesResponder !== preferencesTabs
            || preferencesWindow?.firstResponder !== preferencesResponder
            || NSApp.keyWindow !== preferencesKeyWindow {
            failures.append("Quick switch must refuse while Preferences is open without changing its responder or key window")
        }
        preferencesWindow?.orderOut(nil)
        func waitFor(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(1)
            while !condition() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }
        var automaticFirst = first
        var automaticSecond = second
        automaticFirst.reconnectOnOpen = true
        automaticSecond.reconnectOnOpen = true
        do {
            try profileStore.save(automaticFirst)
            try profileStore.save(automaticSecond)
            try AppRuntime.passwordStore(account: first.id.uuidString).save("isolated first password")
            try AppRuntime.passwordStore(account: second.id.uuidString).save("isolated second password")
        } catch { return failures + ["Isolated reconnect fixtures could not be saved"] }
        remember.state = .on
        showProfile(automaticFirst)
        waitFor { !password.stringValue.isEmpty }
        let beforeStoppedSwitch = accessibilitySessionStartRequests
        perform(second.id)
        waitFor { accessibilitySessionStartRequests > beforeStoppedSwitch }
        if activeProfile?.id != second.id || password.stringValue != "isolated second password"
            || accessibilitySessionStartRequests != beforeStoppedSwitch + 1 {
            failures.append("A stopped quick switch must request one launch-equivalent reconnect with the selected profile password")
        }
        let beforeCurrentSelection = accessibilitySessionStartRequests
        perform(second.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        if accessibilitySessionStartRequests != beforeCurrentSelection {
            failures.append("Choosing the current profile must not reconnect again")
        }
        showProfile(automaticFirst)
        waitFor { password.stringValue == "isolated first password" }
        running = true
        name.stringValue = "Unsaved while running"
        perform(second.id, expectedAlert: "Save changes to Quick fixture first?")
        if activeProfile?.id != first.id || !running || recentProfileAfterStop != nil
            || name.stringValue != "Unsaved while running" {
            failures.append("Cancelling an unsaved running-profile switch must leave its session and edits intact")
        }
        running = false
        showProfile(automaticFirst)
        waitFor { password.stringValue == "isolated first password" }
        let beforeRunningSwitch = accessibilitySessionStartRequests
        running = true
        window.orderOut(nil)
        perform(second.id, global: true)
        waitFor { activeProfile?.id == second.id && accessibilitySessionStartRequests > beforeRunningSwitch }
        if activeProfile?.id != second.id || recentProfileAfterStop != nil
            || accessibilitySessionStartRequests != beforeRunningSwitch + 1
            || window.isVisible || NSApp.activationPolicy() != .accessory {
            failures.append("A running hidden quick switch must stop, restore and request one reconnect without revealing the main window")
        }
        running = false
        automaticFirst.reconnectOnOpen = false
        do { try profileStore.save(automaticFirst) }
        catch { failures.append("Reconnect-off fixture save failed") }
        let beforeDisabledSwitch = accessibilitySessionStartRequests
        perform(first.id, global: true)
        waitFor { password.stringValue == "isolated first password" }
        if activeProfile?.id != first.id || accessibilitySessionStartRequests != beforeDisabledSwitch {
            failures.append("A profile with reconnect off must remain stopped after switching")
        }
        remember.state = .off
        perform(second.id, global: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        if activeProfile?.id != second.id || !password.stringValue.isEmpty
            || accessibilitySessionStartRequests != beforeDisabledSwitch {
            failures.append("A switch without remembered passwords must not reuse the outgoing password or start")
        }
        resetToBlankProfile()
        if selectedSendCodec() != .opusLive || selectedSendPacketSize() != .standard {
            failures.append("New Profile must select live Opus and Standard packets in the actual audio controls")
        }
        return failures
    }

    private func showQuickProfileSwitch() {
        if quickProfileWindow?.window?.isVisible == true {
            quickProfileWindow?.present()
            return
        }
        guard recentProfileAfterStop == nil, !chooseProfileAfterStop else {
            announce("Wait for the current profile switch to finish.")
            return
        }
        if let otherWindow = blockingProfileWindow {
            announce("Close the \(otherWindow.title) window first, then switch profile.")
            return
        }
        do {
            let profiles = try profileStore.list()
            guard !profiles.isEmpty else { announce("No saved profiles yet."); return }
            let wasHidden = NSApp.isHidden || !window.isVisible
            quickProfileReturnsToMenuBar = wasHidden
            if wasHidden {
                window.orderOut(nil)
                NSApp.unhideWithoutActivation()
                _ = NSApp.setActivationPolicy(.accessory)
            }
            var chosenProfile: UUID?
            quickProfileWindow = QuickProfileSwitchWindowController(profiles: profiles.map {
                QuickProfileEntry(id: $0.id, title: $0.title, isCurrent: $0.id == activeProfile?.id)
            }, owner: wasHidden ? nil : window,
                playOpen: { CueSounds.shared.play(.profileMenuOpen) },
                contextHelp: { [weak self] manual in
                    if manual { self?.help() } else { self?.showContextHelp() }
                }, completed: { chosenProfile = $0 })
            NSApp.activate(ignoringOtherApps: true)
            quickProfileWindow?.present()
            if let chooser = quickProfileWindow?.window { NSApp.runModal(for: chooser) }
            if let chosenProfile { switchToRecentProfile(chosenProfile) }
            else { finishQuickProfileVisibility() }
        } catch { announce("Could not open profiles. \(error.localizedDescription)") }
    }
    private func finishQuickProfileVisibility() {
        guard quickProfileReturnsToMenuBar, recentProfileAfterStop == nil else { return }
        window.orderOut(nil)
        statusItem.isVisible = true
        _ = NSApp.setActivationPolicy(.accessory)
        quickProfileReturnsToMenuBar = false
    }
    func openRecentMenuProfile(_ id: UUID) { switchToRecentProfile(id) }
    func performMenuAction(_ action: RemSoundMenuAction) {
        switch action {
        case .about: about()
        case .help: help()
        case .contextHelp: showContextHelp()
        case .checkForUpdates: updates.check(manual: true, installSilently: false)
        case .preferences: showPreferences()
        case .namedPeers: showNamedPeers()
        case .openLogs: openLogs()
        case .showWindow: showWindow()
        case .toggleLaunchAtLogin: toggleLaunchAtLogin()
        case .forgetSavedPassword: forgetSavedPassword()
        case .connectivityTab: showConnectivityTab()
        case .audioTab: showAudioTab()
        case .profileTab: showProfileTab()
        case .mixTab: showMixTab()
        case .newProfile: newProfile()
        case .saveProfile: saveProfile()
        case .saveProfileAs: saveProfileAs()
        case .openProfile: openProfile()
        case .quickProfileSwitch: showQuickProfileSwitch()
        case .renameProfile: renameProfile()
        case .deleteProfile: deleteProfile()
        case .profilePasswords: showProfilePasswords()
        case .installPlugins: changePlugins(install: true)
        case .removePlugins: changePlugins(install: false)
        case .togglePluginShaping: setPluginShaping(!menuPluginShaping)
        case .toggleProfileLock: toggleProfileLock()
        case .toggleRecording: toggleRecording()
        case .changeRecordingsFolder: changeRecordingsFolder()
        case .openRecordingsFolder: openRecordingsFolder()
        }
    }
    /// Preferences' "Start with a specific profile" (Windows StartWithProfileTitle), when on and the profile still exists.
    private func restoreStartProfile() -> Bool {
        guard let id = PreferencesExtras.startProfileID(), let profile = try? profileStore.load(id: id) else { return false }
        recordStartup("Starting with the profile chosen in Preferences.")
        return showProfile(profile, reconnectAfterLoad: true, playSwitchCue: false)
    }
    /// DAW Plugin > Install or Remove (Windows' DAW plugin menu): the AU, VST3 and CLAP plugins the app carries.
    func refreshPluginMenu() {
        menuPluginsInstalled = !PluginInstaller.installed(in: PluginInstaller.targetRoot(AppRuntime.configuration)).isEmpty
    }
    private func changePlugins(install: Bool) {
        let root = PluginInstaller.targetRoot(AppRuntime.configuration)
        if !install {
            let alert = NSAlert()
            alert.messageText = "Remove the RemSound plugins?"
            alert.informativeText = "The AU, VST3 and CLAP plugins are taken out of your Plug-Ins folder. DAW projects that use them will not find them until you install them again."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            guard AppRuntime.configuration.isHeadless || alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let outcome = install ? PluginInstaller.install(from: PluginInstaller.sourceFolder(), to: root) : PluginInstaller.remove(from: root)
        session.note("plugin: \(install ? "install" : "remove") - \(outcome.message)")
        refreshPluginMenu()
        announce(outcome.message)
    }
    private func setPluginShaping(_ on: Bool) {
        menuPluginShaping = on
        AppRuntime.settings.set(on, forKey: Self.pluginShapingKey)
        session.setPluginShaping(on)
        announce(on ? "Pan and EQ applied to plugin audio." : "Plugin audio is raw: no pan or EQ.")
    }
    /// Profiles > Profile Passwords (Windows' Profile passwords window): every saved profile's password, changed in place.
    private func showProfilePasswords() {
        let profiles = ((try? profileStore.list()) ?? []).sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        let rows = profiles.map { profile -> (id: UUID, title: String, password: String) in
            let stored = (try? AppRuntime.passwordStore(account: profile.id.uuidString).load()) ?? nil
            return (profile.id, profile.title, stored ?? "")
        }
        let (alert, fields) = ProfilePasswordsWindow.make(rows)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let changes = ProfilePasswordsWindow.changes(fields)
        guard !changes.isEmpty else { return }
        var failed: [String] = []
        for change in changes {
            let store = AppRuntime.passwordStore(account: change.row.id.uuidString)
            do {
                if change.password.isEmpty { try store.delete() } else { try store.save(change.password) }
                session.note("profile passwords: changed the password of a profile")
            } catch { failed.append(change.row.title) }
            // The open profile's own password: the box shows the new one, used from the next start.
            if change.row.id == activeProfile?.id, !failed.contains(change.row.title) {
                password.stringValue = change.password
                if running { announce("The new password for this profile is used the next time you start RemSound.") }
            }
        }
        if let problem = ProfilePasswordsWindow.report(failed: failed, changed: changes.count) {
            let report = NSAlert()
            report.messageText = "Profile passwords"
            report.informativeText = problem
            report.runModal()
        } else {
            announce("Profile passwords saved.")
        }
    }
    /// A peer you ticked is on another password (Windows CheckPeerSecurity's box): said once until that changes, and not
    /// when nobody is there to answer.
    private func warnDifferentPassword(_ address: String) {
        guard !AppRuntime.configuration.silent, !AppRuntime.configuration.isHeadless else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "RemSound"
        alert.informativeText = "You and \(address) have different passwords, so no audio will pass between you.\n\n"
            + "Make sure you've both set the same password (the Shared password box on the Connectivity tab)."
        alert.runModal()
    }
    /// A cue that is on but whose sound cannot be found is turned off for now and the person told, once a run
    /// (Windows CheckForMissingEnabledCues). Choosing a sound in Preferences turns it back on.
    private func checkForMissingCues() {
        for event in CueSounds.shared.missingEnabledEvents() {
            CueSounds.shared.preferences.setEnabled(false, for: event)
            guard reportedMissingCues.insert(event).inserted else { continue }
            session.note("cue sound '\(event.title)': enabled but file missing - cue turned off, informing the user")
            guard !AppRuntime.configuration.silent, !AppRuntime.configuration.isHeadless else { continue }
            let alert = NSAlert()
            alert.messageText = "RemSound - missing sound file"
            alert.informativeText = "RemSound was unable to find the \(event.title.lowercased()) sound file used when \(event.whenText). "
                + "RemSound has set this particular audio cue to not play for now, until a new sound file is specified."
            showWindow()
            alert.runModal()
        }
        refreshCueChoices()
    }
    /// After opening: old logs deleted and the logs folder's size warning, then the F1 help message - each as chosen in
    /// Preferences, and none when nobody is there to read them.
    private func startupNotices() {
        checkForMissingCues()
        let warning = PreferencesExtras.logCareAtStart { [weak self] line in self?.session.note(line) }
        guard !AppRuntime.configuration.silent, !AppRuntime.configuration.isHeadless, !startupHidden else { return }
        if let warning {
            let alert = NSAlert()
            alert.messageText = "The logs folder is large"
            alert.informativeText = warning
            alert.runModal()
        }
        if PreferencesExtras.flag(PreferencesExtras.helpMessageKey, default: true) {
            let alert = NSAlert()
            alert.messageText = "Help is on F1"
            alert.informativeText = "Press F1 for help on the control you're on, or Shift-F1 for the whole manual."
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Do not show this message again"
            alert.runModal()
            if alert.suppressionButton?.state == .on {
                AppRuntime.settings.set(false, forKey: PreferencesExtras.helpMessageKey)
                preferencesExtras.helpMessage.state = .off
            }
        }
    }
    @discardableResult private func restoreActiveProfile() -> Bool {
        guard let value = AppRuntime.settings.string(forKey: "activeProfileID"),
            let id = UUID(uuidString: value) else { return false }
        do {
            showProfile(try profileStore.load(id: id), reconnectAfterLoad: true, playSwitchCue: false)
            return true
        }
        catch {
            AppRuntime.settings.removeObject(forKey: "activeProfileID")
            announce("Could not restore the selected profile. \(error.localizedDescription)")
            return false
        }
    }
    private struct ProfileModalContext:Equatable {
        let profile:ConnectionProfile?,draft:UUID?,persisted:ConnectionProfile?,form:ConnectionProfile
        let revision:UUID,source:UUID,passwordEpoch:UUID,request:UUID?,worker:UUID?
        let running:Bool,binding:SessionNetworkBinding?
        let window:ObjectIdentifier,profiles:ObjectIdentifier,passwordStore:ObjectIdentifier
        let name:String,peer:String,remember:Bool
    }
    private func currentProfileModalContext(comparisonID:UUID)->ProfileModalContext? {
        guard terminationRequest == nil,!chooseProfileAfterStop,recentProfileAfterStop == nil,profileStopDispatch == nil,
              browserProfileRemoval == nil,browserProfileTransaction == nil,browserListener.profilePersistenceRetired else {return nil}
        let persisted:ConnectionProfile?
        if let profile=activeProfile {
            guard let value=try? profileStore.load(id:profile.id) else {return nil};persisted=value
        } else {persisted=nil}
        // This ID compares form values even before a draft exists. It is never a
        // profile, credential account or native capability; real identities above
        // stay separate, and the snapshot carries no password.
        let form=profileSnapshot(id:comparisonID,title:activeProfile?.title ?? "",readOnly:activeProfile?.readOnly ?? false)
        return .init(profile:activeProfile,draft:draftProfileID,persisted:persisted,form:form,
            revision:browserProfileRevision,source:browserListener.sourceScope,passwordEpoch:profileModalEpoch,
            request:sessionStartRequest,worker:controlView?.pushToTalkKeyGeneration,running:running,binding:controlView?.networkBinding,
            window:ObjectIdentifier(window),profiles:ObjectIdentifier(profileStore),passwordStore:ObjectIdentifier(passwordStore),
            name:name.stringValue,peer:peer.stringValue,remember:remember.state == .on)
    }
    private func runProfileModal(_ alert:NSAlert)->NSApplication.ModalResponse? {
        let comparisonID=UUID()
        guard !profileModalActive,let context=currentProfileModalContext(comparisonID:comparisonID) else {
            announce("Profile confirmation is not ready while cleanup or another profile choice is pending.");return nil
        }
        profileModalActive=true;defer {profileModalActive=false}
        let response:NSApplication.ModalResponse
        if nativeProductFixture && profileLoggingModalCancel {
            response = .alertSecondButtonReturn
        } else {
            #if DEBUG
            if AppRuntime.configuration.isIsolated,let profileModalProbe {response=profileModalProbe(alert)}
            else {showWindow();response=alert.runModal()}
            #else
            showWindow();response=alert.runModal()
            #endif
        }
        guard currentProfileModalContext(comparisonID:comparisonID)==context else {
            announce("The profile or session changed while confirmation was open. No profile choice was applied; choose again in the current context.");return nil
        }
        return response
    }
    private func prepareProfileMutation()->Bool {
        guard !profileModalActive,!chooseProfileAfterStop,recentProfileAfterStop == nil,profileStopDispatch == nil,
              terminationRequest == nil,browserProfileRemoval == nil,browserProfileTransaction == nil,browserListener.profilePersistenceRetired else {
            if !profileModalActive {_ = retireBrowserBeforeProfilePrompt()};return false
        }
        if browserListener.profileContextRetired {return browserListener.renewRetiredProfileContext()}
        // Terminal success permits only local persistence; the permanently closed
        // service remains unable to load a browser credential or activate again.
        invalidateBrowserProfileEditing();return browserListener.profilePersistenceRetired
    }
    private func buildProfileNameAlert(message: String, initial: String) -> (NSAlert, NSTextField) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "Profile files contain connection settings but never the shared password."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(string: initial)
        input.setAccessibilityLabel("Profile name")
        input.frame = NSRect(x: 0, y: 0, width: 300, height: 26)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        input.identifier = NSUserInterfaceItemIdentifier("help-dialog-profile-name-input")
        FocusedHelpContent.markAlert(alert, notice: "dialog-profile-name-notice", buttons: ["dialog-profile-name-accept", "dialog-profile-name-cancel"], helpDelegate: self)
        return (alert, input)
    }
    private func profileNamePrompt(message: String, initial: String = "") -> String? {
        let (alert, input) = buildProfileNameAlert(message: message, initial: initial)
        guard runProfileModal(alert) == .alertFirstButtonReturn else { return nil }
        return input.stringValue
    }
    private var hasUnsavedProfileChanges: Bool {
        if let saved = activeProfile {
            guard !saved.readOnly,
                profileSnapshot(id: saved.id, title: saved.title, readOnly: saved.readOnly) != saved
            else { return false }
        } else if profileLoggingChoice == draftLoggingBaseline && password.stringValue.isEmpty && peer.stringValue.isEmpty
            && name.stringValue == "RemSound Mac" && send.state == .off
            && systemAudio.state == .off
            && !browserOptions.enabled && !browserOptions.autoStart
            && receive.state == .off && monitor.state == .on
            && plugins.state == .on && reconnect.state == .off
            && selectedInputUIDs == [""] && selectedOutputUIDs == [""]
            && selectedOutputChannelPairs.isEmpty
            && selectedSendCodec() == .pcm && selectedSendPacketSize() == .standard
            && selectedReceiveJitterMs() == ReceiveBuffer.legacyDefaultMs
            && selectedReceiveSmoothness() == BufferSmoothness.defaultLevel
            && selectedReceiveArtifact() == .defaultChoice
            && receiveAutoTune.state == .off
            && selectedAutoTuneInterval() == ReceiveBuffer.defaultAutoTuneInterval
            && selectedRecordingSource() == .both
            && selectedRecordingFormat() == .wav24
            && CueSounds.shared.preferences.profileConfigurations.values.allSatisfy({ $0 == CueConfiguration() })
            && CueSounds.shared.preferences.keyboardClicksEnabled
            && selectedRecordingChannels() == .stereo
            && splitRecording.state == .off
            && recordingBypassShaping.state == .off
            && selectedFLACCompression() == FLACCompression.defaultLevel
            && (AppRuntime.settings.string(forKey: "recordingsDirectory") ?? "").isEmpty
            && peerMixes.isEmpty
            && peerAliases.isEmpty
            && (AppRuntime.settings.stringArray(forKey: "selectedPeerAddresses") ?? []).isEmpty {
            return false
        }
        return true
    }
    private func confirmProfileChange() -> Bool {
        guard retireBrowserBeforeProfilePrompt() else {return false}
        guard hasUnsavedProfileChanges else { return true }
        let alert = NSAlert()
        if let saved = activeProfile {
            alert.messageText = "Save changes to \(saved.title)?"
            alert.informativeText = "Your connection and audio choices have changed since this profile was saved."
        } else {
            alert.messageText = "Save the current setup as a profile?"
            alert.informativeText = "Switching setups will replace the current connection and audio choices."
        }
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        guard let response=runProfileModal(alert) else {return false}
        switch response {
        case .alertFirstButtonReturn: return saveCurrentProfile()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
    private func clearDiscardedDraftPassword() -> Bool {
        guard activeProfile == nil && draftProfileID != nil else { return true }
        do {
            try passwordStore.delete()
            draftProfileID = nil
            return true
        } catch {
            announce("Could not remove the unsaved profile password. \(error.localizedDescription)")
            return false
        }
    }
    private func buildReadOnlySaveAlert(title: String) -> (NSAlert, NSButton) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Saving onto a read-only profile"
        alert.informativeText = "Saving now will overwrite \(title). The profile will remain read only. Choose Save Profile As if you want a separate copy."
        alert.addButton(withTitle: "Save Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        let doNotAsk = NSButton(
            checkboxWithTitle: "Do not show me this message again", target: nil, action: nil)
        doNotAsk.frame = NSRect(x: 0, y: 0, width: 340, height: 26)
        doNotAsk.setAccessibilityHelp(
            "When checked, future manual saves to read-only profiles overwrite them without a warning.")
        alert.accessoryView = doNotAsk
        alert.window.initialFirstResponder = doNotAsk
        doNotAsk.identifier = NSUserInterfaceItemIdentifier("help-dialog-read-only-save-donotask")
        FocusedHelpContent.markAlert(alert, notice: "dialog-read-only-save-notice", buttons: ["dialog-read-only-save-accept", "dialog-read-only-save-cancel"], helpDelegate: self)
        return (alert, doNotAsk)
    }
    @discardableResult private func saveCurrentProfile() -> Bool {
        guard retireBrowserBeforeProfilePrompt() else {return false}
        guard let saved=activeProfile else {return saveProfileAsChoice()}
        if saved.readOnly && !AppRuntime.settings.bool(forKey: "suppressReadOnlySaveWarning") {
            let (alert, doNotAsk) = buildReadOnlySaveAlert(title: saved.title)
            guard let choice=runProfileModal(alert) else {return false}
            if doNotAsk.state == .on {
                AppRuntime.settings.set(true, forKey: "suppressReadOnlySaveWarning")
            }
            guard choice == .alertFirstButtonReturn else { return false }
        }
        do {
            try persistCurrentProfile()
            announce("Profile \(saved.title) saved.")
            CueSounds.shared.play(.save)
            return true
        } catch {
            announce("Could not save profile. \(error.localizedDescription)")
            return false
        }
    }
    private func persistCurrentProfile() throws {
        guard prepareProfileMutation() else {throw ProfileStoreError.invalidProfile}
        guard let saved = activeProfile else { throw ProfileStoreError.invalidProfile }
        let updated = profileSnapshot(id: saved.id, title: saved.title, readOnly: saved.readOnly)
        if remember.state == .on && !password.stringValue.isEmpty {
            try passwordStore.save(password.stringValue)
        }
        try profileStore.save(updated)
        activeProfile = updated
        refreshProfileNotice()
    }
    @objc private func saveProfile() { _ = saveCurrentProfile() }
    @objc private func saveProfileAs() {_ = saveProfileAsChoice()}
    @discardableResult private func saveProfileAsChoice()->Bool {
        guard retireBrowserBeforeProfilePrompt(),let title=profileNamePrompt(message:"Save Profile As") else {return false}
        do {
            try persistProfileAs(title);announce("Profile \(activeProfile!.title) saved.")
            CueSounds.shared.play(.save);return true
        } catch {announce("Could not save profile. \(error.localizedDescription)");return false}
    }
    private func persistProfileAs(_ title: String) throws {
        guard prepareProfileMutation() else {throw ProfileStoreError.invalidProfile}
        let id = activeProfile == nil ? (draftProfileID ?? UUID()) : UUID()
        let profile = profileSnapshot(
            id: id, title: title.trimmingCharacters(in: .whitespacesAndNewlines), readOnly: false)
        let newPasswordStore = AppRuntime.passwordStore(account: profile.id.uuidString)
        try profileStore.save(profile)
        do {
            if remember.state == .on && !password.stringValue.isEmpty {
                try newPasswordStore.save(password.stringValue)
            }
        }
        catch {
            try? profileStore.delete(id: profile.id)
            throw error
        }
        activeProfile = profile
        draftProfileID = nil
        passwordStore = newPasswordStore
        AppRuntime.settings.set(profile.id.uuidString, forKey: "activeProfileID")
        window.title = "RemSound Mac — \(profile.title)"
        menuProfileReadOnly = false
        refreshProfileNotice()
        recordRecentProfile(profile.id)
    }
    private func buildOpenProfileAlert(profiles: [ConnectionProfile]) -> (NSAlert, NSPopUpButton) {
        let alert = NSAlert()
        alert.messageText = "Open Profile"
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        picker.setAccessibilityLabel("Saved profiles")
        for profile in profiles {
            picker.addItem(withTitle: profile.title + (profile.readOnly ? " (read only)" : ""))
        }
        alert.accessoryView = picker
        alert.window.initialFirstResponder = picker
        picker.identifier = NSUserInterfaceItemIdentifier("help-dialog-open-profile-picker")
        FocusedHelpContent.markAlert(alert, notice: "dialog-open-profile-notice", buttons: ["dialog-open-profile-accept", "dialog-open-profile-cancel"], helpDelegate: self)
        return (alert, picker)
    }
    @objc private func openProfile() {
        guard retireBrowserBeforeProfilePrompt() else {return}
        if running {
                let alert = NSAlert()
            alert.messageText = "Stop RemSound to open a profile?"
            alert.informativeText =
                "The audio connection will stop. You can choose a saved profile and then press Start."
            alert.addButton(withTitle: "Stop and Choose Profile")
            alert.addButton(withTitle: "Cancel")
            if runProfileModal(alert) == .alertFirstButtonReturn {
                chooseProfileAfterStop = true
                pushToTalkInput?.invalidate()
                sessionStartRequest = nil
                pushToTalkSubmittedStartRequest = nil
                routerControls?.invalidate()
                jam.retireServerNotice()
                stopSessionAfterBrowserRetirement();sealProfileAfterStop()
            }
            return
        }
        guard confirmProfileChange() else { return }
        do {
            let profiles = try profileStore.list()
            guard !profiles.isEmpty else { announce("No saved profiles yet."); return }
            let (alert, picker) = buildOpenProfileAlert(profiles: profiles)
            guard runProfileModal(alert) == .alertFirstButtonReturn else { return }
            guard profiles.indices.contains(picker.indexOfSelectedItem) else { return }
            let selected = profiles[picker.indexOfSelectedItem]
            guard (try? profileStore.load(id:selected.id))==selected else {announce("The selected profile changed. Open the picker again.");return}
            guard clearDiscardedDraftPassword() else { return }
            guard prepareProfileMutation(),showProfile(selected,browserContextAlreadyRetired:true) else {
                announce("Profile selection was not applied. Wait for cleanup, then choose again.");return
            }
            announce("Profile \(selected.title) opened. Press Start to connect.")
        } catch { announce("Could not open profiles. \(error.localizedDescription)") }
    }
    @objc private func newProfile() {
        guard !running else { announce("Stop RemSound before starting a new profile."); return }
        guard confirmProfileChange() else { return }
        guard clearDiscardedDraftPassword() else { return }
        guard prepareProfileMutation(),resetToBlankProfile(inheritingCues:CueSounds.shared.preferences.profileConfigurations,browserContextAlreadyRetired:true) else {
            announce("New profile was not applied. Wait for cleanup, then choose again.");return
        }
        CueSounds.shared.profileOpened()
        announce("New profile. Enter a password and choose Save Profile As to keep this setup.")
    }
    @discardableResult private func resetToBlankProfile(inheritingCues: [String: CueConfiguration]? = nil,browserContextAlreadyRetired:Bool=false)->Bool {
        guard browserProfileRemoval == nil else {browserProfileRemoval?.cancel();return false}
        guard applyProfileLogging(false) else { return false }
        draftLoggingBaseline = false
        suspendPushToTalkForProfileChange(browserContextAlreadyRetired:browserContextAlreadyRetired)
        activeProfile = nil
        browserOptions = .init()
        jam.setVolume(ConnectionProfile.defaultMetronomeVolume)
        jam.loadProfileMetronome(MetronomeChoices())
        pushToTalkSettings = .init()
        pushToTalkSettingsUnreadable = false
        refreshPushToTalkPresentation()
        let id = UUID()
        draftProfileID = id
        passwordStore = AppRuntime.passwordStore(account: id.uuidString)
        AppRuntime.settings.removeObject(forKey: "activeProfileID")
        AppRuntime.settings.set([String](), forKey: "selectedPeerAddresses")
        AppRuntime.settings.set(false, forKey: "lockPeerAddresses")
        connectivityPeers.refresh(entries: rememberedPeerEntries, running: running, locked: false)
        name.stringValue = "RemSound Mac"
        peer.stringValue = ""
        password.stringValue = ""
        send.state = .off
        systemAudio.state = .off
        selectedInputUIDs = [""]
        selectedInputChannelPairs = [:]
        selectedOutputUIDs = [""]
        selectedOutputChannelPairs = [:]
        resumeInputSendingWhenSelected = false
        resumeSystemSendingWhenSelected = false
        selectedCaptureUIDs = nil
        selectedCaptureChannelPairs = [:]
        hotkeyResumeInput = false
        hotkeyResumeSystem = false
        populateDeviceChoices(inputUIDs: selectedInputUIDs, outputUIDs: selectedOutputUIDs,
            systemCaptureUIDs: selectedCaptureUIDs)
        receive.state = .off
        monitor.state = .on
        plugins.state = .on
        codec.selectItem(withTitle: SendCodec.opusLive.label)
        packetSize.selectItem(withTitle: SendPacketSize.standard.label)
        selectReceiveSmoothness(BufferSmoothness.defaultLevel)
        selectReceiveArtifact(.defaultChoice)
        receiveJitter.selectItem(withTitle:
            "\(ReceiveBuffer.legacyDefaultMs) milliseconds")
        receiveAutoTune.state = .off
        receiveAutoTuneInterval.selectItem(withTitle:
            "\(ReceiveBuffer.defaultAutoTuneInterval) seconds")
        refreshReceiveLatencyStatus()
        recordingSource.selectItem(withTitle: RecordingSource.both.label)
        recordingFormat.selectItem(withTitle: RecordingFormat.wav24.label)
        recordingChannels.selectItem(withTitle: RecordingChannels.stereo.label)
        splitRecording.state = .off
        recordingBypassShaping.state = .off
        let cues = CueSounds.shared.preferences
        cues.loadProfile(inheritingCues ?? [:], keyboardClicks: cues.keyboardClicksEnabled)
        refreshTypingFeedback()
        cueCustomFiles = [:]
        refreshCueChoices()
        flacCompression.selectItem(at: FLACCompression.defaultLevel)
        flacCompression.isEnabled = false
        AppRuntime.settings.removeObject(forKey: "recordingsDirectory")
        peerMixes = [:]
        AppRuntime.settings.removeObject(forKey: "peerMixes")
        peerAliases = [:]
        AppRuntime.settings.removeObject(forKey: "peerAliases")
        updatePeerMixControls()
        reconnect.state = .off
        AppRuntime.settings.set(false, forKey: "reconnectOnOpen")
        saveAudioOptions()
        window.title = "RemSound Mac — New Profile"
        menuProfileReadOnly = false
        refreshProfileNotice()
        return true
    }
    @objc private func renameProfile() {
        guard retireBrowserBeforeProfilePrompt() else {return}
        guard let profile = activeProfile else { announce("Save this profile before renaming it."); return }
        guard let title = profileNamePrompt(message: "Rename Current Profile", initial: profile.title)
        else { return }
        do {
            try persistProfileTitle(title)
            announce("Profile renamed to \(activeProfile!.title).")
        } catch { announce("Could not rename profile. \(error.localizedDescription)") }
    }
    private func persistProfileTitle(_ title: String) throws {
        guard prepareProfileMutation() else {throw ProfileStoreError.invalidProfile}
        guard var profile = activeProfile else { throw ProfileStoreError.invalidProfile }
        profile.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try profileStore.save(profile)
        activeProfile = profile
        window.title = "RemSound Mac — \(profile.title)\(profile.readOnly ? " (read only)" : "")"
        refreshProfileNotice()
        recordRecentProfile(profile.id)
    }
    @objc private func deleteProfile() {
        guard !running else {announce("Stop RemSound before deleting a profile.");return}
        guard let profile=activeProfile else {announce("No saved profile is open.");return}
        guard retireBrowserBeforeProfilePrompt() else {return}
        let revision=browserProfileRevision
        let alert=NSAlert()
        alert.messageText="Delete profile \(profile.title)?"
        alert.informativeText="This removes its saved settings and both saved connection and browser passwords. It cannot be undone."
        alert.addButton(withTitle:"Cancel");alert.addButton(withTitle:"Delete Profile")
        guard runProfileModal(alert) == .alertSecondButtonReturn else {return}
        guard activeProfile==profile,browserProfileRevision==revision,browserListener.profileContextRetired,
              startConfirmedProfileRemoval(profile) else {
            announce("Profile deletion was refused because its context changed or earlier work is still finishing.");return
        }
    }
    @objc private func toggleProfileLock() {
        guard let profile = activeProfile else { announce("Save a profile before locking it."); return }
        do {
            try persistProfileLock(!profile.readOnly)
            announce(activeProfile!.readOnly ? "Profile locked read only." : "Profile unlocked.")
        } catch { announce("Could not change profile lock. \(error.localizedDescription)") }
    }
    private func persistProfileLock(_ readOnly: Bool) throws {
        guard prepareProfileMutation() else {throw ProfileStoreError.invalidProfile}
        guard var profile = activeProfile else { throw ProfileStoreError.invalidProfile }
        profile.readOnly = readOnly
        try profileStore.save(profile)
        activeProfile = profile
        menuProfileReadOnly = profile.readOnly
        window.title = "RemSound Mac — \(profile.title)\(profile.readOnly ? " (read only)" : "")"
        refreshProfileNotice()
    }
    private func focusedHelpAccessibilityFailures() -> [String] {
        var failures = [String]()
        let owner = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        let field = NSSecureTextField(frame: NSRect(x: 20, y: 20, width: 320, height: 24))
        field.stringValue = "fixture-private-value"
        field.setAccessibilityLabel("Shared password")
        field.setAccessibilityHelp("Use the same shared password on both computers.")
        owner.contentView?.addSubview(field)
        owner.makeKeyAndOrderFront(nil)
        owner.makeFirstResponder(field)
        let content = FocusedHelpContent.capture(in: owner)
        if content.title != "Shared password" || content.focusedView !== field
            || !content.text.contains("Use the same shared password")
            || content.text.contains("fixture-private-value") {
            failures.append("Focused help must describe the owning secure field without its value")
        }
        var opens = 0, closes = 0, manuals = 0
        let controller = FocusedHelpWindowController(content: content, owner: owner,
            playOpen: { opens += 1 }, playClose: { closes += 1 },
            openManual: { manuals += 1 })
        controller.present()
        controller.present()
        if opens != 1 || closes != 0 || controller.window?.firstResponder !== controller.textView
            || controller.textView.isEditable || !controller.textView.isSelectable
            || controller.textView.selectedRange() != NSRange(location: 0, length: 0)
            || controller.textView.accessibilityLabel() != "Shared password help"
            || controller.textView.accessibilityHelp()?.contains("Escape") != true {
            failures.append("Context help must cue once and focus readable unselected text at its beginning")
        }
        controller.manualButton.performClick(nil)
        if manuals != 1 || closes != 0 || opens != 1 || controller.window?.isVisible != true {
            failures.append("Opening the manual must leave context help open without extra cue events")
        }
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: controller.window!.windowNumber,
                context: nil, characters: code == 48 ? "\t" : "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code)!
        }
        controller.window?.sendEvent(key(48))
        if controller.window?.firstResponder !== controller.manualButton {
            failures.append("Tab from context help must reach Open Manual")
        }
        controller.window?.sendEvent(key(48, .shift))
        if controller.window?.firstResponder !== controller.textView {
            failures.append("Shift-Tab must return to context help text")
        }
        for _ in 0..<3 { controller.window?.sendEvent(key(48)) }
        if controller.window?.firstResponder !== controller.textView {
            failures.append("Forward Tab must traverse the entire context help window")
        }
        for _ in 0..<3 { controller.window?.sendEvent(key(48, .shift)) }
        if controller.window?.firstResponder !== controller.textView {
            failures.append("Reverse Tab must traverse the entire context help window")
        }
        controller.window?.sendEvent(key(53))
        controller.close()
        if closes != 1 || controller.window?.isVisible == true
            || field.currentEditor() !== owner.firstResponder {
            failures.append("Escape must cue help-close once and restore the original editing control")
        }
        var requests = [Bool]()
        owner.contextHelp = { requests.append($0) }
        owner.sendEvent(key(122))
        owner.sendEvent(key(122, [.shift, .function]))
        if requests != [false, true] {
            failures.append("Native focused windows must distinguish F1 help from Shift-F1 manual")
        }
        controller.present()
        controller.window?.sendEvent(key(UInt16(kVK_ANSI_W), .command))
        if closes != 2 || controller.window?.isVisible == true {
            failures.append("Command-W must close the context help window and play its close cue")
        }
        weak var previousController: FocusedHelpWindowController?
        for _ in 0..<20 {
            autoreleasepool {
                let repeated = FocusedHelpWindowController(content: content, owner: owner,
                    playOpen: { opens += 1 }, playClose: { closes += 1 }, openManual: {})
                previousController = repeated
                repeated.present()
                repeated.close()
            }
            if previousController != nil {
                failures.append("Closed context help controllers must be released during churn")
                break
            }
        }
        if opens != 22 || closes != 22 {
            failures.append("Repeated context help must emit one open and one close per lifetime")
        }
        owner.close()
        return failures
    }

    private var contextHelpAction: (Bool, NSWindow) -> Void {
        { [weak self] manual, owner in
            guard let self else { return }
            if manual { self.help() } else { self.showContextHelp(in: owner) }
        }
    }

    private func showContextHelp(in requestedOwner: NSWindow? = nil) {
        guard NSApp.modalWindow == nil else {
            announce("Close the current dialog before opening context help.")
            return
        }
        if focusedHelpWindow?.window?.isVisible == true || (nativeProductFixture && focusedHelpWindow != nil) {
            if !nativeProductFixture { focusedHelpWindow?.present() }
            return
        }
        let owner = requestedOwner ?? NSApp.keyWindow ?? window
        let content = FocusedHelpContent.capture(in: owner)
        let key = content.focusedView.flatMap { FocusedHelpContent.key(of: $0) }
        focusedHelpWindow = FocusedHelpWindowController(
            content: content, owner: owner,
            playOpen: { CueSounds.shared.play(.helpOpen) },
            playClose: { CueSounds.shared.play(.helpClose) },
            openManual: { [weak self] in self?.openManualPage(at: key) })
        if !nativeProductFixture { focusedHelpWindow?.present() }
    }
    func alertShowHelp(_ alert: NSAlert) -> Bool {
        guard alert.delegate as AnyObject? === self,
            NSApp.modalWindow == nil || NSApp.modalWindow === alert.window,
            let content = FocusedHelpContent.content(for: alert, manual: FocusedHelpContent.bundledManual()) else {
            announce("Help for this dialog is unavailable. The dialog has not been changed.")
            return true
        }
        focusedHelpWindow?.close()
        let key = content.focusedView.flatMap { FocusedHelpContent.key(of: $0) }
        focusedHelpWindow = FocusedHelpWindowController(content: content, owner: alert.window,
            playOpen: { CueSounds.shared.play(.helpOpen) }, playClose: { CueSounds.shared.play(.helpClose) },
            openManual: { [weak self] in self?.openManualPage(at: key) })
        if !nativeProductFixture { focusedHelpWindow?.present() }
        // Always consume the request; failed lookup must never open the external Help Viewer.
        return true
    }
    @objc private func help() {
        _ = openManual(file: Bundle.main.url(forResource: "Manual", withExtension: "html"), open: manualReader)
    }
    /// Keep the control's help anchor when opening a local manual in the browser.
    /// The fallback opens the bundled HTML manual if the cached page cannot be prepared.
    private func openManualPage(at key: String?) {
        guard let source = Bundle.main.url(forResource: "README", withExtension: "md"),
              let text = try? String(contentsOf: source, encoding: .utf8) else { help(); return }
        let cache = AppRuntime.configuration.root?.appendingPathComponent("Cache", isDirectory: true)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = cache.appendingPathComponent("RemSound/Manual", isDirectory: true)
        let page = folder.appendingPathComponent("README.html"), opener = folder.appendingPathComponent("open.html")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try ManualHTML.render(text).write(to: page, atomically: true, encoding: .utf8)
            try ManualHTML.redirect(to: "README.html", key: key).write(to: opener, atomically: true, encoding: .utf8)
        } catch { help(); return }
        session.note(key.map { "context help: opening the manual in the browser at \($0)" } ?? "manual: opening the whole manual in the browser")
        guard !AppRuntime.configuration.isHeadless || nativeProductFixture else { return }
        if !manualReader(opener) { help() }
    }
    @discardableResult private func openManual(file: URL?, open: (URL) -> Bool) -> Bool {
        guard let file, (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
            FileManager.default.isReadableFile(atPath: file.path) else {
            announce("The RemSound manual is missing or unreadable. Reinstall the complete app to restore its manual.")
            return false
        }
        guard open(file) else {
            announce("The RemSound manual could not be opened by the default document reader.")
            return false
        }
        return true
    }
    @objc private func openLogs() {
        let url = AppRuntime.configuration.logsDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
    @objc private func about() {
        let alert = NSAlert()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
        alert.messageText = "RemSound Mac \(version)"
        alert.informativeText =
            "Original RemSound by Ed Pourtahmasbi. Mac port by Andre Louis. This is a development preview; Windows feature parity is still in progress."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Open Ed's Original Project")
        if alert.runModal() == .alertSecondButtonReturn,
            let url = URL(string: "https://github.com/Ednunp/RemSound") {
            NSWorkspace.shared.open(url)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }
    func applicationWillHide(_ notification: Notification) {
        hideObservation = beginUIObservation(.hideWindow)
        if let hideObservation { uiObservations.handlerReturned(hideObservation) }
    }
    func applicationDidHide(_ notification: Notification) {
        defer {
            if let hideObservation {
                uiObservations.finish(hideObservation, outcome: NSApp.isHidden ? .effectObserved : .failed)
                self.hideObservation = nil
            }
        }
        if !CommandLine.arguments.contains("--check-accessibility") {
            CueSounds.shared.play(.hide)
        }
        statusItem.isVisible = true
        _ = NSApp.setActivationPolicy(.accessory)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if !quickProfileReturnsToMenuBar,
            !CommandLine.arguments.contains("--check-accessibility") {
            CueSounds.shared.play(.hide)
        }
        statusItem.isVisible = true
        _ = sender.setActivationPolicy(.accessory)
        return false
    }
    private func scheduleTermination() {
        // Let the current action or control reply return before beginning Quit.
        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { _ in NSApp.terminate(nil) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationReady { return .terminateNow }
        if terminationRequest != nil || quitProfileConfirmation != nil { return .terminateCancel }
        recordStartup("Quit requested; checking unsaved work before cleanup.")
        if !AppRuntime.configuration.isHeadless,
            (activeProfile != nil || draftProfileID != nil), hasUnsavedProfileChanges {
            if browserProfileTransaction != nil || !browserListener.profilePersistenceRetired {
                prepareQuitProfileConfirmation(sender)
                return .terminateCancel
            }
            if !confirmProfileChange() {
                discardPendingUpdate()
                recordStartup("Quit cancelled; profile confirmation was cancelled or its context changed.")
                return .terminateCancel
            }
        }
        let request = UUID()
        terminationRequest = request
        recordStartup("Quit cleanup started; keeping the event loop available.")
        pushToTalkSubmittedStartRequest = nil
        pushToTalkInput?.invalidate()
        sessionStartRequest = nil
        startupRequests.invalidate()
        jam.shutdown()
        shutdownRouterThenSession(request) { [weak self] result in
            guard let self, self.terminationRequest == request else { return }
            if case .failure(let error) = result {
                self.terminationRequest = nil; self.discardPendingUpdate()
                self.recordStartup("Quit cancelled; browser or router cleanup failed.")
                self.announce("The browser listener or the router did not close properly, so RemSound stayed open. " + error.localizedDescription)
                return
            }
            self.finishTermination(sender)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sessionShutdownTimeout) { [weak self] in
            guard let self, self.terminationRequest == request else { return }
            self.terminationRequest = nil
            self.discardPendingUpdate()
            self.recordStartup("Quit cancelled; resource cleanup exceeded the deadline.")
            let message = "Browser listener cleanup, router cleanup, audio cleanup or recording is still finishing. RemSound has stayed open to protect active audio resources and your files. Wait, then quit or check for updates again. If capture cleanup cannot finish, restart the app before using capture again."
            self.announce(message)
            if !AppRuntime.configuration.isHeadless {
                let alert = NSAlert()
                alert.messageText = "Session Is Still Finishing"
                alert.informativeText = message
                alert.runModal()
            }
        }
        // terminateLater enters AppKit's nested termination loop. A Quit invoked
        // from a main-queue menu action can then block our main-queue cleanup.
        // Cancel this attempt and request final termination after cleanup finishes.
        return .terminateCancel
    }
    private func prepareQuitProfileConfirmation(_ sender: NSApplication) {
        guard !profileModalActive, !chooseProfileAfterStop, recentProfileAfterStop == nil,
            profileStopDispatch == nil, browserProfileRemoval == nil else {
            announce("Finish the current profile choice, then quit RemSound.")
            return
        }
        let request = UUID()
        quitProfileConfirmation = request
        recordStartup("Quit is waiting for browser editing to retire before profile confirmation.")
        let transaction = browserProfileTransaction
        invalidateBrowserProfileEditing()
        let retire = { [weak self] in
            guard let self, self.quitProfileConfirmation == request else { return }
            self.browserListener.perform(.stopSession) { [weak self] in
                // Retirement callbacks finish on this turn. Resume the original
                // Quit on the next turn instead of requiring another key press.
                DispatchQueue.main.async {
                    guard let self, self.quitProfileConfirmation == request else { return }
                    self.quitProfileConfirmation = nil
                    _ = self.applicationShouldTerminate(sender)
                }
            }
        }
        if let transaction {
            if !transaction.close(completion: retire) {
                quitProfileConfirmation = nil
                discardPendingUpdate()
                announce("Browser editing is still finishing. RemSound stayed open; try Quit again after cleanup.")
            }
        } else { retire() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sessionShutdownTimeout) { [weak self] in
            guard let self, self.quitProfileConfirmation == request else { return }
            self.quitProfileConfirmation = nil
            self.discardPendingUpdate()
            self.recordStartup("Quit cancelled; browser editing did not retire before the deadline.")
            self.announce("Browser editing did not finish closing. RemSound stayed open to protect your settings; try Quit again.")
        }
    }
    private func shutdownRouterThenSession(_ request: UUID, completion: @escaping (Result<Void, Error>) -> Void) {
        let afterRouter: (Result<Void, Error>) -> Void = { [weak self] result in
            guard let self, self.terminationRequest == request else { return }
            if case .failure = result { completion(result); return }
            #if DEBUG
            if AppRuntime.configuration.isIsolated {
                self.browserBeforeSessionShutdownProbe?()
                self.browserShutdownSubmissions += 1
            }
            #endif
            self.session.shutdown { [weak self] in
                guard self?.terminationRequest == request else { return }
                completion(.success(()))
            }
        }
        shutdownBrowserProfile { [weak self] result in
            guard let self, self.terminationRequest == request else { return }
            if case .failure = result { completion(result); return }
            if let routerControls = self.routerControls { routerControls.shutdown(afterRouter) }
            else { afterRouter(.success(())) }
        }
    }
    private func finishTermination(_ sender: NSApplication) {
        if let pendingUpdate {
            do {
                try updates.launchInstaller(stage: pendingUpdate.stage,
                    version: pendingUpdate.version, helper: pendingUpdate.helper)
                self.pendingUpdate = nil
            } catch {
                discardPendingUpdate()
                let alert = NSAlert()
                alert.messageText = "RemSound Update Could Not Start"
                alert.informativeText = error.localizedDescription
                terminationRequest = nil
                recordStartup("Quit cancelled; the update helper could not start.")
                alert.runModal()
                return
            }
        }
        terminationReady = true
        recordStartup("Quit cleanup completed; exiting.")
        #if DEBUG
        if nativeProductFixture, AppRuntime.configuration.isIsolated, let terminationCompletedForTesting {
            terminationCompletedForTesting()
            return
        }
        #endif
        sender.terminate(nil)
    }
    #if DEBUG
    static func quitProfileRegressionFailures(response: NSApplication.ModalResponse?) -> [String] {
        precondition(Thread.isMainThread && AppRuntime.configuration.isIsolated && !AppRuntime.configuration.isHeadless && AppRuntime.configuration.silent)
        _ = NSApplication.shared
        let owner = AppDelegate()
        owner.nativeProductFixture = true
        owner.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        var failures = [String](), completed = false, prompts = 0
        func wait(_ done: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        }
        wait { owner.browserListener.profilePersistenceRetired }
        do {
            owner.remember.state = .off
            try owner.persistProfileAs("Quit regression")
            let saved = owner.activeProfile!
            if response != nil { owner.name.stringValue = "Edited isolated setup" }
            owner.profileModalProbe = { _ in
                prompts += 1
                return response ?? .alertThirdButtonReturn
            }
            // Only the observation is synthetic. The actual Session remains stopped;
            // browser retirement, profile storage, modal admission and Quit are real.
            owner.running = true
            owner.browserListener.invalidate(discardMutations: true)
            owner.browserListener.observe(running: true, binding: .init(port: 49152, generation: UUID()), workerGeneration: UUID())
            owner.terminationCompletedForTesting = { completed = true }
            if owner.applicationShouldTerminate(NSApp) != .terminateCancel { failures.append("Quit must return to the event loop") }
            if owner.applicationShouldTerminate(NSApp) != .terminateCancel { failures.append("Repeated Quit must coalesce while confirmation or cleanup is pending") }
            if response == .alertThirdButtonReturn {
                wait { prompts > 0 }
                if completed || owner.terminationRequest != nil { failures.append("Cancel must preserve the app") }
            } else {
                wait { completed }
                if !completed { failures.append("Quit with a running-profile observation must complete without a second user request") }
            }
            if prompts != (response == nil ? 0 : 1) { failures.append("Quit must show exactly the required save prompt") }
            let persisted = try owner.profileStore.load(id: saved.id)
            if response == .alertFirstButtonReturn {
                if persisted == saved { failures.append("Save must persist the edited profile before Quit") }
            } else if persisted != saved { failures.append("Discard or Cancel must preserve the saved profile") }
            if owner.window.isVisible || owner.preferencesWindow?.isVisible == true { failures.append("Fixture must not present windows") }
            try owner.profileStore.delete(id: saved.id)
        } catch { failures.append("Isolated Quit profile fixture failed: \(error.localizedDescription)") }
        owner.running = false
        owner.profileModalProbe = nil
        var browserClosed = false, sessionClosed = false
        owner.shutdownBrowserProfile { if case .success = $0 { browserClosed = true } }
        wait { browserClosed }
        owner.session.shutdown { sessionClosed = true }
        wait { sessionClosed }
        if !browserClosed || !sessionClosed { failures.append("Fixture retirement did not complete") }
        owner.terminationCompletedForTesting = nil
        owner.preferencesWindow?.close(); owner.window.close()
        return failures
    }

    static func quitLifecycleRegressionFailures() -> [String] {
        precondition(Thread.isMainThread && AppRuntime.configuration.isIsolated && AppRuntime.configuration.silent)
        _ = NSApplication.shared
        let owner = AppDelegate()
        owner.nativeProductFixture = true
        var completed = false, failures = [String]()
        owner.terminationCompletedForTesting = { completed = true }
        let reply = owner.applicationShouldTerminate(NSApp)
        if reply != .terminateCancel { failures.append("Quit must leave AppKit's event loop available while cleanup runs") }
        if owner.terminationRequest == nil { failures.append("Quit must retain its cleanup request") }
        if owner.applicationShouldTerminate(NSApp) != .terminateCancel { failures.append("Repeated Quit must not enter a nested termination loop") }
        let deadline = Date().addingTimeInterval(3)
        while !completed && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        if !completed { failures.append("Actual browser and Session cleanup did not complete") }
        if completed && owner.applicationShouldTerminate(NSApp) != .terminateNow { failures.append("Completed cleanup must permit actual process termination") }
        owner.terminationCompletedForTesting = nil
        return failures
    }
    #endif
    private func discardPendingUpdate() {
        if let pendingUpdate {
            try? FileManager.default.removeItem(at: pendingUpdate.stage)
            self.pendingUpdate = nil
        }
    }
    private func startTypingFeedback() {
        guard !typingFeedbackStarted else { return }
        typingFeedbackStarted = true
        typingPlayer.start()
        typingMonitor.start()
    }
    private func refreshTypingFeedback() {
        pushToTalkPreview?.refresh()
        guard typingFeedbackStarted else { return }
        typingPlayer.refresh()
        typingMonitor.refresh()
    }
    private func stopTypingFeedback() {
        guard typingFeedbackStarted else { return }
        typingFeedbackStarted = false
        typingMonitor.stop()
        typingPlayer.shutdown()
    }
    func applicationWillTerminate(_ notification: Notification) {
        PreferencesExtras.saveWindowFrame(window)
        invalidateBrowserProfileEditing()
        shutdownBrowserProfile { [weak self] result in
            if case .success = result { self?.session.shutdown() }
        }
        routerControls?.shutdown()
        startupRequests.shutdown()
        jam.shutdown()
        pushToTalkClosing = true
        pushToTalkInput?.shutdown()
        pushToTalkInput = nil
        for observer in pushToTalkFocusObservers { NotificationCenter.default.removeObserver(observer) }
        pushToTalkFocusObservers.removeAll()
        pushToTalkPreview?.shutdown()
        pushToTalkPreview = nil
        pushToTalkWindow?.close()
        pushToTalkWindow = nil
        pushToTalkKeys.shutdown()
        stopTypingFeedback()
        AppRuntime.finish()
        controlServer?.stop()
        uiObservations.stop()
        autoSaveTimer?.invalidate()
    }
}

private extension AppDelegate {
    func startControlServer() throws {
        guard let socket = AppRuntime.configuration.controlSocketURL else { return }
        let server = LocalControlServer(socketURL: socket, dispatcher: { [weak self] operation in
            DispatchQueue.main.async {
                guard operation.begin() else {
                    operation.finish(ControlReply(request: operation.request, status: .error, message: "The action was cancelled."))
                    return
                }
                guard let self else {
                    operation.finish(ControlReply(request: operation.request, status: .error, message: "The app is stopping."))
                    return
                }
                do {
                    let command = try ControlCommand(operation.request)
                    operation.finish(self.performControlCommand(command, request: operation.request))
                } catch {
                    operation.finish(ControlReply(request: operation.request, status: .error, message: "Invalid control action or arguments."))
                }
            }
        })
        try server.start()
        controlServer = server
    }

    func headlessPermissionIssue() -> String? {
        guard AppRuntime.configuration.isHeadless else { return nil }
        if send.state == .on && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            return "Microphone permission needs a visible app. Use show, then Preferences, Permissions."
        }
        if systemAudio.state == .on && !(systemAudioAccessChecked && systemAudioAccessAvailable) {
            return "System audio permission needs a visible access check. Use show, then Preferences, Permissions."
        }
        return nil
    }

    func controlState() -> [String: String] {
        // An explicit allowlist; profile identity is safe, settings and connection text are not returned.
        var state = [
            "headless": String(AppRuntime.configuration.isHeadless), "running": String(running),
            "diagnostic-logging": String(effectiveLoggingEnabled),
            "start-pending": String(!running && !start.isEnabled),
            "input-send": String(send.state == .on), "system-send": String(systemAudio.state == .on),
            "receive": String(receive.state == .on), "daw": String(plugins.state == .on),
            "mac-output": String(monitor.state == .on), "password-present": String(!password.stringValue.isEmpty),
            "peers-known": String(rows.count), "peers-connected": String(connectedPeerCount),
            "codec": selectedSendCodec().rawValue, "packet-size": selectedSendPacketSize().rawValue, "jitter-ms": String(selectedReceiveJitterMs()), "smoothness": String(selectedReceiveSmoothness()), "artifact": selectedReceiveArtifact() == .noiseBurst ? "noise" : "click",
            "auto-tune": String(receiveAutoTune.state == .on), "auto-tune-interval": String(selectedAutoTuneInterval()),
            "auto-tune-lowest-delay": String(receiveLowestDelay.state == .on),
            "plugins-installed": String(menuPluginsInstalled), "plugin-shaping": String(menuPluginShaping),
            "server-connected": String(jam.view.connected), "self-monitor": String(jam.view.selfMonitoring),
            "system-all": String(selectedCaptureUIDs == nil),
            "profile-id": activeProfile?.id.uuidString ?? "",
            "profile-read-only": String(activeProfile?.readOnly ?? false),
            "profile-unsaved-changes": String(hasUnsavedProfileChanges),
            "cue-mute": String(CueSounds.shared.preferences.muteAllCues),
            "recording": String(controlView?.recording ?? false),
            "recording-finishing": String(controlView?.recordingFinishing ?? false),
            "recording-source": selectedRecordingSource().rawValue,
            "recording-format": selectedRecordingFormat().rawValue,
            "recording-channels": selectedRecordingChannels().rawValue,
            "recording-split": String(splitRecording.state == .on),
            "recording-bypass": String(recordingBypassShaping.state == .on),
            "flac-compression": String(selectedFLACCompression()),
            "metronome-role": String(describing: jam.view.metronomeRole),
            "metronome-playing": String(jam.view.metronomePlaying),
            "metronome-muted": String(jam.view.metronomeMuted),
            "metronome-tempo": String(jam.view.metronomeBpm),
            "metronome-signature": jam.signature, "metronome-volume": String(jam.volume),
            "metronome-sound": jam.sound,
            "metronome-when-asked": String(describing: jam.view.whenAsked),
            "metronome-hear": jam.choices.hearIn == .daw ? "daw" : "remsound",
            "metronome-record": String(jam.choices.includeInRecordings),
            "window-visible": String(window.isVisible),
            "visible-windows": String(NSApp.windows.filter { $0.isVisible && $0 !== statusItem.button?.window }.count)
        ]
        if let view = controlView {
            state["observed-input-send"] = String(view.sendingInput)
            state["observed-system-send"] = String(view.sendingSystemAudio)
            state["observed-receive"] = String(view.receiving)
            state["observed-daw"] = String(view.allowingPlugins)
            state["observed-mac-output"] = String(view.monitoringInApp)
        }
        return state
    }

    func performControlCommand(_ command: ControlCommand, request: ControlRequest) -> ControlReply {
        func reply(_ status: ControlReply.Status = .ok, _ message: String) -> ControlReply {
            ControlReply(request: request, status: status, message: message, state: controlState())
        }
        guard terminationRequest == nil else {
            return reply(.waiting, "The app is stopping and finishing recordings. Wait for shutdown to complete.")
        }
        if profileModalActive {
            switch command.action {
            case .help,.status,.devices,.profileList,.cueList:break
            default:return reply(.waiting,"A profile confirmation is open. No control change was made.")
            }
        }
        if browserProfileRemoval != nil {
            switch command.action {
            case .profileSave,.profileSaveAs,.profileRename,.profileLock,.profileOpen,.profileNew:
                return reply(.waiting,"Profile deletion is still finishing. No profile change was made; choose again after cleanup.")
            default:break
            }
        }
        switch command.action {
        case .help: return reply(.ok, ControlCommand.help)
        case .status: return reply(.ok, "Current isolated app state.")
        case .cueList:
            var state = controlState()
            for event in CueEvent.allCases {
                let value = CueSounds.shared.preferences.configuration(for: event)
                let variants = CueSounds.shared.variants(for: event)
                let key = "cue.\(event.rawValue)"
                state[key + ".enabled"] = String(value.enabled)
                state[key + ".scope"] = event.isProfileSetting ? "profile" : "machine"
                state[key + ".custom-file-present"] = String(value.customPath != nil)
                state[key + ".built-in"] = CueSounds.shared.preferences.builtInSelection(for: event, variants: variants) ?? ""
                state[key + ".choices"] = variants.joined(separator: "|")
            }
            return ControlReply(request: request, status: .ok, message: "Cue event IDs, choices and scopes; custom paths are private.", state: state)
        case .cueMute:
            cueMute.state = command.enabled ? .on : .off
            cueMuteChanged()
            return reply(.ok, "Turn all audio cues off is \(command.enabled ? "on" : "off"); profile unchanged.")
        case .cue:
            guard let selection = try? CueControlSelection(command.arguments["value"]!),
                CueSounds.shared.preferences.applyControl(selection, variants: CueSounds.shared.variants(for: selection.event)) else {
                return reply(.error, "Choose on, off, or a bundled filename advertised for this event by cue-list.")
            }
            refreshCueChoices()
            recordStartup("Audio cue control changed: \(selection.event.rawValue).")
            return reply(.ok, "Cue choice saved without playing a preview.")
        case .recording:
            if !command.enabled {
                session.stopRecording()
                return reply(.waiting, "Recording stop requested. Inspect status for completion.")
            }
            guard running else { return reply(.error, "Start the session before recording.") }
            if controlView?.recording == true { return reply(.ok, "Recording is already on.") }
            do { try beginRecording() }
            catch { return reply(.error, "Could not create the isolated recordings folder.") }
            return reply(.waiting, "Recording start requested. Inspect status and the isolated log for completion or failure.")
        case .recordingSource, .recordingFormat, .recordingChannels, .recordingSplit, .recordingBypass, .flacCompression:
            let value = command.arguments["value"]!
            if command.action == .recordingSource {
                guard let choice = RecordingSource(rawValue: value) else { return reply(.error, "Unsupported recording source.") }
                recordingSource.selectItem(withTitle: choice.label)
            } else if command.action == .recordingFormat {
                guard let choice = RecordingFormat(rawValue: value) else { return reply(.error, "Unsupported recording format.") }
                recordingFormat.selectItem(withTitle: choice.label)
            } else if command.action == .recordingChannels {
                guard let choice = RecordingChannels(rawValue: value) else { return reply(.error, "Unsupported recording channel choice.") }
                recordingChannels.selectItem(withTitle: choice.label)
            } else if command.action == .flacCompression {
                guard let level = Int(value), (0...FLACCompression.maximumLevel).contains(level) else {
                    return reply(.error, "Unsupported FLAC compression level.")
                }
                flacCompression.selectItem(at: level)
            } else if command.action == .recordingSplit { splitRecording.state = command.enabled ? .on : .off }
            else { recordingBypassShaping.state = command.enabled ? .on : .off }
            recordingSourceChanged()
            return reply(.ok, "Recording choice saved for the next recording.")
        case .metronomeToggle:
            if AppRuntime.configuration.isHeadless && !jam.view.connected
                && jam.view.metronomeRole == .solo && !jam.view.metronomePlaying
                && !AppRuntime.settings.bool(forKey: JamController.noServerMessageKey) {
                return reply(.waiting, "Use the visible Metronome menu to read the solo notice first.")
            }
            jam.startStop()
            return reply(.waiting, "Metronome toggle requested; followers toggle their local clicks. Inspect status.")
        case .metronomeMaster:
            guard !command.enabled || jam.view.connected else {
                return reply(.error, "Connect to a server before becoming the master metronome.")
            }
            jam.setMaster(command.enabled)
            return reply(.waiting, "Metronome master request sent. Inspect status for the observed role.")
        case .metronomeTempo:
            jam.tempo(Int(command.arguments["value"]!)! - jam.view.metronomeBpm)
            return reply(.waiting, "Metronome tempo requested. Inspect status for the observed tempo.")
        case .metronomeSignature, .metronomeVolume, .metronomeSound:
            let value = command.arguments["value"]!
            if command.action == .metronomeSignature {
                guard JamController.signatures.contains(value) else { return reply(.error, "Choose an advertised time signature.") }
                jam.setSignature(value)
            } else if command.action == .metronomeVolume {
                guard let volume = Int(value), JamController.volumes.contains(volume) else { return reply(.error, "Choose an advertised metronome volume.") }
                guard jam.setVolume(volume, announceFailure: false) else { return reply(.error, "The metronome volume could not be saved. Its previous value is retained.") }
            } else {
                guard jam.metronomeSounds.contains(value) else { return reply(.error, "Choose an advertised click sound.") }
                jam.setSound(value)
            }
            return reply(.ok, "Metronome menu choice saved.")
        case .metronomeHear:
            jam.setHearIn(command.arguments["value"] == "daw" ? .daw : .remSound)
            return reply(.ok, "Metronome heard \(jam.choices.hearIn.spoken).")
        case .metronomeRecord:
            jam.setIncludeInRecordings(command.enabled)
            return reply(.ok, "The click is \(jam.choices.includeInRecordings ? "included in" : "left out of") RemSound's recordings.")
        case .metronomeWhenAsked:
            let value = command.arguments["value"]!
            jam.setWhenAsked(value == "accept" ? .acceptAutomatically : value == "decline" ? .declineAutomatically : .ask)
            return reply(.waiting, "Metronome response choice requested. Inspect status.")
        case .profileList:
            do {
                let profiles = try profileStore.list()
                // Bound the listing below the transport's reply limit, including escaped Unicode titles.
                let maximumListedProfiles = 24
                var state = controlState()
                state["profile-count"] = String(profiles.count)
                state["profile-listed-count"] = String(min(profiles.count, maximumListedProfiles))
                state["profile-unreadable-count"] = String(profileStore.unreadable().count)
                for (index, profile) in profiles.prefix(maximumListedProfiles).enumerated() {
                    state["profile.\(index).id"] = profile.id.uuidString
                    state["profile.\(index).title"] = String(decoding: profile.title.utf8.prefix(320), as: UTF8.self)
                    state["profile.\(index).read-only"] = String(profile.readOnly)
                }
                return ControlReply(request: request, status: .ok,
                    message: "Saved profile identifiers and titles; unreadable files are left untouched.", state: state)
            } catch { return reply(.error, "Could not read the isolated profile list.") }
        case .profileSave, .profileSaveAs, .profileRename, .profileLock:
            if command.action != .profileSaveAs && activeProfile == nil {
                return reply(.waiting, "Save this setup with profile-save-as --value title first.")
            }
            if command.action == .profileSave && activeProfile?.readOnly == true
                && !AppRuntime.settings.bool(forKey: "suppressReadOnlySaveWarning") {
                return reply(.waiting, "Read-only overwrite needs the visible confirmation. Use profile-save-as for a separate copy.")
            }
            guard retireBrowserBeforeProfilePrompt() else {return reply(.waiting,"Wait for browser cleanup, then choose the profile change again.")}
            do {
                switch command.action {
                case .profileSave: try persistCurrentProfile()
                case .profileSaveAs: try persistProfileAs(command.arguments["value"]!)
                case .profileRename: try persistProfileTitle(command.arguments["value"]!)
                case .profileLock: try persistProfileLock(command.enabled)
                default: break
                }
                return reply(.ok, "Profile change saved.")
            } catch let error as ProfileStoreError { return reply(.error, error.localizedDescription) }
            catch { return reply(.error, "Could not save the isolated profile. The current setup was retained.") }
        case .profileOpen, .profileNew:
            guard !running && start.isEnabled else {
                return reply(.waiting, "Stop the session before switching profiles.")
            }
            guard !hasUnsavedProfileChanges else {
                return reply(.waiting, "Save the current setup first, or use the visible profile menu to discard it.")
            }
            guard retireBrowserBeforeProfilePrompt() else {return reply(.waiting,"Wait for browser cleanup, then choose the profile selection again.")}
            do {
                let selected = command.action == .profileOpen
                    ? try profileStore.load(id: UUID(uuidString: command.arguments["value"]!)!) : nil
                guard clearDiscardedDraftPassword() else {
                    return reply(.error, "Could not clear the isolated draft password.")
                }
                guard prepareProfileMutation() else {return reply(.waiting,"Profile selection was not applied. Wait for cleanup, then choose again.")}
                if let selected {
                    guard showProfile(selected,browserContextAlreadyRetired:true) else {return reply(.waiting,"Profile selection was not applied.")}
                } else {
                    guard resetToBlankProfile(inheritingCues:CueSounds.shared.preferences.profileConfigurations,browserContextAlreadyRetired:true) else {return reply(.waiting,"New profile was not applied.")}
                    CueSounds.shared.profileOpened()
                }
                return reply(.ok, "Profile selected. The session stays stopped; set the password and use start explicitly.")
            } catch { return reply(.error, "Could not open that isolated profile. The current setup was retained.") }
        case .devices:
            var state = controlState()
            for (kind, choices) in [("input", inputChoices), ("output", outputChoices), ("system", systemOutputs)] {
                state["\(kind)-count"] = String(choices.count)
                for (index, choice) in choices.enumerated() {
                    state["\(kind).\(index).uid"] = choice.uid
                    state["\(kind).\(index).name"] = choice.name
                    let selected = kind == "input" ? selectedInputUIDs.contains(choice.uid)
                        : kind == "output" ? selectedOutputUIDs.contains(choice.uid)
                        : selectedCaptureUIDs == nil || selectedCaptureUIDs!.contains(choice.uid)
                    state["\(kind).\(index).selected"] = String(selected)
                }
            }
            for (kind, choices) in [("input", inputPairChoices), ("output", outputPairChoices), ("system", systemOutputPairChoices)] {
                state["\(kind)-pair-count"] = String(choices.count)
                for (index, choice) in choices.enumerated() {
                    state["\(kind)-pair.\(index).uid"] = choice.uid
                    state["\(kind)-pair.\(index).name"] = choice.name
                    state["\(kind)-pair.\(index).index"] = String(choice.pair)
                    let devices = kind == "input" ? selectedInputUIDs
                        : kind == "output" ? selectedOutputUIDs : selectedCaptureUIDs ?? []
                    let pairs = kind == "input" ? selectedInputChannelPairs
                        : kind == "output" ? selectedOutputChannelPairs : selectedCaptureChannelPairs
                    state["\(kind)-pair.\(index).selected"] = String(devices.contains(choice.uid)
                        && (pairs[choice.uid] ?? [0]).contains(choice.pair))
                }
            }
            return ControlReply(request: request, status: .ok, message: "Advertised devices and selected state.", state: state)
        case .password, .name, .peer:
            guard !running && start.isEnabled else { return reply(.error, "Stop the session before changing connection fields.") }
            if command.action == .password { startupRequests.invalidate();password.stringValue = command.arguments["password"]! }
            else if command.action == .name { name.stringValue = command.arguments["value"]! }
            else { peer.stringValue = command.arguments["value"]! }
            return reply(.ok, "Connection field changed; password values are never returned.")
        case .start:
            if running { return reply(.ok, "The session is already running.") }
            guard start.isEnabled else { return reply(.waiting, "The session is already starting.") }
            guard !password.stringValue.isEmpty else { return reply(.waiting, "Set the shared password through piped standard input first.") }
            if let issue = headlessPermissionIssue() { return reply(.waiting, issue) }
            startSession()
            return reply(.waiting, "Start requested. Use status to inspect the observed session state.")
        case .stop:
            stopSession()
            return reply(.waiting, "Stop requested. Use status to inspect the observed session state.")
        case .show:
            showWindow()
            return reply(.ok, "The isolated app is visible; its configuration remains separate.")
        case .quit:
            guard AppRuntime.configuration.isHeadless else {
                return reply(.waiting, "The visible app may have unsaved work. Quit it from its menu.")
            }
            guard !running && start.isEnabled && controlView?.recordingFinishing != true else {
                return reply(.waiting, "Stop the session and wait until recording-finishing is false before quitting.")
            }
            scheduleTermination()
            return reply(.ok, "Isolated headless app shutdown requested.")
        case .serverConnect:
            guard running || start.isEnabled else { return reply(.waiting, "The session is already starting.") }
            guard running || !password.stringValue.isEmpty else {
                return reply(.waiting, "Set the shared password through piped standard input first.")
            }
            if let issue = headlessPermissionIssue() { return reply(.waiting, issue) }
            jam.connect(command.arguments["value"]!)
            return reply(.waiting, "Server connection requested. Use status to inspect server-connected.")
        case .serverDisconnect:
            jam.disconnect()
            return reply(.waiting, "Server disconnection requested. Direct peer choices remain active.")
        case .selfMonitor:
            if command.enabled && AppRuntime.configuration.isHeadless
                && !AppRuntime.settings.bool(forKey: JamController.selfMonitoringWarningKey) {
                return reply(.waiting, "Use the visible app to read the self-monitoring feedback warning first.")
            }
            if command.enabled && (!running || !jam.view.connected) {
                return reply(.error, "Start RemSound and connect to a server before self-monitoring.")
            }
            jam.setSelfMonitoring(command.enabled)
            return reply(.waiting, "Self-monitoring requested. It also requires active sending and receiving; inspect status.")
        case .systemAll:
            if command.enabled && AppRuntime.configuration.isHeadless
                && !(systemAudioAccessChecked && systemAudioAccessAvailable) {
                return reply(.waiting, "System audio permission needs a visible access check. Use show, then Preferences, Permissions.")
            }
            if (selectedCaptureUIDs == nil) != command.enabled { toggleSystemOutput(0) }
            return reply(running ? .waiting : .ok, "All-system-output choice applied through its existing handler.")
        case .inputPair, .outputPair, .systemPair:
            let uid = command.arguments["device"]!, pair = Int(command.arguments["pair"]!)!
            let choices = command.action == .inputPair ? inputPairChoices
                : command.action == .outputPair ? outputPairChoices : systemOutputPairChoices
            guard let index = choices.firstIndex(where: { $0.uid == uid && $0.pair == pair }) else {
                return reply(.error, "The channel pair is not advertised for this device.")
            }
            if command.enabled && AppRuntime.configuration.isHeadless {
                if command.action == .inputPair && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                    return reply(.waiting, "Microphone permission needs a visible app. Use show, then Preferences, Permissions.")
                }
                if command.action == .systemPair && !(systemAudioAccessChecked && systemAudioAccessAvailable) {
                    return reply(.waiting, "System audio permission needs a visible access check. Use show, then Preferences, Permissions.")
                }
            }
            let devices = command.action == .inputPair ? selectedInputUIDs
                : command.action == .outputPair ? selectedOutputUIDs : selectedCaptureUIDs ?? []
            let pairs = command.action == .inputPair ? selectedInputChannelPairs
                : command.action == .outputPair ? selectedOutputChannelPairs : selectedCaptureChannelPairs
            let selected = devices.contains(uid) && (pairs[uid] ?? [0]).contains(pair)
            if selected != command.enabled {
                if command.action == .inputPair { toggleInputPair(index) }
                else if command.action == .outputPair { toggleOutputPair(index) }
                else { toggleSystemOutputPair(index) }
            }
            return reply(running ? .waiting : .ok, "Channel pair applied through its existing selection handler.")
        case .packetSize:
            let value = command.arguments["value"]!
            guard let choice = SendPacketSize(rawValue: value) else {
                return reply(.error, "Choose Standard or Small sending packet size.")
            }
            packetSize.selectItem(withTitle: choice.label)
            audioOptionsChanged()
            return reply(running ? .waiting : .ok, "Sending packet size applied through its existing handler.")
        case .codec:
            let value = command.arguments["value"]!
            guard SendCodec(rawValue: value) != nil,
                let index = codec.itemArray.firstIndex(where: { ($0.representedObject as? String) == value }) else {
                return reply(.error, "Choose an advertised sending codec.")
            }
            codec.selectItem(at: index)
            audioOptionsChanged()
            return reply(running ? .waiting : .ok, "Sending codec applied through its existing handler.")
        case .artifact:
            selectReceiveArtifact(command.arguments["value"]! == "noise" ? .noiseBurst : .click)
            receiveArtifactChanged()
            return reply(running ? .waiting : .ok, "Receive gap sound applied through its existing handler.")
        case .jitter, .smoothness, .autoTuneInterval:
            let value = Int(command.arguments["value"]!)!
            let popup = command.action == .jitter ? receiveJitter
                : command.action == .smoothness ? receiveSmoothness : receiveAutoTuneInterval
            guard let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? Int) == value }) else {
                return reply(.error, "Choose an advertised receive tuning value.")
            }
            popup.selectItem(at: index)
            if command.action == .jitter { receiveJitterChanged() }
            else if command.action == .smoothness { receiveSmoothnessChanged() }
            else { receiveAutoTuneChanged() }
            return reply(running ? .waiting : .ok, "Receive tuning applied through its existing handler.")
        case .autoTune:
            receiveAutoTune.state = command.enabled ? .on : .off
            receiveAutoTuneChanged()
            return reply(running ? .waiting : .ok, "Receive auto-tune applied through its existing handler.")
        case .pluginInstall, .pluginRemove:
            let root = PluginInstaller.targetRoot(AppRuntime.configuration)
            let outcome = command.action == .pluginInstall
                ? PluginInstaller.install(from: PluginInstaller.sourceFolder(), to: root) : PluginInstaller.remove(from: root)
            refreshPluginMenu()
            switch outcome {
            case .installed, .removed: return reply(.ok, outcome.message)
            default: return reply(.error, outcome.message)
            }
        case .pluginShaping:
            setPluginShaping(command.enabled)
            return reply(.ok, command.enabled ? "Pan and EQ applied to plugin audio." : "Plugin audio is raw.")
        case .autoTuneLowestDelay:
            receiveLowestDelay.state = command.enabled ? .on : .off
            receiveLowestDelayChanged()
            return reply(running ? .waiting : .ok, "Lowest-delay auto-tune \(command.enabled ? "on" : "off").")
        case .inputSelect, .outputSelect, .systemSelect:
            let uid = command.arguments["device"]!
            let choices = command.action == .inputSelect ? inputChoices
                : command.action == .outputSelect ? outputChoices : systemOutputs
            guard let index = choices.firstIndex(where: { $0.uid == uid }) else { return reply(.error, "The device is not advertised in this list.") }
            if command.enabled && AppRuntime.configuration.isHeadless {
                if command.action == .inputSelect && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                    return reply(.waiting, "Microphone permission needs a visible app. Use show, then Preferences, Permissions.")
                }
                if command.action == .systemSelect && !(systemAudioAccessChecked && systemAudioAccessAvailable) {
                    return reply(.waiting, "System audio permission needs a visible access check. Use show, then Preferences, Permissions.")
                }
            }
            let selected = command.action == .inputSelect ? selectedInputUIDs.contains(uid)
                : command.action == .outputSelect ? selectedOutputUIDs.contains(uid)
                : selectedCaptureUIDs == nil || selectedCaptureUIDs!.contains(uid)
            if selected != command.enabled {
                if command.action == .inputSelect { toggleAudioInput(index) }
                else if command.action == .outputSelect { togglePlaybackOutput(index) }
                else { toggleSystemOutput(index + 1) }
            }
            return reply(running ? .waiting : .ok, "Device choice applied through the audio selection handler.")
        case .inputSend, .systemSend, .receive, .daw, .macOutput:
            if command.enabled && AppRuntime.configuration.isHeadless {
                if command.action == .inputSend && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                    return reply(.waiting, "Microphone permission needs a visible app. Use show, then Preferences, Permissions.")
                }
                if command.action == .systemSend && !(systemAudioAccessChecked && systemAudioAccessAvailable) {
                    return reply(.waiting, "System audio permission needs a visible access check. Use show, then Preferences, Permissions.")
                }
            }
            let control: NSButton
            switch command.action {
            case .inputSend: control = send
            case .systemSend: control = systemAudio
            case .receive: control = receive
            case .daw: control = plugins
            default: control = monitor
            }
            control.state = command.enabled ? .on : .off
            audioOptionsChanged()
            refreshStatusItem()
            guard (control.state == .on) == command.enabled else { return reply(.error, "Choose at least one source or output for this audio direction.") }
            return reply(running ? .waiting : .ok, "Audio option applied through its existing handler.")
        }
    }
}

#if DEBUG
@MainActor
private final class PushToTalkPreviewFixtureOutput: PushToTalkPreviewOutput {
    var plays = 0, stops = 0
    func play() -> Bool { plays += 1; return true }
    func stop() { stops += 1 }
}
@MainActor
private final class PushToTalkOwnerFixtureBackend: PushToTalkRegistrationBackend {
    final class Token: PushToTalkRegistrationLifetime {
        var stops = 0
        func stop() { stops += 1 }
    }
    struct Attempt {
        let receive: (PushToTalkNativeKeyEvent) -> Bool
        let token: Token
    }
    struct Refused: LocalizedError { var errorDescription: String? { "Isolated owner listener refusal." } }
    var attempts: [Attempt] = []
    var calls = 0
    var failNext = false
    func install(receive: @escaping (PushToTalkNativeKeyEvent) -> Bool,
                 disabled: @escaping () -> Void) throws -> PushToTalkRegistrationLifetime {
        calls += 1
        if failNext { failNext = false; throw Refused() }
        let token = Token(); attempts.append(.init(receive: receive, token: token)); return token
    }
}
#endif
