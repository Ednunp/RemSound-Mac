import AppKit
import RemSoundRuntime

/// Owns stable cue lists; settings refreshes never rebuild a focused list or change its selected row.
final class CuePreferencesPane: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSStackView()
    let mute = NSButton(checkboxWithTitle: "Turn all audio cues off", target: nil, action: nil)
    let keyboardClicks = NSButton(checkboxWithTitle: "Play keyboard clicks when typing into any edit field, for this profile", target: nil, action: nil)
    let globalList = NSTableView()
    let profileList = NSTableView()
    let choice = NSPopUpButton(frame: .zero, pullsDown: false)
    let play = NSButton(title: "Play", target: nil, action: nil)
    let browse = NSButton(title: "Browse", target: nil, action: nil)
    let scope = NSTextField(wrappingLabelWithString: "")
    private let cues: CueSounds
    private var selecting = false
    private(set) var selectedEvent = CueEvent.save
    var customFiles: [CueEvent: String] = [:]
    var onKeyboardClicksChanged: (() -> Void)?
    var tabOrder: [NSView] { [mute, globalList, profileList, choice, play, browse, keyboardClicks] }

    init(cues: CueSounds) {
        self.cues = cues
        super.init()
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 12
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("Audio cues preferences controls")
        mute.setAccessibilityLabel("Turn all audio cues off")
        mute.setAccessibilityHelp("Silence every automatic audio cue, error beep and DAW plugin Help sound on this Mac. Saved immediately for every profile without marking the profile unsaved. Audio cues list previews still play. The push-to-talk speed preview follows this mute. Untick to restore your choices.")
        view.addArrangedSubview(mute)
        let lists = NSStackView(views: [
            makeList(globalList, title: "Global sounds, for every profile"),
            makeList(profileList, title: "Profile sounds")
        ])
        lists.orientation = .horizontal
        lists.alignment = .top
        lists.distribution = .fillEqually
        lists.spacing = 16
        view.addArrangedSubview(lists)
        lists.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        view.addArrangedSubview(choice)
        let actions = NSStackView(views: [play, browse])
        actions.orientation = .horizontal
        actions.spacing = 12
        view.addArrangedSubview(actions)
        scope.setAccessibilityElement(true)
        view.addArrangedSubview(scope)
        scope.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        keyboardClicks.setAccessibilityLabel(keyboardClicks.title)
        keyboardClicks.setAccessibilityHelp("Play typing sounds in RemSound edit fields. This choice belongs to the current profile and takes effect immediately. Save Profile keeps it. Turn all audio cues off silences typing without changing this choice.")
        keyboardClicks.target = self
        keyboardClicks.action = #selector(keyboardClicksChanged)
        view.addArrangedSubview(keyboardClicks)
        let helpBindings: [(NSView, String)] = [
            (scope, "dialog-cues-scope"),
            (mute, "dialog-cues-mute"),
            (globalList, "dialog-cues-globallist"),
            (profileList, "dialog-cues-profilelist"),
            (choice, "dialog-cues-choice"),
            (play, "dialog-cues-play"),
            (browse, "dialog-cues-browse"),
            (keyboardClicks, "dialog-cues-keyboardclicks"),
        ]
        for (view, key) in helpBindings { view.identifier = NSUserInterfaceItemIdentifier("help-" + key) }
        select(.save, preview: false)
    }

    @objc private func keyboardClicksChanged() {
        cues.preferences.setKeyboardClicksEnabled(keyboardClicks.state == .on)
        onKeyboardClicksChanged?()
        NSAccessibility.post(element: keyboardClicks, notification: .valueChanged)
    }

    private func makeList(_ table: NSTableView, title: String) -> NSStackView {
        table.headerView = nil
        table.rowHeight = 24
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel(title)
        table.setAccessibilityHelp("Use Up and Down to choose an event and preview its current sound. Off stays silent, and previews remain available when all audio cues are turned off. Choose sound, Play and Browse act on the last event selected in either list. " +
            (table === globalList ? "These choices save immediately for every profile." : "Save Profile keeps these choices in the current profile."))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cue"))
        column.width = 240
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        scroll.setAccessibilityLabel(title)
        scroll.heightAnchor.constraint(equalToConstant: 224).isActive = true
        let label = NSTextField(wrappingLabelWithString: title)
        label.identifier = NSUserInterfaceItemIdentifier(table === globalList ? "help-dialog-cues-globallist" : "help-dialog-cues-profilelist")
        let columnView = NSStackView(views: [label, scroll])
        columnView.orientation = .vertical
        columnView.alignment = .leading
        columnView.spacing = 6
        scroll.widthAnchor.constraint(equalTo: columnView.widthAnchor).isActive = true
        label.widthAnchor.constraint(equalTo: columnView.widthAnchor).isActive = true
        table.reloadData()
        return columnView
    }

    private func events(in table: NSTableView) -> [CueEvent] {
        table === globalList ? CueEvent.globalEvents : CueEvent.profileEvents
    }
    func numberOfRows(in tableView: NSTableView) -> Int { events(in: tableView).count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let events = events(in: tableView)
        guard events.indices.contains(row) else { return nil }
        let field = NSTextField(labelWithString: events[row].title)
        field.setAccessibilityLabel(events[row].title)
        field.setAccessibilityHelp(tableView.accessibilityHelp())
        return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, let table = notification.object as? NSTableView,
            table === globalList || table === profileList else { return }
        let events = events(in: table)
        guard events.indices.contains(table.selectedRow) else { return }
        select(events[table.selectedRow], preview: true)
    }
    func select(_ event: CueEvent, preview: Bool) {
        let table = event.isProfileSetting ? profileList : globalList
        guard let row = events(in: table).firstIndex(of: event) else { return }
        selecting = true
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        selecting = false
        selectedEvent = event
        refresh()
        if preview { cues.play(event, preview: true) }
    }
    func refresh() {
        let event = selectedEvent
        let value = cues.preferences.configuration(for: event)
        if let path = value.customPath { customFiles[event] = path }
        mute.state = cues.preferences.muteAllCues ? .on : .off
        keyboardClicks.state = cues.preferences.keyboardClicksEnabled ? .on : .off
        scope.stringValue = event.isProfileSetting
            ? "Enabled state, built-in sound and your own file are saved in the current profile."
            : "Enabled state, built-in sound and your own file apply to every profile on this Mac and save immediately."
        choice.setAccessibilityLabel("Choose sound for \(event.title)")
        choice.setAccessibilityHelp("(none) silences this event and keeps your own file. " + scope.stringValue)
        play.setAccessibilityLabel("Play \(event.title) sound")
        play.setAccessibilityHelp("Preview \(event.title) without changing the connection, even when all audio cues are off. An event set to (none) stays silent.")
        browse.setAccessibilityLabel("Browse for \(event.title) sound")
        browse.setAccessibilityHelp("Choose a WAV file for \(event.title). Choosing a file enables its sound. Missing or unreadable custom files fall back to the chosen built-in sound. " + scope.stringValue)
        choice.removeAllItems()
        choice.addItem(withTitle: "\(event.title), (none)")
        choice.lastItem?.representedObject = "Off"
        if let path = customFiles[event] {
            choice.addItem(withTitle: "\(event.title), Your own file: \((path as NSString).lastPathComponent)")
            choice.lastItem?.representedObject = "Custom"
        }
        let variants = cues.variants(for: event)
        for name in variants {
            choice.addItem(withTitle: "\(event.title), Sound \((name as NSString).deletingPathExtension.split(separator: " ").last ?? "1")")
            choice.lastItem?.representedObject = name
        }
        let selected = !value.enabled ? "Off" : value.customPath != nil ? "Custom"
            : cues.preferences.builtInSelection(for: event, variants: variants) ?? "Off"
        choice.selectItem(at: choice.itemArray.firstIndex { $0.representedObject as? String == selected } ?? 0)
        play.isEnabled = value.enabled
    }
}
