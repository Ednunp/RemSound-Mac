import AppKit
import Carbon

@MainActor
protocol HotkeyCaptureFieldDelegate: AnyObject {
    func hotkeyCaptureFieldDidChange(_ field: HotkeyCaptureField)
}

final class HotkeyCaptureField: NSTextField {
    enum CaptureMode { case general, pushToTalk }
    var captureMode: CaptureMode = .general { didSet { updateCaptureHelp() } }
    private var captureFocused = false
    var onCaptureFocusChanged: ((Bool) -> Void)?
    var onInvalidKey: (() -> Void)?
    weak var hotkeyDelegate: HotkeyCaptureFieldDelegate?
    private var trackedModifiers: HotkeyDescriptor.Modifiers = []
    var descriptor: HotkeyDescriptor? {
        didSet {
            stringValue = descriptor?.description ?? ""
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureCaptureField()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureCaptureField()
    }

    private func configureCaptureField() {
        isEditable = false
        isSelectable = false
        focusRingType = .default
        setAccessibilityRole(.textField)
        updateCaptureHelp()
    }

    private func updateCaptureHelp() {
        if captureMode == .pushToTalk {
            setAccessibilityHelp("Press a push-to-talk key, with or without modifiers. Tab moves focus, Escape cancels, and Command W closes the window. Press Delete or Backspace to clear this key.")
            return
        }
        setAccessibilityHelp("Press a valid global shortcut. Two modifiers are safest. One modifier is allowed only with function keys, Grave, Backslash, or ISO section. Press Delete or Backspace to clear this hotkey.")
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            trackedModifiers = []
            setCaptureFocused(true)
        }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            trackedModifiers = []
            setCaptureFocused(false)
        }
        return resigned
    }

    private func setCaptureFocused(_ focused: Bool) {
        guard captureFocused != focused else { return }
        captureFocused = focused
        onCaptureFocusChanged?(focused)
    }

    private func accepts(_ candidate: HotkeyDescriptor) -> Bool {
        captureMode == .pushToTalk ? candidate.isValidForPushToTalk : candidate.isValid
    }

    private func rejectKey() {
        if let onInvalidKey { onInvalidKey() } else { CueSounds.shared.beep() }
    }

    override func textShouldBeginEditing(_ textObject: NSText) -> Bool {
        false
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        trackedModifiers = HotkeyDescriptor.Modifiers(eventModifierFlags: event.modifierFlags)
    }

    override func keyDown(with event: NSEvent) {
        if captureMode == .pushToTalk {
            if event.isARepeat { return }
            if event.keyCode == UInt16(kVK_Escape) || event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
                super.keyDown(with: event)
                return
            }
        }
        if moveFocusIfNeeded(for: event) {
            return
        }
        if clearHotkeyIfNeeded(for: event) {
            return
        }

        let eventModifiers = HotkeyDescriptor.Modifiers(eventModifierFlags: event.modifierFlags)
        let modifiers = eventModifiers.union(trackedModifiers)
        let keyCode = UInt32(event.keyCode)
        let candidate = HotkeyDescriptor(keyCode: keyCode, modifiers: modifiers)
        guard accepts(candidate) else {
            rejectKey()
            return
        }
        descriptor = candidate
        hotkeyDelegate?.hotkeyCaptureFieldDidChange(self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else {
            return false
        }
        if captureMode == .pushToTalk {
            if event.keyCode == UInt16(kVK_Escape) || event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) { return false }
            if event.isARepeat { return true }
        }
        if moveFocusIfNeeded(for: event) {
            return true
        }
        if clearHotkeyIfNeeded(for: event) {
            return true
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            return false
        }
        let eventModifiers = HotkeyDescriptor.Modifiers(eventModifierFlags: event.modifierFlags)
        let modifiers = eventModifiers.union(trackedModifiers)
        let candidate = HotkeyDescriptor(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        guard accepts(candidate) else {
            if event.modifierFlags.contains(.command) {
                return false
            }
            rejectKey()
            return true
        }
        descriptor = candidate
        hotkeyDelegate?.hotkeyCaptureFieldDidChange(self)
        return true
    }

    private func clearHotkeyIfNeeded(for event: NSEvent) -> Bool {
        guard event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) else {
            return false
        }
        descriptor = nil
        trackedModifiers = []
        hotkeyDelegate?.hotkeyCaptureFieldDidChange(self)
        return true
    }

    private func moveFocusIfNeeded(for event: NSEvent) -> Bool {
        guard event.keyCode == UInt16(kVK_Tab) else { return false }
        if event.modifierFlags.contains(.shift) {
            window?.selectPreviousKeyView(self)
        } else {
            window?.selectNextKeyView(self)
        }
        return true
    }
}
