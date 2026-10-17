import AppKit
import RemSoundCore

/// The Server window: going to a RemSound server, or leaving it. Ed's design (Windows, 2026-09-20 and 2026-09-29):
/// - the servers you have been on come FIRST, then the box to type a new one; moving through the list puts the server in
///   the box, so Connect (or Return) goes to the one you are on;
/// - one action button saying what pressing it does now - Connect, or Disconnect when you are on a server - and Close;
/// - an acknowledged connection closes the window; progress and errors are announced;
/// - Delete in the list forgets that server.
final class ServerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private unowned let controller: JamController
    private let rememberedTable = ServerListTable()
    private let address = NSTextField()
    private let action = NSButton(title: "Connect", target: nil, action: nil)
    private let close = NSButton(title: "Close", target: nil, action: nil)
    private let status = FocusableStatusField(wrappingLabelWithString: "")
    private let explanation = FocusableStatusField(wrappingLabelWithString: JamController.serverExplanation)
    private let details = ServerStatusTextView(frame: NSRect(x: 0, y: 0, width: 488, height: 190))
    private let detailsScroll = NSScrollView()
    private var showingDetails = false
    private var remembered: [String] = []
    private var connected = false
    private var actionStatus: String?
    private var lastConnectionStatus = ""

    init(controller: JamController) {
        self.controller = controller
        let window = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 610),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Server"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contextHelp = { [weak controller, weak window] manual in
            guard let window else { return }
            controller?.contextHelp?(manual, window)
        }
        build()
        window.moveTabFocus = { [weak self] backwards in self?.moveFocus(backwards: backwards) ?? false }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        guard let content = window?.contentView else { return }
        let helpBindings: [(NSView, String)] = [
            (rememberedTable, "dialog-server-rememberedtable"),
            (address, "dialog-server-address"),
            (action, "dialog-server-action"),
            (close, "dialog-server-close"),
            (status, "dialog-server-status"),
            (explanation, "dialog-server-explanation"),
            (details, "dialog-server-details"),
        ]
        for (view, key) in helpBindings { view.identifier = NSUserInterfaceItemIdentifier("help-" + key) }
        let rememberedLabel = NSTextField(labelWithString: "Remembered servers:")
        let addressLabel = NSTextField(labelWithString: "Server address:")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("server"))
        column.title = "Remembered servers"
        rememberedTable.addTableColumn(column)
        rememberedTable.headerView = nil
        rememberedTable.dataSource = self
        rememberedTable.delegate = self
        rememberedTable.setAccessibilityLabel("Remembered servers")
        rememberedTable.setAccessibilityHelp("Servers you have been on. Return connects to the selected one; Delete forgets it.")
        rememberedTable.onReturn = { [weak self] in self?.connectToSelection() }
        rememberedTable.onDelete = { [weak self] in self?.forgetSelection() }
        rememberedTable.doubleAction = #selector(connectToSelectionAction)
        rememberedTable.target = self
        let scroll = NSScrollView()
        scroll.documentView = rememberedTable
        scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        address.placeholderString = "server name or address, e.g. remote.example.com"
        address.setAccessibilityLabel("Server address")
        address.setAccessibilityHelp("Enter a server name or IPv4 address, optionally followed by a colon and port. Press Return or choose Connect to join its group.")
        address.delegate = self
        address.target = self
        address.action = #selector(performAction)

        action.target = self
        action.action = #selector(performAction)
        action.keyEquivalent = "\r"
        action.keyEquivalentModifierMask = []
        action.setAccessibilityHelp("Connect starts RemSound if needed and joins the server using the current profile's password. Existing selected peers remain active. Disconnect leaves only the server. Connection errors are announced.")
        close.target = self
        close.action = #selector(closeWindow)
        close.keyEquivalent = "\u{1b}"
        close.keyEquivalentModifierMask = []
        close.setAccessibilityLabel("Close server window")
        close.setAccessibilityHelp("Close this window without changing the server connection.")
        status.setAccessibilityLabel("Server connection progress")
        status.setAccessibilityHelp("The progress or result of the server connection. You can return to this field to read an error again.")
        explanation.setAccessibilityLabel("How server connections work")
        explanation.isSelectable = true
        explanation.setAccessibilityHelp("Explains the profile password, session startup, peer selections and leaving a server.")

        detailsScroll.hasVerticalScroller = true
        detailsScroll.documentView = details
        detailsScroll.heightAnchor.constraint(equalToConstant: 190).isActive = true
        detailsScroll.isHidden = true
        details.notifyValue = { view in
            guard view.window?.isVisible == true, AppRuntime.configuration?.silent == false else { return }
            NSAccessibility.post(element: view, notification: .valueChanged)
        }

        let buttons = NSStackView(views: [action, close])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [rememberedLabel, scroll, addressLabel, address, buttons, status, detailsScroll, explanation])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            address.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            detailsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        // Keyboard order: the list, the box, the action, Close.
        rememberedTable.nextKeyView = address
        address.nextKeyView = action
        action.nextKeyView = close
        close.nextKeyView = status
        status.nextKeyView = explanation
        explanation.nextKeyView = rememberedTable
    }

    func reloadRemembered() {
        remembered = controller.rememberedServers
        rememberedTable.reloadData()
        let opening = connected ? controller.view.server : (remembered.first ?? "")
        if let index = remembered.firstIndex(of: opening) {
            rememberedTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        address.stringValue = opening
        // It opens on the list when there is one; with none, on the box.
        window?.initialFirstResponder = remembered.isEmpty ? address : rememberedTable
        window?.makeFirstResponder(remembered.isEmpty ? address : rememberedTable)
    }

    func update(_ view: JamView) {
        if view.serverStatus != lastConnectionStatus { actionStatus = nil; lastConnectionStatus = view.serverStatus }
        connected = view.connected
        action.title = view.connected ? "Disconnect" : "Connect"
        action.isEnabled = view.connected || !view.serverStatus.hasPrefix("Checking ")
        action.setAccessibilityLabel(view.connected ? "Disconnect from server" : "Connect to server")
        let showDetails = view.connected && view.serverDetails != nil
        status.isHidden = showDetails && actionStatus == nil
        if status.isHidden, window?.firstResponder === status || (status.currentEditor() != nil && status.currentEditor() === window?.firstResponder) {
            window?.makeFirstResponder(details)
        }
        if !showDetails, window?.firstResponder === details { window?.makeFirstResponder(status) }
        detailsScroll.isHidden = !showDetails
        showingDetails = showDetails
        close.nextKeyView = status.isHidden ? details : status
        status.nextKeyView = showDetails ? details : explanation
        details.nextKeyView = explanation
        if let text = view.serverDetails { details.update(text) }
        showStatus(actionStatus ?? view.serverStatus)
    }

    func showActionStatus(_ message: String) {
        actionStatus = message
        status.isHidden = false
        close.nextKeyView = status
        status.nextKeyView = showingDetails ? details : explanation
        showStatus(message)
    }

    func showStatus(_ message: String) {
        if status.stringValue != message {
            status.stringValue = message
            NSAccessibility.post(element: status, notification: .valueChanged)
        }
    }

    private var controlOrder: [NSView] {
        var order: [NSView] = remembered.isEmpty ? [] : [rememberedTable]
        order += [address, action, close]
        if !status.isHidden { order.append(status) }
        if showingDetails { order.append(details) }
        order.append(explanation)
        return order
    }

    private func moveFocus(backwards: Bool) -> Bool {
        guard let window else { return false }
        let order = controlOrder
        let index = order.firstIndex { control in
            window.firstResponder === control
                || (control as? NSTextField)?.currentEditor() === window.firstResponder
                || (window.firstResponder as? NSView)?.isDescendant(of: control) == true
        }
        let next = index.map { ($0 + (backwards ? order.count - 1 : 1)) % order.count }
            ?? (backwards ? order.count - 1 : 0)
        return window.makeFirstResponder(order[next])
    }

    func accessibilityFailures(expectedDetails: String? = nil) -> [String] {
        var failures = [String]()
        if let expectedDetails, !showingDetails || details.string != expectedDetails {
            failures.append("Opening the Server window must show the newest detailed snapshot")
        }
        if action.keyEquivalent != "\r" || !action.keyEquivalentModifierMask.isEmpty
            || close.keyEquivalent != "\u{1b}" || !close.keyEquivalentModifierMask.isEmpty {
            failures.append("Server Connect and Close must accept plain Return and Escape")
        }
        if action.accessibilityHelp()?.contains("starts RemSound if needed") != true
            || !explanation.isSelectable || explanation.stringValue != JamController.serverExplanation {
            failures.append("Server window must explain automatic startup, the shared password and existing peers")
        }
        for control in [address, action, close, status, explanation] as [NSView] {
            if (control.accessibilityLabel() ?? "").isEmpty || (control.accessibilityHelp() ?? "").isEmpty {
                failures.append("Server controls must expose names and help")
            }
        }
        for backwards in [false, true] {
            let order = backwards ? Array(controlOrder.reversed()) : controlOrder
            guard let first = order.first, window?.makeFirstResponder(first) == true else {
                failures.append("Server window must accept keyboard focus")
                continue
            }
            for expected in order.dropFirst() + [first] {
                let moved = moveFocus(backwards: backwards)
                let focused = window?.firstResponder === expected
                    || (expected as? NSTextField)?.currentEditor() === window?.firstResponder
                if !moved || !focused {
                    failures.append("Server \(backwards ? "Shift-Tab" : "Tab") must reach every control")
                }
            }
        }
        if details.isEditable || !details.isSelectable || details.accessibilityRole() != .textArea
            || details.accessibilityLabel() != "Server status" || (details.accessibilityHelp() ?? "").isEmpty {
            failures.append("Server details must be a named native read-only selectable multiline field")
        }
        return failures
    }

    /// Close only after the server has acknowledged group membership.
    func closeAfterConnecting() {
        window?.orderOut(nil)
    }

    @objc private func performAction() {
        if connected {
            controller.disconnect()
            return
        }
        let typed = address.stringValue.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else {
            status.stringValue = "Type a server address first."
            controller.announce("Type a server address first.")
            return
        }
        controller.connect(typed)
    }

    @objc private func connectToSelectionAction() { connectToSelection() }

    private func connectToSelection() {
        let row = rememberedTable.selectedRow
        guard row >= 0, row < remembered.count else { return }
        address.stringValue = remembered[row]
        controller.connectRemembered(remembered[row])
    }

    private func forgetSelection() {
        let row = rememberedTable.selectedRow
        guard row >= 0, row < remembered.count else { return }
        let doomed = remembered[row]
        controller.forget(doomed)
        remembered = controller.rememberedServers
        rememberedTable.reloadData()
        if !remembered.isEmpty {
            rememberedTable.selectRowIndexes(IndexSet(integer: min(row, remembered.count - 1)), byExtendingSelection: false)
        }
        controller.announce("\(doomed) removed")
    }

    @objc private func closeWindow() { window?.orderOut(nil) }

    // MARK: the list

    func numberOfRows(in tableView: NSTableView) -> Int { remembered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: remembered[row])
        cell.setAccessibilityLabel(remembered[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = rememberedTable.selectedRow
        if row >= 0, row < remembered.count { address.stringValue = remembered[row] }
    }
}

/// The remembered-servers list: Return connects, Delete forgets.
final class ServerListTable: NSTableView {
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()          // Return, Enter
        case 51, 117: onDelete?()         // Delete, Forward Delete
        default: super.keyDown(with: event)
        }
    }
}
