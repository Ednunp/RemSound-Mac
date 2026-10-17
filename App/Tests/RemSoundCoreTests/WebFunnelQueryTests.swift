import XCTest
@testable import RemSoundCore

final class WebFunnelQueryTests:XCTestCase {
    typealias Q=WebFunnelQuery
    final class Child:Q.Child {var cancels=0;var onCancel:(()->Void)?;func cancel(){cancels += 1;onCancel?()}}
    final class Fixture {
        let queue=DispatchQueue(label:"test.FunnelQuery"),scope=Q.Scope(identity:UUID(),localPort:6001)
        var current=true,plans=[Q.Plan](),sinks=[Q.Sink](),children=[Child](),results=[Q.Result](),shutdowns=0
        var launchHook:((Q.Sink,Child)->Void)?,nilLaunch=false
        lazy var service=Q.Service(queue:queue,isolated:false,enabled:true,current:{[unowned self] in self.current && $0==self.scope},launch:{[unowned self] plan,sink in
            self.plans.append(plan);self.sinks.append(sink);let child=Child();self.children.append(child);self.launchHook?(sink,child);return self.nilLaunch ? nil:child
        })
        func pump(){for _ in 0..<12 {queue.sync{}}}
        @discardableResult func start()->Bool {let ok=service.request(scope){[unowned self] in self.results.append($0)};pump();return ok}
        func end(_ index:Int,_ text:String,status:Int32=0) {let sink=sinks[index];sink.stdout(Data(text.utf8));sink.stdoutClosed();sink.stderrClosed();sink.exited(status);sink.retired();pump()}
        func finish(_ index:Int) {let sink=sinks[index];sink.stdoutClosed();sink.stderrClosed();sink.exited(0);sink.retired();pump()}
        func mapping(host:String="mac.tail.ts.net")->String {"{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"\(host):443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:6001\"}}}},\"AllowFunnel\":{\"\(host):443\":true}}"}
        func node(_ name:String="mac.tail.ts.net.")->String {"{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"\(name)\"}}"}
    }
    func testDisabledAndIsolatedRefuseBeforeFactories(){
        for isolated in [false,true] {var calls=0;let q=DispatchQueue(label:"off"),scope=Q.Scope(identity:UUID(),localPort:1)
            let s=Q.Service(queue:q,isolated:isolated,current:{_ in calls += 100;return true},launch:{_,_ in calls += 1;return nil})
            XCTAssertFalse(s.request(scope){_ in XCTFail()});s.setEnabled(true)
            if isolated {XCTAssertFalse(s.request(scope){_ in XCTFail()})};q.sync{};XCTAssertEqual(calls,0)
        }
    }
    func testZeroPortRefused(){let f=Fixture();XCTAssertFalse(f.service.request(.init(identity:UUID(),localPort:0)){_ in XCTFail()});f.pump();XCTAssertTrue(f.plans.isEmpty)}
    func testStaleScopeRefusesBeforeLaunch(){let f=Fixture();f.current=false;XCTAssertTrue(f.start());XCTAssertEqual(f.results,[.failed(.cancelled)]);XCTAssertTrue(f.plans.isEmpty)}
    func testFixedPlansAndMatchingHost(){let f=Fixture();XCTAssertTrue(f.start());f.end(0,f.mapping());XCTAssertEqual(f.plans.map(\.arguments),[["funnel","status","--json"],["status","--json"]]);f.end(1,f.node());guard case .mapping(let address,true)?=f.results.first else {return XCTFail("no verified mapping")};XCTAssertEqual(address.url.absoluteString,"https://mac.tail.ts.net");XCTAssertEqual(f.plans[0].stdoutLimit,131072);XCTAssertEqual(f.plans[0].stderrLimit,8192);XCTAssertEqual(f.plans[0].timeout,10)}
    func testHostMismatchUnknown(){let f=Fixture();f.start();f.end(0,f.mapping());f.end(1,f.node("other.tail.ts.net"));XCTAssertEqual(f.results,[.unknown])}
    func testMissingDNSDoesNotInventAddress(){let f=Fixture();f.start();f.end(0,f.mapping());f.end(1,"{\"BackendState\":\"Running\"}");XCTAssertEqual(f.results,[.unknown])}
    func testNoMatchingRootNotGlobalOff(){let f=Fixture();f.start();f.end(0,"{}");f.end(1,f.node());guard case .mapping(let address,false)?=f.results.first else {return XCTFail("Missing potential node address")};XCTAssertEqual(address.url.absoluteString,"https://mac.tail.ts.net")}
    func testNodeNotReady(){let f=Fixture();f.start();f.end(0,f.mapping());f.end(1,"{\"BackendState\":\"Stopped\"}");XCTAssertEqual(f.results,[.notReady])}
    func testExitDoesNotReleasePipesOrRetirement(){let f=Fixture();f.start();let s=f.sinks[0];s.stdout(Data("{}".utf8));s.exited(0);f.pump();XCTAssertEqual(f.plans.count,1);s.stdoutClosed();s.stderrClosed();f.pump();XCTAssertEqual(f.plans.count,1);s.retired();f.pump();XCTAssertEqual(f.plans.count,2);f.end(1,f.node())}
    func testEarlyRetiredDoesNotForgeEOF(){let f=Fixture();f.start();let s=f.sinks[0];s.retired();s.exited(0);s.stdoutClosed();f.pump();XCTAssertTrue(f.results.isEmpty);XCTAssertFalse(f.service.request(f.scope){_ in XCTFail()});s.stderrClosed();f.pump();XCTAssertEqual(f.results,[.unknown])}
    func testCancellationWaitsEveryReceipt(){let f=Fixture();f.start();f.service.cancel();f.pump();XCTAssertEqual(f.children[0].cancels,1);let s=f.sinks[0];s.exited(0);s.retired();s.stdoutClosed();f.pump();XCTAssertTrue(f.results.isEmpty);s.stderrClosed();f.pump();XCTAssertEqual(f.results,[.failed(.cancelled)])}
    func testDeadlineRetainsCredit(){let f=Fixture();f.start();f.sinks[0].failed(.timedOut);f.pump();XCTAssertEqual(f.children[0].cancels,1);XCTAssertFalse(f.start());XCTAssertTrue(f.results.isEmpty);f.finish(0);XCTAssertEqual(f.results,[.failed(.timedOut)])}
    func testFirstFailureWins(){let f=Fixture();f.start();f.sinks[0].failed(.io);f.service.cancel();f.sinks[0].failed(.timedOut);f.pump();f.finish(0);XCTAssertEqual(f.results,[.failed(.io)]);XCTAssertEqual(f.children[0].cancels,1)}
    func testStdoutCapBeforeQueuedHandoff(){let f=Fixture();f.start();for _ in 0..<9 {f.sinks[0].stdout(Data(repeating:32,count:16384))};f.pump();XCTAssertEqual(f.children[0].cancels,1);XCTAssertTrue(f.results.isEmpty);f.finish(0);XCTAssertEqual(f.results,[.failed(.outputLimit)])}
    func testStderrCapHasNoRawResult(){let f=Fixture();f.start();f.sinks[0].stderr(Data(repeating:65,count:8193));f.pump();f.finish(0);XCTAssertEqual(f.results,[.failed(.outputLimit)])}
    func testChunkCapEvenIfTotalSmall(){let f=Fixture();f.start();f.sinks[0].stdout(Data(repeating:32,count:16385));f.pump();f.finish(0);XCTAssertEqual(f.results,[.failed(.outputLimit)])}
    func testNonzeroExitIsValueFreeFailure(){let f=Fixture();f.start();f.end(0,"private error text",status:7);XCTAssertEqual(f.results,[.failed(.commandFailed)]);XCTAssertEqual(f.plans.count,1)}
    func testNilFactoryNoChildPromise(){let f=Fixture();f.nilLaunch=true;f.start();XCTAssertEqual(f.results,[.failed(.unavailable)])}
    func testSynchronousCompleteBeforeFactoryReturn(){let f=Fixture();f.launchHook={s,_ in s.stdout(Data("{}".utf8));s.stdoutClosed();s.stderrClosed();s.exited(0);s.retired()};f.start();XCTAssertEqual(f.plans.count,2);XCTAssertEqual(f.results,[.unknown])}
    func testDisableDuringFactoryCancelsReturnedChild(){let f=Fixture();f.launchHook={_,_ in f.service.setEnabled(false)};f.start();XCTAssertEqual(f.children[0].cancels,1);XCTAssertTrue(f.results.isEmpty);f.finish(0);XCTAssertEqual(f.results,[.failed(.cancelled)])}
    func testReproofBetweenQueries(){let f=Fixture();f.start();f.current=false;f.end(0,f.mapping());XCTAssertEqual(f.plans.count,1);XCTAssertEqual(f.results,[.failed(.cancelled)])}
    func testShutdownWaitsRawReturnAndFirstReceipts(){let f=Fixture();f.start();XCTAssertTrue(f.service.shutdown{f.shutdowns += 1});f.pump();XCTAssertEqual(f.shutdowns,0);f.sinks[0].exited(0);f.sinks[0].retired();f.sinks[0].stderrClosed();f.pump();XCTAssertEqual(f.shutdowns,0);f.sinks[0].stdoutClosed();f.pump();XCTAssertEqual(f.shutdowns,1);XCTAssertEqual(f.results,[.failed(.cancelled)]);XCTAssertFalse(f.start())}
    func testCallbackRetainsAdmissionUntilReturn(){let f=Fixture();var inside:Bool?;XCTAssertTrue(f.service.request(f.scope){_ in inside=f.service.request(f.scope){_ in XCTFail()};XCTAssertTrue(f.service.shutdown{f.shutdowns += 1});XCTAssertEqual(f.shutdowns,0)});f.pump();f.end(0,"bad");f.pump();XCTAssertEqual(inside,false);XCTAssertEqual(f.shutdowns,1)}
    func testDuplicateLateCallbacksDoNotAffectReplacement(){let f=Fixture();f.start();f.end(0,"bad");XCTAssertEqual(f.results,[.unknown]);let old=f.sinks[0];XCTAssertTrue(f.start());old.failed(.io);old.stdout(Data("private".utf8));old.exited(7);old.retired();f.pump();XCTAssertEqual(f.children[1].cancels,0);f.end(1,"bad");XCTAssertEqual(f.results,[.unknown,.unknown])}
    func testRetiredStageLosesFactoryPermission(){let f=Fixture();f.start();let old=f.sinks[0];XCTAssertTrue(old.isPermitted);f.end(0,f.mapping());XCTAssertFalse(old.isPermitted);XCTAssertTrue(f.sinks[1].isPermitted);f.end(1,f.node());XCTAssertFalse(f.sinks[1].isPermitted)}
    func testNonzeroExitCauseSurvivesLaterCancel(){let f=Fixture();f.start();f.sinks[0].exited(4);f.service.cancel();f.finish(0);XCTAssertEqual(f.results,[.failed(.commandFailed)])}
    func testDataAfterEOFRefusesWithoutReplay(){let f=Fixture();f.start();let s=f.sinks[0];s.stdoutClosed();s.stdout(Data("{}".utf8));s.stderrClosed();s.exited(0);s.retired();f.pump();XCTAssertEqual(f.results,[.failed(.io)]);XCTAssertEqual(f.plans.count,1)}
    func testForeignCallbackOrder(){let f=Fixture();f.start();let s=f.sinks[0];let done=expectation(description:"foreign finished");DispatchQueue.global().async{s.stdout(Data("bad".utf8));s.retired();s.stderrClosed();s.exited(0);s.stdoutClosed();done.fulfill()};wait(for:[done],timeout:2);f.pump();XCTAssertEqual(f.results,[.unknown])}
    func testReleasedServiceRetiresOwnedChild(){let q=DispatchQueue(label:"released"),child=Child(),scope=Q.Scope(identity:UUID(),localPort:1);var sink:Q.Sink?,results=[Q.Result]();var service:Q.Service?=Q.Service(queue:q,isolated:false,enabled:true,current:{_ in true},launch:{_,s in sink=s;return child});weak var weakService=service
        XCTAssertTrue(service!.request(scope){results.append($0)});q.sync{};service=nil;for _ in 0..<4 {q.sync{}};XCTAssertNil(weakService);XCTAssertEqual(child.cancels,1);XCTAssertTrue(results.isEmpty);sink!.exited(0);sink!.stdoutClosed();sink!.stderrClosed();sink!.retired();for _ in 0..<8 {q.sync{}};XCTAssertEqual(results,[.failed(.cancelled)]);XCTAssertFalse(sink!.isPermitted)
    }
    func testBoundedShutdownWaiters(){let f=Fixture();f.start();for _ in 0..<16 {XCTAssertTrue(f.service.shutdown{f.shutdowns += 1})};XCTAssertFalse(f.service.shutdown{XCTFail()});f.pump();XCTAssertEqual(f.shutdowns,0);f.finish(0);XCTAssertEqual(f.shutdowns,16)}
    func testRepeatedCancellationDoesNotRepeatChildStop(){let f=Fixture();f.start();for _ in 0..<1000 {f.service.cancel();f.service.setEnabled(false)};f.pump();XCTAssertEqual(f.children[0].cancels,1);XCTAssertFalse(f.sinks[0].isPermitted);f.finish(0);XCTAssertEqual(f.results,[.failed(.cancelled)])}
    func testPermissionReenteredFromObservationBeforeFactory(){let q=DispatchQueue(label:"reproof"),scope=Q.Scope(identity:UUID(),localPort:1);var calls=0,results=[Q.Result](),service:Q.Service!;service=Q.Service(queue:q,isolated:false,enabled:true,current:{_ in service.setEnabled(false);return true},launch:{_,_ in calls += 1;return nil});XCTAssertTrue(service.request(scope){results.append($0)});for _ in 0..<8 {q.sync{}};XCTAssertEqual(calls,0);XCTAssertEqual(results,[.failed(.cancelled)])}
    func testConcurrentOverflowWakeChurn(){let f=Fixture();for visit in 0..<40 {XCTAssertTrue(f.start());let s=f.sinks[visit];let done=expectation(description:"bounded writer");DispatchQueue.global().async{for _ in 0..<16 {s.stdout(Data(repeating:32,count:16384))};done.fulfill()};wait(for:[done],timeout:2);f.pump();XCTAssertEqual(f.children[visit].cancels,1);f.finish(visit);XCTAssertEqual(f.results.last,.failed(.outputLimit))};XCTAssertEqual(f.results.count,40)}
}
