import AppKit
import Carbon
import RemSoundCore
import RemSoundJam

struct PushToTalkWindowChoice: Equatable {
    var settings: PushToTalkSettings
    var binding: HotkeyDescriptor?
    /// Explicit clear/reselection can replace unreadable machine data even when the displayed key is unchanged.
    var keyWasEdited = false
}

@MainActor
final class PushToTalkSettingsWindow: NSWindowController, NSWindowDelegate, HotkeyCaptureFieldDelegate {
    let enable = NSButton(checkboxWithTitle: "Enable push to talk", target: nil, action: nil)
    let path = NSPopUpButton(), key = HotkeyCaptureField(), trigger = NSPopUpButton()
    let hold = NSButton(checkboxWithTitle: "Hold to speak", target: nil, action: nil)
    let doubleTap = NSButton(checkboxWithTitle: "Double tap to hold", target: nil, action: nil)
    let speed = NSPopUpButton(), level = ResettableSlider.pushToTalkThreshold()
    let bypassRecording = NSButton(checkboxWithTitle: "Bypass push to talk for recording", target: nil, action: nil)
    let bypassPlugin = NSButton(checkboxWithTitle: "Bypass push to talk for the DAW plugin", target: nil, action: nil)
    let ok = NSButton(title: "OK", target: nil, action: nil), cancel = NSButton(title: "Cancel", target: nil, action: nil)
    let status = FocusableStatusField(wrappingLabelWithString: "")
    private let accept: (PushToTalkWindowChoice) -> String?
    private let didClose: () -> Void
    private let announce: (NSView, String) -> Void
    private var finished = false
    private var previewFailureVisible = false
    private(set) var choice: PushToTalkWindowChoice
    var previewDoubleTap: ((PushToTalkDoubleTapSpeed) -> Void)?
    var cancelPreview: (() -> Void)?
    private static let paths: [PushToTalkCapturePath] = [.input, .systemAudio, .both]
    private static let speeds: [PushToTalkDoubleTapSpeed] = [.slow, .medium, .fast]

    init(settings: PushToTalkSettings, binding: HotkeyDescriptor?, contextHelp: ((Bool, NSWindow) -> Void)? = nil,
         accept: @escaping (PushToTalkWindowChoice) -> String?, didClose: @escaping () -> Void = {},
         announce: @escaping (NSView, String) -> Void = { view, message in
             guard AppRuntime.configuration?.silent == false else { return }
             NSAccessibility.post(element: view, notification: .announcementRequested,
                 userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
         }) {
        choice = .init(settings: settings, binding: binding)
        self.accept = accept; self.didClose = didClose; self.announce = announce
        let panel = KeyboardWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 440),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        panel.title = "Push to talk settings"; panel.isReleasedWhenClosed = false
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
        build()
        panel.initialFirstResponder = enable
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        guard let content = window?.contentView else { return }
        path.addItems(withTitles: ["Input audio", "System audio", "Both input and system audio"])
        trigger.addItems(withTitles: ["A key", "Sound reaching a level"])
        speed.addItems(withTitles: ["Slow", "Medium", "Fast"])
        enable.state = choice.settings.enabled ? .on : .off
        path.selectItem(at: Self.paths.firstIndex(of: choice.settings.capturePath) ?? 2)
        key.captureMode = .pushToTalk; key.descriptor = choice.binding; key.placeholderString = "Not set"
        key.hotkeyDelegate = self
        trigger.selectItem(at: choice.settings.trigger == .key ? 0 : 1)
        hold.state = choice.settings.holdToSpeak ? .on : .off
        doubleTap.state = choice.settings.doubleTapToHold ? .on : .off
        speed.selectItem(at: Self.speeds.firstIndex(of: choice.settings.doubleTapSpeed) ?? 1)
        level.integerValue = choice.settings.levelDb
        bypassRecording.state = choice.settings.bypassForRecording ? .on : .off
        bypassPlugin.state = choice.settings.bypassForPlugin ? .on : .off
        for button in [enable, hold, doubleTap, bypassRecording, bypassPlugin] {
            button.target = self; button.action = #selector(controlsChanged(_:)); button.setAccessibilityLabel(button.title)
        }
        for popup in [path, trigger, speed] { popup.target = self; popup.action = #selector(controlsChanged(_:)) }
        level.target = self; level.action = #selector(controlsChanged(_:))
        path.setAccessibilityLabel("Push to talk affected audio path")
        key.setAccessibilityLabel("Push to talk shortcut key")
        trigger.setAccessibilityLabel("Push to talk is triggered by")
        speed.setAccessibilityLabel("Double tap speed")
        enable.setAccessibilityHelp("Enable this profile's push to talk. Changes apply only after OK.")
        path.setAccessibilityHelp("Choose input audio, system audio, or both. DAW sending follows push to talk unless bypassed.")
        hold.setAccessibilityHelp("Send while the key is held. With Hold and Double both off, each press switches talking on or off.")
        doubleTap.setAccessibilityHelp("A double tap locks talking on; one tap releases it.")
        speed.setAccessibilityHelp("Slow, medium or fast double-tap timing. Available when Double tap to hold is selected.")
        trigger.setAccessibilityHelp("Use a key, or sound reaching the chosen level. Other settings are retained when changing mode.")
        level.setAccessibilityHelp("Up raises the threshold. Return or keypad Enter resets to minus 40 decibels without closing this window.")
        bypassRecording.setAccessibilityHelp("Record original sent audio whether talking or not. Sending to peers still follows push to talk.")
        bypassPlugin.setAccessibilityHelp("Send a DAW plugin's audio whether talking or not. Input and system audio still follow push to talk.")
        ok.target = self; ok.action = #selector(acceptPressed); ok.keyEquivalent = "\r"; ok.keyEquivalentModifierMask = []
        cancel.target = self; cancel.action = #selector(cancelPressed); cancel.keyEquivalent = "\u{1b}"; cancel.keyEquivalentModifierMask = []
        ok.setAccessibilityLabel("OK"); ok.setAccessibilityHelp("Apply these choices and close. An error keeps this window open.")
        cancel.setAccessibilityLabel("Cancel"); cancel.setAccessibilityHelp("Close and discard all changes. Escape and Command W also discard.")
        status.setAccessibilityLabel("Push to talk settings result"); status.setAccessibilityHelp("The last error applying these choices. Tab returns to the controls.")
        status.isHidden = true
        func row(_ title: String, _ control: NSView) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.widthAnchor.constraint(equalToConstant: 190).isActive = true
            let row = NSStackView(views: [label, control]); row.orientation = .horizontal
            row.alignment = .centerY; control.widthAnchor.constraint(equalToConstant: 330).isActive = true
            return row
        }
        let buttons = NSStackView(views: [ok, cancel]); buttons.orientation = .horizontal
        let stack = NSStackView(views: [enable, row("Affected audio path", path), row("Shortcut key", key),
            row("Triggered by", trigger), hold, doubleTap, row("Double tap speed", speed), row("Send at this level", level),
            bypassRecording, bypassPlugin, buttons, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        let helpBindings: [(NSView, String)] = [
            (enable, "dialog-ptt-enable"),
            (path, "dialog-ptt-path"),
            (key, "dialog-ptt-key"),
            (trigger, "dialog-ptt-trigger"),
            (hold, "dialog-ptt-hold"),
            (doubleTap, "dialog-ptt-doubletap"),
            (speed, "dialog-ptt-speed"),
            (level, "dialog-ptt-level"),
            (bypassRecording, "dialog-ptt-bypassrecording"),
            (bypassPlugin, "dialog-ptt-bypassplugin"),
            (ok, "dialog-ptt-ok"),
            (cancel, "dialog-ptt-cancel"),
            (status, "dialog-ptt-status"),
        ]
        for (view, key) in helpBindings { view.identifier = NSUserInterfaceItemIdentifier("help-" + key) }
        updateDependencies(); updateLevelName()
    }
    var controlOrder: [NSView] {
        ([enable, path, key, trigger, hold, doubleTap, speed, level, bypassRecording, bypassPlugin, ok, cancel, status] as [NSView])
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
    @objc func controlsChanged(_ sender: NSControl) {
        guard !finished else { return }
        choice.settings.enabled = enable.state == .on
        choice.settings.capturePath = Self.paths[max(0, min(2, path.indexOfSelectedItem))]
        choice.settings.trigger = trigger.indexOfSelectedItem == 1 ? .level : .key
        choice.settings.holdToSpeak = hold.state == .on; choice.settings.doubleTapToHold = doubleTap.state == .on
        choice.settings.doubleTapSpeed = Self.speeds[max(0, min(2, speed.indexOfSelectedItem))]
        choice.settings.levelDb = level.integerValue
        choice.settings.bypassForRecording = bypassRecording.state == .on
        choice.settings.bypassForPlugin = bypassPlugin.state == .on
        updateDependencies(); updateLevelName()
        if !speed.isEnabled { cancelPreview?() }
        if sender === speed, speed.isEnabled { previewDoubleTap?(choice.settings.doubleTapSpeed) }
        if window?.firstResponder === sender {
            if sender === level { announce(level, level.accessibilityLabel() ?? "") }
            if sender === trigger { announce(trigger, "Triggered by " + (trigger.titleOfSelectedItem ?? "")) }
        }
    }
    private func updateDependencies() {
        let byKey = choice.settings.trigger == .key
        for (control, enabled) in [(hold as NSControl, byKey), (doubleTap, byKey),
                                  (speed, byKey && choice.settings.doubleTapToHold), (level, !byKey)] {
            if !enabled, window?.firstResponder === control { window?.makeFirstResponder(trigger) }
            control.isEnabled = enabled
        }
    }
    private func updateLevelName() {
        level.setAccessibilityLabel("Send when sound reaches this level: minus \(-choice.settings.levelDb) decibels")
    }
    func hotkeyCaptureFieldDidChange(_ field: HotkeyCaptureField) {
        guard !finished, field === key else { return }
        choice.binding = key.descriptor; choice.keyWasEdited = true
        if window?.firstResponder === key { announce(key, "Push to talk shortcut key: " + (choice.binding?.description ?? "Not set")) }
    }
    func clearPreviewFailure() {
        guard !finished, previewFailureVisible else { return }; previewFailureVisible = false
        if let responder = window?.firstResponder, responder === status || responder === status.currentEditor() {
            status.stringValue = "Double-tap preview started."
            announce(status, status.stringValue)
        } else { status.stringValue = ""; status.isHidden = true }
    }
    func reportPreviewFailure(_ message: String) {
        guard !finished else { return }
        previewFailureVisible = true
        status.stringValue = message; status.isHidden = false; window?.contentView?.layoutSubtreeIfNeeded()
        if window?.firstResponder === speed { announce(speed, message) }
    }
    @objc func acceptPressed() {
        guard !finished else { return }
        if let error = accept(choice) {
            previewFailureVisible = false
            status.stringValue = error; status.isHidden = false; window?.contentView?.layoutSubtreeIfNeeded(); window?.makeFirstResponder(status); announce(status, error)
            return
        }
        finish()
    }
    @objc func cancelPressed() { finish() }
    private func finish(closeWindow: Bool = true) {
        guard !finished else { return }
        finished = true; window?.makeFirstResponder(nil); if closeWindow { window?.close() }; didClose()
    }
    func windowWillClose(_ notification: Notification) { finish(closeWindow: false) }
    private func handleDialogKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            guard modifiers.isEmpty else { return true }
            acceptPressed(); return true
        }
        if (modifiers.isEmpty && event.keyCode == UInt16(kVK_Escape))
            || (modifiers == .command && event.keyCode == UInt16(kVK_ANSI_W)) { cancelPressed(); return true }
        return false
    }
}
