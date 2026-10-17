import Foundation
import XCTest
import RemSoundCore
@testable import RemSoundApp

@MainActor final class BrowserRootRemovalTests: XCTestCase {
    @MainActor private final class Backend: BrowserSessionBackend {
        var listenerState: BrowserListenerStatus.State = .off
        var stops=[()->Void](), closes=[()->Void](), accepts=true
        func prepareStart(_ id:UUID,completion:@escaping(Bool)->Void)->Bool {XCTFail("No native preparation");return false}
        func activate(_ id:UUID,binding:SessionNetworkBinding,options:BrowserListenerOptions,password:String)->Bool {XCTFail("No native activation");return false}
        func activate(_ id:UUID,binding:SessionNetworkBinding,options:BrowserListenerOptions,password:String,completion:@escaping(BrowserListenerActivationResult)->Void)->Bool {XCTFail("No native activation");return false}
        func stop(completion:@escaping()->Void)->Bool {stops.append(completion);return accepts}
        func shutdown(completion:@escaping()->Void)->Bool {closes.append(completion);return true}
    }
    private final class Storage: BrowserCredentialStorage {
        enum Fault:Error {case injected}
        var value:String?="synthetic",deletes=0,fail=false,hook:(()->Void)?
        func load(maximumUTF8Bytes:Int)throws->String? {XCTFail("No credential read");return value}
        func save(_ value:String)throws {XCTFail("No credential write")}
        func delete()throws {deletes += 1;value=nil;hook?();if fail {throw Fault.injected}}
    }
    @MainActor private final class Fixture {
        let backend=Backend(),account=UUID(),browser=Storage(),audio=Storage()
        lazy var owner=BrowserSessionOwner(backend:backend)
        var current=true,allowSeal=true,allowClose=true,allowAccess=true,inlineClose=false
        var modelReply:(()->Void)?,queue=[@Sendable()->Void](),results=[BrowserProfileRemoval.Outcome]()
        var files=0,fileFails=false,fileHook:(()->Void)?,sealCalls=0
        lazy var removal=BrowserProfileRemoval(owner:owner,account:account,closeEditor:{[weak self] reply in
            guard let self else {return false};modelReply=reply;if inlineClose {reply();reply()};return allowClose
        },seal:{[weak self] in
            guard let self else {return nil};sealCalls += 1;guard allowSeal else {return nil};return {[weak self] in self?.current==true}
        },access:{[weak self] ticket,current in
            guard let self,allowAccess else {return nil}
            return BrowserCredentialAccess(owner:owner,removal:ticket,browser:browser,audio:audio,isCurrent:current,execute:{[weak self] in self?.queue.append($0)})
        },removeFile:{[weak self] in
            guard let self else {return};files += 1;fileHook?();if fileFails {throw Storage.Fault.injected}
        })
        func begin()->Bool {removal.start {[weak self] in self?.results.append($0)}}
        func model() {modelReply?()}
        func run() {guard !queue.isEmpty else {return XCTFail("Missing store work")};queue.removeFirst()()}
    }
    private func pump(_ done:()->Bool) {let end=Date().addingTimeInterval(2);while !done() && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.001))}}
    private func drain() {RunLoop.main.run(until:Date().addingTimeInterval(0.004))}
    private func ready()->Fixture {
        let f=Fixture();XCTAssertTrue(f.begin());f.model();pump {f.backend.stops.count==1}
        f.backend.stops.first?();pump {!f.queue.isEmpty || !f.results.isEmpty};return f
    }
    func testFileRemovalWaitsModelCoreRawAndMainReceipts() {
        let f=ready();guard !f.queue.isEmpty else {return XCTFail("No admitted deletion")}
        XCTAssertEqual(f.files,0);f.run();XCTAssertEqual(f.files,0);pump {!f.results.isEmpty}
        XCTAssertEqual(f.results,[.removed]);XCTAssertEqual(f.files,1);XCTAssertEqual(f.browser.deletes,1);XCTAssertEqual(f.audio.deletes,1)
    }
    func testModelReceiptCannotReplaceCoreReceipt() {
        let f=Fixture();XCTAssertTrue(f.begin());f.model();drain();XCTAssertTrue(f.queue.isEmpty);XCTAssertTrue(f.results.isEmpty)
        f.backend.stops.first?();pump {!f.queue.isEmpty};XCTAssertEqual(f.queue.count,1)
    }
    func testCoreReceiptCannotReplaceModelReceipt() {
        let f=Fixture();XCTAssertTrue(f.begin());pump {f.backend.stops.count==1};f.backend.stops.first?();drain()
        XCTAssertTrue(f.queue.isEmpty);XCTAssertTrue(f.results.isEmpty);f.model();pump {!f.queue.isEmpty};XCTAssertEqual(f.queue.count,1)
    }
    func testCancellationBeforePreparedWaitsBothReceiptsAndDeletesNothing() {
        let f=Fixture();XCTAssertTrue(f.begin());f.removal.cancel();f.model();pump {f.backend.stops.count==1};XCTAssertTrue(f.results.isEmpty)
        f.backend.stops.first?();pump {!f.results.isEmpty};XCTAssertEqual(f.results,[.cancelled]);XCTAssertEqual(f.files+f.browser.deletes+f.audio.deletes,0)
    }
    func testQueuedDeleteRevocationWaitsRawAndIndependentStop() {
        let f=ready();guard !f.queue.isEmpty else {return XCTFail("No work")};f.removal.cancel();f.run();drain();XCTAssertTrue(f.results.isEmpty)
        f.backend.stops.last?();pump {!f.results.isEmpty};XCTAssertEqual(f.results,[.cancelled]);XCTAssertEqual(f.files+f.browser.deletes+f.audio.deletes,0)
    }
    func testRawResultDoesNotDeleteFileAfterContextLoss() {
        let f=ready();guard !f.queue.isEmpty else {return XCTFail("No work")};f.run();f.current=false;pump {!f.results.isEmpty}
        XCTAssertEqual(f.results,[.cancelled]);XCTAssertEqual(f.files,0);XCTAssertNil(f.browser.value);XCTAssertNil(f.audio.value)
    }
    func testRootReproofAfterLowerSuccessAndBeforeFileStep() {
        let f=ready();guard !f.queue.isEmpty else {return XCTFail("No work")};f.run()
        // Lower delivery is already queued. Its success queues the separate file
        // step after this explicit Root identity change on the same main owner.
        DispatchQueue.main.async {f.current=false}
        pump {!f.results.isEmpty};XCTAssertEqual(f.results,[.cancelled]);XCTAssertEqual(f.files,0)
        XCTAssertEqual(f.browser.deletes+f.audio.deletes,2)
    }
    func testBrowserFailureLeavesFileAndAudioWithoutRollbackPromise() {
        let f=ready();guard !f.queue.isEmpty else {return XCTFail("No work")};f.browser.fail=true;f.run();pump {!f.results.isEmpty}
        XCTAssertEqual(f.results,[.failed]);XCTAssertEqual(f.files,0);XCTAssertEqual(f.audio.deletes,0);XCTAssertNil(f.browser.value)
    }
    func testAudioFailureLeavesProfileFileAfterBrowserEffects() {
        let f=ready();guard !f.queue.isEmpty else {return XCTFail("No work")};f.audio.fail=true;f.run();pump {!f.results.isEmpty}
        XCTAssertEqual(f.results,[.failed]);XCTAssertEqual(f.files,0);XCTAssertNil(f.browser.value)
    }
    func testProfileFailureDoesNotRepeatOrRestoreDeletedCredentials() {
        let f=ready();guard !f.queue.isEmpty else {return XCTFail("No work")};f.fileFails=true;f.run();pump {!f.results.isEmpty}
        XCTAssertEqual(f.results,[.failed]);XCTAssertEqual(f.files,1);XCTAssertEqual(f.browser.deletes+f.audio.deletes,2);XCTAssertFalse(f.begin())
    }
    func testCloseWaitsOwnedDeleteEvenIfCoreShutdownArrivesFirst() {
        let f=ready();guard !f.queue.isEmpty else {return XCTFail("No work")};var ended=false,core=false
        XCTAssertTrue(f.removal.close {_ in ended=true});XCTAssertTrue(f.owner.shutdown {_ in core=true});f.backend.closes.first?();drain()
        XCTAssertFalse(core);XCTAssertFalse(ended);f.run();drain();XCTAssertFalse(ended);XCTAssertFalse(core)
        f.backend.stops.last?();pump {ended && core};XCTAssertTrue(ended);XCTAssertTrue(core);XCTAssertEqual(f.files,0)
    }
    func testOneOperationAndBoundedCloseWaiters() {
        let f=Fixture();XCTAssertTrue(f.begin());XCTAssertFalse(f.begin());var replies=0
        for _ in 0..<16 {XCTAssertTrue(f.removal.close {_ in replies += 1})};XCTAssertFalse(f.removal.close {_ in XCTFail("Overflow waiter")})
        f.model();pump {f.backend.stops.count==1};f.backend.stops.first?();pump {replies==16};XCTAssertEqual(replies,16)
    }
    func testRejectedRootSealCannotDispatchStorage() {
        let f=Fixture();f.allowSeal=false;XCTAssertTrue(f.begin());f.model();pump {f.backend.stops.count==1};f.backend.stops.first?();pump {!f.results.isEmpty}
        XCTAssertEqual(f.results,[.cancelled]);XCTAssertTrue(f.queue.isEmpty);XCTAssertEqual(f.files,0)
    }
    func testRefusedModelCloseNeverDeletesFileOrCredentials() {
        let f=Fixture();f.allowClose=false;XCTAssertTrue(f.begin());pump {f.backend.stops.count==1};f.backend.stops.first?();pump {!f.results.isEmpty}
        XCTAssertEqual(f.results,[.failed]);XCTAssertEqual(f.files+f.browser.deletes+f.audio.deletes,0)
    }
    func testRefusedCorePreparationCannotInventRemovalReceipt() {
        let f=Fixture();f.backend.accepts=false;XCTAssertTrue(f.begin());f.model();pump {!f.results.isEmpty}
        XCTAssertEqual(f.results,[.failed]);XCTAssertTrue(f.queue.isEmpty);XCTAssertEqual(f.files,0)
    }
    func testFactoryRefusalNeverTouchesStoresOrFile() {
        let f=Fixture();f.allowAccess=false;XCTAssertTrue(f.begin());f.model();pump {f.backend.stops.count==1};f.backend.stops.first?();pump {!f.results.isEmpty}
        XCTAssertEqual(f.results,[.failed]);XCTAssertEqual(f.files+f.browser.deletes+f.audio.deletes,0)
    }
    func testDuplicateModelAndRawCallbacksCannotReplayDeletion() {
        let f=ready();guard !f.queue.isEmpty else {return XCTFail("No work")};let work=f.queue[0];f.model();f.model();work();work();pump {!f.results.isEmpty};drain()
        XCTAssertEqual(f.results,[.removed]);XCTAssertEqual(f.files,1);XCTAssertEqual(f.browser.deletes+f.audio.deletes,2)
    }
    func testInlineModelCallbackDoesNotRunFileBeforeStartReturns() {
        let f=Fixture();f.inlineClose=true;XCTAssertTrue(f.begin());XCTAssertTrue(f.results.isEmpty);XCTAssertEqual(f.files,0)
        pump {f.backend.stops.count==1};f.backend.stops.first?();pump {!f.queue.isEmpty};XCTAssertEqual(f.queue.count,1)
    }
    func testCancellationBetweenStoresNeverStartsAudioOrFile() {
        let f=ready();guard !f.queue.isEmpty else {return XCTFail("No work")};f.browser.hook={[weak f] in f?.removal.cancel()};f.run();f.backend.stops.last?();pump {!f.results.isEmpty}
        XCTAssertEqual(f.results,[.cancelled]);XCTAssertEqual(f.audio.deletes+f.files,0)
    }
    func testReentrantFileContextChangeSuppressesObsoleteSuccess() {
        let f=ready();guard !f.queue.isEmpty else {return XCTFail("No work")};f.fileHook={[weak f] in f?.current=false};f.run();pump {!f.results.isEmpty}
        XCTAssertEqual(f.results,[.cancelled]);XCTAssertEqual(f.files,1)
    }
    func testFinishedOperationHasNoAutomaticRetryOrSecretReload() {
        let f=ready();guard !f.queue.isEmpty else {return XCTFail("No work")};f.run();pump {!f.results.isEmpty};var reply:BrowserProfileRemoval.Outcome?
        XCTAssertTrue(f.removal.close {reply=$0});XCTAssertEqual(reply,.removed);XCTAssertTrue(f.removal.finished);XCTAssertFalse(f.begin());XCTAssertEqual(f.files,1)
    }
    func testRefusedStartOwnsNoCloseCallbackOrCleanupClaim() {
        let f=Fixture();XCTAssertNotNil(f.owner.prepareRemoval(account:UUID()) {_ in})
        XCTAssertFalse(f.begin());XCTAssertFalse(f.removal.close {_ in XCTFail("Refused operation owns no callback")})
        XCTAssertTrue(f.results.isEmpty);XCTAssertEqual(f.files,0)
    }
    func testRetiredProfileObservationNeverInventsPendingCoreOrSecretQuiescence() {
        let f=Fixture();XCTAssertTrue(f.owner.profileContextRetired)
        f.owner.invalidate();XCTAssertFalse(f.owner.profileContextRetired)
        f.backend.stops.first?();pump {f.owner.profileContextRetired};XCTAssertTrue(f.owner.profileContextRetired)
        XCTAssertTrue(f.begin());XCTAssertFalse(f.owner.profileContextRetired);f.model();pump {f.backend.stops.count==2}
        f.backend.stops.last?();pump {!f.queue.isEmpty};XCTAssertFalse(f.owner.profileContextRetired)
        f.removal.cancel();f.run();f.backend.stops.last?();pump {!f.results.isEmpty};XCTAssertTrue(f.owner.profileContextRetired)
    }
    func testRefusedInlineModelReceiptCannotGrantFileRemoval() {
        let f=Fixture();f.inlineClose=true;f.allowClose=false;XCTAssertTrue(f.begin())
        pump {f.backend.stops.count==1};f.backend.stops.first?();pump {!f.results.isEmpty}
        XCTAssertEqual(f.results,[.failed]);XCTAssertTrue(f.queue.isEmpty);XCTAssertEqual(f.files,0)
    }
    func testForeignModelReceiptMarshalsOnceToMainBeforeStorageAdmission() {
        let f=Fixture();XCTAssertTrue(f.begin());pump {f.backend.stops.count==1};f.backend.stops.first?();drain()
        let reply=f.modelReply;let sent=expectation(description:"Foreign model callback")
        DispatchQueue.global().async {reply?();reply?();sent.fulfill()}
        wait(for:[sent],timeout:2);pump {!f.queue.isEmpty};XCTAssertEqual(f.queue.count,1)
        f.run();pump {!f.results.isEmpty};XCTAssertEqual(f.results,[.removed]);XCTAssertEqual(f.files,1)
    }
    func testCloseRefusalCannotReleaseAnAdmittedSecretCredit() {
        let f=ready();guard !f.queue.isEmpty else {return XCTFail("No work")}
        var ended=0;for _ in 0..<16 {XCTAssertTrue(f.removal.close {_ in ended += 1})}
        XCTAssertFalse(f.removal.close {_ in XCTFail("Overflow")});f.backend.stops.last?();drain();XCTAssertEqual(ended,0)
        f.run();pump {ended==16};XCTAssertEqual(ended,16);XCTAssertEqual(f.files,0)
    }

}
