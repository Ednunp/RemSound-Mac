import AppKit
import RemSoundJam

/// A finite native question. Default Return/Escape is Cancel; only Visit opens the browser.
final class ServerVersionWarningWindow: NSWindowController, NSWindowDelegate {
    static let warningText = "Warning: you are connecting to a RemSound server that is out of date. Please contact the server administrator to request an update to the latest version for features and security enhancements."
    let message = FocusableStatusField(wrappingLabelWithString: warningText)
    let connect = NSButton(title: "Connect anyway", target: nil, action: nil)
    let visit = NSButton(title: "Visit GitHub for the latest RemSound server code", target: nil, action: nil)
    let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    let status = FocusableStatusField(wrappingLabelWithString: "")
    private let isCurrent: () -> Bool
    private let browser: (URL) -> Bool
    private let answer: (Bool) -> Void
    private let didClose: () -> Void
    private let url: URL
    private var finished = false

    init(server: String, latestReleased: String?, isCurrent: @escaping () -> Bool, contextHelp: ((Bool, NSWindow) -> Void)? = nil,
         browser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }, answer: @escaping (Bool) -> Void,
         didClose: @escaping () -> Void = {}) {
        self.isCurrent = isCurrent; self.browser = browser; self.answer = answer; self.didClose = didClose
        url = ServerVersionCheck.latestCodeURL(latestReleased)
        let panel = KeyboardWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        let clean = server.unicodeScalars.map { CharacterSet.controlCharacters.union(.newlines).contains($0) ? " " : String($0) }.joined()
        panel.title = "RemSound server version: " + clean
        super.init(window: panel)
        if let contextHelp {
            panel.contextHelp = { [weak panel] manual in
                guard let panel else { return }
                contextHelp(manual, panel)
            }
        }
        panel.delegate = self
        panel.dialogKey = { [weak self] event in
            guard event.type == .keyDown, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  [36, 76, 53].contains(event.keyCode) else { return false }
            self?.finish(false); return true
        }
        panel.moveTabFocus = { [weak self] backwards in self?.moveFocus(backwards) ?? false }
        build()
        panel.center()
        panel.initialFirstResponder = message
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        guard let content = window?.contentView else { return }
        message.isSelectable = true; message.isEditable = false
        message.setAccessibilityLabel("Server version warning")
        message.setAccessibilityHelp("Read the warning, then choose Connect anyway or Cancel. Return and Escape cancel. Visit opens GitHub and leaves this question open.")
        for button in [connect, visit, cancel] { button.target = self; button.keyEquivalentModifierMask = [] }
        connect.action = #selector(connectAnyway); connect.keyEquivalent = ""
        connect.setAccessibilityHelp("Join or stay on this out-of-date server for this connection only.")
        visit.action = #selector(visitGitHub)
        visit.setAccessibilityHelp("Open the latest RemSound server code on GitHub without answering or closing this warning.")
        cancel.action = #selector(cancelConnection); cancel.keyEquivalent = "\r"
        cancel.setAccessibilityHelp("Cancel this server connection. This is the default for Return and Escape.")
        status.setAccessibilityLabel("GitHub visit result"); status.isHidden = true
        let buttons = NSStackView(views: [connect, visit, cancel]); buttons.orientation = .horizontal; buttons.spacing = 12
        let stack = NSStackView(views: [message, buttons, status]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),status.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        let helpBindings: [(NSView, String)] = [
            (message, "dialog-server-version-message"),
            (connect, "dialog-server-version-connect"),
            (visit, "dialog-server-version-visit"),
            (cancel, "dialog-server-version-cancel"),
            (status, "dialog-server-version-status"),
        ]
        for (view, key) in helpBindings { view.identifier = NSUserInterfaceItemIdentifier("help-" + key) }
        message.preferredMaxLayoutWidth = 668
        message.nextKeyView = connect; connect.nextKeyView = visit; visit.nextKeyView = cancel; cancel.nextKeyView = message
    }

    private func moveFocus(_ backwards: Bool) -> Bool {
        let controls: [NSView] = status.isHidden ? [message, connect, visit, cancel] : [message, connect, visit, cancel, status]
        let current = controls.firstIndex {
            $0 === window?.firstResponder || (($0 as? NSTextField)?.currentEditor() != nil
                && ($0 as? NSTextField)?.currentEditor() === window?.firstResponder)
        } ?? 0
        let next = (current + (backwards ? -1 : 1) + controls.count) % controls.count
        return window?.makeFirstResponder(controls[next]) ?? false
    }
    @objc private func connectAnyway() { finish(true) }
    @objc private func cancelConnection() { finish(false) }
    @objc private func visitGitHub() {
        guard !finished, isCurrent() else { retire(); return }
        guard browser(url) else {
            status.stringValue = "GitHub could not be opened. Try again, or choose Connect anyway or Cancel."
            status.isHidden = false
            if window?.isVisible == true, AppRuntime.configuration?.silent == false {
                NSAccessibility.post(element: status, notification: .announcementRequested,
                    userInfo: [.announcement: status.stringValue, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
            return
        }
        if window?.firstResponder === status || (status.currentEditor() != nil && status.currentEditor() === window?.firstResponder) {
            window?.makeFirstResponder(visit)
        }
        status.isHidden = true; status.stringValue = ""
    }
    private func finish(_ accepted: Bool) {
        guard !finished else { return }
        guard isCurrent() else { retire(); return }
        finished = true; window?.orderOut(nil); window?.close(); answer(accepted); didClose()
    }
    func retire() {
        guard !finished else { return }
        finished = true; window?.orderOut(nil); window?.close(); didClose()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(false); return true }
}
