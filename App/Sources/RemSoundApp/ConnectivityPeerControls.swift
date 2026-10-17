import AppKit
import Carbon
import RemSoundCore

final class RememberedPeerTable: NSTableView {
    var connect: (() -> Void)?
    var forget: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)
            || event.charactersIgnoringModifiers == " " { connect?(); return }
        if event.specialKey == .delete || event.specialKey == .deleteForward { forget?(); return }
        super.keyDown(with: event)
    }
}

/// Native presentation only: Session owns connections and the machine-wide remembered book.
final class ConnectivityPeerControls: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let view = NSStackView()
    let lockAddresses = NSButton(checkboxWithTitle: "Keep peer addresses exactly as saved in this profile", target: nil, action: nil)
    let entry = NSTextField()
    let add = NSButton(title: "Add peer", target: nil, action: nil)
    let cancel = NSButton(title: "Cancel Add", target: nil, action: nil)
    let remembered = RememberedPeerTable()
    let connect = NSButton(title: "Connect remembered peer", target: nil, action: nil)
    let forget = NSButton(title: "Forget peer", target: nil, action: nil)
    let clear = NSButton(title: "Clear remembered peers", target: nil, action: nil)
    var onAdd: ((String, @escaping (PeerAddResult) -> Void) -> Void)? { didSet { updateAvailability() } }
    var onCancel: (() -> Void)?
    var onForget: ((String, @escaping (Bool) -> Void) -> Void)? { didSet { updateAvailability() } }
    var onClear: ((@escaping (Bool) -> Void) -> Void)? { didSet { updateAvailability() } }
    var onLock: ((Bool) -> Void)?
    var onNotice: ((String) -> Void)?
    private(set) var entries: [String] = []
    private(set) var reloadCount = 0
    private(set) var adding = false
    private var running = false
    private var addToken: UUID?
    private var bookToken: UUID?
    var keyViews: [NSView] { [lockAddresses, entry, add, cancel, remembered, connect, forget, clear] }
    /// The remembered list, its heading and its buttons: hidden together when Preferences says not to show the list.
    private var rememberedViews: [NSView] = []
    func showRememberedList(_ shown: Bool) { for view in rememberedViews where view.isHidden == shown { view.isHidden = !shown } }

    override init() {
        super.init()
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 6
        lockAddresses.target = self
        lockAddresses.action = #selector(lockChanged)
        lockAddresses.setAccessibilityLabel(lockAddresses.title)
        lockAddresses.setAccessibilityHelp("This profile keeps its saved IP addresses and ports. Off allows the selected discovery identity to follow a changed address.")
        view.addArrangedSubview(lockAddresses)
        entry.placeholderString = "IPv4 address or hostname, optional :port"
        entry.setAccessibilityLabel("Add peer IPv4 address or hostname")
        entry.setAccessibilityHelp("Add another computer while RemSound is running. An optional port is kept with the typed hostname. Return adds the peer; Escape cancels an outstanding Add.")
        entry.delegate = self
        entry.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        add.target = self; add.action = #selector(addPressed)
        cancel.target = self; cancel.action = #selector(cancelPressed)
        cancel.keyEquivalent = "\u{1b}"
        cancel.keyEquivalentModifierMask = []
        add.setAccessibilityLabel(add.title); cancel.setAccessibilityLabel(cancel.title)
        add.setAccessibilityHelp("Select and remember this computer without stopping the current connections.")
        cancel.setAccessibilityHelp("Cancel the pending hostname lookup. Existing peer selections remain.")
        view.addArrangedSubview(NSStackView(views: [entry, add, cancel]))
        let rememberedHeading = NSTextField(labelWithString: "Remembered peers — Return or Space connects; Delete forgets")
        view.addArrangedSubview(rememberedHeading)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rememberedPeer"))
        column.title = "Remembered peer"; column.width = 620
        remembered.addTableColumn(column)
        remembered.headerView = nil
        remembered.dataSource = self; remembered.delegate = self
        remembered.setAccessibilityLabel("Remembered peers")
        remembered.setAccessibilityHelp("Entries not currently selected. Arrow keys choose an entry; Return or Space connects; Delete forgets only that stored entry.")
        remembered.connect = { [weak self] in self?.connectPressed() }
        remembered.forget = { [weak self] in self?.forgetPressed() }
        let scroll = NSScrollView()
        scroll.documentView = remembered; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 80).isActive = true
        view.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        rememberedViews = [rememberedHeading, scroll]
        for (button, action) in [(connect, #selector(connectPressed)), (forget, #selector(forgetPressed)), (clear, #selector(clearPressed))] {
            button.target = self; button.action = action
            button.setAccessibilityLabel(button.title)
        }
        forget.setAccessibilityHelp("Remove this entry from the machine-wide remembered history. Current selections stay connected.")
        clear.setAccessibilityHelp("Clear remembered history for every profile. Current selections stay connected.")
        let rememberedButtons = NSStackView(views: [connect, forget, clear])
        view.addArrangedSubview(rememberedButtons)
        rememberedViews.append(rememberedButtons)
        for (index, control) in keyViews.enumerated() {
            control.nextKeyView = index + 1 < keyViews.count ? keyViews[index + 1] : nil
        }
        updateAvailability()
    }

    func refresh(entries: [String], running: Bool, locked: Bool) {
        if self.running && !running { cancelAdd(notify: false) }
        self.running = running
        lockAddresses.state = locked ? .on : .off
        replaceEntries(entries)
        updateAvailability()
    }
    private var selectedEntry: String? { entries.indices.contains(remembered.selectedRow) ? entries[remembered.selectedRow] : nil }
    private func replaceEntries(_ values: [String]) {
        guard values != entries else { return }
        let selection = selectedEntry, previousIndex = remembered.selectedRow
        entries = values; reloadCount += 1; remembered.reloadData()
        if let selection, let index = entries.firstIndex(of: selection) {
            remembered.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !entries.isEmpty {
            remembered.selectRowIndexes(IndexSet(integer: min(max(0, previousIndex), entries.count - 1)), byExtendingSelection: false)
        } else { remembered.deselectAll(nil) }
    }
    private func updateAvailability() {
        entry.isEnabled = running && !adding && bookToken == nil
        add.isEnabled = running && !adding && bookToken == nil && onAdd != nil && !entry.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        cancel.isEnabled = adding
        connect.isEnabled = running && !adding && bookToken == nil && selectedEntry != nil && onAdd != nil
        forget.isEnabled = selectedEntry != nil && bookToken == nil && onForget != nil
        clear.isEnabled = !entries.isEmpty && bookToken == nil && onClear != nil
    }
    func handlesOperationStatus(_ message: String) -> Bool {
        if bookToken != nil && ["Remembered peer removed.", "Remembered peer list cleared.", "Could not save remembered peer list."].contains(message) { return true }
        return adding && ["Peer added.", "Peer added, but could not save remembered peer list.", "Enter a valid IPv4 address or hostname, with an optional port from 1 to 65535.", "Start RemSound first, then add a peer.", "Could not resolve that IP address or hostname.", "That's a known server. Use Connect to server.", "The direct peer selection list is full."].contains(message)
    }
    @objc private func lockChanged() { onLock?(lockAddresses.state == .on) }
    @objc private func addPressed() { beginAdd(entry.stringValue, fromEntryField: true) }
    @objc private func connectPressed() {
        guard let selectedEntry else { return }
        beginAdd(selectedEntry, fromEntryField: false)
    }
    private func beginAdd(_ text: String, fromEntryField: Bool) {
        guard running, !adding, bookToken == nil, let onAdd, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = UUID(); addToken = token; adding = true; updateAvailability()
        onAdd(text) { [weak self] result in
            guard let self, self.addToken == token else { return }
            self.addToken = nil; self.adding = false
            switch result {
            case .added(_, let remembered):
                if fromEntryField { self.entry.stringValue = "" }
                self.onNotice?(remembered ? "Peer added." : "Peer added, but could not save remembered peer list.")
            case .knownServer: self.onNotice?("That's a known server. Use Connect to server.")
            case .notRunning: self.onNotice?("Start RemSound first, then add a peer.")
            case .invalidEntry: self.onNotice?("Enter a valid IPv4 address or hostname, with an optional port from 1 to 65535.")
            case .unresolved: self.onNotice?("Could not resolve that IP address or hostname.")
            case .limitReached: self.onNotice?("The direct peer selection list is full.")
            }
            self.updateAvailability()
        }
    }
    @objc private func cancelPressed() { cancelAdd(notify: true) }
    private func cancelAdd(notify: Bool) {
        guard adding else { return }
        addToken = nil; adding = false; onCancel?(); updateAvailability()
        if notify { onNotice?("Add cancelled. Existing connections are unchanged.") }
    }
    @objc private func forgetPressed() {
        guard let selectedEntry, bookToken == nil, let onForget else { return }
        cancelAdd(notify: false)
        let token = UUID(); bookToken = token; updateAvailability()
        onForget(selectedEntry) { [weak self] saved in
            guard let self, self.bookToken == token else { return }
            self.bookToken = nil
            if saved {
                self.replaceEntries(self.entries.filter { $0 != selectedEntry })
                self.remembered.window?.makeFirstResponder(self.remembered)
                self.onNotice?("\(selectedEntry) removed. \(self.selectedEntry.map { $0 + "." } ?? "The list is empty.")")
            } else { self.onNotice?("Could not forget \(selectedEntry). The remembered list was not saved.") }
            self.updateAvailability()
        }
    }
    @objc private func clearPressed() {
        guard !entries.isEmpty, bookToken == nil, let onClear else { return }
        cancelAdd(notify: false)
        let token = UUID(); bookToken = token; updateAvailability()
        onClear { [weak self] saved in
            guard let self, self.bookToken == token else { return }
            self.bookToken = nil
            if saved {
                self.replaceEntries([])
                self.onNotice?("Remembered peer list cleared. Current connections are unchanged.")
            } else { self.onNotice?("Could not clear the remembered peer list. It was not saved.") }
            self.updateAvailability()
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let label = NSTextField(labelWithString: entries[row]); label.setAccessibilityLabel(entries[row]); return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateAvailability() }
    func controlTextDidChange(_ notification: Notification) { updateAvailability() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { addPressed(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), adding { cancelPressed(); return true }
        return false
    }
}
