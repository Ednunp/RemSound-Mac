import Foundation
import AudioSupport
import XCTest
@testable import RemSoundCore
final class WebAudioTests:XCTestCase {
    private final class Encoder:WebAudio.Encoder {
        var frames=[[Float]](),closes=0,hook:(()->Void)?,payload:Data?=Data([42])
        func encode(_ samples:[Float])->Data? {frames.append(samples);hook?();return payload}
        func close() {closes += 1}
    }
    private final class Fixture {
        let queue=DispatchQueue(label:"test.web.audio"),encoder=Encoder()
        var allowed=true,muted=false,demand=WebAudio.Demand(opus:false,pcm:true),factories=0,packets=[WebAudio.Output](),hook:(()->Void)?,outputHook:(()->Void)?,engine:WebAudio.Engine!
        init(isolated:Bool=false,sequence:UInt32=0) {
            engine=WebAudio.Engine(queue:queue,isolated:isolated,permitted:{[weak self] in self?.allowed ?? false},muted:{[weak self] in self?.muted ?? true},demand:{[weak self] in self?.demand ?? .none},initialSequence:sequence,factory:{[weak self] in guard let self else {return nil};factories += 1;hook?();return encoder},output:{[weak self] value in self?.packets.append(value);self?.outputHook?()})
        }
        func on(_ body:()->Void) {queue.sync(execute:body)}
        @discardableResult func feed(_ samples:[Float],_ lane:WebAudio.Lane = .mixed)->Bool {var result=false;on {result=engine.feed(samples,lane:lane)};return result}
        func cleanup() {on {engine.stop()};engine=nil}
    }
    private let block=[Float](repeating:0.5,count:480)
    func testOffIsolationAndForeignQueueRefuseBeforeFactory() {
        for isolated in [true,false] {let f=Fixture(isolated:isolated);defer {f.cleanup()};f.allowed=false;f.demand = .init(opus:true,pcm:true);XCTAssertFalse(f.feed(block));XCTAssertEqual(f.factories,0)}
        let f=Fixture();defer {f.cleanup()};XCTAssertFalse(f.engine.feed(block,lane:.mixed));XCTAssertEqual(f.packets.count,0)
    }
    func testInputCapsOddEmptyAndNonfiniteRefuseBeforeFactory() {
        let f=Fixture();defer {f.cleanup()};f.demand = .init(opus:true,pcm:true)
        for samples in [[],[1],Array(repeating:Float(0),count:8194),[Float.nan,0],[Float.infinity,0]] {XCTAssertFalse(f.feed(samples))}
        XCTAssertEqual(f.factories,0);XCTAssertTrue(f.packets.isEmpty)
    }
    func testPCMChunkingPreservesInterleaveAndFiveMillisecondHeader() throws {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.feed(Array(block.prefix(126))));XCTAssertTrue(f.packets.isEmpty);XCTAssertTrue(f.feed(Array(block.dropFirst(126))))
        XCTAssertEqual(f.packets.count,1);let output=try XCTUnwrap(f.packets.first),packet=try XCTUnwrap(WebAudioPackets.parse(output.bytes,codec:.pcm16))
        XCTAssertEqual(packet.stream,0);XCTAssertEqual(packet.sequence,0);XCTAssertEqual(packet.payload,WebAudioPackets.pcm(block));XCTAssertEqual(f.factories,0)
    }
    func testThreePinnedRouteValuesHaveIndependentSequencesAndWrap() throws {
        let f=Fixture(sequence:UInt32.max);defer {f.cleanup()}
        for lane in WebAudio.Lane.allCases {XCTAssertTrue(f.feed(block,lane));XCTAssertTrue(f.feed(block,lane))}
        XCTAssertEqual(f.packets.count,6)
        guard f.packets.count==6 else {return}
        for (offset,lane) in WebAudio.Lane.allCases.enumerated() {
            let a=try XCTUnwrap(WebAudioPackets.parse(f.packets[offset*2].bytes,codec:.pcm16)),b=try XCTUnwrap(WebAudioPackets.parse(f.packets[offset*2+1].bytes,codec:.pcm16))
            XCTAssertEqual(a.stream,lane.rawValue);XCTAssertEqual(a.sequence,UInt32.max);XCTAssertEqual(b.sequence,0)
        }
    }
    func testMutedAndNoDemandDiscardPartialWithoutCreatingEncoder() {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.feed(Array(block.prefix(240))));f.muted=true;XCTAssertFalse(f.feed(block));f.muted=false
        XCTAssertTrue(f.feed(Array(block.suffix(240))));XCTAssertTrue(f.packets.isEmpty);f.demand = .none;XCTAssertFalse(f.feed(block));f.demand = .init(opus:false,pcm:true)
        XCTAssertTrue(f.feed(Array(block.suffix(240))));XCTAssertTrue(f.packets.isEmpty);XCTAssertEqual(f.factories,0)
    }
    func testDemandChangeAndExplicitFlushDoNotMixOldPartialSamples() throws {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.feed(Array(block.prefix(240))));f.demand = .init(opus:true,pcm:false)
        XCTAssertTrue(f.feed(Array(repeating:Float(-0.5),count:240)));XCTAssertTrue(f.packets.isEmpty)
        f.on {XCTAssertTrue(f.engine.flush())};XCTAssertTrue(f.feed(Array(repeating:Float(-0.5),count:480)));XCTAssertEqual(f.encoder.frames,[Array(repeating:Float(-0.5),count:480)])
    }
    func testOpusAllocatedOncePerLaneAndSameSequenceForTwoCodecs() throws {
        let f=Fixture();defer {f.cleanup()};f.demand = .init(opus:true,pcm:true)
        XCTAssertTrue(f.feed(block+block));XCTAssertEqual(f.factories,1);XCTAssertEqual(f.encoder.frames,[block,block]);XCTAssertEqual(f.packets.count,4)
        guard f.packets.count==4 else {return}
        for i in 0..<2 {let a=try XCTUnwrap(WebAudioPackets.parse(f.packets[i*2].bytes,codec:.opus)),b=try XCTUnwrap(WebAudioPackets.parse(f.packets[i*2+1].bytes,codec:.pcm16));XCTAssertEqual(a.sequence,UInt32(i));XCTAssertEqual(a.sequence,b.sequence)}
    }
    func testInvalidNativeReceiptsFailClosedAndRetireEncoder() {
        for payload in [nil,Data(),Data(repeating:0,count:4001)] as [Data?] {let f=Fixture();f.demand = .init(opus:true,pcm:true);f.encoder.payload=payload;XCTAssertFalse(f.feed(block));XCTAssertTrue(f.packets.isEmpty);XCTAssertEqual(f.encoder.closes,1);XCTAssertFalse(f.feed(block));f.cleanup();XCTAssertEqual(f.encoder.closes,1)}
    }
    func testFactoryPermissionRevokedBeforeEncodeRetiresExactReturnedOwner() {
        let f=Fixture();defer {f.cleanup()};f.demand = .init(opus:true,pcm:false);f.hook={f.allowed=false};XCTAssertFalse(f.feed(block));XCTAssertTrue(f.encoder.frames.isEmpty);XCTAssertEqual(f.encoder.closes,1);XCTAssertTrue(f.packets.isEmpty)
    }
    func testEncoderReentrantFlushCannotPublishStaleFrame() {
        let f=Fixture();defer {f.cleanup()};f.demand = .init(opus:true,pcm:true);f.encoder.hook={XCTAssertTrue(f.engine.flush())};XCTAssertFalse(f.feed(block));XCTAssertTrue(f.packets.isEmpty)
    }
    func testOutputReentrantStopPreventsSecondCodecAndFutureFeed() {
        let f=Fixture();defer {f.cleanup()};f.demand = .init(opus:true,pcm:true);f.outputHook={f.engine.stop()};XCTAssertFalse(f.feed(block));XCTAssertEqual(f.packets.count,1);XCTAssertEqual(f.encoder.closes,1);XCTAssertFalse(f.feed(block))
    }
    func testOutboxDropsOldestOf32AcrossAllLanesButNeverReturnsInvalidData() throws {
        let box=WebAudio.Outbox(codec:.opus)
        for i in 0..<40 {let bytes=try XCTUnwrap(WebAudioPackets.packet(stream:UInt8(i%3),sequence:UInt32(i),payload:Data([42]),codec:.opus));XCTAssertTrue(box.append(bytes))}
        XCTAssertEqual(box.count,32);XCTAssertEqual(box.dropped,8)
        for i in 8..<40 {XCTAssertEqual(WebAudioPackets.parse(try XCTUnwrap(box.pop()),codec:.opus)?.sequence,UInt32(i))}
        XCTAssertNil(box.pop());XCTAssertEqual(box.count,0)
    }
    func testOutboxRejectsWrongRouteCodecAndOversizeBeforeRetainingAndClears() throws {
        let box=WebAudio.Outbox(codec:.pcm16),bytes=try XCTUnwrap(WebAudioPackets.packet(stream:2,sequence:0,payload:Data(repeating:0,count:960),codec:.pcm16))
        XCTAssertFalse(box.append(Data(repeating:0,count:4007)));XCTAssertFalse(box.append(try XCTUnwrap(WebAudioPackets.packet(stream:255,sequence:0,payload:Data([42]),codec:.opus))))
        let whole=Data([99,98])+bytes;XCTAssertTrue(box.append(whole[2...]));XCTAssertEqual(box.pop(),bytes);XCTAssertTrue(box.append(bytes));box.clear();XCTAssertNil(box.pop())
    }
    func testNativeMemoryCodecEncodesAndDecodes240StereoFrames() throws {
        let encoder=try XCTUnwrap(WebAudio.nativeEncoder()),decoder=try XCTUnwrap(rs_opus_decoder(2));defer {encoder.close();rs_opus_destroy(decoder)}
        for n in 0..<32 {
            let samples=(0..<480).map {Float(sin(Double($0+n*480)*0.03))*0.2},bytes=try XCTUnwrap(encoder.encode(samples));XCTAssertTrue((1...4000).contains(bytes.count))
            var decoded=[Float](repeating:0,count:480)
            let frames=bytes.withUnsafeBytes { b in decoded.withUnsafeMutableBufferPointer { rs_opus_decode(decoder,b.bindMemory(to:UInt8.self).baseAddress,Int32(bytes.count),$0.baseAddress,240) } }
            XCTAssertEqual(frames,240);XCTAssertTrue(decoded.allSatisfy(\.isFinite))
        }
        encoder.close();XCTAssertNil(encoder.encode(block))
    }
    func testStopAndLastReleaseRetireEveryLaneOnce() {
        let f=Fixture();f.demand = .init(opus:true,pcm:false)
        for lane in WebAudio.Lane.allCases {XCTAssertTrue(f.feed(block,lane))};XCTAssertEqual(f.factories,3);f.on {f.engine.stop();f.engine.stop()};XCTAssertEqual(f.encoder.closes,3);f.cleanup();XCTAssertEqual(f.encoder.closes,3)
        var closes=0;final class Owned:WebAudio.Encoder {var closed=false;let done:()->Void;init(_ done:@escaping ()->Void) {self.done=done};func encode(_ s:[Float])->Data? {Data([1])};func close() {if !closed {closed=true;done()}};deinit {close()}}
        let q=DispatchQueue(label:"test.web.audio.release");var engine:WebAudio.Engine?=WebAudio.Engine(queue:q,isolated:false,permitted:{true},muted:{false},demand:{.init(opus:true,pcm:false)},factory:{Owned {closes += 1}},output:{_ in})
        q.sync {XCTAssertTrue(engine!.feed(block,lane:.mixed))};engine=nil;XCTAssertEqual(closes,1)
    }
    func testBoundedChurnNeverRetainsMoreThanThreeLanesAnd32Frames() {
        for _ in 0..<200 {let f=Fixture();let box=WebAudio.Outbox(codec:.pcm16);for i in 0..<40 {XCTAssertTrue(f.feed(block,WebAudio.Lane.allCases[i%3]));guard !f.packets.isEmpty else {XCTFail("Expected bounded frame receipt");continue};XCTAssertTrue(box.append(f.packets.removeFirst().bytes))};XCTAssertEqual(box.count,32);XCTAssertEqual(box.dropped,8);f.cleanup()}
    }
    func testPermissionRevokedInsideEncodeRetiresBeforeFeedReturns() {
        let f=Fixture();defer {f.cleanup()};f.demand = .init(opus:true,pcm:true);f.encoder.hook={f.allowed=false}
        XCTAssertFalse(f.feed(block));XCTAssertTrue(f.packets.isEmpty);XCTAssertEqual(f.encoder.closes,1)
    }
    func testNestedFeedCannotInterleaveEncoderOrOutputSequence() throws {
        let f=Fixture();defer {f.cleanup()};f.outputHook={XCTAssertFalse(f.engine.feed(self.block,lane:.asio))}
        XCTAssertTrue(f.feed(block));XCTAssertEqual(f.packets.count,1);XCTAssertTrue(f.feed(block));XCTAssertEqual(WebAudioPackets.parse(try XCTUnwrap(f.packets.last?.bytes),codec:.pcm16)?.sequence,1)
    }
    func testMaximumBlockBoundsWorkAndFlushKeepsSequenceWithoutOldPartial() throws {
        let f=Fixture();defer {f.cleanup()};XCTAssertTrue(f.feed(Array(repeating:0,count:8192)));XCTAssertEqual(f.packets.count,17)
        f.on {XCTAssertTrue(f.engine.flush())};XCTAssertTrue(f.feed(block));let bytes=try XCTUnwrap(f.packets.last?.bytes),packet=try XCTUnwrap(WebAudioPackets.parse(bytes,codec:.pcm16));XCTAssertEqual(packet.sequence,17);XCTAssertEqual(packet.payload,WebAudioPackets.pcm(block))
    }
    func testMutedDuringEncodeDiscardsOldPartialBeforeUnmuting() throws {
        let f=Fixture();defer {f.cleanup()};f.demand = .init(opus:true,pcm:false);XCTAssertTrue(f.feed(Array(block.prefix(240)),.asio));f.encoder.hook={f.muted=true}
        XCTAssertFalse(f.feed(block));XCTAssertTrue(f.packets.isEmpty);f.muted=false;f.encoder.hook=nil
        XCTAssertTrue(f.feed(Array(repeating:Float(-1),count:240),.asio));XCTAssertTrue(f.packets.isEmpty)
    }
    func testOutboxOwnsBoundedCopiesAndPoppedFrameSurvivesChurn() throws {
        let box=WebAudio.Outbox(codec:.opus);var bytes=try XCTUnwrap(WebAudioPackets.packet(stream:0,sequence:7,payload:Data([42]),codec:.opus));XCTAssertTrue(box.append(bytes));bytes[6]=99
        let popped=try XCTUnwrap(box.pop());XCTAssertEqual(popped.last,42)
        for _ in 0..<100 {XCTAssertTrue(box.append(bytes))};XCTAssertEqual(box.count,32);XCTAssertEqual(popped.last,42);box.clear();XCTAssertEqual(box.count,0);XCTAssertEqual(box.dropped,68)
    }

    func testPermissionCallbackCannotAdmitNestedFeedBeforeOuterReservation() {
        let q=DispatchQueue(label:"test.web.audio.gate"),samples=block;var engine:WebAudio.Engine!,visited=false,packets=0
        engine=WebAudio.Engine(queue:q,isolated:false,permitted:{
            if !visited {visited=true;XCTAssertFalse(engine.feed(samples,lane:.asio))};return true
        },muted:{false},demand:{.init(opus:false,pcm:true)},output:{_ in packets += 1})
        q.sync {XCTAssertTrue(engine.feed(samples,lane:.mixed));XCTAssertEqual(packets,1);engine.stop()};engine=nil
    }

}
