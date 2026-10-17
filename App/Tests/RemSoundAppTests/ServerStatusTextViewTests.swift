import AppKit
import XCTest
@testable import RemSoundApp

@MainActor
final class ServerStatusTextViewTests: XCTestCase {
    private func fixture() -> (NSWindow, ServerStatusTextView, NSButton) {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let text = ServerStatusTextView(frame: NSRect(x: 10, y: 40, width: 420, height: 180))
        let button = NSButton(title: "Close", target: nil, action: nil); button.frame = NSRect(x: 10, y: 10, width: 80, height: 24)
        w.contentView?.addSubview(text); w.contentView?.addSubview(button)
        addTeardownBlock { w.close() }; XCTAssertFalse(w.isVisible)
        return (w, text, button)
    }
    func testFocusedFiguresStayStillButMeasuringAndGroupChangesUpdate() {
        let (w, text, _) = fixture(); var notices = 0
        text.notifyValue = { _ in notices += 1 }
        text.update("Your round trip to the server: measuring.")
        XCTAssertTrue(w.makeFirstResponder(text))
        text.update("Your round trip to the server: 21 ms.")
        XCTAssertEqual(text.string, "Your round trip to the server: 21 ms.")
        text.setSelectedRange(NSRange(location: 5, length: 4))
        text.update("Your round trip to the server: 23 ms.")
        XCTAssertEqual(text.string, "Your round trip to the server: 21 ms.")
        XCTAssertEqual(text.selectedRange(), NSRange(location: 5, length: 4))
        XCTAssertEqual(notices, 2)
        text.update("Your round trip to the server: 23 ms.\nA has ticked you.")
        XCTAssertTrue(text.string.contains("A has ticked you."))
        XCTAssertTrue(w.firstResponder === text); XCTAssertEqual(notices, 3)
    }
    func testLeavingFocusAppliesOnlyTheLatestDeferredSnapshot() {
        let (w, text, button) = fixture()
        text.update("Round trip: 21 ms."); XCTAssertTrue(w.makeFirstResponder(text))
        text.update("Round trip: 23 ms."); text.update("Round trip: 31 ms.")
        let refreshed = expectation(description: "latest snapshot after native focus leaves")
        text.notifyValue = { _ in refreshed.fulfill() }
        XCTAssertTrue(w.makeFirstResponder(button)); wait(for: [refreshed], timeout: 3)
        XCTAssertEqual(text.string, "Round trip: 31 ms.")
        XCTAssertTrue(w.firstResponder === button)
    }
    func testNativeReadOnlySelectableMultilineRoleNamesAndValue() {
        let (_, text, _) = fixture()
        text.update("On server.\nYour round trip: measuring.")
        XCTAssertFalse(text.isEditable); XCTAssertTrue(text.isSelectable); XCTAssertFalse(text.isRichText)
        XCTAssertEqual(text.accessibilityRole(), .textArea)
        XCTAssertEqual(text.accessibilityLabel(), "Server status")
        XCTAssertTrue(text.accessibilityHelp()?.contains("figures") == true)
        XCTAssertEqual(text.accessibilityValue() as? String, text.string)
        XCTAssertTrue(text.textContainer?.widthTracksTextView == true)
    }
}
