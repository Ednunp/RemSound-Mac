import AppKit
import Carbon
import RemSoundRuntime
import XCTest
@testable import RemSoundApp

final class TypingEventMonitorTests: XCTestCase {
    private final class Registry {
        var handlers: [(NSEvent) -> NSEvent?] = []
        var removed: [Any] = []
        var fails = false
        func install(_ handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
            handlers.append(handler)
            return fails ? nil : NSObject()
        }
        func remove(_ token: Any) { removed.append(token) }
    }

    private func fixture(_ flags: [String] = []) throws -> (RuntimeConfiguration, CuePreferences) {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("typing-hook-\(UUID())")
        let options = try LaunchOptions.parse(flags + ["--config-dir", root.path],
            environment: ["REMSOUND_ALLOW_VISIBLE_UI_TESTS": "1"])
        let configuration = try RuntimeConfiguration(options: options)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (configuration, CuePreferences(settings: configuration.settings))
    }

    private func event(_ characters: String = "a", code: Int = kVK_ANSI_A,
        modifiers: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)))
    }

    func testTypedCharactersSpaceBackspaceAndOptionTextAreObservedWithoutConsuming() throws {
        let (configuration, cues) = try fixture()
        let registry = Registry(), field = NSTextField(string: "")
        var clicked: [Bool] = []
        let hook = TypingEventMonitor(configuration: configuration, preferences: cues,
            onCharacter: { clicked.append($0) }, install: registry.install, remove: registry.remove,
            context: { _ in .init(responder: field, root: nil) })
        hook.start()
        let handler = try XCTUnwrap(registry.handlers.first)
        let events = try [event(), event(" ", code: kVK_Space), event("\u{7f}", code: kVK_Delete),
            event("A", modifiers: .shift), event("ø", modifiers: .option), event("\n", code: kVK_Return)]
        for value in events { XCTAssertTrue(handler(value) === value) }
        XCTAssertEqual(clicked, Array(repeating: false, count: events.count))
        hook.stop()
        XCTAssertEqual(registry.removed.count, 1)
    }

    func testShortcutsNavigationEscapeTabAndEmptyEventsNeverClick() throws {
        let (configuration, cues) = try fixture()
        let registry = Registry(), field = NSTextField(string: "")
        var clicks = 0
        let hook = TypingEventMonitor(configuration: configuration, preferences: cues,
            onCharacter: { _ in clicks += 1 }, install: registry.install, remove: registry.remove,
            context: { _ in .init(responder: field, root: nil) })
        hook.start()
        let handler = try XCTUnwrap(registry.handlers.first)
        let events = try [event(modifiers: .command), event(modifiers: .control),
            event("\t", code: kVK_Tab), event("\u{1b}", code: kVK_Escape), event("", code: kVK_ANSI_E),
            event("\u{f700}", code: kVK_UpArrow), event("\u{f704}", code: kVK_F1),
            event("\u{f728}", code: kVK_ForwardDelete), event("\u{7f}", code: kVK_Delete, modifiers: .option),
            event("\u{1}", modifiers: []), event(type: .keyUp)]
        for value in events { XCTAssertTrue(handler(value) === value) }
        XCTAssertEqual(clicks, 0)
        hook.stop()
    }

    func testSharedSecureFieldEditorUsesOwningControlWithoutReadingItsValue() throws {
        let editor = NSTextView(), secure = NSSecureTextField(string: "not inspected")
        editor.isFieldEditor = true
        let wrapper = NSView(), root = NSView()
        wrapper.addSubview(secure); root.addSubview(wrapper)
        var visits: [NSTextField] = []
        let result = TypingEventMonitor.target(for: editor, root: root, ownsEditor: { field, candidate in
            visits.append(field)
            return field === secure && candidate === editor
        })
        XCTAssertEqual(result, .password)
        XCTAssertEqual(visits.count, 1)
        XCTAssertTrue(visits.first === secure)
        XCTAssertEqual(TypingEventMonitor.target(for: secure, root: nil), .password)
    }

    func testUnknownSharedEditorFailsClosedAndOrdinaryOwnerIsRecognized() {
        let editor = NSTextView(), field = NSTextField(string: "")
        editor.isFieldEditor = true
        let root = NSView(); root.addSubview(field)
        XCTAssertNil(TypingEventMonitor.target(for: editor, root: nil))
        XCTAssertNil(TypingEventMonitor.target(for: editor, root: root, ownsEditor: { _, _ in false }))
        XCTAssertEqual(TypingEventMonitor.target(for: editor, root: root,
            ownsEditor: { $0 === field && $1 === editor }), .ordinary)
    }

    func testSelectableReadOnlyTextIsIncludedAndNonTextAndHotkeyControlsAreExcluded() {
        let field = NSTextField(string: "")
        field.isEditable = false; field.isSelectable = true
        XCTAssertEqual(TypingEventMonitor.target(for: field, root: nil), .ordinary)
        field.isSelectable = false
        XCTAssertNil(TypingEventMonitor.target(for: field, root: nil))
        let text = NSTextView(); text.isEditable = false; text.isSelectable = true
        XCTAssertEqual(TypingEventMonitor.target(for: text, root: nil), .ordinary)
        text.isSelectable = false
        XCTAssertNil(TypingEventMonitor.target(for: text, root: nil))
        XCTAssertNil(TypingEventMonitor.target(for: NSButton(), root: nil))
        XCTAssertNil(TypingEventMonitor.target(for: HotkeyCaptureField(), root: nil))
    }

    func testMuteProfileAndRuntimeSilenceGateRegistrationAndEveryEvent() throws {
        for flags in [["--silent"], ["--headless"]] {
            let (configuration, cues) = try fixture(flags)
            let registry = Registry()
            let hook = TypingEventMonitor(configuration: configuration, preferences: cues,
                onCharacter: { _ in XCTFail("Ineligible run must not observe typing") },
                install: registry.install, remove: registry.remove)
            hook.start(); hook.refresh(); hook.stop()
            XCTAssertTrue(registry.handlers.isEmpty)
        }
        let (configuration, cues) = try fixture()
        let registry = Registry(), field = NSTextField(string: "")
        var clicks = 0
        let hook = TypingEventMonitor(configuration: configuration, preferences: cues,
            onCharacter: { _ in clicks += 1 }, install: registry.install, remove: registry.remove,
            context: { _ in .init(responder: field, root: nil) })
        cues.setKeyboardClicksEnabled(false)
        hook.start(); XCTAssertTrue(registry.handlers.isEmpty)
        cues.setKeyboardClicksEnabled(true); hook.refresh()
        let handler = try XCTUnwrap(registry.handlers.last), value = try event()
        cues.setMuteAllCues(true)
        XCTAssertTrue(handler(value) === value)
        cues.setMuteAllCues(false); cues.setKeyboardClicksEnabled(false)
        XCTAssertTrue(handler(value) === value)
        XCTAssertEqual(clicks, 0, "A change before refresh must still fail closed")
        hook.refresh(); hook.stop()
        XCTAssertEqual(registry.removed.count, 1)
    }

    func testRefreshAndStopAreIdempotentAndRetiredHandlerCannotDuplicateTyping() throws {
        let (configuration, cues) = try fixture()
        let registry = Registry(), field = NSTextField(string: "")
        var clicks = 0
        let hook = TypingEventMonitor(configuration: configuration, preferences: cues,
            onCharacter: { _ in clicks += 1 }, install: registry.install, remove: registry.remove,
            context: { _ in .init(responder: field, root: nil) })
        hook.start(); hook.start(); hook.refresh()
        XCTAssertEqual(registry.handlers.count, 1)
        let retired = try XCTUnwrap(registry.handlers.first), value = try event()
        cues.setMuteAllCues(true); hook.refresh()
        cues.setMuteAllCues(false); hook.refresh()
        XCTAssertEqual(registry.handlers.count, 2)
        XCTAssertTrue(retired(value) === value)
        XCTAssertEqual(clicks, 0)
        XCTAssertTrue(registry.handlers[1](value) === value)
        XCTAssertEqual(clicks, 1)
        hook.stop(); hook.stop(); hook.refresh()
        XCTAssertTrue(registry.handlers[1](value) === value)
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(registry.removed.count, 2)
    }

    func testHeadlessHandoverOnlyEnablesObservationWithoutExplicitSilent() throws {
        for flags in [["--headless"], ["--headless", "--silent"]] {
            let (configuration, cues) = try fixture(flags)
            let registry = Registry()
            let hook = TypingEventMonitor(configuration: configuration, preferences: cues,
                onCharacter: { _ in }, install: registry.install, remove: registry.remove)
            hook.start(); XCTAssertTrue(registry.handlers.isEmpty)
            configuration.handOverToGUI(); hook.refresh()
            XCTAssertEqual(registry.handlers.count, flags.contains("--silent") ? 0 : 1)
            hook.stop()
        }
    }

    func testShutdownReleasesMonitorWithoutRetainCycleAndStaleEventStillPassesThrough() throws {
        let (configuration, cues) = try fixture()
        let registry = Registry()
        var hook: TypingEventMonitor? = TypingEventMonitor(configuration: configuration, preferences: cues,
            onCharacter: { _ in XCTFail("Released monitor must not click") },
            install: registry.install, remove: registry.remove)
        weak var released = hook
        hook?.start()
        let handler = try XCTUnwrap(registry.handlers.first), value = try event()
        hook = nil
        XCTAssertNil(released)
        XCTAssertEqual(registry.removed.count, 1)
        XCTAssertTrue(handler(value) === value)
    }

    func testUnavailableMonitorLeavesServiceInertAndCanRetryAtExplicitRefresh() throws {
        let (configuration, cues) = try fixture()
        let registry = Registry(); registry.fails = true
        let hook = TypingEventMonitor(configuration: configuration, preferences: cues,
            onCharacter: { _ in XCTFail("Unregistered monitor cannot click") },
            install: registry.install, remove: registry.remove)
        hook.start(); XCTAssertEqual(registry.handlers.count, 1)
        XCTAssertTrue(registry.removed.isEmpty)
        registry.fails = false; hook.refresh()
        XCTAssertEqual(registry.handlers.count, 2)
        hook.stop(); XCTAssertEqual(registry.removed.count, 1)
    }

    func testPrintableAppleSymbolIsNotMistakenForAFunctionKey() throws {
        let (configuration, cues) = try fixture()
        let registry = Registry(), field = NSTextField(string: "")
        var clicks = 0
        let hook = TypingEventMonitor(configuration: configuration, preferences: cues,
            onCharacter: { _ in clicks += 1 }, install: registry.install, remove: registry.remove,
            context: { _ in .init(responder: field, root: nil) })
        hook.start()
        let handler = try XCTUnwrap(registry.handlers.first)
        let apple = try event("\u{f8ff}", code: kVK_ANSI_K, modifiers: [.option, .shift])
        XCTAssertTrue(handler(apple) === apple)
        XCTAssertEqual(clicks, 1, "Only AppKit's function-key range is excluded, not all private-use symbols")
        hook.stop()
    }

    func testSecureEditorRoutesOnlyPasswordFlagAndNavigationCodeCannotMasqueradeAsText() throws {
        let (configuration, cues) = try fixture()
        let registry = Registry(), editor = NSTextView(), secure = NSSecureTextField(string: "not inspected")
        editor.isFieldEditor = true
        let root = NSView(); root.addSubview(secure)
        var flags: [Bool] = []
        let hook = TypingEventMonitor(configuration: configuration, preferences: cues,
            onCharacter: { flags.append($0) }, install: registry.install, remove: registry.remove,
            context: { _ in .init(responder: editor, root: root) },
            ownsEditor: { $0 === secure && $1 === editor })
        hook.start()
        let handler = try XCTUnwrap(registry.handlers.first), typed = try event()
        XCTAssertTrue(handler(typed) === typed)
        for code in [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
            kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete] {
            let navigation = try event("a", code: code)
            XCTAssertTrue(handler(navigation) === navigation)
        }
        XCTAssertEqual(flags, [true])
        hook.stop()
    }

    func testRepeatedLifetimeChurnLeavesExactlyOneMonitorAndNoRetiredCallbacks() throws {
        let (configuration, cues) = try fixture()
        let registry = Registry(), field = NSTextField(string: "")
        var clicks = 0
        let hook = TypingEventMonitor(configuration: configuration, preferences: cues,
            onCharacter: { _ in clicks += 1 }, install: registry.install, remove: registry.remove,
            context: { _ in .init(responder: field, root: nil) })
        for _ in 0..<500 { hook.start(); hook.refresh(); hook.stop() }
        XCTAssertEqual(registry.handlers.count, 500)
        XCTAssertEqual(registry.removed.count, 500)
        let value = try event()
        for retired in registry.handlers { XCTAssertTrue(retired(value) === value) }
        XCTAssertEqual(clicks, 0)
        hook.start()
        XCTAssertTrue(try XCTUnwrap(registry.handlers.last)(value) === value)
        XCTAssertEqual(clicks, 1)
        hook.stop()
        XCTAssertEqual(registry.removed.count, 501)
    }
}
