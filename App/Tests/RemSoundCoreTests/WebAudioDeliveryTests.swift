import Foundation
import AudioSupport
import Network
import XCTest
@testable import RemSoundCore
final class WebAudioDeliveryTests:XCTestCase {
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
    private final class Encoder:WebAudio.Encoder {
        var calls=0,closes=0,hook:(()->Void)?
        func encode(_ samples:[Float])->Data? {calls += 1;hook?();return Data([42])}
        func close() {closes += 1}
    }
    private final class Fixture {
        let queue=DispatchQueue(label:"test.web.room"),key=DispatchSpecificKey<Int>(),listener=Listener()
        let credential=WebAuthentication.Credential.make(password:"synthetic",salt:Data(repeating:0,count:16),derive:{_,_ in Data(repeating:1,count:32)})!
        let encoder=Encoder();var encoders=0,encoderHook:(()->Void)?
        var room:WebRoom.Service!,enabled=true,now=100.0,proof=true,configs=0,factories=0,stops=0,pulses=[UUID:()->Void](),incoming=[Incoming]()
        var peerHook:(()->Void)?,configHook:(()->Void)?,factoryHook:(()->Void)?,factoryReturns=true,source="fixed",isolated=false
        init(isolated:Bool=false,enabled:Bool=true) {
            self.isolated=isolated;self.enabled=enabled;queue.setSpecific(key:key,value:1)
            room=WebRoom.Service(queue:queue,isolated:isolated,permitted:{[weak self] in self?.enabled ?? false},listener:{[weak self] gate in
                guard let self else {return nil};XCTAssertTrue(gate());self.factories += 1;self.factoryHook?();return self.factoryReturns ? self.listener:nil
            },clock:{[weak self] in self?.now ?? .nan},schedule:{[weak self] _,pulse in
                guard let self else {return nil};let id=UUID();self.pulses[id]=pulse;return {[weak self] in self?.stops += 1;self?.pulses[id]=nil}
            },peerSchedule:{[weak self] _,pulse in guard let self else {return nil};self.peerHook?();let id=UUID();self.pulses[id]=pulse;return {[weak self] in self?.stops += 1;self?.pulses[id]=nil}},random:{Data(repeating:2,count:$0)},verify:{[weak self] _,_ in self?.proof ?? false},audioEncoder:{[weak self] in guard let self else {return nil};encoders += 1;encoderHook?();return encoder})
        }
        func on(_ body:()->Void) {queue.sync(execute:body)}
        func drain() {for _ in 0..<32 {queue.sync {}}}
        @discardableResult func start()->Bool {var result=false;on {result=room.start(configuration:{[self] in configs += 1;configHook?();return .init(credential:credential,page:Data("fixed".utf8),policy:.init(hosts:["example.test:47840"],origins:["https://example.test"]),source:source)})};drain();return result}
        @discardableResult func offer()->Incoming {let value=Incoming();incoming.append(value);on {XCTAssertTrue(listener.offer?(value) ?? false)};drain();return value}
        func authenticate(_ value:Incoming,pcm:Bool=false) {on {value.pipe.supply(.bytes(Self.head))};drain()
            let body=Data("{\"response\":\"\(Data(repeating:1,count:32).base64EncodedString())\",\"codec\":\"\(pcm ? "pcm16":"opus")\"}".utf8)
            let answer=Data([0x81,0x80|UInt8(body.count),0,0,0,0])+body
            on {value.pipe.supply(.bytes(answer))};drain()}
        @discardableResult func feed(_ samples:[Float],lane:WebAudio.Lane = .mixed,ticket:UUID?=nil)->Bool {var result=false;on {if let id=ticket ?? room.audioGeneration {result=room.feed(samples,lane:lane,generation:id)}};drain();return result}
        static var head:Data {Data("GET /listen HTTP/1.1\r\nHost: example.test:47840\r\nOrigin: https://example.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n".utf8)}
        static var answer:Data {let data=Data("{\"response\":\"\(Data(repeating:1,count:32).base64EncodedString())\"}".utf8);return Data([0x81,0x80|UInt8(data.count),0,0,0,0])+data}
        func cleanup() {on {_ = room?.shutdown();for v in incoming {v.pipe.holdClose=false;v.holdClose=false;v.pipe.retire();v.retire()};listener.holdClose=false;listener.retire()};drain();on {for v in incoming {v.pipe.retire();v.retire()};listener.retire();room=nil};drain()}
    }
    private func frame(_ opcode:UInt8,_ bytes:Data)->Data {
        var result=Data([0x80|opcode]);if bytes.count<126 {result.append(0x80|UInt8(bytes.count))} else {result.append(contentsOf:[0xfe,UInt8(bytes.count>>8),UInt8(bytes.count&255)])};result.append(contentsOf:[0,0,0,0]);result.append(bytes);return result
    }
    private func json(_ object:[String:Any])->Data {(try? JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])) ?? Data()}
    private func connected(_ f:Fixture)->Incoming {XCTAssertTrue(f.start());let value=f.offer();f.authenticate(value);f.on {XCTAssertEqual(f.room.snapshot?.welcomed,1);XCTAssertTrue(f.room.audioActivity())};f.drain();return value}
    private func pulse(_ f:Fixture,_ now:Double) {f.on {f.now=now;for action in Array(f.pulses.values) {action()}};f.drain()}
    private func messages(_ value:Incoming)->[[String:Any]] {value.pipe.writes.compactMap {wire in guard case .text(let data)=WebSocketPackets.Reader(fromClient:false).feed(wire).event else {return nil};return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]}}

    private let block=[Float](repeating:0.25,count:480)
    private func binary(_ value:Incoming)->[Data] {value.pipe.writes.compactMap {wire in if case .binary(let data)=WebSocketPackets.Reader(fromClient:false).feed(wire).event {return data};return nil}}
    private func sequence(_ bytes:Data?)->UInt32? {bytes.flatMap {WebAudioPackets.parse($0,codec:.opus)?.sequence}}
    func testNoOwnerOffIsolatedAndInvalidSamplesNeverConstructEncoder() {
        for isolated in [false,true] {let f=Fixture(isolated:isolated);defer {f.cleanup()};XCTAssertFalse(f.feed(block));f.on {XCTAssertNil(f.room.audioGeneration)};if !isolated {XCTAssertTrue(f.start());for values in [[],[1],[Float.nan,0],Array(repeating:Float(0),count:8194)] {XCTAssertFalse(f.feed(values))}};XCTAssertEqual(f.encoders,0)}
    }
    func testRoomCodecSelectionSharesOpusWorkAndProducesIndependentPCM() throws {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());let a=f.offer(),b=f.offer(),c=f.offer();f.authenticate(a);f.authenticate(b);f.authenticate(c,pcm:true)
        XCTAssertTrue(f.feed(block));XCTAssertEqual(f.encoders,1);XCTAssertEqual(f.encoder.calls,1)
        let x=try XCTUnwrap(binary(a).first),y=try XCTUnwrap(binary(b).first),z=try XCTUnwrap(binary(c).first);XCTAssertEqual(x,y);XCTAssertEqual(sequence(x),0);XCTAssertEqual(WebAudioPackets.parse(z,codec:.pcm16)?.payload,WebAudioPackets.pcm(block))
    }
    func testPendingProofAndWelcomeNeverCreateAudioDemand() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());let value=f.offer();value.pipe.holdWrite=true
        XCTAssertTrue(f.feed(block));XCTAssertEqual(f.encoders,0);f.on {value.pipe.supply(.bytes(Fixture.head))};f.drain();XCTAssertTrue(f.feed(block));XCTAssertEqual(f.encoders,0);XCTAssertTrue(binary(value).isEmpty)
    }
    func testPendingBrowserReadDoesNotBlockAudioWrite() throws {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);f.on {XCTAssertNotNil(value.pipe.readReply)};XCTAssertTrue(f.feed(block));XCTAssertEqual(sequence(binary(value).last),0);f.on {XCTAssertNotNil(value.pipe.readReply);XCTAssertEqual(value.pipe.closes,0)}
    }
    func testDropOldest32WaitingFramesPreservesOwnedInFlight() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);value.pipe.holdWrite=true
        for _ in 0..<41 {XCTAssertTrue(f.feed(block))}
        f.on {XCTAssertEqual(f.room.peers?.first?.queuedAudio,32);XCTAssertEqual(f.room.peers?.first?.droppedAudio,8);XCTAssertEqual(sequence(binary(value).first),0);value.pipe.writeReply?(value.pipe.writes.last?.count)};f.drain()
        f.on {XCTAssertEqual(sequence(binary(value).last),9);XCTAssertEqual(f.room.peers?.first?.queuedAudio,31)}
    }
    func testControlWaitsWholeOwnedAudioThenPrecedesQueuedAudio() throws {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);value.pipe.holdWrite=true;XCTAssertTrue(f.feed(block));let first=try XCTUnwrap(value.pipe.writes.last);XCTAssertTrue(f.feed(block))
        f.on {value.pipe.supply(.bytes(frame(9,Data([7]))));value.pipe.writeReply?(2)};f.drain();f.on {XCTAssertEqual(value.pipe.writes.last,Data(first.dropFirst(2)));value.pipe.writeReply?(first.count-2)};f.drain()
        f.on {XCTAssertEqual(value.pipe.writes.last,Data([0x8a,1,7]));value.pipe.writeReply?(3)};f.drain();f.on {XCTAssertEqual(sequence(binary(value).last),1)}
    }
    func testOrdinaryCloseDropsWaitingAudioButCompletesOwnedFrameBeforeEcho() throws {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);value.pipe.holdWrite=true;XCTAssertTrue(f.feed(block));XCTAssertTrue(f.feed(block));let first=try XCTUnwrap(value.pipe.writes.last)
        f.on {value.pipe.supply(.bytes(frame(8,Data([3,232]))));value.pipe.writeReply?(first.count)};f.drain();f.on {XCTAssertEqual(value.pipe.writes.last,Data([0x88,2,3,232]));XCTAssertEqual(f.room.peers?.first?.queuedAudio,0);value.pipe.writeReply?(4)};f.drain();XCTAssertEqual(binary(value).count,1)
    }
    func testFinalCloseEOFEchoWaitsWholeAudioAndDoesNotSendQueuedData() throws {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);value.pipe.holdWrite=true;value.pipe.holdClose=true;XCTAssertTrue(f.feed(block));XCTAssertTrue(f.feed(block));let first=try XCTUnwrap(value.pipe.writes.last)
        f.on {value.pipe.supply(.ending(frame(8,Data([3,232])),failed:false));value.pipe.writeReply?(first.count)};f.drain();f.on {XCTAssertEqual(value.pipe.writes.last,Data([0x88,2,3,232]));value.pipe.writeReply?(4)};f.drain();f.on {XCTAssertEqual(f.room.snapshot?.seats,1);value.pipe.retire()};f.drain();f.on {XCTAssertEqual(f.room.snapshot?.seats,0)};XCTAssertEqual(binary(value).count,1)
    }
    func testPartialAudioAtEOFNeverAppendsEchoIntoMissingDataSuffix() throws {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);value.pipe.holdWrite=true;value.pipe.holdClose=true;XCTAssertTrue(f.feed(block));let count=try XCTUnwrap(value.pipe.writes.last?.count)
        f.on {value.pipe.supply(.ending(frame(8,Data([3,232])),failed:false));value.pipe.writeReply?(count-1)};f.drain();f.on {XCTAssertFalse(value.pipe.writes.contains(Data([0x88,2,3,232])));XCTAssertEqual(value.pipe.closes,1);XCTAssertEqual(f.room.snapshot?.seats,1);value.pipe.retire()};f.drain()
    }
    func testDeadlineOriginalAcrossShortWritesWaitsBothCallbacksAndClose() throws {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);value.pipe.holdWrite=true;value.pipe.holdClose=true;XCTAssertTrue(f.feed(block));let count=try XCTUnwrap(value.pipe.writes.last?.count)
        f.on {f.now=102;value.pipe.writeReply?(count-1)};f.drain();pulse(f,103)
        f.on {XCTAssertEqual(value.pipe.closes,1);XCTAssertEqual(f.room.snapshot?.seats,1);XCTAssertEqual(f.pulses.count,0);value.pipe.retire()};f.drain();f.on {XCTAssertEqual(f.room.snapshot?.seats,0)}
    }
    func testMuteAndSourceGenerationResetDiscardPartialAndWaitingNotOwnedSuffix() throws {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);value.pipe.holdWrite=true;XCTAssertTrue(f.feed(block));XCTAssertTrue(f.feed(block));var old:UUID?
        f.on {old=f.room.audioGeneration;XCTAssertTrue(f.room.setAudioMuted(true));XCTAssertEqual(f.room.peers?.first?.queuedAudio,0)};XCTAssertFalse(f.feed(block));f.on {XCTAssertTrue(f.room.setAudioMuted(false))};XCTAssertFalse(f.feed(block,ticket:old))
        XCTAssertTrue(f.feed(Array(block.prefix(240))));f.on {XCTAssertNotNil(f.room.resetAudio())};XCTAssertTrue(f.feed(Array(block.suffix(240))));XCTAssertEqual(f.encoder.calls,2)
    }
    func testIdleGapFlushesPartialBeforeNextBlock() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);XCTAssertTrue(f.feed(Array(block.prefix(240))));pulse(f,102.01);XCTAssertTrue(f.feed(Array(block.suffix(240))));XCTAssertTrue(binary(value).isEmpty);XCTAssertEqual(f.encoders,0)
    }
    func testQuietJoinIsIdleButRecentSourceWithoutListenersIsNot() {
        for recent in [false,true] {let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());if recent {XCTAssertTrue(f.feed(block))};let value=f.offer();f.authenticate(value)
            f.on {XCTAssertEqual(f.room.peers?.first?.idle,!recent)};XCTAssertEqual(messages(value).filter {$0["type"] as? String=="idle"}.count,recent ? 0:1);XCTAssertEqual(f.encoders,0)
        }
    }
    func testLateEncoderFactoryStopCannotPublishOrLoseReturnedNativeOwner() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);f.encoderHook={_ = f.room.stop()};XCTAssertFalse(f.feed(block));XCTAssertTrue(binary(value).isEmpty);XCTAssertEqual(f.encoder.closes,1);f.on {XCTAssertEqual(f.room.snapshot?.state,.off)}
    }
    func testStopReleaseAndRestartKeepSourceTicketsFencedAndRetireCodec() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);XCTAssertTrue(f.feed(block));var old:UUID?
        f.on {old=f.room.audioGeneration;_ = f.room.stop()};f.drain();XCTAssertEqual(f.encoder.closes,1);XCTAssertTrue(f.start());XCTAssertFalse(f.feed(block,ticket:old));f.on {XCTAssertEqual(value.pipe.closes,1)}
    }
    func testPermissionRevokedInsideEncodeCannotQueueAudioAfterRetirement() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);f.encoder.hook={f.enabled=false};XCTAssertFalse(f.feed(block));XCTAssertTrue(binary(value).isEmpty);XCTAssertEqual(f.encoder.closes,1)
    }
    func testFirstAudioAfterQuietWelcomeSendsActiveBeforeBinary() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());let value=f.offer();f.authenticate(value);XCTAssertTrue(f.feed(block));XCTAssertEqual(binary(value).count,1)
        let kinds=value.pipe.writes.compactMap {wire -> String? in
            switch WebSocketPackets.Reader(fromClient:false).feed(wire).event {
            case .binary:return "binary"
            case .text(let data):return ((try? JSONSerialization.jsonObject(with:data)) as? [String:Any])?["type"] as? String
            default:return nil
            }
        };XCTAssertEqual(Array(kinds.suffix(2)),["active","binary"])
    }
    func testResetDuringEncodeFencesOldTicketAndAllowsFreshGeneration() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);var old:UUID?
        f.on {old=f.room.audioGeneration};f.encoder.hook={f.encoder.hook=nil;XCTAssertNotNil(f.room.resetAudio())}
        XCTAssertFalse(f.feed(block));XCTAssertTrue(binary(value).isEmpty);XCTAssertFalse(f.feed(block,ticket:old));XCTAssertTrue(f.feed(block));XCTAssertEqual(binary(value).count,1)
    }
    func testResetDuringLateEncoderFactoryRetiresReturnedOwnerAndAllowsFreshFeed() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);f.encoderHook={f.encoderHook=nil;XCTAssertNotNil(f.room.resetAudio())}
        XCTAssertFalse(f.feed(block));XCTAssertEqual(f.encoder.closes,1);XCTAssertTrue(binary(value).isEmpty);XCTAssertTrue(f.feed(block));XCTAssertEqual(binary(value).count,1)
    }
    func testStoppedPeerNeverSendsFromItsWaitingAudioAfterRestart() {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);value.pipe.holdWrite=true;value.pipe.holdClose=true;XCTAssertTrue(f.feed(block));XCTAssertTrue(f.feed(block));var stopped=0
        f.on {_ = f.room.stop {stopped += 1}};f.drain();XCTAssertFalse(f.feed(block));XCTAssertFalse(f.start());f.on {XCTAssertEqual(stopped,0);value.pipe.retire()};f.drain();XCTAssertTrue(f.start());XCTAssertEqual(binary(value).count,1);XCTAssertEqual(stopped,1)
    }

    func testClosingProtocolStopsDemandBeforeExactCloseReceiptReleasesSeat() throws {
        let f=Fixture();defer {f.cleanup()};let value=connected(f);value.pipe.holdWrite=true;value.pipe.holdClose=true;XCTAssertTrue(f.feed(block));let first=try XCTUnwrap(value.pipe.writes.last)
        f.on {value.pipe.supply(.bytes(frame(8,Data([3,232]))))};f.drain()
        f.on {XCTAssertEqual(f.room.snapshot?.welcomed,0);XCTAssertEqual(f.room.snapshot?.seats,1)}
        let calls=f.encoder.calls;XCTAssertTrue(f.feed(block));XCTAssertEqual(f.encoder.calls,calls)
        f.on {value.pipe.writeReply?(first.count)};f.drain();f.on {value.pipe.writeReply?(4)};f.drain();f.on {value.pipe.retire()};f.drain()
    }

    func testOwnedNativeRoomSendsRealOpusAudioWhileReadingAndRetiresExactly() {
        let q=DispatchQueue(label:"test.web.audio.native.owned",qos:.utility),closed=expectation(description:"native audio room and children retired"),clientClosed=expectation(description:"native audio client retired")
        let credential=WebAuthentication.Credential.make(password:"synthetic",salt:Data(repeating:0,count:16),derive:{_,_ in Data(repeating:1,count:32)})!
        let reader=WebSocketPackets.Reader(fromClient:false),schedule=WebNativeListener.nativeSchedule(permitted:{true})
        var room:WebRoom.Service?,client:NWConnection?,buffer=Data(),phase=0,serverReady=false,clientWelcome=false,sent=false,audio=false,pong=false,stopping=false
        func sendWhenBothReady() {
            guard serverReady,clientWelcome,!sent,let ticket=room?.audioGeneration else {return};sent=true
            let samples=(0..<480).map {Float(sin(Double($0)*0.03))*0.2}
            XCTAssertTrue(room?.feed(samples,lane:.wasapi,generation:ticket) ?? false)
        }
        func finishWhenBothReceived() {
            guard audio,pong,!stopping else {return};stopping=true;phase=4;XCTAssertEqual(room?.snapshot?.welcomed,1)
            _ = room?.stop {closed.fulfill();client?.cancel()}
        }
        q.sync {
            room=WebRoom.Service(queue:q,isolated:false,permitted:{true},listener:{gate in
                WebNativeListener.ownedLoopback(queue:q,permitted:gate,bound:{port in
                    XCTAssertNotEqual(port,WebNativeListener.defaultPort)
                    guard let port=NWEndpoint.Port(rawValue:port) else {XCTFail("Missing owned audio port");return}
                    let c=NWConnection(host:.ipv4(.loopback),port:port,using:.tcp);client=c
                    c.stateUpdateHandler={state in
                        switch state {
                        case .ready:
                            c.send(content:Fixture.head,completion:.contentProcessed {XCTAssertNil($0)})
                            func receive() {
                                c.receive(minimumIncompleteLength:1,maximumLength:4096) {data,_,end,error in
                                    if stopping {return};XCTAssertNil(error);if let data {buffer.append(data)};guard buffer.count<=16384 else {XCTFail("Owned audio input cap");c.cancel();return}
                                    for _ in 0..<32 {
                                        if phase==0 {guard let split=buffer.range(of:Data("\r\n\r\n".utf8)) else {break};XCTAssertTrue(String(decoding:buffer.prefix(upTo:split.upperBound),as:UTF8.self).hasPrefix("HTTP/1.1 101 "));buffer=Data(buffer.suffix(from:split.upperBound));phase=1}
                                        guard !buffer.isEmpty else {break};let result=reader.feed(buffer);guard result.consumedBytes>0 else {XCTFail("Owned audio parse progress");return};buffer=Data(buffer.dropFirst(result.consumedBytes));if result.event == .pending {break}
                                        if phase==1,case .text=result.event {phase=2;c.send(content:Fixture.answer+Data([0x89,0x81,0,0,0,0,7]),completion:.contentProcessed {XCTAssertNil($0)})}
                                        else if phase==2,case .text(let bytes)=result.event,let object=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any],object["type"] as? String=="welcome" {phase=3;clientWelcome=true;sendWhenBothReady()}
                                        else if phase==3,case .text(let bytes)=result.event,let object=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any],let type=object["type"] as? String,["idle","active"].contains(type) {}
                                        else if phase==3,case .pong(let bytes)=result.event {XCTAssertEqual(bytes,Data([7]));pong=true;finishWhenBothReceived()}
                                        else if phase==3,case .binary(let bytes)=result.event {
                                            guard let packet=WebAudioPackets.parse(bytes,codec:.opus),let decoder=rs_opus_decoder(2) else {XCTFail("Owned Opus frame");return};defer {rs_opus_destroy(decoder)}
                                            XCTAssertEqual(packet.stream,1);XCTAssertEqual(packet.sequence,0);var output=[Float](repeating:0,count:480)
                                            let n=packet.payload.withUnsafeBytes { b in output.withUnsafeMutableBufferPointer {rs_opus_decode(decoder,b.bindMemory(to:UInt8.self).baseAddress,Int32(packet.payload.count),$0.baseAddress,240)}}
                                            XCTAssertEqual(n,240);XCTAssertTrue(output.allSatisfy(\.isFinite));audio=true;finishWhenBothReceived()
                                        } else {XCTFail("Unexpected owned audio frame");return}
                                        if stopping {return}
                                    }
                                    if !end,error==nil {receive()} else {XCTFail("Premature owned audio end");c.cancel()}
                                }
                            };receive()
                        case .cancelled:clientClosed.fulfill()
                        case .failed(let error):XCTFail("Owned audio connection failed: \(error)");c.cancel()
                        default:break
                        }
                    };c.start(queue:q)
                })
            },clock:{ProcessInfo.processInfo.systemUptime},schedule:WebNativeTransport.schedule(permitted:{true}),peerSchedule:{queue,pulse in let stop=schedule(queue,pulse);queue.async {serverReady=true;sendWhenBothReady()};return stop},random:{Data(repeating:2,count:$0)},verify:{_,_ in true})
            XCTAssertTrue(room?.start(configuration:{.init(credential:credential,page:Data("fixed".utf8),policy:.init(hosts:["example.test:47840"],origins:["https://example.test"]),source:"fixed")}) ?? false)
        }
        wait(for:[closed,clientClosed],timeout:5)
        q.sync {_ = room?.shutdown();room=nil;client?.cancel();client?.stateUpdateHandler=nil;client=nil;XCTAssertEqual(phase,4);XCTAssertTrue(sent && audio && pong)};q.sync {}
    }

}
