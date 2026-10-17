import Foundation
import Network
import XCTest
@testable import RemSoundCore
final class WebDuplexTests:XCTestCase {
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
    private final class RawPipe:WebNativeTransport.Raw {
        let pipe:Pipe;var state:((WebNativeTransport.State)->Void)?
        init(_ pipe:Pipe) {self.pipe=pipe}
        func start(queue:DispatchQueue,state:@escaping (WebNativeTransport.State)->Void) {self.state=state;state(.ready)}
        func receive(maximum:Int,completion:@escaping (Data?,Bool,Bool)->Void) {pipe.read(maximum:maximum) {result in switch result {case .bytes(let data):completion(data,false,false);case .ending(let data,let failed):completion(data,true,failed);case .end:completion(nil,true,false);case .failed:completion(nil,false,true)}}}
        func send(_ bytes:Data,completion:@escaping (Bool)->Void) {pipe.write(bytes) {completion($0==bytes.count)}}
        func cancel() {pipe.close {[weak self] in self?.state?(.cancelled)}}
    }
    private final class Fixture {
        let queue=DispatchQueue(label:"test.web.connection"),key=DispatchSpecificKey<Int>()
        let pipe=Pipe(),failures=WebAuthentication.Failures()
        let credential=WebAuthentication.Credential.make(password:"synthetic",salt:Data(repeating:0,count:16),derive:{_,_ in Data(repeating:1,count:32)})!
        var current:WebAuthentication.Credential?,now=100.0,enabled=true,proof=true
        var admissionCount=0,factoryCount=0,scheduleCount=0,stopCount=0,completions=[WebConnection.Result]()
        var pulse:(()->Void)?,factoryHook:((@escaping ()->Bool)->Void)?,scheduleHook:(()->Void)?
        var permissionHook:(()->Void)?
        var admissionIgnoresDriver=false
        var useNative=false
        var returnTransport=true,returnSchedule=true,control:WebConnection.Control?
        init() {current=credential;queue.setSpecific(key:key,value:1)}
        func on(_ body:()->Void) {queue.sync(execute:body)}
        func drain() {for _ in 0..<24 {queue.sync {}}}
        func start() {
            on {control=WebConnection.start(queue:queue,permitted:{[weak self] in self?.allowed ?? false},admission:{[weak self] in
                guard let self else {return nil};self.admissionCount += 1
                return WebAdmission.Visit.make(credential:self.credential,failures:self.failures,page:Data("fixed".utf8),policy:.init(hosts:["example.test:47840"],origins:["https://example.test"]),permitted:{[weak self] in guard let self else {return false};return self.admissionIgnoresDriver || self.allowed},current:{[weak self] in self?.current},clock:{[weak self] in self?.now ?? .nan},random:{Data(repeating:2,count:$0)},verify:{[weak self] _,_ in self?.proof ?? false})
            },transport:{[weak self] gate in guard let self else {return nil};self.factoryCount += 1;self.factoryHook?(gate);guard self.returnTransport else {return nil};if self.useNative {return WebNativeTransport.make(queue:self.queue,permitted:{[weak self] in self?.allowed ?? false},factory:{_ in RawPipe(self.pipe)})};return self.pipe},schedule:{[weak self] _,pulse in
                guard let self else {return nil};self.scheduleCount += 1;self.pulse=pulse;self.scheduleHook?();return self.returnSchedule ? {[weak self] in self?.stopCount += 1;self?.pulse=nil}:nil
            },completion:{[weak self] result in guard let self else {return};XCTAssertEqual(DispatchQueue.getSpecific(key:self.key),1);self.pipe.trace.append("complete");self.completions.append(result)})}
            drain()
        }
        var allowed:Bool {permissionHook?();return enabled}
        var closed:WebAdmission.Reason? {for result in completions {if case let .closed(reason)=result {return reason}};return nil}
        var failed:WebConnection.Failure? {for result in completions {if case let .failed(reason)=result {return reason}};return nil}
        var ready:WebConnection.Ready? {for result in completions {if case let .ready(value)=result {return value}};return nil}
        func cleanup() {on {permissionHook=nil;factoryHook=nil;scheduleHook=nil;pipe.readHook=nil;pipe.writeHook=nil;_ = control?.cancel();_ = ready?.close();completions.removeAll();pipe.holdClose=false;pipe.retire();control=nil};drain();on {pipe.retire()};drain()}
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
    private func ready(_ f:Fixture,tail:Data=Data()) {f.start();upgrade(f);f.on {f.pipe.supply(.bytes(answer()+tail))};f.drain();f.on {XCTAssertNotNil(f.ready)}}
    private func closeFrame(_ payload:Data=Data([3,232]))->Data {Data([0x88,0x80|UInt8(payload.count),0,0,0,0])+payload}
    private final class EndFixture {
        let reader=WebSocketPackets.Reader();var now=100.0,pulse:(()->Void)?,schedules=0,stops=0
        var policy:WebConnection.EndPolicy {.init(clock:{[self] in now},schedule:{[self] _,tick in schedules += 1;pulse=tick;return {[self] in stops += 1;pulse=nil}})}
    }
    func testReadyReadAndWriteAdmitOneOfEachBeforeQueueRuns() {
        let f=Fixture();defer {f.cleanup()};ready(f);f.pipe.holdWrite=true;var reads=0,writes=0
        f.on {XCTAssertTrue(f.ready?.read(maximum:4) {_ in reads += 1} ?? false);XCTAssertTrue(f.ready?.write(Data([1,2])) {XCTAssertEqual($0,2);writes += 1} ?? false);XCTAssertFalse(f.ready?.read(maximum:4) {_ in XCTFail("Second read")} ?? true);XCTAssertFalse(f.ready?.write(Data([3])) {_ in XCTFail("Second write")} ?? true)};f.drain()
        f.on {XCTAssertEqual(f.pipe.readCount,3);XCTAssertEqual(f.pipe.writes.count,3);f.pipe.writeReply?(2)};f.drain();f.on {XCTAssertEqual(writes,1);XCTAssertEqual(reads,0);f.pipe.supply(.bytes(Data([4])))};f.drain();f.on {XCTAssertEqual(reads,1)}
    }
    func testReadyCloseWaitsBothLanesAfterTransportReceiptInEitherOrder() {
        for writeFirst in [false,true] {let f=Fixture();ready(f);f.pipe.holdWrite=true;f.pipe.holdClose=true;var completed=0,closed=0;var read:((WebConnection.Read)->Void)?,write:((Int?)->Void)?
            f.on {XCTAssertTrue(f.ready?.read(maximum:4) {_ in completed += 1} ?? false);XCTAssertTrue(f.ready?.write(Data([1])) {_ in completed += 1} ?? false)};f.drain()
            f.on {read=f.pipe.readReply;write=f.pipe.writeReply;_ = f.ready?.close {closed += 1}};f.drain();f.on {f.pipe.retire()};f.drain()
            f.on {XCTAssertEqual(closed,0);if writeFirst {write?(nil)} else {read?(.failed)}};f.drain();f.on {XCTAssertEqual(completed,1);XCTAssertEqual(closed,0);if writeFirst {read?(.failed)} else {write?(nil)}};f.drain();f.on {XCTAssertEqual(completed,2);XCTAssertEqual(closed,1)};f.cleanup()
        }
    }
    func testEOFResponseWaitsExistingWriteAndKeepsOriginalBudget() {
        let f=Fixture(),e=EndFixture();defer {f.cleanup()};ready(f);f.pipe.holdWrite=true;f.pipe.holdClose=true;var outcome:WebConnection.EndOutcome?,dataCount:Int?;var dataWrite:((Int?)->Void)?
        f.on {XCTAssertTrue(f.ready?.write(Data([1,2,3])) {dataCount=$0} ?? false);XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:e.policy) {_,result in outcome=result} ?? false)};f.drain()
        f.on {dataWrite=f.pipe.writeReply;f.pipe.supply(.ending(closeFrame(),failed:false))};f.drain()
        f.on {XCTAssertEqual(f.pipe.writes.count,3);XCTAssertNil(outcome);XCTAssertFalse(f.ready?.write(Data([9])) {_ in XCTFail("Write after EOF")} ?? true);e.now=102;dataWrite?(3)};f.drain()
        f.on {XCTAssertEqual(dataCount,3);XCTAssertEqual(f.pipe.writes.last,Data([0x88,2,3,232]));e.now=103;e.pulse?()};f.drain();f.on {XCTAssertNil(outcome);f.pipe.writeReply?(4)};f.drain();f.on {XCTAssertEqual(outcome,.deadline)}
    }
    func testEOFBarrierExpiresBeforeDataReceiptWithoutEchoOrGuessedRetirement() {
        let f=Fixture(),e=EndFixture();defer {f.cleanup()};ready(f);f.pipe.holdWrite=true;f.pipe.holdClose=true;var outcome:WebConnection.EndOutcome?,closed=0;var write:((Int?)->Void)?
        f.on {XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:e.policy) {_,result in outcome=result} ?? false);XCTAssertTrue(f.ready?.write(Data([1])) {_ in} ?? false)};f.drain()
        f.on {write=f.pipe.writeReply;f.pipe.supply(.ending(closeFrame(),failed:false))};f.drain();f.on {e.now=103;e.pulse?()};f.drain()
        f.on {XCTAssertEqual(outcome,.deadline);XCTAssertEqual(f.pipe.writes.count,3);_ = f.ready?.close {closed += 1};f.pipe.retire()};f.drain();f.on {XCTAssertEqual(closed,0);write?(nil)};f.drain();f.on {XCTAssertEqual(closed,1)}
    }
    func testFailedOwnedDataWriteNeverStartsTerminalEcho() {
        let f=Fixture(),e=EndFixture();defer {f.cleanup()};ready(f);f.pipe.holdWrite=true;var outcome:WebConnection.EndOutcome?
        f.on {XCTAssertTrue(f.ready?.write(Data([1])) {_ in} ?? false);XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:e.policy) {_,result in outcome=result} ?? false)};f.drain();f.on {f.pipe.supply(.ending(closeFrame(),failed:false))};f.drain();f.on {f.pipe.writeReply?(nil)};f.drain();f.on {XCTAssertEqual(outcome,.failed);XCTAssertEqual(f.pipe.writes.count,3);XCTAssertEqual(f.pipe.closeCount,1)}
    }
    func testPersistentPermissionLossRetiresBothLanesWithoutPublishing() {
        let f=Fixture();defer {f.cleanup()};f.useNative=true;ready(f);f.pipe.holdWrite=true;var failed=0;var read:((WebConnection.Read)->Void)?,write:((Int?)->Void)?
        f.on {XCTAssertTrue(f.ready?.read(maximum:4) {if case .failed=$0 {failed += 1}} ?? false);XCTAssertTrue(f.ready?.write(Data([1])) {if $0==nil {failed += 1}} ?? false)};f.drain();f.on {read=f.pipe.readReply;write=f.pipe.writeReply;f.enabled=false;read?(.bytes(Data([1])));write?(1)};f.drain();f.on {XCTAssertEqual(failed,2);XCTAssertEqual(f.pipe.closeCount,1)}
    }
    private final class Raw:WebNativeTransport.Raw {
        var state:((WebNativeTransport.State)->Void)?,read:((Data?,Bool,Bool)->Void)?,write:((Bool)->Void)?;var receives=0,sends=0,cancels=0
        func start(queue:DispatchQueue,state:@escaping (WebNativeTransport.State)->Void) {self.state=state}
        func receive(maximum:Int,completion:@escaping (Data?,Bool,Bool)->Void) {receives += 1;read=completion}
        func send(_ bytes:Data,completion:@escaping (Bool)->Void) {sends += 1;write=completion}
        func cancel() {cancels += 1}
    }
    func testNativePendingReadAndWriteBothStartOnReadinessThenCloseWaitsBoth() {
        let queue=DispatchQueue(label:"test.web.duplex.raw"),raw=Raw();var transport:WebConnection.Transport?,receipts=0,closed=0
        queue.sync {transport=WebNativeTransport.make(queue:queue,permitted:{true},factory:{_ in raw});transport?.read(maximum:4) {_ in receipts += 1};transport?.write(Data([1])) {_ in receipts += 1}}
        func drain() {for _ in 0..<16 {queue.sync {}}};drain();queue.sync {XCTAssertEqual(raw.receives,0);XCTAssertEqual(raw.sends,0);raw.state?(.ready)};drain()
        queue.sync {XCTAssertEqual(raw.receives,1);XCTAssertEqual(raw.sends,1);transport?.close {closed += 1}};drain();queue.sync {raw.state?(.cancelled);raw.read?(nil,false,true)};drain();queue.sync {XCTAssertEqual(closed,0);XCTAssertEqual(receipts,1);raw.write?(false)};drain();queue.sync {XCTAssertEqual(closed,1);XCTAssertEqual(receipts,2);transport=nil};drain()
    }
    func testNativeCancellationBeforeReadyFailsBothWithoutRawIO() {
        let queue=DispatchQueue(label:"test.web.duplex.pending"),raw=Raw();var transport:WebConnection.Transport?,receipts=0,closed=0
        queue.sync {transport=WebNativeTransport.make(queue:queue,permitted:{true},factory:{_ in raw});transport?.read(maximum:4) {_ in receipts += 1};transport?.write(Data([1])) {_ in receipts += 1};transport?.close {closed += 1}}
        for _ in 0..<16 {queue.sync {}};queue.sync {XCTAssertEqual(receipts,2);XCTAssertEqual(raw.receives,0);XCTAssertEqual(raw.sends,0);XCTAssertEqual(closed,0);raw.state?(.cancelled)};for _ in 0..<16 {queue.sync {}};queue.sync {XCTAssertEqual(closed,1);transport=nil};for _ in 0..<16 {queue.sync {}}
    }

    func testReadyLastReleaseKeepsBothCallbacksAliveUntilActualRetirement() {
        let f=Fixture();defer {f.cleanup()};ready(f);f.pipe.holdWrite=true;f.pipe.holdClose=true;var receipts=0;var read:((WebConnection.Read)->Void)?,write:((Int?)->Void)?
        f.on {XCTAssertTrue(f.ready?.read(maximum:4) {_ in receipts += 1} ?? false);XCTAssertTrue(f.ready?.write(Data([1])) {_ in receipts += 1} ?? false)};f.drain()
        f.on {read=f.pipe.readReply;write=f.pipe.writeReply;f.completions.removeAll()};f.drain();f.on {XCTAssertEqual(f.pipe.closeCount,1);f.pipe.retire();write?(nil)};f.drain();f.on {XCTAssertEqual(receipts,1);read?(.failed)};f.drain();f.on {XCTAssertEqual(receipts,2)}
    }
    func testOldWriteReceiptCannotReleaseNewWriteWhileReadRemainsPending() {
        let f=Fixture();defer {f.cleanup()};ready(f);f.pipe.holdWrite=true;var writes=0;var old:((Int?)->Void)?
        f.on {XCTAssertTrue(f.ready?.read(maximum:4) {_ in} ?? false);XCTAssertTrue(f.ready?.write(Data([1])) {_ in writes += 1} ?? false)};f.drain();f.on {old=f.pipe.writeReply;old?(1)};f.drain()
        f.on {XCTAssertTrue(f.ready?.write(Data([2])) {_ in writes += 1} ?? false)};f.drain();f.on {old?(1)};f.drain();f.on {XCTAssertEqual(writes,1);XCTAssertFalse(f.ready?.write(Data([3])) {_ in XCTFail("Stale receipt freed write")} ?? true);f.pipe.writeReply?(1);f.pipe.supply(.bytes(Data([1])))};f.drain();f.on {XCTAssertEqual(writes,2)}
    }
    func testQueuedDuplexCloseNeverConstructsEitherRawOperation() {
        let f=Fixture();defer {f.cleanup()};ready(f);var receipts=0,closed=0
        f.on {XCTAssertTrue(f.ready?.read(maximum:4) {_ in receipts += 1} ?? false);XCTAssertTrue(f.ready?.write(Data([1])) {_ in receipts += 1} ?? false);_ = f.ready?.close {closed += 1}};f.drain();f.on {XCTAssertEqual(receipts,2);XCTAssertEqual(closed,1);XCTAssertEqual(f.pipe.readCount,2);XCTAssertEqual(f.pipe.writes.count,2)}
    }
    func testEchoBarrierCancellationNeverWritesAfterOldDataReceipt() {
        let f=Fixture(),e=EndFixture();defer {f.cleanup()};ready(f);f.pipe.holdWrite=true;f.pipe.holdClose=true;var outcome:WebConnection.EndOutcome?,closed=0;var write:((Int?)->Void)?
        f.on {XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:e.policy) {_,result in outcome=result} ?? false);XCTAssertTrue(f.ready?.write(Data([1])) {_ in} ?? false)};f.drain();f.on {write=f.pipe.writeReply;f.pipe.supply(.ending(closeFrame(),failed:false))};f.drain()
        f.on {_ = f.ready?.close {closed += 1}};f.drain();f.on {XCTAssertEqual(outcome,.cancelled);XCTAssertEqual(e.stops,1);f.pipe.retire()};f.drain();f.on {XCTAssertEqual(closed,0);write?(1)};f.drain();f.on {XCTAssertEqual(closed,1);XCTAssertEqual(f.pipe.writes.count,3)}
    }
    func testEchoBarrierCredentialReplacementCannotSendWhenOldWriteRetires() {
        let f=Fixture(),e=EndFixture();defer {f.cleanup()};ready(f);f.pipe.holdWrite=true;var outcome:WebConnection.EndOutcome?
        f.on {XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:e.policy) {_,result in outcome=result} ?? false);XCTAssertTrue(f.ready?.write(Data([1])) {_ in} ?? false)};f.drain();f.on {f.pipe.supply(.ending(closeFrame(),failed:false))};f.drain();f.on {f.current=nil;f.pipe.writeReply?(1)};f.drain();f.on {XCTAssertEqual(outcome,.cancelled);XCTAssertEqual(f.pipe.writes.count,3);XCTAssertEqual(f.pipe.closeCount,1)}
    }
    func testNativeDuplicateWriteReceiptCannotReleaseReplacementOrPendingRead() {
        let queue=DispatchQueue(label:"test.web.duplex.stale"),raw=Raw();var transport:WebConnection.Transport?,writes=0;var old:((Bool)->Void)?
        func drain() {for _ in 0..<16 {queue.sync {}}}
        queue.sync {transport=WebNativeTransport.make(queue:queue,permitted:{true},factory:{_ in raw});raw.state?(.ready)};drain()
        queue.sync {transport?.read(maximum:4) {_ in};transport?.write(Data([1])) {_ in writes += 1}};drain();queue.sync {old=raw.write;old?(true)};drain()
        queue.sync {transport?.write(Data([2])) {_ in writes += 1}};drain();queue.sync {old?(true)};drain();queue.sync {XCTAssertEqual(writes,1);XCTAssertEqual(raw.sends,2);raw.write?(true);raw.read?(Data([1]),false,false)};drain()
        queue.sync {XCTAssertEqual(writes,2);transport?.close {};transport=nil};drain();queue.sync {raw.state?(.cancelled)};drain()
    }
    func testActualOwnedLoopbackPendingReadDoesNotBlockOutgoingFrameAndClose() throws {
        let queue=DispatchQueue(label:"test.web.ready.owned-loopback"),serverClosed=expectation(description:"Ready native resource retired"),listenerClosed=expectation(description:"Ready listener retired"),clientClosed=expectation(description:"Ready client retired")
        let parameters=NWParameters.tcp;parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:.any)
        let listener=try NWListener(using:parameters)
        let credential=WebAuthentication.Credential.make(password:"synthetic",salt:Data(repeating:0,count:16),derive:{_,_ in Data(repeating:1,count:32)})!,failures=WebAuthentication.Failures()
        var client:NWConnection?,control:WebConnection.Control?,owned:WebConnection.Ready?,buffer=Data(),phase=0,processed=false,heard=false,closingStarted=false
        let frames=WebSocketPackets.Reader(fromClient:false),ping=Data([0x89,0x81,0,0,0,0,7])
        func finishIfBoth() {
            guard processed,heard,!closingStarted else {return};closingStarted=true
            XCTAssertTrue(owned?.close {owned=nil;client?.cancel();listener.cancel();serverClosed.fulfill()} ?? false)
        }
        listener.stateUpdateHandler={state in
            switch state {
            case .ready:
                guard let port=listener.port else {XCTFail("Missing owned Ready port");return}
                let connection=NWConnection(host:.ipv4(.loopback),port:port,using:.tcp);client=connection
                connection.stateUpdateHandler={state in
                    switch state {
                    case .ready:
                        connection.send(content:self.head(),completion:.contentProcessed {XCTAssertNil($0)})
                        func read() {
                            connection.receive(minimumIncompleteLength:1,maximumLength:4096) {data,_,end,error in
                                XCTAssertNil(error);if let data {buffer.append(data)};XCTAssertLessThanOrEqual(buffer.count,16384)
                                for _ in 0..<4 {
                                    if phase==0 {
                                        guard let split=buffer.range(of:Data("\r\n\r\n".utf8)) else {break}
                                        XCTAssertTrue(String(decoding:buffer.prefix(upTo:split.upperBound),as:UTF8.self).hasPrefix("HTTP/1.1 101 "));buffer=Data(buffer.suffix(from:split.upperBound));phase=1
                                    }
                                    guard phase==1 || phase==2,!buffer.isEmpty else {break}
                                    let result=frames.feed(buffer);buffer=Data(buffer.dropFirst(result.consumedBytes))
                                    if result.event == .pending {break}
                                    if phase==1,case .text(let challenge)=result.event {
                                        XCTAssertTrue(String(decoding:challenge,as:UTF8.self).contains("nonce"));phase=2
                                        connection.send(content:self.answer()+ping,completion:.contentProcessed {XCTAssertNil($0)})
                                    } else if phase==2,case .pong(let bytes)=result.event {
                                        XCTAssertEqual(bytes,Data([7]));heard=true;phase=3;finishIfBoth()
                                    } else {XCTFail("Unexpected owned server frame");break}
                                }
                                if phase<3 {if end || error != nil {XCTFail("Premature owned stream end");connection.cancel();listener.cancel()} else {read()}}
                            }
                        };read()
                    case .cancelled:clientClosed.fulfill()
                    default:break
                    }
                };connection.start(queue:queue)
            case .cancelled:listenerClosed.fulfill()
            case .failed(let error):XCTFail("Ready listener failed: \(error)");listener.cancel()
            default:break
            }
        }
        listener.newConnectionHandler={connection in
            control=WebConnection.start(queue:queue,permitted:{true},admission:{WebAdmission.Visit.make(credential:credential,failures:failures,page:Data("fixed".utf8),policy:.init(hosts:["example.test:47840"],origins:["https://example.test"]),permitted:{true},current:{credential},clock:{ProcessInfo.processInfo.systemUptime},random:{Data(repeating:2,count:$0)},verify:{_,_ in true})},transport:{gate in
                guard gate() else {return nil};return WebNativeTransport.loopback(connection,queue:queue,permitted:{true})
            },schedule:WebNativeTransport.schedule(permitted:{true}),completion:{result in
                guard case .ready(let ready)=result else {XCTFail("Owned Ready handoff failed");return};owned=ready
                XCTAssertFalse(control?.cancel() ?? true)
                var gathered=Data()
                func collect() {
                    XCTAssertTrue(ready.read(maximum:min(2,ping.count-gathered.count)) {result in
                        guard case .bytes(let bytes)=result else {XCTFail("Ready tail bytes missing");return}
                        XCTAssertGreaterThan(bytes.count,0);XCTAssertLessThanOrEqual(bytes.count,2);gathered.append(bytes)
                        if gathered.count<ping.count {collect();return}
                        XCTAssertEqual(gathered,ping)
                        XCTAssertTrue(ready.read(maximum:1) {result in
                            if case .failed=result {} else {XCTFail("Pending duplex read did not retire")}
                        })
                        queue.async {
                            let pong=WebSocketPackets.serverFrame(kind:.pong,payload:Data([7]))!
                            XCTAssertTrue(ready.write(pong) {XCTAssertEqual($0,pong.count);processed=true;finishIfBoth()})
                        }
                    })
                };collect()
            })
        }
        listener.start(queue:queue);wait(for:[serverClosed,listenerClosed,clientClosed],timeout:5)
        queue.sync {_ = owned?.close();owned=nil;_ = control?.cancel();control=nil;client?.cancel();listener.cancel();client?.stateUpdateHandler=nil;listener.newConnectionHandler=nil;listener.stateUpdateHandler=nil;client=nil;XCTAssertEqual(phase,3)}
    }


    func testShortOwnedDataFrameCannotBeFollowedByEchoInsideItsMissingSuffix() {
        let f=Fixture(),e=EndFixture();defer {f.cleanup()};ready(f);f.pipe.holdWrite=true;var outcome:WebConnection.EndOutcome?,count:Int?
        f.on {XCTAssertTrue(f.ready?.write(Data([0x82,2,1,2])) {count=$0} ?? false);XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:e.policy) {_,result in outcome=result} ?? false)};f.drain();f.on {f.pipe.supply(.ending(closeFrame(),failed:false))};f.drain();f.on {f.pipe.writeReply?(1)};f.drain()
        f.on {XCTAssertEqual(count,1);XCTAssertEqual(outcome,.failed);XCTAssertEqual(f.pipe.writes.count,3);XCTAssertEqual(f.pipe.closeCount,1)}
    }
}
