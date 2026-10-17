import AppKit
import Carbon
import RemSoundCore
import RemSoundJam
import XCTest
@testable import RemSoundApp

@MainActor
final class PushToTalkSettingsWindowTests: XCTestCase {
    func testF1AndShiftF1UseTheirWindowWithoutCapturingOrApplyingTheShortcut() {
        _ = NSApplication.shared
        var requests = [Bool](), applications = 0
        weak var requestedWindow: NSWindow?
        let c = PushToTalkSettingsWindow(settings: .init(), binding: nil, contextHelp: { manual, window in
            requests.append(manual); requestedWindow = window
        }, accept: { _ in applications += 1; return nil })
        defer { c.window?.close() }
        XCTAssertTrue(c.window!.makeFirstResponder(c.key))
        let before = c.choice
        for flags: NSEvent.ModifierFlags in [.function, [.shift, .function]] {
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: c.window!.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: UInt16(kVK_F1))!
            c.window!.sendEvent(key)
        }
        XCTAssertEqual(requests, [false, true]); XCTAssertTrue(requestedWindow === c.window)
        XCTAssertEqual(c.choice, before); XCTAssertNil(c.key.descriptor); XCTAssertEqual(applications, 0)
        XCTAssertTrue(c.window!.firstResponder === c.key); XCTAssertFalse(c.window!.isVisible)
    }
    private final class Events { var attempts: [PushToTalkWindowChoice] = []; var closes = 0; var announcements: [String] = []; var error: String? }
    private func fixture(_ settings: PushToTalkSettings = .init(), binding: HotkeyDescriptor? = nil) -> (PushToTalkSettingsWindow, Events) {
        _ = NSApplication.shared
        let events = Events()
        let c = PushToTalkSettingsWindow(settings: settings, binding: binding, accept: { events.attempts.append($0); return events.error },
            didClose: { events.closes += 1 }, announce: { _, message in events.announcements.append(message) })
        c.key.onInvalidKey = {}; addTeardownBlock { c.window?.close() }
        XCTAssertFalse(c.window?.isVisible == true)
        return (c, events)
    }
    private func event(_ code: Int, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1, windowNumber: 0,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: UInt16(code))!
    }
    private func change(_ c: PushToTalkSettingsWindow, _ control: NSControl) { c.controlsChanged(control) }
    func testOpeningCopiesDefaultsWithoutCommittingOrChoosingAKey() {
        let (c, e) = fixture(); XCTAssertEqual(c.choice.settings, .init()); XCTAssertNil(c.choice.binding); XCTAssertFalse(c.choice.keyWasEdited)
        XCTAssertTrue(e.attempts.isEmpty); XCTAssertEqual(e.closes, 0); XCTAssertEqual(c.key.captureMode, .pushToTalk)
        XCTAssertEqual(c.level.integerValue, -40); XCTAssertTrue(c.hold.isEnabled); XCTAssertTrue(c.doubleTap.isEnabled); XCTAssertFalse(c.level.isEnabled)
    }
    func testOKCollectsEveryWorkingChoiceOnlyOnAccept() {
        let (c, e) = fixture(); c.enable.state = .on; c.path.selectItem(at: 1); c.trigger.selectItem(at: 1)
        c.hold.state = .off; c.doubleTap.state = .off; c.speed.selectItem(at: 2); c.level.integerValue = -30
        c.bypassRecording.state = .on; c.bypassPlugin.state = .on; change(c, c.enable)
        c.key.descriptor = .init(keyCode: UInt32(kVK_ANSI_A), modifiers: []); c.hotkeyCaptureFieldDidChange(c.key)
        XCTAssertTrue(e.attempts.isEmpty); c.acceptPressed(); XCTAssertEqual(e.attempts.count, 1)
        guard let choice = e.attempts.first else { return }
        XCTAssertTrue(choice.settings.enabled); XCTAssertEqual(choice.settings.capturePath, .systemAudio); XCTAssertEqual(choice.settings.trigger, .level)
        XCTAssertFalse(choice.settings.holdToSpeak); XCTAssertFalse(choice.settings.doubleTapToHold); XCTAssertEqual(choice.settings.doubleTapSpeed, .fast)
        XCTAssertEqual(choice.settings.levelDb, -30); XCTAssertTrue(choice.settings.bypassForRecording); XCTAssertTrue(choice.settings.bypassForPlugin)
        XCTAssertEqual(choice.binding, c.key.descriptor); XCTAssertTrue(choice.keyWasEdited); XCTAssertEqual(e.closes, 1)
    }
    func testCancelDiscardsWorkingSettingsAndExplicitKeyChanges() {
        let (c, e) = fixture(); c.enable.state = .on; change(c, c.enable)
        c.key.descriptor = .init(keyCode: UInt32(kVK_F9), modifiers: []); c.hotkeyCaptureFieldDidChange(c.key); c.cancelPressed()
        XCTAssertTrue(e.attempts.isEmpty); XCTAssertEqual(e.closes, 1)
        c.acceptPressed(); c.cancelPressed(); XCTAssertTrue(e.attempts.isEmpty); XCTAssertEqual(e.closes, 1)
    }
    func testEscapeAndCommandWCloseWithoutAccepting() {
        for (code, flags) in [(kVK_Escape, NSEvent.ModifierFlags()), (kVK_ANSI_W, NSEvent.ModifierFlags.command)] {
            let (c, e) = fixture(); c.enable.state = .on; change(c, c.enable); c.window?.makeFirstResponder(c.key)
            XCTAssertTrue(c.window?.performKeyEquivalent(with: event(code, flags: flags)) == true)
            XCTAssertTrue(e.attempts.isEmpty); XCTAssertEqual(e.closes, 1)
        }
    }
    func testWindowCloseCallbackHappensOnceWithoutCommitting() {
        let (c, e) = fixture(); c.window?.close(); c.window?.close(); c.cancelPressed()
        XCTAssertTrue(e.attempts.isEmpty); XCTAssertEqual(e.closes, 1)
    }
    func testCommitFailureKeepsChoicesAndFocusesReadableResultForRetry() {
        let (c, e) = fixture(); e.error = "Could not save these choices."; c.enable.state = .on; change(c, c.enable)
        c.acceptPressed(); XCTAssertEqual(e.closes, 0); XCTAssertEqual(c.status.stringValue, e.error); XCTAssertFalse(c.status.isHidden)
        XCTAssertTrue(c.window?.firstResponder === c.status || c.status.currentEditor() === c.window?.firstResponder)
        XCTAssertEqual(e.announcements, [e.error!]); XCTAssertTrue(c.choice.settings.enabled)
        e.error = nil; c.acceptPressed(); XCTAssertEqual(e.attempts.count, 2); XCTAssertEqual(e.closes, 1)
    }
    func testExplicitUnsetKeyIsDifferentFromAnUneditedUnsetBook() {
        let (c, _) = fixture(); XCTAssertFalse(c.choice.keyWasEdited)
        c.key.keyDown(with: event(kVK_Delete)); XCTAssertTrue(c.choice.keyWasEdited); XCTAssertNil(c.choice.binding)
    }
    func testCaptureFieldPassesReturnAndKeypadEnterToItsDialog() {
        for code in [kVK_Return, kVK_ANSI_KeypadEnter] {
            let (c, e) = fixture(); c.window?.makeFirstResponder(c.key)
            XCTAssertFalse(c.key.performKeyEquivalent(with: event(code)))
            XCTAssertTrue(c.window?.performKeyEquivalent(with: event(code)) == true)
            XCTAssertEqual(e.attempts.count, 1); XCTAssertEqual(e.closes, 1); XCTAssertEqual(e.attempts.first?.keyWasEdited, false)
        }
    }
    func testLevelReturnResetsThroughNormalActionWithoutAccepting() {
        var settings = PushToTalkSettings(); settings.trigger = .level; settings.levelDb = -32
        let (c, e) = fixture(settings); c.window?.makeFirstResponder(c.level); var resetValues: [Int] = []
        c.level.notifyResetValue = { resetValues.append($0.integerValue) }
        XCTAssertTrue(c.window?.performKeyEquivalent(with: event(kVK_Return)) == true)
        XCTAssertEqual(c.choice.settings.levelDb, -40); XCTAssertEqual(resetValues, [-40]); XCTAssertTrue(e.attempts.isEmpty)
        XCTAssertTrue(c.window?.firstResponder === c.level); XCTAssertTrue(e.announcements.contains(where: { $0.contains("minus 40") }))
        XCTAssertTrue(c.window?.performKeyEquivalent(with: event(kVK_ANSI_KeypadEnter)) == true); XCTAssertEqual(resetValues, [-40])
    }
    func testTriggerDependenciesRetainChoicesAndMoveFocusBeforeDisabling() {
        let (c, _) = fixture(); c.window?.makeFirstResponder(c.hold)
        c.trigger.selectItem(at: 1); change(c, c.trigger)
        XCTAssertTrue(c.window?.firstResponder === c.trigger); XCTAssertFalse(c.hold.isEnabled); XCTAssertFalse(c.doubleTap.isEnabled)
        XCTAssertFalse(c.speed.isEnabled); XCTAssertTrue(c.level.isEnabled); XCTAssertTrue(c.choice.settings.holdToSpeak)
        c.trigger.selectItem(at: 0); change(c, c.trigger); c.doubleTap.state = .off; change(c, c.doubleTap)
        XCTAssertFalse(c.speed.isEnabled); XCTAssertFalse(c.level.isEnabled); XCTAssertTrue(c.key.isEnabled)
    }
    func testBothTabDirectionsReachExactlyTheEnabledNativeControls() {
        for byLevel in [false, true] {
            var settings = PushToTalkSettings(); settings.trigger = byLevel ? .level : .key
            let (c, _) = fixture(settings); let original = c.controlOrder
            for backwards in [false, true] {
                let order = backwards ? Array(original.reversed()) : original
                c.window?.makeFirstResponder(order[0])
                for expected in Array(order.dropFirst()) + [order[0]] {
                    c.window?.sendEvent(event(kVK_Tab, flags: backwards ? .shift : []))
                    XCTAssertTrue(c.window?.firstResponder === expected, "Expected \(expected.accessibilityLabel() ?? "control")")
                }
            }
            XCTAssertFalse(c.window?.isVisible == true)
        }
    }
    func testSpeedPreviewOccursOnlyOnAnActualSpeedAction() {
        let (c, _) = fixture(); var previews: [PushToTalkDoubleTapSpeed] = []; c.previewDoubleTap = { previews.append($0) }
        c.window?.makeFirstResponder(c.speed); XCTAssertTrue(previews.isEmpty)
        c.speed.selectItem(at: 0); change(c, c.speed); XCTAssertEqual(previews, [.slow])
        change(c, c.enable); XCTAssertEqual(previews, [.slow])
    }
    func testControlsExposeNativeRolesNamesHelpAndNegativeLevelWords() {
        let (c, _) = fixture()
        for view in c.controlOrder { XCTAssertFalse((view.accessibilityLabel() ?? "").isEmpty); XCTAssertFalse((view.accessibilityHelp() ?? "").isEmpty) }
        XCTAssertEqual(c.enable.cell?.accessibilityRole(), .checkBox); XCTAssertEqual(c.path.cell?.accessibilityRole(), .popUpButton)
        XCTAssertEqual(c.key.accessibilityRole(), .textField); XCTAssertEqual(c.level.cell?.accessibilityRole(), .slider)
        XCTAssertTrue(c.level.accessibilityLabel()?.contains("minus 40 decibels") == true)
        XCTAssertTrue(c.ok.keyEquivalentModifierMask.isEmpty); XCTAssertTrue(c.cancel.keyEquivalentModifierMask.isEmpty)
    }
    func testNativeSliderFactoriesExposeDistinctPTTAndMetronomeDefaults() {
        let ptt = ResettableSlider.pushToTalkThreshold(), metronome = ResettableSlider.metronomeVolume()
        XCTAssertEqual(ptt.minValue, -70); XCTAssertEqual(ptt.maxValue, -10); XCTAssertEqual(ptt.doubleValue, -40); XCTAssertEqual(ptt.resetValue, -40)
        XCTAssertEqual(metronome.minValue, 0); XCTAssertEqual(metronome.maxValue, 100); XCTAssertEqual(metronome.doubleValue, 70); XCTAssertEqual(metronome.resetValue, 70)
        XCTAssertEqual(ResettableSlider.volume().resetValue, 100)
    }
    func testEveryPathTriggerAndSpeedRoundTripsWithoutACommit() {
        for (i, path) in [PushToTalkCapturePath.input, .systemAudio, .both].enumerated() {
            let (c, e) = fixture(); c.path.selectItem(at: i); change(c, c.path); XCTAssertEqual(c.choice.settings.capturePath, path)
            for (j, speed) in [PushToTalkDoubleTapSpeed.slow, .medium, .fast].enumerated() {
                c.speed.selectItem(at: j); change(c, c.speed); XCTAssertEqual(c.choice.settings.doubleTapSpeed, speed)
            }
            c.trigger.selectItem(at: 1); change(c, c.trigger); XCTAssertEqual(c.choice.settings.trigger, .level); XCTAssertTrue(e.attempts.isEmpty)
        }
    }
    func testFinishedWindowIgnoresQueuedControlAndKeyChanges() {
        let (c, e) = fixture(); c.cancelPressed(); let previous = c.choice
        c.enable.state = .on; change(c, c.enable); c.key.descriptor = .init(keyCode: UInt32(kVK_ANSI_A), modifiers: [])
        c.hotkeyCaptureFieldDidChange(c.key); XCTAssertEqual(c.choice, previous); XCTAssertTrue(e.attempts.isEmpty)
    }
    func testModifiedReturnDoesNotCommitOrResetTheLevel() {
        var settings = PushToTalkSettings(); settings.trigger = .level; settings.levelDb = -32
        let (c, e) = fixture(settings); c.window?.makeFirstResponder(c.level)
        for flags: NSEvent.ModifierFlags in [.control, .option, .command, .shift] {
            _ = c.window?.performKeyEquivalent(with: event(kVK_Return, flags: flags))
        }
        XCTAssertTrue(e.attempts.isEmpty); XCTAssertEqual(c.choice.settings.levelDb, -32)
    }
    func testHiddenGeometryContainsAllControlsIncludingACommitError() {
        let (c, e) = fixture(); e.error = "These choices could not be saved. The previous profile and machine key are retained."
        c.acceptPressed(); guard let content = c.window?.contentView else { return XCTFail("Missing content") }
        content.layoutSubtreeIfNeeded()
        for view in c.controlOrder {
            let frame = content.convert(view.bounds, from: view)
            XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThan(frame.height, 0)
            XCTAssertTrue(content.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Outside content: \(view.accessibilityLabel() ?? "control")")
        }
        XCTAssertFalse(c.window?.isVisible == true)
    }
    func testErrorFieldEditorShiftTabReachesCancelAndHasReadableGeometry() {
        let (c, e) = fixture(); e.error = "Could not save."; c.acceptPressed()
        c.window?.sendEvent(event(kVK_Tab, flags: .shift)); XCTAssertTrue(c.window?.firstResponder === c.cancel)
        c.window?.makeFirstResponder(c.status)
        if let editor = c.status.currentEditor() { XCTAssertGreaterThan(editor.frame.width, 100) }
    }
    func testDisabledSpeedCannotRequestPreviewAndClosingRetiresItsActions() {
        let (c, _) = fixture(); var previews: [PushToTalkDoubleTapSpeed] = []
        c.previewDoubleTap = { previews.append($0) }
        c.trigger.selectItem(at: 1); change(c, c.trigger); change(c, c.speed)
        XCTAssertTrue(previews.isEmpty)
        c.trigger.selectItem(at: 0); change(c, c.trigger); c.doubleTap.state = .off; change(c, c.doubleTap); change(c, c.speed)
        XCTAssertTrue(previews.isEmpty)
        c.doubleTap.state = .on; change(c, c.doubleTap); c.speed.selectItem(at: 2); change(c, c.speed)
        XCTAssertEqual(previews, [.fast]); c.cancelPressed(); change(c, c.speed); XCTAssertEqual(previews, [.fast])
    }

    func testPreviewFailureKeepsSpeedFocusAndClearsWithoutDiscardingCommitError() {
        let (c, e) = fixture(); c.window?.makeFirstResponder(c.speed)
        c.reportPreviewFailure("Preview unavailable."); XCTAssertTrue(c.window?.firstResponder === c.speed)
        XCTAssertFalse(c.status.isHidden); c.clearPreviewFailure(); XCTAssertTrue(c.status.isHidden)
        c.reportPreviewFailure("Preview unavailable."); c.window?.makeFirstResponder(c.status); c.clearPreviewFailure()
        XCTAssertFalse(c.status.isHidden); XCTAssertTrue(c.status.stringValue.contains("started"))
        XCTAssertTrue(c.window?.firstResponder === c.status || c.status.currentEditor() === c.window?.firstResponder)
        e.error = "Save failed."; c.acceptPressed(); c.clearPreviewFailure()
        XCTAssertFalse(c.status.isHidden); XCTAssertEqual(c.status.stringValue, "Save failed.")
    }

}
