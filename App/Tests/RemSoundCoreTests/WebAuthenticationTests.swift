import Foundation
import XCTest
@testable import RemSoundCore
final class WebAuthenticationTests:XCTestCase {
    private let salt=Data(0..<16),nonce=Data(0..<32),proof=Data(repeating:42,count:32)
    private func credential() throws->WebAuthentication.Credential {
        try XCTUnwrap(WebAuthentication.Credential.make(password:"synthetic",salt:salt,derive:{_,_ in Data(repeating:1,count:32)}))
    }
    private func answer(type:String?="auth",codec:String?="opus",response:Data?=nil)->Data {
        var value:[String:Any]=["response":(response ?? proof).base64EncodedString()]
        if let type {value["type"]=type};if let codec {value["codec"]=codec}
        return try! JSONSerialization.data(withJSONObject:value)
    }
    func testCredentialInputCapsPrecedeDeriverAndOpaqueFormatting() throws {
        var calls=0
        for password in ["",String(repeating:"x",count:1025)] {
            XCTAssertNil(WebAuthentication.Credential.make(password:password,salt:salt,derive:{_,_ in calls += 1;return self.proof}))
        }
        XCTAssertNil(WebAuthentication.Credential.make(password:"x",salt:Data(count:15),derive:{_,_ in calls += 1;return self.proof}))
        XCTAssertEqual(calls,0)
        let key=try credential();XCTAssertFalse(String(reflecting:key).contains("synthetic"));XCTAssertTrue(key.description.contains("redacted"))
    }
    func testDeriverFailureOrWrongOutputCannotConstructCredential() {
        for output:Data? in [nil,Data(),Data(count:31),Data(count:33)] {
            XCTAssertNil(WebAuthentication.Credential.make(password:"x",salt:salt,derive:{_,_ in output}))
        }
    }
    func testBinaryUTF8PasswordAndSaltAreNotCStringTruncated() throws {
        var captured:Data?
        _=try XCTUnwrap(WebAuthentication.Credential.make(password:"a\0é",salt:salt,derive:{password,givenSalt in captured=password;XCTAssertEqual(givenSalt,self.salt);return self.proof}))
        XCTAssertEqual(captured,Data([97,0,195,169]))
    }
    func testFixedPrimaryChallengeFieldsAndNoSecretContent() throws {
        let key=try credential()
        let visit=try XCTUnwrap(WebAuthentication.Visit.make(credential:key,failures:.init(),autoStart:true,current:{key},clock:{10},random:{_ in self.nonce}))
        let json=try XCTUnwrap(try JSONSerialization.jsonObject(with:visit.challenge.json) as? [String:Any])
        XCTAssertEqual(json["type"] as? String,"challenge");XCTAssertEqual(json["iterations"] as? Int,150_000)
        XCTAssertEqual(json["salt"] as? String,salt.base64EncodedString());XCTAssertEqual(json["nonce"] as? String,nonce.base64EncodedString())
        XCTAssertEqual(json["autoStart"] as? Bool,true);XCTAssertNil(json["password"]);XCTAssertNil(json["key"])
    }
    func testTypedLegacyAndPCMProofsAuthenticateOnlyOnce() throws {
        let key=try credential()
        for (type,codec,expected):(String?,String?,WebAuthentication.Verdict) in [("auth","opus",.authenticatedOpus),(nil,nil,.authenticatedOpus),("auth","pcm16",.authenticatedPCM)] {
            let visit=try XCTUnwrap(WebAuthentication.Visit.make(credential:key,failures:.init(),current:{key},clock:{10},random:{_ in self.nonce},verify:{$0==self.proof && $1==self.nonce}))
            XCTAssertEqual(visit.receive(answer(type:type,codec:codec)),expected)
            XCTAssertEqual(visit.receive(answer()),.closed)
        }
    }
    func testReportsPongsAndUnknownTypedMessagesSkipWithoutGuessCharge() throws {
        let key=try credential(),failures=WebAuthentication.Failures();var checks=0
        let visit=try XCTUnwrap(WebAuthentication.Visit.make(credential:key,failures:failures,current:{key},clock:{10},random:{_ in self.nonce},verify:{_,_ in checks += 1;return true}))
        for type in ["report","pong","other"] {XCTAssertEqual(visit.receive(answer(type:type)),.ignored)}
        XCTAssertEqual(checks,0);XCTAssertEqual(visit.receive(answer()),.authenticatedOpus)
        XCTAssertEqual(failures.allows(at:10),true)
    }
    func testPreauthMessageCapClosesWithoutNativeVerification() throws {
        let key=try credential();var checks=0
        let visit=try XCTUnwrap(WebAuthentication.Visit.make(credential:key,failures:.init(),current:{key},clock:{10},random:{_ in self.nonce},verify:{_,_ in checks += 1;return true}))
        for _ in 0..<16 {XCTAssertEqual(visit.receive(answer(type:"report")),.ignored)}
        XCTAssertEqual(visit.receive(answer()),.messageLimit);XCTAssertEqual(checks,0)
    }
    func testOversizeAndMalformedProofNeverCallsVerifier() throws {
        let key=try credential();var checks=0
        for data in [Data(repeating:32,count:8193),Data("not json".utf8),answer(response:Data(count:31))] {
            let visit=try XCTUnwrap(WebAuthentication.Visit.make(credential:key,failures:.init(),current:{key},clock:{10},random:{_ in self.nonce},verify:{_,_ in checks += 1;return true}))
            XCTAssertEqual(visit.receive(data),.wrongPassword)
        }
        XCTAssertEqual(checks,0)
    }
    func testUnknownCodecKeepsPinnedOpusFallbackWhileInvalidBase64Refuses() throws {
        let key=try credential();var checks=0
        let unknown=try XCTUnwrap(WebAuthentication.Visit.make(credential:key,failures:.init(),current:{key},clock:{10},random:{_ in self.nonce},verify:{_,_ in checks += 1;return true}))
        XCTAssertEqual(unknown.receive(answer(codec:"unknown")),.authenticatedOpus)
        let invalid=try XCTUnwrap(WebAuthentication.Visit.make(credential:key,failures:.init(),current:{key},clock:{10},random:{_ in self.nonce},verify:{_,_ in checks += 1;return true}))
        XCTAssertEqual(invalid.receive(Data("{\"type\":\"auth\",\"response\":\"!!!\"}".utf8)),.wrongPassword)
        XCTAssertEqual(checks,1)
    }
    func testTenWrongGuessesLockOutIncludingCorrectProofUntilWindowExpires() throws {
        let key=try credential(),failures=WebAuthentication.Failures();var now=10.0,checks=0
        for _ in 0..<10 {
            let visit=try XCTUnwrap(WebAuthentication.Visit.make(credential:key,failures:failures,current:{key},clock:{now},random:{_ in self.nonce},verify:{_,_ in checks += 1;return false}))
            XCTAssertEqual(visit.receive(answer()),.wrongPassword);XCTAssertEqual(visit.retryNotBefore,11)
        }
        let locked=try XCTUnwrap(WebAuthentication.Visit.make(credential:key,failures:failures,current:{key},clock:{now},random:{_ in self.nonce},verify:{_,_ in checks += 1;return true}))
        XCTAssertEqual(locked.receive(answer()),.lockedOut);XCTAssertEqual(checks,10)
        now=610;XCTAssertEqual(failures.allows(at:now),false)
        now=610.001;XCTAssertEqual(failures.allows(at:now),true)
    }
    func testFailureBookBackwardOrNonfiniteClockNeverUnlocks() {
        let failures=WebAuthentication.Failures();XCTAssertTrue(failures.record(at:10))
        XCTAssertNil(failures.allows(at:9));XCTAssertNil(failures.allows(at:.nan));XCTAssertNil(failures.allows(at:.infinity))
        XCTAssertNil(failures.allows(at:Double.greatestFiniteMagnitude))
    }
    func testCancelledStaleAndInvalidClockRefuseBeforeNonceFactory() throws {
        let key=try credential();var calls=0
        XCTAssertNil(WebAuthentication.Visit.make(credential:key,failures:.init(),current:{nil},clock:{10},random:{_ in calls += 1;return self.nonce}))
        XCTAssertNil(WebAuthentication.Visit.make(credential:key,failures:.init(),current:{key},clock:{10},cancelled:{true},random:{_ in calls += 1;return self.nonce}))
        for time in [-1.0,.nan,.infinity,Double.greatestFiniteMagnitude] {
            XCTAssertNil(WebAuthentication.Visit.make(credential:key,failures:.init(),current:{key},clock:{time},random:{_ in calls += 1;return self.nonce}))
        }
        XCTAssertEqual(calls,0)
    }
    func testReentrantNonceFactoryCannotPublishCancelledOrReplacedVisit() throws {
        let key=try credential();var current:WebAuthentication.Credential?=key,cancel=false
        XCTAssertNil(WebAuthentication.Visit.make(credential:key,failures:.init(),current:{current},clock:{10},random:{_ in current=nil;return self.nonce}))
        current=key
        XCTAssertNil(WebAuthentication.Visit.make(credential:key,failures:.init(),current:{current},clock:{10},cancelled:{cancel},random:{_ in cancel=true;return self.nonce}))
    }
    func testTimeoutAndBackwardsClockRefuseBeforeVerifier() throws {
        let key=try credential();var now=10.0,checks=0
        for time in [40.0,9.0] {
            now=10
            let visit=try XCTUnwrap(WebAuthentication.Visit.make(credential:key,failures:.init(),current:{key},clock:{now},random:{_ in self.nonce},verify:{_,_ in checks += 1;return true}))
            now=time;XCTAssertEqual(visit.receive(answer()),time==40 ? .timedOut:.invalidClock)
        }
        XCTAssertEqual(checks,0)
    }
    func testLateSuccessfulVerificationCannotOutrunCredentialOrCancellation() throws {
        let key=try credential();var current:WebAuthentication.Credential?=key,cancel=false,now=10.0
        let stale=try XCTUnwrap(WebAuthentication.Visit.make(credential:key,failures:.init(),current:{current},clock:{now},random:{_ in self.nonce},verify:{_,_ in current=nil;return true}))
        XCTAssertEqual(stale.receive(answer()),.stale)
        current=key
        let cancelled=try XCTUnwrap(WebAuthentication.Visit.make(credential:key,failures:.init(),current:{current},clock:{now},cancelled:{cancel},random:{_ in self.nonce},verify:{_,_ in cancel=true;return true}))
        XCTAssertEqual(cancelled.receive(answer()),.cancelled)
        cancel=false
        let expired=try XCTUnwrap(WebAuthentication.Visit.make(credential:key,failures:.init(),current:{current},clock:{now},random:{_ in self.nonce},verify:{_,_ in now=40;return true}))
        XCTAssertEqual(expired.receive(answer()),.timedOut)
    }
    func testCredentialReplacementRetiresEvenSameMaterialObjectIdentity() throws {
        let key=try credential(),replacement=try credential();var current=key
        let visit=try XCTUnwrap(WebAuthentication.Visit.make(credential:key,failures:.init(),current:{current},clock:{10},random:{_ in self.nonce},verify:{_,_ in true}))
        current=replacement;XCTAssertEqual(visit.receive(answer()),.stale)
    }
    func testNativePBKDFAndHMACMatchIndependentUTF8BinarySaltVectors() throws {
        let cases:[(String,String)]=[("synthetic web","PgjPEXALi9cGEi7Xh06YWw3RkFaqTSebua94JH/cV+0="),("a\0é","TbmG0vtdU+mmICfofC8rzLnwpuQWHHAvPbbZyIyVmDA="),("e\u{301}","au5f5Rgh+CJAkQeXuK1ofl8FMcKGfZImA/JnVtORQw8="),("é","8TDivDxFvfvrEb9jAXJV1vrqUAxeNKnNps9IvWwkgyw=")]
        for (password,response) in cases {
            let credential=try XCTUnwrap(WebAuthentication.Credential.make(password:password,salt:salt))
            let proof=try XCTUnwrap(Data(base64Encoded:response))
            XCTAssertTrue(credential.matches(proof,nonce:nonce))
            var wrong=proof;wrong[0] ^= 1;XCTAssertFalse(credential.matches(wrong,nonce:nonce))
            var otherNonce=nonce;otherNonce[31] ^= 1;XCTAssertFalse(credential.matches(proof,nonce:otherNonce))
            XCTAssertFalse(credential.matches(proof,nonce:Data(count:31)))
        }
    }
    func testNativeRNGUsesOnlyFixedSaltAndNonceSizes() throws {
        let first=try XCTUnwrap(WebAuthentication.random(32)),second=try XCTUnwrap(WebAuthentication.random(32))
        XCTAssertEqual(first.count,32);XCTAssertNotEqual(first,second)
        XCTAssertEqual(try XCTUnwrap(WebAuthentication.random(16)).count,16)
        XCTAssertNil(WebAuthentication.random(0));XCTAssertNil(WebAuthentication.random(1_000_000))
    }
    func testReentrantClockRetirementBeforeAndAfterProofRefuses() throws {
        let key=try credential();var current:WebAuthentication.Credential?=key,calls=0
        XCTAssertNil(WebAuthentication.Visit.make(credential:key,failures:.init(),current:{current},clock:{current=nil;return 10},random:{_ in calls += 1;return self.nonce}))
        XCTAssertEqual(calls,0)
        current=key;var clockCalls=0
        let visit=try XCTUnwrap(WebAuthentication.Visit.make(credential:key,failures:.init(),current:{current},clock:{clockCalls += 1;if clockCalls==5 {current=nil};return 10},random:{_ in self.nonce},verify:{_,_ in true}))
        XCTAssertEqual(visit.receive(answer()),.stale)
    }
    func testBase64WhitespaceMatchesPinnedDecoderButPunctuationDoesNot() throws {
        let key=try credential();var calls=0
        let spaced=" \t"+proof.base64EncodedString()+"\r\n"
        let visit=try XCTUnwrap(WebAuthentication.Visit.make(credential:key,failures:.init(),current:{key},clock:{10},random:{_ in self.nonce},verify:{$0==self.proof && $1==self.nonce}))
        let data=try JSONSerialization.data(withJSONObject:["response":spaced])
        XCTAssertEqual(visit.receive(data),.authenticatedOpus)
        let bad=try XCTUnwrap(WebAuthentication.Visit.make(credential:key,failures:.init(),current:{key},clock:{10},random:{_ in self.nonce},verify:{_,_ in calls += 1;return true}))
        XCTAssertEqual(bad.receive(try JSONSerialization.data(withJSONObject:["response":proof.base64EncodedString()+"!"])),.wrongPassword)
        XCTAssertEqual(calls,0)
    }
    func testMultibytePasswordCapAndWhitespacePreserveInput() throws {
        XCTAssertNil(WebAuthentication.Credential.make(password:String(repeating:"é",count:513),salt:salt,derive:{_,_ in XCTFail("Derived oversized input");return self.proof}))
        var bytes:Data?
        _=try XCTUnwrap(WebAuthentication.Credential.make(password:" \t ",salt:salt,derive:{password,_ in bytes=password;return self.proof}))
        XCTAssertEqual(bytes,Data([32,9,32]))
    }
    func testWrongProofRetiredDuringVerifierDoesNotChargeFailureHistory() throws {
        let key=try credential(),failures=WebAuthentication.Failures();var current:WebAuthentication.Credential?=key
        let visit=try XCTUnwrap(WebAuthentication.Visit.make(credential:key,failures:failures,current:{current},clock:{10},random:{_ in self.nonce},verify:{_,_ in current=nil;return false}))
        XCTAssertEqual(visit.receive(answer()),.stale)
        for _ in 0..<10 {XCTAssertTrue(failures.record(at:10))}
        XCTAssertEqual(failures.allows(at:10),false)
    }

    func testActualNativeVerifierRunsThroughLegacyWireAdmission() throws {
        let key=try XCTUnwrap(WebAuthentication.Credential.make(password:"synthetic web",salt:salt))
        let proof=try XCTUnwrap(Data(base64Encoded:"PgjPEXALi9cGEi7Xh06YWw3RkFaqTSebua94JH/cV+0="))
        let visit=try XCTUnwrap(WebAuthentication.Visit.make(credential:key,failures:.init(),current:{key},clock:{10},random:{_ in self.nonce}))
        XCTAssertEqual(visit.receive(answer(type:nil,codec:"pcm16",response:proof)),.authenticatedPCM)
        let other=try XCTUnwrap(WebAuthentication.Visit.make(credential:key,failures:.init(),current:{key},clock:{10},random:{_ in Data(repeating:1,count:32)}))
        XCTAssertEqual(other.receive(answer(response:proof)),.wrongPassword)
    }

}
