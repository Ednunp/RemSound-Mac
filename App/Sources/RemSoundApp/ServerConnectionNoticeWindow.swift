import AppKit

@MainActor
final class ServerConnectionNoticeWindow: NSWindowController, NSWindowDelegate, ServerNoticePresentation {
    let message = ServerStatusTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 90))
    let suppression = NSButton(checkboxWithTitle: "Don't show this message again", target: nil, action: nil)
    let ok = NSButton(title: "OK", target: nil, action: nil)
    let status = FocusableStatusField(wrappingLabelWithString: "")
    private let answer: (Bool) -> Void
    private var retired = false, answering = false, submitted = false
    init(contextHelp: ((Bool, NSWindow) -> Void)? = nil, answer: @escaping (Bool) -> Void) {
        self.answer = answer
        let window = KeyboardWindow(contentRect: NSRect(x:0,y:0,width:520,height:280),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.title = "Connecting to a server"
        super.init(window:window); window.delegate = self
        if let contextHelp {
            window.contextHelp = { [weak window] manual in
                guard let window else { return }
                contextHelp(manual, window)
            }
        }
        message.update(ServerConnectionNotice.message); message.setSelectedRange(NSRange(location:0,length:0)); message.setAccessibilityLabel("Server notice")
        message.setAccessibilityHelp("Read the notice with arrow keys. Tab reaches Don't show this message again, then OK. Return and Escape acknowledge this notice.")
        suppression.setAccessibilityLabel("Don't show this message again")
        suppression.setAccessibilityHelp("Off by default. Saves this computer's preference only after you acknowledge the notice.")
        ok.setAccessibilityLabel("OK"); ok.target = self; ok.action = #selector(accept); ok.keyEquivalent = "\r"; ok.keyEquivalentModifierMask = []
        status.setAccessibilityLabel("Server notice result"); status.isHidden = true; status.isSelectable = true
        let scroll = NSScrollView(); scroll.documentView = message; scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant:90).isActive = true
        let stack = NSStackView(views:[scroll,suppression,ok,status]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false;window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:16),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-16),
            stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:16),stack.bottomAnchor.constraint(lessThanOrEqualTo:window.contentView!.bottomAnchor,constant:-16),
            scroll.widthAnchor.constraint(equalTo:stack.widthAnchor),status.widthAnchor.constraint(equalTo:stack.widthAnchor)])
        message.nextKeyView = suppression; suppression.nextKeyView = ok; ok.nextKeyView = message
        window.moveTabFocus = { [weak self] backwards in self?.moveFocus(backwards) ?? false }
        window.dialogKey = { [weak self] event in
            guard event.type == .keyDown, !event.isARepeat,
                event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty,
                [UInt16(36),UInt16(76),UInt16(53)].contains(event.keyCode) else { return false }
            self?.accept();return true
        }
        let helpBindings: [(NSView, String)] = [
            (message, "dialog-server-notice-message"),
            (suppression, "dialog-server-notice-suppression"),
            (ok, "dialog-server-notice-ok"),
            (status, "dialog-server-notice-status"),
        ]
        for (view, key) in helpBindings { view.identifier = NSUserInterfaceItemIdentifier("help-" + key) }
        window.initialFirstResponder = message;window.center()
    }
    required init?(coder:NSCoder) { fatalError("not used") }
    private func moveFocus(_ backwards:Bool)->Bool {
        let views:[NSView] = status.isHidden ? [message,suppression,ok] : [message,suppression,ok,status]
        let current = views.firstIndex { $0 === window?.firstResponder || (($0 as? NSTextField)?.currentEditor() != nil && ($0 as? NSTextField)?.currentEditor() === window?.firstResponder) } ?? 0
        let index = (current + (backwards ? -1 : 1) + views.count) % views.count
        return window?.makeFirstResponder(views[index]) ?? false
    }
    func present() {
        guard !retired else { return }; showWindow(nil);window?.makeKeyAndOrderFront(nil);window?.makeFirstResponder(message);message.setSelectedRange(NSRange(location:0,length:0))
    }
    func retire() { guard !retired else { return };retired = true;window?.close() }
    func showError(_ message:String) {
        guard !retired else { return };submitted = false;status.stringValue = message;status.isHidden = false
        ok.nextKeyView = status;status.nextKeyView = self.message
        window?.makeFirstResponder(status)
        if window?.isVisible == true, AppRuntime.configuration?.silent == false {
            NSAccessibility.post(element:status,notification:.announcementRequested,userInfo:[.announcement:message,.priority:NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
    @objc func accept() {
        guard !retired, !answering, !submitted else { return }
        answering = true;submitted = true;answer(suppression.state == .on);answering = false
        if submitted { retire() }
    }
    func windowShouldClose(_ sender:NSWindow)->Bool { if !retired { accept() };return retired }
    func windowWillClose(_ notification:Notification) { if !retired { accept() } }
    override func cancelOperation(_ sender:Any?) { accept() }
}
