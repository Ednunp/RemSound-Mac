import AppKit
import XCTest
@testable import RemSoundApp

@MainActor final class NativeDialogAuditTests: XCTestCase {
    func testNativeFocusOnlyShortcutAndStatusFieldsRemainInTheLiveCensus() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let shortcut = HotkeyCaptureField(), status = FocusableStatusField(wrappingLabelWithString: "")
        status.isEditable = false; status.isSelectable = false; status.setAccessibilityLabel("Result")
        window.contentView?.addSubview(shortcut); window.contentView?.addSubview(status)
        XCTAssertFalse(shortcut.isEditable); XCTAssertFalse(shortcut.isSelectable)
        XCTAssertTrue(shortcut.acceptsFirstResponder); XCTAssertTrue(status.acceptsFirstResponder)
        let actual = NativeDialogAudit.liveControls(in: window)
        XCTAssertTrue(actual.contains { $0 === shortcut })
        XCTAssertTrue(actual.contains { $0 === status })
    }
    func testActualConstructorTokensAndInheritedTypesAreDiscovered() {
        let sources = ["App.swift": """
            // NSWindow() is not a construction site.
            final class Host: NSWindow {}
            final class Child: Host {}
            final class Question: NSAlert {}
            final class Panel: NSWindowController {
                init() { let window = Child(); super.init(window: window) }
                func prompt() { let a = NSAlert(); a.accessoryView = NSTextField() }
                func picker() { let p = NSOpenPanel() }
            }
            let example = "NSAlert()"
            """]
        let found = NativeDialogAudit.census(sources)
        XCTAssertEqual(found.windowTypes, ["Host", "Child"])
        XCTAssertEqual(found.controllerTypes, ["Panel"])
        XCTAssertEqual(found.alertTypes, ["Question"])
        XCTAssertEqual(found.sites, ["App.init": 1, "App.prompt": 1, "App.picker": 1])
        XCTAssertEqual(found.customAlerts, ["App.prompt"])
    }
    func testMissingStaleAndThrowingActualFactoriesCannotPass() {
        _ = NSApplication.shared
        let source = ["Prompt.swift": "func build() { let window = NSWindow() }"]
        let absent = NativeDialogAudit.inspect(sources: source, factories: [], nonDialogs: [:], controls: false)
        XCTAssertTrue(absent.failures.contains("dialogs.native.unreached-site-Prompt.build"))
        let stale = NativeDialogAudit.inspect(sources: source, factories: [.init(site: "Prompt.deleted", make: { .init(window: NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)) })], nonDialogs: [:], controls: false)
        XCTAssertTrue(stale.failures.contains("dialogs.native.stale-factory-Prompt.deleted"))
        let throwing = NativeDialogAudit.inspect(sources: source, factories: [.init(site: "Prompt.build", make: { throw NativeDialogAudit.Failure.missingWindow })], nonDialogs: [:], controls: false)
        XCTAssertTrue(throwing.failures.contains("dialogs.native.throwing-factory-Prompt.build"))
    }
    func testCustomAlertCannotBeClaimedAsPlatformMessageBox() {
        let source = ["Prompt.swift": "func build() { let a = NSAlert(); a.showsSuppressionButton = true }"]
        let found = NativeDialogAudit.inspect(sources: source, factories: [], nonDialogs: ["Prompt.build": 1], controls: false)
        XCTAssertTrue(found.failures.contains("dialogs.native.unreached-site-Prompt.build"))
    }
    func testActualEQPromptRetainsDelegateAndPreviewsOnlyCurrentValidFields() {
        var previews = 0
        let prompt = AddBandDialog.buildPrompt(preview: { band in if band != nil { previews += 1 } })
        let alert = AddBandDialog.buildAlert(prompt: prompt, focus: prompt.start)
        XCTAssertTrue(alert.accessoryView === prompt.grid)
        XCTAssertTrue(alert.window.initialFirstResponder === prompt.start)
        XCTAssertNotNil(prompt.start.delegate)
        prompt.start.stringValue = "100"; prompt.end.stringValue = "1000"
        prompt.start.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: prompt.start))
        XCTAssertEqual(previews, 1)
        prompt.end.stringValue = "50"
        prompt.end.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: prompt.end))
        XCTAssertEqual(previews, 1)
        alert.window.isReleasedWhenClosed = false; alert.window.close()
    }
    func testEmptyPlatformLabelDoesNotHideBlankInputsOrNamedReadouts() {
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let input = NSTextField(string: ""), label = NSTextField(labelWithString: ""), status = NSTextField(labelWithString: "")
        label.isSelectable = true; status.isSelectable = true; status.setAccessibilityLabel("Result")
        for view in [input, label, status] { window.contentView?.addSubview(view) }
        let actual = NativeDialogAudit.liveControls(in: window)
        XCTAssertTrue(actual.contains { $0 === input }); XCTAssertTrue(actual.contains { $0 === status })
        XCTAssertFalse(actual.contains { $0 === label })
    }
    func testInlineExtensionFactoryIsNamedAndDotInitIsNotADeclaration() {
        let source = ["Owner.swift": """
            func previous() {}
            extension Owner { func newlyAdded() -> NSWindow { let x = Value.init(); return NSWindow() } }
            """]
        XCTAssertEqual(NativeDialogAudit.census(source).sites, ["Owner.newlyAdded": 1])
    }
}
