import Foundation
import RemSoundCore
import XCTest
@testable import RemSoundApp

@MainActor final class BrowserAudioTransitionTests:XCTestCase {
    private final class Backend:BrowserSessionBackend {
        var supportsAudioContinuity:Bool {true}
        var reportedState:BrowserListenerStatus.State = .listening
        var stateHook:(()->Void)?
        var listenerState:BrowserListenerStatus.State {let hook=stateHook;stateHook=nil;hook?();return reportedState}
        var full=[(UUID,(Bool)->Void)](),audio=[(UUID,(Bool)->Void)](),attachments=[(UUID,SessionNetworkBinding,(Bool)->Void)]()
        var stops=[()->Void](),shutdowns=[()->Void]()
        func prepareStart(_ request:UUID,completion:@escaping(Bool)->Void)->Bool {full.append((request,completion));return true}
        func prepareAudioTransition(_ request:UUID,completion:@escaping(Bool)->Void)->Bool {audio.append((request,completion));return true}
        func attachAudio(_ request:UUID,binding:SessionNetworkBinding,completion:@escaping(Bool)->Void)->Bool {attachments.append((request,binding,completion));return true}
        func activate(_ request:UUID,binding:SessionNetworkBinding,options:BrowserListenerOptions,password:String)->Bool {false}
        func activate(_ request:UUID,binding:SessionNetworkBinding,options:BrowserListenerOptions,password:String,completion:@escaping(BrowserListenerActivationResult)->Void)->Bool {false}
        func stop(completion:@escaping()->Void)->Bool {stops.append{[weak self] in self?.reportedState = .off;completion()};return true}
        func shutdown(completion:@escaping()->Void)->Bool {shutdowns.append{[weak self] in self?.reportedState = .closed;completion()};return true}
    }
    private func until(_ condition:()->Bool,file:StaticString=#filePath,line:UInt=#line) {
        let end=ProcessInfo.processInfo.systemUptime+2
        while !condition(),ProcessInfo.processInfo.systemUptime<end {RunLoop.current.run(until:Date().addingTimeInterval(0.001))}
        XCTAssertTrue(condition(),file:file,line:line)
    }
    func testAudioStartUsesScopedRetirementAndRequiresBothActualWorkerReceipts() {
        let b=Backend(),o=BrowserSessionOwner(backend:b),request=UUID();var prepared=false
        XCTAssertTrue(o.beforeAudioStart(request){prepared=$0})
        XCTAssertEqual(b.audio.count,1);XCTAssertTrue(b.full.isEmpty)
        guard let reply=b.audio.first?.1 else {return};reply(true);until{prepared}
        let binding=SessionNetworkBinding(port:49221,generation:UUID()),worker=PushToTalkWorkerReceipt(settings:.init(),running:true,generation:UUID())
        o.acknowledgeStart(request,binding:binding);o.observe(running:true,binding:binding,workerGeneration:worker.generation)
        XCTAssertTrue(b.attachments.isEmpty)
        o.acknowledgeWorker(request,receipt:worker);XCTAssertEqual(b.attachments.count,1)
        o.observe(running:true,binding:binding,workerGeneration:worker.generation);XCTAssertEqual(b.attachments.count,1)
        b.attachments.first?.2(true);until{!o.hasPendingSourceWork}
    }
    func testAudioStopWaitsScopedReceiptAndProfileLossStillUsesFullStop() {
        let b=Backend(),o=BrowserSessionOwner(backend:b);var stopped=0
        o.performAudioStop{stopped += 1}
        XCTAssertEqual(b.audio.count,1);XCTAssertTrue(b.stops.isEmpty);XCTAssertEqual(stopped,0)
        guard let reply=b.audio.first?.1 else {return};reply(true);until{stopped==1}
        o.invalidate(discardMutations:true);XCTAssertEqual(b.stops.count,1)
        b.stops.first?()
    }
    func testAudioStartJoinsOldRawSecretWorkWithoutReplacingCredentialRoom() throws {
        let b=Backend(),o=BrowserSessionOwner(backend:b),request=UUID();var prepared=false
        XCTAssertTrue(o.beforeAudioStart(request){prepared=$0});b.audio.first?.1(true);until{prepared}
        let binding=SessionNetworkBinding(port:49221,generation:UUID()),worker=PushToTalkWorkerReceipt(settings:.init(),running:true,generation:UUID())
        o.acknowledgeStart(request,binding:binding);o.observe(running:true,binding:binding,workerGeneration:worker.generation);o.acknowledgeWorker(request,receipt:worker)
        b.attachments.first?.2(true);until{!o.hasPendingSourceWork}
        let ticket=try XCTUnwrap(o.beginEditing()),work=try XCTUnwrap(o.reserveEditorWork(ticket))
        let next=UUID();var started=false,delivered=false
        XCTAssertTrue(o.beforeAudioStart(next){started=$0})
        XCTAssertFalse(o.isCurrentEditor(ticket));XCTAssertEqual(b.audio.count,2);XCTAssertTrue(b.stops.isEmpty)
        b.audio.last?.1(true);RunLoop.current.run(until:Date().addingTimeInterval(0.01))
        XCTAssertEqual(b.audio.count,2);XCTAssertFalse(started)
        XCTAssertTrue(o.completeEditorWork(work){delivered=true});until{delivered && b.audio.count==3}
        XCTAssertEqual(b.audio.last?.0,next);b.audio.last?.1(true);until{started}
    }
    func testReentrantProfileInvalidationDuringAudioStopStateReadCannotReopenContext() {
        let b=Backend(),o=BrowserSessionOwner(backend:b);var stopped=0
        o.performAudioStop{stopped += 1};b.stateHook={o.invalidate(discardMutations:true)}
        b.audio.first?.1(true);until{b.stops.count==1};XCTAssertEqual(stopped,0)
        b.stops.first?();until{o.profileContextRetired}
    }
    func testReentrantContextLossWhileRevokingAudioEditorCannotQueueNewStart() {
        let b=Backend(),o=BrowserSessionOwner(backend:b)
        o.onAudioConfigurationInvalidated={o.invalidate(discardMutations:true)}
        XCTAssertFalse(o.beforeAudioStart(UUID()){_ in XCTFail("Refused source request cannot start.")})
        XCTAssertEqual(b.stops.count,1);b.stops.first?();RunLoop.current.run(until:Date().addingTimeInterval(0.01))
        XCTAssertTrue(b.audio.isEmpty);XCTAssertTrue(o.profileContextRetired)
    }
    func testPermissionLossUsesFullRoomRetirementAndCannotAttachResumedAudio() {
        let b=Backend(),o=BrowserSessionOwner(backend:b),request=UUID();var prepared=false
        XCTAssertTrue(o.beforeAudioStart(request){prepared=$0});b.audio.first?.1(true);until{prepared}
        XCTAssertTrue(o.needsAudioResume(request));_ = o.suspendForPermission();XCTAssertEqual(b.stops.count,1)
        let binding=SessionNetworkBinding(port:49221,generation:UUID()),worker=PushToTalkWorkerReceipt(settings:.init(),running:true,generation:UUID())
        o.acknowledgeStart(request,binding:binding);o.observe(running:true,binding:binding,workerGeneration:worker.generation);o.acknowledgeWorker(request,receipt:worker)
        XCTAssertTrue(b.attachments.isEmpty);b.stops.first?()
    }
    func testPermissionLossUpgradesPendingAudioSecretRetirementAndWaitsBothMainReceipts() throws {
        let b=Backend(),o=BrowserSessionOwner(backend:b),request=UUID();var prepared=false,delivered=false
        XCTAssertTrue(o.beforeAudioStart(request){prepared=$0});b.audio.first?.1(true);until{prepared}
        let binding=SessionNetworkBinding(port:49221,generation:UUID()),worker=PushToTalkWorkerReceipt(settings:.init(),running:true,generation:UUID())
        o.acknowledgeStart(request,binding:binding);o.observe(running:true,binding:binding,workerGeneration:worker.generation);o.acknowledgeWorker(request,receipt:worker)
        b.attachments.first?.2(true);until{!o.hasPendingSourceWork}
        let ticket=try XCTUnwrap(o.beginEditing()),work=try XCTUnwrap(o.reserveEditorWork(ticket))
        XCTAssertTrue(o.beforeAudioStart(UUID()){_ in});XCTAssertEqual(b.audio.count,2)
        _ = o.suspendForPermission()
        XCTAssertEqual(b.stops.count,1,"Permission/context loss must immediately upgrade an already interrupted audio-only retirement to full Room stop.")
        guard let full=b.stops.first else {return};full();RunLoop.current.run(until:Date().addingTimeInterval(0.01))
        XCTAssertTrue(o.completeEditorWork(work){delivered=true});XCTAssertFalse(delivered,"Full Core first plus raw storage return cannot replace the old audio-main receipt.")
        b.audio[1].1(false);until{delivered}
    }
    func testContextLossImmediatelyUpgradesPendingAudioOperationWithoutOldStopAction() {
        for stopping in [false,true] {
            let b=Backend(),o=BrowserSessionOwner(backend:b);var actions=0,failures=0
            o.onFailure={failures += 1}
            if stopping {o.performAudioStop{actions += 1}} else {XCTAssertTrue(o.beforeAudioStart(UUID()){if $0 {actions += 1}})}
            XCTAssertEqual(b.audio.count,1);o.invalidate(discardMutations:true)
            for _ in 0..<100 {o.invalidate(discardMutations:true)}
            XCTAssertEqual(b.stops.count,1,"Context loss must request full Room retirement immediately, while the old audio-only callback remains pending.")
            guard let full=b.stops.first else {continue};full();RunLoop.current.run(until:Date().addingTimeInterval(0.01))
            XCTAssertTrue(o.hasPendingSourceWork);XCTAssertFalse(o.profileContextRetired)
            for _ in 0..<100 {o.invalidate(discardMutations:true)}
            XCTAssertEqual(b.stops.count,1,"A completed full receipt cannot cause repeated upgrades while the same old audio callback is pending.")
            b.audio.first?.1(false);until{b.stops.count==2};b.stops.last?();until{o.profileContextRetired}
            XCTAssertEqual(actions,0);XCTAssertEqual(failures,0,"A cancelled old audio Stop cannot block a newer fully retired context.")
        }
    }
    func testPermanentCoreReceiptCannotPassPendingAudioMainDelivery() {
        let b=Backend(),o=BrowserSessionOwner(backend:b);var started=false,closed=false
        XCTAssertTrue(o.beforeAudioStart(UUID()){started=$0})
        XCTAssertEqual(b.audio.count,1);guard let reply=b.audio.first?.1 else {return}
        XCTAssertTrue(o.shutdown{if case .success=$0 {closed=true}})
        b.shutdowns.first?();RunLoop.current.run(until:Date().addingTimeInterval(0.01))
        XCTAssertFalse(closed);XCTAssertFalse(started)
        reply(true);until{closed};XCTAssertFalse(started)
    }
}
