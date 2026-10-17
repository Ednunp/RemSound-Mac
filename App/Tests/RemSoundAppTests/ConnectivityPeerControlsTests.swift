import AppKit
import Carbon
import RemSoundCore
import RemSoundRuntime
import XCTest
@testable import RemSoundApp

final class ConnectivityPeerControlsTests: XCTestCase {
    private func key(_ characters: String, code: Int) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code))!
    }
    func testNativeNamesRolesAndKeyboardChainWithoutOpeningWindow() {
        let pane = ConnectivityPeerControls()
        XCTAssertNil(pane.view.window)
        XCTAssertEqual(pane.lockAddresses.cell?.accessibilityRole(), .checkBox)
        XCTAssertEqual(pane.entry.cell?.accessibilityRole(), .textField)
        XCTAssertEqual(pane.remembered.accessibilityRole(), .table)
        XCTAssertEqual(pane.entry.accessibilityLabel(), "Add peer IPv4 address or hostname")
        XCTAssertEqual(pane.remembered.accessibilityLabel(), "Remembered peers")
        XCTAssertEqual(pane.keyViews.count, 8)
        for index in 0..<pane.keyViews.count - 1 {
            XCTAssertTrue(pane.keyViews[index].nextKeyView === pane.keyViews[index + 1])
        }
        XCTAssertNil(pane.keyViews.last?.nextKeyView)
        for button in [pane.lockAddresses, pane.add, pane.cancel, pane.connect, pane.forget, pane.clear] {
            XCTAssertEqual(button.accessibilityLabel(), button.title)
            XCTAssertNotNil(button.action)
        }
    }
    func testUnchangedRefreshPreservesSelectedEntryWithoutReloadOrNotice() {
        let pane = ConnectivityPeerControls(); var notices: [String] = []
        pane.onNotice = { notices.append($0) }
        pane.refresh(entries: ["Studio", "Other"], running: true, locked: false)
        pane.remembered.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let before = pane.reloadCount
        for _ in 0..<100 { pane.refresh(entries: ["Studio", "Other"], running: true, locked: false) }
        XCTAssertEqual(pane.reloadCount, before)
        XCTAssertEqual(pane.remembered.selectedRow, 1)
        XCTAssertTrue(notices.isEmpty)
        pane.refresh(entries: ["New", "Other", "Studio"], running: true, locked: false)
        XCTAssertEqual(pane.remembered.selectedRow, 1)
        XCTAssertEqual(pane.entries[pane.remembered.selectedRow], "Other")
    }
    func testNativeAddDisablesWhilePendingAndKeepsOriginalPortForOwner() {
        let pane = ConnectivityPeerControls(); var reply: ((PeerAddResult) -> Void)?, sent: [String] = [], notices: [String] = []
        pane.onAdd = { sent.append($0); reply = $1 }; pane.onNotice = { notices.append($0) }
        pane.entry.stringValue = " Studio.invalid:54321 "
        pane.refresh(entries: [], running: true, locked: false)
        pane.add.performClick(nil)
        XCTAssertEqual(sent, [" Studio.invalid:54321 "])
        XCTAssertTrue(pane.adding); XCTAssertFalse(pane.entry.isEnabled); XCTAssertFalse(pane.add.isEnabled); XCTAssertTrue(pane.cancel.isEnabled)
        reply?(.added(address: "192.0.2.1", remembered: true))
        XCTAssertFalse(pane.adding); XCTAssertTrue(pane.entry.isEnabled); XCTAssertFalse(pane.cancel.isEnabled)
        XCTAssertEqual(pane.entry.stringValue, ""); XCTAssertEqual(notices, ["Peer added."])
        reply?(.knownServer); XCTAssertEqual(notices.count, 1)
    }
    func testRememberingFailureReportsAddedConnectionTruthfully() {
        let pane = ConnectivityPeerControls(); var notices: [String] = []
        pane.onAdd = { _, reply in reply(.added(address: "192.0.2.1", remembered: false)) }
        pane.onNotice = { notices.append($0) }; pane.entry.stringValue = "Studio"
        pane.refresh(entries: [], running: true, locked: false); pane.add.performClick(nil)
        XCTAssertEqual(notices, ["Peer added, but could not save remembered peer list."])
        XCTAssertFalse(pane.adding)
    }
    func testCancelAndStoppedRefreshIgnoreOldResultAndPermitNewAdd() {
        let pane = ConnectivityPeerControls(); var replies: [(PeerAddResult) -> Void] = [], cancelled = 0, notices: [String] = []
        pane.onAdd = { _, reply in replies.append(reply) }; pane.onCancel = { cancelled += 1 }; pane.onNotice = { notices.append($0) }
        pane.entry.stringValue = "Studio"; pane.refresh(entries: [], running: true, locked: false)
        pane.add.performClick(nil); pane.cancel.performClick(nil)
        replies[0](.added(address: "192.0.2.1", remembered: true))
        XCTAssertEqual(cancelled, 1); XCTAssertEqual(pane.entry.stringValue, "Studio")
        XCTAssertEqual(notices, ["Add cancelled. Existing connections are unchanged."])
        pane.add.performClick(nil); pane.refresh(entries: [], running: false, locked: false)
        if replies.indices.contains(1) { replies[1](.knownServer) } else { XCTFail("A fresh Add must remain available after cancellation") }
        XCTAssertEqual(cancelled, 2); XCTAssertEqual(notices.count, 1)
        pane.refresh(entries: [], running: true, locked: false); pane.add.performClick(nil)
        if replies.indices.contains(2) { replies[2](.added(address: "192.0.2.2", remembered: true)) } else { XCTFail("Restarting availability must allow a new Add") }
        XCTAssertEqual(notices.last, "Peer added.")
    }
    func testReturnAndSpaceConnectRememberedEntryWithoutOverwritingUnsentDraft() {
        let pane = ConnectivityPeerControls(); var sent: [String] = []
        pane.onAdd = { sent.append($0); $1(.added(address: "192.0.2.1", remembered: true)) }
        pane.entry.stringValue = "Unsent draft"
        pane.refresh(entries: ["Studio:54321"], running: true, locked: false)
        for event in [key("\r", code: kVK_Return), key("\r", code: kVK_ANSI_KeypadEnter), key(" ", code: kVK_Space)] { pane.remembered.keyDown(with: event) }
        XCTAssertEqual(sent, ["Studio:54321", "Studio:54321", "Studio:54321"])
        XCTAssertEqual(pane.entry.stringValue, "Unsent draft")
        pane.refresh(entries: ["Studio:54321"], running: false, locked: false)
        pane.remembered.keyDown(with: key("\r", code: kVK_Return)); XCTAssertEqual(sent.count, 3)
    }
    func testDeleteForgetsOnlyAfterConfirmedSaveAndAnnouncesNextSameIndexRow() {
        let pane = ConnectivityPeerControls(); var reply: ((Bool) -> Void)?, requested: [String] = [], notices: [String] = []
        pane.onForget = { requested.append($0); reply = $1 }; pane.onNotice = { notices.append($0) }
        pane.refresh(entries: ["Studio", "Other"], running: true, locked: false)
        pane.remembered.keyDown(with: key("\u{7f}", code: kVK_Delete))
        XCTAssertEqual(requested, ["Studio"]); XCTAssertEqual(pane.entries, ["Studio", "Other"])
        XCTAssertFalse(pane.forget.isEnabled); XCTAssertFalse(pane.clear.isEnabled)
        // Session publishes the real saved list before its main-thread completion.
        pane.refresh(entries: ["Other"], running: true, locked: false)
        reply?(true)
        XCTAssertEqual(pane.remembered.selectedRow, 0)
        XCTAssertEqual(notices, ["Studio removed. Other."])
        reply?(true); XCTAssertEqual(notices.count, 1)
    }
    func testFailedForgetAndClearPreserveStoredPresentationAndSelection() {
        let pane = ConnectivityPeerControls(); var notices: [String] = []
        pane.onForget = { _, reply in reply(false) }; pane.onClear = { reply in reply(false) }; pane.onNotice = { notices.append($0) }
        pane.refresh(entries: ["Studio", "Other"], running: false, locked: false)
        pane.forget.performClick(nil); pane.clear.performClick(nil)
        XCTAssertEqual(pane.entries, ["Studio", "Other"]); XCTAssertEqual(pane.remembered.selectedRow, 0)
        XCTAssertEqual(notices.count, 2); XCTAssertTrue(notices.allSatisfy { $0.hasPrefix("Could not") })
        XCTAssertTrue(pane.forget.isEnabled); XCTAssertTrue(pane.clear.isEnabled)
    }
    func testClearCancelsPendingAddAndKeepsEmptyListNoticeDistinctFromDisconnection() {
        let pane = ConnectivityPeerControls(); var reply: ((PeerAddResult) -> Void)?, cancelled = 0, notices: [String] = []
        pane.onAdd = { _, callback in reply = callback }; pane.onCancel = { cancelled += 1 }
        pane.onClear = { callback in callback(true) }; pane.onNotice = { notices.append($0) }
        pane.entry.stringValue = "Other"; pane.refresh(entries: ["Studio"], running: true, locked: false)
        pane.add.performClick(nil); pane.clear.performClick(nil)
        reply?(.added(address: "192.0.2.1", remembered: true))
        XCTAssertEqual(cancelled, 1); XCTAssertTrue(pane.entries.isEmpty); XCTAssertEqual(pane.remembered.selectedRow, -1)
        XCTAssertEqual(notices, ["Remembered peer list cleared. Current connections are unchanged."])
    }
    func testAddressLockRefreshAndActionStayIndependentOfConnectionAvailability() {
        let pane = ConnectivityPeerControls(); var changed: [Bool] = []
        pane.onLock = { changed.append($0) }
        pane.refresh(entries: [], running: false, locked: true)
        XCTAssertEqual(pane.lockAddresses.state, .on); XCTAssertTrue(changed.isEmpty)
        pane.lockAddresses.performClick(nil); XCTAssertEqual(changed, [false])
        pane.refresh(entries: [], running: true, locked: false)
        pane.lockAddresses.performClick(nil); XCTAssertEqual(changed, [false, true])
    }
    func testFieldReturnAndEscapeUseActionsRatherThanStartingAnotherSession() {
        let pane = ConnectivityPeerControls(); var reply: ((PeerAddResult) -> Void)?, calls = 0, cancelled = 0
        pane.onAdd = { _, result in calls += 1; reply = result }; pane.onCancel = { cancelled += 1 }
        pane.entry.stringValue = "Studio"; pane.refresh(entries: [], running: true, locked: false)
        XCTAssertTrue(pane.control(pane.entry, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(pane.control(pane.entry, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        reply?(.knownServer); XCTAssertEqual(cancelled, 1); XCTAssertFalse(pane.adding)
        XCTAssertFalse(pane.control(pane.entry, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(pane.cancel.keyEquivalent, "\u{1b}"); XCTAssertTrue(pane.cancel.keyEquivalentModifierMask.isEmpty)
        XCTAssertFalse(pane.control(pane.entry, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))))
    }
    func testOperationStatusIsSuppressedOnlyForItsOwnPendingResult() {
        let pane = ConnectivityPeerControls(); var reply: ((PeerAddResult) -> Void)?
        pane.onAdd = { _, callback in reply = callback }; pane.entry.stringValue = "Studio"
        pane.refresh(entries: [], running: true, locked: false); pane.add.performClick(nil)
        XCTAssertTrue(pane.handlesOperationStatus("Peer added."))
        XCTAssertFalse(pane.handlesOperationStatus("Another peer connected."))
        reply?(.unresolved); XCTAssertFalse(pane.handlesOperationStatus("Peer added."))
    }
    func testFailureResultsRetainInputAndRestoreAvailability() {
        for result in [PeerAddResult.invalidEntry, .unresolved, .knownServer, .notRunning, .limitReached] {
            let pane = ConnectivityPeerControls(); var notices: [String] = []
            pane.onAdd = { _, callback in callback(result) }; pane.onNotice = { notices.append($0) }
            pane.entry.stringValue = "Studio"; pane.refresh(entries: [], running: true, locked: false); pane.add.performClick(nil)
            XCTAssertEqual(pane.entry.stringValue, "Studio"); XCTAssertFalse(pane.adding)
            XCTAssertTrue(pane.add.isEnabled); XCTAssertEqual(notices.count, 1)
        }
    }
    func testActualOwnerMoveHelperPersistsCopiesWithoutReplacingExplicitDestinationChoices() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("native-owner-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = try SettingsStore(file: root.appendingPathComponent("settings.plist"))
        var mixes = ["192.0.2.1": PeerMix(volume: 42)], aliases = ["192.0.2.1": "Friendly"]
        PeerProfileMove.apply(from: "192.0.2.1", to: "192.0.2.2", mixes: &mixes, aliases: &aliases, settings: settings)
        XCTAssertEqual(mixes["192.0.2.2"], PeerMix(volume: 42)); XCTAssertEqual(aliases["192.0.2.2"], "Friendly")
        XCTAssertNotNil(mixes["192.0.2.1"]); XCTAssertEqual(aliases["192.0.2.1"], "Friendly")
        XCTAssertEqual(try JSONDecoder().decode([String: PeerMix].self, from: XCTUnwrap(settings.data(forKey: "peerMixes"))), mixes)
        mixes["192.0.2.2"] = PeerMix(volume: 17); aliases["192.0.2.2"] = "Explicit"
        PeerProfileMove.apply(from: "192.0.2.1", to: "192.0.2.2", mixes: &mixes, aliases: &aliases, settings: settings)
        XCTAssertEqual(mixes["192.0.2.2"], PeerMix(volume: 17)); XCTAssertEqual(aliases["192.0.2.2"], "Explicit")
        XCTAssertEqual(settings.dictionary(forKey: "peerAliases") as? [String: String], aliases)
    }
    func testAddressLockChoiceReportsFailedPrivateWriteAndRetainsPriorEffectiveSetting() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("native-lock-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.plist")
        let settings = try SettingsStore(file: file)
        XCTAssertTrue(PeerAddressLockChoice.save(true, settings: settings))
        let before = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertFalse(PeerAddressLockChoice.save(false, settings: settings))
        XCTAssertTrue(settings.bool(forKey: "lockPeerAddresses"))
        XCTAssertEqual(try Data(contentsOf: file), before)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
}
