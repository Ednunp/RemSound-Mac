import Foundation
import Network
import XCTest
@testable import RemSoundCore
final class WebReadyTests:XCTestCase {
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
    func testRetainedTailIsReadOnceInBoundedChunksBeforeRawRead() {
        let f=Fixture();defer {f.cleanup()};ready(f,tail:Data([1,2,3]));var bytes=[Data]()
        for size in [2,2] {f.on {XCTAssertTrue(f.ready?.read(maximum:size) {if case .bytes(let data)=$0 {bytes.append(data)} else {XCTFail("Tail receipt missing")}} ?? false)};f.drain()}
        f.on {XCTAssertEqual(bytes,[Data([1,2]),Data([3])]);XCTAssertEqual(f.pipe.readCount,2);XCTAssertTrue(f.ready?.read(maximum:4) {_ in} ?? false)};f.drain();f.on {XCTAssertEqual(f.pipe.readCount,3);f.pipe.supply(.bytes(Data([4])))};f.drain()
    }
    func testEachLaneIncludesQueuedWorkAndSameLaneRefusalHasNoCallback() {
        let f=Fixture();defer {f.cleanup()};ready(f);var received=0
        f.on {XCTAssertTrue(f.ready?.read(maximum:4) {_ in received += 1} ?? false);XCTAssertTrue(f.ready?.write(Data([1])) {XCTAssertEqual($0,1)} ?? false);XCTAssertFalse(f.ready?.read(maximum:4) {_ in XCTFail("Busy read callback")} ?? true)};f.drain()
        f.on {XCTAssertEqual(f.pipe.readCount,3);f.pipe.supply(.bytes(Data([1])))};f.drain();f.on {XCTAssertEqual(received,1);XCTAssertTrue(f.ready?.write(Data([2])) {XCTAssertEqual($0,1)} ?? false)};f.drain()
    }
    func testInvalidSizesRefuseBeforeQueueingOrRawIO() {
        let f=Fixture();defer {f.cleanup()};ready(f)
        f.on {for n in [0,-1,16385,Int.max] {XCTAssertFalse(f.ready?.read(maximum:n) {_ in XCTFail("Invalid read callback")} ?? true)};for data in [Data(),Data(repeating:0,count:16385)] {XCTAssertFalse(f.ready?.write(data) {_ in XCTFail("Invalid write callback")} ?? true)}};f.drain();f.on {XCTAssertEqual(f.pipe.readCount,2);XCTAssertEqual(f.pipe.writes.count,2)}
    }
    func testCloseWinsQueuedIOWithoutConstructingAnotherRawOperation() {
        let f=Fixture();defer {f.cleanup()};ready(f);var readFailed=0,closed=0
        f.on {XCTAssertTrue(f.ready?.read(maximum:4) {if case .failed=$0 {readFailed += 1}} ?? false);XCTAssertTrue(f.ready?.close {closed += 1} ?? false);XCTAssertFalse(f.ready?.write(Data([1])) {_ in XCTFail("Write after close")} ?? true)};f.drain()
        f.on {XCTAssertEqual(readFailed,1);XCTAssertEqual(closed,1);XCTAssertEqual(f.pipe.readCount,2);XCTAssertEqual(f.pipe.closeCount,1)}
    }
    func testCloseReceiptCannotPassStillPendingMarshalledIOCallback() {
        let f=Fixture();defer {f.cleanup()};ready(f);f.pipe.holdClose=true;var readFailed=0,closed=0;var late:((WebConnection.Read)->Void)?
        f.on {XCTAssertTrue(f.ready?.read(maximum:4) {if case .failed=$0 {readFailed += 1}} ?? false)};f.drain()
        f.on {late=f.pipe.readReply;XCTAssertTrue(f.ready?.close {closed += 1} ?? false)};f.drain();f.on {f.pipe.retire()};f.drain();f.on {XCTAssertEqual(closed,0);late?(.bytes(Data([1])))};f.drain();f.on {XCTAssertEqual(readFailed,1);XCTAssertEqual(closed,1)}
    }
    func testDuplicateOldReadCallbackCannotConsumeReplacementSlot() {
        let f=Fixture();defer {f.cleanup()};ready(f);var count=0;var old:((WebConnection.Read)->Void)?
        f.on {XCTAssertTrue(f.ready?.read(maximum:4) {_ in count += 1} ?? false)};f.drain();f.on {old=f.pipe.readReply;old?(.bytes(Data([1])));old?(.bytes(Data([2])))};f.drain()
        f.on {XCTAssertTrue(f.ready?.read(maximum:4) {_ in count += 1} ?? false)};f.drain();f.on {old?(.bytes(Data([3])))};f.drain();f.on {XCTAssertEqual(count,1);f.pipe.supply(.bytes(Data([4])))};f.drain();f.on {XCTAssertEqual(count,2)}
    }
    func testActualShortWriteCountRetainedWithoutImplicitRetry() {
        let f=Fixture();defer {f.cleanup()};ready(f);f.pipe.holdWrite=true;var counts=[Int?]()
        f.on {XCTAssertTrue(f.ready?.write(Data([1,2,3])) {counts.append($0)} ?? false)};f.drain();f.on {f.pipe.writeReply?(1);f.pipe.writeReply?(3)};f.drain()
        f.on {XCTAssertEqual(counts.count,1);XCTAssertEqual(counts.first ?? nil,1);XCTAssertEqual(f.pipe.writes.count,3)}
    }
    func testInvalidWriteCountFailsAndRetiresWithoutRetry() {
        for value in [0,4] {let f=Fixture();ready(f);f.pipe.holdWrite=true;var failures=0;f.on {XCTAssertTrue(f.ready?.write(Data([1,2,3])) {if $0==nil {failures += 1}} ?? false)};f.drain();f.on {f.pipe.writeReply?(value)};f.drain();f.on {XCTAssertEqual(failures,1);XCTAssertEqual(f.pipe.writes.count,3);XCTAssertEqual(f.pipe.closeCount,1)};f.cleanup()}
    }
    func testTerminalReadPreservesBytesAndRefusesFurtherIOBeforeReply() {
        for failed in [false,true] {let f=Fixture();ready(f);var count=0
            f.on {XCTAssertTrue(f.ready?.read(maximum:4) {result in
                if case .ending(let data,let error)=result {XCTAssertEqual(data,Data([1,2]));XCTAssertEqual(error,failed);count += 1} else {XCTFail("Terminal bytes missing")}
                XCTAssertFalse(f.ready?.write(Data([1])) {_ in XCTFail("Write after terminal")} ?? true)
            } ?? false)};f.drain();f.on {f.pipe.supply(.ending(Data([1,2]),failed:failed))};f.drain();f.on {XCTAssertEqual(count,1);XCTAssertEqual(f.pipe.closeCount,1)};f.cleanup()
        }
    }
    func testPermissionLossBeforeIOFailsThenClosesWithoutRawRead() {
        let f=Fixture();defer {f.cleanup()};ready(f);var failures=0;f.on {f.enabled=false;XCTAssertTrue(f.ready?.read(maximum:4) {if case .failed=$0 {failures += 1}} ?? false)};f.drain();f.on {XCTAssertEqual(failures,1);XCTAssertEqual(f.pipe.readCount,2);XCTAssertEqual(f.pipe.closeCount,1)}
    }
    func testCredentialEpochIsReprovedAfterAdmissionEvenWhenRuntimeEnabled() {
        let f=Fixture();defer {f.cleanup()};ready(f);var failures=0;f.on {f.current=nil;XCTAssertTrue(f.ready?.write(Data([1])) {if $0==nil {failures += 1}} ?? false)};f.drain();f.on {XCTAssertEqual(failures,1);XCTAssertEqual(f.pipe.writes.count,2);XCTAssertEqual(f.pipe.closeCount,1)}
    }
    func testReentrantPermissionCloseCannotConstructIO() {
        let f=Fixture();defer {f.cleanup()};ready(f);var failures=0;f.on {f.permissionHook={f.permissionHook=nil;_ = f.ready?.close()};XCTAssertTrue(f.ready?.read(maximum:4) {if case .failed=$0 {failures += 1}} ?? false)};f.drain();f.on {XCTAssertEqual(failures,1);XCTAssertEqual(f.pipe.readCount,2);XCTAssertEqual(f.pipe.closeCount,1)}
    }
    func testPermissionLossBeforeCallbackDoesNotPublishOldBytes() {
        let f=Fixture();defer {f.cleanup()};ready(f);var failures=0;f.on {XCTAssertTrue(f.ready?.read(maximum:4) {if case .failed=$0 {failures += 1}} ?? false)};f.drain();f.on {f.enabled=false;f.pipe.supply(.bytes(Data([1])))};f.drain();f.on {XCTAssertEqual(failures,1);XCTAssertEqual(f.pipe.closeCount,1)}
    }
    func testLastReadyReleaseKeepsPendingIOAndCloseReceiptAlive() {
        let f=Fixture();defer {f.cleanup()};ready(f);var failures=0;var late:((WebConnection.Read)->Void)?
        f.on {XCTAssertTrue(f.ready?.read(maximum:4) {if case .failed=$0 {failures += 1}} ?? false)};f.drain();f.on {late=f.pipe.readReply;f.pipe.holdClose=true;f.completions.removeAll()};f.drain();f.on {XCTAssertEqual(f.pipe.closeCount,1);late?(.bytes(Data([1])))};f.drain();f.on {XCTAssertEqual(failures,1);f.pipe.retire()};f.drain()
    }
    func testCompletedAdmissionCancellationCannotInterruptReadyIO() {
        let f=Fixture();defer {f.cleanup()};ready(f);var count=0;f.on {XCTAssertFalse(f.control?.cancel() ?? true);XCTAssertTrue(f.ready?.write(Data([1])) {XCTAssertEqual($0,1);count += 1} ?? false)};f.drain();f.on {XCTAssertEqual(count,1);XCTAssertEqual(f.pipe.closeCount,0)}
    }
    func testMalformedRawReadCannotExceedRequestedBound() {
        for data in [Data(),Data(repeating:0,count:5)] {let f=Fixture();ready(f);var failures=0;f.on {XCTAssertTrue(f.ready?.read(maximum:4) {if case .failed=$0 {failures += 1}} ?? false)};f.drain();f.on {f.pipe.supply(.bytes(data))};f.drain();f.on {XCTAssertEqual(failures,1);XCTAssertEqual(f.pipe.closeCount,1)};f.cleanup()}
    }
    func testForeignCallbackIsMarshalledAfterRawReturn() {
        let f=Fixture();defer {f.cleanup()};ready(f);var reply:((WebConnection.Read)->Void)?,count=0
        f.on {XCTAssertTrue(f.ready?.read(maximum:4) {_ in XCTAssertEqual(DispatchQueue.getSpecific(key:f.key),1);count += 1} ?? false)};f.drain();f.on {reply=f.pipe.readReply};let done=expectation(description:"foreign raw callback"),callback=reply
        DispatchQueue.global().async {callback?(.bytes(Data([1])));done.fulfill()};wait(for:[done],timeout:2);f.drain();f.on {XCTAssertEqual(count,1)}
    }
    func testReentrantCompletionCanQueueNewReadThenCloseWithoutRawConstruction() {
        let f=Fixture();defer {f.cleanup()};ready(f);var reads=0,failed=0,closed=0
        f.on {XCTAssertTrue(f.ready?.read(maximum:4) {_ in
            reads += 1;XCTAssertTrue(f.ready?.read(maximum:4) {if case .failed=$0 {failed += 1}} ?? false);_ = f.ready?.close {closed += 1}
        } ?? false)};f.drain();f.on {f.pipe.supply(.bytes(Data([1])))};f.drain();f.on {XCTAssertEqual(reads,1);XCTAssertEqual(failed,1);XCTAssertEqual(closed,1);XCTAssertEqual(f.pipe.readCount,3)}
    }
    func testReadyPermissionOutlivesVisitDeadlineButNotCredentialEpoch() {
        let f=Fixture();defer {f.cleanup()};ready(f);var sent=0
        f.on {f.now=10000;XCTAssertTrue(f.ready?.write(Data([1])) {XCTAssertEqual($0,1);sent += 1} ?? false)};f.drain();f.on {XCTAssertEqual(sent,1);XCTAssertEqual(f.pipe.closeCount,0);f.current=nil;XCTAssertTrue(f.ready?.read(maximum:4) {if case .failed=$0 {} else {XCTFail("Stale credential read")}} ?? false)};f.drain();f.on {XCTAssertEqual(f.pipe.closeCount,1);XCTAssertEqual(f.pipe.readCount,2)}
    }
    func testActualDriverReadyNativeRawChainUsesPersistentLifetimePermission() {
        let f=Fixture();defer {f.cleanup()};f.useNative=true;ready(f,tail:Data([5]));var read=0,written=0
        f.on {XCTAssertTrue(f.ready?.read(maximum:1) {if case .bytes(let data)=$0 {XCTAssertEqual(data,Data([5]));read += 1}} ?? false)};f.drain()
        f.on {XCTAssertTrue(f.ready?.write(Data([6])) {XCTAssertEqual($0,1);written += 1} ?? false)};f.drain();f.on {XCTAssertEqual(read,1);XCTAssertEqual(written,1);XCTAssertEqual(f.pipe.closeCount,0)}
    }
    func testActualOwnedLoopbackAuthenticationReadyReadWriteAndClose() throws {
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
                        let pong=WebSocketPackets.serverFrame(kind:.pong,payload:Data([7]))!
                        XCTAssertTrue(ready.write(pong) {XCTAssertEqual($0,pong.count);processed=true;finishIfBoth()})
                    })
                };collect()
            })
        }
        listener.start(queue:queue);wait(for:[serverClosed,listenerClosed,clientClosed],timeout:5)
        queue.sync {_ = owned?.close();owned=nil;_ = control?.cancel();control=nil;client?.cancel();listener.cancel();client?.stateUpdateHandler=nil;listener.newConnectionHandler=nil;listener.stateUpdateHandler=nil;client=nil;XCTAssertEqual(phase,3)}
    }

    func testSeparateDriverPermissionSurvivesHandoffAlongsideCredentialProof() {
        let f=Fixture();defer {f.cleanup()};f.admissionIgnoresDriver=true;ready(f);var failed=0
        f.on {f.enabled=false;XCTAssertTrue(f.ready?.read(maximum:4) {if case .failed=$0 {failed += 1}} ?? false)};f.drain()
        f.on {XCTAssertEqual(failed,1);XCTAssertEqual(f.pipe.readCount,2);XCTAssertEqual(f.pipe.closeCount,1);f.pipe.supply(.failed)};f.drain()
    }

}
