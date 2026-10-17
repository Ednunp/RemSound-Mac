import Foundation
import XCTest
@testable import RemSoundCore

final class BrowserListenerAddressTests:XCTestCase {
    final class Listener:WebRoom.Listener {
        var hold=false,receipt:(()->Void)?,closes=0
        func start(offer:@escaping(WebRoom.Incoming)->Bool,failed:@escaping()->Void){}
        func close(completion:@escaping()->Void){closes += 1;receipt=completion;if !hold {retire()}}
        func retire(){let reply=receipt;receipt=nil;reply?()}
    }
    final class Child:WebFunnelQuery.Child {var cancels=0;func cancel(){cancels += 1}}
    final class Fixture {
        let queue=DispatchQueue(label:"test.browser.address"),listener=Listener(),request=UUID(),binding=SessionNetworkBinding(port:49111,generation:UUID())
        var service:BrowserListenerService!,actual:SessionNetworkBinding?,bound:((UInt16)->Void)?,observeReply:((SessionNetworkBinding?)->Void)?,observations=0,hold=false
        var installationMissing=false,sourceInstalled=true,sourcePermission=true,executableApproved=true,executableInspections=0
        var now=100.0,opens=[URL](),openGate:(()->Bool)?,openReply:((Bool)->Void)?,holdOpen=false
        var providers=0,providerHook:(()->Void)?,permissionHook:(()->Void)?,inspectionHook:(()->Void)?,permissionBindings=[WebAudioHandoff.Binding](),gates=[()->Bool]()
        var children=[Child](),sinks=[WebFunnelQuery.Sink](),plans=[WebFunnelQuery.Plan](),values=[BrowserListenerAddressResult](),raw=true
        init(isolated:Bool=false,approvedExecutable:Bool=false,scoped:Bool=false){actual=binding
            let rawLaunch:WebFunnelQuery.Launch = {[unowned self] plan,sink in if installationMissing {sink.failed(.notInstalled);return nil};guard raw else {return nil};let child=Child();plans.append(plan);sinks.append(sink);children.append(child);return child}
            let approvedLaunch=WebFunnelExecutable.launch(isolated:isolated,permitted:{[unowned self] in sourceInstalled},inspect:{[unowned self] _,gate in executableInspections += 1;inspectionHook?();var value=validExecutableInspection();value.signatureValid=executableApproved;return value},factory:{_,plan,sink,gate in gate() ? rawLaunch(plan,sink):nil})
            var dependencies=WebBrowserDependencies(observe:{[unowned self] reply in observations += 1;observeReply=reply;if !hold {reply(actual)};return true},revoke:{},attach:{_,reply in reply(true);return true},page:{Data("page".utf8)},credential:{_ in WebAuthentication.Credential.make(password:"synthetic",salt:Data(repeating:0,count:16),derive:{_,_ in Data(repeating:1,count:32)})},listener:{[unowned self] _,_,reply in bound=reply;return listener},clock:{[unowned self] in now},admissionSchedule:{_ in {_,_ in {}}},peerSchedule:{_ in {_,_ in {}}},addressQuery:approvedExecutable ? approvedLaunch:rawLaunch,observeAddress:{[unowned self] _,reply in observations += 1;observeReply=reply;if !hold {reply(sourceInstalled ? actual:nil)};return true})
            if scoped {dependencies.scopedAddressQuery = {[unowned self] gate in providers += 1;gates.append(gate);providerHook?();return WebFunnelExecutable.launch(isolated:isolated,permitted:gate,inspect:{[unowned self] _,live in executableInspections += 1;XCTAssertTrue(live());inspectionHook?();var value=validExecutableInspection();value.signatureValid=executableApproved;return value},factory:{_,plan,sink,live in live() ? rawLaunch(plan,sink):nil})};dependencies.addressPermission = {[unowned self] expected in permissionBindings.append(expected);permissionHook?();return sourceInstalled && sourcePermission && actual==expected.network}}
            if !scoped {dependencies.addressPermission = {[unowned self] expected in sourceInstalled && sourcePermission && actual==expected.network}}
            dependencies.approvalOpen = {[unowned self] url,gate,reply in openGate=gate;openReply=reply;guard gate() else {return false};opens.append(url);if !holdOpen {reply(true)};return true}
            service=BrowserListenerService(queue:queue,isolated:isolated,dependencies:dependencies)}
        func pump(){for _ in 0..<48 {queue.sync{}}}
        func ready(){XCTAssertTrue(service.prepareStart(request){XCTAssertTrue($0)});pump();XCTAssertTrue(service.activate(request,binding:binding,options:.init(enabled:true),password:"synthetic"));pump();bound?(6001);pump();XCTAssertEqual(service.status.state,.listening)}
        func readyStopped(){actual=nil;XCTAssertTrue(service.prepareStart(request){XCTAssertTrue($0)});pump();XCTAssertTrue(service.activateStopped(request,options:.init(enabled:true),password:"synthetic"){XCTAssertEqual($0,.listening(port:6001))});pump();bound?(6001);pump();XCTAssertEqual(service.status.state,.listening);XCTAssertFalse(service.status.sourceAttached)}
        @discardableResult func refresh()->Bool{let ok=service.refreshAddress{[unowned self] in values.append($0)};pump();return ok}
        func finish(_ index:Int,_ text:String){guard sinks.indices.contains(index) else {XCTFail("No admitted child");return};let sink=sinks[index];sink.stdout(Data(text.utf8));sink.stdoutClosed();sink.stderrClosed();sink.exited(0);sink.retired();pump()}
        func copy(_ value:BrowserListenerAddress)->String?{var result:String?;_ = service.copyAddress(value){result=$0};pump();return result}
        func mapping()->String{"{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"mac.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:6001\"}}}},\"AllowFunnel\":{\"mac.tail.ts.net:443\":true}}"}
        func node()->String{"{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"mac.tail.ts.net.\"}}"}
        func complete(_ start:Int=0){finish(start,mapping());finish(start+1,node())}
        func cleanup(){hold=false;observeReply?(actual);listener.hold=false;listener.retire();for sink in sinks {sink.stdoutClosed();sink.stderrClosed();sink.exited(0);sink.retired()};_ = service.shutdown{};pump()}
    }
    func testOffAndIsolationRefuseBeforeObservationOrLaunch(){for isolated in [false,true] {let f=Fixture(isolated:isolated);defer{f.cleanup()};XCTAssertFalse(f.refresh());XCTAssertEqual(f.observations,0);XCTAssertTrue(f.plans.isEmpty)}}
    func testBoundAndAttachedAreRequired(){let f=Fixture();defer{f.cleanup()};XCTAssertTrue(f.service.prepareStart(f.request){_ in});f.pump();XCTAssertTrue(f.service.activate(f.request,binding:f.binding,options:.init(enabled:true),password:"synthetic"));f.pump();XCTAssertFalse(f.refresh());XCTAssertTrue(f.plans.isEmpty)}
    func testCurrentPortAndBothSessionProofsBeforeReceipt(){let f=Fixture();defer{f.cleanup()};f.ready();XCTAssertTrue(f.refresh());XCTAssertEqual(f.observations,2);f.complete();XCTAssertEqual(f.observations,3);guard case .configured(let value)?=f.values.first else {return XCTFail("No configured receipt")};XCTAssertEqual(value.urlString,"https://mac.tail.ts.net");XCTAssertTrue(value.publiclyAllowed);XCTAssertEqual(f.copy(value),value.urlString)}
    func testDefaultUnresolvedProviderIsTruthfulUnavailable(){let f=Fixture();defer{f.cleanup()};f.ready();f.raw=false;XCTAssertTrue(f.refresh());XCTAssertEqual(f.values,[.unavailable]);XCTAssertEqual(f.service.status.state,.listening)}
    func testPrequeryBindingChangeRetiresBeforeFailure(){let f=Fixture();defer{f.cleanup()};f.ready();f.actual=nil;f.listener.hold=true;XCTAssertTrue(f.refresh());XCTAssertTrue(f.values.isEmpty);XCTAssertTrue(f.plans.isEmpty);f.listener.retire();f.pump();XCTAssertEqual(f.values,[.cancelled])}
    func testPostqueryBindingChangeCannotIssueAddress(){let f=Fixture();defer{f.cleanup()};f.ready();XCTAssertTrue(f.refresh());f.actual=SessionNetworkBinding(port:f.binding.port,generation:UUID());f.listener.hold=true;f.complete();XCTAssertTrue(f.values.isEmpty);f.listener.retire();f.pump();XCTAssertEqual(f.values,[.cancelled])}
    func testStopWaitsPendingObservationAndRoomIndependently(){let f=Fixture();defer{f.cleanup()};f.ready();f.hold=true;f.listener.hold=true;XCTAssertTrue(f.refresh());var stopped=false;XCTAssertTrue(f.service.stop{stopped=true});f.pump();f.listener.retire();f.pump();XCTAssertFalse(stopped);XCTAssertTrue(f.values.isEmpty);f.observeReply?(f.binding);f.pump();XCTAssertTrue(stopped);XCTAssertEqual(f.values,[.cancelled]);XCTAssertTrue(f.plans.isEmpty)}
    func testStopWaitsActualQueryReceipts(){let f=Fixture();defer{f.cleanup()};f.ready();XCTAssertTrue(f.refresh());f.listener.hold=true;var stopped=false;XCTAssertTrue(f.service.stop{stopped=true});f.pump();XCTAssertEqual(f.children.first?.cancels,1);f.listener.retire();f.pump();XCTAssertFalse(stopped);f.finish(0,"{}");XCTAssertTrue(stopped);XCTAssertEqual(f.values,[.cancelled])}
    func testCancelOnlyQueryPreservesListening(){let f=Fixture();defer{f.cleanup()};f.ready();XCTAssertTrue(f.refresh());f.service.cancelAddressRefresh();f.pump();XCTAssertEqual(f.children.first?.cancels,1);XCTAssertTrue(f.values.isEmpty);f.finish(0,"{}");XCTAssertEqual(f.values,[.cancelled]);XCTAssertEqual(f.listener.closes,0);XCTAssertEqual(f.service.status.state,.listening)}
    func testOneCreditAndNoCallbackOnRefusal(){let f=Fixture();defer{f.cleanup()};f.ready();XCTAssertTrue(f.refresh());for _ in 0..<1000 {XCTAssertFalse(f.service.refreshAddress{_ in XCTFail("Refused callback")})};XCTAssertEqual(f.observations,2);f.complete();XCTAssertEqual(f.values.count,1)}
    func testNewRefreshAndStopInvalidateHistoricalCopyReceipt(){let f=Fixture();defer{f.cleanup()};f.ready();XCTAssertTrue(f.refresh());f.complete();guard case .configured(let old)?=f.values.first else {return XCTFail("No receipt")};XCTAssertNotNil(f.copy(old));XCTAssertTrue(f.refresh());XCTAssertNil(f.copy(old));f.service.cancelAddressRefresh();f.finish(2,"{}");_ = f.service.stop{};f.pump();XCTAssertNil(f.copy(old))}
    func testForeignServiceCannotResolveReceipt(){let f=Fixture(),other=Fixture();defer{f.cleanup();other.cleanup()};f.ready();other.ready();XCTAssertTrue(f.refresh());f.complete();guard case .configured(let value)?=f.values.first else {return XCTFail("No receipt")};XCTAssertNil(other.copy(value))}
    func testResultCallbackRetainsCreditThroughRawReturn(){let f=Fixture();defer{f.cleanup()};f.ready();var inside:Bool?;XCTAssertTrue(f.service.refreshAddress{_ in inside=f.service.refreshAddress{_ in XCTFail()};var closed=false;XCTAssertTrue(f.service.shutdown{closed=true});XCTAssertFalse(closed)});f.pump();f.complete();f.pump();XCTAssertEqual(inside,false)}
    func testUnknownIsNotUninstalledOrGlobalOff(){let f=Fixture();defer{f.cleanup()};f.ready();XCTAssertTrue(f.refresh());f.finish(0,"bad");XCTAssertEqual(f.values,[.unknown]);XCTAssertEqual(f.service.status.state,.listening)}
    func testCopyReobservesSourceAndWaitsFullRetirementOnLoss(){let f=Fixture();defer{f.cleanup()};f.ready();_ = f.refresh();f.complete();guard case .configured(let token)?=f.values.first else {return XCTFail("No receipt")};f.actual=nil;f.listener.hold=true;var returned=false,value:String?;XCTAssertTrue(f.service.copyAddress(token){value=$0;returned=true});f.pump();XCTAssertFalse(returned);f.listener.retire();f.pump();XCTAssertTrue(returned);XCTAssertNil(value);XCTAssertEqual(f.service.status.state,.unavailable)}
    func testCopyObservationRetainsCreditUntilRawAndRoomClose(){let f=Fixture();defer{f.cleanup()};f.ready();_ = f.refresh();f.complete();guard case .configured(let token)?=f.values.first else {return XCTFail("No receipt")};f.hold=true;var copied=false,closed=false;XCTAssertTrue(f.service.copyAddress(token){_ in copied=true});f.pump();XCTAssertTrue(f.service.shutdown{closed=true});f.pump();XCTAssertFalse(copied);XCTAssertFalse(closed);f.observeReply?(f.binding);f.pump();XCTAssertTrue(copied);XCTAssertTrue(closed)}

    func testSameSocketWithoutInstalledSourceCannotQuery(){let f=Fixture();defer{f.cleanup()};f.ready();f.sourceInstalled=false;f.listener.hold=true;XCTAssertTrue(f.refresh());XCTAssertTrue(f.values.isEmpty);XCTAssertTrue(f.plans.isEmpty);f.listener.retire();f.pump();XCTAssertEqual(f.values,[.cancelled])}

    func testActualScopedCoreQueryUsesApprovedExecutableContract(){let f=Fixture(approvedExecutable:true);defer{f.cleanup()};XCTAssertFalse(f.refresh());XCTAssertEqual(f.executableInspections,0);f.ready();XCTAssertTrue(f.refresh());f.complete();guard case .configured(let value)?=f.values.first else {return XCTFail("No address")};XCTAssertEqual(value.urlString,"https://mac.tail.ts.net");XCTAssertEqual(f.executableInspections,4);XCTAssertEqual(f.plans.count,2)}
    func testActualScopedCoreRefusesInvalidExecutableWithoutProcessFallback(){let f=Fixture(approvedExecutable:true);defer{f.cleanup()};f.ready();f.executableApproved=false;XCTAssertTrue(f.refresh());XCTAssertEqual(f.values,[.unavailable]);XCTAssertEqual(f.executableInspections,1);XCTAssertTrue(f.plans.isEmpty);XCTAssertEqual(f.service.status.state,.listening)}

    func testReviewOffAndIsolatedNeverObserveOrLaunch(){for isolated in [false,true] {let f=Fixture(isolated:isolated);defer{f.cleanup()};XCTAssertFalse(f.service.reviewPublicAccess{_ in XCTFail("Refused review callback")});f.pump();XCTAssertEqual(f.observations,0);XCTAssertTrue(f.plans.isEmpty)}}
    func testReviewUsesActualPortAndTwoWorkerProofsWithReadOnlyPlans(){let f=Fixture(scoped:true);defer{f.cleanup()};f.ready();var result:BrowserListenerFunnelReviewResult?;XCTAssertTrue(f.service.reviewPublicAccess{result=$0});f.pump();f.finish(0,"{}");f.finish(1,f.node());XCTAssertEqual(result,.empty);XCTAssertEqual(f.observations,3);XCTAssertEqual(f.executableInspections,4);XCTAssertEqual(f.plans.map(\.arguments),[["funnel","status","--json"],["status","--json"]]);XCTAssertEqual(f.service.status.state,.listening)}
    func testReviewMatchingPrivateAndPublicDoesNotClaimOwnership(){for allowed in [false,true] {let f=Fixture();defer{f.cleanup()};f.ready();var result:BrowserListenerFunnelReviewResult?;XCTAssertTrue(f.service.reviewPublicAccess{result=$0});f.pump();f.finish(0,f.mapping().replacingOccurrences(of:"\"mac.tail.ts.net:443\":true",with:"\"mac.tail.ts.net:443\":\(allowed ? "true":"false")"));f.finish(1,f.node());XCTAssertEqual(result,.matching(publiclyAllowed:allowed));XCTAssertEqual(f.plans.count,2)}}
    func testReviewConflictAndUnknownCannotBeEmptyOrAnAddress(){for text in ["bad","{\"Services\":{\"other\":{}}}"] {let f=Fixture();defer{f.cleanup()};f.ready();var result:BrowserListenerFunnelReviewResult?;XCTAssertTrue(f.service.reviewPublicAccess{result=$0});f.pump();f.finish(0,text);f.finish(1,f.node());XCTAssertEqual(result,text=="bad" ? .unknown:.conflict);XCTAssertTrue(f.values.isEmpty)}}
    func testReviewPostQuerySourceLossWaitsFullRoomRetirement(){let f=Fixture();defer{f.cleanup()};f.ready();var result:BrowserListenerFunnelReviewResult?;XCTAssertTrue(f.service.reviewPublicAccess{result=$0});f.pump();f.actual=nil;f.listener.hold=true;f.finish(0,"{}");f.finish(1,f.node());XCTAssertNil(result);f.listener.retire();f.pump();XCTAssertEqual(result,.cancelled);XCTAssertEqual(f.service.status.state,.unavailable)}
    func testReviewCancelWaitsRawReturnPreservingListener(){let f=Fixture();defer{f.cleanup()};f.ready();var result:BrowserListenerFunnelReviewResult?,closed=false;XCTAssertTrue(f.service.reviewPublicAccess{result=$0});f.pump();XCTAssertFalse(f.refresh());f.service.cancelAddressRefresh();f.pump();let sink=f.sinks.first;XCTAssertNotNil(sink);sink?.stdoutClosed();sink?.stderrClosed();sink?.exited(0);f.pump();XCTAssertNil(result);XCTAssertEqual(f.listener.closes,0);sink?.retired();f.pump();XCTAssertEqual(result,.cancelled);XCTAssertEqual(f.service.status.state,.listening);XCTAssertTrue(f.service.shutdown{closed=true});f.pump();XCTAssertTrue(closed)}
    func testReviewShutdownJoinsRawAndIndependentRoomReceipts(){let f=Fixture();defer{f.cleanup()};f.ready();var result:BrowserListenerFunnelReviewResult?,closed=false;XCTAssertTrue(f.service.reviewPublicAccess{result=$0});f.pump();f.listener.hold=true;XCTAssertTrue(f.service.shutdown{closed=true});f.pump();f.finish(0,"{}");XCTAssertNil(result);XCTAssertFalse(closed);f.listener.retire();f.pump();XCTAssertEqual(result,.cancelled);XCTAssertTrue(closed)}
    func testReviewInvalidatesCopyAndRetainsCreditDuringResult(){let f=Fixture();defer{f.cleanup()};f.ready();XCTAssertTrue(f.refresh());f.complete();guard case .configured(let token)?=f.values.first else {return XCTFail("No address")};var result:BrowserListenerFunnelReviewResult?;XCTAssertTrue(f.service.reviewPublicAccess{result=$0;XCTAssertFalse(f.service.refreshAddress{_ in XCTFail("No reentrant callback")})});f.pump();XCTAssertNil(f.copy(token));f.finish(2,"{}");f.finish(3,f.node());XCTAssertEqual(result,.empty);XCTAssertNil(f.copy(token))}














    func testTurnOnActualFacadeUsesOnlyFixedCommandAndStreamsApproval() {
        let f=Fixture(scoped:true);defer{f.cleanup()};f.ready();var result:BrowserListenerFunnelResult?
        XCTAssertTrue(f.service.turnOnPublicAccess{result=$0});f.pump()
        XCTAssertEqual(f.plans.map(\.arguments),[["funnel","--bg","6001"]])
        f.sinks[0].stderr(Data("https://login.tailscale.com/f/serve?node=synthetic\n".utf8));f.pump();XCTAssertEqual(f.opens.count,1);XCTAssertNil(result)
        f.finish(0,"");XCTAssertEqual(result,.enabled);XCTAssertEqual(f.service.status.state,.listening)
    }
    func testTurnOnShutdownWaitsPrintedBrowserCallbackAndRoomIndependently() {
        let f=Fixture();defer{f.openReply?(false);f.cleanup()};f.ready();f.holdOpen=true;var result:BrowserListenerFunnelResult?,closed=false
        XCTAssertTrue(f.service.turnOnPublicAccess{result=$0});f.pump()
        f.sinks[0].stdout(Data("https://login.tailscale.com/f/serve\n".utf8));f.pump();f.listener.hold=true
        XCTAssertTrue(f.service.shutdown{closed=true});f.finish(0,"");f.listener.retire();f.pump();XCTAssertFalse(closed);XCTAssertNil(result)
        f.openReply?(true);f.openReply?(false);f.pump();XCTAssertTrue(closed);XCTAssertEqual(result,.cancelled)
    }

    func testMissingAppQueryIsTruthfulAndOnlyTurnOnHandsOffFixedDownload() {
        let f=Fixture();defer{f.cleanup()};f.ready();f.installationMissing=true
        XCTAssertTrue(f.refresh());XCTAssertEqual(f.values,[.notInstalled]);XCTAssertTrue(f.opens.isEmpty);XCTAssertTrue(f.children.isEmpty)
        var result:BrowserListenerFunnelResult?;XCTAssertTrue(f.service.turnOnPublicAccess{result=$0});f.pump()
        XCTAssertEqual(f.opens,[WebFunnelStatus.downloadPage]);XCTAssertEqual(result,.downloadOpened);XCTAssertTrue(f.children.isEmpty)
    }
    func testMissingAppDownloadRawReturnStillJoinsShutdown() {
        let f=Fixture();defer{f.openReply?(false);f.cleanup()};f.ready();f.installationMissing=true;f.holdOpen=true
        var result:BrowserListenerFunnelResult?,closed=false
        XCTAssertTrue(f.service.turnOnPublicAccess{result=$0});f.pump();XCTAssertEqual(f.opens,[WebFunnelStatus.downloadPage])
        XCTAssertTrue(f.service.shutdown{closed=true});f.pump();XCTAssertNil(result);XCTAssertFalse(closed);XCTAssertFalse(f.openGate?() ?? true)
        f.openReply?(true);f.pump();XCTAssertEqual(result,.cancelled);XCTAssertTrue(closed)
    }
    func testOffMappingIsPotentialAddressButCannotBeCopied() {
        let f=Fixture();defer{f.cleanup()};f.ready();XCTAssertTrue(f.refresh());f.finish(0,f.mapping().replacingOccurrences(of:"\"mac.tail.ts.net:443\":true",with:"\"mac.tail.ts.net:443\":false"));f.finish(1,f.node())
        guard case .configured(let token)?=f.values.first else {return XCTFail("Missing actual potential-address receipt")}
        XCTAssertFalse(token.publiclyAllowed)
        XCTAssertFalse(f.service.copyAddress(token){_ in XCTFail("No copy of potential address")})
    }
    func testStoppedBoundListenerUsesScopedReadOnlyQueryAndCurrentCopyWithoutAudioBinding() {
        let f=Fixture(scoped:true);defer{f.cleanup()};f.readyStopped()
        let accepted=f.refresh();XCTAssertTrue(accepted,"A real stopped listener must not need a fabricated audio worker to query its address.");guard accepted else {return}
        f.complete();guard case .configured(let token)?=f.values.first else {return XCTFail("No stopped receipt")}
        XCTAssertEqual(token.urlString,"https://mac.tail.ts.net");XCTAssertEqual(f.copy(token),token.urlString)
        XCTAssertTrue(f.permissionBindings.isEmpty);XCTAssertEqual(f.executableInspections,4)
        XCTAssertEqual(f.plans.map(\.arguments),[["funnel","status","--json"],["status","--json"]]);XCTAssertFalse(f.service.status.sourceAttached)
    }
    func testStoppedExplicitFunnelUsesFixedPortAndBoundedApprovalHook() {
        let f=Fixture(scoped:true);defer{f.cleanup()};f.readyStopped();var result:BrowserListenerFunnelResult?
        let accepted=f.service.turnOnPublicAccess{result=$0};XCTAssertTrue(accepted);guard accepted else {return};f.pump()
        XCTAssertEqual(f.plans.map(\.arguments),[["funnel","--bg","6001"]]);guard let sink=f.sinks.first else {return XCTFail("No fixed stopped command")}
        sink.stderr(Data("https://login.tailscale.com/f/serve?node=synthetic\n".utf8));f.pump()
        XCTAssertEqual(f.opens.count,1);XCTAssertEqual(f.openGate?(),true);XCTAssertTrue(f.permissionBindings.isEmpty)
        f.finish(0,"");XCTAssertEqual(result,.enabled);XCTAssertEqual(f.service.status.state,.listening);XCTAssertFalse(f.service.status.sourceAttached)
    }

    func testStoppedPrequeryRunningObservationRetiresBeforeAnyCommand() {
        let f=Fixture(scoped:true);defer{f.cleanup()};f.readyStopped();f.actual=f.binding;f.listener.hold=true
        XCTAssertTrue(f.refresh());XCTAssertTrue(f.plans.isEmpty);XCTAssertTrue(f.values.isEmpty)
        f.listener.retire();f.pump();XCTAssertEqual(f.values,[.cancelled]);XCTAssertEqual(f.service.status.state,.unavailable)
    }
    func testStoppedNativeScopeNeverBorrowsAnUnrelatedAudioSourcePermission() {
        let f=Fixture(scoped:true);defer{f.cleanup()};f.readyStopped();f.sourceInstalled=false;f.sourcePermission=false
        XCTAssertTrue(f.refresh());f.complete();guard case .configured(let value)?=f.values.first else {return XCTFail("Missing independent listener address")}
        XCTAssertEqual(f.copy(value),value.urlString);XCTAssertTrue(f.permissionBindings.isEmpty);XCTAssertFalse(f.service.status.sourceAttached)
    }
    func testStoppedCopyWaitsRawNilObservationAndIndependentRoomRetirement() {
        let f=Fixture();defer{f.cleanup()};f.readyStopped();XCTAssertTrue(f.refresh());f.complete()
        guard case .configured(let value)?=f.values.first else {return XCTFail("Missing receipt")}
        f.hold=true;f.listener.hold=true;var returned=false,closed=false,text:String?
        XCTAssertTrue(f.service.copyAddress(value){text=$0;returned=true});f.pump();XCTAssertFalse(returned)
        XCTAssertTrue(f.service.shutdown{closed=true});f.pump();f.listener.retire();f.pump();XCTAssertFalse(closed);XCTAssertFalse(returned)
        f.observeReply?(nil);f.pump();XCTAssertTrue(returned);XCTAssertNil(text);XCTAssertTrue(closed)
    }
    func testStoppedPostqueryModeChangeCannotProduceACopyableReceipt() {
        let f=Fixture();defer{f.cleanup()};f.readyStopped();XCTAssertTrue(f.refresh());f.actual=f.binding;f.listener.hold=true
        f.complete();XCTAssertTrue(f.values.isEmpty);f.listener.retire();f.pump();XCTAssertEqual(f.values,[.cancelled])
        XCTAssertEqual(f.service.status.state,.unavailable)
    }
    func testStoppedApprovalShutdownJoinsChildBrowserRawAndRoomReceipts() {
        let f=Fixture(scoped:true);defer{f.cleanup()};f.readyStopped();f.holdOpen=true;var result:BrowserListenerFunnelResult?,closed=false
        XCTAssertTrue(f.service.turnOnPublicAccess{result=$0});f.pump();guard let sink=f.sinks.first else {return XCTFail("No stopped command")}
        sink.stderr(Data("https://login.tailscale.com/f/serve?node=synthetic\n".utf8));f.pump();XCTAssertEqual(f.opens.count,1)
        f.listener.hold=true;XCTAssertTrue(f.service.shutdown{closed=true});f.pump();XCTAssertEqual(f.openGate?(),false)
        f.finish(0,"");f.listener.retire();f.pump();XCTAssertNil(result);XCTAssertFalse(closed)
        f.openReply?(false);f.pump();XCTAssertEqual(result,.cancelled);XCTAssertTrue(closed)
    }

    func testRunningSourcePermissionRefusesBeforeExecutableInspectionDespiteSameSocket() {
        let f=Fixture(scoped:true);defer{f.cleanup()};f.ready();f.sourcePermission=false
        XCTAssertTrue(f.refresh());XCTAssertEqual(f.values,[.unavailable]);XCTAssertEqual(f.executableInspections,0);XCTAssertTrue(f.plans.isEmpty)
    }
    func testRunningSourcePermissionIsReprovedAfterOfflineInspectionBeforeProcessFactory() {
        let f=Fixture(scoped:true);defer{f.cleanup()};f.ready();f.inspectionHook={f.sourcePermission=false}
        XCTAssertTrue(f.refresh());XCTAssertEqual(f.values,[.unavailable]);XCTAssertEqual(f.executableInspections,1);XCTAssertTrue(f.plans.isEmpty)
    }

}
