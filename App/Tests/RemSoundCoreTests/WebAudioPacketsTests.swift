import Foundation
import XCTest
@testable import RemSoundCore
final class WebAudioPacketsTests:XCTestCase {
    func testGoldenBrowserHeaderIsSeparateFromUDPWire() throws {
        let bytes=try XCTUnwrap(WebAudioPackets.packet(stream:7,sequence:0x01020304,payload:Data([9,10]),codec:.opus))
        XCTAssertEqual(bytes,Data([1,7,4,3,2,1,9,10]));XCTAssertNil(Wire.parse(bytes))
        let packet=try XCTUnwrap(WebAudioPackets.parse(bytes,codec:.opus))
        XCTAssertEqual(packet.stream,7);XCTAssertEqual(packet.sequence,0x01020304);XCTAssertEqual(packet.payload,Data([9,10]))
    }
    func testAllStreamBytesAndSequenceExtremesPreserveSharedPageLayout() throws {
        for stream:UInt8 in [0,1,2,3,255] {
            for sequence:UInt32 in [0,1,UInt32.max] {
                let bytes=try XCTUnwrap(WebAudioPackets.packet(stream:stream,sequence:sequence,payload:Data([42]),codec:.opus))
                let result=try XCTUnwrap(WebAudioPackets.parse(bytes,codec:.opus))
                XCTAssertEqual(result.stream,stream);XCTAssertEqual(result.sequence,sequence)
            }
        }
    }
    func testTruncatedWrongVersionOrEmptyAudioRefuses() {
        for length in 0...6 {XCTAssertNil(WebAudioPackets.parse(Data(repeating:1,count:length),codec:.opus))}
        for version:UInt8 in [0,2,255] {XCTAssertNil(WebAudioPackets.parse(Data([version,1,0,0,0,0,42]),codec:.opus))}
        XCTAssertNil(WebAudioPackets.packet(stream:1,sequence:0,payload:Data(),codec:.opus))
    }
    func testOpusApplicationCapBeforeFramingAndParsing() throws {
        let maximum=Data(repeating:42,count:4000),tooBig=Data(repeating:42,count:4001)
        XCTAssertEqual(try XCTUnwrap(WebAudioPackets.packet(stream:1,sequence:0,payload:maximum,codec:.opus)).count,4006)
        XCTAssertNil(WebAudioPackets.packet(stream:1,sequence:0,payload:tooBig,codec:.opus))
        XCTAssertNil(WebAudioPackets.parse(Data([1,1,0,0,0,0])+tooBig,codec:.opus))
    }
    func testNonzeroDataSliceIndexesAreBoundedAndSafe() throws {
        let whole=Data([99,98,1,4,0x78,0x56,0x34,0x12,42])
        let result=try XCTUnwrap(WebAudioPackets.parse(whole[2...],codec:.opus))
        XCTAssertEqual(result.sequence,0x12345678);XCTAssertEqual(result.payload,Data([42]))
        XCTAssertNil(WebAudioPackets.parse(whole[6...],codec:.opus))
    }
    func testPCMMustBeOneFiveMillisecondStereoFrame() throws {
        let payload=Data(repeating:0,count:960)
        let bytes=try XCTUnwrap(WebAudioPackets.packet(stream:2,sequence:7,payload:payload,codec:.pcm16))
        XCTAssertEqual(bytes.count,966);XCTAssertEqual(WebAudioPackets.parse(bytes,codec:.pcm16)?.payload,payload)
        for size in [0,1,959,961,1920] {
            let data=Data(repeating:0,count:size)
            XCTAssertNil(WebAudioPackets.packet(stream:2,sequence:0,payload:data,codec:.pcm16))
            XCTAssertNil(WebAudioPackets.parse(Data([1,2,0,0,0,0])+data,codec:.pcm16))
        }
    }
    func testPCMBrowserGoldenClampingAndLittleEndianInterleaving() throws {
        var samples=[Float](repeating:0,count:480)
        samples.replaceSubrange(0..<8,with:[1,-1,2,-2,0.5,-0.5,0,0])
        let pcm=try XCTUnwrap(WebAudioPackets.pcm(samples))
        XCTAssertEqual(pcm.count,960)
        XCTAssertEqual(Data(pcm.prefix(16)),Data([255,127,1,128,255,127,1,128,0,64,0,192,0,0,0,0]))
        XCTAssertTrue(pcm.dropFirst(16).allSatisfy {$0==0})
    }
    func testPCMMatchesWindowsFloatScalingAndTiesToEven() throws {
        var samples=[Float](repeating:0,count:480)
        let halves:[Float]=[0.5,1.5,2.5,-0.5,-1.5,-2.5]
        samples.replaceSubrange(0..<6,with:halves.map {$0/Float(32767)})
        let pcm=try XCTUnwrap(WebAudioPackets.pcm(samples))
        XCTAssertEqual(Data(pcm.prefix(12)),Data([0,0,2,0,2,0,0,0,254,255,254,255]))
    }
    func testPCMRefusesNonfiniteOrWrongLengthBeforeConversion() {
        for size in [0,479,481,960] {XCTAssertNil(WebAudioPackets.pcm([Float](repeating:0,count:size)))}
        for value:Float in [.nan,.infinity,-.infinity] {
            var samples=[Float](repeating:0,count:480);samples[479]=value;XCTAssertNil(WebAudioPackets.pcm(samples))
        }
    }
    func testPCMSliceChannelsAreNotSwappedOrSilentlyNormalized() throws {
        let samples=(0..<480).map {$0.isMultiple(of:2) ? Float(1):Float(0)}
        let pcm=try XCTUnwrap(WebAudioPackets.pcm(samples))
        for offset in stride(from:0,to:pcm.count,by:4) {XCTAssertEqual(pcm[offset],255);XCTAssertEqual(pcm[offset+1],127);XCTAssertEqual(pcm[offset+2],0);XCTAssertEqual(pcm[offset+3],0)}
    }
    func testFrameConstantsKeepPageTimestampAndPCMContracts() {
        XCTAssertEqual(WebAudioPackets.frameSamples*1000/Wire.sampleRate,5)
        XCTAssertEqual(WebAudioPackets.pcmBytes,960);XCTAssertEqual(WebAudioPackets.headerSize,6)
    }
    func testBoundedRepeatedGoldenFramesRetainIndependentPayloads() throws {
        var first:Data?
        for sequence in 0..<128 {
            let bytes=try XCTUnwrap(WebAudioPackets.packet(stream:3,sequence:UInt32(sequence),payload:Data([UInt8(sequence)]),codec:.opus))
            if sequence==0 {first=bytes}
            XCTAssertEqual(WebAudioPackets.parse(bytes,codec:.opus)?.payload,Data([UInt8(sequence)]))
        }
        XCTAssertEqual(first,Data([1,3,0,0,0,0,0]))
    }
}
