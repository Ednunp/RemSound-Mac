import AppKit
import XCTest
import RemSoundCore
import RemSoundJam
@testable import RemSoundApp

/// Windows' Keyboard shortcuts on the Mac: every one kept under its own name, the held ones repeating, and the metronome's
/// five listed in its settings window in Windows' order.
@MainActor
final class GlobalHotkeyListTests: XCTestCase {
    func testEveryShortcutHasItsOwnSettingAndTheVolumeAndTempoKeysRepeat() {
        let keys = GlobalHotkeyAction.allCases.map(\.settingKey)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(GlobalHotkeyAction.allCases.count, 23)
        for action in [GlobalHotkeyAction.localVolumeUp, .localVolumeDown, .metronomeTempoUp, .metronomeTempoDown,
                       .metronomeVolumeUp, .metronomeVolumeDown] {
            XCTAssertTrue(action.repeatsWhileHeld, action.settingKey)
        }
        for action in [GlobalHotkeyAction.toggleRecording, .speakStatus, .metronomeStartStop, .hearMyself, .muteReceived] {
            XCTAssertFalse(action.repeatsWhileHeld, action.settingKey)
        }
        XCTAssertLessThan(GlobalHotkeyAction.allCases.map(\.rawValue).max()!, 100, "alias ids are the action's plus 100")
    }

    func testTheMetronomeWindowListsItsFiveKeysAndOKReturnsThem() {
        XCTAssertEqual(GlobalHotkeyAction.metronomeKeys,
                       [.metronomeStartStop, .metronomeTempoUp, .metronomeTempoDown, .metronomeVolumeUp, .metronomeVolumeDown])
        let start = HotkeyDescriptor(keyCode: 46, modifiers: [.command, .option])
        var returned: [HotkeyDescriptor?]?
        var accepted: Bool?
        let window = MetronomeSettingsWindow(choices: MetronomeChoices(), volume: 70, sounds: ["Click"], master: nil,
            keys: [start, nil, nil, nil, nil],
            state: { .init(playing: false, following: false, muted: false) }, startStop: {},
            heardLive: { _, _ in }, loadSound: { _ in nil }, preview: { _, _, _ in },
            finishWith: { ok, _, _, _, keys in accepted = ok; returned = keys })
        XCTAssertEqual(window.keyFields.map(\.descriptor), [start, nil, nil, nil, nil])
        window.keyFields[1].descriptor = HotkeyDescriptor(keyCode: 126, modifiers: [.command, .option])
        window.acceptPressed()
        XCTAssertEqual(accepted, true)
        XCTAssertEqual(returned?[0], start)
        XCTAssertEqual(returned?[1], HotkeyDescriptor(keyCode: 126, modifiers: [.command, .option]))
    }

    func testCancelPutsTheProfilesSettingsAndKeysBack() {
        var kept: MetronomeChoices?
        var keptKeys: [HotkeyDescriptor?]?
        var changed = MetronomeChoices()
        changed.bpm = 90
        let window = MetronomeSettingsWindow(choices: MetronomeChoices(), volume: 70, sounds: ["Click"], master: nil,
            keys: [nil, nil, nil, nil, nil],
            state: { .init(playing: false, following: false, muted: false) }, startStop: {},
            heardLive: { _, _ in }, loadSound: { _ in nil }, preview: { _, _, _ in },
            finishWith: { _, choices, _, _, keys in kept = choices; keptKeys = keys })
        window.tempo.integerValue = 90
        window.keyFields[0].descriptor = HotkeyDescriptor(keyCode: 46, modifiers: [.command, .option])
        window.cancelPressed()
        XCTAssertEqual(kept, MetronomeChoices())
        XCTAssertEqual(keptKeys?.compactMap { $0 }.count, 0)
        XCTAssertNotEqual(kept, changed)
    }
}
