import AppKit
import RemSoundCore
import RemSoundJam
import SwiftUI

/// The Server and Metronome menus and the Server window, joined to the session (2026-09-29). The menus are SwiftUI
/// (AppEntry.swift) and read this; the window is AppKit (ServerWindowController.swift).
///
/// Ed's server window rules (2026-09-29): the remembered servers come first, then the box to type one; connecting closes
/// the window, silently (the keyboard goes back where it was); and the people on a server are listed only while you are
/// connected to it - on the Mac they appear in the peer list, marked "(on the server)", only then.
@MainActor
final class JamController: ObservableObject {
    @Published private(set) var view = JamView(connected: false, server: "", serverStatus: "Not connected to a server.",
                                               metronomeRole: .solo, metronomePlaying: false, metronomeLine: "stopped",
                                               metronomeBpm: 120, whenAsked: .ask)
    private weak var session: Session?
    private var serverWindow: ServerWindowController?
    private var latestServerView: JamView?
    private var serverReleaseLookup: ServerReleaseLookup?
    private var serverVersionWindow: ServerVersionWarningWindow?
    private var activeServerWarning: ServerVersionWarning?
    private var serverNotice: ServerConnectionNotice?
    private var shuttingDown = false
    var connectionNoticeLog: ((String) -> Void)?
    /// Stopped owner fixtures inject a presenter; production never uses this to bypass native isolation.
    var serverWarningPresenter: ((ServerVersionWarning, @escaping (Bool) -> Void) -> Void)?
    var connectUsingProfile: ((String) -> Void)?
    var guiShown: (() -> Void)?
    var contextHelp: ((Bool, NSWindow) -> Void)?
    weak var alertHelpDelegate: NSAlertDelegate?
    var volumeChanged: (() -> Void)?
    var selfMonitoringChanged: ((Bool, String) -> Void)?
    private var selfMonitoringRequestID = UUID()
    static let selfMonitoringWarningKey = "RemSoundSelfMonitoringWarningHidden"
    static let selfMonitoringWarning = "The server will send your own sound back to you, so you hear the whole round trip. Use headphones. Don't send a loopback of what you hear while it's on, such as your interface's loopback channels or an app capturing RemSound's output. Your sound would go round and round and build into feedback."
    var selfMonitoringTitle: String { view.selfMonitoring ? "Mute myself" : "Unmute myself to test round trip" }

    static let rememberedServersKey = "RemSoundRememberedServers"
    static let noServerMessageKey = "RemSoundMetronomeNoServerMessageHidden"
    static let serverNoticeKey = ServerConnectionNotice.settingsKey
    static let serverExplanation = "Connect starts RemSound if needed, using the current profile's password and audio settings. The server lists only people with the same password. Select each other to exchange audio. Existing selected peers remain active; Disconnect leaves only the server."

    // Jamming at speed and the detailed log, kept for next time.
    static let bufferFramesKey = "RemSoundCoreAudioBufferFrames"
    static let logFolderKey = "RemSoundLogFolder"
    static let keepsInTimeKey = "RemSoundKeepsInTime"
    static let signatureKey = "RemSoundMetronomeSignature"
    static let volumeKey = "RemSoundMetronomeVolume"
    static let soundKey = "RemSoundMetronomeSound"
    /// Jamulus-style 64-sample frames are automatic, as on Windows since 6.1 (Ed, 2026-10-01: the switch "is supposed to be
    /// automatic now. so that needs coming out"). Windows' rule is "64 samples whenever both ends are on ASIO"; every Mac
    /// plays through Core Audio, the Mac's ASIO, so it always says it can take them, and sends them to everyone who says
    /// the same. The old Jamming menu switch (and its RemSoundJamulusStyle setting) is gone.
    let jamulusStyle = true
    @Published private(set) var bufferFrames = AppRuntime.settings.integer(forKey: JamController.bufferFramesKey)
    // On unless it has been unticked: a key never set reads as on.
    @Published private(set) var keepsInTime = AppRuntime.settings.object(forKey: JamController.keepsInTimeKey) as? Bool ?? true
    @Published private(set) var volume = min(100, max(0, AppRuntime.settings.object(forKey: JamController.volumeKey) as? Int ?? ConnectionProfile.defaultMetronomeVolume))
    /// The profile's metronome settings (Windows MetronomeSettings). Before profiles kept them, the signature and sound
    /// were this Mac's: a profile saved then starts from those.
    @Published private(set) var choices = JamController.legacyChoices()
    var signature: String { choices.signature.description }
    var sound: String { choices.sound }
    static let signatures = MetronomeSignature.offered.map(\.description)
    private var metronomeWindow: MetronomeSettingsWindow?
    private let soundPreview = MetronomeSoundPreview()
    /// A change of the profile's metronome settings (the window's OK, the tempo keys).
    var choicesChanged: (() -> Void)?
    /// The metronome's five global keys, for its settings window, and keeping those it changed (AppDelegate owns them).
    var metronomeKeys: (() -> [HotkeyDescriptor?])?
    var keepMetronomeKeys: (([HotkeyDescriptor?]) -> String?)?

    static func legacyChoices() -> MetronomeChoices {
        var c = MetronomeChoices()
        let parts = (AppRuntime.settings.string(forKey: signatureKey) ?? "4/4").split(separator: "/").compactMap { Int($0) }
        if parts.count == 2 { c.beatsPerBar = parts[0]; c.beatUnit = parts[1] }
        if let sound = AppRuntime.settings.string(forKey: soundKey), !sound.isEmpty { c.sound = sound }
        return c
    }
    static let volumes = [25, 50, 70, 100]
    static let bufferChoices = [0, 32, 64, 128, 256]

    func attach(session: Session) {
        serverNotice?.shutdown(); serverNotice = nil; shuttingDown = false
        self.session = session
        serverReleaseLookup?.shutdown()
        let lookup = ServerReleaseLookup(permitted: { AppRuntime.configuration?.isIsolated == false })
        serverReleaseLookup = lookup
        session.fetchServerRelease = { [weak lookup] completion in
            guard let lookup else { completion(nil); return {} }
            return lookup.latest(completion)
        }
        session.onServerVersionWarning = { [weak self] warning, answer in
            guard let self else { answer(false); return }
            self.askServerVersion(warning, answer: answer)
        }
        session.setJamulusStyle(jamulusStyle)
        session.setCoreAudioBufferFrames(bufferFrames)
        session.setKeepsInTime(keepsInTime)
        if AppRuntime.configuration.isIsolated { session.setLogFolder(AppRuntime.configuration.logsDirectory) }
        else if let folder = AppRuntime.settings.url(forKey: Self.logFolderKey) { session.setLogFolder(folder) }
        applyMetronomeSettings()
        session.setAcceptConnections(acceptConnections)
        session.onAcceptNotice = { [weak self] text in self?.announce(text) }
        // Nobody is there to answer in a headless or silent run: the session then leaves the person unticked, as Windows does.
        session.onAcceptQuestion = AppRuntime.configuration.isHeadless || AppRuntime.configuration.silent
            ? nil : { [weak self] question, answer in self?.askToAccept(question, answer: answer) ?? answer(false) }
        session.onJamChange = { [weak self] view in self?.changed(view) }
        session.onMetronomeNotice = { [weak self] text in self?.announce(text) }
        session.onMetronomeQuestion = { [weak self] name, leading, answer in self?.ask(name, whileLeading: leading, answer: answer) }
    }

    private func changed(_ new: JamView) {
        let wasConnected = view.connected
        let previousStatus = view.serverStatus
        latestServerView = new
        if let warning = activeServerWarning, !warning.isCurrent() { retireServerWarning() }
        selfMonitoringChanged?(new.selfMonitoring, new.selfMonitoringStatus)
        // The once-a-second measurements update their AppKit field without invalidating a focused SwiftUI menu.
        if new.connected != view.connected || new.server != view.server || new.serverStatus != view.serverStatus
            || new.metronomeRole != view.metronomeRole || new.metronomePlaying != view.metronomePlaying
            || new.metronomeLine != view.metronomeLine || new.metronomeBpm != view.metronomeBpm
            || new.whenAsked != view.whenAsked || new.selfMonitoring != view.selfMonitoring
            || new.pendingServer != view.pendingServer || new.masterName != view.masterName
            || new.masterBpm != view.masterBpm || new.masterSignature != view.masterSignature {
            view = new
        }
        serverWindow?.update(new)
        if new.serverStatus != previousStatus { announce(new.serverStatus) }
        // Windows' server sounds (PlayServerSound): on joining, and on leaving a server we were on.
        if new.connected != wasConnected { CueSounds.shared.play(new.connected ? .serverConnect : .serverDisconnect) }
        if new.connected && !wasConnected {
            remember(new.server)
            serverWindow?.closeAfterConnecting()
        }
    }

    #if DEBUG
    func serverVersionOwnerFailures(_ owner: Session) -> [String] {
        guard AppRuntime.configuration.isIsolated && AppRuntime.configuration.isHeadless,
              ProcessInfo.processInfo.environment["REMSOUND_TEST_PEER_MOVE_CHECK"] == "1" else { return ["Server owner fixture requires explicit isolated headless opt-in."] }
        var failures: [String] = []
        guard let warn = owner.onServerVersionWarning, let fetch = owner.fetchServerRelease else { return ["Actual owner must install version warning and release lookup."] }
        let signal = DispatchSemaphore(value: 0)
        var latest: String? = "pending"
        _ = fetch { latest = $0; signal.signal() }
        if signal.wait(timeout: .now() + 2) != .success || latest != nil { failures.append("Isolated actual release callback must return nil without native transport.") }
        var silentReplies: [Bool] = []
        let warning = ServerVersionWarning(requestID: UUID(), server: "isolated.current", version: "server-v2.16",
            latestReleased: "server-v2.17", beforeConnecting: true, isCurrent: { true })
        warn(warning) { silentReplies.append($0) }
        if silentReplies != [true] || serverVersionWindow != nil { failures.append("Default headless warning must continue before native construction.") }
        let presenterBefore = serverWarningPresenter
        defer { retireServerWarning(); serverWarningPresenter = presenterBefore }
        var presented = 0, fakeReply: ((Bool) -> Void)?, results: [Bool] = []
        serverWarningPresenter = { details, reply in
            presented += 1; fakeReply = reply
            if details.server != warning.server || details.latestReleased != warning.latestReleased { failures.append("Actual warning caller must retain current server/release facts.") }
        }
        warn(warning) { results.append($0) }; fakeReply?(true); fakeReply?(false)
        if presented != 1 || results != [true] { failures.append("Fake presenter must forward only one current decision.") }
        let stale = ServerVersionWarning(requestID: UUID(), server: "obsolete", version: nil, latestReleased: nil,
            beforeConnecting: true, isCurrent: { false })
        warn(stale) { _ in failures.append("Obsolete question must not answer.") }
        if presented != 1 { failures.append("Obsolete question must not be presented.") }
        let beforeView = latestServerView ?? view
        let beforeBook = AppRuntime.settings.object(forKey: Self.rememberedServersKey)
        let beforeNotice = AppRuntime.settings.object(forKey: Self.serverNoticeKey)
        let beforeConnect = connectUsingProfile
        defer {
            connectUsingProfile = beforeConnect; changed(beforeView)
            AppRuntime.settings.set(beforeBook, forKey: Self.rememberedServersKey)
            AppRuntime.settings.set(beforeNotice, forKey: Self.serverNoticeKey)
        }
        AppRuntime.settings.set(["isolated.current", "isolated.next"], forKey: Self.rememberedServersKey)
        AppRuntime.settings.set(true, forKey: Self.serverNoticeKey)
        var targets: [String] = []; connectUsingProfile = { targets.append($0) }
        changed(JamView(connected: true, server: "isolated.current", serverStatus: "On isolated.current.",
            metronomeRole: .solo, metronomePlaying: false, metronomeLine: "stopped", metronomeBpm: 120, whenAsked: .ask,
            serverDetails: "On isolated.current.\nYour round trip: 21 ms."))
        let dialog = ServerWindowController(controller: self)
        let beforeWindow = serverWindow; serverWindow = dialog
        defer { dialog.window?.close(); serverWindow = beforeWindow }
        dialog.update(view); dialog.reloadRemembered()
        func find(_ view: NSView) -> ServerListTable? {
            if let table = view as? ServerListTable { return table }
            for child in view.subviews { if let table = find(child) { return table } }
            return nil
        }
        guard let content = dialog.window?.contentView, let table = find(content) else { return failures + ["Actual native remembered table missing."] }
        func returnKey(_ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); table.keyDown(with: returnKey(36))
        if !targets.isEmpty { failures.append("Current remembered server Return must report already-on without reconnect.") }
        func progress(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.accessibilityLabel() == "Server connection progress" { return field }
            for child in view.subviews { if let field = progress(child) { return field } }
            return nil
        }
        if progress(content)?.stringValue != "Already on isolated.current." { failures.append("Current server selection must expose its already-on result.") }
        if progress(content)?.isHidden != false { failures.append("Already-on result must remain visible alongside connected details.") }
        changed(JamView(connected: true, server: "isolated.current", serverStatus: "On isolated.current.",
            metronomeRole: .solo, metronomePlaying: false, metronomeLine: "stopped", metronomeBpm: 120, whenAsked: .ask,
            serverDetails: "On isolated.current.\nYour round trip: 43 ms."))
        if progress(content)?.stringValue != "Already on isolated.current." || progress(content)?.isHidden != false {
            failures.append("Measurements must not hide or overwrite a focused explicit server action result.")
        }
        if !dialog.accessibilityFailures(expectedDetails: "On isolated.current.\nYour round trip: 43 ms.").isEmpty {
            failures.append("Explicit result and details must both remain reachable in native Tab/Shift-Tab order.")
        }
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false); table.keyDown(with: returnKey(76))
        if targets != ["isolated.next"] { failures.append("Different remembered server Return must reach current-profile connection owner.") }
        if dialog.window?.isVisible == true || serverVersionWindow != nil { failures.append("Actual owner fixtures must remain hidden and stopped.") }
        return failures
    }
    #endif

    // MARK: the Server menu and window

    var serverMenuTitle: String { view.connected ? "Disconnect from or Change Server…" : "Connect to Server…" }

    func serverAccessibilityFailures(expectedDetails: String? = nil) -> [String] {
        let window = ServerWindowController(controller: self)
        defer { window.window?.close() }
        window.update(latestServerView ?? view)
        window.reloadRemembered()
        return window.accessibilityFailures(expectedDetails: expectedDetails)
    }

    func showServerWindow() {
        AppRuntime.configuration.handOverToGUI()
        guiShown?()
        let window = serverWindow ?? ServerWindowController(controller: self)
        serverWindow = window
        window.update(latestServerView ?? view)
        window.reloadRemembered()
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    func serverNoticeOwnerFailures(stop: () -> Void, profileChange: () -> Void) -> [String] {
        @MainActor final class Dialog: ServerNoticePresentation {
            let answer: (Bool) -> Void
            var shows = 0, retires = 0
            init(_ answer: @escaping (Bool) -> Void) { self.answer = answer }
            func present() { shows += 1 }
            func retire() { retires += 1 }
            func showError(_ message: String) {}
        }
        var failures: [String] = [], assertions = 0
        func check(_ condition: Bool, _ message: String) { assertions += 1; if !condition { failures.append(message) } }
        guard let session, AppRuntime.configuration.isIsolated, AppRuntime.configuration.isHeadless else {
            return ["Notice owner fixture requires an isolated stopped headless Session."]
        }
        let choice = AppRuntime.settings.object(forKey: Self.serverNoticeKey)
        let originalRoute = connectUsingProfile, originalLog = connectionNoticeLog, originalPresenter = serverWarningPresenter
        var connections: [String] = [], logs: [String] = []
        defer {
            serverNotice?.shutdown(); serverNotice = nil; shuttingDown = false
            connectUsingProfile = originalRoute; connectionNoticeLog = originalLog; serverWarningPresenter = originalPresenter
            AppRuntime.settings.set(choice, forKey: Self.serverNoticeKey)
        }
        AppRuntime.settings.removeObject(forKey: Self.serverNoticeKey)
        connectUsingProfile = { connections.append($0) }; connectionNoticeLog = { logs.append($0) }
        let windows = NSApp.windows.count
        connect("isolated-first-server"); connect("isolated-second-server")
        check(connections == ["isolated-first-server", "isolated-second-server"], "Actual unsuppressed headless caller must continue through profile route.")
        check(logs.count == 2 && logs.allSatisfy { $0.contains("same password") }, "Actual unattended caller must log the readable notice.")
        check(AppRuntime.settings.object(forKey: Self.serverNoticeKey) == nil, "Unattended connect must not silently persist suppression.")
        check(NSApp.windows.count == windows, "Default unattended/isolation gate must construct no notice window.")
        connect("   "); check(connections.count == 2 && logs.count == 2, "Blank requests must construct and log nothing.")
        var dialog: Dialog?
        serverNotice?.shutdown()
        serverNotice = ServerConnectionNotice(settings: AppRuntime.settings, unattended: { false }, allowed: { true }, log: { logs.append($0) },
            makeDialog: { let value = Dialog($0); dialog = value; return value })
        connect("isolated-pending-stop"); let stopped = dialog
        check(stopped?.shows == 1 && connections.count == 2, "Actual caller must wait for an injected interactive notice.")
        stop(); stopped?.answer(true)
        check(stopped?.retires == 1 && connections.count == 2, "Actual Stop must retire notice and refuse old connect/save callback.")
        check(AppRuntime.settings.object(forKey: Self.serverNoticeKey) == nil, "Retired Stop response must not persist suppression.")
        connect("isolated-pending-profile"); let profiled = dialog; profileChange(); profiled?.answer(false)
        check(profiled?.retires == 1 && connections.count == 2, "Actual profile transition must refuse an old notice callback.")
        connect("isolated-pending-disconnect"); let disconnected = dialog; disconnect(); disconnected?.answer(false)
        check(disconnected?.retires == 1 && connections.count == 2, "Actual Disconnect must retire notice before any worker action.")
        connect("isolated-pending-quit"); let quitting = dialog; shutdown(); quitting?.answer(false); connect("isolated-after-quit")
        check(quitting?.retires == 1 && connections.count == 2, "Shutdown must retire current notice and refuse subsequent connect.")
        serverNotice = nil; connect("isolated-never-opened-after-quit")
        check(connections.count == 2 && serverNotice == nil, "Shutdown before notice construction must still refuse a new factory.")
        var versionResults: [Bool] = [], presentations = 0
        serverWarningPresenter = { _, _ in presentations += 1 }
        let warning = ServerVersionWarning(requestID: UUID(), server: "isolated-old-version", version: nil,
            latestReleased: nil, beforeConnecting: true, isCurrent: { true })
        session.onServerVersionWarning?(warning) { versionResults.append($0) }
        check(versionResults == [false] && presentations == 0, "A late version question must fail closed while the controller is shutting down.")
        shuttingDown = false
        print("Headless server notice owner assertions: \(assertions).")
        return failures
    }
    #endif

    func connect(_ entry: String) {
        guard !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !shuttingDown else { return }
        guard let session else {
            announce("The audio session is unavailable. Close and reopen RemSound before connecting.")
            return
        }
        if serverNotice == nil {
            serverNotice = ServerConnectionNotice(settings: AppRuntime.settings,
                unattended: { AppRuntime.configuration.silent || AppRuntime.configuration.isHeadless },
                allowed: { !AppRuntime.configuration.isIsolated },
                log: { [weak self] message in self?.connectionNoticeLog?(message) },
                makeDialog: { [weak self] answer in ServerConnectionNoticeWindow(contextHelp: self?.contextHelp, answer: answer) })
        }
        serverNotice?.begin { [weak self, weak session] in
            guard let self, let session, self.session === session else { return }
            if let connectUsingProfile = self.connectUsingProfile { connectUsingProfile(entry) }
            else { session.connectServer(entry) }
        }
    }
    func retireServerNotice() { serverNotice?.invalidate() }
    func connectRemembered(_ entry: String) {
        let typed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        if view.connected, typed.caseInsensitiveCompare(view.server.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame {
            showConnectionStatus("Already on \(view.server).")
            return
        }
        connect(typed)
    }
    func disconnect() { retireServerNotice(); retireServerWarning(); session?.disconnectServer() }

    private func askServerVersion(_ warning: ServerVersionWarning, answer: @escaping (Bool) -> Void) {
        guard warning.isCurrent() else { return }
        guard !shuttingDown else { answer(false); return }
        retireServerWarning()
        let finish: (Bool) -> Void = { [weak self] accepted in
            guard let self, warning.isCurrent(), self.activeServerWarning?.requestID == warning.requestID else { return }
            self.retireServerWarning()
            answer(accepted)
        }
        if let presenter = serverWarningPresenter {
            activeServerWarning = warning
            presenter(warning, finish)
            return
        }
        guard !AppRuntime.configuration.silent, !AppRuntime.configuration.isHeadless, !AppRuntime.configuration.isIsolated else {
            answer(true)
            return
        }
        activeServerWarning = warning
        let dialog = ServerVersionWarningWindow(server: warning.server, latestReleased: warning.latestReleased,
            isCurrent: warning.isCurrent, contextHelp: contextHelp, answer: finish)
        serverVersionWindow = dialog
        dialog.showWindow(nil)
        dialog.window?.makeKeyAndOrderFront(nil)
        dialog.window?.makeFirstResponder(dialog.message)
    }

    private func retireServerWarning() {
        serverVersionWindow?.retire(); serverVersionWindow = nil; activeServerWarning = nil
    }
    func shutdown() {
        shuttingDown = true
        serverNotice?.shutdown()
        retireServerWarning()
        serverReleaseLookup?.shutdown()
    }

    func showConnectionStatus(_ message: String) {
        serverWindow?.showActionStatus(message)
        announce(message)
    }

    var rememberedServers: [String] { AppRuntime.settings.stringArray(forKey: Self.rememberedServersKey) ?? [] }

    func remember(_ entry: String) {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let kept = [trimmed] + rememberedServers.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        AppRuntime.settings.set(Array(kept.prefix(20)), forKey: Self.rememberedServersKey)
    }

    func forget(_ entry: String) {
        AppRuntime.settings.set(rememberedServers.filter { $0 != entry }, forKey: Self.rememberedServersKey)
    }

    // MARK: the Metronome menu

    var metronomeStartStopTitle: String {
        view.metronomeRole == .follower ? "Mute or Unmute the Metronome" : (view.metronomePlaying ? "Stop Metronome" : "Start Metronome")
    }

    func makeSoloNotice() -> NSAlert { Self.buildSoloNotice(helpDelegate: alertHelpDelegate) }
    func makeSelfMonitoringWarning() -> NSAlert { Self.buildSelfMonitoringWarning(helpDelegate: alertHelpDelegate) }

    static func buildSoloNotice(helpDelegate: NSAlertDelegate? = nil) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Not connected to a server"
        alert.informativeText = "The metronome will click for you, but you're not connected to a server, so no one else will be able to hear your metronome."
        alert.addButton(withTitle: "OK")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Do not show me this message again"
        FocusedHelpContent.markAlert(alert, notice: "dialog-solo-metronome-notice", buttons: ["dialog-solo-metronome-accept"], helpDelegate: helpDelegate)
        alert.suppressionButton?.identifier = NSUserInterfaceItemIdentifier("help-dialog-solo-metronome-suppression")
        return alert
    }
    func startStop() {
        // With no server your own metronome clicks for you alone: say so, until told not to.
        if !view.connected && view.metronomeRole == .solo && !view.metronomePlaying
            && !AppRuntime.settings.bool(forKey: Self.noServerMessageKey) {
            guard !AppRuntime.configuration.isHeadless else {
                announce("Use the visible Metronome menu to read the solo metronome notice first.")
                return
            }
            let alert = makeSoloNotice()
            alert.runModal()
            if alert.suppressionButton?.state == .on { AppRuntime.settings.set(true, forKey: Self.noServerMessageKey) }
        }
        session?.metronomeStartStop()
    }

    var isMaster: Bool { view.metronomeRole == .master }
    func setMaster(_ on: Bool) { session?.setMetronomeMaster(on) }
    func tempo(_ delta: Int) {
        let bpm = min(Int(MetronomeTimeline.maxBpm), max(Int(MetronomeTimeline.minBpm), view.metronomeBpm + delta))
        session?.setMetronomeTempo(bpm)
        if view.metronomeRole != .follower && choices.bpm != bpm { choices.bpm = bpm; choicesChanged?() }
    }
    func setWhenAsked(_ answer: ServerMetronome.WhenAsked) {
        session?.setMetronomeWhenAsked(answer)
        let accept = answer == .acceptAutomatically
        if choices.acceptMasterAutomatically != accept { choices.acceptMasterAutomatically = accept; choicesChanged?() }
    }

    func speakMetronomeStatus() { announce("Metronome: \(view.metronomeLine).") }

    func toggleSelfMonitoring() {
        setSelfMonitoring(!view.selfMonitoring)
    }

    static func buildSelfMonitoringWarning(helpDelegate: NSAlertDelegate? = nil) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Hearing yourself through the server"
        alert.informativeText = Self.selfMonitoringWarning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Do not show me this message again"
        FocusedHelpContent.markAlert(alert, notice: "dialog-self-monitor-notice", buttons: ["dialog-self-monitor-accept", "dialog-self-monitor-cancel"], helpDelegate: helpDelegate)
        alert.suppressionButton?.identifier = NSUserInterfaceItemIdentifier("help-dialog-self-monitor-suppression")
        return alert
    }
    func setSelfMonitoring(_ on: Bool) {
        let requestID = UUID()
        selfMonitoringRequestID = requestID
        guard let session else { return }
        if !on { session.setSelfMonitoring(false); return }
        guard !view.selfMonitoring else { return }
        if AppRuntime.configuration.isHeadless && !AppRuntime.settings.bool(forKey: Self.selfMonitoringWarningKey) {
            announce("Open the visible app to read the self-monitoring feedback warning first.")
            return
        }
        session.selfMonitoringReadiness { [weak self, weak session] reason in
            // An off request made while readiness is queued must not be undone by a late on callback.
            guard let self, let session, self.selfMonitoringRequestID == requestID else { return }
            if let reason { self.announce(reason); return }
            if !AppRuntime.settings.bool(forKey: Self.selfMonitoringWarningKey) {
                let alert = self.makeSelfMonitoringWarning()
                guard alert.runModal() == .alertFirstButtonReturn else {
                    self.announce("Self-monitoring off. Cancelled.")
                    return
                }
                if alert.suppressionButton?.state == .on {
                    AppRuntime.settings.set(true, forKey: Self.selfMonitoringWarningKey)
                }
            }
            guard self.selfMonitoringRequestID == requestID else { return }
            session.setSelfMonitoring(true)
        }
    }

    func setKeepsInTime(_ on: Bool) {
        keepsInTime = on
        AppRuntime.settings.set(on, forKey: Self.keepsInTimeKey)
        session?.setKeepsInTime(on)
    }

    func setBufferFrames(_ frames: Int) {
        bufferFrames = frames
        AppRuntime.settings.set(frames, forKey: Self.bufferFramesKey)
        session?.setCoreAudioBufferFrames(frames)
    }

    func bufferLabel(_ frames: Int) -> String {
        frames == 0 ? "As the Devices Are" : "\(frames) Samples (\(String(format: "%.1f", Double(frames) / 48)) ms)"
    }

    func setSignature(_ text: String) {
        let parts = text.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        choices.beatsPerBar = parts[0]; choices.beatUnit = parts[1]
        applyMetronomeSettings()
        choicesChanged?()
    }

    @discardableResult
    func setVolume(_ percent: Int, announceFailure: Bool = true) -> Bool {
        let accepted = min(100, max(0, percent))
        guard AppRuntime.settings.setValues([Self.volumeKey: accepted]) else {
            if announceFailure { announce("The metronome volume could not be saved. Its previous value is retained.") }
            return false
        }
        volume = accepted
        applyMetronomeSettings()
        volumeChanged?()
        return true
    }

    func setSound(_ name: String) {
        choices.sound = name
        applyMetronomeSettings()
        choicesChanged?()
    }

    private func applyMetronomeSettings() { session?.setMetronomeChoices(choices, volume: volume) }

    func setHearIn(_ hearIn: MetronomeHearIn) {
        guard choices.hearIn != hearIn else { return }
        choices.hearIn = hearIn
        applyMetronomeSettings()
        choicesChanged?()
    }

    func setIncludeInRecordings(_ on: Bool) {
        guard choices.includeInRecordings != on else { return }
        choices.includeInRecordings = on
        applyMetronomeSettings()
        choicesChanged?()
    }

    /// A profile opening: its metronome settings, or this Mac's old ones for a profile saved before profiles kept them.
    func loadProfileMetronome(_ saved: MetronomeChoices?) {
        choices = saved ?? Self.legacyChoices()
        applyMetronomeSettings()
    }

    /// The sounds on offer: the shipped five, then a person's own from the Metronome sounds folder.
    var metronomeSounds: [String] {
        let folders = Session.metronomeSoundFolders(AppRuntime.configuration)
        return MetronomeSoundLibrary.names(shipped: folders.shipped, user: folders.user)
    }

    /// Metronome > Metronome Settings (Windows' "Metronome settings..."). One window at a time.
    func showMetronomeSettings() {
        if let window = metronomeWindow?.window { window.makeKeyAndOrderFront(nil); return }
        let folders = Session.metronomeSoundFolders(AppRuntime.configuration)
        let master: (name: String, bpm: Int, signature: MetronomeSignature)? = view.metronomeRole == .follower
            ? (view.masterName ?? "Someone", view.masterBpm ?? view.metronomeBpm, view.masterSignature ?? choices.signature) : nil
        let controller = MetronomeSettingsWindow(
            choices: choices, volume: volume, sounds: metronomeSounds, master: master,
            keys: metronomeKeys?() ?? [],
            state: { [weak self] in
                guard let self else { return .init(playing: false, following: false, muted: false) }
                return .init(playing: self.view.metronomePlaying, following: self.view.metronomeRole == .follower,
                             muted: self.view.metronomeMuted)
            },
            startStop: { [weak self] in self?.startStop() },
            heardLive: { [weak self] live, liveVolume in self?.session?.setMetronomeChoices(live, volume: liveVolume) },
            loadSound: { MetronomeSoundLibrary.load($0, shipped: folders.shipped, user: folders.user) },
            preview: { [weak self] sound, beatMs, gain in self?.soundPreview.play(sound, beatMs: beatMs, gain: gain) },
            contextHelp: contextHelp,
            finishWith: { [weak self] accepted, kept, keptVolume, startedHere, keys in
                guard let self else { return }
                if accepted, let problem = self.keepMetronomeKeys?(keys) { self.announce(problem) }
                self.soundPreview.stop()
                self.metronomeWindow = nil
                if !accepted && startedHere && self.view.metronomePlaying { self.session?.metronomeStartStop() }
                let changed = kept != self.choices || keptVolume != self.volume
                self.choices = kept
                if keptVolume != self.volume { _ = self.setVolume(keptVolume) } else { self.applyMetronomeSettings() }
                if accepted && changed { self.choicesChanged?() }
            })
        metronomeWindow = controller
        controller.window?.center()
        controller.showWindow(nil)
    }

    /// Save the last minute of the network, for Ed's simulator: said aloud where it went.
    func saveNetworkRecording() {
        session?.saveNetworkRecording { [weak self] _, said in self?.announce(said) }
    }

    /// Where the detailed log goes: Andre can put it in Dropbox, so Ed reads it as it is written.
    func chooseLogFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose where RemSound writes its detailed log."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppRuntime.settings.set(url, forKey: Self.logFolderKey)
        session?.setLogFolder(url)
        announce("The log now goes to \(url.lastPathComponent).")
    }

    /// Accept connections from other peers (Preferences), machine-wide as on Windows: Ask me each time unless changed.
    @Published private(set) var acceptConnections =
        AcceptConnections(rawValue: AppRuntime.settings.string(forKey: AcceptConnections.settingsKey) ?? "") ?? .default

    func setAcceptConnections(_ mode: AcceptConnections) {
        acceptConnections = mode
        AppRuntime.settings.set(mode.rawValue, forKey: AcceptConnections.settingsKey)
        session?.setAcceptConnections(mode)
    }

    /// Somebody on our password has ticked us: Windows' question, in front of whatever is on screen.
    private func askToAccept(_ question: String, answer: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = "Do you want to allow this?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        NSApp.activate(ignoringOtherApps: true)
        answer(alert.runModal() == .alertFirstButtonReturn)
    }

    private func ask(_ name: String, whileLeading: Bool, answer: @escaping (Bool) -> Void) {
        guard !AppRuntime.configuration.isHeadless else { answer(false); return }
        let alert = NSAlert()
        alert.messageText = whileLeading
            ? "\(name) would like to take over as the master metronome."
            : "\(name) would like to be the master metronome."
        alert.informativeText = whileLeading
            ? "Hand over? You will follow their metronome."
            : "Follow their metronome? Your clicks will come from the server's beat."
        alert.addButton(withTitle: whileLeading ? "Hand Over" : "Follow")
        alert.addButton(withTitle: "No")
        NSApp.activate(ignoringOtherApps: true)
        answer(alert.runModal() == .alertFirstButtonReturn)
    }

    func announce(_ text: String) {
        guard !AppRuntime.configuration.silent else { return }
        let element: Any = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp as Any
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
