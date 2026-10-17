import Foundation
import XCTest
@testable import RemSoundCore
final class WebAudioHandoffTests:XCTestCase {
    private final class Sink:WebAudioHandoff.Sink {
        var blocks=[WebAudioHandoff.Block](),gaps=[Bool](),reply:((Bool)->Void)?,closed:(()->Void)?,closes=0,autoReply=true,autoClose=true,hook:(()->Void)?
        func consume(_ block:WebAudioHandoff.Block,discontinuity:Bool,completion:@escaping (Bool)->Void) {blocks.append(block);gaps.append(discontinuity);reply=completion;hook?();if autoReply {completion(true)}}
        func close(completion:@escaping ()->Void) {closes += 1;closed=completion;if autoClose {completion()}}
    }
    private final class Fixture {
        let q=DispatchQueue(label:"test.web.handoff"),sink=Sink(),binding=WebAudioHandoff.Binding(request:UUID(),network:.init(port:49199,generation:UUID()))
        var service:WebAudioHandoff.Service!,producer:WebAudioHandoff.Producer?,jobs=[()->Void](),allowed=true,isolated=false,factories=0,opens=0,lastOpenWasNil=false,factoryHook:(()->Void)?,factoryReturns=true,lifetime:(()->Bool)?
        init(isolated:Bool=false) {
            self.isolated=isolated
            service=WebAudioHandoff.Service(queue:q,isolated:isolated,permitted:{[weak self] in self?.allowed ?? false},enqueue:{[weak self] work in self?.jobs.append(work)},factory:{[weak self] binding,gate in
                guard let self else {return nil};XCTAssertEqual(binding,self.binding);XCTAssertTrue(gate());factories += 1;lifetime=gate;factoryHook?();return factoryReturns ? sink:nil
            })
        }
        func on(_ body:()->Void) {q.sync(execute:body)}
        func callbacks() {for _ in 0..<8 {q.sync {}}}
        func runOne() {var work:(()->Void)?;on {if !jobs.isEmpty {work=jobs.removeFirst()}};if let work {on {work()}};callbacks()}
        func run() {for _ in 0..<80 {var count=0;on {count=jobs.count};guard count>0 else {callbacks();return};runOne()};XCTFail("Bounded work did not drain")}
        @discardableResult func open()->Bool {var value=false;on {value=service.open(binding) {[weak self] producer in self?.opens += 1;self?.lastOpenWasNil=producer==nil;self?.producer=producer}};return value}
        func start() {XCTAssertTrue(open());run();XCTAssertNotNil(producer)}
        func cleanup() {sink.autoReply=true;sink.autoClose=true;on {_ = service?.shutdown();sink.reply?(false);sink.closed?()};callbacks();run();on {producer=nil;service=nil};callbacks();run()}
    }
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
    private final class RoomFixture {
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
    private func connected(_ f:RoomFixture)->Incoming {XCTAssertTrue(f.start());let value=f.offer();f.authenticate(value);f.on {XCTAssertEqual(f.room.snapshot?.welcomed,1);XCTAssertTrue(f.room.audioActivity())};f.drain();return value}
    private func pulse(_ f:RoomFixture,_ now:Double) {f.on {f.now=now;for action in Array(f.pulses.values) {action()}};f.drain()}
    private func messages(_ value:Incoming)->[[String:Any]] {value.pipe.writes.compactMap {wire in guard case .text(let data)=WebSocketPackets.Reader(fromClient:false).feed(wire).event else {return nil};return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]}}

    private let block=[Float](repeating:0.25,count:480)
    func testOffIsolationForeignQueueAndInvalidBindingRefuseBeforeFactory() {
        for isolated in [false,true] {let f=Fixture(isolated:isolated);defer {f.cleanup()};f.allowed=false;XCTAssertFalse(f.open());XCTAssertEqual(f.factories,0);XCTAssertEqual(f.opens,0);XCTAssertTrue(f.jobs.isEmpty)}
        let f=Fixture();defer {f.cleanup()};XCTAssertFalse(f.service.open(f.binding) {_ in XCTFail("Foreign open callback")});f.on {XCTAssertFalse(f.service.open(.init(request:UUID(),network:.init(port:0,generation:UUID()))) {_ in XCTFail("Invalid binding callback")})};XCTAssertEqual(f.factories,0)
    }
    func testNoProducerUntilFactoryReturnAndSingleBindingExcludesConcurrentWriter() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.open());XCTAssertNil(f.producer);XCTAssertFalse(f.open());f.run();XCTAssertEqual(f.opens,1);XCTAssertEqual(f.factories,1);XCTAssertNotNil(f.producer);XCTAssertFalse(f.open())
    }
    func testOfferCapsBeforeQueueAndOwnsCopiedSamples() {
        let f=Fixture();defer {f.cleanup()};f.start();guard let producer=f.producer else {return}
        for samples in [[],[1],[Float.nan,0],[Float.infinity,0],Array(repeating:Float(0),count:8194)] {XCTAssertFalse(producer.offer(samples,lane:.mixed))};XCTAssertTrue(f.jobs.isEmpty)
        var samples=block;XCTAssertTrue(producer.offer(samples,lane:.asio));samples[0] = -1;f.run();XCTAssertEqual(f.sink.blocks.first?.samples.first,0.25);XCTAssertEqual(f.sink.blocks.first?.lane.rawValue,2)
    }
    func testCoalescedWakeAnd32BlocksDropOldestWithGapBeforeNextConsumption() {
        let f=Fixture();defer {f.cleanup()};f.start();guard let producer=f.producer else {return}
        for n in 0..<40 {XCTAssertTrue(producer.offer([Float(n),Float(n)],lane:.mixed))}
        XCTAssertEqual(f.jobs.count,1);f.on {XCTAssertEqual(f.service.snapshot?.queuedBlocks,32);XCTAssertEqual(f.service.snapshot?.droppedBlocks,8)};f.run()
        XCTAssertEqual(f.sink.blocks.count,32);XCTAssertEqual(f.sink.blocks.first?.samples,[8,8]);XCTAssertEqual(f.sink.gaps.filter {$0}.count,1);XCTAssertEqual(f.sink.gaps.first,true);XCTAssertTrue(f.jobs.isEmpty)
    }
    func testTotalSampleReservationBeforeAllocationIndependentOfBlockCount() {
        let f=Fixture();defer {f.cleanup()};f.start();guard let producer=f.producer else {return};let large=[Float](repeating:0,count:8192)
        XCTAssertTrue(producer.offer(large,lane:.mixed));XCTAssertTrue(producer.offer(large,lane:.asio));f.on {XCTAssertEqual(f.service.snapshot?.queuedBlocks,1);XCTAssertEqual(f.service.snapshot?.queuedSamples,8192);XCTAssertEqual(f.service.snapshot?.droppedBlocks,1)};f.run();XCTAssertEqual(f.sink.blocks.count,1);XCTAssertEqual(f.sink.gaps,[true])
    }
    func testOnlyOneSinkConsumptionPendingWithNoBusyLoopOrExtraWake() {
        let f=Fixture();defer {f.cleanup()};f.start();f.sink.autoReply=false;guard let producer=f.producer else {return};for _ in 0..<10 {XCTAssertTrue(producer.offer(block,lane:.mixed))};f.runOne()
        XCTAssertEqual(f.sink.blocks.count,1);XCTAssertTrue(f.jobs.isEmpty);f.on {XCTAssertEqual(f.service.snapshot?.inflight,true);f.sink.reply?(true)};f.callbacks();XCTAssertEqual(f.jobs.count,1);f.runOne();XCTAssertEqual(f.sink.blocks.count,2)
    }
    func testCloseImmediatelyFencesOfferButWaitsBothConsumeAndCloseReceipts() {
        let f=Fixture();defer {f.cleanup()};f.start();f.sink.autoReply=false;f.sink.autoClose=false;guard let producer=f.producer else {return};XCTAssertTrue(producer.offer(block,lane:.mixed));f.runOne();var done=0
        XCTAssertTrue(f.service.stop {done += 1});XCTAssertFalse(producer.offer(block,lane:.mixed));f.run();f.on {f.sink.closed?()};f.callbacks();XCTAssertEqual(done,0);XCTAssertFalse(f.open());f.on {f.sink.reply?(false)};f.callbacks();f.run();XCTAssertEqual(done,1);XCTAssertEqual(f.sink.closes,1)
    }
    func testCancelBeforeFactoryAndReentrantLateFactoryRetainExactCleanup() {
        for late in [false,true] {let f=Fixture();defer {f.cleanup()};f.sink.autoClose=false
            if late {f.factoryHook={_ = f.service.stop()}};XCTAssertTrue(f.open());if !late {_ = f.service.stop()};f.run()
            if late {XCTAssertEqual(f.opens,0);XCTAssertFalse(f.open());f.on {f.sink.closed?()};f.callbacks();f.run()}
            XCTAssertEqual(f.factories,late ? 1:0);XCTAssertEqual(f.opens,1);XCTAssertTrue(f.lastOpenWasNil);XCTAssertNil(f.producer)
        }
    }
    func testForeignDuplicateAndStaleReceiptsCannotAdvanceAnotherBlock() {
        let f=Fixture();defer {f.cleanup()};f.start();f.sink.autoReply=false;guard let producer=f.producer else {return};XCTAssertTrue(producer.offer(block,lane:.mixed));XCTAssertTrue(producer.offer(block,lane:.mixed));f.runOne()
        let first=f.sink.reply,done=expectation(description:"foreign receipt offered");DispatchQueue.global().async {first?(true);first?(false);done.fulfill()};wait(for:[done],timeout:2);f.callbacks();f.runOne();XCTAssertEqual(f.sink.blocks.count,2)
        f.on {first?(false)};f.callbacks();XCTAssertEqual(f.sink.closes,0);f.on {f.sink.reply?(true)};f.callbacks();f.run();XCTAssertEqual(f.sink.blocks.count,2)
    }
    func testPermissionRefusalAndNilFactoryDoNotGuessProgressOrReopen() {
        let f=Fixture();defer {f.cleanup()};f.start();guard let producer=f.producer else {return};XCTAssertTrue(producer.offer(block,lane:.mixed));f.allowed=false;f.run();XCTAssertTrue(f.sink.blocks.isEmpty);XCTAssertEqual(f.sink.closes,1);XCTAssertFalse(producer.offer(block,lane:.mixed));XCTAssertEqual(f.factories,1)
        let g=Fixture();defer {g.cleanup()};g.factoryReturns=false;XCTAssertTrue(g.open());g.run();XCTAssertTrue(g.lastOpenWasNil);XCTAssertEqual(g.sink.closes,0)
    }
    func testOldProducerCannotRetireOrFeedNewBindingAfterAcknowledgedClose() {
        let f=Fixture();defer {f.cleanup()};f.start();let old=f.producer;var done=0;_ = f.service.stop {done += 1};f.run();XCTAssertEqual(done,1);f.producer=nil;XCTAssertTrue(f.open());f.run();XCTAssertFalse(old?.offer(block,lane:.mixed) ?? true);XCTAssertFalse(old?.retire() ?? true);XCTAssertTrue(f.producer?.offer(block,lane:.mixed) ?? false);f.run();XCTAssertEqual(f.sink.blocks.count,1)
    }
    func testServiceAndProducerReleaseRetainCleanupWithoutLeavingWorker() {
        for service in [false,true] {let f=Fixture();f.start();f.sink.autoReply=false;f.sink.autoClose=false;XCTAssertTrue(f.producer?.offer(block,lane:.mixed) ?? false);f.runOne();if service {f.on {f.service=nil}} else {f.on {f.producer=nil}};f.run();XCTAssertEqual(f.sink.closes,1);f.on {f.sink.closed?();f.sink.reply?(false)};f.callbacks();f.run();f.cleanup()}
    }
    func testWaiterCapIncludesQueuedCallbacksAndCoalescesNativeClose() {
        let f=Fixture();defer {f.cleanup()};f.start();f.sink.autoClose=false;var done=0
        for _ in 0..<16 {XCTAssertTrue(f.service.stop {done += 1})};XCTAssertFalse(f.service.stop {XCTFail("Unadmitted waiter")});f.run();XCTAssertEqual(f.sink.closes,1);f.on {f.sink.closed?()};f.callbacks();f.run();XCTAssertEqual(done,16)
    }
    func testConcurrentProducersCannotExceedReservationsOrQueueManyDrains() {
        let f=Fixture();defer {f.cleanup()};f.start();guard let producer=f.producer else {return};let values=block
        DispatchQueue.concurrentPerform(iterations:100) {_ in XCTAssertTrue(producer.offer(values,lane:.wasapi))};f.on {XCTAssertLessThanOrEqual(f.service.snapshot?.queuedSamples ?? Int.max,15360);XCTAssertEqual(f.service.snapshot?.queuedBlocks,32)};XCTAssertEqual(f.jobs.count,1);f.run();XCTAssertEqual(f.sink.blocks.count,32)
    }
    func testSynchronousExecutorReentrantFactoryCloseWaitsReturnedResource() {
        let q=DispatchQueue(label:"test.web.handoff.sync"),sink=Sink();sink.autoClose=false;var service:WebAudioHandoff.Service!,opens=0,done=0
        let binding=WebAudioHandoff.Binding(request:UUID(),network:.init(port:49198,generation:UUID()))
        service=WebAudioHandoff.Service(queue:q,isolated:false,permitted:{true},enqueue:{$0()},factory:{_,_ in _ = service.stop {done += 1};return sink})
        q.sync {XCTAssertTrue(service.open(binding) {value in opens += 1;XCTAssertNil(value)});XCTAssertEqual(sink.closes,1);XCTAssertEqual(opens,0);sink.closed?()};for _ in 0..<8 {q.sync {}}
        XCTAssertEqual(opens,1);XCTAssertEqual(done,1);q.sync {_ = service.shutdown();service=nil}
    }
    func testRawCompletionCannotRetireBeforeConsumeMethodReturnsEvenWithSyncExecutor() {
        final class Inline:WebAudioHandoff.Sink {
            var inside:(()->Void)?
            func consume(_ block:WebAudioHandoff.Block,discontinuity:Bool,completion:@escaping (Bool)->Void) {completion(true);inside?();completion(false)}
            func close(completion:@escaping ()->Void) {completion()}
        }
        let q=DispatchQueue(label:"test.web.handoff.receipt"),sink=Inline();var source:WebAudioHandoff.Producer?,service:WebAudioHandoff.Service!
        service=WebAudioHandoff.Service(queue:q,isolated:false,permitted:{true},enqueue:{$0()},factory:{_,_ in sink});sink.inside={XCTAssertEqual(service.snapshot?.inflight,true)}
        q.sync {XCTAssertTrue(service.open(.init(request:UUID(),network:.init(port:49198,generation:UUID()))) {source=$0});XCTAssertTrue(source?.offer(self.block,lane:.mixed) ?? false)};for _ in 0..<8 {q.sync {}}
        q.sync {XCTAssertEqual(service.snapshot?.inflight,false);_ = service.shutdown()};for _ in 0..<8 {q.sync {}};q.sync {source=nil;service=nil;sink.inside=nil}
    }
    func testPermissionChangeDuringFactoryAndRefusedConsumePreserveOneCleanup() {
        let f=Fixture();defer {f.cleanup()};f.sink.autoClose=false;f.factoryHook={f.allowed=false};XCTAssertTrue(f.open());f.run();XCTAssertEqual(f.sink.closes,1);XCTAssertEqual(f.opens,0);f.on {f.sink.closed?()};f.callbacks();f.run();XCTAssertTrue(f.lastOpenWasNil)
        let g=Fixture();defer {g.cleanup()};g.start();g.sink.autoReply=false;g.sink.autoClose=false;guard let source=g.producer else {return};XCTAssertTrue(source.offer(block,lane:.mixed));XCTAssertTrue(source.offer(block,lane:.mixed));g.runOne();g.on {g.sink.reply?(false)};g.callbacks();g.run();XCTAssertEqual(g.sink.blocks.count,1);XCTAssertEqual(g.sink.closes,1);XCTAssertFalse(g.open())
    }
    func testLifetimePredicateDoesNotExpireAtAcknowledgmentAndShutdownIsPermanent() {
        let f=Fixture();defer {f.cleanup()};f.start();f.on {XCTAssertTrue(f.lifetime?() ?? false)};var done=0;XCTAssertTrue(f.service.shutdown {done += 1});f.run();XCTAssertEqual(done,1);f.on {XCTAssertFalse(f.lifetime?() ?? true)};XCTAssertFalse(f.open())
    }

    func testForeignInjectedExecutorMarshalsFactoryBackOntoOwner() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.open());var work:(()->Void)?;f.on {if !f.jobs.isEmpty {work=f.jobs.removeFirst()}}
        let ran=expectation(description:"foreign executor posted control");let task=work
        DispatchQueue.global().async {task?();ran.fulfill()};wait(for:[ran],timeout:2);f.callbacks();XCTAssertEqual(f.factories,1);XCTAssertNotNil(f.producer);f.on {XCTAssertTrue(f.lifetime?() ?? false)}
    }
    func testActualRoomSinkDeliversAndSourceCloseIsNotRoomNetworkRetirement() {
        let f=RoomFixture();defer {f.cleanup()};let value=connected(f);var source:WebAudioHandoff.Producer?,service:WebAudioHandoff.Service!,closed=0
        f.on {service=WebAudioHandoff.Service(queue:f.queue,isolated:false,permitted:{f.enabled},factory:{_,gate in WebAudioHandoff.roomSink(f.room,permitted:gate)});XCTAssertTrue(service.open(.init(request:UUID(),network:.init(port:49197,generation:UUID()))) {source=$0})};f.drain()
        XCTAssertTrue(source?.offer(block,lane:.mixed) ?? false);f.drain();XCTAssertEqual(value.pipe.writes.filter {if case .binary=WebSocketPackets.Reader(fromClient:false).feed($0).event {return true};return false}.count,1)
        f.on {_ = service.stop {closed += 1}};f.drain();f.on {XCTAssertEqual(closed,1);XCTAssertEqual(f.room.snapshot?.state,.running);XCTAssertEqual(f.room.snapshot?.seats,1);XCTAssertEqual(value.pipe.closes,0);_ = service.shutdown();source=nil;service=nil};f.drain()
    }
    func testRoomSinkGapFlushesOldPartialBeforeNextAcceptedSamples() {
        let f=RoomFixture();defer {f.cleanup()};let value=connected(f);var source:WebAudioHandoff.Producer?,service:WebAudioHandoff.Service!,jobs=[()->Void]()
        f.on {service=WebAudioHandoff.Service(queue:f.queue,isolated:false,permitted:{true},enqueue:{jobs.append($0)},factory:{_,gate in WebAudioHandoff.roomSink(f.room,permitted:gate)});XCTAssertTrue(service.open(.init(request:UUID(),network:.init(port:49197,generation:UUID()))) {source=$0});let open=jobs.removeFirst();open()};f.drain()
        func runOne() {f.on {if !jobs.isEmpty {let work=jobs.removeFirst();work()}};f.drain()}
        XCTAssertTrue(source?.offer(Array(block.prefix(240)),lane:.mixed) ?? false);runOne()
        for _ in 0..<40 {XCTAssertTrue(source?.offer(Array(block.suffix(240)),lane:.mixed) ?? false)};runOne()
        XCTAssertEqual(value.pipe.writes.filter {if case .binary=WebSocketPackets.Reader(fromClient:false).feed($0).event {return true};return false}.count,0)
        f.on {_ = service.shutdown()};runOne();f.on {source=nil;service=nil};f.drain();for _ in 0..<4 {runOne()}
    }
    func testOldRoomSinkCannotResetNewRoomSourceGenerationOnLateRefusal() {
        let f=RoomFixture();defer {f.cleanup()};_ = connected(f);var source:WebAudioHandoff.Producer?,service:WebAudioHandoff.Service!,newTicket:UUID?
        f.on {service=WebAudioHandoff.Service(queue:f.queue,isolated:false,permitted:{true},factory:{_,gate in WebAudioHandoff.roomSink(f.room,permitted:gate)});XCTAssertTrue(service.open(.init(request:UUID(),network:.init(port:49197,generation:UUID()))) {source=$0})};f.drain()
        f.on {newTicket=f.room.resetAudio()};XCTAssertTrue(source?.offer(block,lane:.mixed) ?? false);f.drain()
        f.on {XCTAssertEqual(f.room.audioGeneration,newTicket);XCTAssertNil(service.snapshot?.binding);XCTAssertEqual(f.room.snapshot?.state,.running);_ = service.shutdown();source=nil;service=nil};f.drain()
    }

}
