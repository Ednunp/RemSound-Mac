import AppKit
import XCTest
@testable import RemSoundApp

@MainActor private final class OwnedAlertHelpProbe: NSObject, NSAlertDelegate {
    var calls = 0
    func alertShowHelp(_ alert: NSAlert) -> Bool { calls += 1; return true }
}

@MainActor final class NativeContextHelpTests: XCTestCase {
    func testActualAlertHelpPreservesPlatformIdentityFocusAndUnmappedAccessory() {
        _ = NSApplication.shared
        let alert = NSAlert()
        alert.messageText = "Confirm the edit"
        alert.informativeText = "Keep this edit or cancel without changing the saved profile."
        alert.addButton(withTitle: "Keep"); alert.addButton(withTitle: "Cancel")
        let input = NSSecureTextField(string: "must-never-enter-help")
        input.identifier = .init("existing-input-identity")
        alert.accessoryView = input; alert.window.initialFirstResponder = input
        alert.layout()
        let identities = alert.buttons.map(\.identifier)
        FocusedHelpContent.markAlert(alert, notice: "dialog-notice", buttons: ["dialog-keep", "dialog-cancel"])
        XCTAssertEqual(alert.buttons.map(\.identifier), identities)
        XCTAssertEqual(alert.buttons.map { FocusedHelpContent.key(of: $0) }, ["dialog-keep", "dialog-cancel"])
        XCTAssertTrue(alert.window.initialFirstResponder === input)
        XCTAssertEqual(input.identifier?.rawValue, "existing-input-identity")
        XCTAssertNil(FocusedHelpContent.key(of: input))
        let text = NativeDialogAudit.liveControls(in: alert.window).compactMap { $0 as? NSTextField }.filter { $0 !== input }
        XCTAssertEqual(text.count, 2)
        XCTAssertTrue(text.allSatisfy { FocusedHelpContent.key(of: $0) == "dialog-notice" })
        alert.window.isReleasedWhenClosed = false; alert.window.close()
    }

    func testDialogAuditRejectsActualAddedControlsMissingDuplicateAndStaleManualEntries() {
        _ = NSApplication.shared
        var addControl = false
        let factory = NativeDialogAudit.Factory(site: "Example.init", make: {
            let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
            let input = NSSecureTextField(string: "private fixture value")
            input.identifier = .init("help-dialog-input"); window.contentView?.addSubview(input)
            if addControl { window.contentView?.addSubview(NSButton(title: "Added", target: nil, action: nil)) }
            return .init(window: window)
        })
        let words = entry.replacingOccurrences(of: "main-button", with: "dialog-input")
        XCTAssertEqual(NativeContextHelpAudit.inspectDialogs(factories: [factory], manual: .init(words)).failures, ["help.native.empty-dialog-factory-census"])
        addControl = true
        XCTAssertTrue(NativeContextHelpAudit.inspectDialogs(factories: [factory], manual: .init(words)).failures.contains("help.native.unkeyed-dialog-Example.init-1"))
        addControl = false
        XCTAssertTrue(NativeContextHelpAudit.inspectDialogs(factories: [factory], manual: .init(entry)).failures.contains("help.native.missing-or-duplicate-dialog-entry"))
        XCTAssertTrue(NativeContextHelpAudit.inspectDialogs(factories: [factory], manual: .init(words + words)).failures.contains("help.native.missing-or-duplicate-dialog-entry"))
        XCTAssertTrue(NativeContextHelpAudit.inspectDialogs(factories: [factory], manual: .init(words + words.replacingOccurrences(of: "dialog-input", with: "dialog-retired"))).failures.contains("help.native.stale-dialog-entry"))
    }

    func testDialogAuditVisitsInactivePagesAndRefusesThrowingFactory() {
        _ = NSApplication.shared
        let factory = NativeDialogAudit.Factory(site: "Tabs.init", make: {
            let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
            let tabs = NSTabView(); window.contentView?.addSubview(tabs)
            for index in 0..<2 {
                let item = NSTabViewItem(identifier: index); item.view = NSView()
                if index == 0 { item.view?.identifier = .init("help-dialog-input") }
                tabs.addTabViewItem(item)
            }
            return .init(window: window)
        })
        let words = entry.replacingOccurrences(of: "main-button", with: "dialog-input")
        XCTAssertTrue(NativeContextHelpAudit.inspectDialogs(factories: [factory], manual: .init(words)).failures.contains("help.native.unkeyed-dialog-tab"))
        let throwing = NativeDialogAudit.Factory(site: "Broken.init", make: { throw NativeDialogAudit.Failure.missingWindow })
        XCTAssertTrue(NativeContextHelpAudit.inspectDialogs(factories: [throwing], manual: .init(words)).failures.contains("help.native.throwing-dialog-Broken.init"))
    }
    func testMenuHelpPreservesNativeIdentityTargetActionStateShortcutAndPrivateProfileID() {
        let item = NSMenuItem(title: "Private profile title", action: #selector(NSObject.description), keyEquivalent: "p")
        let target = NSObject(); item.target = target; item.state = .on; item.isEnabled = false
        item.identifier = .init("native-existing-identity"); item.representedObject = UUID().uuidString
        let identity = item.representedObject as? String
        let manual = FocusedHelpContent.Manual(entry)
        XCTAssertTrue(FocusedHelpContent.markMenuItem(item, key: "main-button", manual: manual) === item)
        XCTAssertEqual(FocusedHelpContent.key(of: item), "main-button")
        XCTAssertEqual(item.toolTip, manual.entry("main-button"))
        XCTAssertFalse(item.toolTip!.contains(item.title))
        XCTAssertEqual(item.identifier?.rawValue, "native-existing-identity")
        XCTAssertEqual(item.representedObject as? String, identity)
        XCTAssertTrue(item.target as AnyObject? === target)
        XCTAssertEqual(item.action, #selector(NSObject.description)); XCTAssertEqual(item.keyEquivalent, "p")
        XCTAssertEqual(item.state, .on); XCTAssertFalse(item.isEnabled)
        FocusedHelpContent.markMenuItem(item, key: "missing", manual: manual)
        XCTAssertNil(item.toolTip)
    }

    func testActualNativeMenuAuditVisitsDisabledHiddenNestedItemsAndRejectsKeyOrCallerDrift() {
        let menu = NSMenu(title: "Fixture"), nested = NSMenu(title: "Nested")
        let parent = menu.addItem(withTitle: "Parent", action: nil, keyEquivalent: "")
        parent.submenu = nested; parent.isHidden = true; parent.isEnabled = false
        let child = nested.addItem(withTitle: "Child", action: nil, keyEquivalent: "")
        nested.addItem(.separator())
        let manual = FocusedHelpContent.Manual(entry)
        XCTAssertEqual(NativeContextHelpAudit.inspectMenu(menu, manual: manual).failures.count, 2)
        for item in [parent, child] { FocusedHelpContent.markMenuItem(item, key: "main-button", manual: manual) }
        XCTAssertTrue(NativeContextHelpAudit.inspectMenu(menu, manual: manual).failures.isEmpty)
        child.toolTip = "Wrong caller words"
        XCTAssertEqual(NativeContextHelpAudit.inspectMenu(menu, manual: manual).failures, ["help.native.menu-caller-text"])
        child.toolTip = manual.entry("main-button")
        XCTAssertTrue(NativeContextHelpAudit.inspectMenu(menu, manual: .init(entry + entry)).failures.contains("help.native.missing-or-duplicate-menu-entry"))
        nested.addItem(withTitle: "New actionable item", action: #selector(NSObject.description), keyEquivalent: "")
        XCTAssertTrue(NativeContextHelpAudit.inspectMenu(menu, manual: manual).failures.contains("help.native.unkeyed-menu-item"))
    }

    func testActualStandardHelpButtonDispatchKeepsNativeResponsesAndInputFocus() throws {
        _ = NSApplication.shared
        let alert = NSAlert(), delegate = OwnedAlertHelpProbe()
        alert.messageText = "Owned alert"; alert.informativeText = "Private entered context must never enter the manual."
        alert.addButton(withTitle: "Keep"); alert.addButton(withTitle: "Cancel")
        let input = NSSecureTextField(string: "private entered value")
        input.identifier = .init("native-input-id"); alert.accessoryView = input
        alert.window.initialFirstResponder = input; alert.layout()
        let ids = alert.buttons.map(\.identifier), keys = alert.buttons.map(\.keyEquivalent)
        FocusedHelpContent.markAlert(alert, notice: "main-button", buttons: ["keep", "cancel"], helpDelegate: delegate)
        XCTAssertTrue(alert.showsHelp); XCTAssertTrue(alert.delegate === delegate); XCTAssertNil(alert.helpAnchor)
        let help = try XCTUnwrap(NativeDialogAudit.liveControls(in: alert.window).compactMap { $0 as? NSButton }.first { $0.bezelStyle == .helpButton })
        XCTAssertNotNil(help.action); XCTAssertEqual(FocusedHelpContent.key(of: help), "main-button")
        XCTAssertEqual(help.accessibilityLabel(), "Help for this dialog")
        help.performClick(nil)
        XCTAssertEqual(delegate.calls, 1)
        XCTAssertEqual(alert.buttons.map(\.identifier), ids); XCTAssertEqual(alert.buttons.map(\.keyEquivalent), keys)
        XCTAssertTrue(alert.window.initialFirstResponder === input)
        XCTAssertEqual(input.stringValue, "private entered value"); XCTAssertEqual(input.identifier?.rawValue, "native-input-id")
        let content = try XCTUnwrap(FocusedHelpContent.content(for: alert, manual: .init(entry)))
        XCTAssertEqual(content.text, FocusedHelpContent.Manual(entry).entry("main-button"))
        XCTAssertFalse(content.text.contains(input.stringValue)); XCTAssertFalse(content.text.contains(alert.informativeText))
        XCTAssertNil(FocusedHelpContent.content(for: alert, manual: .init(entry + entry)))
        XCTAssertFalse(alert.window.isVisible); XCTAssertNil(NSApp.modalWindow)
        alert.window.isReleasedWhenClosed = false; alert.window.close()
    }

    func testUnownedAlertDoesNotAdvertiseExternalHelpAndNoticeLookupRequiresAMark() {
        _ = NSApplication.shared
        let alert = NSAlert(); alert.messageText = "Unowned"; alert.addButton(withTitle: "Close")
        XCTAssertNil(FocusedHelpContent.content(for: alert, manual: .init(entry)))
        FocusedHelpContent.markAlert(alert, notice: "main-button", buttons: ["close"])
        XCTAssertFalse(alert.showsHelp); XCTAssertNil(alert.delegate); XCTAssertNil(alert.helpAnchor)
        XCTAssertTrue(NativeDialogAudit.liveControls(in: alert.window).compactMap { $0 as? NSButton }.allSatisfy { $0.bezelStyle != .helpButton })
        alert.window.isReleasedWhenClosed = false; alert.window.close()
    }

    private let entry = "<!-- help-entry:main-button -->\nStart\n\nStart the current profile using its selected sources.\n<!-- /help-entry -->\n"
    func testManualKeepsExactWordsAndRefusesDuplicateShortMalformedAndOversizedEntries() {
        let manual = FocusedHelpContent.Manual(entry)
        XCTAssertEqual(manual.entry("main-button"), "Start\n\nStart the current profile using its selected sources.")
        XCTAssertNil(FocusedHelpContent.Manual(entry + entry).entry("main-button"))
        XCTAssertNil(FocusedHelpContent.Manual(entry.replacingOccurrences(of: "Start\n\nStart the current profile using its selected sources.", with: "Short")).entry("main-button"))
        XCTAssertFalse(FocusedHelpContent.Manual(entry + "<!-- help-entry:orphan -->").valid)
        XCTAssertFalse(FocusedHelpContent.Manual(String(repeating: "x", count: 512 * 1024 + 1)).valid)
    }
    func testActualContentUsesManualWordsWithoutReadingSecureValues() {
        let field = NSSecureTextField(string: "must-never-enter-help")
        field.identifier = .init("help-main-button"); field.setAccessibilityLabel("Password")
        field.setAccessibilityHelp("This older description must not override the manual.")
        let content = FocusedHelpContent.content(for: field, manual: .init(entry))
        XCTAssertEqual(content.text, FocusedHelpContent.Manual(entry).entry("main-button"))
        XCTAssertFalse(content.text.contains(field.stringValue))
        XCTAssertTrue(content.focusedView === field)
    }
    func testUnmappedDialogKeepsExistingDescriptionWithoutBorrowingAParentKey() {
        let field = NSTextField(string: "private entered value")
        field.setAccessibilityLabel("Example"); field.setAccessibilityHelp("Existing useful dialog instructions.")
        let content = FocusedHelpContent.content(for: field, manual: .init(entry))
        XCTAssertNil(FocusedHelpContent.key(of: field))
        XCTAssertEqual(content.text, "Example\n\nExisting useful dialog instructions.")
        XCTAssertFalse(content.text.contains(field.stringValue))
    }
    func testActualLiveTreeIncludesInactiveTabsAndRejectsUnkeyedOrStaleEntries() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 460, height: 300)); window.contentView?.addSubview(tabs)
        for index in 0..<4 {
            let item = NSTabViewItem(identifier: index), panel = NSView()
            panel.identifier = .init("help-main-tab-\(index)")
            item.view = panel; tabs.addTabViewItem(item)
            let field = NSTextField(); field.identifier = .init("help-main-button"); panel.addSubview(field)
        }
        var text = entry
        for index in 0..<4 { text += entry.replacingOccurrences(of: "main-button", with: "main-tab-\(index)") }
        let before = NativeContextHelpAudit.inspect(window: window, manual: .init(text))
        XCTAssertEqual(before.failures, ["help.native.empty-main-census"])
        let added = NSButton(title: "Added", target: nil, action: nil)
        tabs.tabViewItems[3].view?.addSubview(added)
        XCTAssertTrue(NativeContextHelpAudit.inspect(window: window, manual: .init(text)).failures.contains("help.native.unkeyed-main-control"))
        added.identifier = .init("help-main-new")
        XCTAssertTrue(NativeContextHelpAudit.inspect(window: window, manual: .init(text)).failures.contains("help.native.missing-or-duplicate-main-entry"))
        added.removeFromSuperview()
        let stale = text + entry.replacingOccurrences(of: "main-button", with: "main-retired")
        XCTAssertTrue(NativeContextHelpAudit.inspect(window: window, manual: .init(stale)).failures.contains("help.native.stale-main-entry"))
        XCTAssertTrue(NativeContextHelpAudit.inspect(window: window, manual: .init(text + entry)).failures.contains("help.native.missing-or-duplicate-main-entry"))
    }
    func testTabStripUsesItsActualSelectedPageKey() {
        let tabs = NSTabView()
        for index in 0..<2 {
            let item = NSTabViewItem(identifier: index); item.view = NSView()
            item.view?.identifier = .init("help-main-tab-\(index)"); tabs.addTabViewItem(item)
        }
        XCTAssertEqual(FocusedHelpContent.key(of: tabs), "main-tab-0")
        tabs.selectTabViewItem(at: 1)
        XCTAssertEqual(FocusedHelpContent.key(of: tabs), "main-tab-1")
    }
}
