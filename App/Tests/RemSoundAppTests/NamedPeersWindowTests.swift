import AppKit
import Carbon
import XCTest
import RemSoundRuntime
@testable import RemSoundApp

@MainActor
final class NamedPeersWindowTests: XCTestCase {
    private func fixture(contextHelp: ((Bool, NSWindow) -> Void)? = nil) throws -> (NamedPeersWindow, NamedPeerHistory) {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]))
            .appendingPathComponent("named-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let history = try NamedPeerHistory(settings: SettingsStore(file: root.appendingPathComponent("settings.plist")))
        XCTAssertTrue(history.name(machine: "A", address: "192.0.2.1", friendlyName: "Alpha"))
        XCTAssertTrue(history.name(machine: "B", address: nil, friendlyName: "Beta"))
        let c = NamedPeersWindow(owner: nil, contextHelp: contextHelp, read: { history.entries },
            rename: { history.rename($0, friendlyName: $1) }, forget: { history.forget($0) }, announce: { _ in })
        addTeardownBlock { c.window?.close(); try? FileManager.default.removeItem(at: root) }
        return (c, history)
    }
    func testHelpKeysKeepTheRealBookAndNativeSelection() throws {
        var requests = [Bool]()
        weak var requestedWindow: NSWindow?
        let (c, book) = try fixture(contextHelp: { manual, window in requests.append(manual); requestedWindow = window })
        let before = book.entries
        c.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertTrue(c.window!.makeFirstResponder(c.table))
        for flags: NSEvent.ModifierFlags in [.function, [.shift, .function]] {
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: c.window!.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: UInt16(kVK_F1))!
            c.window!.sendEvent(key)
        }
        XCTAssertEqual(requests, [false, true]); XCTAssertTrue(requestedWindow === c.window)
        XCTAssertEqual(book.entries, before); XCTAssertEqual(c.table.selectedRow, 1)
        XCTAssertTrue(c.window!.firstResponder === c.table); XCTAssertFalse(c.window!.isVisible)
    }
    func testHiddenConstructionAndTabOrderExposeActualNamedBook() throws {
        let (c, _) = try fixture()
        XCTAssertFalse(c.window?.isVisible == true); XCTAssertEqual(c.records.count, 2)
        XCTAssertEqual(c.table.accessibilityLabel(), "Named peers")
        XCTAssertTrue(c.table.allowsMultipleSelection)
        XCTAssertTrue(c.table.nextKeyView === c.renameButton)
        XCTAssertTrue(c.renameButton.nextKeyView === c.deleteButton)
        XCTAssertTrue(c.deleteButton.nextKeyView === c.closeButton)
        XCTAssertTrue(c.closeButton.nextKeyView === c.table)
        XCTAssertEqual(c.renameButton.keyEquivalentModifierMask, .option)
        XCTAssertEqual(c.deleteButton.keyEquivalentModifierMask, .option)
    }
    func testRenameAndCancelUseRealStoreWithoutLosingIdentitySelection() throws {
        let (c, h) = try fixture()
        c.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let before = h.entries
        c.namePrompt = { _ in nil }; c.renameSelected(); XCTAssertEqual(h.entries, before)
        c.namePrompt = { _ in "Zulu" }; c.renameSelected()
        XCTAssertEqual(h.entries.first(where: { $0.machineName == "A" })?.friendlyName, "Zulu")
        XCTAssertEqual(c.records[c.table.selectedRow].machineName, "A")
        let selected = c.table.selectedRowIndexes; c.refresh(); XCTAssertEqual(c.table.selectedRowIndexes, selected)
    }
    func testCommandAAndDeleteForgetAllAndDoNotCollectAnonymousTraffic() throws {
        let (c, h) = try fixture()
        let all = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 1, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: UInt16(kVK_ANSI_A)))
        c.table.keyDown(with: all); XCTAssertEqual(c.table.selectedRowIndexes.count, 2)
        let delete = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_Delete)))
        c.table.keyDown(with: delete)
        XCTAssertTrue(h.entries.isEmpty); XCTAssertTrue(c.records.isEmpty)
        XCTAssertFalse(c.renameButton.isEnabled); XCTAssertFalse(c.deleteButton.isEnabled)
        XCTAssertFalse(h.noteConnected(machine: "A", address: "192.0.2.1"))
    }
    func testStaleDialogKeepsCurrentNamesAndSelectionAndShowsRefusal() throws {
        let (c, h) = try fixture()
        c.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        c.namePrompt = { row in
            XCTAssertTrue(h.rename(row, friendlyName: "Changed elsewhere"))
            return "Stale modal answer"
        }
        c.renameSelected()
        XCTAssertEqual(h.entries.first(where: { $0.machineName == "A" })?.friendlyName, "Changed elsewhere")
        XCTAssertEqual(c.records[c.table.selectedRow].machineName, "A")
        XCTAssertTrue(c.status.stringValue.contains("could not be saved"))
    }
    func testUnavailableBookIsTruthfulAndDisablesMutations() {
        _ = NSApplication.shared
        let c = NamedPeersWindow(owner: nil, read: { nil }, rename: { _, _ in XCTFail(); return false },
            forget: { _ in XCTFail(); return false }, announce: { _ in })
        defer { c.window?.close() }
        XCTAssertTrue(c.status.stringValue.contains("could not be read"))
        XCTAssertFalse(c.renameButton.isEnabled); XCTAssertFalse(c.deleteButton.isEnabled)
    }
}
