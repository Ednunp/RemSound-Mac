import Foundation
import XCTest
@testable import RemSoundCore

final class CrossPortFormatTests: XCTestCase {
    private func format() -> Data { StreamFormat.opus(Data([160,161,162,163,164,165,166,167]),frames:120).encode(lane:.asio) }
    func testLegacy32And36MetadataParseWithoutInventingPasswordFingerprint() throws {
        let full=format()
        for size in [32,36] {
            let parsed=try XCTUnwrap(StreamFormat.parse(Data(full.prefix(size))))
            XCTAssertTrue(parsed.fingerprint.isEmpty)
            XCTAssertEqual(parsed.channels,2);XCTAssertEqual(parsed.frames,120)
        }
    }
    func testCaptureLatencyTenthsSurviveActualParserAndEncoder() throws {
        for value:UInt16 in [0,1,35,65535] {
            var bytes=Data(format().prefix(44));bytes.put(value)
            let parsed=try XCTUnwrap(StreamFormat.parse(bytes))
            XCTAssertEqual(parsed.encode(lane:.asio),bytes)
        }
    }
    func testFingerprintLayout44DefaultsCaptureAndLegacyExtensionsAreLengthGated() throws {
        let full=format()
        for size in 32...46 {
            let parsed=try XCTUnwrap(StreamFormat.parse(Data(full.prefix(size))))
            XCTAssertEqual(parsed.fingerprint.count,size >= 44 ? 8 : 0)
        }
        XCTAssertNil(StreamFormat.parse(Data(full.prefix(31))))
    }
    func testMalformedChannelsCodecEncodingAndFramesStillFailClosed() {
        let good=format()
        for (offset,value) in [(0,UInt32(44100)),(4,0),(4,3),(24,99),(28,0),(28,2881)] {
            var bad=good;var replacement=Data();replacement.put(value);bad.replaceSubrange(offset..<offset+4,with:replacement)
            XCTAssertNil(StreamFormat.parse(bad))
        }
        var pcm=StreamFormat.pcm(Data(repeating:1,count:8)).encode();pcm[12]=2
        XCTAssertNil(StreamFormat.parse(pcm))
    }
    func testCaptureQuantizationClampsAndInvalidNumbersNeverTrap() {
        for (input,want) in [(3.5,UInt16(35)),(0.25,2),(0.35,4),(-1,0),(1e100,65535),(Double.nan,0),(Double.infinity,0),(-Double.infinity,0)] {
            let bytes=StreamFormat.opus(Data(repeating:1,count:8),frames:120).capturing(milliseconds:input).encode()
            XCTAssertEqual(bytes.u16(44),want)
        }
    }
    func testUnknownLaneDefaultsMixedAndPartialExtensionsDoNotBecomeFlags() throws {
        var bytes=format();bytes[32]=255;bytes[33]=1
        XCTAssertEqual(try XCTUnwrap(StreamFormat.parse(bytes)).lane,.mixed)
        for size in 32..<36 {
            let parsed=try XCTUnwrap(StreamFormat.parse(Data(bytes.prefix(size))))
            XCTAssertEqual(parsed.lane,.mixed);XCTAssertEqual(parsed.labFlags,0);XCTAssertEqual(parsed.captureLatencyMs,0)
        }
    }
    func testInvalidFingerprintDoesNotAppendUnboundedBytesOrCaptureExtension() {
        for size in [0,1,7,9,65536] {
            let bytes=StreamFormat.pcm(Data(repeating:1,count:size)).capturing(milliseconds:3.5).encode()
            XCTAssertEqual(bytes.count,36)
        }
    }
    func testMetadataUpdatePreservesRealQueuedPCMAndRefusesDecoderChanges() throws {
        let key=try Credentials(password:"synthetic metadata queue")
        let format=StreamFormat.pcm(key.fingerprint),decoder=StreamDecoder(format,jitterMs:10)
        let pcm=Data((0..<Wire.pcmFrames).flatMap { _ in [UInt8(0),0,64,0,0,192] })
        for frame in 1...8 {
            var payload=Data();payload.put(UInt32(frame));payload.append(contentsOf:[0,1]);payload.append(try key.seal(pcm))
            let packet=try XCTUnwrap(Wire.parse(Wire.packet(.audio,stream:7,sequence:UInt32(frame),payload:payload)))
            XCTAssertTrue(decoder.accept(packet,credentials:key))
        }
        let queued=decoder.queuedFrames;XCTAssertGreaterThan(queued,0)
        var updated=format.capturing(milliseconds:3.5);updated.lane = .asio
        XCTAssertTrue(decoder.updateMetadata(updated));XCTAssertEqual(decoder.queuedFrames,queued)
        let audio=decoder.read(240)
        XCTAssertGreaterThan(audio[0],0.4);XCTAssertLessThan(audio[1],-0.4)
        var incompatible=updated;incompatible.frames += 1
        XCTAssertFalse(decoder.updateMetadata(incompatible));XCTAssertEqual(decoder.format,updated)
    }
    func testSharedHeartbeatParserPinsFlagsBoundsAndUInt64TickBytes() throws {
        let bytes=HeartbeatPayload.encode(.ping,tickMs:UInt64.max,flags:1)
        let read=try XCTUnwrap(HeartbeatPayload.parse(bytes))
        XCTAssertEqual(read.tickMs,UInt64.max);XCTAssertEqual(read.flags,1);XCTAssertEqual(read.kind,.ping)
        XCTAssertNil(HeartbeatPayload.parse(Data([2]+Array(repeating:UInt8(0),count:8))))
        XCTAssertNil(HeartbeatPayload.parse(Data(bytes.prefix(8))))
    }
    func testSharedTickParserRejectsVersionAndExactLengthWithoutGrantingAdmission() throws {
        let id=UUID(),bytes=TickProofPayload.encode(id:id,unixSeconds:1_790_000_000)
        let read=try XCTUnwrap(TickProofPayload.parse(bytes))
        XCTAssertEqual(read.id,id);XCTAssertEqual(read.unixSeconds,1_790_000_000)
        for size in [0,24,26] { XCTAssertNil(TickProofPayload.parse(Data(repeating:1,count:size))) }
        var bad=bytes;bad[0]=2;XCTAssertNil(TickProofPayload.parse(bad))
    }
}
