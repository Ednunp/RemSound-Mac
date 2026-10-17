import AppKit
import Carbon

struct QuickProfileEntry {
    let id: UUID
    let title: String
    let isCurrent: Bool

    var displayedTitle: String { title + (isCurrent ? " (current)" : "") }
}

private final class QuickProfileTable: NSTableView {
    var acceptSelection: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty,
            event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            acceptSelection?()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        if row >= 0, selectedRow == row { acceptSelection?() }
    }
}

private final class QuickProfileWindow: NSWindow {
    var cancelSelection: (() -> Void)?
    var moveTabFocus: ((Bool) -> Void)?
    var contextHelp: ((Bool) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.type == .keyDown {
            if (event.keyCode == UInt16(kVK_Escape) && modifiers.isEmpty)
                || (event.keyCode == UInt16(kVK_ANSI_W) && modifiers == .command) {
                cancelSelection?()
                return
            }
            if event.keyCode == UInt16(kVK_Tab), modifiers.isEmpty || modifiers == .shift {
                moveTabFocus?(modifiers == .shift)
                return
            }
            if event.keyCode == UInt16(kVK_F1), modifiers.isEmpty || modifiers == .shift {
                contextHelp?(modifiers == .shift)
                return
            }
        }
        super.sendEvent(event)
    }
}

final class QuickProfileSwitchWindowController: NSWindowController,
    NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let profiles: [QuickProfileEntry]
    let table: NSTableView
    let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private weak var ownerWindow: NSWindow?
    private weak var restoreView: NSView?
    private let playOpen: () -> Void
    private let completed: (UUID?) -> Void
    private var presented = false
    private var selectedProfile: UUID?

    init?(profiles: [QuickProfileEntry], owner: NSWindow?, playOpen: @escaping () -> Void,
        contextHelp: @escaping (Bool) -> Void, completed: @escaping (UUID?) -> Void) {
        guard !profiles.isEmpty else { return nil }
        self.profiles = profiles
        ownerWindow = owner
        restoreView = FocusedHelpContent.capture(in: owner).focusedView
        self.playOpen = playOpen
        self.completed = completed
        let list = QuickProfileTable()
        table = list
        let chooser = QuickProfileWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        chooser.title = "Quick Profile Switch"
        chooser.minSize = NSSize(width: 360, height: 260)
        chooser.isReleasedWhenClosed = false
        super.init(window: chooser)
        chooser.delegate = self
        chooser.cancelSelection = { [weak self] in self?.close() }
        chooser.contextHelp = contextHelp
        list.acceptSelection = { [weak self] in self?.acceptSelectedProfile() }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
        column.title = "Profiles"
        column.width = 440
        column.resizingMask = .autoresizingMask
        list.addTableColumn(column)
        list.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        list.headerView = nil
        list.allowsMultipleSelection = false
        list.rowHeight = 26
        list.usesAlternatingRowBackgroundColors = true
        list.setAccessibilityLabel("Saved profiles")
        list.setAccessibilityHelp("Use Up and Down to choose a profile, then Return to switch. The current profile is marked. Choosing it or pressing Escape closes without changing anything.")
        list.dataSource = self
        list.delegate = self
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = list
        let instructions = NSTextField(wrappingLabelWithString:
            "Arrow up and down to a profile, then press Return to switch. Escape closes without changing.")
        closeButton.target = self
        closeButton.action = #selector(cancelPressed)
        closeButton.setAccessibilityHelp("Close the profile list without switching. Escape and Command-W also close it.")
        let helpBindings: [(NSView, String)] = [
            (instructions, "dialog-quick-profile-instructions"),
            (list, "dialog-quick-profile-list"),
            (closeButton, "dialog-quick-profile-closebutton"),
        ]
        for (view, key) in helpBindings { view.identifier = NSUserInterfaceItemIdentifier("help-" + key) }
        let stack = NSStackView(views: [instructions, scroll, closeButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        chooser.contentView?.addSubview(stack)
        if let root = chooser.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
                stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
                instructions.widthAnchor.constraint(equalTo: stack.widthAnchor),
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            ])
        }
        table.nextKeyView = closeButton
        closeButton.nextKeyView = table
        chooser.moveTabFocus = { [weak self, weak chooser] backwards in
            guard let self, let chooser else { return }
            chooser.makeFirstResponder(chooser.firstResponder === self.table
                ? self.closeButton : self.table)
        }
        chooser.initialFirstResponder = list
        chooser.center()
        list.reloadData()
        list.selectRowIndexes(IndexSet(integer: profiles.firstIndex(where: \.isCurrent) ?? 0),
            byExtendingSelection: false)
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        guard !presented else { return }
        presented = true
        selectedProfile = nil
        window?.makeFirstResponder(table)
        table.scrollRowToVisible(table.selectedRow)
        playOpen()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard profiles.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("profile-title")
        let label = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        label.identifier = identifier
        label.stringValue = profiles[row].displayedTitle
        label.setAccessibilityLabel(label.stringValue)
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard presented, profiles.indices.contains(table.selectedRow) else { return }
        NSAccessibility.post(element: table, notification: .announcementRequested,
            userInfo: [.announcement: profiles[table.selectedRow].displayedTitle,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func acceptSelectedProfile() {
        guard presented, profiles.indices.contains(table.selectedRow) else { return }
        let selected = profiles[table.selectedRow]
        selectedProfile = selected.isCurrent ? nil : selected.id
        close()
    }

    @objc private func cancelPressed() { close() }

    func windowWillClose(_ notification: Notification) {
        guard presented else { return }
        presented = false
        if NSApp.modalWindow === window { NSApp.stopModal() }
        if let owner = ownerWindow, owner.isVisible {
            owner.makeKeyAndOrderFront(nil)
            if let restoreView, restoreView.window === owner { owner.makeFirstResponder(restoreView) }
        }
        completed(selectedProfile)
    }
}
