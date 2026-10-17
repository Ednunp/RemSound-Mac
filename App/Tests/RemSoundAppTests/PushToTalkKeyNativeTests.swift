import AppKit
import Carbon
import RemSoundCore
import RemSoundRuntime
import XCTest
@testable import RemSoundApp

@MainActor
final class PushToTalkKeyNativeTests: XCTestCase {
    private let bare = HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_A), modifiers: [])
    private final class Changes: HotkeyCaptureFieldDelegate {
        var count = 0
        func hotkeyCaptureFieldDidChange(_ field: HotkeyCaptureField) { count += 1 }
    }
    private func field(_ mode: HotkeyCaptureField.CaptureMode = .pushToTalk) -> (HotkeyCaptureField, Changes) {
        _ = NSApplication.shared
        let field = HotkeyCaptureField(frame: .init(x: 0, y: 0, width: 200, height: 24)), changes = Changes()
        field.captureMode = mode; field.hotkeyDelegate = changes; field.onInvalidKey = {}
        return (field, changes)
    }
    private func event(_ code: Int = kVK_ANSI_A, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
                        windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                        isARepeat: repeatKey, keyCode: UInt16(code))!
    }
    func testBareLettersDigitsFunctionAndSpaceArePTTOnlyChoices() {
        for code in [kVK_ANSI_A, kVK_ANSI_Z, kVK_ANSI_0, kVK_ANSI_9, kVK_F1, kVK_F12, kVK_Space] {
            let key = HotkeyDescriptor(keyCode: UInt32(code), modifiers: [])
            XCTAssertTrue(key.isValidForPushToTalk, key.description); XCTAssertFalse(key.isValid)
        }
        XCTAssertNil(HotkeyDescriptor.parse("A"))
    }
    func testAllKnownModifierCombinationsRemainPTTChoices() {
        for mask in UInt32(0)..<16 {
            XCTAssertTrue(HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_A), modifiers: .init(rawValue: mask)).isValidForPushToTalk)
        }
        XCTAssertFalse(HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_A), modifiers: .init(rawValue: 16)).isValidForPushToTalk)
    }
    func testDialogAndUnknownKeysCannotBeBindings() {
        for code in [kVK_Tab, kVK_Escape, kVK_Return, kVK_Delete, kVK_ForwardDelete, kVK_Shift, kVK_LeftArrow, 65535] {
            XCTAssertFalse(HotkeyDescriptor(keyCode: UInt32(code), modifiers: [.control, .shift]).isValidForPushToTalk)
        }
        for code in [kVK_ANSI_W, kVK_ANSI_Q] {
            XCTAssertFalse(HotkeyDescriptor(keyCode: UInt32(code), modifiers: [.command]).isValidForPushToTalk)
            XCTAssertTrue(HotkeyDescriptor(keyCode: UInt32(code), modifiers: []).isValidForPushToTalk)
        }
    }
    func testNativeFieldCapturesBareKeyAndKeepsGeneralValidation() {
        let (f, c) = field(); f.keyDown(with: event()); XCTAssertEqual(f.descriptor, bare); XCTAssertEqual(c.count, 1)
        let (g, gc) = field(.general); g.keyDown(with: event()); XCTAssertNil(g.descriptor); XCTAssertEqual(gc.count, 0)
        g.keyDown(with: event(flags: [.control, .shift])); XCTAssertTrue(g.descriptor?.isValid == true); XCTAssertEqual(gc.count, 1)
    }
    func testCaptureRepeatDoesNotChangeValueOrAnnounceAgain() {
        let (f, c) = field(); f.keyDown(with: event()); f.keyDown(with: event(kVK_ANSI_Z, repeatKey: true))
        f.keyDown(with: event(kVK_Delete, repeatKey: true)); XCTAssertEqual(f.descriptor, bare); XCTAssertEqual(c.count, 1)
    }
    func testDeleteClearsAndTabKeepsTheBinding() {
        let (f, c) = field(); f.descriptor = bare
        f.keyDown(with: event(kVK_Tab)); XCTAssertEqual(f.descriptor, bare); XCTAssertEqual(c.count, 0)
        f.keyDown(with: event(kVK_Delete)); XCTAssertNil(f.descriptor); XCTAssertEqual(c.count, 1)
    }
    func testFocusedKeyEquivalentCapturesAndEscapePassesToWindow() {
        let (f, c) = field(); let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 240, height: 60),
            styleMask: [.titled], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false; w.contentView?.addSubview(f); XCTAssertTrue(w.makeFirstResponder(f))
        defer { w.makeFirstResponder(nil); w.close() }
        XCTAssertTrue(f.performKeyEquivalent(with: event())); XCTAssertEqual(f.descriptor, bare)
        XCTAssertFalse(f.performKeyEquivalent(with: event(kVK_Escape))); XCTAssertEqual(c.count, 1)
        XCTAssertFalse(f.performKeyEquivalent(with: event(kVK_ANSI_W, flags: [.command])))
        XCTAssertEqual(f.descriptor, bare)
    }
    func testFocusRetirementAndAccessibleCaptureHelp() {
        let (f, _) = field(); var focus: [Bool] = []; f.onCaptureFocusChanged = { focus.append($0) }
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 240, height: 60), styleMask: [.titled], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false; w.contentView?.addSubview(f)
        XCTAssertTrue(w.makeFirstResponder(f)); XCTAssertTrue(w.makeFirstResponder(f)); XCTAssertTrue(w.makeFirstResponder(nil)); w.close()
        XCTAssertEqual(focus, [true, false]); XCTAssertEqual(f.accessibilityRole(), .textField)
        XCTAssertTrue(f.accessibilityHelp()?.contains("with or without modifiers") == true)
        f.captureMode = .general; XCTAssertTrue(f.accessibilityHelp()?.contains("Two modifiers") == true)
    }
    func testInvalidCaptureKeepsExistingChoiceAndReportsOnce() {
        let (f, c) = field(); f.descriptor = bare; var invalid = 0; f.onInvalidKey = { invalid += 1 }
        f.keyDown(with: event(kVK_LeftArrow)); XCTAssertEqual(f.descriptor, bare); XCTAssertEqual(c.count, 0); XCTAssertEqual(invalid, 1)
    }
}

final class PushToTalkKeyPreferencesTests: XCTestCase {
    private let bare = HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_A), modifiers: [])
    private func fixture() throws -> (URL, SettingsStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ptt-key-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = try SettingsStore(file: root.appendingPathComponent("settings.plist"))
        addTeardownBlock { try FileManager.default.removeItem(at: root) }; return (root, store)
    }
    func testMissingBindingDoesNotChooseOrWriteADefault() throws {
        let (root, s) = try fixture(); XCTAssertNil(try PushToTalkKeyPreferences.load(from: s))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("settings.plist").path))
    }
    func testMachineBookReopensAndExplicitClearPersists() throws {
        let (root, s) = try fixture(); try PushToTalkKeyPreferences.save(bare, to: s)
        let reopened = try SettingsStore(file: root.appendingPathComponent("settings.plist"))
        XCTAssertEqual(try PushToTalkKeyPreferences.load(from: reopened), bare)
        try PushToTalkKeyPreferences.save(nil, to: reopened)
        XCTAssertNil(try PushToTalkKeyPreferences.load(from: try SettingsStore(file: root.appendingPathComponent("settings.plist"))))
        XCTAssertNotNil(reopened.data(forKey: PushToTalkKeyPreferences.settingsKey))
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("settings.plist").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testMalformedVersionTypeAndUnknownModifiersArePreserved() throws {
        let (_, s) = try fixture()
        for data in [Data("broken".utf8), Data("{\"version\":2}".utf8),
                     Data("{\"version\":1,\"binding\":{\"keyCode\":0,\"modifiers\":16}}".utf8)] {
            s.set(data, forKey: PushToTalkKeyPreferences.settingsKey)
            XCTAssertThrowsError(try PushToTalkKeyPreferences.load(from: s)); XCTAssertEqual(s.data(forKey: PushToTalkKeyPreferences.settingsKey), data)
        }
        s.set("previous sentinel", forKey: PushToTalkKeyPreferences.settingsKey)
        XCTAssertThrowsError(try PushToTalkKeyPreferences.load(from: s)); XCTAssertEqual(s.string(forKey: PushToTalkKeyPreferences.settingsKey), "previous sentinel")
    }
    func testOversizedDataIsRejectedWithoutClearingIt() throws {
        let (_, s) = try fixture(); let data = Data(repeating: 32, count: PushToTalkKeyPreferences.maximumStoredBytes + 1)
        s.set(data, forKey: PushToTalkKeyPreferences.settingsKey); XCTAssertThrowsError(try PushToTalkKeyPreferences.load(from: s))
        XCTAssertEqual(s.data(forKey: PushToTalkKeyPreferences.settingsKey), data)
    }
    func testInvalidExplicitChoiceDoesNotOverwriteGoodKey() throws {
        let (_, s) = try fixture(); try PushToTalkKeyPreferences.save(bare, to: s)
        let bytes = s.data(forKey: PushToTalkKeyPreferences.settingsKey)
        XCTAssertThrowsError(try PushToTalkKeyPreferences.save(.init(keyCode: UInt32(kVK_Escape), modifiers: []), to: s))
        XCTAssertEqual(s.data(forKey: PushToTalkKeyPreferences.settingsKey), bytes)
        XCTAssertEqual(try PushToTalkKeyPreferences.load(from: s), bare)
    }
    func testFailedAtomicWriteKeepsCachedKeyAndReportsFailure() throws {
        let (root, s) = try fixture(); try PushToTalkKeyPreferences.save(bare, to: s)
        let file = root.appendingPathComponent("settings.plist"); try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try PushToTalkKeyPreferences.save(nil, to: s)); XCTAssertTrue(s.persistenceFailed)
        XCTAssertEqual(try PushToTalkKeyPreferences.load(from: s), bare)
    }
    func testProfileChoicesAndGeneralHotkeysRemainIndependent() throws {
        let (_, s) = try fixture(); let general = Data("general hotkey book".utf8); s.set(general, forKey: "hotkeys")
        try PushToTalkKeyPreferences.save(bare, to: s); let keyData = s.data(forKey: PushToTalkKeyPreferences.settingsKey)
        var ptt = PushToTalkSettings(); ptt.enabled = true; ptt.levelDb = -30
        try PushToTalkPreferences.save(ptt, to: s); try PushToTalkPreferences.save(.init(), to: s)
        XCTAssertEqual(s.data(forKey: PushToTalkKeyPreferences.settingsKey), keyData); XCTAssertEqual(s.data(forKey: "hotkeys"), general)
        XCTAssertEqual(try PushToTalkKeyPreferences.load(from: s), bare)
    }
}
