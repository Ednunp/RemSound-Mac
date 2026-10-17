import AppKit
import Carbon
import RemSoundRuntime
import XCTest
@testable import RemSoundApp

@MainActor
final class SliderResetTests: XCTestCase {
    private final class Action: NSObject {
        var values: [Double] = []
        var accepted = 0
        var afterChange: ((NSSlider) -> Void)?
        @objc func changed(_ sender: NSSlider) {
            values.append(sender.doubleValue)
            afterChange?(sender)
        }
        @objc func accept(_ sender: Any?) { accepted += 1 }
    }

    private func returnEvent(_ window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: UInt16(kVK_Return)))
    }

    private func event(_ code: Int, modifiers: NSEvent.ModifierFlags = [], characters: String = "\r") throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)))
    }

    private func fixture(_ slider: ResettableSlider) -> (KeyboardWindow, Action) {
        _ = NSApplication.shared
        let window = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        slider.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
        let action = Action()
        slider.target = action
        slider.action = #selector(Action.changed(_:))
        window.contentView?.addSubview(slider)
        XCTAssertTrue(window.makeFirstResponder(slider))
        XCTAssertFalse(window.isVisible)
        return (window, action)
    }

    func testReturnOnFocusedVolumeResetsAndCallsItsNormalAction() throws {
        _ = NSApplication.shared
        let window = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let slider = ResettableSlider.volume()
        slider.doubleValue = 37
        slider.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
        let action = Action()
        slider.target = action
        slider.action = #selector(Action.changed(_:))
        window.contentView?.addSubview(slider)
        XCTAssertTrue(window.makeFirstResponder(slider))
        XCTAssertFalse(window.isVisible, "A component test must not show a user window")
        XCTAssertTrue(window.performKeyEquivalent(with: try returnEvent(window)), "Focused slider owns Return")
        XCTAssertEqual(slider.doubleValue, 100)
        XCTAssertEqual(action.values, [100], "Reset must use the existing action and persistence path")
    }

    func testKeypadEnterResetsVolumeCentrePanAndFlatEQThroughTheirActions() throws {
        for (slider, changed, expected) in [(ResettableSlider.volume(), 23.0, 100.0),
            (.pan(), -71.0, 0.0), (.equalizerBand(), 73.0, 50.0)] {
            let (window, action) = fixture(slider)
            slider.doubleValue = changed
            XCTAssertTrue(window.performKeyEquivalent(with: try event(kVK_ANSI_KeypadEnter, modifiers: .numericPad, characters: "\u{3}")))
            XCTAssertEqual(slider.doubleValue, expected)
            XCTAssertEqual(action.values, [expected])
            XCTAssertTrue(window.firstResponder === slider)
            let native = NSSlider(value: expected, minValue: slider.minValue, maxValue: slider.maxValue,
                target: nil, action: nil)
            native.frame = slider.frame
            window.contentView?.addSubview(native)
            XCTAssertEqual(slider.accessibilityRole(), native.accessibilityRole())
            XCTAssertEqual(slider.cell?.accessibilityRole(), native.cell?.accessibilityRole())
            XCTAssertEqual(slider.cell?.accessibilityRole(), .slider)
        }
    }

    func testFocusedResetPrecedesDefaultButtonButReturnElsewhereStillAccepts() throws {
        let slider = ResettableSlider.volume()
        let (window, action) = fixture(slider)
        let button = NSButton(title: "OK", target: action, action: #selector(Action.accept(_:)))
        button.frame = NSRect(x: 210, y: 60, width: 60, height: 24)
        button.keyEquivalent = "\r"
        button.keyEquivalentModifierMask = []
        window.contentView?.addSubview(button)
        window.defaultButtonCell = button.cell as? NSButtonCell
        slider.doubleValue = 23
        XCTAssertTrue(window.performKeyEquivalent(with: try returnEvent(window)))
        XCTAssertEqual(slider.doubleValue, 100)
        XCTAssertEqual(action.accepted, 0)
        XCTAssertTrue(window.makeFirstResponder(button))
        XCTAssertTrue(window.performKeyEquivalent(with: try returnEvent(window)))
        XCTAssertEqual(action.accepted, 1)
        XCTAssertEqual(action.values, [100])
    }

    func testWindowSendEventAndDirectKeyDownUseTheSameReset() throws {
        let slider = ResettableSlider.volume()
        let (window, action) = fixture(slider)
        slider.doubleValue = 23
        window.sendEvent(try returnEvent(window))
        XCTAssertEqual(action.values, [100])
        slider.doubleValue = 37
        slider.keyDown(with: try event(kVK_ANSI_KeypadEnter, characters: "\u{3}"))
        XCTAssertEqual(action.values, [100, 100])
    }

    func testAlreadyDefaultConsumesReturnWithoutDuplicateActionOrAnnouncement() throws {
        let slider = ResettableSlider.volume()
        let (window, action) = fixture(slider)
        var notifications = 0
        var logged = 0
        slider.logReset = { _, _ in logged += 1 }
        slider.notifyResetValue = { _ in notifications += 1 }
        XCTAssertTrue(window.performKeyEquivalent(with: try returnEvent(window)))
        window.sendEvent(try returnEvent(window))
        XCTAssertTrue(action.values.isEmpty)
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(logged, 0)
    }

    func testShortcutsAndOtherKeysNeverReset() throws {
        let slider = ResettableSlider.volume()
        let (_, action) = fixture(slider)
        slider.doubleValue = 23
        let shortcuts: [NSEvent.ModifierFlags] = [.command, .option, .control, .shift, [.control, .option]]
        for modifiers in shortcuts {
            XCTAssertFalse(slider.resetIfRequested(by: try event(kVK_Return, modifiers: modifiers)))
        }
        for code in [kVK_LeftArrow, kVK_RightArrow, kVK_Tab, kVK_Escape, kVK_ANSI_A] {
            XCTAssertFalse(slider.resetIfRequested(by: try event(code)))
        }
        XCTAssertTrue(action.values.isEmpty)
        XCTAssertEqual(slider.doubleValue, 23)
    }

    func testDisabledHiddenAndUnconfiguredControlsNeverReset() throws {
        let slider = ResettableSlider.volume()
        let (_, action) = fixture(slider)
        slider.doubleValue = 23
        slider.isEnabled = false
        XCTAssertFalse(slider.resetIfRequested(by: try event(kVK_Return)))
        slider.isEnabled = true
        slider.superview?.isHidden = true
        XCTAssertFalse(slider.resetIfRequested(by: try event(kVK_Return)))
        slider.superview?.isHidden = false
        slider.resetValue = nil
        XCTAssertFalse(slider.resetIfRequested(by: try event(kVK_Return)))
        slider.resetValue = .nan
        XCTAssertFalse(slider.resetIfRequested(by: try event(kVK_Return)))
        XCTAssertTrue(action.values.isEmpty)
        XCTAssertEqual(slider.doubleValue, 23)
    }

    func testResetClampsToCurrentRangeAndAnnouncesAfterOwnerUpdatesName() throws {
        let slider = ResettableSlider.volume()
        let (_, action) = fixture(slider)
        slider.doubleValue = 23
        slider.maxValue = 80
        var announced: [String] = []
        action.afterChange = { $0.setAccessibilityLabel("Volume \($0.integerValue) percent") }
        slider.notifyResetValue = { announced.append($0.accessibilityLabel() ?? "") }
        XCTAssertTrue(slider.resetIfRequested(by: try event(kVK_Return)))
        XCTAssertEqual(action.values, [80])
        XCTAssertEqual(announced, ["Volume 80 percent"])
        slider.resetValue = -5
        XCTAssertTrue(slider.resetIfRequested(by: try event(kVK_Return)))
        XCTAssertEqual(action.values, [80, 0])
        XCTAssertEqual(announced, ["Volume 80 percent", "Volume 0 percent"])
    }

    func testUnfocusedSliderCannotStealReturnFromAnotherControl() throws {
        let slider = ResettableSlider.volume()
        let (window, action) = fixture(slider)
        let other = NSTextField(string: "")
        window.contentView?.addSubview(other)
        XCTAssertTrue(window.makeFirstResponder(other))
        slider.doubleValue = 23
        XCTAssertFalse(slider.performKeyEquivalent(with: try returnEvent(window)))
        XCTAssertEqual(slider.doubleValue, 23)
        XCTAssertTrue(action.values.isEmpty)
    }

    func testNativeArrowDispatchMatchesFocusedAppKitControl() throws {
        let slider = ResettableSlider.volume()
        let (window, _) = fixture(slider)
        let native = NSSlider(value: 23, minValue: slider.minValue, maxValue: slider.maxValue,
            target: nil, action: nil)
        native.frame = slider.frame
        window.contentView?.addSubview(native)
        let arrow = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{f703}",
            charactersIgnoringModifiers: "\u{f703}", isARepeat: false, keyCode: UInt16(kVK_RightArrow)))
        XCTAssertTrue(window.makeFirstResponder(native))
        native.keyDown(with: arrow)
        slider.doubleValue = 23
        XCTAssertTrue(window.makeFirstResponder(slider))
        slider.keyDown(with: arrow)
        XCTAssertEqual(slider.doubleValue, native.doubleValue)
        guard native.doubleValue > 23 else {
            throw XCTSkip("AppKit does not dispatch arrow increments in this unordered window; visible keyboard acceptance remains unverified")
        }
        XCTAssertGreaterThan(slider.doubleValue, 23)
    }

    func testVoiceOverIncrementMatchesNativeControl() throws {
        let slider = ResettableSlider.volume()
        let (_, action) = fixture(slider)
        slider.doubleValue = 23
        let afterArrow = slider.doubleValue
        let native = NSSlider(value: afterArrow, minValue: slider.minValue, maxValue: slider.maxValue,
            target: nil, action: nil)
        native.frame = slider.frame
        slider.superview?.addSubview(native)
        let nativeResult = native.accessibilityPerformIncrement()
        let result = slider.accessibilityPerformIncrement()
        XCTAssertEqual(result, nativeResult)
        XCTAssertEqual(slider.doubleValue, native.doubleValue)
        XCTAssertGreaterThan(slider.doubleValue, afterArrow)
        XCTAssertFalse(action.values.isEmpty)
    }

    func testNormalActionPersistsResetValueInDisposableSettings() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("slider-persistence-\(UUID())")
        let options = try LaunchOptions.parse(["--config-dir", root.path, "--silent"])
        let configuration = try RuntimeConfiguration(options: options)
        let slider = ResettableSlider.volume()
        let (window, action) = fixture(slider)
        action.afterChange = { configuration.settings.set($0.integerValue, forKey: "volume") }
        slider.doubleValue = 23
        XCTAssertTrue(window.performKeyEquivalent(with: try returnEvent(window)))
        let reopened = try RuntimeConfiguration(options: options)
        XCTAssertEqual(reopened.settings.integer(forKey: "volume"), 100)
        XCTAssertEqual(action.values, [100])
    }

    func testActionLoggingAndAccessibleValueNotificationHaveCompletedState() throws {
        let slider = ResettableSlider.volume()
        let (window, action) = fixture(slider)
        slider.doubleValue = 23
        var order: [String] = []
        action.afterChange = { sender in
            XCTAssertEqual(sender.doubleValue, 100)
            order.append("action")
        }
        slider.logReset = { previous, value in
            XCTAssertEqual(previous, 23)
            XCTAssertEqual(value, 100)
            order.append("log")
        }
        slider.notifyResetValue = { sender in
            XCTAssertEqual(sender.cell?.accessibilityRole(), .slider)
            XCTAssertEqual((sender.cell?.accessibilityValue() as? NSNumber)?.doubleValue, 100)
            order.append("accessible value")
        }
        XCTAssertTrue(window.performKeyEquivalent(with: try returnEvent(window)))
        XCTAssertEqual(order, ["action", "log", "accessible value"])
    }
}
