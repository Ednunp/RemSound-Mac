import AppKit
import Carbon
import Foundation
import XCTest
@testable import RemSoundCore
@testable import RemSoundApp

@MainActor final class BrowserListenerAddressModelTests:XCTestCase {
    final class Backend:BrowserSessionBackend {
        var listenerState:BrowserListenerStatus.State = .off
        var prepares=[(Bool)->Void](),stops=[()->Void](),closes=[()->Void](),queries=[(BrowserListenerAddressResult)->Void](),copies=[(String?)->Void](),approvals=[(BrowserListenerFunnelResult)->Void](),openings=[(Bool)->Void](),reviews=[(BrowserListenerFunnelReviewResult)->Void](),cancels=0,cancelHook:(()->Void)?
        var accepts=true,hook:(()->Void)?
        func prepareStart(_ id:UUID,completion:@escaping(Bool)->Void)->Bool {prepares.append(completion);return true}
        func activate(_ id:UUID,binding:SessionNetworkBinding,options:BrowserListenerOptions,password:String)->Bool {false}
        func activate(_ id:UUID,binding:SessionNetworkBinding,options:BrowserListenerOptions,password:String,completion:@escaping(BrowserListenerActivationResult)->Void)->Bool {false}
        func refreshAddress(completion:@escaping(BrowserListenerAddressResult)->Void)->Bool {hook?();if accepts {queries.append(completion)};return accepts}
        func reviewPublicAccess(completion:@escaping(BrowserListenerFunnelReviewResult)->Void)->Bool {hook?();if accepts {reviews.append(completion)};return accepts}
        func turnOnPublicAccess(completion:@escaping(BrowserListenerFunnelResult)->Void)->Bool {hook?();if accepts {approvals.append(completion)};return accepts}
        func cancelAddressRefresh(){cancels += 1;cancelHook?()}
        func copyAddress(_ value:BrowserListenerAddress,completion:@escaping(String?)->Void)->Bool {if accepts {copies.append(completion)};return accepts}
        func stop(completion:@escaping()->Void)->Bool {stops.append(completion);return true}
        func shutdown(completion:@escaping()->Void)->Bool {closes.append(completion);return true}
    }
    @MainActor final class Fixture {
        let backend=Backend(),request=UUID(),binding=SessionNetworkBinding(port:49229,generation:UUID())
        var owner:BrowserSessionOwner!,ticket:BrowserSessionOwner.ConfigurationTicket!,model:BrowserListenerAddressModel!,current=true
        init(){owner=BrowserSessionOwner(backend:backend)}
        func configured(){backend.queries.last?(.configured(.init(urlString:"https://mac.tail.ts.net",publiclyAllowed:true,visit:UUID(),receipt:UUID(),port:6001)))}
    }
    private func pump(_ condition:()->Bool){let limit=Date().addingTimeInterval(2);while !condition() && Date()<limit {RunLoop.main.run(until:Date().addingTimeInterval(0.001))}}
    private func drain(){RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
    private func ready(running:Bool=true)->Fixture {
        let f=Fixture()
        if running {
            var prepared=false;XCTAssertTrue(f.owner.beforeStart(f.request){prepared=$0});f.backend.prepares.last?(true);pump{prepared};XCTAssertTrue(prepared)
            let worker=PushToTalkWorkerReceipt(settings:.init(),running:true,generation:UUID())
            f.owner.acknowledgeStart(f.request,binding:f.binding);f.owner.acknowledgeWorker(f.request,receipt:worker);f.owner.observe(running:true,binding:f.binding,workerGeneration:worker.generation)
        }
        f.ticket=f.owner.beginConfiguration(.init(account:UUID(),revision:UUID(),readOnly:false));XCTAssertNotNil(f.ticket)
        f.model=BrowserListenerAddressModel(owner:f.owner,ticket:f.ticket,isCurrent:{[weak f] in f?.current==true})
        if running {f.backend.listenerState = .listening}
        return f
    }
    func testStoppedConfigurationHasNoQueryOrGuessedAddress(){let f=ready(running:false);XCTAssertFalse(f.model.canRefresh);XCTAssertFalse(f.model.refresh());XCTAssertTrue(f.backend.queries.isEmpty);XCTAssertTrue(f.model.address.isEmpty);XCTAssertFalse(f.model.canCopy)}
    func testExplicitRefreshOnlyAndHistoricalDescription(){let f=ready();XCTAssertTrue(f.backend.queries.isEmpty);XCTAssertTrue(f.model.canRefresh);XCTAssertTrue(f.model.refresh());XCTAssertTrue(f.model.busy);f.configured();pump{!f.model.busy};XCTAssertEqual(f.model.address,"https://mac.tail.ts.net");XCTAssertTrue(f.model.canCopy);XCTAssertTrue(f.model.message.contains("configuration"));XCTAssertFalse(f.model.message.contains("reachable"))}
    func testOneSharedLedgerBlocksStoragePreviewAndReplacementDuringQuery(){let f=ready();XCTAssertTrue(f.model.refresh());XCTAssertNil(f.owner.reserveConfigurationWork(f.ticket));XCTAssertFalse(f.owner.apply(.empty,configuration:f.ticket){_ in XCTFail()});XCTAssertNil(f.owner.beginConfiguration(.init(account:UUID(),revision:UUID(),readOnly:false)));for _ in 0..<100 {XCTAssertFalse(f.model.refresh())};XCTAssertEqual(f.backend.queries.count,1);f.backend.queries.first?(.unknown);pump{!f.model.busy};XCTAssertNotNil(f.owner.reserveConfigurationWork(f.ticket))}
    func testCopyWaitsFreshCoreReceiptBeforeHook(){let f=ready();XCTAssertTrue(f.model.refresh());f.configured();pump{!f.model.busy};var copied=[String]();XCTAssertTrue(f.model.copy{copied.append($0);return true});XCTAssertTrue(copied.isEmpty);XCTAssertEqual(f.backend.copies.count,1);f.backend.copies.last?("https://mac.tail.ts.net");pump{!f.model.busy};XCTAssertEqual(copied,["https://mac.tail.ts.net"])}
    func testStaleCopyCannotReachClipboardHook(){let f=ready();_ = f.model.refresh();f.configured();pump{!f.model.busy};var copied=false;XCTAssertTrue(f.model.copy{_ in copied=true;return true});f.current=false;f.model.invalidate();XCTAssertTrue(f.model.address.isEmpty);f.backend.copies.last?("https://mac.tail.ts.net");pump{!f.model.busy};XCTAssertFalse(copied);XCTAssertFalse(f.model.canCopy)}
    func testExternalStartWaitsRawQueryAndIndependentStop(){let f=ready();XCTAssertTrue(f.model.refresh());var prepared:Bool?;XCTAssertTrue(f.owner.beforeStart(UUID()){prepared=$0});f.backend.stops.first?();drain();XCTAssertEqual(f.backend.prepares.count,1);XCTAssertNil(prepared);f.backend.queries.first?(.unknown);pump{f.backend.prepares.count==2};XCTAssertEqual(f.backend.prepares.count,2);XCTAssertTrue(f.model.address.isEmpty);f.backend.prepares.last?(true);pump{prepared != nil};XCTAssertEqual(prepared,true)}
    func testShutdownWaitsQueryReturnEvenAfterCoreShutdown(){let f=ready();XCTAssertTrue(f.model.refresh());var closed=false;XCTAssertTrue(f.owner.shutdown{_ in closed=true});f.backend.closes.first?();f.backend.stops.first?();drain();XCTAssertFalse(closed);f.backend.queries.first?(.unknown);pump{closed};XCTAssertTrue(closed)}
    func testCancelJoinsOnlyQueryBeforeEditingContinuation(){let f=ready();XCTAssertTrue(f.model.refresh());var continued=false;XCTAssertTrue(f.model.cancelThen{continued=true;XCTAssertNotNil(f.owner.reserveConfigurationWork(f.ticket))});XCTAssertEqual(f.backend.cancels,1);XCTAssertTrue(f.backend.stops.isEmpty);XCTAssertFalse(continued);f.backend.queries.first?(.cancelled);pump{continued};XCTAssertTrue(continued);XCTAssertEqual(f.backend.listenerState,.listening)}
    func testUnknownAndRefusalDoNotInventAURLOrRetry(){let f=ready();XCTAssertTrue(f.model.refresh());f.backend.queries.first?(.unknown);pump{!f.model.busy};XCTAssertEqual(f.model.address,"Not known.");XCTAssertFalse(f.model.canCopy);XCTAssertEqual(f.backend.queries.count,1);f.backend.accepts=false;XCTAssertFalse(f.model.refresh());pump{!f.model.busy};XCTAssertTrue(f.model.address.isEmpty);XCTAssertTrue(f.model.message.contains("unavailable"))}
    func testFirstForeignResultOnlyAndCallbackRetainsCredit(){let f=ready();var replies=0;XCTAssertTrue(f.owner.refreshAddress(configuration:f.ticket){_ in replies += 1;XCTAssertNil(f.owner.reserveConfigurationWork(f.ticket))});let reply=f.backend.queries.first;DispatchQueue.global().async{reply?(.unknown);reply?(.cancelled)};pump{replies>0};XCTAssertEqual(replies,1);XCTAssertNotNil(f.owner.reserveConfigurationWork(f.ticket))}
    func testReentrantBackendInvalidationCannotReturnCurrentSuccess(){let f=ready();f.backend.hook={f.owner.invalidate(discardMutations:true)};XCTAssertTrue(f.model.refresh());f.backend.queries.first?(.configured(.init(urlString:"https://mac.tail.ts.net",publiclyAllowed:true,visit:UUID(),receipt:UUID(),port:6001)));drain();XCTAssertTrue(f.model.busy);f.backend.stops.first?();pump{!f.model.busy};XCTAssertTrue(f.model.address.isEmpty);XCTAssertFalse(f.model.canCopy)}
    private func window(_ f:Fixture)throws->BrowserListenerWindow {
        _=NSApplication.shared
        let edit=try XCTUnwrap(BrowserListenerEdit(opened:.empty,isCurrent:{f.current},apply:{_,reply in reply(true);return true}))
        return try XCTUnwrap(BrowserListenerWindow(edit:edit,visit:f.ticket.isRunning ? .running:.stopped,address:f.model,copyAddress:{_ in XCTFail("No actual clipboard");return false},didEnd:{_,_ in},announce:{_,_ in}))
    }
    func testWindowAdoptsSameModelWithoutQueryOnConstruction()throws{let f=ready();let c=try window(f);XCTAssertTrue(c.addressModel === f.model);XCTAssertTrue(f.backend.queries.isEmpty);XCTAssertTrue(c.controlOrder.contains{$0 === c.turnOnButton});XCTAssertTrue(c.turnOnButton.isEnabled);c.refreshAddressPressed();XCTAssertEqual(f.backend.queries.count,1);XCTAssertFalse(c.enable.isEnabled);f.configured();pump{!f.model.busy};XCTAssertEqual(c.addressValue.stringValue,"https://mac.tail.ts.net");XCTAssertTrue(c.copyAddressButton.isEnabled);XCTAssertFalse(c.window?.isVisible == true)}
    func testAddressControlsExposeNamesHelpAndFitHiddenLayout()throws{let f=ready();let c=try window(f);let content=try XCTUnwrap(c.window?.contentView);content.layoutSubtreeIfNeeded();for control in [c.addressValue,c.addressResult,c.copyAddressButton] as [NSView] {XCTAssertFalse((control.accessibilityLabel() ?? "").isEmpty);XCTAssertFalse((control.accessibilityHelp() ?? "").isEmpty);let rect=content.convert(control.bounds,from:control);XCTAssertGreaterThan(rect.width,0);XCTAssertGreaterThan(rect.height,0);XCTAssertTrue(content.bounds.insetBy(dx:-1,dy:-1).contains(rect))};XCTAssertEqual(c.turnOnButton.cell?.accessibilityRole(),.button)}
    func testWindowCancelClearsPasswordImmediatelyButWaitsQueryRawReturn()throws{let f=ready();let c=try window(f);c.password.stringValue="synthetic";c.refreshAddressPressed();XCTAssertTrue(f.model.busy);c.cancelPressed();XCTAssertEqual(c.password.stringValue,"");XCTAssertFalse(c.edit.finished);XCTAssertTrue(f.backend.stops.isEmpty);f.backend.queries.first?(.cancelled);pump{c.edit.finished};XCTAssertTrue(c.edit.finished);XCTAssertFalse(f.model.busy)}
    func testWindowOKCannotOvertakePendingQuery()throws{let f=ready();let c=try window(f);c.refreshAddressPressed();c.acceptPressed();XCTAssertFalse(c.edit.finished);f.backend.queries.first?(.cancelled);pump{c.edit.finished};XCTAssertTrue(c.edit.finished)}
    func testWindowInvalidityClearsAddressAndPasswordBeforeOwnerEnd()throws{let f=ready();let c=try window(f);c.refreshAddressPressed();f.configured();pump{!f.model.busy};XCTAssertFalse(c.addressValue.stringValue.isEmpty);c.password.stringValue="synthetic";f.current=false;c.invalidateContext();XCTAssertTrue(c.addressValue.stringValue.isEmpty);XCTAssertEqual(c.password.stringValue,"");XCTAssertFalse(c.copyAddressButton.isEnabled)}
    func testStagedWindowHasTruthfulUnavailableAddressWithoutQuery()throws{let f=ready(running:false);let c=try window(f);XCTAssertFalse(c.turnOnButton.isEnabled);XCTAssertFalse(c.copyAddressButton.isEnabled);XCTAssertTrue(c.addressResult.stringValue.contains("staged"));c.refreshAddressPressed();XCTAssertTrue(f.backend.queries.isEmpty)}

    func testRefusedQueryDoesNotStrandTheNextEditorCredit(){let f=ready();f.backend.accepts=false;XCTAssertFalse(f.model.refresh());XCTAssertNotNil(f.owner.reserveConfigurationWork(f.ticket));XCTAssertFalse(f.model.busy)}
    func testAddressButtonsParticipateInBothTabDirectionsAfterReceipt()throws{let f=ready();let c=try window(f);c.refreshAddressPressed();f.configured();pump{!f.model.busy};for backwards in [false,true] {let order=backwards ? Array(c.controlOrder.reversed()):c.controlOrder;c.window?.makeFirstResponder(order[0]);for expected in Array(order.dropFirst())+[order[0]] {let event=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:backwards ? .shift:[],timestamp:1,windowNumber:0,context:nil,characters:"\t",charactersIgnoringModifiers:"\t",isARepeat:false,keyCode:UInt16(kVK_Tab)));c.window?.sendEvent(event);XCTAssertTrue(c.window?.firstResponder === expected || (expected as? NSTextField)?.currentEditor() === c.window?.firstResponder)}}}
    func testQueryFocusAndResultAnnouncementAreReadableWithoutPassword()throws{let f=ready();_=NSApplication.shared;let edit=try XCTUnwrap(BrowserListenerEdit(opened:.empty,isCurrent:{true},apply:{_,_ in false}));var spoken=[String]();let c=try XCTUnwrap(BrowserListenerWindow(edit:edit,address:f.model,copyAddress:{_ in false},didEnd:{_,_ in},announce:{_,text in spoken.append(text)}));c.password.stringValue="synthetic secret";c.window?.makeFirstResponder(c.password);c.refreshAddressPressed();XCTAssertTrue(c.window?.firstResponder === c.addressResult || c.addressResult.currentEditor() === c.window?.firstResponder);f.configured();pump{!f.model.busy};XCTAssertTrue(spoken.contains{$0.contains("Reported configuration")});XCTAssertFalse(spoken.contains{$0.contains("synthetic secret")})}

    func testCancelTakesPriorityOverOKWhileAddressQueryRetires()throws {
        for cancelFirst in [false,true] {
            let f=ready();_=NSApplication.shared;var end:BrowserListenerEdit.End?
            let edit=try XCTUnwrap(BrowserListenerEdit(opened:.empty,isCurrent:{true},apply:{_,reply in reply(true);return true}))
            let c=try XCTUnwrap(BrowserListenerWindow(edit:edit,address:f.model,copyAddress:{_ in false},didEnd:{result,_ in end=result},announce:{_,_ in}))
            c.refreshAddressPressed()
            if cancelFirst {c.cancelPressed();c.acceptPressed()} else {c.acceptPressed();c.cancelPressed()}
            XCTAssertNil(end);f.backend.queries.first?(.cancelled);pump{end != nil};XCTAssertEqual(end,.cancelled)
        }
    }

    func testUnavailableAfterAdmittedQueryDoesNotInventAProcessVerdict(){let f=ready();XCTAssertTrue(f.model.refresh());f.backend.queries.last?(.unavailable);pump{!f.model.busy};XCTAssertTrue(f.model.message.contains("could not be verified"));XCTAssertFalse(f.model.message.contains("No command was started"));XCTAssertFalse(f.model.message.contains("unresolved provider"));XCTAssertEqual(f.model.address,"Not known.");XCTAssertFalse(f.model.canCopy);XCTAssertEqual(f.backend.queries.count,1)}
    func testUnavailableClearsOldReceiptAndUsesTruthfulHiddenWindowAnnouncement()throws{let f=ready();_=NSApplication.shared;let edit=try XCTUnwrap(BrowserListenerEdit(opened:.empty,isCurrent:{true},apply:{_,_ in false}));var spoken=[String]();let c=try XCTUnwrap(BrowserListenerWindow(edit:edit,address:f.model,copyAddress:{_ in XCTFail("No clipboard on failure");return false},didEnd:{_,_ in},announce:{_,text in spoken.append(text)}));c.refreshAddressPressed();f.configured();pump{!f.model.busy};XCTAssertTrue(c.copyAddressButton.isEnabled);c.refreshAddressPressed();f.backend.queries.last?(.unavailable);pump{!f.model.busy};XCTAssertEqual(c.addressValue.stringValue,"Not known.");XCTAssertFalse(c.copyAddressButton.isEnabled);XCTAssertTrue(c.addressResult.stringValue.contains("could not be verified"));XCTAssertTrue(spoken.contains{$0.contains("could not be verified")});XCTAssertFalse(spoken.contains{$0.contains("No command was started")})}

    func testReviewIsExplicitAndUsesTheSameConfigurationLedger(){let f=ready();XCTAssertTrue(f.backend.reviews.isEmpty);XCTAssertTrue(f.model.reviewPublicAccess());XCTAssertTrue(f.model.busy);XCTAssertNil(f.owner.reserveConfigurationWork(f.ticket));XCTAssertFalse(f.model.refresh());XCTAssertFalse(f.model.reviewPublicAccess());XCTAssertEqual(f.backend.reviews.count,1);f.backend.reviews.first?(.empty);pump{!f.model.busy};XCTAssertTrue(f.model.message.contains("empty"));XCTAssertTrue(f.model.message.contains("No settings were changed"));XCTAssertNotNil(f.owner.reserveConfigurationWork(f.ticket))}
    func testReviewPriorSharedStateAndPartialEffectsDisclosureIsTruthful(){let f=ready();for result in [BrowserListenerFunnelReviewResult.matching(publiclyAllowed:false),.matching(publiclyAllowed:true),.conflict,.unknown,.unavailable] {XCTAssertTrue(f.model.reviewPublicAccess());f.backend.reviews.last?(result);pump{!f.model.busy};XCTAssertTrue(f.model.message.contains("No settings were changed"));XCTAssertTrue(f.model.address.isEmpty);XCTAssertFalse(f.model.canCopy)};XCTAssertTrue(f.model.reviewPublicAccess());f.backend.reviews.last?(.empty);pump{!f.model.busy};XCTAssertTrue(f.model.message.contains("persist"));XCTAssertTrue(f.model.message.contains("Cancel"));XCTAssertFalse(f.model.message.contains("will undo"))}
    func testReviewStagedOrRefusedNeverLoadsCredentialsOrStartsListener(){let stopped=ready(running:false);XCTAssertFalse(stopped.model.reviewPublicAccess());XCTAssertTrue(stopped.backend.reviews.isEmpty);let f=ready();f.backend.accepts=false;XCTAssertFalse(f.model.reviewPublicAccess());XCTAssertFalse(f.model.busy);XCTAssertNotNil(f.owner.reserveConfigurationWork(f.ticket));XCTAssertTrue(f.backend.stops.isEmpty)}
    func testReviewShutdownWaitsRawCallbackAndIndependentStop(){let f=ready();XCTAssertTrue(f.model.reviewPublicAccess());var closed=false;XCTAssertTrue(f.owner.shutdown{_ in closed=true});f.backend.closes.first?();f.backend.stops.first?();drain();XCTAssertFalse(closed);f.backend.reviews.first?(.empty);pump{closed};XCTAssertTrue(closed);XCTAssertFalse(f.model.message.contains("configuration is empty"));XCTAssertFalse(f.model.canRefresh)}
    func testReviewFirstForeignCallbackOnlyAndReentrantContextLoss(){let f=ready();f.backend.hook={f.owner.invalidate(discardMutations:true)};XCTAssertTrue(f.model.reviewPublicAccess());let reply=f.backend.reviews.first;DispatchQueue.global().async{reply?(.empty);reply?(.matching(publiclyAllowed:true))};drain();XCTAssertTrue(f.model.busy);f.backend.stops.first?();pump{!f.model.busy};XCTAssertFalse(f.model.message.contains("configuration is empty"));XCTAssertFalse(f.model.canCopy)}





    func testReviewDirectOwnerReproofAfterForeignInvalidation(){let f=ready();var result:BrowserListenerFunnelReviewResult?;XCTAssertTrue(f.owner.reviewPublicAccess(configuration:f.ticket){result=$0;XCTAssertNil(f.owner.reserveConfigurationWork(f.ticket))});f.owner.invalidate(discardMutations:true);f.backend.reviews.first?(.empty);drain();XCTAssertNil(result);f.backend.stops.first?();pump{result != nil};XCTAssertEqual(result,.cancelled)}




















    func testTurnOnUsesActualOwnerThenRefreshesAfterCompletion() {
        let f=ready();XCTAssertTrue(f.model.turnOn());XCTAssertEqual(f.backend.approvals.count,1);XCTAssertTrue(f.backend.queries.isEmpty)
        f.backend.approvals[0](.enabled);pump{f.backend.queries.count==1};f.configured();pump{!f.model.busy};XCTAssertTrue(f.model.canCopy)
    }
    func testWindowQueriesOnceOnOpenAndHasSingleNamedTurnOnControl() throws {
        let f=ready();_ = NSApplication.shared
        let edit=try XCTUnwrap(BrowserListenerEdit(opened:.empty,isCurrent:{true},apply:{_,reply in reply(true);return true}))
        let c=try XCTUnwrap(BrowserListenerWindow(edit:edit,address:f.model,didEnd:{_,_ in},announce:{_,_ in}))
        XCTAssertTrue(f.backend.queries.isEmpty);c.queryOnOpen();c.queryOnOpen();XCTAssertEqual(f.backend.queries.count,1)
        XCTAssertEqual(c.turnOnButton.title,"Turn on Tailscale Funnel");XCTAssertEqual(c.turnOnButton.accessibilityLabel(),"Turn on Tailscale Funnel")
        guard let query=f.backend.queries.first else {return};query(.notInstalled);pump{!f.model.busy};XCTAssertEqual(f.model.address,"None yet.");XCTAssertFalse(f.model.canCopy)
        c.cancelPressed()
    }
    func testTurnOnCancellationAndShutdownKeepSameRawCredit() {
        let f=ready();XCTAssertTrue(f.model.turnOn());var closed=false
        XCTAssertTrue(f.owner.shutdown{_ in closed=true});f.backend.closes.first?();f.backend.stops.first?();drain();XCTAssertFalse(closed)
        f.backend.approvals[0](.enabled);pump{closed};XCTAssertTrue(f.backend.queries.isEmpty);XCTAssertFalse(f.model.canCopy)
    }

    func testTurnOnWindowCancelPriorityClearsPasswordAndWaitsRawReturn() throws {
        let f=ready();let c=try window(f);c.password.stringValue="synthetic";c.turnOnPressed()
        XCTAssertTrue(f.model.busy);c.acceptPressed();c.cancelPressed();XCTAssertEqual(c.password.stringValue,"");XCTAssertFalse(c.edit.finished)
        f.backend.approvals.first?(.cancelled);pump{c.edit.finished};XCTAssertTrue(c.edit.finished)
    }
    func testTurnOnControlsFitWindowAndUseActualTabOrder() throws {
        let f=ready();let c=try window(f);let content=try XCTUnwrap(c.window?.contentView);content.layoutSubtreeIfNeeded()
        for view in [c.addressResult,c.turnOnButton,c.ok,c.cancel] as [NSView] {let rect=content.convert(view.bounds,from:view);XCTAssertGreaterThan(rect.height,0);XCTAssertTrue(content.bounds.insetBy(dx:-1,dy:-1).contains(rect))}
        XCTAssertTrue(c.controlOrder.contains{$0 === c.turnOnButton});XCTAssertFalse(c.copyAddressButton.isEnabled);c.refreshAddressPressed();f.configured();pump{!f.model.busy};XCTAssertTrue(c.controlOrder.contains{$0 === c.copyAddressButton})
    }

    func testPotentialAddressUsesWindowsOnceOnTextAndCannotCopy() {
        let f=ready();XCTAssertTrue(f.model.refresh())
        f.backend.queries[0](.configured(.init(urlString:"https://mac.tail.ts.net",publiclyAllowed:false,visit:UUID(),receipt:UUID(),port:6001)))
        pump{!f.model.busy};XCTAssertEqual(f.model.address,"https://mac.tail.ts.net (once Tailscale Funnel is on)");XCTAssertFalse(f.model.canCopy)
        XCTAssertFalse(f.model.copy{_ in XCTFail("No potential address clipboard");return false})
    }
}
