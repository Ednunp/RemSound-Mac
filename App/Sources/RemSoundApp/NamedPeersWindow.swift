import AppKit
import Carbon
import RemSoundRuntime

private final class NamedPeersTable: NSTableView {
    var renameSelection: (() -> Void)?
    var forgetSelection: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty, event.keyCode == UInt16(kVK_F2) { renameSelection?(); return }
        if modifiers.isEmpty, event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            forgetSelection?(); return
        }
        if modifiers == .command, event.charactersIgnoringModifiers == "a" { selectAll(nil); return }
        super.keyDown(with: event)
    }
}

/// A view of the Session owner's existing machine-wide book; no separate persistence or polling.
final class NamedPeersWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let table: NSTableView = NamedPeersTable()
    let renameButton = NSButton(title: "Rename…", target: nil, action: nil)
    let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    let closeButton = NSButton(title: "Close", target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "")
    private(set) var records: [NamedPeerRecord] = []
    private weak var alertHelpDelegate: NSAlertDelegate?
    private let read: () -> [NamedPeerRecord]?
    private let rename: (NamedPeerRecord, String) -> Bool
    private let forget: ([NamedPeerRecord]) -> Bool
    private let announce: (String) -> Void
    private weak var ownerWindow: NSWindow?
    private weak var restoreFocus: NSView?
    private var presented = false
    var namePrompt: ((NamedPeerRecord) -> String?)?

    init(owner: NSWindow?, contextHelp: ((Bool, NSWindow) -> Void)? = nil, alertHelpDelegate: NSAlertDelegate? = nil, read: @escaping () -> [NamedPeerRecord]?,
        rename: @escaping (NamedPeerRecord, String) -> Bool,
        forget: @escaping ([NamedPeerRecord]) -> Bool, announce: @escaping (String) -> Void) {
        ownerWindow = owner
        restoreFocus = FocusedHelpContent.capture(in: owner).focusedView
        self.alertHelpDelegate = alertHelpDelegate
        self.read = read; self.rename = rename; self.forget = forget; self.announce = announce
        let panel = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Manage Named Peers"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        if let contextHelp {
            panel.contextHelp = { [weak panel] manual in
                guard let panel else { return }
                contextHelp(manual, panel)
            }
        }
        panel.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading
        stack.spacing = 12; stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        }
        let intro = NSTextField(wrappingLabelWithString:
            "Names apply across profiles. Deleting forgets the name only; the peer still connects normally.")
        stack.addArrangedSubview(intro)
        let column = NSTableColumn(identifier: .init("name")); column.width = 600
        table.addTableColumn(column); table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil; table.allowsMultipleSelection = true
        table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel("Named peers")
        table.setAccessibilityHelp("Arrow keys choose peers. F2 renames one; Delete forgets selected names. Command A selects all.")
        let list = table as! NamedPeersTable
        list.renameSelection = { [weak self] in self?.renameSelected() }
        list.forgetSelection = { [weak self] in self?.deleteSelected() }
        table.target = self; table.doubleAction = #selector(renameSelected)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        stack.addArrangedSubview(status)
        status.setAccessibilityLabel("Named peers status")
        let buttons = NSStackView(views: [renameButton, deleteButton, closeButton])
        buttons.spacing = 12; stack.addArrangedSubview(buttons)
        renameButton.target = self; renameButton.action = #selector(renameSelected)
        deleteButton.target = self; deleteButton.action = #selector(deleteSelected)
        closeButton.target = self; closeButton.action = #selector(closePanel)
        renameButton.keyEquivalent = "r"; renameButton.keyEquivalentModifierMask = .option
        deleteButton.keyEquivalent = "d"; deleteButton.keyEquivalentModifierMask = .option
        closeButton.keyEquivalent = "\u{1b}"
        table.nextKeyView = renameButton; renameButton.nextKeyView = deleteButton
        deleteButton.nextKeyView = closeButton; closeButton.nextKeyView = table
        let helpBindings: [(NSView, String)] = [
            (intro, "dialog-named-peers-intro"),
            (table, "dialog-named-peers-table"),
            (renameButton, "dialog-named-peers-renamebutton"),
            (deleteButton, "dialog-named-peers-deletebutton"),
            (closeButton, "dialog-named-peers-closebutton"),
            (status, "dialog-named-peers-status"),
        ]
        for (view, key) in helpBindings { view.identifier = NSUserInterfaceItemIdentifier("help-" + key) }
        panel.initialFirstResponder = table
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() {
        restoreFocus = FocusedHelpContent.capture(in: ownerWindow).focusedView
        presented = true
        showWindow(nil); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(table)
    }
    func refresh() {
        let selected = Set(table.selectedRowIndexes.compactMap { records.indices.contains($0) ? records[$0].machineName.lowercased() : nil })
        let previous = max(0, table.selectedRow)
        guard let next = read() else {
            records = []; table.reloadData(); status.stringValue = "Named peers could not be read. No names were changed."
            updateButtons(); return
        }
        if next != records {
            records = next; table.reloadData()
            let preserved = IndexSet(records.indices.filter { selected.contains(records[$0].machineName.lowercased()) })
            table.selectRowIndexes(preserved.isEmpty && !records.isEmpty ? IndexSet(integer: min(previous, records.count - 1)) : preserved,
                byExtendingSelection: false)
        }
        status.stringValue = records.isEmpty ? "No named peers yet." : "\(records.count) named peers."
        updateButtons()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { records.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row) else { return nil }
        let record = records[row]
        let formatter = DateFormatter(); formatter.dateFormat = "d MMM yyyy"
        let seen = record.lastSeen.map { "last seen " + formatter.string(from: $0) } ?? "not seen yet"
        return NSTextField(labelWithString: "\(record.friendlyName), \(record.machineName), \(seen)" + (record.lastAddress.map { ", \($0)" } ?? ""))
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    private func updateButtons() {
        renameButton.isEnabled = table.selectedRowIndexes.count == 1
        deleteButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }
    static func buildRenameAlert(machine: String, initial: String, helpDelegate: NSAlertDelegate? = nil) -> (NSAlert, NSTextField) {
        let alert = NSAlert(); alert.messageText = "Rename Named Peer"
        alert.informativeText = "Name for \(machine), across profiles. Clear the field to forget this name."
        alert.addButton(withTitle: "Save Name"); alert.addButton(withTitle: "Cancel")
        let input = NSTextField(string: initial)
        input.setAccessibilityLabel("Peer name"); input.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
        alert.accessoryView = input; alert.window.initialFirstResponder = input
        input.identifier = NSUserInterfaceItemIdentifier("help-dialog-named-rename-input")
        FocusedHelpContent.markAlert(alert, notice: "dialog-named-rename-notice", buttons: ["dialog-named-rename-accept", "dialog-named-rename-cancel"], helpDelegate: helpDelegate)
        return (alert, input)
    }
    func makeRenameAlert(machine: String, initial: String) -> (NSAlert, NSTextField) {
        Self.buildRenameAlert(machine: machine, initial: initial, helpDelegate: alertHelpDelegate)
    }
    @objc func renameSelected() {
        guard table.selectedRowIndexes.count == 1, records.indices.contains(table.selectedRow) else { return }
        let record = records[table.selectedRow]
        let choice: String?
        if let namePrompt { choice = namePrompt(record) }
        else {
            let (alert, input) = makeRenameAlert(machine: record.machineName, initial: record.friendlyName)
            choice = alert.runModal() == .alertFirstButtonReturn ? input.stringValue : nil
        }
        guard let choice else { return }
        let saved = rename(record, choice)
        refresh()
        let message = saved ? "Peer name saved." : "The name could not be saved or changed while editing. Review the current list."
        status.stringValue = message; announce(message)
    }
    @objc func deleteSelected() {
        let selected = table.selectedRowIndexes.compactMap { records.indices.contains($0) ? records[$0] : nil }
        guard !selected.isEmpty else { return }
        let saved = forget(selected)
        refresh()
        let message = saved ? "Selected names forgotten. Connections are unchanged." : "Names could not be forgotten or changed while editing. Review the current list."
        status.stringValue = message; announce(message)
    }
    @objc private func closePanel() { close() }
    func windowWillClose(_ notification: Notification) {
        guard presented else { return }
        presented = false
        ownerWindow?.makeKeyAndOrderFront(nil)
        if let restoreFocus { ownerWindow?.makeFirstResponder(restoreFocus) }
    }
}
