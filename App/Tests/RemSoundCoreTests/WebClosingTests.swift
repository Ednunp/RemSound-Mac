import Foundation
import Network
import XCTest
@testable import RemSoundCore
final class WebClosingTests:XCTestCase {
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
    func testOnlyValidatedClientCloseCreatesSingleUseExactResponse() {
        for body in [Data(),Data([3,232]),Data([3,232])+Data("reason".utf8),Data([3,242])] {
            let reader=WebSocketPackets.Reader();XCTAssertEqual(reader.feed(closeFrame(body)).event,.close(body));let proof=reader.takeCloseResponse();XCTAssertNotNil(proof)
            let expected=body==Data([3,242]) ? Data([0x88,0]):Data([0x88,UInt8(body.count)])+body
            XCTAssertEqual(proof?.takeBytes(),expected);XCTAssertNil(proof?.takeBytes());XCTAssertNil(reader.takeCloseResponse())
        }
    }
    func testMalformedPartialServerOrOtherFrameCannotCreateCloseResponse() {
        for data in [Data([0x88,0x81,0,0,0,0,3]),Data([0x88,0x82,0,0,0,0,3,237]),Data([0x89,0x80,0,0,0,0]),Data([0x88])] {let reader=WebSocketPackets.Reader();_ = reader.feed(data);XCTAssertNil(reader.takeCloseResponse())}
        let server=WebSocketPackets.Reader(fromClient:false);_ = server.feed(Data([0x88,2,3,232]));XCTAssertNil(server.takeCloseResponse())
    }
    func testFinalCloseAndEOFProcessesExactEchoBeforeQuiescentClose() {
        let f=Fixture(),e=EndFixture();defer {f.cleanup()};ready(f);var result:WebConnection.EndOutcome?;f.pipe.holdWrite=true;f.pipe.holdClose=true
        f.on {XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:e.policy) {_,outcome in result=outcome} ?? false)};f.drain();f.on {f.pipe.supply(.ending(closeFrame(),failed:false))};f.drain()
        f.on {XCTAssertEqual(f.pipe.writes.last,Data([0x88,2,3,232]));XCTAssertNil(result);XCTAssertEqual(f.pipe.closeCount,0);f.pipe.writeReply?(4)};f.drain()
        f.on {XCTAssertEqual(result,.processed);XCTAssertEqual(e.stops,1);XCTAssertEqual(f.pipe.closeCount,1);var closed=0;_ = f.ready?.close {closed += 1};XCTAssertEqual(closed,0);f.pipe.retire()};f.drain()
    }
    func testSplitCloseUsesSameParserAndShortWritesAdvanceExactSuffix() {
        let f=Fixture(),e=EndFixture();defer {f.cleanup()};ready(f);f.pipe.holdWrite=true;var result:WebConnection.EndOutcome?
        f.on {XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:e.policy) {read,outcome in if case .bytes(let bytes)=read {XCTAssertEqual(e.reader.feed(bytes).event,.pending)};XCTAssertEqual(outcome,.notRequested)} ?? false)};f.drain();f.on {f.pipe.supply(.bytes(closeFrame().prefix(4)))};f.drain()
        f.on {XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:e.policy) {_,outcome in result=outcome} ?? false)};f.drain();f.on {f.pipe.supply(.ending(closeFrame().dropFirst(4),failed:false))};f.drain()
        var old:((Int?)->Void)?;f.on {old=f.pipe.writeReply;old?(1)};f.drain();f.on {XCTAssertEqual(f.pipe.writes.last,Data([2,3,232]));old?(4);XCTAssertNil(result);f.pipe.writeReply?(3)};f.drain();f.on {XCTAssertEqual(result,.processed);XCTAssertEqual(f.pipe.writes.count,4)}
    }
    func testEOFWithoutCloseOrFailedReadDoesNotScheduleOrWrite() {
        for data in [Data([0x89,0x80,0,0,0,0]),Data([0x88]),closeFrame()] {let f=Fixture(),e=EndFixture();ready(f);var result:WebConnection.EndOutcome?;f.on {XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:e.policy) {_,outcome in result=outcome} ?? false)};f.drain();f.on {f.pipe.supply(.ending(data,failed:data==closeFrame()))};f.drain();f.on {XCTAssertEqual(result,.notRequested);XCTAssertEqual(e.schedules,0);XCTAssertEqual(f.pipe.writes.count,2);XCTAssertEqual(f.pipe.closeCount,1)};f.cleanup()}
    }
    func testTerminalResponseClosesAdmissionBeforeAnyOtherWrite() {
        let f=Fixture(),e=EndFixture();defer {f.cleanup()};ready(f);f.pipe.holdWrite=true
        f.on {XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:e.policy) {_,_ in} ?? false)};f.drain();f.on {f.pipe.supply(.ending(closeFrame(),failed:false))};f.drain()
        f.on {XCTAssertFalse(f.ready?.write(Data([1])) {_ in XCTFail("Generic write after EOF")} ?? true);XCTAssertFalse(f.ready?.read(maximum:1) {_ in XCTFail("Read after EOF")} ?? true);f.pipe.writeReply?(4)};f.drain()
    }
    func testExplicitCancelWhileEchoPendingWaitsRawRetirementAndDoesNotClaimProcessed() {
        let f=Fixture(),e=EndFixture();defer {f.cleanup()};ready(f);f.pipe.holdWrite=true;f.pipe.holdClose=true;var result:WebConnection.EndOutcome?,closed=0;var write:((Int?)->Void)?
        f.on {XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:e.policy) {_,outcome in result=outcome} ?? false)};f.drain();f.on {f.pipe.supply(.ending(closeFrame(),failed:false))};f.drain()
        f.on {write=f.pipe.writeReply;_ = f.ready?.close {closed += 1}};f.drain();f.on {f.pipe.retire()};f.drain();f.on {XCTAssertEqual(closed,0);XCTAssertNil(result);write?(nil)};f.drain();f.on {XCTAssertEqual(result,.cancelled);XCTAssertEqual(closed,1);XCTAssertEqual(e.stops,1)}
    }
    func testResponseDeadlineStopsDriverAndCancelsButNeverFabricatesWriteReceipt() {
        let f=Fixture(),e=EndFixture();defer {f.cleanup()};ready(f);f.pipe.holdWrite=true;f.pipe.holdClose=true;var result:WebConnection.EndOutcome?;var write:((Int?)->Void)?
        f.on {XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:e.policy) {_,outcome in result=outcome} ?? false)};f.drain();f.on {f.pipe.supply(.ending(closeFrame(),failed:false))};f.drain()
        f.on {write=f.pipe.writeReply;e.now=103;e.pulse?()};f.drain();f.on {XCTAssertEqual(e.stops,1);XCTAssertEqual(f.pipe.closeCount,1);XCTAssertNil(result);write?(nil)};f.drain();f.on {XCTAssertEqual(result,.deadline);f.pipe.retire()};f.drain()
    }
    func testClockAndPermissionAreReprovedBeforeSchedulerOrTerminalWrite() {
        for invalid in [Double.nan,-1,Double.greatestFiniteMagnitude] {let f=Fixture(),e=EndFixture();ready(f);e.now=invalid;var result:WebConnection.EndOutcome?;f.on {XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:e.policy) {_,outcome in result=outcome} ?? false)};f.drain();f.on {f.pipe.supply(.ending(closeFrame(),failed:false))};f.drain();f.on {XCTAssertEqual(result,.clock);XCTAssertEqual(e.schedules,0);XCTAssertEqual(f.pipe.writes.count,2)};f.cleanup()}
    }
    func testReceiptFailureDoesNotRetryEchoOrReportProcessed() {
        for count:Int? in [nil,0,5] {let f=Fixture(),e=EndFixture();ready(f);f.pipe.holdWrite=true;var result:WebConnection.EndOutcome?;f.on {XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:e.policy) {_,outcome in result=outcome} ?? false)};f.drain();f.on {f.pipe.supply(.ending(closeFrame(),failed:false))};f.drain();f.on {f.pipe.writeReply?(count)};f.drain();f.on {XCTAssertEqual(result,.failed);XCTAssertEqual(f.pipe.writes.count,3);XCTAssertEqual(f.pipe.closeCount,1)};f.cleanup()}
    }
    func testPureEOFCanUseAlreadyReceivedCloseProofOnce() {
        let f=Fixture(),e=EndFixture();defer {f.cleanup()};ready(f);var result:WebConnection.EndOutcome?;XCTAssertEqual(e.reader.feed(closeFrame()).event,.close(Data([3,232])))
        f.on {XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:e.policy) {_,outcome in result=outcome} ?? false)};f.drain();f.on {f.pipe.supply(.end)};f.drain();f.on {XCTAssertEqual(result,.processed);XCTAssertEqual(f.pipe.writes.last,Data([0x88,2,3,232]));XCTAssertNil(e.reader.takeCloseResponse())}
    }
    func testClientOnly1010GetsEmptyServerCloseResponse() {
        let f=Fixture(),e=EndFixture();defer {f.cleanup()};ready(f);var result:WebConnection.EndOutcome?
        f.on {XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:e.policy) {_,outcome in result=outcome} ?? false)};f.drain();f.on {f.pipe.supply(.ending(closeFrame(Data([3,242])),failed:false))};f.drain();f.on {XCTAssertEqual(result,.processed);XCTAssertEqual(f.pipe.writes.last,Data([0x88,0]))}
    }
    func testReturnedSchedulerIsRetiredIfPermissionOrOriginalDeadlineChanged() {
        for mode in 0..<3 {let f=Fixture(),e=EndFixture();ready(f);var outcome:WebConnection.EndOutcome?
            let policy=WebConnection.EndPolicy(clock:{e.now},schedule:{_,_ in e.schedules += 1;if mode==0 {f.current=nil} else if mode==1 {e.now=103} else {e.now=99};return {e.stops += 1}})
            f.on {XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:policy) {_,result in outcome=result} ?? false)};f.drain();f.on {f.pipe.supply(.ending(closeFrame(),failed:false))};f.drain()
            f.on {XCTAssertEqual(outcome,mode==0 ? .cancelled:mode==1 ? .deadline:.clock);XCTAssertEqual(e.schedules,1);XCTAssertEqual(e.stops,1);XCTAssertEqual(f.pipe.writes.count,2);XCTAssertEqual(f.pipe.closeCount,1)};f.cleanup()
        }
    }
    func testReentrantClockCloseRefusesBeforeParserScheduleOrWrite() {
        let f=Fixture(),e=EndFixture();defer {f.cleanup()};ready(f);var outcome:WebConnection.EndOutcome?
        let policy=WebConnection.EndPolicy(clock:{_ = f.ready?.close();return e.now},schedule:{_,_ in XCTFail("Schedule after reentrant close");return nil})
        f.on {XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:policy) {_,result in outcome=result} ?? false)};f.drain();f.on {f.pipe.supply(.ending(closeFrame(),failed:false))};f.drain();f.on {XCTAssertEqual(outcome,.cancelled);XCTAssertEqual(f.pipe.writes.count,2);XCTAssertEqual(f.pipe.closeCount,1)}
    }
    func testChangingParserIdentityRefusesBeforeAnotherRawRead() {
        let f=Fixture(),e=EndFixture();defer {f.cleanup()};ready(f);var failed=0
        f.on {XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:e.policy) {_,outcome in XCTAssertEqual(outcome,.notRequested)} ?? false)};f.drain();f.on {f.pipe.supply(.bytes(Data([1])))};f.drain()
        f.on {XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:WebSocketPackets.Reader(),policy:e.policy) {read,_ in if case .failed=read {failed += 1}} ?? false)};f.drain();f.on {XCTAssertEqual(failed,1);XCTAssertEqual(f.pipe.readCount,3);XCTAssertEqual(f.pipe.closeCount,1)}
    }
    func testActualOwnedLoopbackFinalCloseAndFINReceiveEchoBeforeNativeRetirement() throws {
        let queue=DispatchQueue(label:"test.web.closing.owned-loopback"),serverClosed=expectation(description:"terminal Ready retired"),listenerClosed=expectation(description:"terminal listener retired"),clientClosed=expectation(description:"terminal client retired"),echoSeen=expectation(description:"peer received terminal close echo")
        let parameters=NWParameters.tcp;parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:.any)
        let listener=try NWListener(using:parameters),frames=WebSocketPackets.Reader(fromClient:false),peer=WebSocketPackets.Reader()
        let credential=WebAuthentication.Credential.make(password:"synthetic",salt:Data(repeating:0,count:16),derive:{_,_ in Data(repeating:1,count:32)})!,failures=WebAuthentication.Failures()
        var client:NWConnection?,control:WebConnection.Control?,owned:WebConnection.Ready?,buffer=Data(),phase=0,outcome:WebConnection.EndOutcome?
        listener.stateUpdateHandler={state in
            switch state {
            case .ready:
                guard let port=listener.port else {XCTFail("Missing closing spare port");return}
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
                                    guard (1...3).contains(phase),!buffer.isEmpty else {break}
                                    let receipt=frames.feed(buffer);buffer=Data(buffer.dropFirst(receipt.consumedBytes));if receipt.event == .pending {break}
                                    if phase==1,case .text=receipt.event {phase=2;connection.send(content:self.answer(),completion:.contentProcessed {XCTAssertNil($0)})}
                                    else if phase==2,case .text(let ready)=receipt.event {
                                        XCTAssertEqual(ready,Data("ready".utf8));phase=3
                                        connection.send(content:self.closeFrame(),contentContext:.finalMessage,isComplete:true,completion:.contentProcessed {XCTAssertNil($0)})
                                    } else if phase==3,case .close(let body)=receipt.event {XCTAssertEqual(body,Data([3,232]));phase=4;echoSeen.fulfill();connection.cancel()}
                                    else {XCTFail("Unexpected terminal peer frame");break}
                                }
                                if phase<4 {if end || error != nil {XCTFail("Peer ended before exact echo");connection.cancel()} else {read()}}
                            }
                        };read()
                    case .cancelled:clientClosed.fulfill()
                    default:break
                    }
                };connection.start(queue:queue)
            case .cancelled:listenerClosed.fulfill()
            case .failed(let error):XCTFail("Closing listener failed: \(error)");listener.cancel()
            default:break
            }
        }
        listener.newConnectionHandler={connection in
            control=WebConnection.start(queue:queue,permitted:{true},admission:{WebAdmission.Visit.make(credential:credential,failures:failures,page:Data("fixed".utf8),policy:.init(hosts:["example.test:47840"],origins:["https://example.test"]),permitted:{true},current:{credential},clock:{ProcessInfo.processInfo.systemUptime},random:{Data(repeating:2,count:$0)},verify:{_,_ in true})},transport:{gate in
                guard gate() else {return nil};return WebNativeTransport.loopback(connection,queue:queue,permitted:{true})
            },schedule:WebNativeTransport.schedule(permitted:{true}),completion:{result in
                guard case .ready(let ready)=result else {XCTFail("Closing Ready handoff failed");return};owned=ready
                let signal=WebSocketPackets.serverFrame(kind:.text,payload:Data("ready".utf8))!
                func readPeer() {
                    let policy=WebConnection.EndPolicy(clock:{ProcessInfo.processInfo.systemUptime},schedule:WebNativeTransport.schedule(permitted:{true}))
                    XCTAssertTrue(ready.readRespondingToEnd(maximum:64,reader:peer,policy:policy) {read,result in
                        if case .bytes(let bytes)=read {_ = peer.feed(bytes);XCTAssertEqual(result,.notRequested);readPeer();return}
                        outcome=result;XCTAssertEqual(result,.processed)
                        XCTAssertTrue(ready.close {owned=nil;listener.cancel();serverClosed.fulfill()})
                    })
                }
                XCTAssertTrue(ready.write(signal) {XCTAssertEqual($0,signal.count);readPeer()})
            })
        }
        listener.start(queue:queue);wait(for:[serverClosed,listenerClosed,clientClosed,echoSeen],timeout:5)
        queue.sync {_ = owned?.close();owned=nil;_ = control?.cancel();control=nil;client?.cancel();listener.cancel();client?.stateUpdateHandler=nil;listener.newConnectionHandler=nil;listener.stateUpdateHandler=nil;client=nil;XCTAssertEqual(phase,4);XCTAssertEqual(outcome,.processed)}
    }

    func testAnotherReadyCannotReuseAnAlreadyBoundParser() {
        let f=Fixture(),g=Fixture(),e=EndFixture();defer {f.cleanup();g.cleanup()};ready(f);ready(g);var failed=0
        f.on {XCTAssertTrue(f.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:e.policy) {_,_ in} ?? false)};f.drain();f.on {f.pipe.supply(.bytes(Data([1])))};f.drain()
        g.on {XCTAssertTrue(g.ready?.readRespondingToEnd(maximum:32,reader:e.reader,policy:e.policy) {read,_ in if case .failed=read {failed += 1}} ?? false)};g.drain()
        g.on {XCTAssertEqual(failed,1);XCTAssertEqual(g.pipe.readCount,2);XCTAssertEqual(g.pipe.closeCount,1);g.pipe.supply(.failed)};g.drain()
    }

}
