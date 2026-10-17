import AppKit
import Foundation
import RemSoundCore
import XCTest
@testable import RemSoundApp

@MainActor final class BrowserStagedConfigurationTests:XCTestCase {
    @MainActor private final class Backend:BrowserSessionBackend {
        var state:BrowserListenerStatus.State = .off,hook:(()->Void)?
        var listenerState:BrowserListenerStatus.State {hook?();return state}
        var prepares=[(Bool)->Void](),stops=[()->Void](),closes=[()->Void](),activations=[(BrowserListenerActivationResult)->Void]()
        func prepareStart(_ id:UUID,completion:@escaping(Bool)->Void)->Bool {prepares.append(completion);return true}
        func activate(_ id:UUID,binding:SessionNetworkBinding,options:BrowserListenerOptions,password:String)->Bool {XCTFail("No legacy activation");return false}
        func activate(_ id:UUID,binding:SessionNetworkBinding,options:BrowserListenerOptions,password:String,completion:@escaping(BrowserListenerActivationResult)->Void)->Bool {activations.append(completion);return true}
        func stop(completion:@escaping()->Void)->Bool {stops.append(completion);return true}
        func shutdown(completion:@escaping()->Void)->Bool {closes.append(completion);return true}
    }
    @MainActor private final class Fixture {
        let backend=Backend(),binding=SessionNetworkBinding(port:49127,generation:UUID()),worker=UUID(),account=UUID(),revision=UUID()
        var owner:BrowserSessionOwner!,ticket:BrowserSessionOwner.ConfigurationTicket?
        init() {owner=BrowserSessionOwner(backend:backend)}
        func observe() {owner.observe(running:true,binding:binding,workerGeneration:worker)}
        func stage(readOnly:Bool=false) {observe();ticket=owner.beginConfiguration(.init(account:account,revision:revision,readOnly:readOnly));XCTAssertNotNil(ticket)}
    }
    private let choice=BrowserListenerChoice(options:.init(enabled:true,autoStart:true),password:"synthetic staged")
    private func pump(_ done:()->Bool) {let end=Date().addingTimeInterval(2);while !done() && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.001))}}
    func testObservedRunningWithoutAcceptedRootCanEditButCannotMintNativeVisit() {
        let f=Fixture();f.stage();guard let ticket=f.ticket else {return}
        XCTAssertFalse(ticket.isRunning);XCTAssertEqual(ticket.account,f.account);XCTAssertNil(f.owner.currentVisitTicket);XCTAssertNil(f.owner.beginEditing())
        XCTAssertFalse(f.owner.activate(options:choice.options,password:choice.password));XCTAssertTrue(f.backend.prepares.isEmpty && f.backend.activations.isEmpty)
    }
    func testEnabledPreviewIsAsynchronouslyStagedWithoutBackendCalls() {
        let f=Fixture();f.stage();guard let ticket=f.ticket else {return};var result:BrowserSessionOwner.ConfigurationApplyResult?
        XCTAssertTrue(f.owner.apply(choice,configuration:ticket) {result=$0});XCTAssertNil(result);pump {result != nil}
        XCTAssertEqual(result,.staged);XCTAssertTrue(f.backend.prepares.isEmpty && f.backend.stops.isEmpty && f.backend.activations.isEmpty)
    }
    func testIdenticalRunningObservationsKeepTheCapturedConfiguration() {
        let f=Fixture();f.stage();guard let ticket=f.ticket else {return}
        for _ in 0..<200 {f.observe();XCTAssertTrue(f.owner.isCurrentConfiguration(ticket))}
        XCTAssertTrue(f.backend.stops.isEmpty);XCTAssertNil(f.owner.currentVisitTicket)
    }
    func testNewWorkerInvalidatesBeforeAnyFurtherUse() {
        let f=Fixture();f.stage();guard let ticket=f.ticket else {return}
        f.owner.observe(running:true,binding:f.binding,workerGeneration:UUID());XCTAssertFalse(f.owner.isCurrentConfiguration(ticket));XCTAssertEqual(f.backend.stops.count,1)
    }
    func testNewBindingGenerationInvalidatesEvenAtTheSamePort() {
        let f=Fixture();f.stage();guard let ticket=f.ticket else {return}
        f.owner.observe(running:true,binding:.init(port:f.binding.port,generation:UUID()),workerGeneration:f.worker)
        XCTAssertFalse(f.owner.isCurrentConfiguration(ticket));XCTAssertNil(f.owner.reserveConfigurationWork(ticket))
    }
    func testRunningToStoppedInvalidatesAndNeedsExplicitNewConfiguration() {
        let f=Fixture();f.stage();guard let ticket=f.ticket else {return}
        f.owner.observe(running:false,binding:nil,workerGeneration:UUID());XCTAssertFalse(f.owner.isCurrentConfiguration(ticket))
        XCTAssertNil(f.owner.beginConfiguration(.init(account:f.account,revision:f.revision,readOnly:false)))
        f.backend.stops.last?();pump {f.owner.profileContextRetired}
        XCTAssertNotNil(f.owner.beginConfiguration(.init(account:f.account,revision:f.revision,readOnly:false)))
    }
    func testMissingRunningBindingCanStageOnlyAndArrivalInvalidates() {
        let f=Fixture();f.owner.observe(running:true,binding:nil,workerGeneration:f.worker)
        guard let ticket=f.owner.beginConfiguration(.init(account:f.account,revision:f.revision,readOnly:false)) else {return XCTFail("Missing stage-only configuration")}
        XCTAssertFalse(ticket.isRunning);XCTAssertNil(f.owner.currentVisitTicket);f.observe();XCTAssertFalse(f.owner.isCurrentConfiguration(ticket))
    }
    func testPartialAcceptedPreparationCannotBeDowngradedToStaging() {
        let f=Fixture();var prepared=false;XCTAssertTrue(f.owner.beforeStart(UUID()) {prepared=$0});f.backend.prepares.last?(true)
        pump {prepared};XCTAssertTrue(prepared);f.observe();XCTAssertNil(f.owner.beginConfiguration(.init(account:f.account,revision:f.revision,readOnly:false)))
    }
    func testPendingStopCannotBeRelabelledStaging() {
        let f=Fixture();f.observe();f.owner.invalidate();XCTAssertNil(f.owner.beginConfiguration(.init(account:f.account,revision:f.revision,readOnly:false)))
        f.backend.stops.last?();pump {f.backend.stops.count==1};f.observe()
        pump {f.owner.beginConfiguration(.init(account:f.account,revision:f.revision,readOnly:false)) != nil}
        XCTAssertTrue(f.backend.activations.isEmpty)
    }
    func testOneStagePreviewBlocksReplacementAndFailsAfterStartUntilStopReceipt() {
        let f=Fixture();f.stage();guard let ticket=f.ticket else {return};var result:BrowserSessionOwner.ConfigurationApplyResult?
        XCTAssertTrue(f.owner.apply(choice,configuration:ticket) {result=$0});XCTAssertTrue(f.owner.beforeStart(UUID()) {_ in})
        XCTAssertNil(f.owner.beginConfiguration(.init(account:UUID(),revision:UUID(),readOnly:false)));XCTAssertNil(result)
        f.backend.stops.last?();pump {result != nil};XCTAssertEqual(result,.failed);XCTAssertTrue(f.backend.activations.isEmpty)
    }
    func testCompletedStagingCannotBeUpgradedByARepeatedObservation() {
        let f=Fixture();f.stage();guard let ticket=f.ticket else {return};var result:BrowserSessionOwner.ConfigurationApplyResult?
        XCTAssertTrue(f.owner.apply(choice,configuration:ticket) {result=$0});pump {result != nil};f.observe()
        XCTAssertEqual(result,.staged);XCTAssertFalse(ticket.isRunning);XCTAssertNil(f.owner.currentVisitTicket)
    }
    func testReentrantNativeStateGetterCannotIssueAReplacementContext() {
        let f=Fixture();f.observe();f.backend.hook={[weak f] in f?.backend.hook=nil;f?.owner.invalidate()}
        XCTAssertNil(f.owner.beginConfiguration(.init(account:f.account,revision:f.revision,readOnly:false)))
    }
    func testUnavailableBackendNeverConfersConfigurationOrFactoryPermission() {
        let f=Fixture();f.backend.state = .unavailable;f.observe()
        XCTAssertNil(f.owner.beginConfiguration(.init(account:f.account,revision:f.revision,readOnly:false)));XCTAssertTrue(f.backend.prepares.isEmpty)
    }
    func testForeignOwnerConfigurationIsNotReusableForStaging() {
        let f=Fixture(),other=Fixture();f.stage();guard let ticket=f.ticket else {return};other.observe()
        XCTAssertFalse(other.owner.isCurrentConfiguration(ticket));XCTAssertFalse(other.owner.apply(choice,configuration:ticket) {_ in XCTFail("Foreign callback")})
    }
    func testReentrantConfigurationRequestCannotSupersedeAnInProgressOpen() {
        let f=Fixture();f.observe();var nested:BrowserSessionOwner.ConfigurationTicket?
        f.backend.hook={[weak f] in guard let f else {return};f.backend.hook=nil;nested=f.owner.beginConfiguration(.init(account:UUID(),revision:UUID(),readOnly:false))}
        let ticket=f.owner.beginConfiguration(.init(account:f.account,revision:f.revision,readOnly:false))
        XCTAssertNotNil(ticket);XCTAssertNil(nested);if let ticket {XCTAssertTrue(f.owner.isCurrentConfiguration(ticket))}
    }
    func testActualTransactionStagesThenPersistsTheDedicatedAccountWithoutListening() throws {
        let f=Fixture();f.stage();guard let ticket=f.ticket else {return}
        let stores=ProfilePasswordStores(),store=stores.store(account:f.account.uuidString,role:.browser,isolated:true)
        try store.save("synthetic opened");var queue=[()->Void](),model:BrowserListenerEdit?,persisted:BrowserListenerOptions?,effective:BrowserListenerChoice?
        let access=BrowserCredentialAccess(owner:f.owner,configuration:ticket,storage:store,isCurrent:{true},execute:{queue.append($0)})
        let tx=BrowserProfileTransaction(owner:f.owner,ticket:ticket,access:access,options:.init(),isCurrent:{true},commitMetadata:{persisted=$0;return true})
        tx.onEffective={effective=$0};XCTAssertTrue(tx.open {model=$0});XCTAssertEqual(queue.count,1);queue.removeFirst()();pump {model != nil}
        guard let model else {return XCTFail("Missing model")};model.update(choice);model.accept();pump {!queue.isEmpty}
        XCTAssertFalse(model.finished);XCTAssertNil(persisted);XCTAssertEqual(effective,.empty)
        guard !queue.isEmpty else {return XCTFail("Missing save")};queue.removeFirst()();pump {model.finished}
        XCTAssertTrue(model.finished && tx.finished);XCTAssertEqual(persisted,choice.options);XCTAssertEqual(try store.load(),choice.password)
        XCTAssertTrue(f.backend.prepares.isEmpty && f.backend.activations.isEmpty && f.backend.stops.isEmpty)
    }
    func testReadOnlyStagingUsesTemporaryChoicesWithoutChangingTheCredential() throws {
        let f=Fixture();f.stage(readOnly:true);guard let ticket=f.ticket else {return}
        let stores=ProfilePasswordStores(),store=stores.store(account:f.account.uuidString,role:.browser,isolated:true);try store.save("synthetic unchanged")
        var queue=[()->Void](),model:BrowserListenerEdit?,persisted=false
        let access=BrowserCredentialAccess(owner:f.owner,configuration:ticket,storage:store,isCurrent:{true},execute:{queue.append($0)})
        let tx=BrowserProfileTransaction(owner:f.owner,ticket:ticket,access:access,options:.init(),isCurrent:{true},commitMetadata:{_ in persisted=true;return true})
        XCTAssertTrue(tx.open {model=$0});queue.removeFirst()();pump {model != nil};guard let model else {return XCTFail("Missing model")}
        model.update(choice);model.accept();pump {model.finished};XCTAssertTrue(persisted && model.finished);XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(try store.load(),"synthetic unchanged");XCTAssertTrue(f.backend.prepares.isEmpty && f.backend.activations.isEmpty)
    }
    func testShutdownFirstStillWaitsTheStagedRawLoadAndIndependentStop() throws {
        let f=Fixture();f.stage();guard let ticket=f.ticket else {return}
        let store=ProfilePasswordStores().store(account:f.account.uuidString,role:.browser,isolated:true)
        var queue=[()->Void](),result:BrowserCredentialAccess.Outcome?,closed=false
        let access=BrowserCredentialAccess(owner:f.owner,configuration:ticket,storage:store,isCurrent:{true},execute:{queue.append($0)})
        XCTAssertTrue(access.load {result=$0});XCTAssertTrue(f.owner.shutdown {_ in closed=true});f.backend.closes.last?()
        pump {f.backend.stops.count==1};XCTAssertFalse(closed);XCTAssertNil(result)
        queue.removeFirst()();XCTAssertNil(result);XCTAssertFalse(closed)
        f.backend.stops.last?();pump {closed};XCTAssertTrue(closed);XCTAssertEqual(result,.stale)
    }
    func testStagedRunningWindowExplainsItsModeWithoutClaimingStoppedAudio() throws {
        let edit=try XCTUnwrap(BrowserListenerEdit(opened:.empty,isCurrent:{true},apply:{_,reply in reply(true);return true}))
        let c=try XCTUnwrap(BrowserListenerWindow(edit:edit,visit:.stagedRunning,persistence:.draft,didEnd:{_,_ in},announce:{_,_ in}))
        XCTAssertTrue(c.scopeNote.stringValue.contains("staged") && c.scopeNote.stringValue.contains("audio session is running"))
        XCTAssertFalse(c.scopeNote.stringValue.contains("session is stopped"));XCTAssertFalse(c.scopeNote.isHidden)
        XCTAssertEqual(c.scopeNote.accessibilityLabel(),"Browser configuration scope");XCTAssertFalse(c.window?.isVisible == true)
        c.cancelPressed();pump {edit.finished};XCTAssertTrue(edit.finished)
    }
    func testAcceptedRootBindingAndWorkerStillUseTheNativeEditorPath() {
        let f=Fixture(),request=UUID();var prepared=false
        XCTAssertTrue(f.owner.beforeStart(request) {prepared=$0});f.backend.prepares.last?(true);pump {prepared}
        let receipt=PushToTalkWorkerReceipt(settings:.init(),running:true,generation:f.worker)
        f.owner.acknowledgeStart(request,binding:f.binding);f.owner.acknowledgeWorker(request,receipt:receipt);f.observe()
        guard let ticket=f.owner.beginConfiguration(.init(account:f.account,revision:f.revision,readOnly:false)) else {return XCTFail("Missing native editor")}
        XCTAssertTrue(ticket.isRunning);XCTAssertFalse(ticket.isStagedWhileRunning);XCTAssertNotNil(f.owner.currentVisitTicket)
        var result:BrowserSessionOwner.ConfigurationApplyResult?;XCTAssertTrue(f.owner.apply(choice,configuration:ticket) {result=$0})
        f.backend.prepares.last?(true);pump {!f.backend.activations.isEmpty};XCTAssertEqual(f.backend.activations.count,1);XCTAssertNil(result)
        f.backend.activations.last?(.listening(port:49128));pump {result != nil};XCTAssertEqual(result,.listening)
    }

}
