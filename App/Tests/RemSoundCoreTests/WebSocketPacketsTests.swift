import Foundation
import XCTest
@testable import RemSoundCore
final class WebSocketPacketsTests:XCTestCase {
    private func client(_ payload:Data,opcode:UInt8=1,final:Bool=true,mask:[UInt8]=[0x37,0xfa,0x21,0x3d])->Data {
        var bytes=[UInt8((final ? 0x80:0)|opcode)]
        if payload.count<126 {bytes.append(0x80|UInt8(payload.count))} else {bytes += [0xfe,UInt8(payload.count>>8),UInt8(payload.count&255)]}
        bytes += mask
        for (i,b) in payload.enumerated() {bytes.append(b^mask[i%4])}
        return Data(bytes)
    }
    func testRFCMaskedHelloGoldenAndServerBytes() throws {
        let golden=Data([0x81,0x85,0x37,0xfa,0x21,0x3d,0x7f,0x9f,0x4d,0x51,0x58])
        XCTAssertEqual(client(Data("Hello".utf8)),golden)
        let receipt=WebSocketPackets.Reader().feed(golden)
        XCTAssertEqual(receipt.event,.text(Data("Hello".utf8)));XCTAssertEqual(receipt.consumedBytes,golden.count)
        XCTAssertEqual(try XCTUnwrap(WebSocketPackets.serverFrame(kind:.text,payload:Data("Hello".utf8))),Data([0x81,5])+Data("Hello".utf8))
    }
    func testEverySplitAndByteDeliveryRetainMaskOffset() {
        let payload=Data((0..<256).map {UInt8($0)}),bytes=client(payload,opcode:2)
        for split in 0..<bytes.count {
            let reader=WebSocketPackets.Reader();XCTAssertEqual(reader.feed(bytes.prefix(split)).event,.pending)
            XCTAssertEqual(reader.feed(bytes.dropFirst(split)).event,.binary(payload));XCTAssertEqual(reader.bufferedBytes,0)
        }
        let reader=WebSocketPackets.Reader()
        for (index,byte) in bytes.enumerated() {XCTAssertEqual(reader.feed(Data([byte])).event,index==bytes.count-1 ? .binary(payload):.pending)}
    }
    func testOneEventConsumesOnlyItsFrameAndNextMessageRemains() {
        let a=client(Data("one".utf8)),b=client(Data("two".utf8)),reader=WebSocketPackets.Reader()
        let first=reader.feed(a+b);XCTAssertEqual(first.event,.text(Data("one".utf8)));XCTAssertEqual(first.consumedBytes,a.count)
        XCTAssertEqual(reader.feed((a+b).dropFirst(first.consumedBytes)).event,.text(Data("two".utf8)))
    }
    func testMaskDirectionIsMandatory() {
        XCTAssertEqual(WebSocketPackets.Reader().feed(Data([0x81,0])).event,.protocolError)
        XCTAssertEqual(WebSocketPackets.Reader(fromClient:false).feed(client(Data())).event,.protocolError)
        XCTAssertEqual(WebSocketPackets.Reader(fromClient:false).feed(Data([0x81,0])).event,.text(Data()))
    }
    func testReservedBitsAndUndefinedOpcodesRefuseBeforePayload() {
        for bit:UInt8 in [0x10,0x20,0x40] {XCTAssertEqual(WebSocketPackets.Reader().feed(Data([0x81|bit,0x80])).event,.protocolError)}
        for opcode:UInt8 in [3,4,5,6,7,11,12,13,14,15] {XCTAssertEqual(WebSocketPackets.Reader().feed(Data([0x80|opcode,0x80])).event,.protocolError)}
    }
    func testFragmentedUTF8AcrossCodePointAndInterleavedPing() {
        let reader=WebSocketPackets.Reader(),first=client(Data([0xe2]),final:false),ping=client(Data([42]),opcode:9),last=client(Data([0x82,0xac]),opcode:0)
        let result=reader.feed(first+ping+last)
        XCTAssertEqual(result.event,.ping(Data([42])));XCTAssertEqual(result.consumedBytes,first.count+ping.count)
        XCTAssertEqual(reader.feed(last).event,.text(Data([0xe2,0x82,0xac])));XCTAssertEqual(reader.bufferedBytes,0)
    }
    func testFragmentOrderRejectsContinuationWithoutStartOrNewStart() {
        XCTAssertEqual(WebSocketPackets.Reader().feed(client(Data(),opcode:0)).event,.protocolError)
        for opcode:UInt8 in [1,2] {
            let reader=WebSocketPackets.Reader();XCTAssertEqual(reader.feed(client(Data([1]),opcode:2,final:false)).event,.pending)
            XCTAssertEqual(reader.feed(client(Data(),opcode:opcode)).event,.protocolError);XCTAssertEqual(reader.bufferedBytes,0)
        }
    }
    func testCumulativeMessageLimitBeforeContinuationPayload() {
        let reader=WebSocketPackets.Reader();XCTAssertEqual(reader.feed(client(Data(repeating:42,count:8192),opcode:2,final:false)).event,.pending)
        XCTAssertEqual(reader.feed(Data([0x80,0x81])).event,.limit);XCTAssertEqual(reader.bufferedBytes,0)
        let exact=WebSocketPackets.Reader();_ = exact.feed(client(Data(repeating:42,count:4096),opcode:2,final:false))
        XCTAssertEqual(exact.feed(client(Data(repeating:42,count:4096),opcode:0)).event,.binary(Data(repeating:42,count:8192)))
    }
    func testControlFramesMustBeFinalAndShort() {
        for opcode:UInt8 in [8,9,10] {
            XCTAssertEqual(WebSocketPackets.Reader().feed(Data([opcode,0x80])).event,.protocolError)
            XCTAssertEqual(WebSocketPackets.Reader().feed(Data([0x80|opcode,0xfe])).event,.protocolError)
        }
        XCTAssertEqual(WebSocketPackets.Reader().feed(client(Data(repeating:1,count:125),opcode:9)).event,.ping(Data(repeating:1,count:125)))
        XCTAssertEqual(WebSocketPackets.Reader().feed(client(Data(),opcode:10)).event,.pong(Data()))
    }
    func testExtendedLengthRequiresMinimalEncodingAndNetworkOrder() {
        XCTAssertEqual(WebSocketPackets.Reader().feed(Data([0x81,0xfe,0,125])).event,.protocolError)
        XCTAssertEqual(WebSocketPackets.Reader().feed(Data([0x81,0xff,0,0,0,0,0,0,0,126])).event,.protocolError)
        let payload=Data(repeating:42,count:126)
        XCTAssertEqual(WebSocketPackets.Reader().feed(client(payload)).event,.text(payload))
    }
    func testLengthHighBitAndHugeAnnouncementBeforeAllocation() {
        let reader=WebSocketPackets.Reader();XCTAssertEqual(reader.feed(Data([0x82,0xff,0x80,0,0,0,0,0,0,0])).event,.protocolError);XCTAssertEqual(reader.bufferedBytes,0)
        for head in [Data([0x82,0xfe,0x20,1]),Data([0x82,0xff,0,0,0,0,0,1,0,0])] {
            let reader=WebSocketPackets.Reader();XCTAssertEqual(reader.feed(head).event,.limit);XCTAssertEqual(reader.bufferedBytes,0)
        }
    }
    func testZeroMessagesAndNonzeroSliceIndexes() {
        XCTAssertEqual(WebSocketPackets.Reader().feed(client(Data())).event,.text(Data()))
        XCTAssertEqual(WebSocketPackets.Reader().feed(client(Data(),opcode:2)).event,.binary(Data()))
        let whole=Data([9,8])+client(Data([0,255]),opcode:2)
        XCTAssertEqual(WebSocketPackets.Reader().feed(whole[2...]).event,.binary(Data([0,255])))
    }
    func testInvalidTextUTF8RefusesAndBinaryPreservesSameBytes() {
        for bytes in [Data([0xc0,0xaf]),Data([0xed,0xa0,0x80]),Data([0xe2,0x82]),Data([0xff])] {
            XCTAssertEqual(WebSocketPackets.Reader().feed(client(bytes)).event,.protocolError)
            XCTAssertEqual(WebSocketPackets.Reader().feed(client(bytes,opcode:2)).event,.binary(bytes))
        }
        let reader=WebSocketPackets.Reader();_ = reader.feed(client(Data([0xc0]),final:false))
        XCTAssertEqual(reader.feed(client(Data([0xaf]),opcode:0)).event,.protocolError)
    }
    func testCloseCodeReasonAndReservedValues() {
        XCTAssertEqual(WebSocketPackets.Reader().feed(client(Data(),opcode:8)).event,.close(Data()))
        XCTAssertEqual(WebSocketPackets.Reader().feed(client(Data([3]),opcode:8)).event,.protocolError)
        for code:UInt16 in [1000,1001,1002,1003,1007,1008,1009,1010,1011,1012,1013,1014,3000,4999] {
            let payload=Data([UInt8(code>>8),UInt8(code&255)])+Data("é".utf8)
            XCTAssertEqual(WebSocketPackets.Reader().feed(client(payload,opcode:8)).event,.close(payload))
        }
        for code:UInt16 in [0,999,1004,1005,1006,1015,2000,2999,5000] {
            XCTAssertEqual(WebSocketPackets.Reader().feed(client(Data([UInt8(code>>8),UInt8(code&255)]),opcode:8)).event,.protocolError)
        }
        XCTAssertEqual(WebSocketPackets.Reader().feed(client(Data([3,232,0xff]),opcode:8)).event,.protocolError)
    }
    func testCancelAndEOFDiscardPartialFragmentsWithoutCleanCloseClaim() {
        let reader=WebSocketPackets.Reader();_ = reader.feed(client(Data([42]),opcode:2,final:false));reader.cancel()
        XCTAssertEqual(reader.bufferedBytes,0);XCTAssertEqual(reader.feed(client(Data())).event,.cancelled)
        let partial=WebSocketPackets.Reader();_ = partial.feed(Data([0x81]));XCTAssertEqual(partial.endOfInput(),.protocolError);XCTAssertEqual(partial.bufferedBytes,0)
        let fragment=WebSocketPackets.Reader();_ = fragment.feed(client(Data(),final:false));XCTAssertEqual(fragment.endOfInput(),.protocolError)
        XCTAssertEqual(WebSocketPackets.Reader().endOfInput(),.ended)
    }
    func testServerWriterBoundsUTF8ControlAndFragmentRefusal() throws {
        XCTAssertNil(WebSocketPackets.serverFrame(kind:.continuation,payload:Data()))
        XCTAssertNil(WebSocketPackets.serverFrame(kind:.text,payload:Data([0xff])))
        XCTAssertNil(WebSocketPackets.serverFrame(kind:.binary,payload:Data(repeating:0,count:8193)))
        for kind:WebSocketPackets.Kind in [.ping,.pong,.close] {XCTAssertNil(WebSocketPackets.serverFrame(kind:kind,payload:Data(repeating:0,count:126)))}
        XCTAssertNil(WebSocketPackets.serverFrame(kind:.close,payload:Data([3,242]))) // Extension-required code is client-only.
        let frame=try XCTUnwrap(WebSocketPackets.serverFrame(kind:.binary,payload:Data(repeating:42,count:8192)))
        XCTAssertEqual(frame.prefix(4),Data([0x82,126,0x20,0]));XCTAssertEqual(frame.count,8196)
    }
    func testActualHTTPRemainderBecomesFirstMaskedFrame() {
        let head=Data("GET /listen HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n".utf8)
        let message=Data("{\"type\":\"pong\"}".utf8),bytes=head+client(message),receipt=WebHandshake.Reader().feed(bytes)
        XCTAssertEqual(receipt.consumedBytes,head.count)
        XCTAssertEqual(WebSocketPackets.Reader().feed(bytes.dropFirst(receipt.consumedBytes)).event,.text(message))
    }
    func testFragmentCountCapsEmptyFragmentsWithoutByteGrowth() {
        let reader=WebSocketPackets.Reader();_ = reader.feed(client(Data(),opcode:2,final:false))
        for _ in 1..<64 {XCTAssertEqual(reader.feed(client(Data(),opcode:0,final:false)).event,.pending)}
        XCTAssertEqual(reader.feed(client(Data(),opcode:0)).event,.limit);XCTAssertEqual(reader.bufferedBytes,0)
        let exact=WebSocketPackets.Reader();_ = exact.feed(client(Data(),opcode:2,final:false))
        for _ in 1..<63 {_ = exact.feed(client(Data(),opcode:0,final:false))}
        XCTAssertEqual(exact.feed(client(Data(),opcode:0)).event,.binary(Data()))
    }
    func testCloseRetiresFragmentAndLeavesTrailingDataUnconsumed() {
        let reader=WebSocketPackets.Reader();_ = reader.feed(client(Data([42]),opcode:2,final:false))
        let close=client(Data([3,232]),opcode:8),tail=client(Data([1]),opcode:0),result=reader.feed(close+tail)
        XCTAssertEqual(result.event,.close(Data([3,232])));XCTAssertEqual(result.consumedBytes,close.count);XCTAssertEqual(reader.bufferedBytes,0)
        reader.cancel();XCTAssertEqual(reader.feed(tail).event,.closed)
    }
    func testReadCapAndServerAudioFramingRemainSeparate() throws {
        let reader=WebSocketPackets.Reader();XCTAssertEqual(reader.feed(Data(repeating:0,count:16385)).event,.limit);XCTAssertEqual(reader.bufferedBytes,0)
        let audio=try XCTUnwrap(WebAudioPackets.packet(stream:7,sequence:0x01020304,payload:Data([42]),codec:.opus))
        let frame=try XCTUnwrap(WebSocketPackets.serverFrame(kind:.binary,payload:audio))
        XCTAssertEqual(frame,Data([0x82,7,1,7,4,3,2,1,42]))
    }

    func testAllMaskBytesAndServerRoundTripUseActualPayloadLengths() throws {
        for n in [0,1,125,126,127,4006,8192] {
            let payload=Data((0..<n).map {UInt8($0&255)})
            for mask:[UInt8] in [[0,0,0,0],[255,128,1,0]] {XCTAssertEqual(WebSocketPackets.Reader().feed(client(payload,opcode:2,mask:mask)).event,.binary(payload))}
            let frame=try XCTUnwrap(WebSocketPackets.serverFrame(kind:.binary,payload:payload))
            XCTAssertEqual(WebSocketPackets.Reader(fromClient:false).feed(frame).event,.binary(payload))
        }
    }
    func testControlInterleavePreservesFragmentQuotaAndNextMessageResets() {
        let reader=WebSocketPackets.Reader();_ = reader.feed(client(Data([1]),opcode:2,final:false))
        for _ in 0..<70 {XCTAssertEqual(reader.feed(client(Data([2]),opcode:10)).event,.pong(Data([2])))}
        XCTAssertEqual(reader.feed(client(Data([3]),opcode:0)).event,.binary(Data([1,3])))
        XCTAssertEqual(reader.feed(client(Data([4]),opcode:2)).event,.binary(Data([4])))
    }
    func testMaximumCloseReasonAndNonzeroCloseSlice() throws {
        let reason=Data(repeating:97,count:123),payload=Data([3,232])+reason
        XCTAssertEqual(WebSocketPackets.Reader().feed(client(payload,opcode:8)).event,.close(payload))
        let whole=Data([255,255])+payload
        XCTAssertEqual(try XCTUnwrap(WebSocketPackets.serverFrame(kind:.close,payload:whole[2...])).count,127)
        XCTAssertNil(WebSocketPackets.serverFrame(kind:.close,payload:payload+Data([97])))
        XCTAssertEqual(WebSocketPackets.Reader(fromClient:false).feed(Data([0x88,2,3,242])).event,.protocolError)
    }
    func testOriginalFrameRemainsPendingUntilCompleteMaskAndPayload() {
        for input in [Data([0x81,0x80,0,0,0]),Data([0x82,0xfe,0,126,0,0,0,0])+Data(repeating:42,count:125)] {
            let reader=WebSocketPackets.Reader();XCTAssertEqual(reader.feed(input).event,.pending)
            XCTAssertEqual(reader.endOfInput(),.protocolError);XCTAssertEqual(reader.bufferedBytes,0)
            XCTAssertEqual(reader.feed(client(Data())).consumedBytes,0)
        }
    }
}
