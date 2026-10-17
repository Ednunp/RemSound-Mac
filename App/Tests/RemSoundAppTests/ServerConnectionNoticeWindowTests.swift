import AppKit
import XCTest
@testable import RemSoundApp

@MainActor
final class ServerConnectionNoticeWindowTests:XCTestCase {
    private func fixture()->(ServerConnectionNoticeWindow,NSMutableArray) {
        _=NSApplication.shared;let answers=NSMutableArray();let d=ServerConnectionNoticeWindow(answer:{answers.add($0)})
        addTeardownBlock{MainActor.assumeIsolated{d.retire()}};return(d,answers)
    }
    func testNativeReadableNoticeNamesDefaultAndFocus() {
        let(d,a)=fixture();XCTAssertEqual(d.message.string,ServerConnectionNotice.message)
        XCTAssertEqual(d.message.accessibilityLabel(),"Server notice");XCTAssertFalse(d.message.isEditable);XCTAssertTrue(d.message.isSelectable)
        XCTAssertEqual(d.suppression.state,.off);XCTAssertEqual(d.suppression.accessibilityLabel(),"Don't show this message again")
        XCTAssertEqual(d.ok.accessibilityLabel(),"OK");XCTAssertEqual(a.count,0);XCTAssertFalse(d.window!.isVisible)
        d.window?.makeFirstResponder(d.message);XCTAssertEqual(d.message.selectedRange(),NSRange(location:0,length:0))
    }
    func testNativeTabAndShiftTabTraverseMessageChoiceAndOK() {
        let(d,_)=fixture();d.window?.makeFirstResponder(d.message)
        d.window?.selectNextKeyView(nil);XCTAssertTrue(d.window?.firstResponder === d.suppression)
        d.window?.selectNextKeyView(nil);XCTAssertTrue(d.window?.firstResponder === d.ok)
        d.window?.selectPreviousKeyView(nil);XCTAssertTrue(d.window?.firstResponder === d.suppression)
        d.window?.selectPreviousKeyView(nil);XCTAssertTrue(d.window?.firstResponder === d.message)
    }
    func testReturnEscapeAndWindowCloseAcknowledgeOnlyOnceWithWorkingChoice() {
        for code:UInt16 in [36,76,53] {
            let(d,a)=fixture();d.suppression.state = .on
            let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:code)!
            XCTAssertTrue(d.window!.performKeyEquivalent(with:event));XCTAssertEqual(a.count,1);XCTAssertEqual(a.firstObject as? Bool,true)
            d.accept();XCTAssertEqual(a.count,1)
        }
        let(d,a)=fixture();d.window?.close();XCTAssertEqual(a.count,1);XCTAssertEqual(a.firstObject as? Bool,false)
    }
    func testRetirementClosesWithoutAcknowledgmentAndRefusesQueuedActions() {
        let(d,a)=fixture();d.suppression.state = .on;d.retire();d.accept();d.window?.close();XCTAssertEqual(a.count,0)
    }
    func testErrorKeepsWorkingChoiceFocusAndRetryAction() {
        let(d,a)=fixture();d.suppression.state = .on;d.showError("Could not save the notice choice.")
        XCTAssertEqual(d.status.stringValue,"Could not save the notice choice.");XCTAssertFalse(d.status.isHidden)
        XCTAssertTrue(d.window?.firstResponder === d.status || d.status.currentEditor() === d.window?.firstResponder)
        XCTAssertEqual(d.suppression.state,.on);XCTAssertEqual(a.count,0);d.accept();XCTAssertEqual(a.count,1)
    }
    func testReadoutRemainsAfterNativeFocusLeavesAndQueuedRefreshRuns() async {
        let(d,_)=fixture();d.window?.makeFirstResponder(d.message);d.window?.makeFirstResponder(d.suppression)
        let refreshed=expectation(description:"Native readout refresh")
        DispatchQueue.main.async { XCTAssertEqual(d.message.string,ServerConnectionNotice.message);refreshed.fulfill() }
        await fulfillment(of:[refreshed],timeout:2)
    }
}
