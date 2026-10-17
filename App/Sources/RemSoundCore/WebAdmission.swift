import Foundation

enum WebAdmission {
    static let maximumPageBytes=262144,maximumEvents=32
    private static let httpSeconds=10.0,maximumPolicyEntries=16
    struct Policy {let hosts:Set<String>,origins:Set<String>;var allowMissingOrigin=false,autoStart=false}
    enum Codec:Equatable {case opus,pcm}
    enum Reason:Equatable {case permission,stale,cancelled,clock,deadline,request,policy,protocolFailure,limit,writeFailure,unexpectedInput,pageDone,wrongPassword,lockedOut,peerEnded}
    enum Action:Equatable {case read,write(id:UUID,bytes:Data),wait(until:Double),accepted(Codec),close(Reason)}
    final class Visit {
        private enum Stage {case http,upgrade,challenge,auth,page,delayed,refusal,peerClose,accepted(Codec),closed(Reason)}
        private struct Write {var id=UUID();let bytes:Data;var offset=0}
        private let credential:WebAuthentication.Credential,failures:WebAuthentication.Failures,page:Data,policy:Policy
        private let permitted:()->Bool,current:()->WebAuthentication.Credential?,clock:()->Double,random:(Int)->Data?,verify:((Data,Data)->Bool)?
        private let head=WebHandshake.Reader(),frames=WebSocketPackets.Reader()
        private var stage=Stage.http,previous:Double,deadline:Double,checking=false
        private var pending:Write?,remainder=Data(),auth:WebAuthentication.Visit?,events=0,draining=false
        private var delayedUntil:Double?,refusalReason=Reason.wrongPassword
        private init(credential:WebAuthentication.Credential,failures:WebAuthentication.Failures,page:Data,policy:Policy,
            permitted:@escaping ()->Bool,current:@escaping ()->WebAuthentication.Credential?,clock:@escaping ()->Double,
            random:@escaping (Int)->Data?,verify:((Data,Data)->Bool)?,started:Double) {
            self.credential=credential;self.failures=failures;self.page=page;self.policy=policy;self.permitted=permitted;self.current=current
            self.clock=clock;self.random=random;self.verify=verify;previous=started;deadline=started+httpSeconds
        }
        static func make(credential:WebAuthentication.Credential,failures:WebAuthentication.Failures,page:Data,policy:Policy,
            permitted:@escaping ()->Bool,current:@escaping ()->WebAuthentication.Credential?,clock:@escaping ()->Double,
            random:@escaping (Int)->Data?=WebAuthentication.random,verify:((Data,Data)->Bool)?=nil)->Visit? {
            guard permitted(),current() === credential,page.count>0,page.count<=maximumPageBytes,valid(policy) else {return nil}
            let started=clock(),deadline=started+httpSeconds
            guard started.isFinite,started>=0,deadline.isFinite,deadline>started,permitted(),current() === credential else {return nil}
            return Visit(credential:credential,failures:failures,page:page,policy:policy,permitted:permitted,current:current,clock:clock,random:random,verify:verify,started:started)
        }
        private static func valid(_ policy:Policy)->Bool {
            guard !policy.hosts.isEmpty,policy.hosts.count<=maximumPolicyEntries,policy.origins.count<=maximumPolicyEntries,
                  policy.hosts.allSatisfy({!$0.isEmpty && $0.utf8.count<=261}) else {return false}
            return policy.origins.allSatisfy {origin in
                guard origin.utf8.count<=512,let value=URLComponents(string:origin),["http","https"].contains(value.scheme),
                      value.host?.isEmpty==false,value.user==nil,value.password==nil,value.path.isEmpty,value.query==nil,value.fragment==nil else {return false}
                return value.port.map({$0>0 && $0<=65535}) ?? true
            }
        }
        // These are local protocol actions. Close requests never prove transport quiescence or remote rollback.
        var action:Action {
            guard boundary() else {return closedAction}
            if case .delayed=stage,let until=delayedUntil {
                if previous<until {return .wait(until:until)}
                queueRefusal(refusalReason)
            }
            drain()
            if let pending {return .write(id:pending.id,bytes:pending.bytes.dropFirst(pending.offset))}
            switch stage {
            case let .accepted(codec):return .accepted(codec)
            case let .closed(reason):return .close(reason)
            default:return .read
            }
        }
        private var closedAction:Action {
            if case let .closed(reason)=stage {return .close(reason)}
            return .close(.protocolFailure)
        }
        func takeAuthenticatedRemainder()->Data? {
            guard case .accepted=stage,boundary() else {return nil}
            let data=remainder;remainder.removeAll(keepingCapacity:false);return data
        }
        // Transfer only the persistent identity/permission proof, not admission buffers or its expiring visit.
        func authenticatedPermission()->(() ->Bool)? {
            guard case .accepted=stage,boundary() else {return nil}
            let credential=self.credential,permitted=self.permitted,current=self.current
            return {permitted() && current() === credential && permitted() && current() === credential}
        }
        func cancel() {close(.cancelled)}
        func endOfInput() {
            guard boundary() else {return}
            if pending != nil {close(.writeFailure);return}
            if case .http=stage {close(.request)}
            else {close(frames.endOfInput() == .protocolError ? .protocolFailure:.peerEnded)}
        }
        private func close(_ reason:Reason) {
            if case .closed=stage {return}
            stage = .closed(reason);pending=nil;remainder.removeAll(keepingCapacity:false);auth=nil;head.cancel();frames.cancel()
        }
        private func boundary()->Bool {
            if case .closed=stage {return false}
            guard !checking else {close(.clock);return false}
            checking=true;defer {checking=false}
            guard permitted() else {close(.permission);return false}
            guard current() === credential else {close(.stale);return false}
            let now=clock()
            if case .closed=stage {return false}
            guard permitted() else {close(.permission);return false}
            guard current() === credential else {close(.stale);return false}
            guard now.isFinite,now>=previous else {close(.clock);return false}
            previous=now
            guard now<deadline else {close(.deadline);return false}
            return true
        }
        func receive(_ bytes:Data) {
            guard !draining else {close(.unexpectedInput);return}
            guard boundary() else {return}
            guard pending==nil,remainder.isEmpty else {close(.unexpectedInput);return}
            guard bytes.count<=WebSocketPackets.maximumReadBytes else {close(.limit);return}
            if case .http=stage {
                let result=head.feed(bytes)
                switch result.outcome {
                case .pending:return
                case .page:
                    // The same explicit authority set governs static page and upgrade routing.
                    // Page requests have no challenge/proof and reveal no credential values.
                    guard let host=head.validatedPageHost,policy.hosts.contains(where:{$0.lowercased()==host.lowercased()}) else {close(.policy);return}
                    let headers="HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline' blob:; style-src 'unsafe-inline'; connect-src 'self'; worker-src blob:\r\nConnection: close\r\n\r\n"
                    stage = .page;pending=Write(bytes:Data(headers.utf8)+page)
                case let .upgrade(accept,host,origin):
                    guard policy.hosts.contains(where:{$0.lowercased()==host.lowercased()}),origin.map({policy.origins.contains($0)}) ?? policy.allowMissingOrigin else {close(.policy);return}
                    let headers="HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
                    remainder=Data(bytes.dropFirst(result.consumedBytes));stage = .upgrade;pending=Write(bytes:Data(headers.utf8))
                case .limit:close(.limit)
                default:close(.request)
                }
            } else if case .auth=stage {remainder=bytes;drain()}
            else {close(.unexpectedInput)}
        }
        @discardableResult func acknowledge(id:UUID,written:Int)->Bool {
            guard var write=pending,write.id==id else {return false}
            guard boundary() else {return false}
            let available=write.bytes.count-write.offset
            guard written>0,written<=available else {close(.writeFailure);return false}
            write.offset += written
            if write.offset<write.bytes.count {write.id=UUID();pending=write;return true}
            pending=nil
            switch stage {
            case .page:close(.pageDone)
            case .upgrade:beginChallenge()
            case .challenge:stage = .auth;drain()
            case .refusal:close(refusalReason)
            case .peerClose:close(.peerEnded)
            case .auth:drain()
            default:close(.writeFailure)
            }
            return true
        }
        private func beginChallenge() {
            guard boundary() else {return}
            let began=previous,target=began+WebAuthentication.admissionSeconds
            guard target.isFinite,target>began else {close(.clock);return}
            deadline=target
            let visit=WebAuthentication.Visit.make(credential:credential,failures:failures,autoStart:policy.autoStart,current:current,clock:clock,
                cancelled:{[weak self] in guard let self else {return true};if case .closed=self.stage {return true};return !self.permitted()},random:random,verify:verify)
            guard boundary() else {return}
            guard let visit,let frame=WebSocketPackets.serverFrame(kind:.text,payload:visit.challenge.json) else {close(.protocolFailure);return}
            auth=visit;stage = .challenge;pending=Write(bytes:frame)
        }
        private func drain() {
            guard !draining else {close(.unexpectedInput);return}
            draining=true;defer {draining=false}
            while pending==nil,!remainder.isEmpty {
                guard case .auth=stage,boundary() else {return}
                let result=frames.feed(remainder)
                guard result.consumedBytes>=0,result.consumedBytes<=remainder.count else {close(.protocolFailure);return}
                remainder=Data(remainder.dropFirst(result.consumedBytes))
                if result.event == .pending {return}
                guard events<maximumEvents else {close(.limit);return};events += 1
                switch result.event {
                case let .text(data):
                    guard let auth else {close(.protocolFailure);return}
                    let verdict=auth.receive(data)
                    guard boundary() else {return}
                    switch verdict {
                    case .ignored:continue
                    case .authenticatedOpus:stage = .accepted(.opus)
                    case .authenticatedPCM:stage = .accepted(.pcm)
                    case .wrongPassword:
                        guard let until=auth.retryNotBefore else {close(.clock);return}
                        refusalReason = .wrongPassword;delayedUntil=until;stage = .delayed;remainder.removeAll(keepingCapacity:false)
                    case .lockedOut:queueRefusal(.lockedOut)
                    case .messageLimit:close(.limit)
                    case .timedOut:close(.deadline)
                    case .invalidClock:close(.clock)
                    case .stale:close(.stale)
                    case .cancelled:close(.cancelled)
                    default:close(.protocolFailure)
                    }
                case let .ping(data):
                    guard let frame=WebSocketPackets.serverFrame(kind:.pong,payload:data) else {close(.protocolFailure);return}
                    pending=Write(bytes:frame)
                case .pong:continue
                case let .close(data):
                    guard let frame=WebSocketPackets.serverFrame(kind:.close,payload:data) ?? WebSocketPackets.serverFrame(kind:.close,payload:Data()) else {close(.protocolFailure);return}
                    stage = .peerClose;pending=Write(bytes:frame);remainder.removeAll(keepingCapacity:false)
                case .limit:close(.limit)
                default:close(.protocolFailure)
                }
            }
        }
        private func queueRefusal(_ reason:Reason) {
            let text=reason == .lockedOut ? "Too many wrong passwords. Try again in a few minutes.":"The password was not accepted."
            guard let data=try? JSONSerialization.data(withJSONObject:["type":"refused","reason":text]),let frame=WebSocketPackets.serverFrame(kind:.text,payload:data) else {close(.protocolFailure);return}
            refusalReason=reason;stage = .refusal;pending=Write(bytes:frame);remainder.removeAll(keepingCapacity:false)
        }
    }
}
