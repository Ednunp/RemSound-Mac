import AppKit
import Carbon
import RemSoundRuntime

/// Main-thread, app-local observation only; the original event always reaches AppKit.
final class TypingEventMonitor {
    private static let functionCharacters = UInt32(NSUpArrowFunctionKey)...UInt32(NSModeSwitchFunctionKey)
    enum Target: Equatable { case ordinary, password }
    struct Context {
        var responder: NSResponder?
        var root: NSView?
    }
    private let configuration: RuntimeConfiguration
    private let preferences: CuePreferences
    private let onCharacter: (Bool) -> Void
    private let install: (@escaping (NSEvent) -> NSEvent?) -> Any?
    private let remove: (Any) -> Void
    private let context: (NSEvent) -> Context
    private let ownsEditor: (NSTextField, NSText) -> Bool
    private var token: Any?
    private var started = false
    private var generation = 0

    init(configuration: RuntimeConfiguration, preferences: CuePreferences,
        onCharacter: @escaping (Bool) -> Void,
        install: @escaping (@escaping (NSEvent) -> NSEvent?) -> Any? = {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: $0)
        }, remove: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) },
        context: @escaping (NSEvent) -> Context = { event in
            guard NSApp.isActive, let window = event.window, window.isKeyWindow else {
                return Context(responder: nil, root: nil)
            }
            return Context(responder: window.firstResponder, root: window.contentView)
        }, ownsEditor: @escaping (NSTextField, NSText) -> Bool = { $0.currentEditor() === $1 }) {
        self.configuration = configuration
        self.preferences = preferences
        self.onCharacter = onCharacter
        self.install = install
        self.remove = remove
        self.context = context
        self.ownsEditor = ownsEditor
    }

    func start() {
        started = true
        refresh()
    }

    func refresh() {
        guard started, eligible else { retireMonitor(); return }
        guard token == nil else { return }
        generation += 1
        let current = generation
        token = install { [weak self] event in
            self?.observe(event, generation: current)
            return event
        }
    }

    func stop() {
        started = false
        retireMonitor()
    }

    deinit { stop() }

    private var eligible: Bool {
        !configuration.silent && !configuration.isHeadless && preferences.automaticKeyboardClicksEnabled
    }

    private func retireMonitor() {
        generation += 1
        guard let token else { return }
        self.token = nil
        remove(token)
    }

    private func observe(_ event: NSEvent, generation: Int) {
        guard started, token != nil, generation == self.generation, eligible,
            Self.isCharacter(event) else { return }
        let focused = context(event)
        guard let target = Self.target(for: focused.responder, root: focused.root,
            ownsEditor: ownsEditor) else { return }
        // Only the password distinction crosses into playback; no text or control value is retained.
        onCharacter(target == .password)
    }

    private static func isCharacter(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
            event.modifierFlags.intersection([.command, .control]).isEmpty else { return false }
        switch Int(event.keyCode) {
        case kVK_Tab, kVK_Escape, kVK_ForwardDelete, kVK_LeftArrow, kVK_RightArrow,
            kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown: return false
        case kVK_Delete: return !event.modifierFlags.contains(.option)
        default: break
        }
        guard let characters = event.characters, !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy {
            if $0 == "\n" || $0 == "\r" { return true }
            // AppKit function/navigation keys use private-use characters, not typed text.
            return !functionCharacters.contains($0.value) && !CharacterSet.controlCharacters.contains($0)
        }
    }

    static func target(for responder: NSResponder?, root: NSView?,
        ownsEditor: (NSTextField, NSText) -> Bool = { $0.currentEditor() === $1 }) -> Target? {
        if let field = responder as? NSTextField {
            guard !(field is HotkeyCaptureField), field.isEditable || field.isSelectable else { return nil }
            return field is NSSecureTextField || field is BrowserListenerPasswordField ? .password : .ordinary
        }
        guard let editor = responder as? NSTextView else { return nil }
        if editor.isFieldEditor {
            guard let root else { return nil }
            // The shared NSTextView must inherit the secure/nonsecure identity of its owning field.
            func owner(in view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, ownsEditor(field, editor) { return field }
                for child in view.subviews {
                    if let found = owner(in: child) { return found }
                }
                return nil
            }
            guard let field = owner(in: root) else { return nil }
            return target(for: field, root: nil)
        }
        return editor.isEditable || editor.isSelectable ? .ordinary : nil
    }
}
