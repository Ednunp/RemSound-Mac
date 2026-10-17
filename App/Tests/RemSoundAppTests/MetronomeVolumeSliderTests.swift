import AppKit
import Carbon
import XCTest
@testable import RemSoundApp

@MainActor
final class MetronomeVolumeSliderTests: XCTestCase {
    private final class Action: NSObject {
        var values = [Int]()
        @objc func changed(_ sender: NSSlider) { values.append(sender.integerValue) }
    }
    func testBothEnterKeysResetSeventyThroughNormalActionAndPreserveNativeFocus() throws {
        _ = NSApplication.shared
        for code in [kVK_Return, kVK_ANSI_KeypadEnter] {
            let window = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let slider = ResettableSlider.metronomeVolume(), action = Action()
            slider.target = action; slider.action = #selector(Action.changed(_:)); slider.doubleValue = 37
            slider.frame = NSRect(x: 10, y: 10, width: 200, height: 24); window.contentView?.addSubview(slider)
            XCTAssertTrue(window.makeFirstResponder(slider)); XCTAssertFalse(window.isVisible)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: code == kVK_Return ? [] : .numericPad,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: UInt16(code)))
            XCTAssertTrue(window.performKeyEquivalent(with: event)); XCTAssertEqual(action.values, [70])
            XCTAssertEqual(slider.integerValue, 70); XCTAssertTrue(window.firstResponder === slider)
            XCTAssertEqual(slider.cell?.accessibilityRole(), .slider)
            XCTAssertTrue(window.performKeyEquivalent(with: event)); XCTAssertEqual(action.values, [70])
        }
    }
}
