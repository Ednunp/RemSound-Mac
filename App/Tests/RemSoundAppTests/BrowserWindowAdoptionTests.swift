import AppKit
import Carbon
import Foundation
import RemSoundCore
import XCTest
@testable import RemSoundApp

@MainActor final class BrowserWindowAdoptionTests: XCTestCase {
    @MainActor private final class Fixture {
        var current = true, writes = [(Bool)->Void](), attempts = [(BrowserListenerChoice,(Bool)->Void)]()
        var ownerEnds = [BrowserListenerEdit.End](), windowEnds = [BrowserListenerEdit.End](), changes = 0
        var edit: BrowserListenerEdit!, window: BrowserListenerWindow?, clearedBeforeOwner = false
        var ownerEndHook: (() -> Void)?
        init(visit: BrowserListenerWindow.Visit = .unconfirmed, persistence: BrowserListenerWindow.Persistence = .profile, commit: Bool = false) {
            _ = NSApplication.shared
            edit = BrowserListenerEdit(opened: .empty, isCurrent: { [weak self] in self?.current == true }, apply: { [weak self] choice,reply in self?.attempts.append((choice,reply)); return true }, commit: commit ? { [weak self] _,reply in self?.writes.append(reply); return true } : nil)
            edit.changed = { [weak self] in self?.changes += 1 }
            edit.ended = { [weak self] result,_ in
                guard let self else { return }; self.clearedBeforeOwner = self.window?.password.stringValue.isEmpty ?? true; self.ownerEnds.append(result); self.ownerEndHook?()
            }
            window = BrowserListenerWindow(edit: edit, visit: visit, persistence: persistence, didEnd: { [weak self] result,_ in self?.windowEnds.append(result) }, announce: { _,_ in })
        }
    }
    private let choice = BrowserListenerChoice(options: .init(enabled: true), password: "synthetic")
    private func pump(_ done: ()->Bool) { let end = Date().addingTimeInterval(2); while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) } }
    private func ready(_ f: Fixture) -> BrowserListenerWindow? { XCTAssertNotNil(f.window); return f.window }
    func testAdoptsExactExistingModelWithoutSendingOrLosingOwnerCallbacks() {
        let f = Fixture(); guard let c = ready(f) else { return }
        XCTAssertTrue(c.edit === f.edit); XCTAssertTrue(f.attempts.isEmpty); XCTAssertFalse(c.window?.isVisible == true)
        c.password.stringValue = "synthetic"; c.enable.state = .on; c.acceptPressed(); XCTAssertGreaterThan(f.changes, 0)
        f.attempts.first?.1(true); pump { !f.ownerEnds.isEmpty }
        XCTAssertEqual(f.ownerEnds, [.accepted]); XCTAssertEqual(f.windowEnds, [.accepted]); XCTAssertTrue(f.clearedBeforeOwner); XCTAssertEqual(c.password.stringValue, "")
    }
    func testOneExistingModelCannotBePresentedByTwoWindows() {
        let f = Fixture(); guard ready(f) != nil else { return }
        XCTAssertNil(BrowserListenerWindow(edit: f.edit, didEnd: { _,_ in XCTFail("Foreign window") }))
        f.window?.cancelPressed(); XCTAssertEqual(f.ownerEnds, [.cancelled])
    }
    func testFinishedOrInvalidatedModelCannotAcquireWindow() {
        let f = Fixture(); guard ready(f) != nil else { return }; f.edit.invalidate()
        XCTAssertNil(BrowserListenerWindow(edit: f.edit, didEnd: { _,_ in XCTFail("Finished model") }))
        XCTAssertEqual(f.ownerEnds, [.invalidated])
    }
    func testOwnerChangedNotificationIsPreservedThroughPreviewFailure() {
        let f = Fixture(); guard let c = ready(f) else { return }; c.edit.update(choice)
        XCTAssertGreaterThan(f.changes, 0); f.attempts.first?.1(false); pump { !c.edit.busy }
        XCTAssertFalse(c.status.stringValue.isEmpty); XCTAssertTrue(f.ownerEnds.isEmpty); XCTAssertGreaterThan(f.changes, 1)
        f.current = false; c.invalidateContext()
    }
    func testWindowReleasePreservesOriginalPendingOwnerAndDoesNotRetainController() {
        var f: Fixture!; weak var old: BrowserListenerWindow?
        autoreleasepool {
            f = Fixture(); guard ready(f) != nil else { return }; f.edit.update(choice)
            old = f.window; f.window = nil
        }
        XCTAssertNil(old); XCTAssertTrue(f.ownerEnds.isEmpty)
        f.attempts.first?.1(true); pump { f.attempts.count == 2 }; f.attempts.last?.1(true); pump { !f.ownerEnds.isEmpty }
        XCTAssertEqual(f.ownerEnds, [.cancelled]); XCTAssertTrue(f.windowEnds.isEmpty)
    }
    func testReleasedIdleWindowCancelsOwnerExactlyOnce() {
        var f: Fixture!; weak var old: BrowserListenerWindow?
        autoreleasepool {
            f = Fixture(); guard ready(f) != nil else { return }; old = f.window; f.window = nil
        }
        XCTAssertNil(old); XCTAssertEqual(f.ownerEnds, [.cancelled]); XCTAssertTrue(f.windowEnds.isEmpty)
        f.edit.cancel(); XCTAssertEqual(f.ownerEnds.count, 1)
    }
    func testContextLossClearsShownPasswordBeforeOwnerCompletion() {
        let f = Fixture(); guard let c = ready(f) else { return }
        c.password.stringValue = "synthetic"; c.enable.state = .on; c.commitPassword(); f.current = false; c.invalidateContext()
        XCTAssertEqual(c.password.stringValue, ""); XCTAssertFalse(c.password.isEnabled); XCTAssertTrue(f.ownerEnds.isEmpty)
        f.attempts.first?.1(true); pump { !f.ownerEnds.isEmpty }; XCTAssertEqual(f.ownerEnds, [.invalidated]); XCTAssertTrue(f.clearedBeforeOwner)
    }
    func testProvidedModelCommitFailureKeepsWindowAndOwnerOpen() {
        let f = Fixture(commit: true); guard let c = ready(f) else { return }; c.acceptPressed()
        XCTAssertEqual(f.writes.count, 1); f.writes.first?(false); pump { c.password.isEnabled }
        XCTAssertTrue(f.ownerEnds.isEmpty); XCTAssertFalse(c.status.stringValue.isEmpty); XCTAssertFalse(c.window?.isVisible == true)
        f.current = false; c.invalidateContext()
    }
    func testStoppedDraftDescriptionDoesNotCallStagingListeningOrSaving() {
        let f = Fixture(visit: .stopped, persistence: .draft); guard let c = ready(f) else { return }
        let texts = c.controlOrder.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
        XCTAssertTrue(texts.contains("stopped")); XCTAssertTrue(texts.contains("unsaved profile")); XCTAssertTrue(texts.contains("not saved")); XCTAssertTrue(f.attempts.isEmpty)
        for view in c.controlOrder { XCTAssertFalse((view.accessibilityLabel() ?? "").isEmpty); XCTAssertFalse((view.accessibilityHelp() ?? "").isEmpty) }
        c.cancelPressed()
    }
    func testReadOnlyAndRunningDescriptionDoesNotPromiseHealthOrPlayback() {
        let f = Fixture(visit: .running, persistence: .readOnly); guard let c = ready(f) else { return }
        let texts = c.controlOrder.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
        XCTAssertTrue(texts.contains("read-only")); XCTAssertTrue(texts.contains("running")); XCTAssertTrue(texts.contains("playback")); c.cancelPressed()
    }
    func testExistingModelStillUsesNativeKeyboardAndPasswordIdentity() throws {
        let f = Fixture(); guard let c = ready(f) else { return }
        XCTAssertEqual(TypingEventMonitor.target(for: c.password, root: nil), .password)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: UInt16(kVK_Escape)))
        XCTAssertTrue(c.window?.performKeyEquivalent(with: key) == true); XCTAssertEqual(f.ownerEnds, [.cancelled]); XCTAssertEqual(f.windowEnds, [.cancelled])
    }
    func testAddedScopeNotesAndControlsFitHiddenNativeLayout() {
        let f = Fixture(visit: .stopped, persistence: .draft); guard let c = ready(f), let content = c.window?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        for view in c.controlOrder { XCTAssertTrue(content.bounds.insetBy(dx: -1, dy: -1).contains(content.convert(view.bounds, from: view))) }
        XCTAssertFalse(c.window?.isVisible == true); c.cancelPressed()
    }
    func testCancelClearsShownValueImmediatelyWhileOriginalOwnerWaitsRestoration() {
        let f = Fixture(); guard let c = ready(f) else { return }
        c.password.stringValue = "synthetic"; c.enable.state = .on; c.commitPassword(); c.cancelPressed()
        XCTAssertEqual(c.password.stringValue, ""); XCTAssertTrue(f.ownerEnds.isEmpty)
        f.attempts.first?.1(true); pump { f.attempts.count == 2 }; f.attempts.last?.1(true); pump { !f.ownerEnds.isEmpty }
        XCTAssertEqual(f.ownerEnds, [.cancelled]); XCTAssertTrue(f.clearedBeforeOwner)
    }
    func testOriginalOwnerMayReleaseWindowReentrantlyWithoutLosingItsReceipt() {
        let f = Fixture(); guard ready(f) != nil else { return }
        f.ownerEndHook = { [weak f] in f?.window = nil }
        f.edit.cancel(); XCTAssertEqual(f.ownerEnds, [.cancelled]); XCTAssertTrue(f.clearedBeforeOwner)
    }
    func testScopeNotesParticipateInBothNativeTabDirections() throws {
        let f = Fixture(visit: .stopped, persistence: .draft); guard let c = ready(f) else { return }
        for backwards in [false,true] {
            let order = backwards ? Array(c.controlOrder.reversed()) : c.controlOrder
            c.window?.makeFirstResponder(order[0])
            for expected in Array(order.dropFirst()) + [order[0]] {
                let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: backwards ? .shift : [], timestamp: 1, windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: UInt16(kVK_Tab)))
                c.window?.sendEvent(key)
                XCTAssertTrue(c.window?.firstResponder === expected || (expected as? NSTextField)?.currentEditor() === c.window?.firstResponder)
            }
        }
        c.cancelPressed()
    }
    func testScopeAndStorageHelpNeverIncludeTheShownPassword() {
        let f = Fixture(visit: .stopped, persistence: .draft); guard let c = ready(f) else { return }
        c.password.stringValue = "synthetic-never-description"
        for view in c.controlOrder { XCTAssertFalse((view.accessibilityHelp() ?? "").contains(c.password.stringValue)) }
        XCTAssertTrue(c.storageNote.stringValue.contains("does not immediately clear")); XCTAssertTrue(c.scopeNote.stringValue.contains("temporary")); c.cancelPressed()
    }

}
