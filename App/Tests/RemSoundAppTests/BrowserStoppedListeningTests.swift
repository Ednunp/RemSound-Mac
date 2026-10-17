import Foundation
import RemSoundCore
import XCTest
@testable import RemSoundApp

@MainActor final class BrowserStoppedListeningTests:XCTestCase {
    final class Backend:BrowserSessionBackend {
        var supportsStoppedListening:Bool {true}
        var listenerState:BrowserListenerStatus.State = .off
        var prepares=[(Bool)->Void](),stops=[()->Void](),closes=[()->Void](),activations=[(BrowserListenerActivationResult)->Void]()
        func prepareStart(_ request:UUID,completion:@escaping(Bool)->Void)->Bool {prepares.append(completion);return true}
        func activate(_ request:UUID,binding:SessionNetworkBinding,options:BrowserListenerOptions,password:String)->Bool {XCTFail("No running authority");return false}
        func activate(_ request:UUID,binding:SessionNetworkBinding,options:BrowserListenerOptions,password:String,completion:@escaping(BrowserListenerActivationResult)->Void)->Bool {XCTFail("No fabricated binding");return false}
        func activateStopped(_ request:UUID,options:BrowserListenerOptions,password:String,completion:@escaping(BrowserListenerActivationResult)->Void)->Bool {activations.append(completion);return true}
        func stop(completion:@escaping()->Void)->Bool {stops.append(completion);return true}
        func shutdown(completion:@escaping()->Void)->Bool {closes.append(completion);return true}
    }
    private func pump(_ condition:()->Bool) {
        let deadline=Date().addingTimeInterval(2)
        while !condition(),Date()<deadline {RunLoop.main.run(until:Date().addingTimeInterval(0.001))}
    }
    func testStoppedConfigurationUsesCompletedBindWithoutForgingRunningTicket() throws {
        let backend=Backend(),owner=BrowserSessionOwner(backend:backend)
        let ticket=try XCTUnwrap(owner.beginConfiguration(.init(account:UUID(),revision:UUID(),readOnly:true)))
        var result:BrowserSessionOwner.ConfigurationApplyResult?
        XCTAssertTrue(owner.apply(.init(options:.init(enabled:true),password:"synthetic"),configuration:ticket){result=$0})
        XCTAssertEqual(backend.prepares.count,1);guard let prepare=backend.prepares.last else {return}
        prepare(true);pump{!backend.activations.isEmpty};XCTAssertEqual(backend.activations.count,1);XCTAssertNil(result)
        backend.listenerState = .listening;backend.activations.last?(.listening(port:49290));pump{result != nil}
        XCTAssertEqual(result,.listening);XCTAssertNil(owner.currentVisitTicket);XCTAssertTrue(owner.isCurrentConfiguration(ticket))
    }
    func testStoppedStartInvalidatesImmediatelyButJoinsRawActivationAndIndependentStop() throws {
        let backend=Backend(),owner=BrowserSessionOwner(backend:backend)
        let ticket=try XCTUnwrap(owner.beginConfiguration(.init(account:UUID(),revision:UUID(),readOnly:false)))
        var result:BrowserSessionOwner.ConfigurationApplyResult?,prepared:Bool?
        XCTAssertTrue(owner.apply(.init(options:.init(enabled:true),password:"synthetic"),configuration:ticket){result=$0})
        backend.prepares.first?(true);pump{backend.activations.count==1}
        XCTAssertTrue(owner.beforeStart(UUID()){prepared=$0});XCTAssertFalse(owner.isCurrentConfiguration(ticket))
        backend.stops.first?();RunLoop.main.run(until:Date().addingTimeInterval(0.008));XCTAssertNil(result);XCTAssertEqual(backend.prepares.count,1)
        backend.activations.first?(.listening(port:49290));pump{result != nil}
        XCTAssertEqual(result,.failed);XCTAssertNil(prepared);XCTAssertEqual(backend.prepares.count,2)
        backend.prepares.last?(true);pump{prepared != nil};XCTAssertEqual(prepared,true)
    }
    func testStoppedReopenAndExactOffPreviewKeepSameConfigurationContext() throws {
        let backend=Backend(),owner=BrowserSessionOwner(backend:backend),identity=BrowserSessionOwner.ConfigurationIdentity(account:UUID(),revision:UUID(),readOnly:true)
        let first=try XCTUnwrap(owner.beginConfiguration(identity));var result:BrowserSessionOwner.ConfigurationApplyResult?
        XCTAssertTrue(owner.apply(.init(options:.init(enabled:true),password:"synthetic"),configuration:first){result=$0})
        backend.prepares.first?(true);pump{backend.activations.count==1};backend.listenerState = .listening
        backend.activations.first?(.listening(port:49290));pump{result != nil};XCTAssertEqual(result,.listening)
        owner.endConfiguration(first);let second=try XCTUnwrap(owner.beginConfiguration(identity));XCTAssertFalse(owner.isCurrentConfiguration(first))
        XCTAssertTrue(owner.isCurrentConfiguration(second));XCTAssertEqual(backend.prepares.count,1)
        result=nil;XCTAssertTrue(owner.apply(.empty,configuration:second){result=$0});XCTAssertNil(result)
        backend.listenerState = .off;backend.stops.last?();pump{result != nil}
        XCTAssertEqual(result,.staged);XCTAssertTrue(owner.isCurrentConfiguration(second));XCTAssertNil(owner.currentVisitTicket)
    }
    func testStoppedUnavailableReceiptStaysFailedUntilAnExplicitNewChoice() throws {
        let backend=Backend(),owner=BrowserSessionOwner(backend:backend)
        let ticket=try XCTUnwrap(owner.beginConfiguration(.init(account:UUID(),revision:UUID(),readOnly:false)))
        var result:BrowserSessionOwner.ConfigurationApplyResult?
        XCTAssertTrue(owner.apply(.init(options:.init(enabled:true),password:"synthetic"),configuration:ticket){result=$0})
        backend.prepares.first?(true);pump{backend.activations.count==1};backend.listenerState = .unavailable
        backend.activations.first?(.unavailable);pump{result != nil};XCTAssertEqual(result,.failed)
        XCTAssertTrue(owner.isCurrentConfiguration(ticket));XCTAssertEqual(backend.prepares.count,1)
        result=nil;XCTAssertTrue(owner.apply(.empty,configuration:ticket){result=$0})
        backend.listenerState = .off;backend.stops.last?();pump{result != nil};XCTAssertEqual(result,.staged)
    }

}
