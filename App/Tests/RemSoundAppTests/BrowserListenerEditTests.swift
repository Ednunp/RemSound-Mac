import Foundation
import XCTest
import RemSoundCore
@testable import RemSoundApp

@MainActor final class BrowserListenerEditTests: XCTestCase {
    @MainActor private final class Fixture {
        var current = true, accept = true, inline: Bool?, hook: (() -> Void)?
        var attempts = [(BrowserListenerChoice,(Bool)->Void)](), endings = [(BrowserListenerEdit.End,BrowserListenerChoice?)]()
        var edit: BrowserListenerEdit!
        init(_ opened: BrowserListenerChoice = .empty) {
            edit = BrowserListenerEdit(opened:opened,isCurrent:{ [weak self] in self?.current == true },apply:{ [weak self] value,reply in
                guard let self else { return false }; self.attempts.append((value,reply)); self.hook?(); if let inline=self.inline {reply(inline)}; return self.accept
            })
            edit?.ended = { [weak self] in self?.endings.append(($0,$1)) }
        }
    }
    private let enabled = BrowserListenerChoice(options:.init(enabled:true),password:"synthetic")
    private func drain() { RunLoop.main.run(until:Date().addingTimeInterval(0.003)) }
    func testOpeningNeverAppliesAndInvalidOversizedSecretRefusesBeforeFactory() {
        let f=Fixture();XCTAssertEqual(f.edit.choice,.empty);XCTAssertTrue(f.attempts.isEmpty)
        let invalid=BrowserListenerChoice(options:.init(),password:String(repeating:"x",count:1025))
        XCTAssertNil(BrowserListenerEdit(opened:invalid,isCurrent:{true},apply:{_,_ in XCTFail("Oversized secret factory");return true}))
    }
    func testOneApplyAndLatestCoalescedPreviewBoundAThousandEdits() {
        let f=Fixture();f.edit.update(enabled);XCTAssertEqual(f.attempts.count,1);XCTAssertTrue(f.edit.busy)
        for n in 0..<1000 {f.edit.update(.init(options:.init(enabled:true,autoStart:n%2==0),password:"next"))}
        func pump(_ done: () -> Bool) { let end=Date().addingTimeInterval(2); while !done() && Date()<end { drain() } }
        XCTAssertEqual(f.attempts.count,1);f.attempts.first?.1(true);pump {f.attempts.count==2};XCTAssertEqual(f.attempts.count,2)
        XCTAssertEqual(f.attempts.last?.0.password,"next");f.attempts.last?.1(true);pump {!f.edit.busy};XCTAssertFalse(f.edit.busy)
    }
    func testCancelWaitsOldReceiptThenExactOpenedChoiceRestoration() {
        let opened=BrowserListenerChoice(options:.init(autoStart:true),password:"opened")
        let f=Fixture(opened);f.edit.update(enabled);f.edit.cancel();XCTAssertTrue(f.endings.isEmpty)
        f.attempts.first?.1(true);drain();XCTAssertEqual(f.attempts.last?.0,opened);XCTAssertTrue(f.endings.isEmpty)
        f.attempts.last?.1(true);drain();XCTAssertEqual(f.endings.first?.0,.cancelled);XCTAssertEqual(f.endings.first?.1,opened)
        XCTAssertEqual(f.edit.choice,.empty)
    }
    func testAcceptWaitsActualFinalPreviewReceipt() {
        let f=Fixture();f.edit.update(enabled);f.edit.accept();XCTAssertTrue(f.endings.isEmpty)
        f.attempts.first?.1(true);drain();XCTAssertEqual(f.endings.count,1);XCTAssertEqual(f.endings.first?.0,.accepted);XCTAssertEqual(f.endings.first?.1,enabled)
    }
    func testRefusedInlineCallbackCannotInventReceipt() {
        let f=Fixture();f.accept=false;f.inline=true;f.edit.update(enabled);drain()
        XCTAssertFalse(f.edit.busy);XCTAssertFalse(f.edit.message.isEmpty);XCTAssertTrue(f.endings.isEmpty)
    }
    func testFirstCallbackWinsAndNoDuplicateNativeWorkAfterAccept() {
        let f=Fixture();f.edit.update(enabled);f.edit.accept();f.attempts.first?.1(true);f.attempts.first?.1(false);drain()
        XCTAssertEqual(f.endings.count,1);f.edit.update(.empty);f.edit.cancel();XCTAssertEqual(f.attempts.count,1);XCTAssertEqual(f.endings.count,1)
    }
    func testFailedEffectNeedsExactRestoreBeforeCancelCanClose() {
        let f=Fixture();f.edit.update(enabled);f.attempts.first?.1(false);drain();XCTAssertFalse(f.edit.message.isEmpty)
        XCTAssertEqual(f.attempts.count,1);f.edit.cancel();XCTAssertEqual(f.attempts.count,2);XCTAssertTrue(f.endings.isEmpty)
        f.attempts.last?.1(true);drain();XCTAssertEqual(f.endings.first?.0,.cancelled)
    }
    func testFailedRestoreKeepsWindowOpenWithoutRetryLoopOrFalseCancel() {
        let f=Fixture();f.edit.update(enabled);f.attempts.first?.1(true);drain();f.edit.cancel();f.attempts.last?.1(false);drain()
        XCTAssertEqual(f.attempts.count,2);XCTAssertTrue(f.endings.isEmpty);XCTAssertFalse(f.edit.message.isEmpty)
        f.edit.cancel();XCTAssertEqual(f.attempts.count,3);f.attempts.last?.1(true);drain();XCTAssertEqual(f.endings.count,1)
    }
    func testBlankEnabledDraftStopsPreviewButCannotBeAccepted() {
        let f=Fixture(enabled);f.edit.update(.init(options:.init(enabled:true,autoStart:true),password:""))
        XCTAssertEqual(f.attempts.first?.0.options.enabled,false);XCTAssertEqual(f.attempts.first?.0.password,"")
        f.attempts.first?.1(true);drain();f.edit.accept();XCTAssertTrue(f.endings.isEmpty);XCTAssertFalse(f.edit.message.isEmpty)
    }
    func testUTF8LimitIsBytesAndRefusalRetainsPriorDraft() {
        let f=Fixture();let wanted=BrowserListenerChoice(options:.init(),password:String(repeating:"é",count:512))
        f.edit.update(wanted);XCTAssertEqual(f.edit.choice,wanted);f.attempts.first?.1(true);drain()
        f.edit.update(.init(options:.init(),password:String(repeating:"é",count:513)));XCTAssertEqual(f.edit.choice,wanted);XCTAssertEqual(f.attempts.count,1)
    }
    func testProfileLossWaitsPendingReceiptAndNeverRestoresIntoReplacement() {
        let f=Fixture();f.edit.update(enabled);f.current=false;f.edit.invalidate();XCTAssertTrue(f.endings.isEmpty)
        f.attempts.first?.1(true);drain();XCTAssertEqual(f.endings.first?.0,.invalidated);XCTAssertNil(f.endings.first?.1);XCTAssertEqual(f.attempts.count,1)
    }
    func testReentrantProfileLossDuringRawApplyDoesNotBorrowAnotherSecret() {
        let f=Fixture();f.hook={f.current=false;f.edit.invalidate()};f.edit.update(enabled)
        XCTAssertTrue(f.endings.isEmpty);f.attempts.first?.1(true);drain();XCTAssertEqual(f.endings.first?.0,.invalidated);XCTAssertEqual(f.attempts.count,1)
    }
    func testNoChangeCancelDoesNotInvokeBackend() {
        let f=Fixture(enabled);f.edit.cancel();XCTAssertTrue(f.attempts.isEmpty);XCTAssertEqual(f.endings.first?.1,enabled)
    }
    func testRetirementInvalidationDiscardsPasswordAndQueuedDraft() {
        let f=Fixture();f.edit.update(enabled);f.edit.update(.init(options:.init(enabled:true),password:"queued"));f.edit.invalidate()
        f.attempts.first?.1(true);drain();XCTAssertEqual(f.attempts.count,1);XCTAssertEqual(f.edit.choice,.empty);XCTAssertTrue(f.edit.finished)
    }
    func testForeignCallbackIsMarshalledToMain() {
        let f=Fixture();f.edit.update(enabled);let done=expectation(description:"main completion")
        f.edit.ended={_,_ in XCTAssertTrue(Thread.isMainThread);done.fulfill()};f.edit.accept();let reply=f.attempts.first?.1
        DispatchQueue.global().async {reply?(true);reply?(false)};wait(for:[done],timeout:2);XCTAssertTrue(f.edit.finished)
    }
    func testCancelBeforeRawApplyNeverBorrowsTheObsoletePassword() {
        let f=Fixture();var once=true
        f.edit.changed={if once && f.edit.busy {once=false;f.edit.cancel()}}
        f.edit.update(enabled);XCTAssertTrue(f.attempts.isEmpty);XCTAssertEqual(f.endings.first?.0,.cancelled)
    }
    func testCancelDuringRawApplyWaitsReceiptThenRestoresBeforeEnding() {
        let f=Fixture();f.hook={f.hook=nil;f.edit.cancel()};f.edit.update(enabled)
        XCTAssertEqual(f.attempts.count,1);XCTAssertTrue(f.endings.isEmpty);f.attempts.first?.1(true);drain()
        XCTAssertEqual(f.attempts.last?.0,.empty);XCTAssertTrue(f.endings.isEmpty);f.attempts.last?.1(true);drain();XCTAssertEqual(f.endings.first?.0,.cancelled)
    }
}
