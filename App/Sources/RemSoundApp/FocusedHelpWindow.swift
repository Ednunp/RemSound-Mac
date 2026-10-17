import AppKit
import Carbon

struct FocusedHelpContent {
    let title: String
    let text: String
    let focusedView: NSView?

    private static var helpKeyAssociation: UInt8 = 0

    private static func bind(_ key: String, to view: NSView) {
        // AppKit owns standard alert identifiers. Keep those identities and attach only the help key.
        objc_setAssociatedObject(view, &helpKeyAssociation, key, .OBJC_ASSOCIATION_COPY_NONATOMIC)
    }

    static func markAlert(_ alert: NSAlert, notice: String, buttons: [String], helpDelegate: NSAlertDelegate? = nil) {
        let focus = alert.window.initialFirstResponder
        objc_setAssociatedObject(alert, &helpKeyAssociation, notice, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        // Without an owned delegate AppKit would send Help to the external Help Viewer.
        if let helpDelegate { alert.delegate = helpDelegate; alert.showsHelp = true }
        alert.layout()
        // The standard alert text belongs to its notice. Accessory controls need their own explicit keys.
        func markText(in view: NSView) {
            if let accessory = alert.accessoryView, view === accessory || view.isDescendant(of: accessory) { return }
            if let field = view as? NSTextField, !field.isEditable, key(of: field) == nil,
                field.stringValue == alert.messageText || (!alert.informativeText.isEmpty && field.stringValue == alert.informativeText) {
                bind(notice, to: field)
            }
            if let button = view as? NSButton, button.bezelStyle == .helpButton {
                bind(notice, to: button)
                button.setAccessibilityLabel("Help for this dialog")
                button.setAccessibilityHelp(bundledManual()?.entry(notice))
            }
            for child in view.subviews { markText(in: child) }
        }
        if let content = alert.window.contentView { markText(in: content) }
        for (button, key) in zip(alert.buttons, buttons) where Self.key(of: button) == nil {
            bind(key, to: button)
        }
        alert.window.initialFirstResponder = focus
    }

    static func content(for alert: NSAlert, manual: Manual?) -> FocusedHelpContent? {
        guard let key = objc_getAssociatedObject(alert, &helpKeyAssociation) as? String,
            let words = manual?.entry(key) else { return nil }
        // The notice's manual entry never includes entered values or the dynamic informative text.
        return .init(title: "Dialog", text: words, focusedView: capture(in: alert.window).focusedView)
    }

    struct Manual {
        static let maximumBytes = 512 * 1024
        static let minimumEntryCharacters = 20
        let entries: [String: [String]]
        let valid: Bool
        init(_ text: String) {
            guard text.utf8.count <= Self.maximumBytes else { entries = [:]; valid = false; return }
            let pattern = #"<!-- help-entry:([a-z0-9-]{1,80}) -->\n([\s\S]*?)\n<!-- /help-entry -->"#
            let source = text.replacingOccurrences(of: "\r\n", with: "\n") as NSString
            let regex = try! NSRegularExpression(pattern: pattern)
            let matches = regex.matches(in: source as String, range: NSRange(location: 0, length: source.length))
            var result = [String: [String]]()
            for match in matches {
                let key = source.substring(with: match.range(at: 1))
                let words = source.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                result[key, default: []].append(words)
            }
            entries = result
            valid = !matches.isEmpty &&
                text.components(separatedBy: "<!-- help-entry:").count - 1 == matches.count &&
                text.components(separatedBy: "<!-- /help-entry -->").count - 1 == matches.count
        }
        func entry(_ key: String) -> String? {
            guard valid, let values = entries[key], values.count == 1, values[0].count >= Self.minimumEntryCharacters else { return nil }
            return values[0]
        }
    }

    static func bundledManual(in bundle: Bundle = .main) -> Manual? {
        guard let file = bundle.url(forResource: "README", withExtension: "md"),
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
            values.isRegularFile == true, let size = values.fileSize, size <= Manual.maximumBytes,
            let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Manual.maximumBytes + 1), data.count <= Manual.maximumBytes,
            let text = String(data: data, encoding: .utf8) else { return nil }
        let manual = Manual(text)
        return manual.valid ? manual : nil
    }

    @discardableResult static func markMenuItem(_ item: NSMenuItem, key: String, manual: Manual?) -> NSMenuItem {
        // Keep native menu identity, represented profile IDs and actions separate from help metadata.
        objc_setAssociatedObject(item, &helpKeyAssociation, key, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        item.toolTip = manual?.entry(key)
        return item
    }

    static func key(of item: NSMenuItem) -> String? {
        objc_getAssociatedObject(item, &helpKeyAssociation) as? String
    }

    static func key(of view: NSView) -> String? {
        // AppKit can focus its segmented tab-strip implementation instead of the public tab view.
        let tabView = (view as? NSTabView) ?? ((view as? NSSegmentedControl).flatMap { strip -> NSTabView? in
            guard let tabs = strip.superview as? NSTabView, strip.target as AnyObject? === tabs,
                strip.segmentCount == tabs.tabViewItems.count else { return nil }
            return tabs
        })
        if tabView == nil, let key = objc_getAssociatedObject(view, &helpKeyAssociation) as? String { return key }
        let identifier = tabView?.selectedTabViewItem?.view?.identifier ?? view.identifier
        guard let raw = identifier?.rawValue, raw.hasPrefix("help-") else { return nil }
        return String(raw.dropFirst(5))
    }

    static func content(for view: NSView, manual: Manual?) -> FocusedHelpContent {
        let title = view.accessibilityLabel() ?? (view as? NSButton)?.title ?? "RemSound"
        let words = key(of: view).flatMap { manual?.entry($0) }
        return .init(title: title, text: words ?? "\(title)\n\n\(view.accessibilityHelp() ?? "Choose a control and press F1 for help.")", focusedView: view)
    }

    static func capture(in window: NSWindow?) -> FocusedHelpContent {
        let responder = window?.firstResponder
        var view = responder as? NSView
        if (view as? NSTextView)?.isFieldEditor == true,
            let root = window?.contentView {
            // A shared field editor does not carry its owning control's help or name.
            func editingControl(in candidate: NSView) -> NSView? {
                if let field = candidate as? NSTextField,
                    field.currentEditor() === responder { return field }
                for child in candidate.subviews {
                    if let found = editingControl(in: child) { return found }
                }
                return nil
            }
            view = editingControl(in: root)
        }
        if let view { return content(for: view, manual: bundledManual()) }
        let title = view?.accessibilityLabel() ?? (view as? NSButton)?.title ?? "RemSound"
        let instructions = view?.accessibilityHelp()
            ?? "Choose a control and press F1 for its help. Use Tab or Shift-Tab to move between controls. Use Command-1 through Command-4 to change sections in the active RemSound window."
        // Read descriptions only. Values may contain a password, address or profile data.
        return FocusedHelpContent(title: title, text: "\(title)\n\n\(instructions)",
            focusedView: view)
    }
}

private final class HelpReadingWindow: NSWindow {
    override var worksWhenModal: Bool {
        guard let parent, NSApp.modalWindow === parent else { return super.worksWhenModal }
        return true
    }
    var closeHelp: (() -> Void)?
    var moveTabFocus: ((Bool) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
            closeHelp?()
            return
        }
        if event.type == .keyDown, event.keyCode == UInt16(kVK_ANSI_W), modifiers == .command {
            closeHelp?()
            return
        }
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Tab),
            modifiers.isEmpty || modifiers == .shift {
            moveTabFocus?(modifiers == .shift)
            return
        }
        super.sendEvent(event)
    }
    override func cancelOperation(_ sender: Any?) { closeHelp?() }
}

final class FocusedHelpWindowController: NSWindowController, NSWindowDelegate {
    let textView = NSTextView()
    let manualButton = NSButton(title: "Open RemSound Manual", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private weak var ownerWindow: NSWindow?
    private weak var restoreView: NSView?
    private let playOpen: () -> Void
    private let playClose: () -> Void
    private let openManual: () -> Void
    private var presented = false

    init(content: FocusedHelpContent, owner: NSWindow?, playOpen: @escaping () -> Void,
        playClose: @escaping () -> Void, openManual: @escaping () -> Void) {
        self.ownerWindow = owner
        restoreView = content.focusedView
        self.playOpen = playOpen
        self.playClose = playClose
        self.openManual = openManual
        let helpWindow = HelpReadingWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 360),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        helpWindow.title = "Help: \(content.title)"
        helpWindow.isReleasedWhenClosed = false
        super.init(window: helpWindow)
        helpWindow.delegate = self
        helpWindow.closeHelp = { [weak self] in self?.close() }

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.frame = NSRect(x: 0, y: 0, width: 540, height: 250)
        textView.string = content.text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.setAccessibilityLabel("\(content.title) help")
        textView.setAccessibilityHelp("Read with arrow keys or VoiceOver. Escape closes help and returns to the control. Tab moves to Open RemSound Manual and Close.")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 580, height: CGFloat.greatestFiniteMagnitude)
        manualButton.target = self
        manualButton.action = #selector(manualPressed)
        manualButton.setAccessibilityHelp("Open the full RemSound manual in your default document reader. Help remains open.")
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.setAccessibilityHelp("Close context help and return to the control you were using. Escape also closes help.")
        let buttons = NSStackView(views: [manualButton, closeButton])
        buttons.spacing = 12
        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        helpWindow.contentView?.addSubview(stack)
        if let root = helpWindow.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
                stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            ])
        }
        textView.nextKeyView = manualButton
        manualButton.nextKeyView = closeButton
        closeButton.nextKeyView = textView
        helpWindow.moveTabFocus = { [weak self, weak helpWindow] backwards in
            guard let self, let helpWindow else { return }
            let order: [NSView] = [self.textView, self.manualButton, self.closeButton]
            let index = order.firstIndex { $0 === helpWindow.firstResponder } ?? 0
            let next = backwards ? (index + order.count - 1) % order.count
                : (index + 1) % order.count
            helpWindow.makeFirstResponder(order[next])
        }
        helpWindow.initialFirstResponder = textView
        helpWindow.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        if let ownerWindow, NSApp.modalWindow === ownerWindow, let window {
            ownerWindow.addChildWindow(window, ordered: .above)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        guard !presented else { return }
        presented = true
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        playOpen()
    }

    @objc private func manualPressed() { openManual() }
    @objc private func closePressed() { close() }

    func windowWillClose(_ notification: Notification) {
        if let window, let parent = window.parent { parent.removeChildWindow(window) }
        guard presented else { return }
        presented = false
        playClose()
        guard let owner = ownerWindow, owner.isVisible else { return }
        owner.makeKeyAndOrderFront(nil)
        if let restoreView, restoreView.window === owner {
            owner.makeFirstResponder(restoreView)
        }
    }
}
