import AppKit
import RemSoundCore
import RemSoundJam
import RemSoundRuntime

/// The rest of Windows' Preferences (PreferencesDialog: Appearance, Startup behaviour, Logging), on the Mac's General tab.
/// All machine-wide, as on Windows. AppDelegate owns the window and the session; this owns these controls and their
/// settings, and asks AppDelegate (the closures) for what only it can do.
@MainActor
final class PreferencesExtras: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    // Keys, machine-wide.
    static let themeKey = "RemSoundTheme"
    static let tabOrderKey = "RemSoundMainTabOrder"
    static let showPanEqTabKey = "RemSoundShowPanEqTab"
    static let showRememberedPeersKey = "RemSoundShowRememberedPeers"
    static let rememberWindowKey = "RemSoundRememberMainWindowPlacement"
    static let windowFrameKey = "RemSoundMainWindowFrame"
    static let startMinimisedKey = "RemSoundStartMinimised"
    static let startProfileKey = "RemSoundStartWithProfile"
    static let helpMessageKey = "RemSoundShowF1HelpMessageAtStartup"

    static let defaultTabOrder = ["Connectivity", "Audio I/O", "Recording / Profiles", "Pan / EQ"]
    static let themes = [("system", "Follow the Mac"), ("light", "Light"), ("dark", "Dark")]

    // Appearance.
    let theme = NSPopUpButton()
    let tabOrderList = NSTableView()
    let tabOrderScroll = NSScrollView()
    let moveTabUp = NSButton(title: "Move tab up", target: nil, action: nil)
    let moveTabDown = NSButton(title: "Move tab down", target: nil, action: nil)
    let showPanEqTab = NSButton(checkboxWithTitle: "Show the Pan / EQ tab", target: nil, action: nil)
    let showRememberedPeers = NSButton(checkboxWithTitle: "Show the remembered peers list on the Connectivity tab", target: nil, action: nil)
    let rememberWindow = NSButton(checkboxWithTitle: "Remember the main window's size and position", target: nil, action: nil)
    // Startup.
    let startMinimised = NSButton(checkboxWithTitle: "Start hidden in the menu bar", target: nil, action: nil)
    let startWithProfile = NSButton(checkboxWithTitle: "Start with a specific profile", target: nil, action: nil)
    let startProfile = NSPopUpButton()
    let helpMessage = NSButton(checkboxWithTitle: "Show the F1 help message at startup", target: nil, action: nil)
    let chooseProfilesFolder = NSButton(title: "Choose profiles folder…", target: nil, action: nil)
    let defaultProfilesFolder = NSButton(title: "Use the default profiles folder", target: nil, action: nil)
    let profilesFolderStatus = NSTextField(wrappingLabelWithString: "")
    let clearServers = NSButton(title: "Clear remembered servers list…", target: nil, action: nil)
    let clearApplications = NSButton(title: "Clear remembered applications list…", target: nil, action: nil)
    // Logs.
    let writeLogsNow = NSButton(title: "Write logs now", target: nil, action: nil)
    let openCurrentLog = NSButton(title: "Open current log", target: nil, action: nil)
    let openLogsFolder = NSButton(title: "Open logs folder", target: nil, action: nil)
    let warnLogs = NSButton(checkboxWithTitle: "Warn at startup if the logs folder is larger than", target: nil, action: nil)
    let warnMegabytes = NSPopUpButton()
    let pruneLogs = NSButton(checkboxWithTitle: "Delete logs older than", target: nil, action: nil)
    let pruneDays = NSPopUpButton()
    let deleteAllLogs = NSButton(title: "Delete all logs…", target: nil, action: nil)

    // What only AppDelegate can do.
    var applyTabs: (() -> Void)?
    var applyRememberedPeers: (() -> Void)?
    var profiles: (() -> [(id: UUID, title: String)])?
    var clearRememberedServers: (() -> Void)?
    var clearRememberedApplications: (() -> Void)?
    var note: ((String) -> Void)?
    /// Write logs now, through the session (the five minutes before kept in the readings file).
    var writeLogs: (() -> Void)?
    /// Open the log being written; false when there is none (logging off).
    var openLog: (() -> Bool)?
    var openFolder: (() -> Void)?
    /// What the running log's files start with, so deleting logs never deletes them.
    var liveLogStem: (() -> String?)?
    var announce: ((String) -> Void)?

    private var order: [String] = PreferencesExtras.storedTabOrder()

    // MARK: settings as the app reads them

    static var settings: SettingsStore { AppRuntime.settings }
    static func flag(_ key: String, default value: Bool) -> Bool { settings.object(forKey: key) as? Bool ?? value }

    /// The main window's tabs in the chosen order: any missing are added in their usual place, unknown ones dropped.
    static func storedTabOrder() -> [String] {
        let stored = (settings.object(forKey: tabOrderKey) as? [String] ?? []).filter(defaultTabOrder.contains)
        var result = [String]()
        for tab in stored where !result.contains(tab) { result.append(tab) }
        for tab in defaultTabOrder where !result.contains(tab) { result.append(tab) }
        return result
    }

    /// The colour theme, now (Windows applies it at the next launch; the Mac can at once).
    static func applyTheme() {
        switch settings.string(forKey: themeKey) {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// The main window where it was when it last closed, when that is remembered and the place is still on a screen.
    static func restoreWindowFrame(_ window: NSWindow) {
        guard flag(rememberWindowKey, default: false), let text = settings.string(forKey: windowFrameKey) else { return }
        let frame = NSRectFromString(text)
        guard frame.width >= 200, frame.height >= 150,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return }
        window.setFrame(frame, display: false)
    }

    static func saveWindowFrame(_ window: NSWindow) {
        guard flag(rememberWindowKey, default: false) else { return }
        settings.set(NSStringFromRect(window.frame), forKey: windowFrameKey)
    }

    /// The profile to start with, when one is chosen and still exists.
    static func startProfileID() -> UUID? {
        guard flag(startProfileKey + "Enabled", default: false) else { return nil }
        return settings.string(forKey: startProfileKey).flatMap(UUID.init(uuidString:))
    }

    // MARK: building

    func addControls(to stack: NSStackView) {
        func heading(_ text: String) {
            let label = NSTextField(labelWithString: text)
            label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
            stack.addArrangedSubview(label)
        }
        func row(_ views: [NSView]) {
            let row = NSStackView(views: views); row.orientation = .horizontal; row.alignment = .centerY
            stack.addArrangedSubview(row)
        }
        let s = Self.settings

        heading("Appearance")
        theme.addItems(withTitles: Self.themes.map(\.1))
        theme.selectItem(at: Self.themes.firstIndex { $0.0 == (s.string(forKey: Self.themeKey) ?? "system") } ?? 0)
        theme.setAccessibilityLabel("Colour theme")
        theme.setAccessibilityHelp("Follow the Mac's light or dark appearance, or always light, or always dark. It changes at once.")
        row([NSTextField(labelWithString: "Colour theme"), theme])

        let column = NSTableColumn(identifier: .init("tab"))
        column.title = "Tab order"
        tabOrderList.addTableColumn(column)
        tabOrderList.headerView = nil
        tabOrderList.dataSource = self
        tabOrderList.delegate = self
        tabOrderList.setAccessibilityLabel("Tab order")
        tabOrderList.setAccessibilityHelp("The main window's tabs, first to last. Choose one and use Move tab up or Move tab down.")
        tabOrderScroll.documentView = tabOrderList
        tabOrderScroll.hasVerticalScroller = true
        tabOrderScroll.borderType = .bezelBorder
        tabOrderScroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
        tabOrderScroll.widthAnchor.constraint(equalToConstant: 260).isActive = true
        stack.addArrangedSubview(NSTextField(labelWithString: "Tab order"))
        stack.addArrangedSubview(tabOrderScroll)
        moveTabUp.setAccessibilityHelp("Move the chosen tab one place earlier in the main window.")
        moveTabDown.setAccessibilityHelp("Move the chosen tab one place later in the main window.")
        row([moveTabUp, moveTabDown])
        tabOrderList.reloadData()
        tabOrderList.selectRowIndexes([0], byExtendingSelection: false)

        showPanEqTab.state = Self.flag(Self.showPanEqTabKey, default: true) ? .on : .off
        showPanEqTab.setAccessibilityHelp("On by default. Off hides the Pan / EQ tab; each profile's volume, pan and EQ still apply.")
        showRememberedPeers.state = Self.flag(Self.showRememberedPeersKey, default: true) ? .on : .off
        showRememberedPeers.setAccessibilityHelp("On by default. Off hides the remembered peers list and its buttons on the Connectivity tab.")
        rememberWindow.state = Self.flag(Self.rememberWindowKey, default: false) ? .on : .off
        rememberWindow.setAccessibilityHelp("Off by default. On, the main window opens as big as, and where, it was when it last closed.")
        for view in [showPanEqTab, showRememberedPeers, rememberWindow] { stack.addArrangedSubview(view) }

        heading("Startup")
        startMinimised.state = Self.flag(Self.startMinimisedKey, default: false) ? .on : .off
        startMinimised.setAccessibilityHelp("Off by default. On, RemSound opens with its window hidden; the menu bar item shows it.")
        startWithProfile.state = Self.flag(Self.startProfileKey + "Enabled", default: false) ? .on : .off
        startWithProfile.setAccessibilityHelp("Off by default, when RemSound opens the profile you used last. On, it opens the profile chosen below.")
        startProfile.setAccessibilityLabel("Profile to start with")
        startProfile.setAccessibilityHelp("The profile RemSound opens with while Start with a specific profile is on.")
        refreshStartProfiles()
        helpMessage.state = Self.flag(Self.helpMessageKey, default: true) ? .on : .off
        helpMessage.setAccessibilityHelp("On by default. When RemSound opens, it says that F1 gives help on the control you're on and Shift-F1 opens the manual.")
        stack.addArrangedSubview(startMinimised)
        stack.addArrangedSubview(startWithProfile)
        row([NSTextField(labelWithString: "Profile to start with"), startProfile])
        stack.addArrangedSubview(helpMessage)

        heading("Profiles and lists")
        chooseProfilesFolder.setAccessibilityHelp("Keep profiles in another folder, such as one shared through Dropbox. It takes effect the next time RemSound opens.")
        defaultProfilesFolder.setAccessibilityHelp("Go back to the usual profiles folder. It takes effect the next time RemSound opens.")
        profilesFolderStatus.setAccessibilityLabel("Profiles folder")
        refreshProfilesFolder()
        row([chooseProfilesFolder, defaultProfilesFolder])
        stack.addArrangedSubview(profilesFolderStatus)
        clearServers.setAccessibilityHelp("Forget every server in the Server window's remembered list, after asking.")
        clearApplications.setAccessibilityHelp("Forget every application RemSound has remembered for sending system audio, after asking.")
        row([clearServers, clearApplications])

        heading("Logs")
        writeLogsNow.setAccessibilityHelp("Write a mark into the log now, and keep every second of the five minutes before it in the readings file, so the moment can be found when the log is read.")
        openCurrentLog.setAccessibilityHelp("Open the log RemSound is writing now. Logging must be on.")
        openLogsFolder.setAccessibilityHelp("Open the folder the logs and their readings files are in, in the Finder.")
        warnLogs.state = s.bool(forKey: LogFolderCare.warnKey) ? .on : .off
        warnLogs.setAccessibilityHelp("Off by default. On, RemSound warns when it opens if the logs folder has grown past the size chosen.")
        warnMegabytes.addItems(withTitles: LogFolderCare.warnChoices.map { "\($0) megabytes" })
        let warnAt = s.object(forKey: LogFolderCare.warnMegabytesKey) as? Int ?? LogFolderCare.defaultWarnMegabytes
        warnMegabytes.selectItem(at: LogFolderCare.warnChoices.firstIndex(of: warnAt) ?? 1)
        warnMegabytes.setAccessibilityLabel("Logs folder size to warn at")
        pruneLogs.state = s.bool(forKey: LogFolderCare.pruneKey) ? .on : .off
        pruneLogs.setAccessibilityHelp("Off by default. On, RemSound deletes logs older than the days chosen when it opens. Logs in use are kept.")
        pruneDays.addItems(withTitles: LogFolderCare.pruneDayRange.map { "\($0) day\($0 == 1 ? "" : "s") old" })
        let days = s.object(forKey: LogFolderCare.pruneDaysKey) as? Int ?? LogFolderCare.defaultPruneDays
        pruneDays.selectItem(at: max(0, days - 1))
        pruneDays.setAccessibilityLabel("Delete logs older than")
        deleteAllLogs.setAccessibilityHelp("Delete every log except those RemSound is writing now, after asking. This cannot be undone.")
        row([writeLogsNow, openCurrentLog, openLogsFolder])
        row([warnLogs, warnMegabytes])
        row([pruneLogs, pruneDays])
        stack.addArrangedSubview(deleteAllLogs)

        for control in [theme, startProfile, warnMegabytes, pruneDays] as [NSControl] {
            control.target = self; control.action = #selector(changed(_:))
        }
        for button in [showPanEqTab, showRememberedPeers, rememberWindow, startMinimised, startWithProfile, helpMessage,
                       warnLogs, pruneLogs] {
            button.target = self; button.action = #selector(changed(_:)); button.setAccessibilityLabel(button.title)
        }
        moveTabUp.target = self; moveTabUp.action = #selector(moveTab(_:))
        moveTabDown.target = self; moveTabDown.action = #selector(moveTab(_:))
        chooseProfilesFolder.target = self; chooseProfilesFolder.action = #selector(chooseFolder)
        defaultProfilesFolder.target = self; defaultProfilesFolder.action = #selector(useDefaultFolder)
        clearServers.target = self; clearServers.action = #selector(clearServersPressed)
        clearApplications.target = self; clearApplications.action = #selector(clearApplicationsPressed)
        writeLogsNow.target = self; writeLogsNow.action = #selector(writeLogsNowPressed)
        openCurrentLog.target = self; openCurrentLog.action = #selector(openCurrentLogPressed)
        openLogsFolder.target = self; openLogsFolder.action = #selector(openLogsFolderPressed)
        deleteAllLogs.target = self; deleteAllLogs.action = #selector(deleteAllLogsPressed)
        refreshDependents()

        let help: [(NSView, String)] = [
            (theme, "theme"), (tabOrderList, "taborder"), (moveTabUp, "taborder"), (moveTabDown, "taborder"),
            (showPanEqTab, "showpaneqtab"), (showRememberedPeers, "showrememberedpeers"), (rememberWindow, "rememberwindow"),
            (startMinimised, "startminimised"), (startWithProfile, "startwithprofile"), (startProfile, "startwithprofile"),
            (helpMessage, "helpmessage"), (chooseProfilesFolder, "profilesfolder"), (defaultProfilesFolder, "profilesfolder"),
            (profilesFolderStatus, "profilesfolder"), (clearServers, "clearservers"), (clearApplications, "clearapplications"),
            (writeLogsNow, "writelogsnow"), (openCurrentLog, "opencurrentlog"), (openLogsFolder, "openlogsfolder"),
            (warnLogs, "warnlogs"), (warnMegabytes, "warnlogs"), (pruneLogs, "prunelogs"),
            (pruneDays, "prunelogs"), (deleteAllLogs, "deletealllogs"),
        ]
        for (view, key) in help { view.identifier = NSUserInterfaceItemIdentifier("help-dialog-preferences-" + key) }
    }

    /// In the order the General tab reads them.
    var controlOrder: [NSView] {
        [theme, tabOrderList, moveTabUp, moveTabDown, showPanEqTab, showRememberedPeers, rememberWindow,
         startMinimised, startWithProfile, startProfile, helpMessage, chooseProfilesFolder, defaultProfilesFolder,
         profilesFolderStatus, clearServers, clearApplications, writeLogsNow, openCurrentLog, openLogsFolder, warnLogs, warnMegabytes, pruneLogs, pruneDays,
         deleteAllLogs]
    }

    func refreshStartProfiles() {
        let list = profiles?() ?? []
        startProfile.removeAllItems()
        for profile in list {
            startProfile.addItem(withTitle: profile.title)
            startProfile.lastItem?.representedObject = profile.id.uuidString
        }
        let chosen = Self.settings.string(forKey: Self.startProfileKey)
        if let index = list.firstIndex(where: { $0.id.uuidString == chosen }) { startProfile.selectItem(at: index) }
        refreshDependents()
    }

    private func refreshProfilesFolder() {
        let chosen = Self.settings.string(forKey: RuntimeConfiguration.chosenProfilesDirectoryKey)
        let now = AppRuntime.configuration.profilesDirectory.path
        profilesFolderStatus.stringValue = chosen.map { $0 == now ? "Profiles folder: \($0)" : "Profiles folder from the next start: \($0)" }
            ?? "Profiles folder: \(now)"
        defaultProfilesFolder.isEnabled = chosen != nil
    }

    private func refreshDependents() {
        startProfile.isEnabled = startWithProfile.state == .on && startProfile.numberOfItems > 0
        warnMegabytes.isEnabled = warnLogs.state == .on
        pruneDays.isEnabled = pruneLogs.state == .on
    }

    // MARK: actions

    @objc private func changed(_ sender: NSControl) {
        let s = Self.settings
        switch sender {
        case theme:
            s.set(Self.themes[max(0, theme.indexOfSelectedItem)].0, forKey: Self.themeKey)
            Self.applyTheme()
        case showPanEqTab:
            s.set(showPanEqTab.state == .on, forKey: Self.showPanEqTabKey)
            applyTabs?()
        case showRememberedPeers:
            s.set(showRememberedPeers.state == .on, forKey: Self.showRememberedPeersKey)
            applyRememberedPeers?()
        case rememberWindow: s.set(rememberWindow.state == .on, forKey: Self.rememberWindowKey)
        case startMinimised: s.set(startMinimised.state == .on, forKey: Self.startMinimisedKey)
        case startWithProfile: s.set(startWithProfile.state == .on, forKey: Self.startProfileKey + "Enabled")
        case startProfile:
            if let id = startProfile.selectedItem?.representedObject as? String { s.set(id, forKey: Self.startProfileKey) }
        case helpMessage: s.set(helpMessage.state == .on, forKey: Self.helpMessageKey)
        case warnLogs: s.set(warnLogs.state == .on, forKey: LogFolderCare.warnKey)
        case warnMegabytes: s.set(LogFolderCare.warnChoices[max(0, warnMegabytes.indexOfSelectedItem)], forKey: LogFolderCare.warnMegabytesKey)
        case pruneLogs: s.set(pruneLogs.state == .on, forKey: LogFolderCare.pruneKey)
        case pruneDays: s.set(max(0, pruneDays.indexOfSelectedItem) + 1, forKey: LogFolderCare.pruneDaysKey)
        default: break
        }
        if sender === startWithProfile, startWithProfile.state == .on,
           let id = startProfile.selectedItem?.representedObject as? String { s.set(id, forKey: Self.startProfileKey) }
        refreshDependents()
    }

    @objc private func moveTab(_ sender: NSButton) {
        let row = tabOrderList.selectedRow
        let target = sender === moveTabUp ? row - 1 : row + 1
        guard order.indices.contains(row), order.indices.contains(target) else {
            NSSound.beep()
            return
        }
        order.swapAt(row, target)
        Self.settings.set(order, forKey: Self.tabOrderKey)
        tabOrderList.reloadData()
        tabOrderList.selectRowIndexes([target], byExtendingSelection: false)
        applyTabs?()
        announce?("\(order[target]), \(target + 1) of \(order.count).")
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose the folder for RemSound's profiles. It takes effect the next time RemSound opens."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Self.settings.set(url.path, forKey: RuntimeConfiguration.chosenProfilesDirectoryKey)
        refreshProfilesFolder()
        announce?("Profiles folder chosen. It takes effect the next time RemSound opens.")
    }

    @objc private func useDefaultFolder() {
        Self.settings.removeObject(forKey: RuntimeConfiguration.chosenProfilesDirectoryKey)
        refreshProfilesFolder()
        announce?("The default profiles folder is used from the next start.")
    }

    private func confirm(_ question: String, _ detail: String, _ action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = detail
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func clearServersPressed() {
        guard confirm("Clear the remembered servers list?", "Every remembered server is forgotten. This cannot be undone.", "Clear") else { return }
        clearRememberedServers?()
        announce?("Remembered servers list cleared.")
    }

    @objc private func clearApplicationsPressed() {
        guard confirm("Clear the remembered applications list?", "Every remembered application is forgotten. This cannot be undone.", "Clear") else { return }
        clearRememberedApplications?()
        announce?("Remembered applications list cleared.")
    }

    @objc private func writeLogsNowPressed() {
        if let writeLogs { writeLogs() } else { note?("user requested write logs now") }
        announce?("Logs written.")
    }

    @objc private func openCurrentLogPressed() {
        if openLog?() != true { announce?("No log is being written. Turn on logging first.") }
    }

    @objc private func openLogsFolderPressed() { openFolder?() }

    @objc private func deleteAllLogsPressed() {
        guard confirm("Delete all logs?", "This permanently deletes every log file in the logs folder except the ones RemSound is writing now. This cannot be undone.", "Delete") else { return }
        let live = liveLogStem?()
        let deleted = Self.deleteLogs { LogFolderCare.all($0, now: Date(), sparing: live) }
        note?("logs: deleted all (\(deleted) file\(deleted == 1 ? "" : "s"))")
        announce?("\(deleted) log file\(deleted == 1 ? "" : "s") deleted.")
    }

    // MARK: the logs folder at start

    static func logFiles() -> [LogFolderCare.File] {
        let folder = AppRuntime.configuration.logsDirectory
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return .init(name: url.lastPathComponent, modified: values.contentModificationDate ?? Date(),
                         bytes: Int64(values.fileSize ?? 0))
        }
    }

    /// Deletes what `choose` picks from the logs folder; returns how many went.
    @discardableResult
    static func deleteLogs(_ choose: ([LogFolderCare.File]) -> [LogFolderCare.File]) -> Int {
        let folder = AppRuntime.configuration.logsDirectory
        var deleted = 0
        for file in choose(logFiles()) where (try? FileManager.default.removeItem(at: folder.appendingPathComponent(file.name))) != nil {
            deleted += 1
        }
        return deleted
    }

    /// When RemSound opens: old logs deleted, then the size warning, as chosen.
    static func logCareAtStart(note: (String) -> Void) -> String? {
        let s = settings
        if s.bool(forKey: LogFolderCare.pruneKey) {
            let days = s.object(forKey: LogFolderCare.pruneDaysKey) as? Int ?? LogFolderCare.defaultPruneDays
            let deleted = deleteLogs { LogFolderCare.older($0, thanDays: days, now: Date()) }
            if deleted > 0 { note("logs: deleted \(deleted) older than \(days) days") }
        }
        guard s.bool(forKey: LogFolderCare.warnKey) else { return nil }
        let megabytes = s.object(forKey: LogFolderCare.warnMegabytesKey) as? Int ?? LogFolderCare.defaultWarnMegabytes
        return LogFolderCare.warning(logFiles(), megabytes: megabytes)
    }

    // MARK: the tab order list

    func numberOfRows(in tableView: NSTableView) -> Int { order.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: order[row])
        label.setAccessibilityLabel(order[row])
        return label
    }
}
