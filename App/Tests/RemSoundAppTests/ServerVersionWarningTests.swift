import AppKit
import XCTest
import RemSoundJam
@testable import RemSoundApp

@MainActor
final class ServerVersionWarningTests: XCTestCase {
    private let exact = "Warning: you are connecting to a RemSound server that is out of date. Please contact the server administrator to request an update to the latest version for features and security enhancements."
    private func fixture(current: @escaping () -> Bool = { true }, browser: @escaping (URL) -> Bool = { _ in true }, answer: @escaping (Bool) -> Void) -> ServerVersionWarningWindow {
        _ = NSApplication.shared
        let w = ServerVersionWarningWindow(server: "isolated.example", latestReleased: "server-v2.18", isCurrent: current, browser: browser, answer: answer)
        addTeardownBlock { w.retire() }; XCTAssertFalse(w.window?.isVisible ?? true); return w
    }
    private func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }
    func testExactWarningNativeNamesDefaultAndFocusedMessage() throws {
        let w = fixture(answer: { _ in })
        XCTAssertEqual(ServerVersionWarningWindow.warningText, exact); XCTAssertEqual(w.message.stringValue, exact)
        XCTAssertEqual(w.message.accessibilityLabel(), "Server version warning")
        XCTAssertEqual(w.message.accessibilityValue() as? String, exact)
        XCTAssertTrue(w.message.acceptsFirstResponder); XCTAssertFalse(w.message.isEditable)
        XCTAssertEqual(w.connect.title, "Connect anyway"); XCTAssertEqual(w.cancel.title, "Cancel")
        XCTAssertEqual(w.cancel.keyEquivalent, "\r"); XCTAssertEqual(w.connect.keyEquivalent, "")
        XCTAssertTrue(try XCTUnwrap(w.window).initialFirstResponder === w.message)
        XCTAssertFalse(w.window?.isVisible ?? true)
    }
    func testReturnKeypadEscapeAllCancelEvenWhenConnectFocused() throws {
        for code: UInt16 in [36, 76, 53] {
            var results: [Bool] = []; let w = fixture(answer: { results.append($0) })
            let panel = try XCTUnwrap(w.window); XCTAssertTrue(panel.makeFirstResponder(w.connect))
            panel.sendEvent(key(code)); XCTAssertEqual(results, [false]); w.cancel.performClick(nil); XCTAssertEqual(results, [false])
        }
    }
    func testExplicitConnectClickAnswersOnceAndRetiresWindow() {
        var results: [Bool] = []; let w = fixture(answer: { results.append($0) })
        w.connect.performClick(nil); w.cancel.performClick(nil); w.retire()
        XCTAssertEqual(results, [true]); XCTAssertFalse(w.window?.isVisible ?? true)
    }
    func testVisitOpensOnlyValidatedReleaseAndKeepsQuestionOpen() {
        var visited: [URL] = [], results: [Bool] = []
        let w = fixture(browser: { visited.append($0); return true }, answer: { results.append($0) })
        w.visit.performClick(nil)
        XCTAssertEqual(visited.map(\.absoluteString), ["https://github.com/Ednunp/RemSound/releases/tag/server-v2.18"])
        XCTAssertTrue(results.isEmpty); w.connect.performClick(nil); XCTAssertEqual(results, [true])
    }
    func testFailedVisitKeepsDecisionAndFocusAvailable() throws {
        var results: [Bool] = []; let w = fixture(browser: { _ in false }, answer: { results.append($0) })
        let panel = try XCTUnwrap(w.window); XCTAssertTrue(panel.makeFirstResponder(w.visit)); w.visit.performClick(nil)
        XCTAssertFalse(w.status.stringValue.isEmpty); XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(panel.firstResponder === w.visit); w.cancel.performClick(nil); XCTAssertEqual(results, [false])
    }
    func testRetirementAndStaleActionNeverAnswerOrBrowse() {
        var current = true, visited = 0, results: [Bool] = []
        let w = fixture(current: { current }, browser: { _ in visited += 1; return true }, answer: { results.append($0) })
        current = false; w.visit.performClick(nil); w.connect.performClick(nil); w.cancel.performClick(nil); w.retire()
        XCTAssertEqual(visited, 0); XCTAssertTrue(results.isEmpty)
    }
    func testCloseCancelsAndNativeTabBothDirectionsReachActionsAndText() throws {
        var results: [Bool] = []; let w = fixture(answer: { results.append($0) }), panel = try XCTUnwrap(w.window)
        panel.contentView?.layoutSubtreeIfNeeded()
        let controls: [NSView] = [w.message, w.connect, w.visit, w.cancel]
        for backwards in [false, true] {
            XCTAssertTrue(panel.makeFirstResponder(w.message))
            for step in 1...controls.count {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: backwards ? .shift : [], timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
                panel.sendEvent(event)
                let expected = controls[(backwards ? controls.count - step : step) % controls.count]
                XCTAssertTrue(expected === panel.firstResponder || ((expected as? NSTextField)?.currentEditor() != nil
                    && (expected as? NSTextField)?.currentEditor() === panel.firstResponder))
            }
        }
        panel.performClose(nil); XCTAssertEqual(results, [false])
    }
    func testVisitRecoveryMovesFocusOffHiddenResultAndGeometryFits() throws {
        var succeeds = false
        let w = fixture(browser: { _ in succeeds }, answer: { _ in }), panel = try XCTUnwrap(w.window)
        w.visit.performClick(nil); XCTAssertTrue(panel.makeFirstResponder(w.status))
        succeeds = true; w.visit.performClick(nil)
        XCTAssertTrue(w.status.isHidden); XCTAssertTrue(panel.firstResponder === w.visit)
        panel.contentView?.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(panel.contentView)
        let frames = [w.message, w.connect, w.visit, w.cancel].map { $0.convert($0.bounds, to: content) }
        for frame in frames {
            XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThan(frame.height, 0)
            XCTAssertTrue(content.bounds.insetBy(dx: -1, dy: -1).contains(frame))
        }
        for pair in [(1, 2), (2, 3)] { XCTAssertFalse(frames[pair.0].intersects(frames[pair.1])) }
    }

}
