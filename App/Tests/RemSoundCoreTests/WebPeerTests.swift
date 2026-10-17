import Foundation
import Network
import XCTest
@testable import RemSoundCore
final class WebPeerTests:XCTestCase {
    private final class Pipe:WebConnection.Transport {
        var readReply:((WebConnection.Read)->Void)?,writeReply:((Int?)->Void)?,closeReply:(()->Void)?
        var reads=0,writes=[Data](),closes=0,holdWrite=false,holdClose=false
        func read(maximum:Int,completion:@escaping (WebConnection.Read)->Void) {reads += 1;readReply=completion}
        func write(_ bytes:Data,completion:@escaping (Int?)->Void) {writes.append(bytes);writeReply=completion;if !holdWrite {completion(bytes.count)}}
        func close(completion:@escaping ()->Void) {closes += 1;closeReply=completion;if !holdClose {retire()}}
        func supply(_ result:WebConnection.Read) {let callback=readReply;readReply=nil;callback?(result)}
        func retire() {let read=readReply,write=writeReply,close=closeReply;readReply=nil;writeReply=nil;closeReply=nil;read?(.failed);write?(nil);close?()}
    }
    private final class Incoming:WebRoom.Incoming {
        let pipe=Pipe();var factories=0,closes=0,transfers=true,holdClose=false,closeReply:(()->Void)?,hook:(()->Void)?,lifetime:(()->Bool)?
        func transport(permitted:@escaping ()->Bool)->WebConnection.Transport? {factories += 1;lifetime=permitted;XCTAssertTrue(permitted());hook?();return transfers ? pipe:nil}
        func close(completion:@escaping ()->Void) {closes += 1;closeReply=completion;if !holdClose {retire()}}
        func retire() {let callback=closeReply;closeReply=nil;callback?()}
    }
    private final class Listener:WebRoom.Listener {
        var offer:((WebRoom.Incoming)->Bool)?,closeReply:(()->Void)?,starts=0,closes=0,holdClose=false,startHook:(()->Void)?
        func start(offer:@escaping (WebRoom.Incoming)->Bool,failed:@escaping ()->Void) {starts += 1;self.offer=offer;startHook?()}
        func close(completion:@escaping ()->Void) {closes += 1;closeReply=completion;if !holdClose {retire()}}
        func retire() {let callback=closeReply;closeReply=nil;callback?()}
    }
    private final class Fixture {
        let queue=DispatchQueue(label:"test.web.room"),key=DispatchSpecificKey<Int>(),listener=Listener()
        let credential=WebAuthentication.Credential.make(password:"synthetic",salt:Data(repeating:0,count:16),derive:{_,_ in Data(repeating:1,count:32)})!
        var room:WebRoom.Service!,enabled=true,now=100.0,proof=true,configs=0,factories=0,stops=0,pulses=[UUID:()->Void](),incoming=[Incoming]()
        var peerHook:(()->Void)?,configHook:(()->Void)?,factoryHook:(()->Void)?,factoryReturns=true,source="fixed",isolated=false
        init(isolated:Bool=false,enabled:Bool=true) {
            self.isolated=isolated;self.enabled=enabled;queue.setSpecific(key:key,value:1)
            room=WebRoom.Service(queue:queue,isolated:isolated,permitted:{[weak self] in self?.enabled ?? false},listener:{[weak self] gate in
                guard let self else {return nil};XCTAssertTrue(gate());self.factories += 1;self.factoryHook?();return self.factoryReturns ? self.listener:nil
            },clock:{[weak self] in self?.now ?? .nan},schedule:{[weak self] _,pulse in
                guard let self else {return nil};let id=UUID();self.pulses[id]=pulse;return {[weak self] in self?.stops += 1;self?.pulses[id]=nil}
            },peerSchedule:{[weak self] _,pulse in guard let self else {return nil};self.peerHook?();let id=UUID();self.pulses[id]=pulse;return {[weak self] in self?.stops += 1;self?.pulses[id]=nil}},random:{Data(repeating:2,count:$0)},verify:{[weak self] _,_ in self?.proof ?? false})
        }
        func on(_ body:()->Void) {queue.sync(execute:body)}
        func drain() {for _ in 0..<32 {queue.sync {}}}
        @discardableResult func start()->Bool {var result=false;on {result=room.start(configuration:{[self] in configs += 1;configHook?();return .init(credential:credential,page:Data("fixed".utf8),policy:.init(hosts:["example.test:47840"],origins:["https://example.test"]),source:source)})};drain();return result}
        @discardableResult func offer()->Incoming {let value=Incoming();incoming.append(value);on {XCTAssertTrue(listener.offer?(value) ?? false)};drain();return value}
        func authenticate(_ value:Incoming) {on {value.pipe.supply(.bytes(Self.head))};drain();on {value.pipe.supply(.bytes(Self.answer))};drain()}
        static var head:Data {Data("GET /listen HTTP/1.1\r\nHost: example.test:47840\r\nOrigin: https://example.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n".utf8)}
        static var answer:Data {let data=Data("{\"response\":\"\(Data(repeating:1,count:32).base64EncodedString())\"}".utf8);return Data([0x81,0x80|UInt8(data.count),0,0,0,0])+data}
        func cleanup() {on {_ = room?.shutdown();for v in incoming {v.pipe.holdClose=false;v.holdClose=false;v.pipe.retire();v.retire()};listener.holdClose=false;listener.retire()};drain();on {for v in incoming {v.pipe.retire();v.retire()};listener.retire();room=nil};drain()}
    }
    private func frame(_ opcode:UInt8,_ bytes:Data)->Data {
        var result=Data([0x80|opcode]);if bytes.count<126 {result.append(0x80|UInt8(bytes.count))} else {result.append(contentsOf:[0xfe,UInt8(bytes.count>>8),UInt8(bytes.count&255)])};result.append(contentsOf:[0,0,0,0]);result.append(bytes);return result
    }
    private func json(_ object:[String:Any])->Data {(try? JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])) ?? Data()}
    private func connected(_ f:Fixture)->Incoming {XCTAssertTrue(f.start());let value=f.offer();f.authenticate(value);f.on {XCTAssertEqual(f.room.snapshot?.welcomed,1)};return value}
    private func pulse(_ f:Fixture,_ now:Double) {f.on {f.now=now;for action in Array(f.pulses.values) {action()}};f.drain()}
    private func messages(_ value:Incoming)->[[String:Any]] {value.pipe.writes.compactMap {wire in guard case .text(let data)=WebSocketPackets.Reader(fromClient:false).feed(wire).event else {return nil};return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]}}
    func testNumericReportIsBoundedRoundedAndDoesNotReturnRawStrings() {
        let data=json(["type":"report","streams":[["id":1,"depthMs":2.5,"targetMs":3.5,"gaps":-9,"skips":2000000,"longestWaitMs":"secret"]],"outMs":true,"rate":48000,"reconnects":-10,"unknown":"untrusted"])
        guard case .report(let report)=WebPeer.message(data) else {XCTFail("Missing typed report");return}
        XCTAssertEqual(report.streams,[.init(id:1,depthMs:2,targetMs:4,longestWaitMs:0,gaps:-1,skips:1000000)]);XCTAssertEqual(report.outMs,0);XCTAssertEqual(report.rate,48000);XCTAssertEqual(report.reconnects,0)
    }
    func testMessageBoundsDepthBooleansUnknownAndPongIntegers() {
        XCTAssertEqual(WebPeer.message(json(["type":"pong","t":100000])),.pong(100000))
        for data in [Data(repeating:0,count:8193),Data("{\"type\":\"pong\",\"t\":true}".utf8),Data("{\"type\":\"pong\",\"t\":1.5}".utf8),Data((String(repeating:"[",count:65)+String(repeating:"]",count:65)).utf8),json(["type":"quit"])] {XCTAssertEqual(WebPeer.message(data),.ignored)}
        let rows=Array(repeating:["id":1],count:30);if case .report(let report)=WebPeer.message(json(["type":"report","streams":rows])) {XCTAssertEqual(report.streams.count,4)} else {XCTFail("Bounded report missing")}
    }
    func testRoomStartsPostAuthReadAndPublishesOnlyNumericReportValues() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f)
        f.on {XCTAssertEqual(value.pipe.reads,3);value.pipe.supply(.bytes(frame(1,json(["type":"report","outMs":12,"rate":48000,"reconnects":2]))))};f.drain()
        f.on {XCTAssertEqual(f.room.peers?.first?.report?.outMs,12);XCTAssertEqual(f.room.peers?.first?.report?.reconnects,2);XCTAssertEqual(f.room.peers?.first?.answersBack,true);XCTAssertEqual(value.pipe.reads,4)}
    }
    func testPingPongWriteRunsWhileNextReadIsPending() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f)
        f.on {value.pipe.supply(.bytes(frame(9,Data([7]))))};f.drain();f.on {XCTAssertEqual(value.pipe.writes.last,Data([0x8a,1,7]));XCTAssertEqual(value.pipe.reads,4);XCTAssertEqual(value.pipe.closes,0)}
    }
    func testIdleAliveAndWebSocketPingAreActiveOnlyAndDoNotBlockRead() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);pulse(f,102)
        f.on {XCTAssertEqual(messages(value).filter({$0["type"] as? String=="idle"}).count,1)};pulse(f,105)
        f.on {XCTAssertEqual(messages(value).filter({$0["type"] as? String=="alive"}).count,1);XCTAssertEqual(value.pipe.reads,3);XCTAssertTrue(f.room.audioActivity())};f.drain()
        f.on {XCTAssertEqual(messages(value).filter({$0["type"] as? String=="active"}).count,1)};pulse(f,115)
        f.on {XCTAssertTrue(value.pipe.writes.contains(Data([0x89,0])));_ = f.room.stop()};f.drain();f.on {XCTAssertEqual(f.pulses.count,0)}
    }
    func testUnknownTextAndBinaryNeverBecomeCommandsOrAnsweredState() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f)
        f.on {value.pipe.supply(.bytes(frame(1,json(["type":"quit","password":"ignored"]))+frame(2,Data([1,2,3]))))};f.drain();pulse(f,121)
        f.on {XCTAssertEqual(f.room.snapshot?.welcomed,1);XCTAssertEqual(f.room.peers?.first?.answersBack,false);XCTAssertNil(f.room.peers?.first?.report);XCTAssertEqual(value.pipe.closes,0)}
    }
    func testOnlyIssuedTypedPongCanAddOneRoundTrip() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);pulse(f,105)
        f.on {value.pipe.supply(.bytes(frame(1,json(["type":"pong","t":105000]))))};f.drain()
        f.on {XCTAssertEqual(f.room.peers?.first?.roundTrips,[0]);value.pipe.supply(.bytes(frame(1,json(["type":"pong","t":105000]))+frame(1,json(["type":"pong","t":999999]))))};f.drain();f.on {XCTAssertEqual(f.room.peers?.first?.roundTrips,[0])}
    }
    func testPreviouslyAnsweredSilentClientKeepsSeatUntilQuiescence() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);f.on {value.pipe.supply(.bytes(frame(1,json(["type":"report"]))))};f.drain();value.pipe.holdClose=true;pulse(f,121)
        f.on {XCTAssertEqual(value.pipe.closes,1);XCTAssertEqual(f.room.snapshot?.seats,1);value.pipe.retire()};f.drain();f.on {XCTAssertEqual(f.room.snapshot?.seats,0)}
    }
    func testFinalCloseWithEOFEchoesOnceWithoutDoubleParsingAndWaitsRetirement() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);value.pipe.holdWrite=true;value.pipe.holdClose=true
        f.on {value.pipe.supply(.ending(frame(8,Data([3,232])),failed:false))};f.drain();f.on {XCTAssertEqual(value.pipe.writes.last,Data([0x88,2,3,232]));XCTAssertEqual(value.pipe.closes,0);value.pipe.writeReply?(4)};f.drain()
        f.on {XCTAssertEqual(value.pipe.closes,1);XCTAssertEqual(f.room.snapshot?.seats,1);value.pipe.retire()};f.drain();f.on {XCTAssertEqual(f.room.snapshot?.seats,0);XCTAssertEqual(value.pipe.writes.filter({$0==Data([0x88,2,3,232])}).count,1)}
    }
    func testOrdinaryCloseWaitsOwnedControlWriteThenExactEcho() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);value.pipe.holdWrite=true
        f.on {value.pipe.supply(.bytes(frame(9,Data([7]))))};f.drain();var first:((Int?)->Void)?
        f.on {first=value.pipe.writeReply;value.pipe.supply(.bytes(frame(8,Data([3,232]))))};f.drain();f.on {XCTAssertEqual(value.pipe.writes.last,Data([0x8a,1,7]));first?(3)};f.drain()
        f.on {XCTAssertEqual(value.pipe.writes.last,Data([0x88,2,3,232]));value.pipe.writeReply?(4)};f.drain();f.on {XCTAssertEqual(f.room.snapshot?.seats,0)}
    }
    func testReadEventAndControlQueueBudgetsFailClosed() {
        for count in [20,33] {let f=Fixture();let value=connected(f);value.pipe.holdWrite=true
            let data=(0..<count).reduce(into:Data()) {data,_ in data.append(frame(count==20 ? 9:2,Data()))}
            f.on {value.pipe.supply(.bytes(data))};f.drain();f.on {XCTAssertEqual(value.pipe.closes,1);XCTAssertEqual(f.room.snapshot?.welcomed,0)};f.cleanup()
        }
    }
    func testStopWithPendingDuplexIOWaitsBothCallbacksAndCleansDriver() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);value.pipe.holdWrite=true;value.pipe.holdClose=true;var stopped=0
        f.on {value.pipe.supply(.bytes(frame(9,Data([7]))))};f.drain();f.on {_ = f.room.stop {stopped += 1}};f.drain();f.on {XCTAssertEqual(stopped,0);XCTAssertEqual(f.pulses.count,0);value.pipe.retire()};f.drain();f.on {XCTAssertEqual(stopped,1);XCTAssertEqual(f.room.snapshot?.state,.off)}
    }

    func testEOFWhileOwnedWriteAndQueuedControlWaitsExactResponseWithoutRetry() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);value.pipe.holdWrite=true;value.pipe.holdClose=true;var first:((Int?)->Void)?
        f.on {value.pipe.supply(.bytes(frame(9,Data([1]))+frame(9,Data([2]))))};f.drain()
        f.on {first=value.pipe.writeReply;value.pipe.supply(.ending(frame(8,Data([3,232])),failed:false))};f.drain();f.on {XCTAssertEqual(value.pipe.writes.last,Data([0x8a,1,1]));first?(3)};f.drain()
        f.on {XCTAssertEqual(value.pipe.writes.last,Data([0x88,2,3,232]));value.pipe.writeReply?(4)};f.drain();f.on {XCTAssertEqual(value.pipe.writes.filter({$0==Data([0x8a,1,2])}).count,0);value.pipe.retire()};f.drain();f.on {XCTAssertEqual(f.room.snapshot?.seats,0)}
    }
    func testControlDeadlineStopsActiveDriverButKeepsSeatUntilReceipts() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);value.pipe.holdWrite=true;value.pipe.holdClose=true
        f.on {value.pipe.supply(.bytes(frame(9,Data([1]))))};f.drain();pulse(f,103)
        f.on {XCTAssertEqual(value.pipe.closes,1);XCTAssertEqual(f.room.snapshot?.seats,1);XCTAssertEqual(f.pulses.count,0);value.pipe.retire()};f.drain();f.on {XCTAssertEqual(f.room.snapshot?.seats,0)}
    }
    func testLatePostAuthSchedulerCannotPublishOrStartReadAfterStopOrClockChange() {
        for mode in 0..<2 {let f=Fixture();XCTAssertTrue(f.start());f.peerHook={if mode==0 {_ = f.room.stop()} else {f.now=99}};let value=f.offer();f.authenticate(value)
            f.on {XCTAssertEqual(value.pipe.reads,2);XCTAssertEqual(f.room.snapshot?.welcomed,0);XCTAssertEqual(f.pulses.count,0);XCTAssertEqual(value.pipe.closes,1)};f.cleanup()
        }
    }
    func testOrdinaryClientOnlyCloseCodeReceivesOneEmptyServerClose() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f)
        f.on {value.pipe.supply(.bytes(frame(8,Data([3,242]))))};f.drain();f.on {XCTAssertEqual(value.pipe.writes.last,Data([0x88,0]));XCTAssertEqual(f.room.snapshot?.seats,0)}
    }
    func testAudioActivityRefusesOutsideActiveOwnerAndAfterStop() {
        let f=Fixture();defer {f.cleanup()};XCTAssertFalse(f.room.audioActivity());f.on {XCTAssertFalse(f.room.audioActivity())};let value=connected(f)
        f.on {XCTAssertTrue(f.room.audioActivity());_ = f.room.stop()};f.drain();f.on {XCTAssertFalse(f.room.audioActivity());XCTAssertEqual(value.pipe.closes,1)}
    }
    func testSilenceEdgeAndBackwardClockDoNotInventElapsedTime() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);f.on {value.pipe.supply(.bytes(frame(1,json(["type":"report"]))))};f.drain();pulse(f,120)
        f.on {XCTAssertEqual(value.pipe.closes,0)};pulse(f,119);f.on {XCTAssertEqual(value.pipe.closes,1);XCTAssertEqual(f.room.snapshot?.welcomed,0)}
    }
    func testActualOwnedLoopbackAdmissionPeerPingPongAndQuiescentCancel() throws {
        let queue=DispatchQueue(label:"test.web.ready.owned-loopback"),serverClosed=expectation(description:"Ready native resource retired"),listenerClosed=expectation(description:"Ready listener retired"),clientClosed=expectation(description:"Ready client retired")
        let parameters=NWParameters.tcp;parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:.any)
        let listener=try NWListener(using:parameters)
        let credential=WebAuthentication.Credential.make(password:"synthetic",salt:Data(repeating:0,count:16),derive:{_,_ in Data(repeating:1,count:32)})!,failures=WebAuthentication.Failures()
        var peer:WebPeer.Control?,client:NWConnection?,control:WebConnection.Control?,owned:WebConnection.Ready?,buffer=Data(),phase=0,processed=false,heard=false,closingStarted=false
        let frames=WebSocketPackets.Reader(fromClient:false),ping=Data([0x89,0x81,0,0,0,0,7])
        func finishIfBoth() {
            guard processed,heard,!closingStarted else {return};closingStarted=true
            XCTAssertTrue(peer?.cancel() ?? false)
        }
        listener.stateUpdateHandler={state in
            switch state {
            case .ready:
                guard let port=listener.port else {XCTFail("Missing owned Ready port");return}
                let connection=NWConnection(host:.ipv4(.loopback),port:port,using:.tcp);client=connection
                connection.stateUpdateHandler={state in
                    switch state {
                    case .ready:
                        connection.send(content:Fixture.head,completion:.contentProcessed {XCTAssertNil($0)})
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
                                        connection.send(content:Fixture.answer+ping,completion:.contentProcessed {XCTAssertNil($0)})
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
                peer=WebPeer.start(queue:queue,ready:ready,permitted:{true},clock:{ProcessInfo.processInfo.systemUptime},schedule:WebNativeTransport.schedule(permitted:{true}),started:{processed=true;finishIfBoth()},closed:{_ in owned=nil;client?.cancel();listener.cancel();serverClosed.fulfill()})
            })
        }
        listener.start(queue:queue);wait(for:[serverClosed,listenerClosed,clientClosed],timeout:5)
        queue.sync {_ = peer?.cancel();peer=nil;_ = owned?.close();owned=nil;_ = control?.cancel();control=nil;client?.cancel();listener.cancel();client?.stateUpdateHandler=nil;listener.newConnectionHandler=nil;listener.stateUpdateHandler=nil;client=nil;XCTAssertEqual(phase,3)}
    }


    func testClosingPeerIsNoLongerWelcomedButItsSeatStaysReserved() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);value.pipe.holdClose=true
        f.on {value.pipe.supply(.bytes(frame(1,json(["type":"report"]))))};f.drain();pulse(f,121)
        f.on {XCTAssertEqual(f.room.snapshot?.welcomed,0);XCTAssertEqual(f.room.snapshot?.seats,1);value.pipe.retire()};f.drain();f.on {XCTAssertEqual(f.room.snapshot?.seats,0)}
    }
}
