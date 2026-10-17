import AppKit
import Foundation
import XCTest
@testable import RemSoundCore
@testable import RemSoundApp

@MainActor final class BrowserStoppedAddressTests:XCTestCase {
    final class Backend:BrowserSessionBackend {
        var supportsStoppedListening:Bool {true}
        var listenerState:BrowserListenerStatus.State = .off
        var queries=[(BrowserListenerAddressResult)->Void](),copies=[(String?)->Void](),approvals=[(BrowserListenerFunnelResult)->Void](),stops=[()->Void](),prepares=0,cancels=0
        func prepareStart(_ request:UUID,completion:@escaping(Bool)->Void)->Bool {prepares += 1;completion(true);return true}
        func activate(_ request:UUID,binding:SessionNetworkBinding,options:BrowserListenerOptions,password:String)->Bool {XCTFail("No fabricated running binding");return false}
        func activate(_ request:UUID,binding:SessionNetworkBinding,options:BrowserListenerOptions,password:String,completion:@escaping(BrowserListenerActivationResult)->Void)->Bool {false}
        func activateStopped(_ request:UUID,options:BrowserListenerOptions,password:String,completion:@escaping(BrowserListenerActivationResult)->Void)->Bool {listenerState = .listening;completion(.listening(port:6001));return true}
        func refreshAddress(completion:@escaping(BrowserListenerAddressResult)->Void)->Bool {queries.append(completion);return true}
        func copyAddress(_ value:BrowserListenerAddress,completion:@escaping(String?)->Void)->Bool {copies.append(completion);return true}
        func turnOnPublicAccess(completion:@escaping(BrowserListenerFunnelResult)->Void)->Bool {approvals.append(completion);return true}
        func cancelAddressRefresh(){cancels += 1}
        func stop(completion:@escaping()->Void)->Bool {stops.append(completion);return true}
        func shutdown(completion:@escaping()->Void)->Bool {completion();return true}
    }
    private func pump(_ done:()->Bool){let end=Date().addingTimeInterval(2);while !done(),Date()<end{RunLoop.main.run(until:Date().addingTimeInterval(0.001))}}
    private func ready() throws -> (Backend,BrowserSessionOwner,BrowserSessionOwner.ConfigurationTicket,BrowserListenerAddressModel) {
        let backend=Backend(),owner=BrowserSessionOwner(backend:backend)
        let ticket=try XCTUnwrap(owner.beginConfiguration(.init(account:UUID(),revision:UUID(),readOnly:true)))
        var applied=false;XCTAssertTrue(owner.apply(.init(options:.init(enabled:true),password:"synthetic"),configuration:ticket){applied = $0 == .listening});pump{applied}
        XCTAssertTrue(applied);XCTAssertNil(owner.currentVisitTicket)
        return (backend,owner,ticket,BrowserListenerAddressModel(owner:owner,ticket:ticket,isCurrent:{true}))
    }
    private func configured(_ backend:Backend) {
        backend.queries.last?(.configured(.init(urlString:"https://mac.tail.ts.net",publiclyAllowed:true,visit:UUID(),receipt:UUID(),port:6001)))
    }
    func testStoppedWindowQueriesOnceCopiesFreshAndRefreshesAfterExplicitFunnel() throws {
        let (backend,owner,_,model)=try ready();_=NSApplication.shared;var copied=[String]()
        let edit=try XCTUnwrap(BrowserListenerEdit(opened:.empty,isCurrent:{true},apply:{_,reply in reply(true);return true}))
        let window=try XCTUnwrap(BrowserListenerWindow(edit:edit,visit:.stoppedListening,address:model,copyAddress:{copied.append($0);return true},didEnd:{_,_ in},announce:{_,_ in}))
        window.queryOnOpen();window.queryOnOpen();XCTAssertEqual(backend.queries.count,1);guard backend.queries.count==1 else{return}
        configured(backend);pump{!model.busy};XCTAssertTrue(window.copyAddressButton.isEnabled);XCTAssertTrue(window.turnOnButton.isEnabled)
        window.copyAddressPressed();XCTAssertTrue(copied.isEmpty);backend.copies.last?("https://mac.tail.ts.net");pump{!model.busy}
        XCTAssertEqual(copied,["https://mac.tail.ts.net"])
        window.turnOnPressed();XCTAssertEqual(backend.approvals.count,1);backend.approvals.last?(.enabled);pump{backend.queries.count==2}
        configured(backend);pump{!model.busy};XCTAssertEqual(backend.queries.count,2);XCTAssertNil(owner.currentVisitTicket)
    }
    func testStoppedListeningHealthFlagAloneCannotGrantQueryAuthority() throws {
        let backend=Backend(),owner=BrowserSessionOwner(backend:backend)
        let ticket=try XCTUnwrap(owner.beginConfiguration(.init(account:UUID(),revision:UUID(),readOnly:true)))
        backend.listenerState = .listening
        XCTAssertFalse(owner.canQueryAddress(ticket));XCTAssertTrue(backend.queries.isEmpty)
    }
    func testStoppedStartRejectsLateCopyAndRetainsWorkUntilRawAndStopReturn() throws {
        let (backend,owner,_,model)=try ready();var copied=false,prepared:Bool?
        XCTAssertTrue(model.refresh());configured(backend);pump{!model.busy}
        XCTAssertTrue(model.copy{_ in copied=true;return true});XCTAssertTrue(model.busy)
        XCTAssertTrue(owner.beforeStart(UUID()){prepared=$0});XCTAssertFalse(model.canCopy)
        backend.copies.last?("https://mac.tail.ts.net");RunLoop.main.run(until:Date().addingTimeInterval(0.01))
        XCTAssertFalse(copied);XCTAssertTrue(model.busy);XCTAssertNil(prepared)
        backend.stops.last?();pump{!model.busy};XCTAssertFalse(copied);XCTAssertTrue(model.address.isEmpty)
    }
    func testStoppedShutdownFirstStillWaitsRawQueryAndIndependentStop() throws {
        let (backend,owner,_,model)=try ready();var closed=false
        XCTAssertTrue(model.refresh());XCTAssertTrue(owner.shutdown{_ in closed=true})
        RunLoop.main.run(until:Date().addingTimeInterval(0.01));XCTAssertFalse(closed)
        configured(backend);RunLoop.main.run(until:Date().addingTimeInterval(0.01))
        XCTAssertFalse(closed);XCTAssertTrue(model.busy)
        backend.stops.last?();pump{closed};XCTAssertTrue(closed);XCTAssertFalse(model.busy);XCTAssertFalse(model.canCopy)
    }

}
