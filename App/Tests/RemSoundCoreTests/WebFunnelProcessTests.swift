import XCTest
@testable import RemSoundCore

final class WebFunnelProcessTests:XCTestCase {
    typealias P=WebFunnelProcess;typealias Q=WebFunnelQuery
    final class Resource:P.Resource {
        let lock=NSRecursiveLock()
        var out:[P.Read]=[.output(Data("bad".utf8)),.end],err:[P.Read]=[.end]
        var status:P.Exit = .exited(0),terminal=true,reaped=true,outClose=true,errClose=true,signals=[P.Signal](),closes=[P.Stream](),reaps=0,pauses=0
        var hook:((String)->Void)?,signalsSucceed=true,started=true,setupFailed=false
        var admissions=0,admitResult=true,admitHook:(()->Void)?,gateHook:((()->Bool)->Void)?
        func admit(_ permitted:()->Bool)->Bool {admissions += 1;admitHook?();gateHook?(permitted);return admitResult && permitted()}
        func read(_ stream:P.Stream,remaining:Int)->P.Read {lock.lock();defer{lock.unlock()};hook?(stream == .output ? "output":"error");if stream == .output {return out.isEmpty ? .pending:out.removeFirst()};return err.isEmpty ? .pending:err.removeFirst()}
        func exit()->P.Exit {lock.lock();defer{lock.unlock()};hook?("exit");return status}
        func groupTerminal()->Bool {lock.lock();defer{lock.unlock()};return terminal}
        func signal(_ signal:P.Signal)->Bool {lock.lock();defer{lock.unlock()};signals.append(signal);hook?(signal == .kill ? "kill":"term");return signalsSucceed}
        func close(_ stream:P.Stream)->Bool {lock.lock();defer{lock.unlock()};closes.append(stream);return stream == .output ? outClose:errClose}
        func reap()->Bool {lock.lock();defer{lock.unlock()};reaps += 1;return reaped}
        func pause(){lock.lock();pauses += 1;hook?("pause");lock.unlock();Thread.sleep(forTimeInterval:0.001)}
    }
    final class Fixture {
        let q=DispatchQueue(label:"test.Funnel.process"),scope=Q.Scope(identity:UUID(),localPort:6001),resource=Resource()
        var now:Double=0,step:Double=0.1,enabled=true,isolated=false,paths=0,spawns=0,onPath:(()->Void)?,onSpawn:(()->Void)?,path=URL(fileURLWithPath:"/owned/test-cli"),spawnNil=false
        var plans=[Q.Plan](),results=[Q.Result]();var completion:(()->Void)?
        lazy var service=Q.Service(queue:q,isolated:false,enabled:true,current:{_ in true},launch:P.launch(isolated:isolated,permitted:{[unowned self] in self.enabled},executable:{[unowned self] in self.paths += 1;self.onPath?();return self.path},dependencies:.init(clock:{[unowned self] in let v=self.now;self.now += self.step;return v},spawn:{[unowned self] _,plan,gate in self.spawns += 1;self.plans.append(plan);self.onSpawn?();return self.spawnNil ? nil:self.resource})))
        func run(){let done=XCTestExpectation(description:"query retired");completion={done.fulfill()};XCTAssertTrue(service.request(scope){[unowned self] in self.results.append($0);self.completion?()});XCTWaiter().wait(for:[done],timeout:2).requireCompleted()}
    }
    func testDefaultOffBeforeExecutable(){let f=Fixture();f.enabled=false;f.run();XCTAssertEqual(f.paths,0);XCTAssertEqual(f.spawns,0);XCTAssertEqual(f.results,[.failed(.unavailable)])}
    func testIsolationBeforeExecutable(){let f=Fixture();f.isolated=true;f.run();XCTAssertEqual(f.paths,0);XCTAssertEqual(f.spawns,0)}
    func testExecutableCallbackRevocationBeforeSpawn(){let f=Fixture();f.onPath={f.enabled=false};f.run();XCTAssertEqual(f.spawns,0)}
    func testFixedPlanWithoutShell(){let f=Fixture();f.run();XCTAssertEqual(f.spawns,1);XCTAssertEqual(f.plans.first?.arguments,["funnel","status","--json"]);XCTAssertEqual(f.results,[.unknown])}
    func testNonFileURLRefusesBeforeSpawn(){let f=Fixture();f.path=URL(string:"https://untrusted.invalid/tool")!;f.run();XCTAssertEqual(f.spawns,0)}
    func testNormalExitNeedsBothCloseAndReap(){let f=Fixture();f.run();XCTAssertEqual(f.resource.closes.count,2);XCTAssertEqual(f.resource.reaps,1);XCTAssertEqual(f.results,[.unknown])}
    func testExitBeforePipeEOFStillDrains(){let f=Fixture();f.resource.out=[.pending,.output(Data("bad".utf8)),.end];f.run();XCTAssertGreaterThan(f.resource.pauses,0);XCTAssertEqual(f.results,[.unknown])}
    func testNonzeroExitHasValueFreeFailure(){let f=Fixture();f.resource.status = .exited(7);f.run();XCTAssertEqual(f.results,[.failed(.commandFailed)])}
    func testNativeStdoutCapBeforeSink(){let f=Fixture();f.resource.out=Array(repeating:.output(Data(repeating:32,count:16384)),count:9)+[.end];f.step=0.01;f.run();XCTAssertEqual(f.results,[.failed(.outputLimit)]);XCTAssertEqual(f.resource.reaps,1)}
    func testStderrCapDiscarded(){let f=Fixture();f.resource.err=[.discarded(8193),.end];f.run();XCTAssertEqual(f.results,[.failed(.outputLimit)])}
    func testReadErrorClosesActualResource(){let f=Fixture();f.resource.out=[.failure];f.run();XCTAssertEqual(f.results,[.failed(.io)]);XCTAssertEqual(f.resource.closes.count,2)}
    func testReaderLimitCategorical(){let f=Fixture();f.resource.out=[.limit,.end];f.run();XCTAssertEqual(f.results,[.failed(.outputLimit)])}
    func testSilentDeadlineThenGraceEscalation(){let f=Fixture();f.step=1;f.resource.status = .running;f.resource.out=[];f.resource.err=[];f.resource.terminal=false;f.resource.hook={kind in if kind=="kill" {f.resource.status = .exited(137);f.resource.terminal=true;f.resource.out=[.end];f.resource.err=[.end]}};f.run();XCTAssertEqual(f.results,[.failed(.timedOut)]);XCTAssertTrue(f.resource.signals.contains(.terminate));XCTAssertTrue(f.resource.signals.contains(.kill));XCTAssertLessThanOrEqual(f.now,14)}
    func testRevokeAtSpawnReturnRetiresActualChild(){let f=Fixture();f.onSpawn={f.enabled=false};f.run();XCTAssertEqual(f.results,[.failed(.cancelled)]);XCTAssertEqual(f.resource.reaps,1);XCTAssertEqual(f.resource.signals.first,.terminate)}
    func testBadClockStopsWithoutFakeExit(){let f=Fixture();f.step = .infinity;f.run();XCTAssertEqual(f.results,[.failed(.io)]);XCTAssertEqual(f.resource.reaps,1)}
    func testReapRefusalRetainsUntilActualReceipt(){let f=Fixture();f.resource.reaped=false;f.resource.hook={kind in if kind=="pause",f.resource.pauses==3 {f.resource.reaped=true}};f.run();XCTAssertGreaterThanOrEqual(f.resource.pauses,3);XCTAssertEqual(f.results,[.unknown])}
    func testGroupQuiescenceBeforeReap(){let f=Fixture();f.resource.terminal=false;f.resource.hook={kind in if kind=="kill" {f.resource.terminal=true}};f.run();XCTAssertEqual(f.resource.reaps,1);XCTAssertTrue(f.resource.signals.contains(.kill));XCTAssertNotEqual(f.results,[.unknown])}
    func testLateWorkerPermissionRefusesSpawn(){let f=Fixture();f.resource.hook={_ in};f.onPath={f.service.cancel()};f.run();XCTAssertEqual(f.spawns,0);XCTAssertEqual(f.results,[.failed(.cancelled)])}
    func testNegativeClockRefusesBeforeSpawnAsIOFailure(){let f=Fixture();f.now = -1;f.run();XCTAssertEqual(f.spawns,0);XCTAssertEqual(f.results,[.failed(.io)])}
    func testCloseRefusalRetainsUntilActualCloseReceipt(){let f=Fixture();f.resource.outClose=false;f.resource.hook={kind in if kind=="pause",f.resource.pauses==3 {f.resource.outClose=true}};f.run();XCTAssertEqual(f.results,[.failed(.io)]);XCTAssertGreaterThanOrEqual(f.resource.pauses,3);XCTAssertEqual(f.resource.reaps,1)}
    func testFailedSignalsNeverSubstituteForExit(){let f=Fixture();f.onSpawn={f.enabled=false};f.resource.signalsSucceed=false;f.resource.status = .running;f.resource.terminal=false;f.resource.out=[];f.resource.err=[];f.resource.hook={kind in if kind=="pause",f.resource.pauses==8 {f.resource.status = .exited(0);f.resource.terminal=true;f.resource.out=[.end];f.resource.err=[.end]}};f.run();XCTAssertGreaterThanOrEqual(f.resource.pauses,8);XCTAssertEqual(f.resource.reaps,1);XCTAssertEqual(f.results,[.failed(.cancelled)])}
    func testUnknownExitRetainsUntilActualReceipt(){let f=Fixture();f.resource.status = .unknown;f.resource.hook={kind in if kind=="pause",f.resource.pauses==3 {f.resource.status = .exited(0)}};f.run();XCTAssertGreaterThanOrEqual(f.resource.pauses,3);XCTAssertEqual(f.resource.reaps,1);XCTAssertEqual(f.results,[.failed(.io)])}
    func testSpawnFailureRetiresOnlyNoChildWork(){let f=Fixture();f.spawnNil=true;f.run();XCTAssertEqual(f.results,[.failed(.unavailable)]);XCTAssertEqual(f.resource.reaps,0);XCTAssertTrue(f.resource.closes.isEmpty)}
    func testDecoratedExecutableURLRefusesBeforeSpawn(){let f=Fixture();f.path=URL(string:"file://user@localhost/owned/test-cli")!;f.run();XCTAssertEqual(f.spawns,0);XCTAssertEqual(f.results,[.failed(.unavailable)])}
    func testFailedPreSpawnSetupRetainsRawCreditUntilIndependentCleanup(){let f=Fixture();f.resource.started=false;f.resource.status = .exited(-1);f.resource.out=[.end];f.resource.err=[.end];f.resource.outClose=false;f.resource.terminal=false;f.resource.hook={kind in if kind=="pause",f.resource.pauses==3 {XCTAssertTrue(f.results.isEmpty);XCTAssertEqual(f.resource.reaps,0);f.resource.outClose=true;f.resource.terminal=true}};f.run();XCTAssertEqual(f.results,[.failed(.unavailable)]);XCTAssertGreaterThanOrEqual(f.resource.pauses,3);XCTAssertEqual(f.resource.reaps,1)}
    func testChildSetupFailureIsIOEvenWhenChildWouldOtherwiseSucceed(){let f=Fixture();f.resource.setupFailed=true;f.run();XCTAssertEqual(f.results,[.failed(.io)]);XCTAssertEqual(f.resource.signals.first,.terminate);XCTAssertEqual(f.resource.reaps,1)}

}
private extension XCTWaiter.Result {func requireCompleted(file:StaticString=#filePath,line:UInt=#line){XCTAssertEqual(self,.completed,file:file,line:line)}}
