import Foundation
import XCTest
@testable import RemSoundCore
final class WebRoomTests:XCTestCase {
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
        var offer:((WebRoom.Incoming)->Bool)?,closeReply:(()->Void)?,starts=0,closes=0,holdClose=false,startHook:(()->Void)?,failure:(()->Void)?
        func start(offer:@escaping (WebRoom.Incoming)->Bool,failed:@escaping ()->Void) {starts += 1;self.offer=offer;failure=failed;startHook?()}
        func close(completion:@escaping ()->Void) {closes += 1;closeReply=completion;if !holdClose {retire()}}
        func retire() {let callback=closeReply;closeReply=nil;callback?()}
    }
    private final class Fixture {
        let queue=DispatchQueue(label:"test.web.room"),key=DispatchSpecificKey<Int>(),listener=Listener()
        let credential=WebAuthentication.Credential.make(password:"synthetic",salt:Data(repeating:0,count:16),derive:{_,_ in Data(repeating:1,count:32)})!
        var room:WebRoom.Service!,enabled=true,now=100.0,proof=true,configs=0,factories=0,stops=0,pulses=[UUID:()->Void](),incoming=[Incoming]()
        var retirements=0,autoStart=false;var retirementHook:(()->Void)?
        var configHook:(()->Void)?,factoryHook:(()->Void)?,factoryReturns=true,source="fixed",isolated=false
        init(isolated:Bool=false,enabled:Bool=true) {
            self.isolated=isolated;self.enabled=enabled;queue.setSpecific(key:key,value:1)
            room=WebRoom.Service(queue:queue,isolated:isolated,permitted:{[weak self] in self?.enabled ?? false},listener:{[weak self] gate in
                guard let self else {return nil};XCTAssertTrue(gate());self.factories += 1;self.factoryHook?();return self.factoryReturns ? self.listener:nil
            },clock:{[weak self] in self?.now ?? .nan},schedule:{[weak self] _,pulse in
                guard let self else {return nil};let id=UUID();self.pulses[id]=pulse;return {[weak self] in self?.stops += 1;self?.pulses[id]=nil}
            },peerSchedule:{[weak self] _,pulse in guard let self else {return nil};let id=UUID();self.pulses[id]=pulse;return {[weak self] in self?.stops += 1;self?.pulses[id]=nil}},random:{Data(repeating:2,count:$0)},verify:{[weak self] _,_ in self?.proof ?? false},retiring:{[weak self] in self?.retirements += 1;self?.retirementHook?()})
        }
        func on(_ body:()->Void) {queue.sync(execute:body)}
        func drain() {for _ in 0..<32 {queue.sync {}}}
        @discardableResult func start()->Bool {var result=false;on {result=room.start(configuration:{[self] in configs += 1;configHook?();return .init(credential:credential,page:Data("fixed".utf8),policy:.init(hosts:["example.test:47840"],origins:["https://example.test"],autoStart:autoStart),source:source)})};drain();return result}
        @discardableResult func offer()->Incoming {let value=Incoming();incoming.append(value);on {XCTAssertTrue(listener.offer?(value) ?? false)};drain();return value}
        func authenticate(_ value:Incoming) {on {value.pipe.supply(.bytes(Self.head))};drain();on {value.pipe.supply(.bytes(Self.answer))};drain()}
        static var head:Data {Data("GET /listen HTTP/1.1\r\nHost: example.test:47840\r\nOrigin: https://example.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n".utf8)}
        static var answer:Data {let data=Data("{\"response\":\"\(Data(repeating:1,count:32).base64EncodedString())\"}".utf8);return Data([0x81,0x80|UInt8(data.count),0,0,0,0])+data}
        func cleanup() {on {_ = room?.shutdown();for v in incoming {v.pipe.holdClose=false;v.holdClose=false;v.pipe.retire();v.retire()};listener.holdClose=false;listener.retire()};drain();on {for v in incoming {v.pipe.retire();v.retire()};listener.retire();room=nil};drain()}
    }
    func testDefaultOffAndIsolationRefuseBeforeConfigurationOrListenerFactory() {
        for f in [Fixture(enabled:false),Fixture(isolated:true)] {XCTAssertFalse(f.start());f.on {XCTAssertEqual(f.configs,0);XCTAssertEqual(f.factories,0);XCTAssertEqual(f.listener.starts,0)};f.cleanup()}
    }
    func testEightPendingOffersBoundedAndRefusalLeavesCallerOwnership() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());for _ in 0..<8 {_ = f.offer()};let extra=Incoming()
        f.on {XCTAssertEqual(f.room.snapshot?.pending,8);XCTAssertFalse(f.listener.offer?(extra) ?? true);XCTAssertEqual(extra.factories,0);XCTAssertEqual(extra.closes,0)}
    }
    func testSeatReservedBeforeWelcomeAndOnlyFourProofsReceiveWelcome() throws {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());var values=[Incoming]()
        for _ in 0..<5 {let value=f.offer();f.authenticate(value);values.append(value)}
        f.on {XCTAssertEqual(f.room.snapshot?.seats,4);XCTAssertEqual(f.room.snapshot?.welcomed,4);XCTAssertEqual(f.room.snapshot?.pending,0);XCTAssertEqual(values[4].pipe.closes,1)}
        for (index,value) in values.enumerated() {
            guard let wire=value.pipe.writes.first(where:{if case .text(let body)=WebSocketPackets.Reader(fromClient:false).feed($0).event,let object=try? JSONSerialization.jsonObject(with:body) as? [String:Any] {return ["welcome","refused"].contains(object["type"] as? String ?? "")};return false}) else {XCTFail("Missing room receipt");continue}
            let reader=WebSocketPackets.Reader(fromClient:false)
            guard case .text(let body)=reader.feed(wire).event,let object=try JSONSerialization.jsonObject(with:body) as? [String:Any] else {XCTFail("Missing room text");continue}
            XCTAssertEqual(object["type"] as? String,index<4 ? "welcome":"refused")
            if index<4 {XCTAssertEqual(object["frameMs"] as? Int,5);XCTAssertEqual(object["source"] as? String,"fixed");XCTAssertEqual(object["autoStart"] as? Bool,false)} else {XCTAssertEqual(object["retry"] as? Bool,true)}
        }
    }
    func testStopWaitsListenerAndAllExactPendingTransportReceipts() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());let a=f.offer(),b=f.offer();a.pipe.holdClose=true;b.pipe.holdClose=true;f.listener.holdClose=true;var stopped=0
        f.on {XCTAssertTrue(f.room.stop {XCTAssertEqual(DispatchQueue.getSpecific(key:f.key),1);stopped += 1})};f.drain();f.on {XCTAssertEqual(stopped,0);XCTAssertEqual(f.room.snapshot?.state,.stopping);a.pipe.retire();f.listener.retire()};f.drain();f.on {XCTAssertEqual(stopped,0);b.pipe.retire()};f.drain();f.on {XCTAssertEqual(stopped,1);XCTAssertEqual(f.room.snapshot?.state,.off)}
    }
    func testQueuedOfferCancelledBeforeFactoryClosesIncomingExactly() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());let value=Incoming();value.holdClose=true;f.incoming.append(value);var stopped=0
        f.on {XCTAssertTrue(f.listener.offer?(value) ?? false);_ = f.room.stop {stopped += 1}};f.drain();f.on {XCTAssertEqual(value.factories,0);XCTAssertEqual(value.closes,1);XCTAssertEqual(stopped,0);value.retire()};f.drain();f.on {XCTAssertEqual(stopped,1)}
    }
    func testFailedTransportFactoryStillClosesUntransferredIncoming() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());let value=Incoming();value.transfers=false;value.holdClose=true;f.incoming.append(value)
        f.on {XCTAssertTrue(f.listener.offer?(value) ?? false)};f.drain();f.on {XCTAssertEqual(value.closes,1);XCTAssertEqual(f.room.snapshot?.pending,1);value.retire()};f.drain();f.on {XCTAssertEqual(f.room.snapshot?.pending,0)}
    }
    func testLateListenerFactoryResourceRetiresWithoutStartOrReplacement() {
        let f=Fixture();defer {f.cleanup()};f.listener.holdClose=true;f.factoryHook={_ = f.room.stop()};XCTAssertFalse(f.start())
        f.on {XCTAssertEqual(f.listener.starts,0);XCTAssertEqual(f.listener.closes,1);XCTAssertEqual(f.room.snapshot?.state,.stopping)};XCTAssertFalse(f.start());f.on {f.listener.retire()};f.drain();f.factoryHook=nil;XCTAssertTrue(f.start())
    }
    func testConfigurationReentrantStopCannotReachListenerFactory() {
        let f=Fixture();defer {f.cleanup()};f.configHook={_ = f.room.stop()};XCTAssertFalse(f.start());f.on {XCTAssertEqual(f.factories,0);XCTAssertEqual(f.listener.starts,0)}
    }
    func testStaleOfferFromRetiredListenerCannotAffectNewGeneration() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());let old=f.listener.offer;f.on {_ = f.room.stop()};f.drain();XCTAssertTrue(f.start());let value=Incoming()
        f.on {XCTAssertFalse(old?(value) ?? true);XCTAssertEqual(value.factories,0);XCTAssertEqual(f.room.snapshot?.pending,0)}
    }
    func testCredentialReplacementMustWaitOldSeatCleanupBeforeNewStart() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());let value=f.offer();f.authenticate(value);value.pipe.holdClose=true
        f.on {_ = f.room.stop()};f.drain();XCTAssertFalse(f.start());f.on {XCTAssertEqual(f.room.snapshot?.seats,1);value.pipe.retire()};f.drain();XCTAssertTrue(f.start());f.on {XCTAssertEqual(f.room.snapshot?.seats,0)}
    }
    func testWelcomePartialWritesAdvanceOnlyExactSuffixBeforePublishingSeat() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());let value=f.offer();f.on {value.pipe.supply(.bytes(Fixture.head))};f.drain();value.pipe.holdWrite=true
        f.on {value.pipe.supply(.bytes(Fixture.answer))};f.drain();var wire=Data();var old:((Int?)->Void)?
        f.on {wire=value.pipe.writes.last ?? Data();XCTAssertGreaterThan(wire.count,2);XCTAssertEqual(f.room.snapshot?.seats,1);XCTAssertEqual(f.room.snapshot?.welcomed,0);old=value.pipe.writeReply;old?(1)};f.drain()
        f.on {XCTAssertEqual(value.pipe.writes.last,Data(wire.dropFirst()));old?(wire.count);XCTAssertEqual(f.room.snapshot?.welcomed,0);value.pipe.writeReply?(wire.count-1)};f.drain();f.on {XCTAssertEqual(f.room.snapshot?.welcomed,1)}
    }
    func testWelcomeDeadlineCancelsButWaitsPendingWriteAndNativeReceipt() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());let value=f.offer();f.on {value.pipe.supply(.bytes(Fixture.head))};f.drain();value.pipe.holdWrite=true;value.pipe.holdClose=true
        f.on {value.pipe.supply(.bytes(Fixture.answer))};f.drain();f.on {f.now=103;for pulse in Array(f.pulses.values) {pulse()}};f.drain();f.on {XCTAssertEqual(value.pipe.closes,1);XCTAssertEqual(f.room.snapshot?.welcomed,0);XCTAssertEqual(f.room.snapshot?.seats,1);value.pipe.retire()};f.drain();f.on {XCTAssertEqual(f.room.snapshot?.seats,0)}
    }
    func testShutdownIsPermanentAndWaitersCoalesceAfterQuiescence() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());let value=f.offer();value.pipe.holdClose=true;var completions=0
        f.on {for _ in 0..<3 {XCTAssertTrue(f.room.shutdown {completions += 1})}};f.drain();f.on {XCTAssertEqual(completions,0);value.pipe.retire()};f.drain();f.on {XCTAssertEqual(completions,3);XCTAssertEqual(f.room.snapshot?.state,.closed)};XCTAssertFalse(f.start())
    }
    func testOwnerQueueAndSourceBoundsRefuseBeforeNativeFactories() {
        let f=Fixture();defer {f.cleanup()};XCTAssertNil(f.room.snapshot);XCTAssertFalse(f.room.start(configuration:{XCTFail("Off-owner config");return nil}))
        for text in ["",String(repeating:"x",count:129),"bad\nsource"] {f.source=text;XCTAssertFalse(f.start())};f.on {XCTAssertEqual(f.factories,0)}
    }

    func testIncomingLifetimePredicateSurvivesDriverCompletionAndFencesStop() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());let value=f.offer();f.authenticate(value)
        f.on {XCTAssertEqual(f.room.snapshot?.welcomed,1);XCTAssertTrue(value.lifetime?() ?? false);_ = f.room.stop();XCTAssertFalse(value.lifetime?() ?? true)};f.drain()
    }
    func testStopBetweenQueuedBeginAndDriverStartClosesUntransferredResource() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());let value=Incoming();value.holdClose=true;f.incoming.append(value);var closed=0
        f.on {XCTAssertTrue(f.listener.offer?(value) ?? false);f.queue.async {_ = f.room.stop {closed += 1}}};f.drain()
        f.on {XCTAssertEqual(value.factories,0);XCTAssertEqual(value.closes,1);XCTAssertEqual(closed,0);value.retire()};f.drain();f.on {XCTAssertEqual(closed,1)}
    }
    func testCancelledNilTransportFactoryStillRequiresIncomingCloseReceipt() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());let value=Incoming();value.transfers=false;value.holdClose=true;value.hook={_ = f.room.stop()};f.incoming.append(value)
        f.on {XCTAssertTrue(f.listener.offer?(value) ?? false)};f.drain();f.on {XCTAssertEqual(value.factories,1);XCTAssertEqual(value.closes,1);XCTAssertEqual(f.room.snapshot?.state,.stopping);value.retire()};f.drain();f.on {XCTAssertEqual(f.room.snapshot?.state,.off)}
    }
    func testSharedFailureHistorySurvivesStopAndStart() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());f.proof=false
        for _ in 0..<10 {let value=f.offer();f.authenticate(value);f.on {f.now += 1;for pulse in Array(f.pulses.values) {pulse()}};f.drain()}
        f.on {XCTAssertEqual(f.room.snapshot?.seats,0);_ = f.room.stop()};f.drain();f.proof=true;XCTAssertTrue(f.start());let value=f.offer();f.authenticate(value)
        f.on {XCTAssertEqual(f.room.snapshot?.welcomed,0);XCTAssertEqual(f.room.snapshot?.seats,0);for pulse in Array(f.pulses.values) {pulse()}};f.drain()
    }
    func testWrapperReleaseRetainsListenerAndEveryPendingResourceThroughCleanup() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());let value=f.offer();value.pipe.holdClose=true;f.listener.holdClose=true
        f.on {f.room=nil};f.drain();f.on {XCTAssertEqual(value.pipe.closes,1);XCTAssertEqual(f.listener.closes,1);value.pipe.retire()};f.drain();f.on {f.listener.retire()};f.drain()
    }
    func testStopWaitersAreBoundedAndOldCompletionCannotStopRestart() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());f.listener.holdClose=true;var done=0
        f.on {for _ in 0..<16 {XCTAssertTrue(f.room.stop {done += 1})};XCTAssertFalse(f.room.stop {XCTFail("Excess waiter")})};f.drain();f.on {XCTAssertEqual(done,0);f.listener.retire()};f.drain();f.on {XCTAssertEqual(done,16)};f.listener.holdClose=false;XCTAssertTrue(f.start());f.on {XCTAssertEqual(f.room.snapshot?.state,.running)}
    }

    func testInvalidOrBackwardClockRefusesFactoryOrRetiresLateListener() {
        for invalid in [Double.nan,-1,Double.greatestFiniteMagnitude] {let f=Fixture();f.now=invalid;XCTAssertFalse(f.start());f.on {XCTAssertEqual(f.factories,0)};f.cleanup()}
        let f=Fixture();defer {f.cleanup()};f.factoryHook={f.now=99};XCTAssertFalse(f.start());f.on {XCTAssertEqual(f.listener.starts,0);XCTAssertEqual(f.listener.closes,1);XCTAssertEqual(f.room.snapshot?.state,.off)}
    }
    func testInlineListenerOfferAndStopWaitForStartReturnBeforeIncomingCleanup() {
        let f=Fixture();defer {f.cleanup()};let value=Incoming();f.incoming.append(value);var returned=false
        f.listener.startHook={XCTAssertTrue(f.listener.offer?(value) ?? false);XCTAssertEqual(value.factories,0);_ = f.room.stop {XCTAssertTrue(returned)}}
        f.on {XCTAssertFalse(f.room.start(configuration:{.init(credential:f.credential,page:Data("fixed".utf8),policy:.init(hosts:["example.test:47840"],origins:[]),source:"fixed")}));returned=true};f.drain();f.on {XCTAssertEqual(value.factories,0);XCTAssertEqual(value.closes,1);XCTAssertEqual(f.room.snapshot?.state,.off)}
    }
    func testFullRoomRefusalsRetainAllEightPendingSlotsUntilExactClose() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());for _ in 0..<4 {let value=f.offer();f.authenticate(value)}
        var refused=[Incoming]();for _ in 0..<8 {let value=f.offer();value.pipe.holdClose=true;f.authenticate(value);refused.append(value)}
        let extra=Incoming();f.on {XCTAssertEqual(f.room.snapshot?.seats,4);XCTAssertEqual(f.room.snapshot?.pending,8);XCTAssertFalse(f.listener.offer?(extra) ?? true);refused[0].pipe.retire()};f.drain();f.on {XCTAssertEqual(f.room.snapshot?.pending,7);XCTAssertTrue(f.listener.offer?(extra) ?? false)};f.incoming.append(extra);f.drain()
    }
    func testFailedWelcomeNeverPublishesAndCompletedWelcomeHasOnlyActivePeerDriver() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());let value=f.offer();f.on {value.pipe.supply(.bytes(Fixture.head))};f.drain();value.pipe.holdWrite=true;value.pipe.holdClose=true
        f.on {value.pipe.supply(.bytes(Fixture.answer))};f.drain();f.on {value.pipe.writeReply?(nil)};f.drain();f.on {XCTAssertEqual(f.room.snapshot?.welcomed,0);XCTAssertEqual(f.room.snapshot?.seats,1);value.pipe.retire()};f.drain()
        let good=f.offer();f.authenticate(good);f.on {XCTAssertEqual(f.room.snapshot?.welcomed,1);XCTAssertEqual(f.pulses.count,1);XCTAssertEqual(good.pipe.reads,3)}
    }
    func testRetiringNoticePrecedesCloseReceiptAndOccursOncePerGeneration() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());f.listener.holdClose=true;var closed=0
        f.on {_ = f.room.stop {closed += 1}};f.drain();XCTAssertEqual(f.retirements,1);XCTAssertEqual(closed,0)
        f.on {f.listener.failure?();_ = f.room.stop()};f.drain();XCTAssertEqual(f.retirements,1)
        f.on {f.listener.retire()};f.drain();XCTAssertEqual(closed,1)
    }
    func testNativeFactoryFailureNotifiesWithoutInventingListenerReceipt() {
        let f=Fixture();defer {f.cleanup()};f.factoryReturns=false;XCTAssertFalse(f.start());XCTAssertEqual(f.retirements,1);XCTAssertEqual(f.listener.starts,0)
        f.on {XCTAssertEqual(f.room.snapshot?.state,.off)}
    }
    func testRetiringObserverCanReenterShutdownAndResetsForNextVisit() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.start());f.on {_ = f.room.stop()};f.drain();XCTAssertEqual(f.retirements,1)
        f.retirementHook={_ = f.room.shutdown()};XCTAssertTrue(f.start());f.on {_ = f.room.stop()};f.drain();XCTAssertEqual(f.retirements,2)
        f.on {XCTAssertEqual(f.room.snapshot?.state,.closed)}
    }
    func testAutoStartAlreadyReachesBothChallengeAndWelcome() throws {
        let f=Fixture();defer {f.cleanup()};f.autoStart=true;XCTAssertTrue(f.start());let value=f.offer();f.authenticate(value)
        var seen=Set<String>()
        for wire in value.pipe.writes {
            guard case .text(let body)=WebSocketPackets.Reader(fromClient:false).feed(wire).event,
                let object=try JSONSerialization.jsonObject(with:body) as? [String:Any],let type=object["type"] as? String,["challenge","welcome"].contains(type) else {continue}
            seen.insert(type);XCTAssertEqual(object["autoStart"] as? Bool,true)
        }
        XCTAssertEqual(seen,["challenge","welcome"])
    }

}
