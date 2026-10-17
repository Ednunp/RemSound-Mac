import Foundation
import XCTest
@testable import RemSoundCore
final class WebConnectionTests:XCTestCase {
    private final class Pipe:WebConnection.Transport {
        var readReply:((WebConnection.Read)->Void)?,writeReply:((Int?)->Void)?,closeReply:(()->Void)?
        var readCount=0,closeCount=0,maximums=[Int](),writes=[Data](),trace=[String]()
        var holdClose=false,holdWrite=false
        var readHook:(()->Void)?,writeHook:(()->Void)?
        func read(maximum:Int,completion:@escaping (WebConnection.Read)->Void) {readCount += 1;maximums.append(maximum);readReply=completion;readHook?();trace.append("read-return")}
        func write(_ bytes:Data,completion:@escaping (Int?)->Void) {writes.append(bytes);writeReply=completion;writeHook?();if !holdWrite {completion(bytes.count)};trace.append("write-return")}
        func close(completion:@escaping ()->Void) {closeCount += 1;closeReply=completion;if !holdClose {retire()};trace.append("close-return")}
        func retire() {readReply=nil;writeReply=nil;let reply=closeReply;closeReply=nil;reply?()}
        func supply(_ result:WebConnection.Read) {let callback=readReply;readReply=nil;callback?(result)}
    }
    private final class Fixture {
        let queue=DispatchQueue(label:"test.web.connection"),key=DispatchSpecificKey<Int>()
        let pipe=Pipe(),failures=WebAuthentication.Failures()
        let credential=WebAuthentication.Credential.make(password:"synthetic",salt:Data(repeating:0,count:16),derive:{_,_ in Data(repeating:1,count:32)})!
        var current:WebAuthentication.Credential?,now=100.0,enabled=true,proof=true
        var admissionCount=0,factoryCount=0,scheduleCount=0,stopCount=0,completions=[WebConnection.Result]()
        var pulse:(()->Void)?,factoryHook:((@escaping ()->Bool)->Void)?,scheduleHook:(()->Void)?
        var returnTransport=true,returnSchedule=true,control:WebConnection.Control?
        init() {current=credential;queue.setSpecific(key:key,value:1)}
        func on(_ body:()->Void) {queue.sync(execute:body)}
        func drain() {for _ in 0..<24 {queue.sync {}}}
        func start() {
            on {control=WebConnection.start(queue:queue,permitted:{[weak self] in self?.allowed ?? false},admission:{[weak self] in
                guard let self else {return nil};self.admissionCount += 1
                return WebAdmission.Visit.make(credential:self.credential,failures:self.failures,page:Data("fixed".utf8),policy:.init(hosts:["example.test:47840"],origins:["https://example.test"]),permitted:{[weak self] in self?.allowed ?? false},current:{[weak self] in self?.current},clock:{[weak self] in self?.now ?? .nan},random:{Data(repeating:2,count:$0)},verify:{[weak self] _,_ in self?.proof ?? false})
            },transport:{[weak self] gate in guard let self else {return nil};self.factoryCount += 1;self.factoryHook?(gate);return self.returnTransport ? self.pipe:nil},schedule:{[weak self] _,pulse in
                guard let self else {return nil};self.scheduleCount += 1;self.pulse=pulse;self.scheduleHook?();return self.returnSchedule ? {[weak self] in self?.stopCount += 1;self?.pulse=nil}:nil
            },completion:{[weak self] result in guard let self else {return};XCTAssertEqual(DispatchQueue.getSpecific(key:self.key),1);self.pipe.trace.append("complete");self.completions.append(result)})}
            drain()
        }
        var allowed:Bool {enabled && current === credential}
        var closed:WebAdmission.Reason? {for result in completions {if case let .closed(reason)=result {return reason}};return nil}
        var failed:WebConnection.Failure? {for result in completions {if case let .failed(reason)=result {return reason}};return nil}
        var ready:WebConnection.Ready? {for result in completions {if case let .ready(value)=result {return value}};return nil}
        func cleanup() {on {factoryHook=nil;scheduleHook=nil;pipe.readHook=nil;pipe.writeHook=nil;_ = control?.cancel();_ = ready?.close();completions.removeAll();pipe.holdClose=false;pipe.retire();control=nil};drain();on {pipe.retire()};drain()}
    }
    private func head(page:Bool=false)->Data {
        if page {return Data("GET / HTTP/1.1\r\nHost: example.test:47840\r\n\r\n".utf8)}
        return Data("GET /listen HTTP/1.1\r\nHost: example.test:47840\r\nOrigin: https://example.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n".utf8)
    }
    private func answer()->Data {
        let body=Data("{\"response\":\"\(Data(repeating:1,count:32).base64EncodedString())\"}".utf8)
        return Data([0x81,0x80|UInt8(body.count),0,0,0,0])+body
    }
    private func upgrade(_ f:Fixture) {f.on {f.pipe.supply(.bytes(head()))};f.drain()}
    func testActualAdmissionChainTransfersOwnedReadyAndRemainder() {
        let f=Fixture();defer {f.cleanup()};f.start();upgrade(f)
        let tail=Data([0x89,0x80,1,2,3,4]);f.on {f.pipe.supply(.bytes(answer()+tail))};f.drain()
        f.on {XCTAssertEqual(f.completions.count,1);XCTAssertEqual(f.ready?.codec,.opus);XCTAssertEqual(f.pipe.closeCount,0);XCTAssertEqual(f.stopCount,1);XCTAssertFalse(f.control?.cancel() ?? true)}
        var retained:Data?
        f.on {XCTAssertTrue(f.ready?.read(maximum:tail.count) {if case .bytes(let data)=$0 {retained=data}} ?? false)};f.drain();f.on {XCTAssertEqual(retained,tail)}
    }
    func testOffRefusesBeforeAdmissionTransportOrSchedule() {
        let f=Fixture();defer {f.cleanup()};f.enabled=false;f.start();f.on {XCTAssertEqual(f.admissionCount,0);XCTAssertEqual(f.factoryCount,0);XCTAssertEqual(f.scheduleCount,0);XCTAssertEqual(f.closed,.permission)}
    }
    func testCancellationBeforeQueuedStartConstructsNothing() {
        let f=Fixture();defer {f.cleanup()}
        f.queue.suspend();let control=WebConnection.start(queue:f.queue,permitted:{true},admission:{XCTFail("Admission after prestart cancel");return nil},transport:{_ in XCTFail("Transport after prestart cancel");return nil},schedule:{_,_ in XCTFail("Schedule after prestart cancel");return nil},completion:{result in f.completions.append(result)})
        XCTAssertTrue(control.cancel());f.queue.resume();f.drain();f.on {XCTAssertEqual(f.closed,.cancelled)}
    }
    func testCancelDuringFactoryRetiresLateReturnedResourceBeforeCompletion() {
        let f=Fixture();defer {f.cleanup()};f.pipe.holdClose=true;f.factoryHook={gate in XCTAssertTrue(gate());XCTAssertTrue(f.control?.cancel() ?? false);XCTAssertFalse(gate())};f.start()
        f.on {XCTAssertEqual(f.pipe.closeCount,1);XCTAssertTrue(f.completions.isEmpty);XCTAssertEqual(f.scheduleCount,0);f.pipe.retire()};f.drain();f.on {XCTAssertEqual(f.closed,.cancelled)}
    }
    func testPermissionLostDuringFactoryNeverStartsIOOrTimer() {
        let f=Fixture();defer {f.cleanup()};f.factoryHook={gate in f.enabled=false;XCTAssertFalse(gate())};f.start()
        f.on {XCTAssertEqual(f.pipe.readCount,0);XCTAssertEqual(f.scheduleCount,0);XCTAssertEqual(f.pipe.closeCount,1);XCTAssertEqual(f.closed,.permission)}
    }
    func testDeadlineStopsDriverButWaitsActualCloseReceipt() {
        let f=Fixture();defer {f.cleanup()};f.pipe.holdClose=true;f.start();f.on {f.now=110;f.pulse?()};f.drain()
        f.on {XCTAssertEqual(f.stopCount,1);XCTAssertEqual(f.pipe.closeCount,1);XCTAssertTrue(f.completions.isEmpty);f.now=1000;f.control?.tick()};f.drain()
        f.on {XCTAssertTrue(f.completions.isEmpty);f.pipe.retire()};f.drain();f.on {XCTAssertEqual(f.closed,.deadline);XCTAssertEqual(f.completions.count,1)}
    }
    func testSynchronousPageWriteAndClosePublishAfterMethodsReturn() {
        let f=Fixture();defer {f.cleanup()};f.start();f.on {f.pipe.supply(.bytes(head(page:true)))};f.drain()
        f.on {XCTAssertEqual(f.closed,.pageDone);XCTAssertEqual(f.pipe.writes.count,1);XCTAssertEqual(f.pipe.trace.last,"complete");XCTAssertTrue(f.pipe.trace.contains("write-return"));XCTAssertTrue(f.pipe.trace.contains("close-return"))}
    }
    func testDuplicateReadReplyCannotBecomeASecondCommand() {
        let f=Fixture();defer {f.cleanup()};f.start();f.on {let reply=f.pipe.readReply;reply?(.bytes(head()));reply?(.bytes(head()))};f.drain()
        f.on {XCTAssertEqual(f.pipe.writes.count,2);XCTAssertEqual(f.pipe.readCount,2);XCTAssertTrue(f.completions.isEmpty)}
    }
    func testShortWriteReceiptSubmitsOnlyRemainingBytes() {
        let f=Fixture();defer {f.cleanup()};f.pipe.holdWrite=true;f.start();f.on {f.pipe.supply(.bytes(head()))};f.drain()
        var first=Data();f.on {first=f.pipe.writes.first ?? Data();f.pipe.writeReply?(1)};f.drain()
        f.on {XCTAssertEqual(f.pipe.writes.count,2);XCTAssertEqual(f.pipe.writes.last,first.dropFirst());let n=f.pipe.writes.last?.count ?? 0;f.pipe.writeReply?(n)};f.drain()
        f.on {XCTAssertEqual(f.pipe.writes.count,3);XCTAssertEqual(f.pipe.readCount,1)}
    }
    func testZeroOrOversizedWriteFailsAndClosesExactlyOnce() {
        for value in [0,Int.max] {let f=Fixture();f.pipe.holdWrite=true;f.start();f.on {f.pipe.supply(.bytes(head()))};f.drain();f.on {f.pipe.writeReply?(value)};f.drain();f.on {XCTAssertEqual(f.failed,.write);XCTAssertEqual(f.pipe.closeCount,1)};f.cleanup()}
    }
    func testOversizedOrEmptyNonEOFReadFailsBeforeWorkflow() {
        for data in [Data(),Data(repeating:0,count:16385)] {let f=Fixture();f.start();f.on {f.pipe.supply(.bytes(data))};f.drain();f.on {XCTAssertEqual(f.failed,.read);XCTAssertEqual(f.pipe.writes.count,0);XCTAssertEqual(f.pipe.closeCount,1)};f.cleanup()}
    }
    func testResourceFactoryAndSchedulerFailureRemainDistinct() {
        let f=Fixture();defer {f.cleanup()};f.returnTransport=false;f.start();f.on {XCTAssertEqual(f.failed,.transport);XCTAssertEqual(f.scheduleCount,0)}
        let g=Fixture();defer {g.cleanup()};g.returnSchedule=false;g.start();g.on {XCTAssertEqual(g.failed,.scheduler);XCTAssertEqual(g.pipe.closeCount,1)}
    }
    func testSchedulerReentrantCancellationCancelsReturnedDriver() {
        let f=Fixture();defer {f.cleanup()};f.scheduleHook={XCTAssertTrue(f.control?.cancel() ?? false)};f.start()
        f.on {XCTAssertEqual(f.stopCount,1);XCTAssertEqual(f.pipe.readCount,0);XCTAssertEqual(f.pipe.closeCount,1);XCTAssertEqual(f.closed,.cancelled)}
    }
    func testReadFactoryCancellationBeatsInlineLateData() {
        let f=Fixture();defer {f.cleanup()};f.pipe.readHook={XCTAssertTrue(f.control?.cancel() ?? false);f.pipe.readReply?(.bytes(self.head()))};f.start()
        f.on {XCTAssertEqual(f.pipe.writes.count,0);XCTAssertEqual(f.closed,.cancelled);XCTAssertEqual(f.pipe.closeCount,1)}
    }
    func testControlReleaseRetainsCleanupUntilQuiescent() {
        let f=Fixture();defer {f.cleanup()};f.pipe.holdClose=true;f.start();f.on {f.control=nil};f.drain()
        f.on {XCTAssertEqual(f.pipe.closeCount,1);XCTAssertTrue(f.completions.isEmpty);f.pipe.retire()};f.drain();f.on {XCTAssertEqual(f.closed,.cancelled)}
    }
    func testReadyCloseCoalescesAndLastReleaseRetiresOwnedResource() {
        let f=Fixture();defer {f.cleanup()};f.start();upgrade(f);f.on {f.pipe.supply(.bytes(answer()))};f.drain();var replies=0
        f.on {XCTAssertTrue(f.ready?.close({replies += 1}) ?? false);XCTAssertTrue(f.ready?.close({replies += 1}) ?? false)};f.drain()
        f.on {XCTAssertEqual(f.pipe.closeCount,1);XCTAssertEqual(replies,2);f.completions.removeAll()};f.drain();f.on {XCTAssertEqual(f.pipe.closeCount,1)}
    }
    func testWrongPasswordWaitDoesNotIssueExtraReadOrEarlyRefusal() {
        let f=Fixture();defer {f.cleanup()};f.proof=false;f.start();upgrade(f);f.on {f.pipe.supply(.bytes(answer()))};f.drain()
        f.on {XCTAssertEqual(f.pipe.writes.count,2);XCTAssertEqual(f.pipe.readCount,2);f.now=100.5;f.pulse?()};f.drain();f.on {XCTAssertEqual(f.pipe.writes.count,2);f.now=101;f.pulse?()};f.drain();f.on {XCTAssertEqual(f.pipe.writes.count,3);XCTAssertEqual(f.closed,.wrongPassword)}
    }
    func testEOFAndBackwardsClockUseQuiescentClose() {
        let f=Fixture();defer {f.cleanup()};f.start();f.on {f.pipe.supply(.end)};f.drain();f.on {XCTAssertEqual(f.closed,.request);XCTAssertEqual(f.pipe.closeCount,1)}
        let g=Fixture();defer {g.cleanup()};g.start();g.on {g.now=99;g.pulse?()};g.drain();g.on {XCTAssertEqual(g.closed,.clock);XCTAssertEqual(g.pipe.closeCount,1)}
    }

    func testCloseWaiterQueuedBehindReceiptStillRunsExactlyOnce() {
        let f=Fixture();defer {f.cleanup()};f.start();upgrade(f);f.on {f.pipe.supply(.bytes(answer()))};f.drain();var callbacks=0
        f.on {f.pipe.holdClose=true;XCTAssertTrue(f.ready?.close({callbacks += 1}) ?? false)};f.drain()
        f.on {f.pipe.retire();XCTAssertTrue(f.ready?.close({callbacks += 1}) ?? false)};f.drain()
        f.on {XCTAssertEqual(callbacks,2);XCTAssertEqual(f.pipe.closeCount,1)}
    }
    func testReadyLastReleaseKeepsExactCloseReceiptAlive() {
        let f=Fixture();defer {f.cleanup()};f.start();upgrade(f);f.on {f.pipe.supply(.bytes(answer()))};f.drain()
        f.on {f.pipe.holdClose=true;f.completions.removeAll()};f.drain();f.on {XCTAssertEqual(f.pipe.closeCount,1);XCTAssertNotNil(f.pipe.closeReply);f.pipe.retire()};f.drain()
        f.on {XCTAssertNil(f.pipe.closeReply);XCTAssertEqual(f.stopCount,1)}
    }
    func testForeignQueueReadReceiptIsMarshalledToOwner() {
        let f=Fixture();defer {f.cleanup()};f.start();var reply:((WebConnection.Read)->Void)?
        f.on {reply=f.pipe.readReply};let sent=expectation(description:"foreign reply returned")
        let deliver=reply
        DispatchQueue.global().async {deliver?(.bytes(self.head(page:true)));sent.fulfill()}
        wait(for:[sent],timeout:2);f.drain();f.on {XCTAssertEqual(f.closed,.pageDone);XCTAssertEqual(f.completions.count,1)}
    }
    func testOversizedPageWritesAreChunkedAtNativeBoundary() {
        let f=Fixture();defer {f.cleanup()};var control:WebConnection.Control?,results=0
        f.on {control=WebConnection.start(queue:f.queue,permitted:{true},admission:{WebAdmission.Visit.make(credential:f.credential,failures:f.failures,page:Data(repeating:42,count:40000),policy:.init(hosts:["example.test:47840"],origins:[]),permitted:{true},current:{f.credential},clock:{100})},transport:{_ in f.pipe},schedule:{_,_ in {}},completion:{_ in results += 1})};f.drain()
        f.on {f.pipe.supply(.bytes(head(page:true)))};f.drain()
        f.on {XCTAssertEqual(results,1);XCTAssertGreaterThan(f.pipe.writes.count,2);XCTAssertTrue(f.pipe.writes.allSatisfy({$0.count<=16384}));XCTAssertEqual(f.pipe.closeCount,1)}
        _ = control?.cancel();control=nil
    }
    func testLateReadAfterQuiescentCloseCannotAffectAnotherConnection() {
        let f=Fixture();defer {f.cleanup()};f.start();var old:((WebConnection.Read)->Void)?
        f.on {old=f.pipe.readReply;_ = f.control?.cancel()};f.drain()
        let g=Fixture();defer {g.cleanup()};g.start();old?(.bytes(head()));g.drain();f.drain()
        f.on {XCTAssertEqual(f.completions.count,1);XCTAssertEqual(f.pipe.writes.count,0)};g.on {XCTAssertEqual(g.pipe.closeCount,0);XCTAssertEqual(g.pipe.readCount,1);XCTAssertTrue(g.completions.isEmpty)}
    }
    func testReadyWaiterCapacityRefusesWithoutClaimingQuiescence() {
        let f=Fixture();defer {f.cleanup()};f.start();upgrade(f);f.on {f.pipe.supply(.bytes(answer()))};f.drain();var replies=0
        f.on {f.pipe.holdClose=true;for _ in 0..<16 {XCTAssertTrue(f.ready?.close({replies += 1}) ?? false)};XCTAssertFalse(f.ready?.close({XCTFail("Refused waiter invoked")}) ?? true)};f.drain()
        f.on {XCTAssertEqual(replies,0);f.pipe.retire()};f.drain();f.on {XCTAssertEqual(replies,16);XCTAssertEqual(f.pipe.closeCount,1)}
    }
    func testFinalHTTPBytesCanWritePageBeforeQuiescentClose() {
        let f=Fixture();defer {f.cleanup()};f.start();f.on {f.pipe.supply(.ending(head(page:true),failed:false))};f.drain()
        f.on {XCTAssertEqual(f.pipe.writes.count,1);XCTAssertEqual(f.closed,.pageDone);XCTAssertEqual(f.pipe.readCount,1);XCTAssertNil(f.ready)}
    }
    func testFinalAuthProofCanNeverTransferUsableReady() {
        for failure in [false,true] {let f=Fixture();f.start();upgrade(f);f.on {f.pipe.supply(.ending(answer(),failed:failure))};f.drain();f.on {XCTAssertNil(f.ready);XCTAssertEqual(f.pipe.closeCount,1);XCTAssertEqual(f.completions.count,1)};f.cleanup()}
    }
    func testIncompleteFinalHTTPBytesCloseWithoutAnotherRead() {
        let f=Fixture();defer {f.cleanup()};f.start();f.on {f.pipe.supply(.ending(Data("GET /".utf8),failed:false))};f.drain();f.on {XCTAssertEqual(f.closed,.request);XCTAssertEqual(f.pipe.readCount,1);XCTAssertTrue(f.pipe.writes.isEmpty)}
    }

}
