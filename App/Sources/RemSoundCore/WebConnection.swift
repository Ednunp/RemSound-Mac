import Foundation

enum WebConnection {
    static let maximumIOBytes=16384
    enum Read {case bytes(Data),ending(Data,failed:Bool),end,failed}
    // A close receipt means callbacks and native resources are retired, not merely cancellation requested.
    protocol Transport:AnyObject {
        func read(maximum:Int,completion:@escaping (Read)->Void)
        func write(_ bytes:Data,completion:@escaping (Int?)->Void)
        func close(completion:@escaping ()->Void)
    }
    typealias Schedule=(DispatchQueue,@escaping ()->Void)->(() ->Void)?
    enum Failure:Equatable {case admission,transport,scheduler,read,write}
    enum Result {case ready(Ready),closed(WebAdmission.Reason),failed(Failure)}
    struct EndPolicy {let clock:()->Double;let schedule:Schedule}
    enum EndOutcome:Equatable {case notRequested,processed,failed,cancelled,deadline,clock}
    final class Ready {
        let codec:WebAdmission.Codec
        private let owner:Retirement
        fileprivate init(codec:WebAdmission.Codec,remainder:Data,queue:DispatchQueue,transport:Transport,permitted:@escaping ()->Bool) {
            self.codec=codec;owner=Retirement(queue:queue,transport:transport,remainder:remainder,permitted:permitted)
        }
        @discardableResult func read(maximum:Int=maximumIOBytes,completion:@escaping (Read)->Void)->Bool {owner.read(maximum,completion)}
        @discardableResult func write(_ bytes:Data,completion:@escaping (Int?)->Void)->Bool {owner.write(bytes,completion)}
        @discardableResult func readRespondingToEnd(maximum:Int=maximumIOBytes,reader:WebSocketPackets.Reader,policy:EndPolicy,completion:@escaping (Read,EndOutcome)->Void)->Bool {owner.readRespondingToEnd(maximum,reader,policy,completion)}
        @discardableResult func close(_ completion:(()->Void)?=nil)->Bool {owner.request(completion)}
        deinit {_ = owner.request(nil)}
    }
    private final class Once {
        private let lock=NSLock();private var claimed=false
        func claim()->Bool {lock.lock();defer {lock.unlock()};guard !claimed else {return false};claimed=true;return true}
    }
    private final class Ticket {
        private let lock=NSLock();private var cancelled=false,finished=false,pulsePending=false
        func cancel()->Bool {lock.lock();defer {lock.unlock()};guard !finished,!cancelled else {return false};cancelled=true;return true}
        var isCancelled:Bool {lock.lock();defer {lock.unlock()};return cancelled}
        func completeReady()->Bool {lock.lock();defer {lock.unlock()};guard !finished,!cancelled else {return false};finished=true;return true}
        func completeClosed()->Bool {lock.lock();defer {lock.unlock()};guard !finished else {return false};finished=true;return true}
        func pulse()->Bool {lock.lock();defer {lock.unlock()};guard !finished,!pulsePending else {return false};pulsePending=true;return true}
        func takePulse() {lock.lock();pulsePending=false;lock.unlock()}
    }
    final class Control {
        private let pulse:()->Void,retire:()->Bool
        fileprivate init(tick:@escaping ()->Void,cancel:@escaping ()->Bool) {pulse=tick;retire=cancel}
        func tick() {pulse()}
        @discardableResult func cancel()->Bool {retire()}
        deinit {_ = retire()}
    }
    static func start(queue:DispatchQueue,permitted:@escaping ()->Bool,admission:@escaping ()->WebAdmission.Visit?,
        transport:@escaping (@escaping ()->Bool)->Transport?,schedule:@escaping Schedule,completion:@escaping (Result)->Void)->Control {
        let driver=Driver(queue:queue,permitted:permitted,admission:admission,transport:transport,schedule:schedule,completion:completion)
        let control=Control(tick:driver.enqueuePulse,cancel:driver.cancel);queue.async {driver.start()};return control
    }
    private final class Driver {
        let queue:DispatchQueue
        private let key=DispatchSpecificKey<UInt8>(),ticket=Ticket()
        private var allowed:(()->Bool)?,makeAdmission:(()->WebAdmission.Visit?)?,factory:((@escaping ()->Bool)->Transport?)?,schedule:Schedule?,completion:((Result)->Void)?
        private var visit:WebAdmission.Visit?,transport:Transport?,stop:(()->Void)?,activeIO:UUID?,closing=false,finished=false
        private var keepAlive:Driver?,closingResult:Result?,readTerminal:Bool?
        init(queue:DispatchQueue,permitted:@escaping ()->Bool,admission:@escaping ()->WebAdmission.Visit?,transport:@escaping (@escaping ()->Bool)->Transport?,schedule:@escaping Schedule,completion:@escaping (Result)->Void) {
            self.queue=queue;allowed=permitted;makeAdmission=admission;factory=transport;self.schedule=schedule;self.completion=completion
            queue.setSpecific(key:key,value:1)
        }
        deinit {queue.setSpecific(key:key,value:nil)}
        func cancel()->Bool {guard ticket.cancel() else {return false};enqueuePulse();return true}
        func enqueuePulse() {
            guard ticket.pulse() else {return}
            queue.async {[self] in ticket.takePulse();drive()}
        }
        private func gate()->Bool {
            guard DispatchQueue.getSpecific(key:key)==1,!finished,!closing,!ticket.isCancelled,allowed?()==true,let visit else {return false}
            if case .close=visit.action {return false}
            return !ticket.isCancelled && allowed?()==true
        }
        func start() {
            keepAlive=self
            guard !ticket.isCancelled else {beginClose(.closed(.cancelled));return}
            guard allowed?()==true else {beginClose(.closed(.permission));return}
            visit=makeAdmission?()
            guard !ticket.isCancelled else {beginClose(.closed(.cancelled));return}
            guard allowed?()==true else {beginClose(.closed(.permission));return}
            guard let visit else {beginClose(.failed(.admission));return}
            if case let .close(reason)=visit.action {beginClose(.closed(reason));return}
            transport=factory?({[weak self] in self?.gate() ?? false})
            guard gate() else {drive();return}
            guard transport != nil else {beginClose(.failed(.transport));return}
            stop=schedule?(queue,{[weak self] in self?.enqueuePulse()})
            guard gate() else {drive();return}
            guard stop != nil else {beginClose(.failed(.scheduler));return}
            drive()
        }
        private func drive() {
            guard !finished,!closing else {return}
            guard !ticket.isCancelled else {beginClose(.closed(.cancelled));return}
            guard allowed?()==true else {beginClose(.closed(.permission));return}
            guard let visit else {beginClose(.failed(.admission));return}
            let action=visit.action
            guard !ticket.isCancelled else {beginClose(.closed(.cancelled));return}
            guard allowed?()==true else {beginClose(.closed(.permission));return}
            switch action {
            case let .close(reason):beginClose(.closed(reason))
            case let .accepted(codec):
                if let readTerminal {beginClose(readTerminal ? .failed(.read):.closed(.peerEnded));return}
                guard activeIO==nil,let bytes=visit.takeAuthenticatedRemainder(),let transport else {
                    if activeIO==nil {beginClose(.closed(.stale))};return
                }
                stopDriver()
                guard let lifetime=visit.authenticatedPermission(),let persistent=allowed,gate(),ticket.completeReady() else {beginClose(.closed(ticket.isCancelled ? .cancelled:.stale));return}
                self.transport=nil
                let ready=Ready(codec:codec,remainder:bytes,queue:queue,transport:transport,permitted:{persistent() && lifetime() && persistent()})
                finish(.ready(ready))
            case .read:
                if let readTerminal {
                    if readTerminal {beginClose(.failed(.read))} else {visit.endOfInput();drive()}
                    return
                }
                guard activeIO==nil,let transport else {return}
                let id=UUID(),once=Once();activeIO=id
                transport.read(maximum:maximumIOBytes) {[weak self] result in
                    guard once.claim(),let self else {return}
                    let bounded:Read
                    switch result {
                    case .bytes(let data),.ending(let data,_):bounded=(data.isEmpty || data.count>maximumIOBytes) ? .failed:result
                    default:bounded=result
                    }
                    queue.async {[weak self] in self?.readFinished(id,bounded)}
                }
            case let .write(writeID,bytes):
                guard activeIO==nil,let transport else {return}
                let part=Data(bytes.prefix(maximumIOBytes)),id=UUID(),once=Once();activeIO=id
                guard !part.isEmpty else {beginClose(.failed(.write));return}
                transport.write(part) {[weak self] count in
                    guard once.claim(),let self else {return}
                    queue.async {[weak self] in self?.writeFinished(id,writeID,count,part.count)}
                }
            case .wait:break
            }
        }
        private func readFinished(_ id:UUID,_ result:Read) {
            guard !finished,!closing,activeIO==id else {return};activeIO=nil
            guard gate() else {drive();return}
            switch result {
            case let .bytes(data):visit?.receive(data)
            case let .ending(data,failed):readTerminal=failed;visit?.receive(data)
            case .end:visit?.endOfInput()
            case .failed:beginClose(.failed(.read));return
            }
            drive()
        }
        private func writeFinished(_ id:UUID,_ writeID:UUID,_ count:Int?,_ maximum:Int) {
            guard !finished,!closing,activeIO==id else {return};activeIO=nil
            guard gate() else {drive();return}
            guard let count,count>0,count<=maximum,visit?.acknowledge(id:writeID,written:count)==true else {beginClose(.failed(.write));return}
            drive()
        }
        private func stopDriver() {let cancel=stop;stop=nil;cancel?()}
        private func beginClose(_ result:Result) {
            guard !finished,!closing else {return}
            closing=true;closingResult=result;activeIO=nil;visit?.cancel();visit=nil;stopDriver()
            guard let transport else {closed();return}
            let once=Once()
            transport.close {[weak self] in
                guard once.claim(),let self else {return}
                queue.async {[weak self] in self?.closed()}
            }
        }
        private func closed() {
            guard !finished,closing,let result=closingResult,ticket.completeClosed() else {return}
            transport=nil;finish(result)
        }
        private func finish(_ result:Result) {
            guard !finished else {return};finished=true;stopDriver()
            let reply=completion;completion=nil;allowed=nil;makeAdmission=nil;factory=nil;schedule=nil;visit=nil;closingResult=nil
            keepAlive=nil;reply?(result)
        }
    }
    private final class Retirement {
        private let queue:DispatchQueue,lock=NSLock()
        // Admission flags and lane identities are locked; transport, permission and buffers live on queue.
        private var done=false,closing=false,abortRequested=false,reserved=0,readID:UUID?,writeID:UUID?
        private var transport:Transport?,allowed:(()->Bool)?,keepAlive:Retirement?,remainder:Data
        private var waiters=[()->Void](),started=false,closeReceived=false
        private static let maximumWaiters=16,maximumEndEvents=32
        private static let endSeconds=3.0
        private var endWrite:EndWrite?,readerIdentity:ObjectIdentifier?
        private let readerOwner=UUID()
        private struct EndRead {let reader:WebSocketPackets.Reader,policy:EndPolicy}
        private final class EndWrite {
            let id:UUID,read:Read,bytes:Data,policy:EndPolicy,reply:(Read,EndOutcome)->Void,ticket=Ticket()
            var previous:Double,target:Double,offset=0,pending:UUID?,stop:(()->Void)?,reason:EndOutcome?
            init(_ id:UUID,_ read:Read,_ bytes:Data,_ policy:EndPolicy,_ began:Double,_ reply:@escaping (Read,EndOutcome)->Void) {
                self.id=id;self.read=read;self.bytes=bytes;self.policy=policy;self.previous=began;target=began+endSeconds;self.reply=reply
            }
            func stopDriver() {let cancel=stop;stop=nil;_ = ticket.completeClosed();cancel?()}
        }
        init(queue:DispatchQueue,transport:Transport,remainder:Data,permitted:@escaping ()->Bool) {
            self.queue=queue;self.transport=transport;self.remainder=remainder;allowed=permitted
        }
        private enum Lane {case read,write}
        private func identity(_ lane:Lane)->UUID? {lane == .read ? readID:writeID}
        private func setIdentity(_ lane:Lane,_ id:UUID?) {if lane == .read {readID=id} else {writeID=id}}
        private func admit(_ lane:Lane = .read)->UUID? {
            lock.lock();defer {lock.unlock()};guard !closing,!done,identity(lane)==nil else {return nil}
            let id=UUID();setIdentity(lane,id);return id
        }
        private func live(_ id:UUID,_ lane:Lane = .read)->Bool {lock.lock();defer {lock.unlock()};return !closing && !done && identity(lane)==id}
        private func owns(_ id:UUID,_ lane:Lane = .read)->Bool {lock.lock();defer {lock.unlock()};return !done && identity(lane)==id}
        private func release(_ id:UUID,_ lane:Lane = .read)->Bool {
            lock.lock();defer {lock.unlock()};guard identity(lane)==id else {return false};setIdentity(lane,nil);return true
        }
        private func releaseIfIdle() {
            lock.lock();let idle = !closing && readID==nil && writeID==nil;lock.unlock()
            if idle {keepAlive=nil}
        }
        private func canCompleteWrite(_ id:UUID)->Bool {
            lock.lock();defer {lock.unlock()}
            return !done && !abortRequested && writeID==id && (!closing || endWrite != nil)
        }
        func read(_ maximum:Int,_ reply:@escaping (Read)->Void)->Bool {read(maximum,nil) {read,_ in reply(read)}}
        func readRespondingToEnd(_ maximum:Int,_ reader:WebSocketPackets.Reader,_ policy:EndPolicy,_ reply:@escaping (Read,EndOutcome)->Void)->Bool {
            read(maximum,EndRead(reader:reader,policy:policy),reply)
        }
        private func read(_ maximum:Int,_ end:EndRead?,_ reply:@escaping (Read,EndOutcome)->Void)->Bool {
            guard maximum>0,maximum<=maximumIOBytes,let id=admit() else {return false}
            queue.async {[self] in
                keepAlive=self
                if let end {
                    let identity=ObjectIdentifier(end.reader)
                    guard (readerIdentity==nil || readerIdentity==identity),end.reader.bindCloseResponses(to:readerOwner) else {received(id,.failed,nil,reply);return}
                    readerIdentity=identity
                }
                guard live(id),allowed?()==true,live(id),let transport else {received(id,.failed,nil,reply);return}
                if !remainder.isEmpty {
                    let bytes=Data(remainder.prefix(maximum));remainder=Data(remainder.dropFirst(bytes.count))
                    received(id,.bytes(bytes),end,reply);return
                }
                let once=Once()
                transport.read(maximum:maximum) {[weak self] result in
                    guard once.claim(),let self else {return}
                    let bounded:Read
                    switch result {
                    case .bytes(let bytes),.ending(let bytes,_):bounded=(!bytes.isEmpty && bytes.count<=maximum) ? result:.failed
                    default:bounded=result
                    }
                    queue.async {[weak self] in self?.received(id,bounded,end,reply)}
                }
            }
            return true
        }
        private func received(_ id:UUID,_ result:Read,_ end:EndRead?,_ reply:@escaping (Read,EndOutcome)->Void) {
            guard owns(id) else {return}
            var delivered=result
            if !live(id) || allowed?() != true || !live(id) {delivered = .failed}
            if let end {
                switch delivered {
                case .ending(let bytes,false):beginEnd(id,delivered,bytes,end,reply);return
                case .end:beginEnd(id,delivered,Data(),end,reply);return
                default:break
                }
            }
            completeRead(id,delivered,.notRequested,reply)
        }
        private func completeRead(_ id:UUID,_ delivered:Read,_ outcome:EndOutcome,_ reply:(Read,EndOutcome)->Void) {
            switch delivered {case .bytes:break;default:_ = request(nil)}
            guard release(id) else {return}
            releaseIfIdle()
            reply(delivered,outcome);finishIfRetired()
        }
        private func beginEnd(_ id:UUID,_ read:Read,_ bytes:Data,_ context:EndRead,_ reply:@escaping (Read,EndOutcome)->Void) {
            let began=context.policy.clock(),target=began+Self.endSeconds
            guard began.isFinite,began>=0,target.isFinite,target>began else {completeRead(id,read,.clock,reply);return}
            guard live(id),allowed?()==true,live(id) else {completeRead(id,.failed,.cancelled,reply);return}
            var proof=context.reader.takeCloseResponse(),input=bytes,events=0
            while proof==nil,!input.isEmpty,events<Self.maximumEndEvents {
                let receipt=context.reader.feed(input);events += 1
                guard receipt.consumedBytes>0,receipt.consumedBytes<=input.count else {break}
                input=Data(input.dropFirst(receipt.consumedBytes));proof=context.reader.takeCloseResponse()
                if receipt.event == .pending {break}
            }
            guard let wire=proof?.takeBytes(),wire.count>=2,wire.count<=WebSocketPackets.CloseResponse.maximumBytes else {
                _ = context.reader.endOfInput();completeRead(id,read,.notRequested,reply);return
            }
            let operation=EndWrite(id,read,wire,context.policy,began,reply);endWrite=operation
            // Freeze new data while an already admitted write retires; the original response budget includes that wait.
            lock.lock();let accepted = !closing && !done && readID==id
            if accepted {closing=true};lock.unlock()
            guard accepted else {endFinished(operation,.cancelled);return}
            if let reason=endBoundary(operation) {endFinished(operation,reason);return}
            operation.stop=operation.policy.schedule(queue,{[weak self,weak operation] in
                guard let self,let operation,operation.ticket.pulse() else {return}
                queue.async {[weak self,weak operation] in
                    guard let self,let operation else {return};operation.ticket.takePulse()
                    guard self.endWrite === operation else {return}
                    if let reason=self.endBoundary(operation) {self.abortEnd(operation,reason)}
                }
            })
            if let reason=endBoundary(operation) {endFinished(operation,reason);return}
            guard operation.stop != nil else {endFinished(operation,.failed);return}
            endSend(operation)
        }
        private func endBoundary(_ operation:EndWrite)->EndOutcome? {
            if let reason=operation.reason {return reason}
            lock.lock();let cancelled=abortRequested || done || readID != operation.id;lock.unlock()
            guard !cancelled,allowed?()==true else {return .cancelled}
            let now=operation.policy.clock()
            lock.lock();let after=abortRequested || done || readID != operation.id;lock.unlock()
            guard !after,allowed?()==true else {return .cancelled}
            guard now.isFinite,now>=operation.previous else {return .clock}
            operation.previous=now
            return now<operation.target ? nil:.deadline
        }
        private func endSend(_ operation:EndWrite) {
            guard endWrite === operation else {return}
            if let reason=endBoundary(operation) {abortEnd(operation,reason);return}
            lock.lock();let writing=writeID != nil;lock.unlock()
            guard !writing else {return}
            guard let transport,operation.offset<operation.bytes.count else {endFinished(operation,.failed);return}
            let part=Data(operation.bytes.dropFirst(operation.offset)),writeID=UUID(),once=Once();operation.pending=writeID
            transport.write(part) {[weak self,weak operation] count in
                guard once.claim(),let self,let operation else {return}
                queue.async {[weak self,weak operation] in
                    guard let self,let operation,self.endWrite === operation,operation.pending==writeID else {return}
                    operation.pending=nil
                    if let reason=self.endBoundary(operation) {self.endFinished(operation,reason);return}
                    guard let count,count>0,count<=part.count else {self.endFinished(operation,.failed);return}
                    operation.offset += count
                    if operation.offset==operation.bytes.count {self.endFinished(operation,.processed)} else {self.endSend(operation)}
                }
            }
        }
        private func abortEnd(_ operation:EndWrite,_ reason:EndOutcome) {
            guard endWrite === operation else {return}
            if operation.reason==nil {operation.reason=reason};operation.stopDriver()
            if operation.pending==nil {endFinished(operation,operation.reason ?? reason)} else {_ = request(nil)}
        }
        private func endFinished(_ operation:EndWrite,_ outcome:EndOutcome) {
            guard endWrite === operation,operation.pending==nil else {return}
            operation.stopDriver();endWrite=nil
            completeRead(operation.id,operation.read,outcome,operation.reply)
        }
        func write(_ bytes:Data,_ reply:@escaping (Int?)->Void)->Bool {
            guard !bytes.isEmpty,bytes.count<=maximumIOBytes,let id=admit(.write) else {return false}
            queue.async {[self] in
                keepAlive=self
                guard live(id,.write),allowed?()==true,live(id,.write),let transport else {written(id,nil,bytes.count,reply);return}
                let once=Once()
                transport.write(bytes) {[weak self] count in
                    guard once.claim(),let self else {return}
                    queue.async {[weak self] in self?.written(id,count,bytes.count,reply)}
                }
            }
            return true
        }
        private func written(_ id:UUID,_ count:Int?,_ maximum:Int,_ reply:(Int?)->Void) {
            guard owns(id,.write) else {return}
            let accepted:Int?
            if canCompleteWrite(id),allowed?()==true,canCompleteWrite(id),let count,count>0,count<=maximum {accepted=count} else {accepted=nil}
            guard release(id,.write) else {return}
            releaseIfIdle()
            reply(accepted)
            if let operation=endWrite {
                if let reason=endBoundary(operation) {abortEnd(operation,reason)}
                else if accepted != maximum {abortEnd(operation,.failed)} else {endSend(operation)}
            } else if accepted==nil {_ = request(nil)}
            finishIfRetired()
        }
        func request(_ completion:(()->Void)?)->Bool {
            lock.lock()
            if done {lock.unlock();if let completion {queue.async(execute:completion)};return true}
            if completion != nil {guard reserved<Self.maximumWaiters else {lock.unlock();return false};reserved += 1}
            closing=true;abortRequested=true;lock.unlock()
            queue.async {[self] in
                lock.lock();let alreadyDone=done;lock.unlock()
                if alreadyDone {completion?();return}
                if let completion {waiters.append(completion)}
                if let operation=endWrite {
                    if operation.reason==nil {operation.reason = .cancelled};operation.stopDriver()
                    if operation.pending==nil {endFinished(operation,operation.reason ?? .cancelled)}
                }
                guard !started else {finishIfRetired();return};started=true;keepAlive=self
                remainder.removeAll(keepingCapacity:false);allowed=nil
                guard let transport else {closeReceived=true;finishIfRetired();return}
                let once=Once()
                transport.close {[weak self] in guard once.claim(),let self else {return};queue.async {[weak self] in self?.closeReceived=true;self?.finishIfRetired()}}
            }
            return true
        }
        private func finishIfRetired() {
            guard closeReceived else {return}
            lock.lock();guard closing,!done,readID==nil,writeID==nil else {lock.unlock();return};done=true;reserved=0;lock.unlock()
            let callbacks=waiters;waiters.removeAll();transport=nil;allowed=nil;remainder.removeAll(keepingCapacity:false);keepAlive=nil
            for callback in callbacks {callback()}
        }
    }
}
