import Foundation
import XCTest
@testable import RemSoundCore
final class WebHandshakeTests:XCTestCase {
    private let key="dGhlIHNhbXBsZSBub25jZQ=="
    private let accept="s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    private func request(path:String="/listen",extra:String="",host:String="example.test:47840")->Data {
        Data(("GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(key)\r\n"+extra+"\r\n").utf8)
    }
    private func refuse(_ text:String,file:StaticString=#filePath,line:UInt=#line) {
        XCTAssertEqual(WebHandshake.Reader().feed(Data(text.utf8)).outcome,.refused,file:file,line:line)
    }
    func testRFCGoldenAcceptAndCaseInsensitiveTokens() {
        let result=WebHandshake.Reader().feed(request())
        XCTAssertEqual(result.outcome,.upgrade(accept:accept,host:"example.test:47840",origin:nil))
        XCTAssertEqual(result.consumedBytes,request().count)
        let text=String(decoding:request(),as:UTF8.self).replacingOccurrences(of:"Upgrade: websocket",with:"uPgRaDe: WebSocket").replacingOccurrences(of:"Upgrade\r\n",with:"uPgRaDe\r\n")
        XCTAssertEqual(WebHandshake.Reader().feed(Data(text.utf8)).outcome,result.outcome)
    }
    func testEverySplitAndSingleByteDeliveryProducesOneReceipt() {
        let data=request()
        for split in 0..<data.count {
            let reader=WebHandshake.Reader()
            XCTAssertEqual(reader.feed(data.prefix(split)).outcome,.pending)
            XCTAssertEqual(reader.feed(data.dropFirst(split)).outcome,.upgrade(accept:accept,host:"example.test:47840",origin:nil))
            XCTAssertEqual(reader.bufferedBytes,0)
            XCTAssertEqual(reader.feed(data).outcome,.closed)
        }
        let reader=WebHandshake.Reader()
        for (offset,byte) in data.enumerated() {
            let result=reader.feed(Data([byte]))
            XCTAssertEqual(result.outcome,offset==data.count-1 ? .upgrade(accept:accept,host:"example.test:47840",origin:nil):.pending)
        }
    }
    func testRootAndIndexAreOnlyUnauthenticatedPageRoutes() {
        for path in ["/","/index.html"] {
            let text="GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n"
            XCTAssertEqual(WebHandshake.Reader().feed(Data(text.utf8)).outcome,.page)
        }
        for path in ["/listen","/favicon.ico","/INDEX.html","/%69ndex.html","/?x=1","//","http://localhost/","/../","/index.html#x"] {
            refuse("GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n")
        }
        XCTAssertEqual(WebHandshake.Reader().feed(request(path:"/")).outcome,.refused)
    }
    func testMethodVersionAndRequestWhitespaceRefuse() {
        for line in ["POST / HTTP/1.1","GET / HTTP/1.0","GET  / HTTP/1.1"," GET / HTTP/1.1","GET\t/ HTTP/1.1","GET / HTTP/1.1 ","GET / HTTP/2"] {refuse(line+"\r\nHost: localhost\r\n\r\n")}
    }
    func testHostRequiredUniqueAndAuthorityOnly() {
        for header in ["","Host:\r\n","Host: a\r\nHost: b\r\n","Host : a\r\n","Host: user@host\r\n","Host: a/path\r\n","Host: a?x\r\n","Host: a#x\r\n","Host: a:0\r\n","Host: a:65536\r\n","Host: a:bad\r\n","Host: a b\r\n"] {refuse("GET / HTTP/1.1\r\n"+header+"\r\n")}
    }
    func testPublicFunnelHostAndOriginAreValuesNotLoopbackAuthority() {
        for host in ["public-node.example.ts.net","127.0.0.1:47840","[::1]:47840"] {
            XCTAssertEqual(WebHandshake.Reader().feed(request(extra:"Origin: https://public-node.example.ts.net\r\nX-Forwarded-Host: attacker.invalid\r\nSec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n",host:host)).outcome,.upgrade(accept:accept,host:host,origin:"https://public-node.example.ts.net"))
        }
        XCTAssertEqual(WebHandshake.Reader().feed(request(extra:"Origin: null\r\n")).outcome,.upgrade(accept:accept,host:"example.test:47840",origin:"null"))
    }
    func testKeyMustBeSingleCanonicalSixteenByteBase64() {
        let text=String(decoding:request(),as:UTF8.self)
        for value in ["", "abc", "AAAAAAAAAAAAAAAAAAAA",key+"x",String(key.dropLast(2))+"=", "dGhlIHNhbXBsZSBub25jZR=="] {
            let changed=text.replacingOccurrences(of:"Sec-WebSocket-Key: \(key)",with:"Sec-WebSocket-Key: \(value)")
            XCTAssertEqual(WebHandshake.Reader().feed(Data(changed.utf8)).outcome,.refused)
        }
        XCTAssertEqual(WebHandshake.Reader().feed(request(extra:"Sec-WebSocket-Key: \(key)\r\n")).outcome,.refused)
    }
    func testMissingWrongVersionAndMissingUpgradeTokensRefuse() {
        let text=String(decoding:request(),as:UTF8.self)
        for (old,new) in [("Sec-WebSocket-Version: 13\r\n",""),("Sec-WebSocket-Version: 13","Sec-WebSocket-Version: 12"),("Upgrade: websocket","Upgrade: h2c"),("Connection: keep-alive, Upgrade","Connection: keep-alive"),("Connection: keep-alive, Upgrade","Connection: ,Upgrade"),("Upgrade: websocket","Upgrade: web socket")] {
            XCTAssertEqual(WebHandshake.Reader().feed(Data(text.replacingOccurrences(of:old,with:new).utf8)).outcome,.refused)
        }
    }
    func testBodiesTransferEncodingAndDuplicateLengthNeverAdmit() {
        for extra in ["Content-Length: 1\r\n","Content-Length: +0\r\n","Content-Length: 00\r\n","Content-Length: 0\r\nContent-Length: 0\r\n","Transfer-Encoding: chunked\r\n","Transfer-Encoding: identity\r\n"] {XCTAssertEqual(WebHandshake.Reader().feed(request(extra:extra)).outcome,.refused)}
        XCTAssertEqual(WebHandshake.Reader().feed(request(extra:"Content-Length: 0\r\n")).outcome,.upgrade(accept:accept,host:"example.test:47840",origin:nil))
    }
    func testFoldBadNamesControlAndBareLineEndingsRefuse() {
        for extra in [" folded\r\n","\tfolded\r\n","Bad Name: a\r\n","X@: a\r\n","X: a\u{0}b\r\n","X: a\u{7f}\r\n","X: a\nb\r\n","X: a\rb\r\n","X: café\r\n"] {XCTAssertEqual(WebHandshake.Reader().feed(request(extra:extra)).outcome,.refused)}
        refuse("GET / HTTP/1.1\nHost: localhost\n\n")
    }
    func testHeaderCountAtApplicationLimitAndOneMore() {
        let extras=(0..<59).map {"X-\($0): x\r\n"}.joined()
        XCTAssertEqual(WebHandshake.Reader().feed(request(extra:extras)).outcome,.upgrade(accept:accept,host:"example.test:47840",origin:nil))
        XCTAssertEqual(WebHandshake.Reader().feed(request(extra:extras+"X-last: x\r\n")).outcome,.limit)
    }
    func testLineCapBeforeUnboundedBufferGrowth() {
        let reader=WebHandshake.Reader()
        let bytes=Data(("GET / HTTP/1.1\r\nHost: localhost\r\nX: "+String(repeating:"x",count:2048)).utf8)
        XCTAssertEqual(reader.feed(bytes).outcome,.limit);XCTAssertEqual(reader.bufferedBytes,0)
        XCTAssertEqual(reader.feed(request()).outcome,.closed)
    }
    func testHeadCapExactBoundaryAndOversizedReadBeforeCopy() {
        var text="GET / HTTP/1.1\r\nHost: localhost\r\n"
        for i in 0..<4 {text += "X-\(i): "+String(repeating:"x",count:1900)+"\r\n"}
        let padding=8192-text.utf8.count-11
        let exact=Data((text+"X-pad: "+String(repeating:"x",count:padding)+"\r\n\r\n").utf8)
        XCTAssertEqual(exact.count,8192);XCTAssertEqual(WebHandshake.Reader().feed(exact).outcome,.page)
        let over=Data((text+"X-pad: "+String(repeating:"x",count:padding+1)+"\r\n\r\n").utf8)
        XCTAssertEqual(WebHandshake.Reader().feed(over).outcome,.limit)
        let reader=WebHandshake.Reader();XCTAssertEqual(reader.feed(Data(repeating:65,count:16385)).outcome,.limit);XCTAssertEqual(reader.bufferedBytes,0)
    }
    func testUpgradeConsumesOnlyHeadLeavingFirstFrameToOwner() {
        let head=request(),frame=Data([0x81,0x80,1,2,3,4]),reader=WebHandshake.Reader()
        let result=reader.feed(head+frame)
        XCTAssertEqual(result.outcome,.upgrade(accept:accept,host:"example.test:47840",origin:nil));XCTAssertEqual(result.consumedBytes,head.count);XCTAssertEqual(reader.bufferedBytes,0)
    }
    func testCancelDiscardAndNonzeroSliceDelivery() {
        let reader=WebHandshake.Reader();_ = reader.feed(Data("GET /".utf8));reader.cancel()
        XCTAssertEqual(reader.bufferedBytes,0);XCTAssertEqual(reader.feed(request()).outcome,.cancelled)
        let whole=Data([1,2,3])+request()
        XCTAssertEqual(WebHandshake.Reader().feed(whole[3...]).outcome,.upgrade(accept:accept,host:"example.test:47840",origin:nil))
    }

    func testExactLineLimitIncludingCRLFThenNextLine() {
        let extra="X: "+String(repeating:"x",count:2043)+"\r\n"
        XCTAssertEqual(extra.utf8.count,2048)
        XCTAssertEqual(WebHandshake.Reader().feed(request(extra:extra)).outcome,.upgrade(accept:accept,host:"example.test:47840",origin:nil))
        XCTAssertEqual(WebHandshake.Reader().feed(request(extra:extra.replacingOccurrences(of:"\r\n",with:"x\r\n"))).outcome,.limit)
    }
    func testCumulativeHeadQuotaIsNotResetBetweenReads() {
        let reader=WebHandshake.Reader(),first=Data("GET / HTTP/1.1\r\nHost: localhost\r\n".utf8)
        XCTAssertEqual(reader.feed(first).outcome,.pending)
        var outcome=WebHandshake.Outcome.pending
        for i in 0..<10 {
            outcome=reader.feed(Data(("X-\(i): "+String(repeating:"x",count:1000)+"\r\n").utf8)).outcome
            if outcome != .pending {break}
            XCTAssertLessThanOrEqual(reader.bufferedBytes,8192)
        }
        XCTAssertEqual(outcome,.limit);XCTAssertEqual(reader.bufferedBytes,0)
    }
    func testDuplicateCaseNamesAndAmbiguousOriginRefuse() {
        for extra in ["hOsT: localhost\r\n","Connection: Upgrade\r\n","Sec-WebSocket-Version: 13\r\n","Origin: a\r\norigin: b\r\n","X: a\r\nx: b\r\n"] {
            XCTAssertEqual(WebHandshake.Reader().feed(request(extra:extra)).outcome,.refused)
        }
    }
    func testAuthorityInvalidLiteralsAndDomainEdgesRefuse() {
        for host in ["[nope]","[::1]x","[::1]:","::1","-a.test","a-.test","a..test",".","a%2etest","a:123456"] {XCTAssertEqual(WebHandshake.Reader().feed(request(host:host)).outcome,.refused)}
        XCTAssertEqual(WebHandshake.Reader().feed(request(host:"example.test.:65535")).outcome,.upgrade(accept:accept,host:"example.test.:65535",origin:nil))
    }
    func testTerminalReceiptCannotBeReplacedByLaterCancelOrTraffic() {
        let reader=WebHandshake.Reader()
        XCTAssertEqual(reader.feed(request()).outcome,.upgrade(accept:accept,host:"example.test:47840",origin:nil))
        reader.cancel();XCTAssertEqual(reader.feed(Data(repeating:1,count:20000)).outcome,.closed)
        XCTAssertEqual(reader.bufferedBytes,0)
        let pending=WebHandshake.Reader();XCTAssertEqual(pending.feed(Data()).outcome,.pending);XCTAssertEqual(pending.bufferedBytes,0)
    }

    func testMalformedExtensionAndProtocolOffersRefuseEvenWhenNotSelected() {
        for value in ["","foo;","foo; bad name=a","foo; p=\"a,b\"","foo; p=\"unterminated","foo,,bar"] {
            XCTAssertEqual(WebHandshake.Reader().feed(request(extra:"Sec-WebSocket-Extensions: \(value)\r\n")).outcome,.refused)
        }
        XCTAssertEqual(WebHandshake.Reader().feed(request(extra:"Sec-WebSocket-Protocol: chat, CHAT\r\n")).outcome,.upgrade(accept:accept,host:"example.test:47840",origin:nil))
        XCTAssertEqual(WebHandshake.Reader().feed(request(extra:"Sec-WebSocket-Protocol: chat, chat\r\n")).outcome,.refused)
        for value in ["chat,,audio","chat; audio"] {XCTAssertEqual(WebHandshake.Reader().feed(request(extra:"Sec-WebSocket-Protocol: \(value)\r\n")).outcome,.refused)}
        for extra in ["Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n","Sec-WebSocket-Extensions: x-test; p=\"a\\b\"\r\n","Sec-WebSocket-Protocol: chat, audio\r\n"] {
            XCTAssertEqual(WebHandshake.Reader().feed(request(extra:extra)).outcome,.upgrade(accept:accept,host:"example.test:47840",origin:nil))
        }
    }
}
