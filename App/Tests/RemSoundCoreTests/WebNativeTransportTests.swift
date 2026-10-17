import Foundation
import Network
import RemSoundRuntime
import XCTest
@testable import RemSoundCore
final class WebNativeTransportTests:XCTestCase {
    private final class Pipe:WebNativeTransport.Raw {
        var state:((WebNativeTransport.State)->Void)?,read:((Data?,Bool,Bool)->Void)?,write:((Bool)->Void)?
        var starts=0,cancels=0,maximums=[Int](),writes=[Data](),trace=[String]()
        var ready=true,inlineRead=false,inlineWrite=false,inlineCancel=false
        func start(queue:DispatchQueue,state:@escaping (WebNativeTransport.State)->Void) {starts += 1;self.state=state;if ready {state(.ready)};trace.append("start-return")}
        func receive(maximum:Int,completion:@escaping (Data?,Bool,Bool)->Void) {maximums.append(maximum);read=completion;if inlineRead {completion(Data([1]),false,false)};trace.append("read-return")}
        func send(_ bytes:Data,completion:@escaping (Bool)->Void) {writes.append(bytes);write=completion;if inlineWrite {completion(true)};trace.append("write-return")}
        func cancel() {cancels += 1;if inlineCancel {state?(.cancelled)};trace.append("cancel-return")}
    }
    private final class Fixture {
        let queue=DispatchQueue(label:"test.web.native"),pipe=Pipe()
        var enabled=true,factories=0,transport:WebConnection.Transport?
        func on(_ body:()->Void) {queue.sync(execute:body)}
        func drain() {for _ in 0..<20 {queue.sync {}}}
        func start(_ hook:(()->Void)?=nil) {on {transport=WebNativeTransport.make(queue:queue,permitted:{[weak self] in self?.enabled ?? false},factory:{[self] gate in factories += 1;XCTAssertTrue(gate());hook?();return pipe})};drain()}
        func cleanup() {on {transport?.close {};transport=nil};drain();on {pipe.read?(nil,false,true);pipe.write?(false);pipe.state?(.cancelled)};drain();on {pipe.read=nil;pipe.write=nil;pipe.state=nil}}
    }
    func testOffBeforeFactory() {
        let f=Fixture();defer {f.cleanup()};f.enabled=false;f.start();f.on {XCTAssertNil(f.transport);XCTAssertEqual(f.factories,0);XCTAssertEqual(f.pipe.starts,0)}
    }
    func testReadAndWriteWaitForReadyAndReturnOnOwnerAfterRawReturn() {
        let f=Fixture();defer {f.cleanup()};f.pipe.ready=false;f.start();var received=false
        f.on {XCTAssertNotNil(f.transport);f.transport?.read(maximum:12) {_ in received=true;XCTAssertEqual(f.pipe.trace.last,"read-return")}};f.drain();f.on {XCTAssertTrue(f.pipe.maximums.isEmpty);f.pipe.inlineRead=true;f.pipe.state?(.ready)};f.drain()
        f.on {XCTAssertTrue(received);XCTAssertEqual(f.pipe.maximums,[12]);f.pipe.inlineWrite=true;f.transport?.write(Data([2])) {XCTAssertEqual($0,1);XCTAssertEqual(f.pipe.trace.last,"write-return")}};f.drain();f.on {XCTAssertEqual(f.pipe.writes,[Data([2])])}
    }
    func testCapsBeforeQueueAndOnePendingOperationPerLane() {
        let f=Fixture();defer {f.cleanup()};f.start();var refusals=0
        f.on {for n in [0,-1,16385,Int.max] {f.transport?.read(maximum:n) {if case .failed=$0 {refusals += 1}}};for n in [0,16385] {f.transport?.write(Data(repeating:0,count:n)) {if $0==nil {refusals += 1}}}};f.drain()
        f.on {XCTAssertEqual(refusals,6);XCTAssertTrue(f.pipe.maximums.isEmpty);XCTAssertTrue(f.pipe.writes.isEmpty);f.transport?.read(maximum:16384) {_ in};f.transport?.write(Data([1])) {if $0==nil {refusals += 1}}};f.drain();f.on {XCTAssertEqual(f.pipe.maximums,[16384]);XCTAssertEqual(f.pipe.writes,[Data([1])]);XCTAssertEqual(refusals,6)}
    }
    func testDataWithEOFOrFailurePreservesBytesAndTerminal() {
        for failed in [false,true] {let f=Fixture();f.start();var answer:WebConnection.Read?
            f.on {f.transport?.read(maximum:4) {answer=$0}};f.drain();f.on {f.pipe.read?(Data([7,8]),true,failed)};f.drain()
            f.on {switch answer {case .ending(let data,let error):XCTAssertEqual(data,Data([7,8]));XCTAssertEqual(error,failed);default:XCTFail("Missing data and terminal receipt")};f.transport?.read(maximum:4) {switch $0 {case .end:XCTAssertFalse(failed);case .failed:XCTAssertTrue(failed);default:XCTFail("Read after terminal")}}};f.drain();f.on {XCTAssertEqual(f.pipe.maximums.count,1)};f.cleanup()
        }
    }
    func testEmptyOrOversizedNativeDataFailsClosed() {
        for data in [Data(),Data(repeating:0,count:5)] {let f=Fixture();f.start();var failures=0;f.on {f.transport?.read(maximum:4) {if case .failed=$0 {failures += 1}}};f.drain();f.on {f.pipe.read?(data,false,false)};f.drain();f.on {XCTAssertEqual(failures,1);XCTAssertEqual(f.pipe.cancels,1)};f.cleanup()}
    }
    func testFinalCancelledMustAlsoRetirePendingReadCallback() {
        let f=Fixture();defer {f.cleanup()};f.start();var closed=0,reads=0
        f.on {f.transport?.read(maximum:4) {_ in reads += 1}};f.drain();f.on {f.transport?.close {closed += 1}};f.drain();f.on {XCTAssertEqual(f.pipe.cancels,1);f.pipe.state?(.cancelled)};f.drain();f.on {XCTAssertEqual(closed,0);f.pipe.read?(nil,false,true)};f.drain();f.on {XCTAssertEqual(reads,1);XCTAssertEqual(closed,1)}
    }
    func testCallbackRetirementAloneDoesNotConfirmClose() {
        let f=Fixture();defer {f.cleanup()};f.start();var closed=0
        f.on {f.transport?.write(Data([1])) {_ in}};f.drain();f.on {f.transport?.close {closed += 1}};f.drain();f.on {f.pipe.write?(false)};f.drain();f.on {XCTAssertEqual(closed,0);f.pipe.state?(.failed)};f.drain();f.on {XCTAssertEqual(closed,0);f.pipe.state?(.cancelled)};f.drain();f.on {XCTAssertEqual(closed,1)}
    }
    func testDuplicateAndStaleCallbacksCannotConsumeNewIO() {
        let f=Fixture();defer {f.cleanup()};f.start();var reads=0;var old:((Data?,Bool,Bool)->Void)?
        f.on {f.transport?.read(maximum:4) {_ in reads += 1}};f.drain();f.on {old=f.pipe.read;old?(Data([1]),false,false);old?(Data([2]),false,false)};f.drain()
        f.on {f.transport?.read(maximum:4) {_ in reads += 1}};f.drain();f.on {old?(Data([3]),false,false)};f.drain();f.on {XCTAssertEqual(reads,1);f.pipe.read?(Data([4]),false,false)};f.drain();f.on {XCTAssertEqual(reads,2)}
    }
    func testPermissionLossAndWrapperReleaseRetainExactCancellation() {
        let f=Fixture();defer {f.cleanup()};f.start();var closed=0
        f.on {f.enabled=false;f.transport?.read(maximum:4) {_ in};f.transport?.close {closed += 1};f.transport=nil};f.drain();f.on {XCTAssertTrue(f.pipe.maximums.isEmpty);XCTAssertEqual(f.pipe.cancels,1);XCTAssertEqual(closed,0);f.pipe.state?(.cancelled)};f.drain();f.on {XCTAssertEqual(closed,1)}
    }
    func testLateFactoryPermissionLossClosesWithoutIO() {
        let f=Fixture();defer {f.cleanup()};f.start {f.enabled=false};f.on {XCTAssertNotNil(f.transport);XCTAssertEqual(f.pipe.starts,1);XCTAssertEqual(f.pipe.cancels,1);XCTAssertTrue(f.pipe.maximums.isEmpty);XCTAssertTrue(f.pipe.writes.isEmpty)}
    }
    func testSendFailureNeverReportsPartialOrRetries() {
        let f=Fixture();defer {f.cleanup()};f.start();var answers=[Int?]()
        f.on {f.transport?.write(Data([1,2,3])) {answers.append($0)}};f.drain();f.on {f.pipe.write?(false);f.pipe.write?(true)};f.drain();f.on {XCTAssertEqual(answers.count,1);XCTAssertTrue(answers.first.map({$0==nil}) ?? false);XCTAssertEqual(f.pipe.writes.count,1);XCTAssertEqual(f.pipe.cancels,1)}
    }
    func testCancelBeforeReadyReturnsPendingCallbackBeforeCloseReceipt() {
        let f=Fixture();defer {f.cleanup()};f.pipe.ready=false;f.start();var reads=0,closed=0
        f.on {f.transport?.read(maximum:4) {_ in reads += 1}};f.drain();f.on {f.transport?.close {closed += 1}};f.drain();f.on {f.pipe.state?(.cancelled)};f.drain();f.on {XCTAssertEqual(reads,1);XCTAssertEqual(closed,1);XCTAssertTrue(f.pipe.maximums.isEmpty)}
    }
    func testForeignQueueReceiptIsMarshalledAndCloseWaitsRawMethodReturn() {
        let f=Fixture();defer {f.cleanup()};f.start();let key=DispatchSpecificKey<Int>();f.queue.setSpecific(key:key,value:1);var replies=0;var deliver:((Data?,Bool,Bool)->Void)?
        f.on {f.transport?.read(maximum:4) {_ in XCTAssertEqual(DispatchQueue.getSpecific(key:key),1);replies += 1}};f.drain();f.on {deliver=f.pipe.read}
        let sent=expectation(description:"foreign callback returned"),callback=deliver
        DispatchQueue.global().async {callback?(Data([1]),false,false);sent.fulfill()};wait(for:[sent],timeout:2);f.drain();f.on {XCTAssertEqual(replies,1)}
    }
    func testInlineCancellationReceiptRunsAfterRawReturnAndCoalesces() {
        let f=Fixture();defer {f.cleanup()};f.pipe.inlineCancel=true;f.start();var closed=0
        f.on {f.transport?.close {closed += 1;XCTAssertEqual(f.pipe.trace.last,"cancel-return")};f.transport?.close {closed += 1}};f.drain();f.on {XCTAssertEqual(closed,2);XCTAssertEqual(f.pipe.cancels,1);f.transport?.close {closed += 1}};f.drain();f.on {XCTAssertEqual(closed,3)}
    }
    func testNativeConvenienceRefusesIsolatedBeforeStartingOwnedConnection() throws {
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]!).appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let runtime=try RuntimeConfiguration(options:LaunchOptions.parse(["--config-dir",root.path,"--headless","--silent"]))
        let queue=DispatchQueue(label:"test.web.native.refusal"),connection=NWConnection(host:.ipv4(.loopback),port:9,using:.tcp)
        queue.sync {XCTAssertNil(WebNativeTransport.accepted(connection,runtime:runtime,queue:queue,permitted:{true}));XCTAssertNil(WebNativeTransport.loopback(connection,queue:queue,permitted:{false}))}
        XCTAssertEqual(connection.state,.setup)
        connection.cancel()
    }
    func testExternalOrUnresolvedEndpointRefusesWithoutStart() {
        let queue=DispatchQueue(label:"test.web.native.identity")
        for host:NWEndpoint.Host in [.ipv4(IPv4Address("192.0.2.1")!),.name("example.invalid",nil)] {
            let connection=NWConnection(host:host,port:9,using:.tcp)
            queue.sync {XCTAssertNil(WebNativeTransport.loopback(connection,queue:queue,permitted:{true}))};XCTAssertEqual(connection.state,.setup);connection.cancel()
        }
    }
    func testFiniteSchedulerRefusesOffInvalidClockAndStopsAfterCancellation() {
        let queue=DispatchQueue(label:"test.web.native.timer"),tick=expectation(description:"finite product pulse"),quiet=expectation(description:"cancelled product timer drained")
        var count=0,stop:(()->Void)?
        queue.sync {
            XCTAssertNil(WebNativeTransport.schedule(permitted:{false})(queue,{}))
            for clock in [-1.0,Double.nan,Double.infinity,Double.greatestFiniteMagnitude] {XCTAssertNil(WebNativeTransport.schedule(permitted:{true},clock:{clock})(queue,{}))}
            stop=WebNativeTransport.schedule(permitted:{true})(queue,{count += 1;stop?();tick.fulfill()})
        }
        wait(for:[tick],timeout:2)
        queue.asyncAfter(deadline:.now()+0.08) {XCTAssertEqual(count,1);stop=nil;quiet.fulfill()};wait(for:[quiet],timeout:2)
    }
    func testActualOwnedSpareLoopbackReadsFinalBytesAndWaitsNativeCancellation() throws {
        let queue=DispatchQueue(label:"test.web.native.owned-loopback"),accepted=expectation(description:"owned connection final bytes and cancellation"),listenerClosed=expectation(description:"owned listener retired"),clientClosed=expectation(description:"owned client retired")
        let parameters=NWParameters.tcp;parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:.any)
        let listener=try NWListener(using:parameters)
        var client:NWConnection?,transport:WebConnection.Transport?,closed=false
        listener.stateUpdateHandler={state in
            switch state {
            case .ready:
                guard let port=listener.port else {XCTFail("Missing spare port");listener.cancel();accepted.fulfill();return}
                let connection=NWConnection(host:.ipv4(.loopback),port:port,using:.tcp);client=connection
                connection.stateUpdateHandler={state in
                    switch state {
                    case .ready:connection.send(content:Data([41,42]),contentContext:.finalMessage,isComplete:true,completion:.contentProcessed {error in XCTAssertNil(error)})
                    case .cancelled:clientClosed.fulfill()
                    default:break
                    }
                };connection.start(queue:queue)
            case .cancelled:listenerClosed.fulfill()
            case .failed(let error):XCTFail("Owned listener failed: \(error)");listener.cancel();accepted.fulfill()
            default:break
            }
        }
        listener.newConnectionHandler={connection in
            XCTAssertNil(transport)
            transport=WebNativeTransport.loopback(connection,queue:queue,permitted:{true})
            guard let owned=transport else {XCTFail("Owned loopback identity refused");connection.cancel();accepted.fulfill();return}
            var bytes=Data()
            func receive() {
                owned.read(maximum:4) {result in
                    switch result {
                    case .bytes(let data):bytes.append(data);receive()
                    case .ending(let data,let failed):XCTAssertFalse(failed);bytes.append(data);finish()
                    case .end:finish()
                    default:XCTFail("Unexpected owned loopback receive");finish()
                    }
                }
            }
            func finish() {
                XCTAssertEqual(bytes,Data([41,42]));owned.close {XCTAssertFalse(closed);closed=true;transport=nil;client?.cancel();listener.cancel();accepted.fulfill()}
            }
            receive()
        }
        listener.start(queue:queue)
        wait(for:[accepted,listenerClosed,clientClosed],timeout:5)
        queue.sync {transport?.close {};transport=nil;client?.cancel();listener.cancel();listener.newConnectionHandler=nil;listener.stateUpdateHandler=nil;client?.stateUpdateHandler=nil;client=nil}
        XCTAssertTrue(closed)
    }

    func testSchedulerDeadlineAndBackwardClockEmitOneFinalPulseThenRetire() {
        for final in [99.0,145.0,Double.nan] {
            let queue=DispatchQueue(label:"test.web.native.finite-clock"),done=expectation(description:"retired finite product driver"),quiet=expectation(description:"no idle timer"),key=DispatchSpecificKey<Int>()
            queue.setSpecific(key:key,value:1);var now=100.0,count=0,stop:(()->Void)?
            queue.sync {stop=WebNativeTransport.schedule(permitted:{true},clock:{XCTAssertEqual(DispatchQueue.getSpecific(key:key),1);return now})(queue,{count += 1;done.fulfill()});now=final}
            wait(for:[done],timeout:2);queue.asyncAfter(deadline:.now()+0.06) {XCTAssertEqual(count,1);stop?();stop=nil;quiet.fulfill()};wait(for:[quiet],timeout:2)
        }
    }
    func testActualAdmissionNativePageAndProductDriverRetireOnOwnedLoopback() throws {
        let queue=DispatchQueue(label:"test.web.native.actual-admission"),finished=expectation(description:"actual HTTP driver closed"),received=expectation(description:"owned client response ended"),serverClosed=expectation(description:"page listener retired"),clientClosed=expectation(description:"page client retired")
        let parameters=NWParameters.tcp;parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:.any)
        let listener=try NWListener(using:parameters)
        let credential=WebAuthentication.Credential.make(password:"synthetic",salt:Data(repeating:0,count:16),derive:{_,_ in Data(repeating:1,count:32)})!,failures=WebAuthentication.Failures()
        var client:NWConnection?,control:WebConnection.Control?,response=Data(),completed=false
        listener.stateUpdateHandler={state in
            switch state {
            case .ready:
                guard let port=listener.port else {XCTFail("Missing page spare port");return}
                let connection=NWConnection(host:.ipv4(.loopback),port:port,using:.tcp);client=connection
                connection.stateUpdateHandler={state in
                    switch state {
                    case .ready:
                        connection.send(content:Data("GET / HTTP/1.1\r\nHost: example.test\r\n\r\n".utf8),contentContext:.finalMessage,isComplete:true,completion:.contentProcessed {XCTAssertNil($0)})
                        func read() {
                            connection.receive(minimumIncompleteLength:1,maximumLength:1024) {data,_,end,error in
                                XCTAssertNil(error);if let data {response.append(data)};XCTAssertLessThanOrEqual(response.count,4096)
                                if end || error != nil {XCTAssertTrue(String(decoding:response,as:UTF8.self).hasSuffix("fixed-page"));received.fulfill();connection.cancel();listener.cancel()} else {read()}
                            }
                        };read()
                    case .cancelled:clientClosed.fulfill()
                    default:break
                    }
                };connection.start(queue:queue)
            case .cancelled:serverClosed.fulfill()
            case .failed(let error):XCTFail("Page listener failed: \(error)");listener.cancel()
            default:break
            }
        }
        listener.newConnectionHandler={connection in
            XCTAssertNil(control)
            control=WebConnection.start(queue:queue,permitted:{true},admission:{WebAdmission.Visit.make(credential:credential,failures:failures,page:Data("fixed-page".utf8),policy:.init(hosts:["example.test"],origins:[]),permitted:{true},current:{credential},clock:{ProcessInfo.processInfo.systemUptime})},transport:{gate in
                guard gate() else {return nil};return WebNativeTransport.loopback(connection,queue:queue,permitted:{true})
            },schedule:WebNativeTransport.schedule(permitted:{true}),completion:{result in
                if case .closed(.pageDone)=result {completed=true} else {XCTFail("Actual page did not close truthfully")};finished.fulfill()
            })
        }
        listener.start(queue:queue);wait(for:[finished,received,serverClosed,clientClosed],timeout:5)
        queue.sync {_ = control?.cancel();control=nil;client?.cancel();listener.cancel();client?.stateUpdateHandler=nil;listener.newConnectionHandler=nil;listener.stateUpdateHandler=nil;client=nil;XCTAssertTrue(completed)}
    }

    func testActualNativePendingReadRetiresBeforeOwnedCloseReceipt() throws {
        let queue=DispatchQueue(label:"test.web.native.pending-cancel"),closed=expectation(description:"native pending read and close retired"),listenerClosed=expectation(description:"cancel listener retired"),clientClosed=expectation(description:"cancel client retired")
        let parameters=NWParameters.tcp;parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:.any)
        let listener=try NWListener(using:parameters)
        var client:NWConnection?,transport:WebConnection.Transport?,secondReply=false
        listener.stateUpdateHandler={state in
            switch state {
            case .ready:
                guard let port=listener.port else {XCTFail("Missing cancel spare port");return}
                let connection=NWConnection(host:.ipv4(.loopback),port:port,using:.tcp);client=connection
                connection.stateUpdateHandler={state in
                    switch state {case .ready:connection.send(content:Data([1]),completion:.contentProcessed {XCTAssertNil($0)});case .cancelled:clientClosed.fulfill();default:break}
                };connection.start(queue:queue)
            case .cancelled:listenerClosed.fulfill()
            case .failed(let error):XCTFail("Cancel listener failed: \(error)");listener.cancel()
            default:break
            }
        }
        listener.newConnectionHandler={connection in
            transport=WebNativeTransport.loopback(connection,queue:queue,permitted:{true})
            guard let owned=transport else {XCTFail("Cancel connection refused");connection.cancel();return}
            owned.read(maximum:1) {result in
                if case .bytes(let data)=result {XCTAssertEqual(data,Data([1]))} else {XCTFail("First owned byte missing")}
                owned.read(maximum:1) {result in if case .failed=result {secondReply=true} else {XCTFail("Pending cancel callback truth missing")}}
                queue.asyncAfter(deadline:.now()+0.02) {owned.close {XCTAssertTrue(secondReply);transport=nil;client?.cancel();listener.cancel();closed.fulfill()}}
            }
        }
        listener.start(queue:queue);wait(for:[closed,listenerClosed,clientClosed],timeout:5)
        queue.sync {transport?.close {};transport=nil;client?.cancel();listener.cancel();listener.newConnectionHandler=nil;listener.stateUpdateHandler=nil;client?.stateUpdateHandler=nil;client=nil;XCTAssertTrue(secondReply)}
    }

}
