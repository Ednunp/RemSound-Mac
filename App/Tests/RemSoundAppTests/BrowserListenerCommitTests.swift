import AppKit
import Foundation
import RemSoundCore
import XCTest
@testable import RemSoundApp

@MainActor final class BrowserListenerCommitTests: XCTestCase {
    private let enabled = BrowserListenerChoice(options: .init(enabled: true), password: "synthetic")
    private func pump(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    }
    @MainActor private final class Fixture {
        var current = true, admitted = true, inline: Bool?, hook: (() -> Void)?
        var applied = [(BrowserListenerChoice, (Bool) -> Void)](), saved = [(BrowserListenerChoice, (Bool) -> Void)]()
        var ends = [(BrowserListenerEdit.End, BrowserListenerChoice?)](), edit: BrowserListenerEdit!
        init(_ opened: BrowserListenerChoice = .empty, effective: BrowserListenerChoice? = nil) {
            edit = BrowserListenerEdit(opened: opened, effectiveOpened: effective, isCurrent: { [weak self] in self?.current == true }, apply: { [weak self] value, reply in
                self?.applied.append((value, reply)); return true
            }, commit: { [weak self] value, reply in
                guard let self else { return false }; self.saved.append((value, reply)); self.hook?(); if let inline = self.inline { reply(inline) }; return self.admitted
            })
            edit.ended = { [weak self] in self?.ends.append(($0, $1)) }
        }
        func preview(_ choice: BrowserListenerChoice) { edit.update(choice); applied.last?.1(true); drain() }
        func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    func testAcceptWaitsPreviewThenPersistenceReceipt() {
        let f = Fixture(); f.edit.update(enabled); f.edit.accept(); XCTAssertTrue(f.saved.isEmpty)
        f.applied.first?.1(true); f.drain(); XCTAssertEqual(f.saved.count, 1); XCTAssertTrue(f.ends.isEmpty); XCTAssertTrue(f.edit.busy)
        f.saved.first?.1(true); f.drain(); XCTAssertEqual(f.ends.first?.0, .accepted); XCTAssertEqual(f.ends.first?.1, enabled); XCTAssertEqual(f.edit.choice, .empty)
    }
    func testFailedCommitKeepsDraftEditableAndNeedsExplicitRetry() {
        let f = Fixture(); f.preview(enabled); f.edit.accept(); f.saved.first?.1(false); f.drain()
        XCTAssertFalse(f.edit.finished); XCTAssertFalse(f.edit.busy); XCTAssertFalse(f.edit.closingRequested); XCTAssertEqual(f.edit.choice, enabled); XCTAssertFalse(f.edit.message.isEmpty)
        f.drain(); XCTAssertEqual(f.saved.count, 1); f.edit.accept(); XCTAssertEqual(f.saved.count, 2); f.saved.last?.1(true); f.drain(); XCTAssertEqual(f.ends.first?.0, .accepted)
    }
    func testCancelDuringCommitWaitsThenRestoresRuntimeAndPersistedOpenedChoice() {
        let f = Fixture(); f.preview(enabled); f.edit.accept(); f.edit.cancel(); XCTAssertTrue(f.ends.isEmpty); XCTAssertEqual(f.applied.count, 1)
        f.saved.first?.1(true); f.drain(); XCTAssertEqual(f.applied.last?.0, .empty); XCTAssertEqual(f.saved.count, 1)
        f.applied.last?.1(true); f.drain(); XCTAssertEqual(f.saved.last?.0, .empty); XCTAssertTrue(f.ends.isEmpty)
        f.saved.last?.1(true); f.drain(); XCTAssertEqual(f.ends.first?.0, .cancelled); XCTAssertEqual(f.ends.first?.1, .empty)
    }
    func testFailedCommitIsUncertainSoCancelRequiresPersistenceRestore() {
        let f = Fixture(); f.preview(enabled); f.edit.accept(); f.saved.first?.1(false); f.drain(); f.edit.cancel()
        f.applied.last?.1(true); f.drain(); XCTAssertEqual(f.saved.count, 2); XCTAssertEqual(f.saved.last?.0, .empty); XCTAssertTrue(f.ends.isEmpty)
        f.saved.last?.1(true); f.drain(); XCTAssertEqual(f.ends.first?.0, .cancelled)
    }
    func testFailedRestoreStaysOpenWithoutAutomaticRetry() {
        let f = Fixture(); f.preview(enabled); f.edit.accept(); f.edit.cancel(); f.saved.first?.1(true); f.drain(); f.applied.last?.1(true); f.drain()
        f.saved.last?.1(false); f.drain(); XCTAssertEqual(f.saved.count, 2); XCTAssertTrue(f.ends.isEmpty); XCTAssertFalse(f.edit.busy)
        f.edit.cancel(); XCTAssertEqual(f.saved.count, 3); f.saved.last?.1(true); f.drain(); XCTAssertEqual(f.ends.count, 1)
    }
    func testRefusedCommitOwnsNoCallbackAndDoesNotInventSavedResult() {
        let f = Fixture(); f.admitted = false; f.inline = true; f.edit.accept(); f.drain()
        XCTAssertTrue(f.ends.isEmpty); XCTAssertFalse(f.edit.busy); XCTAssertFalse(f.edit.closingRequested); XCTAssertFalse(f.edit.message.isEmpty)
        f.edit.cancel(); XCTAssertEqual(f.ends.first?.0, .cancelled); XCTAssertEqual(f.saved.count, 1)
    }
    func testForeignDuplicatePersistenceReceiptsAreFirstFencedOnMain() {
        let f = Fixture(); f.preview(enabled); let done = expectation(description: "main commit receipt")
        f.edit.ended = { result, _ in XCTAssertTrue(Thread.isMainThread); XCTAssertEqual(result, .accepted); done.fulfill() }
        f.edit.accept(); let reply = f.saved.first?.1; DispatchQueue.global().async { reply?(true); reply?(false) }
        wait(for: [done], timeout: 2); f.drain(); XCTAssertTrue(f.edit.finished); XCTAssertEqual(f.saved.count, 1)
    }
    func testContextLossWaitsCommitWithoutSavingOpenedSecretIntoReplacement() {
        let f = Fixture(); f.preview(enabled); f.edit.accept(); f.current = false; f.edit.invalidate()
        XCTAssertTrue(f.ends.isEmpty); f.saved.first?.1(true); f.drain(); XCTAssertEqual(f.ends.first?.0, .invalidated); XCTAssertNil(f.ends.first?.1); XCTAssertEqual(f.saved.count, 1)
    }
    func testReentrantInvalidationDuringPersistenceWaitsRawReturnReceipt() {
        let f = Fixture(); f.hook = { f.current = false; f.edit.invalidate() }; f.edit.accept()
        XCTAssertEqual(f.saved.count, 1); XCTAssertTrue(f.ends.isEmpty); f.saved.first?.1(false); f.drain(); XCTAssertEqual(f.ends.first?.0, .invalidated)
    }
    func testReentrantCancelBeforePersistenceCallDoesNotBorrowDraft() {
        let f = Fixture(); f.preview(enabled); var once = true
        f.edit.changed = { if once && f.edit.busy { once = false; f.edit.cancel() } }; f.edit.accept()
        XCTAssertTrue(f.saved.isEmpty); XCTAssertEqual(f.applied.last?.0, .empty); f.applied.last?.1(true); f.drain(); XCTAssertEqual(f.ends.first?.0, .cancelled)
    }
    func testSavedEnabledFlagIsNotAssumedToBeAnEffectiveListener() {
        let f = Fixture(enabled, effective: .empty); f.edit.cancel(); XCTAssertTrue(f.applied.isEmpty); XCTAssertTrue(f.saved.isEmpty); XCTAssertEqual(f.ends.first?.1, enabled)
    }
    func testRuntimeRestoreIsSeparateFromPersistedOpenedChoices() {
        let f = Fixture(enabled, effective: .empty); let changed = BrowserListenerChoice(options: .init(enabled: true, autoStart: true), password: "new")
        f.preview(changed); f.edit.accept(); f.edit.cancel(); f.saved.first?.1(true); f.drain(); XCTAssertEqual(f.applied.last?.0, .empty)
        f.applied.last?.1(true); f.drain(); XCTAssertEqual(f.saved.last?.0, enabled); f.saved.last?.1(true); f.drain(); XCTAssertEqual(f.ends.first?.1, enabled)
    }
    func testInvalidEffectiveOpenedSecretRefusesConstruction() {
        XCTAssertNil(BrowserListenerEdit(opened: .empty, effectiveOpened: .init(options: .init(), password: String(repeating: "é", count: 513)), isCurrent: { true }, apply: { _,_ in XCTFail("No preview"); return false }))
    }
    func testRepeatedAcceptAndUpdatesCannotQueueMoreThanOneCommit() {
        let f = Fixture(); f.preview(enabled); f.edit.accept()
        for _ in 0..<1000 { f.edit.accept(); f.edit.update(.empty) }; XCTAssertEqual(f.saved.count, 1); XCTAssertEqual(f.applied.count, 1)
        f.saved.first?.1(true); f.drain(); f.saved.first?.1(true); f.drain(); XCTAssertEqual(f.ends.count, 1)
    }
    func testCancelBeforeAnyCommitOnlyRestoresPreview() {
        let f = Fixture(); f.preview(enabled); f.edit.cancel(); f.applied.last?.1(true); f.drain(); XCTAssertTrue(f.saved.isEmpty); XCTAssertEqual(f.ends.first?.0, .cancelled)
    }
    func testPersistenceFailureAfterCancelStartsOneDistinctRestoreNotACommitRetry() {
        let f = Fixture(); f.preview(enabled); f.edit.accept(); f.edit.cancel(); f.saved.first?.1(false); f.drain(); f.applied.last?.1(true); f.drain()
        XCTAssertEqual(f.saved.count, 2); XCTAssertEqual(f.saved.last?.0, .empty); f.saved.last?.1(true); f.drain(); XCTAssertEqual(f.ends.first?.0, .cancelled)
    }
    func testHiddenWindowWaitsCommitAndFailureReenablesEditingWithReadableResult() throws {
        _ = NSApplication.shared; var current = true; var saves = [(Bool)->Void](), ends = [BrowserListenerEdit.End]()
        let c = try XCTUnwrap(BrowserListenerWindow(opened: .empty, isCurrent: { current }, apply: { _,reply in reply(true); return true }, commit: { _,reply in saves.append(reply); return true }, didEnd: { result,_ in ends.append(result) }, announce: { _,_ in }))
        c.acceptPressed(); XCTAssertEqual(saves.count, 1); XCTAssertFalse(c.password.isEnabled); XCTAssertTrue(ends.isEmpty)
        saves.first?(false); pump { c.password.isEnabled }; XCTAssertTrue(c.password.isEnabled); XCTAssertFalse(c.status.stringValue.isEmpty); XCTAssertTrue(ends.isEmpty); XCTAssertFalse(c.window?.isVisible == true)
        current = false; c.invalidateContext(); c.window?.close()
    }
    func testHiddenWindowCloseDuringCommitWaitsPersistedRestoration() throws {
        _ = NSApplication.shared; var current = true; var saves = [(BrowserListenerChoice,(Bool)->Void)](), ends = [BrowserListenerEdit.End]()
        let c = try XCTUnwrap(BrowserListenerWindow(opened: .empty, isCurrent: { current }, apply: { _,reply in reply(true); return true }, commit: { saves.append(($0,$1)); return true }, didEnd: { result,_ in ends.append(result) }, announce: { _,_ in }))
        c.password.stringValue = "synthetic"; c.enable.state = .on; c.acceptPressed(); pump { saves.count == 1 }; XCTAssertEqual(saves.count, 1)
        XCTAssertFalse(c.windowShouldClose(try XCTUnwrap(c.window))); saves.first?.1(true); pump { saves.count == 2 }; XCTAssertEqual(saves.count, 2); XCTAssertTrue(ends.isEmpty)
        saves.last?.1(true); pump { !ends.isEmpty }; XCTAssertEqual(ends, [.cancelled]); XCTAssertEqual(c.password.stringValue, "")
        current = false; c.window?.close()
    }
    func testHiddenWindowUsesExplicitEffectiveOpenedStateOnCancel() throws {
        _ = NSApplication.shared; var current = true; var previews = [BrowserListenerChoice](), saved = 0; var result: BrowserListenerChoice?
        let c = try XCTUnwrap(BrowserListenerWindow(opened: enabled, effectiveOpened: .empty, isCurrent: { current }, apply: { value,reply in previews.append(value); reply(true); return true }, commit: { _,_ in saved += 1; return false }, didEnd: { _,value in result = value }, announce: { _,_ in }))
        c.autoStart.state = .on; c.controlsChanged(c.autoStart); pump { !c.edit.busy }
        c.cancelPressed(); pump { result != nil }; XCTAssertEqual(previews.count, 2); XCTAssertEqual(previews.last, .empty); XCTAssertEqual(saved, 0); XCTAssertEqual(result, enabled); current = false; c.window?.close()
    }
    func testInvalidationFromChangedBeforeCommitDoesNotCallPersistence() {
        let f = Fixture(); var once = true; f.edit.changed = { if once && f.edit.busy { once = false; f.current = false; f.edit.invalidate() } }; f.edit.accept()
        XCTAssertTrue(f.saved.isEmpty); XCTAssertEqual(f.ends.first?.0, .invalidated); XCTAssertNil(f.ends.first?.1)
    }
    func testRefusedRestorationDoesNotInventCancelAndRequiresExplicitRetry() {
        let f = Fixture(); f.preview(enabled); f.edit.accept(); f.saved.first?.1(false); f.drain(); f.admitted = false; f.edit.cancel(); f.applied.last?.1(true); f.drain()
        XCTAssertEqual(f.saved.count, 2); XCTAssertTrue(f.ends.isEmpty); XCTAssertFalse(f.edit.busy)
        f.admitted = true; f.edit.cancel(); XCTAssertEqual(f.saved.count, 3); f.saved.last?.1(true); f.drain(); XCTAssertEqual(f.ends.first?.0, .cancelled)
    }
    func testOldPersistenceReceiptCannotFinishNewRetry() {
        let f = Fixture(); f.preview(enabled); f.edit.accept(); f.saved.first?.1(false); f.drain(); f.edit.accept()
        f.saved.first?.1(true); f.drain(); XCTAssertTrue(f.ends.isEmpty); XCTAssertTrue(f.edit.busy)
        f.saved.last?.1(true); f.drain(); XCTAssertEqual(f.ends.count, 1)
    }
}
