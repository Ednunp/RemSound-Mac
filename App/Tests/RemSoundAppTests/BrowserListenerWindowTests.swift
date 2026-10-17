import AppKit
import Carbon
import Foundation
import RemSoundCore
import XCTest
@testable import RemSoundApp

@MainActor final class BrowserListenerWindowTests:XCTestCase {
    func testHelpKeysKeepTheCurrentPasswordEditorAndDoNotCommitOrQuery() throws {
        _ = NSApplication.shared
        var requests = [Bool](), applications = 0, endings = 0
        weak var requestedWindow: NSWindow?
        let edit = try XCTUnwrap(BrowserListenerEdit(opened: .empty, isCurrent: { true }, apply: { _, done in
            applications += 1; done(true); return true
        }))
        let c = try XCTUnwrap(BrowserListenerWindow(edit: edit, visit: .stopped, contextHelp: { manual, window in
            requests.append(manual); requestedWindow = window
        }, didEnd: { _, _ in endings += 1 }))
        defer { c.invalidateContext(); c.window?.close() }
        c.password.stringValue = "owned-uncommitted-password"
        XCTAssertTrue(c.window!.makeFirstResponder(c.password))
        for flags: NSEvent.ModifierFlags in [.function, [.shift, .function]] {
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: c.window!.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: UInt16(kVK_F1))!
            c.window!.sendEvent(key)
        }
        XCTAssertEqual(requests, [false, true]); XCTAssertTrue(requestedWindow === c.window)
        XCTAssertTrue(FocusedHelpContent.capture(in: c.window).focusedView === c.password)
        XCTAssertEqual(c.password.stringValue, "owned-uncommitted-password")
        XCTAssertEqual(applications, 0); XCTAssertEqual(endings, 0)
        XCTAssertNil(c.addressModel); XCTAssertFalse(c.window!.isVisible)
    }
    @MainActor private final class Events {
        var current=true
        var attempts=[(BrowserListenerChoice,(Bool)->Void)](),ends=[(BrowserListenerEdit.End,BrowserListenerChoice?)](),announcements=[String]()
    }
    private func fixture(_ opened:BrowserListenerChoice = .empty) throws -> (BrowserListenerWindow,Events) {
        _=NSApplication.shared;let e=Events()
        let c=try XCTUnwrap(BrowserListenerWindow(opened:opened,isCurrent:{e.current},apply:{e.attempts.append(($0,$1));return true},didEnd:{e.ends.append(($0,$1))},announce:{_,message in e.announcements.append(message)}))
        addTeardownBlock {MainActor.assumeIsolated { e.current=false;c.invalidateContext();for row in e.attempts {row.1(true)};RunLoop.main.run(until:Date().addingTimeInterval(0.003));c.window?.close() }}
        return (c,e)
    }
    private func drain() {RunLoop.main.run(until:Date().addingTimeInterval(0.004))}
    private func pump(_ condition:()->Bool) {
        let deadline=Date().addingTimeInterval(2)
        while !condition() && Date() < deadline {RunLoop.main.run(until:Date().addingTimeInterval(0.001))}
    }
    private func event(_ code:Int,flags:NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:1,windowNumber:0,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:UInt16(code)))
    }
    func testHiddenOpeningCopiesChoicesWithoutApplyingOrConstructingService() throws {
        let wanted=BrowserListenerChoice(options:.init(enabled:true,autoStart:true),password:"synthetic")
        let (c,e)=try fixture(wanted);XCTAssertEqual(c.password.stringValue,wanted.password);XCTAssertEqual(c.enable.state,.on);XCTAssertEqual(c.autoStart.state,.on)
        XCTAssertTrue(e.attempts.isEmpty);XCTAssertFalse(c.window?.isVisible == true)
    }
    func testNativeControlsExposeNamesHelpRolesAndStorageWarning() throws {
        let(c,_)=try fixture();for view in c.controlOrder {XCTAssertFalse((view.accessibilityLabel() ?? "").isEmpty);XCTAssertFalse((view.accessibilityHelp() ?? "").isEmpty)}
        XCTAssertEqual(c.enable.cell?.accessibilityRole(),.checkBox);XCTAssertEqual(c.password.accessibilityRole(),.textField)
        XCTAssertTrue(c.autoStart.accessibilityHelp()?.contains("local storage") == true);XCTAssertTrue(c.storageNote.stringValue.contains("does not immediately clear"))
        XCTAssertTrue(c.ok.keyEquivalentModifierMask.isEmpty);XCTAssertTrue(c.cancel.keyEquivalentModifierMask.isEmpty)
    }
    func testBothTabDirectionsFollowActualNestedNativeControls() throws {
        let(c,_)=try fixture();for backwards in [false,true] {
            let order=backwards ? Array(c.controlOrder.reversed()):c.controlOrder;c.window?.makeFirstResponder(order[0])
            for expected in Array(order.dropFirst())+[order[0]] {c.window?.sendEvent(try event(kVK_Tab,flags:backwards ? .shift:[]));XCTAssertTrue(c.window?.firstResponder === expected || (expected as? NSTextField)?.currentEditor() === c.window?.firstResponder)}
        }
    }
    func testCheckboxPreviewUsesOnlyCommittedPasswordAndPasswordCommitsOnLeaving() throws {
        let(c,e)=try fixture();c.password.stringValue="  synthetic  ";c.enable.state = .on;c.controlsChanged(c.enable)
        XCTAssertEqual(e.attempts.count,0) // Blank enabled preview is already off.
        c.controlTextDidEndEditing(Notification(name:NSControl.textDidEndEditingNotification,object:c.password))
        XCTAssertEqual(e.attempts.count,1);XCTAssertEqual(e.attempts.first?.0.password,"synthetic");XCTAssertTrue(e.attempts.first?.0.options.enabled == true)
    }
    func testCancelEscapeAndCloseWaitActualOpenedChoiceRestoration() throws {
        for key in [kVK_Escape,kVK_ANSI_W] {
            let(c,e)=try fixture();c.password.stringValue="synthetic";XCTAssertTrue(c.commitPassword());e.attempts.first?.1(true);pump{!c.edit.busy}
            c.enable.state = .on;c.controlsChanged(c.enable);XCTAssertTrue(c.window?.performKeyEquivalent(with:try event(key,flags:key==kVK_ANSI_W ? .command:[])) == true)
            XCTAssertTrue(e.ends.isEmpty);e.attempts.last?.1(true);pump{e.attempts.last?.0 == .empty};XCTAssertEqual(e.attempts.last?.0,.empty);XCTAssertTrue(e.ends.isEmpty)
            e.attempts.last?.1(true);pump{!e.ends.isEmpty};XCTAssertEqual(e.ends.first?.0,.cancelled);XCTAssertEqual(e.ends.first?.1,.empty)
        }
    }
    func testOKCommitsCurrentlyTypedPasswordAndWaitsReceipt() throws {
        let(c,e)=try fixture();c.password.stringValue="synthetic";c.enable.state = .on;c.autoStart.state = .on;c.acceptPressed()
        XCTAssertEqual(e.attempts.count,1);XCTAssertTrue(e.ends.isEmpty);e.attempts.first?.1(true);pump{!e.ends.isEmpty}
        XCTAssertEqual(e.ends.first?.0,.accepted);XCTAssertTrue(e.ends.first?.1?.options.autoStart == true);XCTAssertEqual(c.password.stringValue,"")
    }
    func testEmptyPasswordAndOverLimitStayOpenWithFocusedReadableFailure() throws {
        let(c,e)=try fixture();c.enable.state = .on;c.acceptPressed();XCTAssertTrue(e.ends.isEmpty);XCTAssertFalse(c.status.stringValue.isEmpty)
        c.password.stringValue=String(repeating:"é",count:513);XCTAssertFalse(c.commitPassword());XCTAssertTrue(e.attempts.isEmpty)
        XCTAssertTrue(c.window?.firstResponder === c.password || c.password.currentEditor() === c.window?.firstResponder);XCTAssertFalse(e.announcements.isEmpty)
    }
    func testShownPasswordTypingAndSharedEditorUsePasswordIdentity() throws {
        let(c,_)=try fixture();XCTAssertEqual(TypingEventMonitor.target(for:c.password,root:nil),.password)
        let editor=NSTextView();editor.isFieldEditor=true;let root=try XCTUnwrap(c.window?.contentView)
        XCTAssertEqual(TypingEventMonitor.target(for:editor,root:root,ownsEditor:{$0 === c.password && $1 === editor}),.password)
    }
    func testFocusedHelpContainsDescriptionsWithoutPasswordValue() throws {
        let(c,_)=try fixture();c.password.stringValue="synthetic-never-help";c.window?.makeFirstResponder(c.password)
        let help=FocusedHelpContent.capture(in:c.window);XCTAssertEqual(help.title,"Browser listener password");XCTAssertFalse(help.text.contains(c.password.stringValue))
    }
    func testHiddenLayoutContainsEveryFocusableControl() throws {
        let(c,_)=try fixture();let content=try XCTUnwrap(c.window?.contentView);content.layoutSubtreeIfNeeded()
        for view in c.controlOrder {let rect=content.convert(view.bounds,from:view);XCTAssertGreaterThan(rect.width,0);XCTAssertGreaterThan(rect.height,0);XCTAssertTrue(content.bounds.insetBy(dx:-1,dy:-1).contains(rect))}
        XCTAssertFalse(c.window?.isVisible == true)
    }
    func testProfileInvalidationWaitsPendingPreviewAndDoesNotRestoreOldSecret() throws {
        let(c,e)=try fixture();c.password.stringValue="synthetic";XCTAssertTrue(c.commitPassword());c.window?.makeFirstResponder(c.password);e.current=false;c.invalidateContext();XCTAssertTrue(e.ends.isEmpty)
        XCTAssertEqual(c.password.stringValue,"");XCTAssertFalse(c.password.isEnabled)
        XCTAssertTrue(c.window?.firstResponder === c.status || c.status.currentEditor() === c.window?.firstResponder)
        e.attempts.first?.1(true);pump{!e.ends.isEmpty};XCTAssertEqual(e.ends.first?.0,.invalidated);XCTAssertNil(e.ends.first?.1);XCTAssertEqual(e.attempts.count,1);XCTAssertEqual(c.password.stringValue,"")
    }
    func testCloseDelegateUsesSamePendingRestorationBarrierAsCancel() throws {
        let(c,e)=try fixture();c.password.stringValue="synthetic";XCTAssertTrue(c.commitPassword());c.window?.makeFirstResponder(c.password)
        XCTAssertFalse(c.windowShouldClose(try XCTUnwrap(c.window)));XCTAssertTrue(e.ends.isEmpty)
        XCTAssertTrue(c.window?.firstResponder === c.status || c.status.currentEditor() === c.window?.firstResponder)
        e.attempts.first?.1(true);pump{e.attempts.count == 2};XCTAssertEqual(e.attempts.last?.0,.empty);XCTAssertTrue(e.ends.isEmpty)
        e.attempts.last?.1(true);pump{!e.ends.isEmpty};XCTAssertEqual(e.ends.first?.0,.cancelled)
    }
    func testModifiedReturnNeverAcceptsButReturnAndKeypadEnterDo() throws {
        let(c,e)=try fixture()
        for flags:NSEvent.ModifierFlags in [.control,.option,.command,.shift] {_=c.window?.performKeyEquivalent(with:try event(kVK_Return,flags:flags))}
        XCTAssertTrue(e.ends.isEmpty)
        XCTAssertTrue(c.window?.performKeyEquivalent(with:try event(kVK_ANSI_KeypadEnter)) == true);XCTAssertEqual(e.ends.first?.0,.accepted)
    }
}
