import Foundation
import XCTest
@testable import RemSoundCore
final class WebAdmissionTests:XCTestCase {
    private final class Fixture {
        var now=100.0,enabled=true,rngCalls=0,proofCalls=0
        let credential=WebAuthentication.Credential.make(password:"synthetic",salt:Data(repeating:0,count:16),derive:{_,_ in Data(repeating:1,count:32)})!
        var current:WebAuthentication.Credential?
        let failures:WebAuthentication.Failures
        var randomHook:(()->Void)?,clockHook:(()->Void)?
        var proof=true,proofHook:(()->Void)?=nil
        init(failures:WebAuthentication.Failures=WebAuthentication.Failures()) {self.failures=failures;current=credential}
        func make(policy:WebAdmission.Policy = .init(hosts:["example.test:47840"],origins:["https://example.test"]))->WebAdmission.Visit? {
            WebAdmission.Visit.make(credential:credential,failures:failures,page:Data("<html>fixed</html>".utf8),policy:policy,
                permitted:{self.enabled},current:{self.current},clock:{self.clockHook?();return self.now},random:{count in self.rngCalls += 1;self.randomHook?();return Data(repeating:2,count:count)},verify:{_,_ in self.proofCalls += 1;self.proofHook?();return self.proof})
        }
    }
    private func head(page:Bool=false,host:String="example.test:47840",origin:String?="https://example.test")->Data {
        var text="GET \(page ? "/":"/listen") HTTP/1.1\r\nHost: \(host)\r\n"
        if !page {text += "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n";if let origin {text += "Origin: \(origin)\r\n"}}
        return Data((text+"\r\n").utf8)
    }
    private func client(_ text:String,opcode:UInt8=1)->Data {
        let data=Data(text.utf8);precondition(data.count<126)
        return Data([0x80|opcode,0x80|UInt8(data.count),0,0,0,0])+data
    }
    private func answer(codec:String="opus")->Data {client("{\"response\":\"\(Data(repeating:1,count:32).base64EncodedString())\",\"codec\":\"\(codec)\"}")}
    @discardableResult private func write(_ visit:WebAdmission.Visit,file:StaticString=#filePath,line:UInt=#line)->Data {
        guard case let .write(id,bytes)=visit.action else {XCTFail("Expected bounded write action",file:file,line:line);return Data()}
        XCTAssertTrue(visit.acknowledge(id:id,written:bytes.count),file:file,line:line);return bytes
    }
    private func admit(_ f:Fixture,file:StaticString=#filePath,line:UInt=#line)->WebAdmission.Visit? {
        guard let visit=f.make() else {XCTFail("Missing admission workflow",file:file,line:line);return nil}
        visit.receive(head());let upgrade=write(visit,file:file,line:line)
        XCTAssertTrue(String(decoding:upgrade,as:UTF8.self).hasPrefix("HTTP/1.1 101"),file:file,line:line)
        let challenge=write(visit,file:file,line:line)
        guard case let .text(body)=WebSocketPackets.Reader(fromClient:false).feed(challenge).event,
              let object=(try? JSONSerialization.jsonObject(with:body)) as? [String:Any] else {XCTFail("Missing challenge values",file:file,line:line);return nil}
        XCTAssertEqual(Set(object.keys),["type","salt","nonce","iterations","autoStart"],file:file,line:line)
        XCTAssertEqual(object["type"] as? String,"challenge",file:file,line:line)
        XCTAssertEqual(object["salt"] as? String,f.credential.salt.base64EncodedString(),file:file,line:line)
        XCTAssertEqual(object["nonce"] as? String,Data(repeating:2,count:32).base64EncodedString(),file:file,line:line)
        XCTAssertEqual(object["iterations"] as? Int,150000,file:file,line:line)
        XCTAssertEqual(object["autoStart"] as? Bool,false,file:file,line:line)
        XCTAssertEqual(visit.action,.read,file:file,line:line);return visit
    }
    func testActualUpgradeChallengeAndProofChainPublishesOnlyAfterWrites() {
        let f=Fixture();guard let visit=admit(f) else {return};visit.receive(answer(codec:"pcm16"))
        XCTAssertEqual(visit.action,.accepted(.pcm));XCTAssertEqual(f.rngCalls,1);XCTAssertEqual(f.proofCalls,1)
    }
    func testRootPageHasSecurityHeadersAndNoNonceOrProof() {
        let f=Fixture();guard let visit=f.make() else {return XCTFail("Missing workflow")};visit.receive(head(page:true))
        let response=String(decoding:write(visit),as:UTF8.self)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"));XCTAssertTrue(response.contains("Content-Length: 18\r\n"));XCTAssertTrue(response.contains("Content-Security-Policy:"));XCTAssertTrue(response.hasSuffix("<html>fixed</html>"))
        XCTAssertEqual(visit.action,.close(.pageDone));XCTAssertEqual(f.rngCalls,0);XCTAssertEqual(f.proofCalls,0)
    }
    func testNoAdmissionOffOrStaleBeforeClockAndRandom() {
        let f=Fixture();f.enabled=false;f.clockHook={XCTFail("Clock constructed while off")};XCTAssertNil(f.make());XCTAssertEqual(f.rngCalls,0)
        f.enabled=true;f.current=nil;XCTAssertNil(f.make());XCTAssertEqual(f.rngCalls,0)
    }
    func testHTTPDeadlineDoesNotRestartWithPartialHeaders() {
        let f=Fixture();guard let visit=f.make() else {return XCTFail("Missing workflow")}
        visit.receive(Data("GET /".utf8));f.now=109.9;visit.receive(Data("listen".utf8));XCTAssertEqual(visit.action,.read)
        f.now=110;XCTAssertEqual(visit.action,.close(.deadline));XCTAssertEqual(f.rngCalls,0)
    }
    func testClockBackwardNonfiniteAndUnrepresentableMakeFailClosed() {
        for now in [-1.0,Double.nan,Double.infinity,Double.greatestFiniteMagnitude] {let f=Fixture();f.now=now;XCTAssertNil(f.make());XCTAssertEqual(f.rngCalls,0)}
        let f=Fixture();guard let visit=f.make() else {return XCTFail("Missing workflow")};f.now=99;XCTAssertEqual(visit.action,.close(.clock))
    }
    func testOriginAndHostExplicitPolicyNeverTrustForwardedAuthority() {
        for (host,origin) in [("other.invalid","https://example.test"),("example.test:47840","https://other.invalid"),("example.test:47840","null")] {
            let f=Fixture();guard let visit=f.make() else {return XCTFail("Missing workflow")};visit.receive(head(host:host,origin:origin));XCTAssertEqual(visit.action,.close(.policy));XCTAssertEqual(f.rngCalls,0)
        }
        let f=Fixture();guard let visit=f.make() else {return XCTFail("Missing workflow")};visit.receive(head(origin:nil));XCTAssertEqual(visit.action,.close(.policy))
    }
    func testConfiguredFunnelHostAndMissingOriginChoiceAreExplicit() {
        let f=Fixture(),policy=WebAdmission.Policy(hosts:["public.example.ts.net"],origins:["https://public.example.ts.net"])
        guard let visit=f.make(policy:policy) else {return XCTFail("Missing workflow")};visit.receive(head(host:"public.example.ts.net",origin:"https://public.example.ts.net"));XCTAssertFalse(write(visit).isEmpty)
        var local=WebAdmission.Policy(hosts:["example.test:47840"],origins:[]);local.allowMissingOrigin=true
        guard let other=f.make(policy:local) else {return XCTFail("Missing workflow")};other.receive(head(origin:nil));XCTAssertFalse(write(other).isEmpty)
    }
    func testShortWriteTicketsRotateAndOldDuplicateCannotAdvanceNewWrite() {
        let f=Fixture();guard let visit=f.make() else {return XCTFail("Missing workflow")};visit.receive(head())
        guard case let .write(id,bytes)=visit.action else {return XCTFail("Missing upgrade")}
        XCTAssertTrue(visit.acknowledge(id:id,written:1));XCTAssertFalse(visit.acknowledge(id:id,written:1))
        guard case let .write(next,remainder)=visit.action else {return XCTFail("Missing partial write")}
        XCTAssertNotEqual(id,next);XCTAssertEqual(remainder,bytes.dropFirst())
        XCTAssertTrue(visit.acknowledge(id:next,written:remainder.count));XCTAssertFalse(visit.acknowledge(id:next,written:remainder.count));_ = write(visit)
        visit.receive(answer());XCTAssertEqual(visit.action,.accepted(.opus))
    }
    func testWriteFailureZeroAndOverflowNeverGenerateChallenge() {
        for count in [0,Int.max] {let f=Fixture();guard let visit=f.make() else {return XCTFail("Missing workflow")};visit.receive(head());guard case let .write(id,_)=visit.action else {return XCTFail("Missing write")};XCTAssertFalse(visit.acknowledge(id:id,written:count));XCTAssertEqual(visit.action,.close(.writeFailure));XCTAssertEqual(f.rngCalls,0)}
    }
    func testCancelOrDisableDuringPendingWriteDiscardsRemainder() {
        for cancel in [true,false] {let f=Fixture();guard let visit=f.make() else {return XCTFail("Missing workflow")};visit.receive(head()+client("{\"type\":\"pong\"}"));guard case let .write(id,bytes)=visit.action else {return XCTFail("Missing write")};if cancel {visit.cancel()} else {f.enabled=false};XCTAssertFalse(visit.acknowledge(id:id,written:bytes.count));XCTAssertEqual(visit.action,.close(cancel ? .cancelled:.permission));XCTAssertEqual(f.rngCalls,0)}
    }
    func testReentrantRandomAndClockRetirementCannotPublishChallenge() {
        let f=Fixture();guard let visit=f.make() else {return XCTFail("Missing workflow")};visit.receive(head());f.randomHook={f.current=nil};_ = write(visit)
        XCTAssertEqual(visit.action,.close(.stale))
        let g=Fixture();guard let other=g.make() else {return XCTFail("Missing workflow")};g.clockHook={g.enabled=false};other.receive(head());XCTAssertEqual(other.action,.close(.permission));XCTAssertEqual(g.rngCalls,0)
    }
    func testCoalescedTypedPongRemainderWaitsForChallengeAcknowledgment() {
        let f=Fixture();guard let visit=f.make() else {return XCTFail("Missing workflow")};visit.receive(head()+client("{\"type\":\"pong\"}"));_ = write(visit);XCTAssertEqual(f.proofCalls,0);_ = write(visit);XCTAssertEqual(visit.action,.read);XCTAssertEqual(f.proofCalls,0)
        visit.receive(answer());XCTAssertEqual(visit.action,.accepted(.opus))
    }
    func testAuthBudgetOriginalAndProtocolEOFNeverClaimClosedSocket() {
        let f=Fixture();guard let visit=admit(f) else {return};f.now=129.9;visit.receive(client("{\"type\":\"report\"}"));XCTAssertEqual(visit.action,.read)
        f.now=130;XCTAssertEqual(visit.action,.close(.deadline));XCTAssertEqual(f.proofCalls,0)
        let g=Fixture();guard let other=admit(g) else {return};other.endOfInput();XCTAssertEqual(other.action,.close(.peerEnded))
    }
    func testWrongPasswordDelayAndSharedTenAttemptWindowAreRetained() {
        let failures=WebAuthentication.Failures()
        for i in 0..<10 {
            let f=Fixture(failures:failures);f.now=100+Double(i);f.proof=false;guard let visit=admit(f) else {return};visit.receive(answer())
            XCTAssertEqual(visit.action,.wait(until:f.now+1));f.now += 1
            let refusal=write(visit);guard case let .text(body)=WebSocketPackets.Reader(fromClient:false).feed(refusal).event else {return XCTFail("Missing refusal frame")}
            XCTAssertTrue(String(decoding:body,as:UTF8.self).contains("The password was not accepted."));XCTAssertEqual(visit.action,.close(.wrongPassword))
        }
        let f=Fixture(failures:failures);f.now=110;guard let visit=admit(f) else {return};visit.receive(answer());_ = write(visit);XCTAssertEqual(visit.action,.close(.lockedOut));XCTAssertEqual(f.proofCalls,0)
    }
    func testBinaryAndBadFrameNeverBecomeArbitraryControlCommand() {
        for packet in [client("{\"op\":\"quit\"}",opcode:2),Data([0x81,0])] {let f=Fixture();guard let visit=admit(f) else {return};visit.receive(packet);XCTAssertEqual(visit.action,.close(.protocolFailure));XCTAssertEqual(f.proofCalls,0)}
    }
    func testPingsHaveExactPongAndBoundedOriginalAdmissionWork() {
        let f=Fixture();guard let visit=admit(f) else {return};visit.receive(client("ping",opcode:9));let reply=write(visit)
        XCTAssertEqual(WebSocketPackets.Reader(fromClient:false).feed(reply).event,.pong(Data("ping".utf8)));XCTAssertEqual(visit.action,.read)
        for _ in 1..<32 {visit.receive(client("pong",opcode:10));_ = visit.action}
        visit.receive(client("last",opcode:10));XCTAssertEqual(visit.action,.close(.limit))
    }
    func testAcceptedProofRetiresOnCredentialChangeBeforeConsumption() {
        let f=Fixture();guard let visit=admit(f) else {return};visit.receive(answer());f.current=nil;XCTAssertEqual(visit.action,.close(.stale))
    }
    func testUnexpectedInputWhileWriteIsPendingFailsClosed() {
        let f=Fixture();guard let visit=f.make() else {return XCTFail("Missing workflow")};visit.receive(head());visit.receive(client("extra"));XCTAssertEqual(visit.action,.close(.unexpectedInput));XCTAssertEqual(f.rngCalls,0)
    }

    func testFragmentedPageUsesValidatedHostFromCompleteHead() {
        let f=Fixture();guard let visit=f.make() else {return XCTFail("Missing workflow")}
        let bytes=head(page:true);visit.receive(bytes.dropLast(2));XCTAssertEqual(visit.action,.read)
        visit.receive(bytes.suffix(2));XCTAssertTrue(String(decoding:write(visit),as:UTF8.self).hasPrefix("HTTP/1.1 200"));XCTAssertEqual(visit.action,.close(.pageDone))
    }
    func testAuthenticatedRemainderCanBeTakenOnceAfterFreshBoundary() {
        let f=Fixture();guard let visit=admit(f) else {return}
        let tail=client("{\"type\":\"report\"}");visit.receive(answer()+tail)
        XCTAssertEqual(visit.action,.accepted(.opus));XCTAssertEqual(visit.takeAuthenticatedRemainder(),tail)
        XCTAssertEqual(visit.takeAuthenticatedRemainder(),Data())
    }
    func testReentrantProofInputCannotPublishAcceptedState() {
        let f=Fixture();guard let visit=admit(f) else {return}
        f.proofHook={f.proofHook=nil;visit.receive(self.answer())};visit.receive(answer())
        XCTAssertEqual(visit.action,.close(.unexpectedInput));XCTAssertEqual(f.proofCalls,1)
    }
    func testPeerCloseEchoRequiresExactWriteBeforeLocalCloseIntent() {
        let f=Fixture();guard let visit=admit(f) else {return}
        let payload=Data([3,232]);visit.receive(Data([0x88,0x82,0,0,0,0])+payload)
        XCTAssertEqual(WebSocketPackets.Reader(fromClient:false).feed(write(visit)).event,.close(payload));XCTAssertEqual(visit.action,.close(.peerEnded))
    }
    func testPolicyAndPageBoundsRefuseBeforeObservation() {
        let f=Fixture();f.clockHook={XCTFail("Invalid policy observed clock")}
        for policy in [WebAdmission.Policy(hosts:[],origins:[]),WebAdmission.Policy(hosts:["example.test:47840"],origins:["https://user:password@example.test"]),WebAdmission.Policy(hosts:["example.test:47840"],origins:["https://example.test/path"])] {XCTAssertNil(f.make(policy:policy))}
        XCTAssertNil(WebAdmission.Visit.make(credential:f.credential,failures:f.failures,page:Data(repeating:42,count:262145),policy:.init(hosts:["example.test:47840"],origins:[]),permitted:{true},current:{f.current},clock:{XCTFail("Oversized page observed clock");return 100}))
    }

    func testReadOnlyPageHostReceiptIsAbsentUntilStrictPageCompletion() {
        let reader=WebHandshake.Reader(),bytes=head(page:true)
        XCTAssertNil(reader.validatedPageHost);_ = reader.feed(bytes.dropLast(2));XCTAssertNil(reader.validatedPageHost)
        XCTAssertEqual(reader.feed(bytes.suffix(2)).outcome,.page);XCTAssertEqual(reader.validatedPageHost,"example.test:47840")
        let wrong=WebHandshake.Reader();_ = wrong.feed(Data("GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n".utf8));XCTAssertNil(wrong.validatedPageHost)
    }
    func testHandoffRemainderRefusesAfterCredentialRetirement() {
        let f=Fixture();guard let visit=admit(f) else {return};visit.receive(answer()+client("tail"));f.current=nil
        XCTAssertNil(visit.takeAuthenticatedRemainder());XCTAssertEqual(visit.action,.close(.stale))
    }
    func testClientOnlyCloseCodeIsNotEchoedAsServerCode() {
        let f=Fixture();guard let visit=admit(f) else {return};visit.receive(Data([0x88,0x82,0,0,0,0,3,242]))
        XCTAssertEqual(WebSocketPackets.Reader(fromClient:false).feed(write(visit)).event,.close(Data()));XCTAssertEqual(visit.action,.close(.peerEnded))
    }
    func testFalseProofAfterDeadlineDoesNotChargeSharedFailureBook() {
        let f=Fixture();f.proof=false;guard let visit=admit(f) else {return};f.proofHook={f.now=130};visit.receive(answer())
        XCTAssertEqual(visit.action,.close(.deadline));XCTAssertEqual(f.proofCalls,1)
        for _ in 0..<10 {XCTAssertTrue(f.failures.record(at:130))}
        XCTAssertEqual(f.failures.allows(at:130),false)
    }
}
