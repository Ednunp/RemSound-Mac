import AppKit
import AVFoundation
import Carbon
import RemSoundCore
import RemSoundJam

/// METRONOME SETTINGS (Windows MetronomeSettingsDialog; Ed, 2026-09-28: "you select what time sig it is, plus you select a
/// sound to play, plus you set whether you want to hear it in recording or daw"), from the Metronome menu. First the
/// metronome itself (Ed, 2026-10-02): Listen, or Stop once playing - Mute and Unmute while following a master - and every
/// change heard at once. Then the tempo, the time signature, the click sound (moving along the list plays it), its volume,
/// where you hear it, whether RemSound's recordings carry it, and what happens when someone asks to be the master
/// metronome. All of it is the profile's. While you follow a master its tempo and signature are theirs: shown, not changed
/// here, with a line saying whose. OK keeps the changes; Cancel and Escape put the profile's settings back, and stop a
/// metronome this window started.
@MainActor
final class MetronomeSettingsWindow: NSWindowController, NSWindowDelegate {
    struct State { var playing: Bool; var following: Bool; var muted: Bool }

    let listen = NSButton(title: "Listen to the metronome", target: nil, action: nil)
    let tempo = NSTextField(string: "")
    let tempoStepper = NSStepper()
    let signature = NSPopUpButton()
    let masterNote = NSTextField(wrappingLabelWithString: "")
    let sound = NSPopUpButton()
    let volume = ResettableSlider.metronomeVolume()
    let hear = NSPopUpButton()
    let record = NSButton(checkboxWithTitle: "Include the click in RemSound's recordings", target: nil, action: nil)
    let ask = NSPopUpButton()
    /// The metronome's own shortcut keys (Ed, 2026-10-01: "a little mini hotkeys in the metronome settings for just the
    /// metronome hotkeys"): the same keys as their rows in Preferences, kept on this Mac.
    let keyFields = (0..<5).map { _ in HotkeyCaptureField() }
    static let keyNames = ["Start or stop the metronome (mute or unmute while following a master)", "Tempo up a beat a minute",
                           "Tempo down a beat a minute", "Volume up", "Volume down"]
    let ok = NSButton(title: "OK", target: nil, action: nil), cancel = NSButton(title: "Cancel", target: nil, action: nil)

    private(set) var working: MetronomeChoices
    private(set) var workingVolume: Int
    private let initial: MetronomeChoices
    private let initialVolume: Int
    private let soundNames: [String]
    private let following: Bool
    private let state: () -> State
    private let startStop: () -> Void
    private let heardLive: (MetronomeChoices, Int) -> Void
    private let finishWith: (_ accepted: Bool, _ choices: MetronomeChoices, _ volume: Int, _ startedHere: Bool,
                             _ keys: [HotkeyDescriptor?]) -> Void
    private let initialKeys: [HotkeyDescriptor?]
    private let preview: (MetronomeClickSound?, Int, Float) -> Void
    private let loadSound: (String) -> MetronomeClickSound?
    private var watch: Timer?
    private var finished = false
    /// True when this window's button started the metronome (and it is still going): Cancel stops it again.
    private(set) var startedHere = false

    /// - Parameters:
    ///   - master: while following, the master's name, tempo and signature - shown instead of the profile's.
    ///   - finishWith: OK (true) or Cancel (false), with the settings to keep or to put back.
    init(choices: MetronomeChoices, volume: Int, sounds: [String], master: (name: String, bpm: Int, signature: MetronomeSignature)?,
         keys: [HotkeyDescriptor?],
         state: @escaping () -> State, startStop: @escaping () -> Void,
         heardLive: @escaping (MetronomeChoices, Int) -> Void,
         loadSound: @escaping (String) -> MetronomeClickSound?,
         preview: @escaping (MetronomeClickSound?, Int, Float) -> Void,
         contextHelp: ((Bool, NSWindow) -> Void)? = nil,
         finishWith: @escaping (Bool, MetronomeChoices, Int, Bool, [HotkeyDescriptor?]) -> Void) {
        working = choices; initial = choices
        initialKeys = (0..<5).map { $0 < keys.count ? keys[$0] : nil }
        workingVolume = min(100, max(0, volume)); initialVolume = workingVolume
        soundNames = sounds.isEmpty ? MetronomeSoundLibrary.shippedNames : sounds
        following = master != nil
        self.state = state; self.startStop = startStop; self.heardLive = heardLive
        self.loadSound = loadSound; self.preview = preview; self.finishWith = finishWith
        let panel = KeyboardWindow(contentRect: .init(x: 0, y: 0, width: 620, height: 470),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        panel.title = "Metronome settings"; panel.isReleasedWhenClosed = false
        super.init(window: panel)
        if let contextHelp {
            panel.contextHelp = { [weak panel] manual in
                guard let panel else { return }
                contextHelp(manual, panel)
            }
        }
        panel.delegate = self
        panel.dialogKey = { [weak self] event in self?.handleDialogKey(event) ?? false }
        panel.moveTabFocus = { [weak self] backwards in self?.moveFocus(backwards: backwards) ?? false }
        build(master: master)
        panel.initialFirstResponder = listen
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func build(master: (name: String, bpm: Int, signature: MetronomeSignature)?) {
        guard let content = window?.contentView else { return }
        let bpmRange = Double(MetronomeTimeline.minBpm)...Double(MetronomeTimeline.maxBpm)
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: bpmRange.lowerBound); formatter.maximum = NSNumber(value: bpmRange.upperBound)
        tempo.formatter = formatter
        tempoStepper.minValue = bpmRange.lowerBound; tempoStepper.maxValue = bpmRange.upperBound
        tempoStepper.increment = 1; tempoStepper.valueWraps = false
        signature.addItems(withTitles: MetronomeSignature.offered.map(\.description))
        sound.addItems(withTitles: soundNames)
        hear.addItems(withTitles: MetronomeHearIn.allCases.map(\.title))
        ask.addItems(withTitles: ["Ask me", "Accept automatically"])

        showTempo(working.clampedBpm)
        signature.selectItem(at: MetronomeSignature.offered.firstIndex(of: working.signature) ?? 2)
        sound.selectItem(at: soundNames.firstIndex { $0.caseInsensitiveCompare(working.sound) == .orderedSame } ?? 0)
        volume.integerValue = workingVolume
        hear.selectItem(at: MetronomeHearIn.allCases.firstIndex(of: working.hearIn) ?? 0)
        record.state = working.includeInRecordings ? .on : .off
        ask.selectItem(at: working.acceptMasterAutomatically ? 1 : 0)
        masterNote.isHidden = true
        if let master {
            // Following: the master's tempo and signature, shown and not changed here.
            showTempo(master.bpm)
            if let index = MetronomeSignature.offered.firstIndex(of: master.signature) { signature.selectItem(at: index) }
            tempo.isEnabled = false; tempoStepper.isEnabled = false; signature.isEnabled = false
            masterNote.stringValue = "Tempo and time signature are \(master.name)'s, the master metronome."
            masterNote.isHidden = false
            // The tempo and signature cannot be reached by the keyboard now, so the first list says whose they are.
            sound.setAccessibilityHelp(masterNote.stringValue)
        }

        listen.target = self; listen.action = #selector(listenPressed)
        tempo.target = self; tempo.action = #selector(tempoTyped)
        tempoStepper.target = self; tempoStepper.action = #selector(tempoStepped)
        for popup in [signature, sound, hear, ask] { popup.target = self; popup.action = #selector(controlsChanged(_:)) }
        volume.target = self; volume.action = #selector(controlsChanged(_:))
        record.target = self; record.action = #selector(controlsChanged(_:))
        ok.target = self; ok.action = #selector(acceptPressed); ok.keyEquivalent = "\r"; ok.keyEquivalentModifierMask = []
        cancel.target = self; cancel.action = #selector(cancelPressed); cancel.keyEquivalent = "\u{1b}"; cancel.keyEquivalentModifierMask = []

        tempo.setAccessibilityLabel("Tempo in beats per minute")
        tempoStepper.setAccessibilityLabel("Tempo in beats per minute")
        signature.setAccessibilityLabel("Time signature")
        sound.setAccessibilityLabel("Click sound")
        hear.setAccessibilityLabel("Hear the click")
        record.setAccessibilityLabel(record.title)
        ask.setAccessibilityLabel("When someone asks to be the master metronome")
        ok.setAccessibilityLabel("OK"); cancel.setAccessibilityLabel("Cancel")
        listen.setAccessibilityHelp("Start or stop the metronome with these settings. Every change here is heard at once.")
        tempo.setAccessibilityHelp("From \(Int(bpmRange.lowerBound)) to \(Int(bpmRange.upperBound)). Up and Down Arrow change it by one.")
        signature.setAccessibilityHelp("Beats in a bar over the beat's note value. The bar's first beat is accented.")
        if master == nil { sound.setAccessibilityHelp("Moving through the list plays the sound. Your own WAV files go in the Metronome sounds folder beside your profiles.") }
        volume.setAccessibilityHelp("The click's volume from zero to one hundred percent. Return resets to seventy percent.")
        hear.setAccessibilityHelp("In RemSound plays the click in your outputs. In the DAW makes Metronome an entry in a track's RemSound plugin.")
        record.setAccessibilityHelp("Only when the click is heard in RemSound: a DAW records its own tracks. A split recording gives it a track of its own.")
        ask.setAccessibilityHelp("Ask me each time, or follow anyone who asks automatically.")
        ok.setAccessibilityHelp("Keep these settings in the profile and close.")
        cancel.setAccessibilityHelp("Put the profile's settings back and close. Stops a metronome this window started.")
        updateVolumeName(); updateRecord(); showListen()
        for (index, field) in keyFields.enumerated() {
            field.descriptor = initialKeys[index]
            field.placeholderString = "Unset"
            field.setAccessibilityLabel("Metronome shortcut: " + Self.keyNames[index])
            field.setAccessibilityHelp("Press a key to set it, or Delete to clear it. The same key is in Preferences. OK keeps it.")
        }

        func row(_ title: String, _ control: NSView, width: CGFloat = 330) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.widthAnchor.constraint(equalToConstant: 230).isActive = true
            let row = NSStackView(views: [label, control]); row.orientation = .horizontal; row.alignment = .centerY
            control.widthAnchor.constraint(equalToConstant: width).isActive = true
            return row
        }
        let tempoPair = NSStackView(views: [tempo, tempoStepper]); tempoPair.orientation = .horizontal
        tempo.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let buttons = NSStackView(views: [ok, cancel]); buttons.orientation = .horizontal
        let keysHeading = NSTextField(labelWithString: "Metronome shortcut keys - also in Preferences")
        let keyRows = keyFields.enumerated().map { row(Self.keyNames[$0.offset], $0.element, width: 220) }
        let stack = NSStackView(views: [listen, row("Tempo, beats per minute", tempoPair, width: 120),
            row("Time signature", signature), masterNote, row("Click sound", sound), row("Volume", volume),
            row("Hear the click", hear), record, row("When someone asks to be the master metronome", ask), keysHeading]
            + keyRows + [buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            masterNote.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        let helpBindings: [(NSView, String)] = [
            (listen, "dialog-metronome-listen"), (tempo, "dialog-metronome-tempo"), (tempoStepper, "dialog-metronome-tempo"),
            (signature, "dialog-metronome-signature"), (sound, "dialog-metronome-sound"), (volume, "dialog-metronome-volume"),
            (hear, "dialog-metronome-hear"), (record, "dialog-metronome-record"), (ask, "dialog-metronome-whenasked"),
            (ok, "dialog-metronome-ok"), (cancel, "dialog-metronome-cancel"),
        ] + keyFields.map { ($0 as NSView, "dialog-metronome-keys") }
        for (view, key) in helpBindings { view.identifier = NSUserInterfaceItemIdentifier("help-" + key) }
        // The Metronome menu, a key or a master can start or stop it while the window is open: the button follows.
        watch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.showListen() }
        }
    }

    var controlOrder: [NSView] {
        ([listen, tempo, tempoStepper, signature, sound, volume, hear, record, ask] + keyFields + [ok, cancel] as [NSView])
            .filter { !$0.isHiddenOrHasHiddenAncestor && ($0 as? NSControl)?.isEnabled != false }
    }
    private func moveFocus(backwards: Bool) -> Bool {
        guard let window else { return false }
        let order = controlOrder
        guard !order.isEmpty else { return false }
        let index = order.firstIndex { window.firstResponder === $0 || ($0 as? NSTextField)?.currentEditor() === window.firstResponder }
        let next = index.map { ($0 + (backwards ? order.count - 1 : 1)) % order.count } ?? (backwards ? order.count - 1 : 0)
        return window.makeFirstResponder(order[next])
    }

    private func showTempo(_ bpm: Int) {
        tempo.integerValue = bpm
        tempoStepper.integerValue = bpm
        tempoStepper.setAccessibilityValueDescription("\(bpm) beats per minute")
    }

    @objc private func tempoTyped() {
        guard !finished, tempo.isEnabled else { return }
        let bpm = min(Int(MetronomeTimeline.maxBpm), max(Int(MetronomeTimeline.minBpm), tempo.integerValue))
        showTempo(bpm)
        guard bpm != working.bpm else { return }
        working.bpm = bpm
        hearLive()
    }

    @objc private func tempoStepped() {
        guard !finished, tempoStepper.isEnabled else { return }
        showTempo(tempoStepper.integerValue)
        working.bpm = tempoStepper.integerValue
        hearLive()
    }

    @objc func controlsChanged(_ sender: NSControl) {
        guard !finished else { return }
        if sender === signature, signature.isEnabled, signature.indexOfSelectedItem >= 0 {
            let chosen = MetronomeSignature.offered[signature.indexOfSelectedItem]
            working.beatsPerBar = Int(chosen.beatsPerBar); working.beatUnit = Int(chosen.beatUnit)
        }
        if sender === sound, sound.indexOfSelectedItem >= 0 {
            working.sound = soundNames[sound.indexOfSelectedItem]
            // Only a move along the list plays. With the metronome itself sounding, that is the preview: the new sound is
            // heard on its next click.
            if !sounding { preview(loadSound(working.sound), Int((60_000.0 / Double(max(1, tempo.integerValue))).rounded()), Float(workingVolume) / 100) }
        }
        if sender === volume { workingVolume = volume.integerValue; updateVolumeName() }
        if sender === hear, hear.indexOfSelectedItem >= 0 { working.hearIn = MetronomeHearIn.allCases[hear.indexOfSelectedItem]; updateRecord() }
        if sender === record { working.includeInRecordings = record.state == .on }
        if sender === ask { working.acceptMasterAutomatically = ask.indexOfSelectedItem == 1; return }
        hearLive()
    }

    private var sounding: Bool { let s = state(); return s.playing && !(s.following && s.muted) }

    private func hearLive() { heardLive(working, workingVolume) }

    private func updateVolumeName() { volume.setAccessibilityLabel("Volume: \(volume.integerValue) %") }

    /// The click is recorded only when it is heard in RemSound: a DAW records its own tracks.
    private func updateRecord() {
        let enabled = working.hearIn == .remSound
        if !enabled, window?.firstResponder === record { window?.makeFirstResponder(hear) }
        record.isEnabled = enabled
    }

    /// The button says what pressing it does, as the Metronome menu's first item does.
    private func showListen() {
        let s = state()
        let title = s.following ? (s.muted ? "Unmute metronome" : "Mute metronome")
            : s.playing ? "Stop metronome" : "Listen to the metronome"
        if listen.title != title { listen.title = title; listen.setAccessibilityLabel(title) }
    }

    @objc private func listenPressed() {
        guard !finished else { return }
        let before = state()
        startStop()
        let after = state()
        // A metronome this window started is stopped again by Cancel; one already going, or stopped here, is left.
        if !before.following && !before.playing && after.playing { startedHere = true } else if !after.playing { startedHere = false }
        showListen()
    }

    @objc func acceptPressed() {
        tempoTyped()
        finish(accepted: true)
    }
    @objc func cancelPressed() { finish(accepted: false) }

    private func finish(accepted: Bool, closeWindow: Bool = true) {
        guard !finished else { return }
        finished = true
        watch?.invalidate(); watch = nil
        window?.makeFirstResponder(nil)
        if closeWindow { window?.close() }
        finishWith(accepted, accepted ? working : initial, accepted ? workingVolume : initialVolume, startedHere,
                   accepted ? keyFields.map(\.descriptor) : initialKeys)
    }
    func windowWillClose(_ notification: Notification) { finish(accepted: false, closeWindow: false) }

    private func handleDialogKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            guard modifiers.isEmpty else { return true }
            if window?.firstResponder === listen { listenPressed(); return true }
            acceptPressed(); return true
        }
        if (modifiers.isEmpty && event.keyCode == UInt16(kVK_Escape))
            || (modifiers == .command && event.keyCode == UInt16(kVK_ANSI_W)) { cancelPressed(); return true }
        return false
    }
}

/// A click sound, heard (Windows MetronomePreview): the bar's first beat and then one beat, a beat apart at the window's
/// tempo, at its volume. A new preview replaces one still playing. Silent when RemSound's cues are all off or it runs
/// silent.
@MainActor
final class MetronomeSoundPreview {
    private var player: AVAudioPlayer?

    func play(_ sound: MetronomeClickSound?, beatMs: Int, gain: Float) {
        guard let sound, !(AppRuntime.configuration?.silent ?? true), !CueSounds.shared.preferences.muteAllCues,
              let data = Self.wave(Self.render(sound, beatMs: beatMs, gain: gain)) else { return }
        player?.stop()
        player = try? AVAudioPlayer(data: data)
        player?.play()
    }

    func stop() { player?.stop(); player = nil }

    /// The accent at the start and the beat exactly `beatMs` later, interleaved stereo at 48 kHz.
    static func render(_ sound: MetronomeClickSound, beatMs: Int, gain: Float) -> [Float] {
        func stereo(_ samples: [Float]) -> [Float] { sound.channels == 2 ? samples : samples.flatMap { [$0, $0] } }
        let accent = stereo(sound.accent), beat = stereo(sound.normal)
        let offset = Int((Double(beatMs) * 48.0).rounded()) * 2
        var result = [Float](repeating: 0, count: max(accent.count, offset + beat.count))
        for i in accent.indices { result[i] += accent[i] * gain }
        for i in beat.indices { result[offset + i] += beat[i] * gain }
        return result
    }

    /// 32-bit float WAV of interleaved stereo at 48 kHz.
    static func wave(_ samples: [Float]) -> Data? {
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite }) else { return nil }
        var data = Data()
        func u16(_ v: UInt16) { var v = v.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { var v = v.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 4
        data.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + bytes))
        data.append(contentsOf: "WAVEfmt ".utf8); u32(16); u16(3); u16(2); u32(48_000); u32(48_000 * 8); u16(8); u16(32)
        data.append(contentsOf: "data".utf8); u32(UInt32(bytes))
        samples.map { $0.bitPattern.littleEndian }.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
