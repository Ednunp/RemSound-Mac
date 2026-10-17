import AppKit
import RemSoundRuntime
import XCTest
@testable import RemSoundApp

final class CuePreferencesPaneTests: XCTestCase {
    private final class Player: CueSoundPlayer {
        var isPlaying = false
        func play() -> Bool { isPlaying = true; return true }
        func stop() { isPlaying = false }
    }
    private func fixture(_ flags: [String] = []) throws -> (CueSounds, () -> [String]) {
        guard let base = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"],
            (base as NSString).isAbsolutePath else {
            throw XCTSkip("Cue list tests require a disposable REMSOUND_TEST_ROOT")
        }
        let root = URL(fileURLWithPath: base).appendingPathComponent("cue-lists-\(UUID())")
        let options = try LaunchOptions.parse(flags + ["--config-dir", root.path],
            environment: ["REMSOUND_ALLOW_VISIBLE_UI_TESTS": "1"])
        let configuration = try RuntimeConfiguration(options: options)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let sounds = root.appendingPathComponent("sounds")
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: false)
        for name in Set(CueEvent.allCases.map { $0.filenameBase + ".wav" }) {
            try Data().write(to: sounds.appendingPathComponent(name))
        }
        var played: [String] = []
        let cues = CueSounds(configuration: configuration, directory: sounds,
            enqueue: { $0() }, makePlayer: { played.append($0.lastPathComponent); return Player() })
        return (cues, { played })
    }

    func testInitialListsScopeNamesActionsAndKeyboardOrderWithoutPlaying() throws {
        let (cues, played) = try fixture()
        let pane = CuePreferencesPane(cues: cues)
        XCTAssertNil(pane.view.window, "The component test must not open a live GUI")
        XCTAssertEqual(pane.selectedEvent, .save)
        XCTAssertEqual(pane.globalList.selectedRow, 0)
        XCTAssertEqual(pane.profileList.selectedRow, -1)
        XCTAssertEqual(pane.globalList.numberOfRows, 6)
        XCTAssertEqual(pane.profileList.numberOfRows, 20)
        for (list, events) in [(pane.globalList, CueEvent.globalEvents), (pane.profileList, CueEvent.profileEvents)] {
            for (row, event) in events.enumerated() {
                XCTAssertEqual(pane.tableView(list, viewFor: nil, row: row)?.accessibilityLabel(), event.title)
            }
        }
        XCTAssertEqual(pane.tabOrder.map(ObjectIdentifier.init),
            [pane.mute, pane.globalList, pane.profileList, pane.choice, pane.play, pane.browse, pane.keyboardClicks].map(ObjectIdentifier.init))
        for control in pane.tabOrder {
            XCTAssertFalse(control.accessibilityLabel()?.isEmpty ?? true)
            XCTAssertFalse(control.accessibilityHelp()?.isEmpty ?? true)
        }
        let columns = try XCTUnwrap(pane.view.arrangedSubviews[1] as? NSStackView)
        XCTAssertEqual(columns.orientation, .horizontal)
        XCTAssertTrue(pane.globalList.isDescendant(of: columns.arrangedSubviews[0]))
        XCTAssertTrue(pane.profileList.isDescendant(of: columns.arrangedSubviews[1]))
        XCTAssertTrue(pane.view.arrangedSubviews[0] === pane.mute)
        XCTAssertEqual(pane.choice.item(at: 0)?.title, "\(CueEvent.save.title), (none)")
        XCTAssertTrue(pane.scope.stringValue.contains("every profile"))
        XCTAssertTrue(played().isEmpty)
    }

    func testNativeSelectionPreviewsLastSelectedListEvenWhenAutomaticCuesMuted() throws {
        let (cues, played) = try fixture()
        let pane = CuePreferencesPane(cues: cues)
        cues.setMuteAllCues(true)
        for event in [CueEvent.connect, .helpOpen, .disconnect, .profileSwitch, .pushToTalkOn, .pushToTalkOff] {
            let list = event.isProfileSetting ? pane.profileList : pane.globalList
            let events = event.isProfileSetting ? CueEvent.profileEvents : CueEvent.globalEvents
            list.selectRowIndexes(IndexSet(integer: try XCTUnwrap(events.firstIndex(of: event))), byExtendingSelection: false)
            XCTAssertEqual(pane.selectedEvent, event)
            XCTAssertEqual(pane.choice.accessibilityLabel(), "Choose sound for \(event.title)")
            XCTAssertEqual(pane.play.accessibilityLabel(), "Play \(event.title) sound")
            XCTAssertEqual(pane.browse.accessibilityLabel(), "Browse for \(event.title) sound")
            XCTAssertEqual(played().last, event.filenameBase + ".wav")
        }
        XCTAssertEqual(played().count, 6)
        cues.preferences.setEnabled(false, for: .recordStart)
        pane.profileList.selectRowIndexes(IndexSet(integer: try XCTUnwrap(CueEvent.profileEvents.firstIndex(of: .recordStart))), byExtendingSelection: false)
        XCTAssertEqual(pane.selectedEvent, .recordStart)
        XCTAssertEqual(played().count, 6, "An Off event remains silent when arrowed")
        XCTAssertFalse(pane.play.isEnabled)
        XCTAssertEqual(pane.choice.selectedItem?.representedObject as? String, "Off")
    }

    func testRefreshKeepsSelectionAndCustomOffChoiceAcrossProfileChanges() throws {
        let (cues, _) = try fixture()
        let pane = CuePreferencesPane(cues: cues)
        cues.preferences.chooseCustomFile("/private/disposable.wav", for: .connect)
        cues.preferences.setEnabled(false, for: .connect)
        pane.select(.connect, preview: false)
        let expectedRow = try XCTUnwrap(CueEvent.profileEvents.firstIndex(of: .connect))
        XCTAssertEqual(pane.profileList.selectedRow, expectedRow)
        let globalRow = pane.globalList.selectedRow
        let profileRow = pane.profileList.selectedRow
        for _ in 0..<5 { pane.refresh() }
        XCTAssertEqual(pane.globalList.selectedRow, globalRow)
        XCTAssertEqual(pane.profileList.selectedRow, profileRow)
        XCTAssertEqual(pane.profileList.selectedRow, expectedRow)
        XCTAssertEqual(pane.selectedEvent, .connect)
        XCTAssertEqual(pane.choice.selectedItem?.representedObject as? String, "Off")
        XCTAssertEqual(pane.choice.itemArray.filter { $0.representedObject as? String == "Custom" }.count, 1)
        XCTAssertTrue(pane.choice.accessibilityHelp()?.contains("current profile") == true)
        cues.preferences.setEnabled(false, for: .save)
        pane.customFiles.removeAll()
        cues.preferences.loadProfile([:])
        pane.refresh()
        XCTAssertEqual(pane.profileList.selectedRow, profileRow)
        XCTAssertTrue(pane.customFiles.isEmpty)
        XCTAssertFalse(cues.preferences.configuration(for: .save).enabled, "A profile change must preserve global choices")
        XCTAssertTrue(pane.play.isEnabled)
        pane.select(.save, preview: false)
        XCTAssertFalse(pane.play.isEnabled)
        XCTAssertTrue(pane.scope.stringValue.contains("every profile"))
    }

    func testSilentSelectionNeverConstructsAudioPlayers() throws {
        let (cues, played) = try fixture(["--silent"])
        let pane = CuePreferencesPane(cues: cues)
        for event in CueEvent.allCases { pane.select(event, preview: true) }
        XCTAssertTrue(played().isEmpty)
        XCTAssertNil(pane.view.window)
    }

    func testTypingActionNotifiesPlaybackAfterChoiceChangesWithoutRefreshSideEffects() throws {
        let (cues, played) = try fixture()
        let pane = CuePreferencesPane(cues: cues)
        var observed: [Bool] = []
        pane.onKeyboardClicksChanged = { observed.append(cues.preferences.keyboardClicksEnabled) }
        pane.keyboardClicks.performClick(nil); pane.keyboardClicks.performClick(nil)
        for _ in 0..<20 { pane.refresh() }
        XCTAssertEqual(observed, [false, true])
        XCTAssertTrue(played().isEmpty)
    }

    func testTypingCheckboxIsLastNamedControlAndAppliesProfileChoiceImmediately() throws {
        let (cues, played) = try fixture()
        let pane = CuePreferencesPane(cues: cues)
        XCTAssertTrue(pane.tabOrder.last === pane.keyboardClicks)
        XCTAssertTrue(pane.view.arrangedSubviews.last === pane.keyboardClicks)
        XCTAssertEqual(pane.keyboardClicks.accessibilityLabel(),
            "Play keyboard clicks when typing into any edit field, for this profile")
        XCTAssertTrue(pane.keyboardClicks.accessibilityHelp()?.contains("Save Profile") == true)
        XCTAssertTrue(pane.keyboardClicks.accessibilityHelp()?.contains("audio cues off") == true)
        XCTAssertEqual(pane.keyboardClicks.state, .on)
        let before = cues.preferences.profileConfigurations
        pane.keyboardClicks.performClick(nil)
        XCTAssertFalse(cues.preferences.keyboardClicksEnabled)
        XCTAssertEqual(cues.preferences.profileConfigurations, before)
        cues.setMuteAllCues(true)
        pane.keyboardClicks.performClick(nil)
        XCTAssertTrue(cues.preferences.keyboardClicksEnabled)
        XCTAssertFalse(cues.preferences.automaticKeyboardClicksEnabled)
        pane.refresh()
        XCTAssertEqual(pane.keyboardClicks.state, .on, "Muting must preserve the profile choice")
        cues.preferences.loadProfile([:], keyboardClicks: false)
        pane.refresh()
        XCTAssertEqual(pane.keyboardClicks.state, .off)
        XCTAssertTrue(played().isEmpty, "Changing typing settings must not preview or open audio")
        XCTAssertNil(pane.view.window)
    }
}
