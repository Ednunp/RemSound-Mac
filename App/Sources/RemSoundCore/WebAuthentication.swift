import CommonCrypto
import CryptoKit
import Foundation
import Security

enum WebAuthentication {
    static let iterations=150_000,saltBytes=16,nonceBytes=32,keyBytes=32
    static let maximumPasswordBytes=1024,maximumMessageBytes=8192,maximumMessages=16
    static let admissionSeconds=30.0,lockoutSeconds=600.0,wrongPasswordDelay=1.0
    final class Credential:CustomStringConvertible,CustomDebugStringConvertible {
        let salt:Data
        private let key:SymmetricKey
        private init(salt:Data,key:Data) {self.salt=salt;self.key=SymmetricKey(data:key)}
        var description:String {"Web listener credential (redacted)"}
        var debugDescription:String {description}
        static func make(password:String,salt:Data,derive:(Data,Data)->Data?=nativeDerive)->Credential? {
            let count=password.utf8.prefix(maximumPasswordBytes+1).count
            guard count>0,count<=maximumPasswordBytes,salt.count==saltBytes,
                let key=derive(Data(password.utf8),salt),key.count==keyBytes else {return nil}
            return .init(salt:salt,key:key)
        }
        func matches(_ response:Data,nonce:Data)->Bool {
            guard response.count==keyBytes,nonce.count==nonceBytes else {return false}
            return HMAC<SHA256>.isValidAuthenticationCode(response,authenticating:nonce,using:key)
        }
    }
    private static func nativeDerive(_ password:Data,_ salt:Data)->Data? {
        var bytes=[UInt8](repeating:0,count:keyBytes)
        let status=password.withUnsafeBytes { p in salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),p.bindMemory(to:Int8.self).baseAddress,password.count,
                s.bindMemory(to:UInt8.self).baseAddress,salt.count,CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),UInt32(iterations),&bytes,bytes.count)
        }}
        return status==kCCSuccess ? Data(bytes):nil
    }
    static func random(_ count:Int)->Data? {
        guard count==saltBytes || count==nonceBytes else {return nil}
        var bytes=[UInt8](repeating:0,count:count)
        return SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)==errSecSuccess ? Data(bytes):nil
    }
    final class Failures {
        private static let maximumFailures=10
        private var values:[Double]=[],previous:Double?
        func record(at now:Double)->Bool {
            guard allows(at:now)==true else {return false}
            values.append(now);return true
        }
        func allows(at now:Double)->Bool? {
            let expiry=now+lockoutSeconds
            guard now.isFinite,now>=0,expiry.isFinite,expiry>now,previous.map({now >= $0}) ?? true else {return nil}
            previous=now;values.removeAll {now-$0>lockoutSeconds}
            return values.count<Self.maximumFailures
        }
    }
    struct Challenge {
        let salt:Data,nonce:Data,autoStart:Bool
        var json:Data {
            (try? JSONSerialization.data(withJSONObject:["type":"challenge","salt":salt.base64EncodedString(),
                "nonce":nonce.base64EncodedString(),"iterations":iterations,"autoStart":autoStart])) ?? Data()
        }
    }
    enum Verdict:Equatable {case ignored,authenticatedOpus,authenticatedPCM,wrongPassword,lockedOut,stale,cancelled,timedOut,invalidClock,unavailable,messageLimit,closed}
    final class Visit {
        let challenge:Challenge
        private let credential:Credential,failures:Failures,current:()->Credential?,clock:()->Double,cancelled:()->Bool,verify:(Data,Data)->Bool
        private let deadline:Double
        private var previous:Double,messages=0,finished=false
        private init(credential:Credential,failures:Failures,challenge:Challenge,started:Double,
            current:@escaping ()->Credential?,clock:@escaping ()->Double,cancelled:@escaping ()->Bool,verify:@escaping (Data,Data)->Bool) {
            self.credential=credential;self.failures=failures;self.challenge=challenge;self.current=current;self.clock=clock
            self.cancelled=cancelled;self.verify=verify;previous=started;deadline=started+admissionSeconds
        }
        private(set) var retryNotBefore:Double?
        static func make(credential:Credential,failures:Failures,autoStart:Bool=false,
            current:@escaping ()->Credential?,clock:@escaping ()->Double={ProcessInfo.processInfo.systemUptime},
            cancelled:@escaping ()->Bool={false},random:(Int)->Data?=WebAuthentication.random,
            verify:((Data,Data)->Bool)?=nil)->Visit? {
            guard !cancelled(),current() === credential else {return nil}
            let began=clock(),deadline=began+admissionSeconds
            guard began.isFinite,began>=0,deadline.isFinite,deadline>began,failures.allows(at:began) != nil,
                !cancelled(),current() === credential,
                let nonce=random(nonceBytes),nonce.count==nonceBytes else {return nil}
            let visit=Visit(credential:credential,failures:failures,challenge:.init(salt:credential.salt,nonce:nonce,autoStart:autoStart),
                started:began,current:current,clock:clock,cancelled:cancelled,verify:verify ?? {credential.matches($0,nonce:$1)})
            guard visit.boundary()==nil else {return nil}
            return visit
        }
        private func boundary()->Verdict? {
            if cancelled() {return .cancelled}
            if current() !== credential {return .stale}
            let now=clock();guard now.isFinite,now>=previous else {return .invalidClock}
            if cancelled() {return .cancelled}
            if current() !== credential {return .stale}
            previous=now;return now>=deadline ? .timedOut:nil
        }
        private func retire(_ verdict:Verdict)->Verdict {finished=true;return verdict}
        private func wrong()->Verdict {
            if let reason=boundary() {return retire(reason)}
            guard let allowed=failures.allows(at:previous) else {return retire(.invalidClock)}
            guard allowed else {return retire(.lockedOut)}
            let retry=previous+wrongPasswordDelay
            guard retry.isFinite,retry>previous,failures.record(at:previous) else {return retire(.invalidClock)}
            retryNotBefore=retry;return retire(.wrongPassword)
        }
        func receive(_ data:Data)->Verdict {
            guard !finished else {return .closed}
            if let reason=boundary() {return retire(reason)}
            guard messages<maximumMessages else {return retire(.messageLimit)}
            messages += 1
            guard data.count<=maximumMessageBytes,String(data:data,encoding:.utf8) != nil,
                let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else {return wrong()}
            if let type=value["type"] as? String,type != "auth" {return .ignored}
            guard let text=value["response"] as? String,text.utf8.prefix(129).count<=128 else {return wrong()}
            // .NET's Base64 accepts whitespace, not arbitrary ignored punctuation.
            let compact=text.utf8.filter {![9,10,13,32].contains($0)}
            guard let proof=Data(base64Encoded:Data(compact)),proof.count==keyBytes else {return wrong()}
            if let reason=boundary() {return retire(reason)}
            guard let allowed=failures.allows(at:previous) else {return retire(.invalidClock)}
            guard allowed else {return retire(.lockedOut)}
            let accepted=verify(proof,challenge.nonce)
            // An injected/native proof receipt cannot publish after credential retirement or the deadline.
            if let reason=boundary() {return retire(reason)}
            guard accepted else {return wrong()}
            return retire((value["codec"] as? String)=="pcm16" ? .authenticatedPCM:.authenticatedOpus)
        }
    }
}
