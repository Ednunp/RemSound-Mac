import Foundation
import XCTest
import RemSoundCore
@testable import RemSoundApp

@MainActor final class ProfileActionRetirementTests: XCTestCase {
    @MainActor private final class Backend: BrowserSessionBackend {
        var state:BrowserListenerStatus.State = .off, hook:(()->Void)?
        var listenerState:BrowserListenerStatus.State {hook?();return state}
        var stops=[()->Void](),prepares=[(Bool)->Void](),closes=[()->Void](),accepts=true
        func prepareStart(_ id:UUID,completion:@escaping(Bool)->Void)->Bool {prepares.append(completion);return true}
        func activate(_ id:UUID,binding:SessionNetworkBinding,options:BrowserListenerOptions,password:String)->Bool {XCTFail("No activation");return false}
        func activate(_ id:UUID,binding:SessionNetworkBinding,options:BrowserListenerOptions,password:String,completion:@escaping(BrowserListenerActivationResult)->Void)->Bool {XCTFail("No activation");return false}
        func stop(completion:@escaping()->Void)->Bool {stops.append(completion);return accepts}
        func shutdown(completion:@escaping()->Void)->Bool {closes.append(completion);return true}
    }
    private func pump(_ done:()->Bool) {let end=Date().addingTimeInterval(2);while !done() && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.001))}}
    func testAudioObservationDoesNotReopenRetiredProfileStorage() {
        let backend = Backend(), binding = SessionNetworkBinding(port: 49152, generation: UUID()), worker = UUID()
        let owner = BrowserSessionOwner(backend: backend)
        owner.observe(running: true, binding: binding, workerGeneration: worker)
        owner.invalidate(discardMutations: true)
        XCTAssertFalse(owner.profilePersistenceRetired)
        backend.stops.first?()
        pump { backend.stops.count == 1 && owner.profilePersistenceRetired }
        owner.observe(running: true, binding: binding, workerGeneration: worker)
        XCTAssertTrue(owner.profilePersistenceRetired)
        XCTAssertFalse(owner.profileContextRetired, "Audio observation must still prevent source-context renewal")
        XCTAssertFalse(owner.renewRetiredProfileContext())
        XCTAssertNil(owner.currentVisitTicket)
    }

    func testRetiredRenewalRotatesContextWithoutAnyNativeFactoryOrStop() {
        let backend=Backend()
        let exact=BrowserSessionOwner(backend:backend),scope=exact.sourceScope
        XCTAssertTrue(exact.profileContextRetired);XCTAssertTrue(exact.renewRetiredProfileContext());XCTAssertNotEqual(scope,exact.sourceScope)
        XCTAssertTrue(exact.profileContextRetired);XCTAssertTrue(backend.stops.isEmpty && backend.prepares.isEmpty && backend.closes.isEmpty)
    }
    func testDirtyContextRequiresActualStopBeforeRenewal() {
        let backend=Backend()
        let exact=BrowserSessionOwner(backend:backend);exact.invalidate();let scope=exact.sourceScope
        XCTAssertFalse(exact.renewRetiredProfileContext());XCTAssertEqual(scope,exact.sourceScope);XCTAssertEqual(backend.stops.count,1)
        backend.stops.first?();pump {exact.profileContextRetired};XCTAssertTrue(exact.renewRetiredProfileContext());XCTAssertEqual(backend.stops.count,1)
    }
    func testPendingRootPreparationCannotBeReplacedByRetiredRenewal() {
        let backend=Backend()
        let exact=BrowserSessionOwner(backend:backend);XCTAssertTrue(exact.beforeStart(UUID()) {_ in});let scope=exact.sourceScope
        XCTAssertFalse(exact.renewRetiredProfileContext());XCTAssertEqual(scope,exact.sourceScope);XCTAssertEqual(backend.prepares.count,1)
    }
    func testExistingConfigurationMustEndBeforeRenewal() {
        let backend=Backend();let owner=BrowserSessionOwner(backend:backend)
        guard let ticket=owner.beginConfiguration(.init(account:UUID(),revision:UUID(),readOnly:false)) else {return XCTFail("Missing configuration")}
        XCTAssertFalse(owner.renewRetiredProfileContext());XCTAssertTrue(owner.isCurrentConfiguration(ticket))
        owner.endConfiguration(ticket);XCTAssertTrue(owner.renewRetiredProfileContext());XCTAssertFalse(owner.isCurrentConfiguration(ticket))
    }
    func testAdmittedSecretCreditRequiresRawAndIndependentStop() {
        let backend=Backend();let owner=BrowserSessionOwner(backend:backend)
        guard let ticket=owner.beginConfiguration(.init(account:UUID(),revision:UUID(),readOnly:false)),let work=owner.reserveConfigurationWork(ticket) else {return XCTFail("Missing secret credit")}
        owner.endConfiguration(ticket);XCTAssertFalse(owner.renewRetiredProfileContext());var delivered=false
        XCTAssertTrue(owner.completeEditorWork(work) {delivered=true});XCTAssertFalse(delivered);XCTAssertFalse(owner.renewRetiredProfileContext())
        backend.stops.first?();pump {delivered};XCTAssertTrue(delivered);XCTAssertTrue(owner.renewRetiredProfileContext())
    }
    func testIssuedRemovalPurposeIsNeverRetiredRenewalAuthority() {
        let backend=Backend();let owner=BrowserSessionOwner(backend:backend);var ticket:BrowserSessionOwner.RemovalTicket?
        XCTAssertNotNil(owner.prepareRemoval(account:UUID()) {ticket=$0});pump {backend.stops.count==1};backend.stops.first?();pump {ticket != nil}
        XCTAssertFalse(owner.renewRetiredProfileContext());if let ticket {owner.endRemoval(ticket)};XCTAssertTrue(owner.renewRetiredProfileContext())
    }
    func testUnavailableStateCannotFabricateQuiescentRenewal() {
        let backend=Backend();backend.state = .unavailable;let owner=BrowserSessionOwner(backend:backend),scope=owner.sourceScope
        XCTAssertFalse(owner.renewRetiredProfileContext());XCTAssertEqual(scope,owner.sourceScope);XCTAssertTrue(backend.stops.isEmpty)
    }
    func testPermanentShutdownNeverReopensProfileAuthority() {
        let backend=Backend();let owner=BrowserSessionOwner(backend:backend);XCTAssertTrue(owner.shutdown {_ in})
        XCTAssertFalse(owner.renewRetiredProfileContext());backend.closes.first?();pump {backend.closes.count==1};XCTAssertFalse(owner.renewRetiredProfileContext())
    }
    func testRetirementRefusalRemainsFenced() {
        let backend=Backend();backend.accepts=false;let owner=BrowserSessionOwner(backend:backend);owner.invalidate();pump {!owner.profileContextRetired && backend.stops.count==1}
        RunLoop.main.run(until:Date().addingTimeInterval(0.01));XCTAssertFalse(owner.renewRetiredProfileContext());XCTAssertEqual(backend.stops.count,1)
    }
    func testReentrantClearSourceChangeCannotYieldSuccessfulRenewal() {
        let backend=Backend();let owner=BrowserSessionOwner(backend:backend);var first=true
        owner.onConfigurationInvalidated={[weak owner] in guard first else {return};first=false;owner?.suspendSource()}
        XCTAssertFalse(owner.renewRetiredProfileContext());XCTAssertFalse(first);XCTAssertFalse(owner.profileContextRetired)
    }
    func testReentrantBackendObservationCannotEraseNewRootWork() {
        let backend=Backend();let owner=BrowserSessionOwner(backend:backend);var first=true
        backend.hook={[weak owner] in guard first else {return};first=false;_ = owner?.beforeStart(UUID()) {_ in}}
        XCTAssertFalse(owner.renewRetiredProfileContext());XCTAssertFalse(first);XCTAssertEqual(backend.prepares.count,1)
        backend.hook=nil
    }
    func testBoundedRepeatedRetiredTransitionsHaveNoIdleWork() {
        let backend=Backend();let owner=BrowserSessionOwner(backend:backend);var notices=0;owner.onConfigurationInvalidated={notices += 1}
        for _ in 0..<200 {XCTAssertTrue(owner.renewRetiredProfileContext())}
        XCTAssertEqual(notices,200);XCTAssertTrue(backend.stops.isEmpty && backend.prepares.isEmpty && backend.closes.isEmpty)
    }
    func testCompletedPermanentReceiptAllowsOnlyPersistenceWithoutNativeRenewal() {
        let backend=Backend();let owner=BrowserSessionOwner(backend:backend);var closed=false
        XCTAssertTrue(owner.shutdown {_ in closed=true});XCTAssertFalse(owner.profilePersistenceRetired)
        backend.closes.first?();pump {closed};XCTAssertTrue(owner.profilePersistenceRetired)
        XCTAssertFalse(owner.profileContextRetired);XCTAssertFalse(owner.renewRetiredProfileContext())
        XCTAssertFalse(owner.beforeStart(UUID()) {_ in XCTFail("Closed owner must not start")})
    }
    func testPendingOldSecretPreventsPersistenceEvenAfterCoreShutdownReceipt() {
        let backend=Backend();let owner=BrowserSessionOwner(backend:backend)
        guard let ticket=owner.beginConfiguration(.init(account:UUID(),revision:UUID(),readOnly:false)),let work=owner.reserveConfigurationWork(ticket) else {return XCTFail("Missing work")}
        var closed=false;XCTAssertTrue(owner.shutdown {_ in closed=true});backend.closes.first?()
        RunLoop.main.run(until:Date().addingTimeInterval(0.004));XCTAssertFalse(closed);XCTAssertFalse(owner.profilePersistenceRetired)
        XCTAssertTrue(owner.completeEditorWork(work) {});backend.stops.last?();pump {closed}
        XCTAssertTrue(closed);XCTAssertTrue(owner.profilePersistenceRetired);XCTAssertFalse(owner.renewRetiredProfileContext())
    }
}
