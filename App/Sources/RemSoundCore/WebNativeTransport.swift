import Foundation
import Network
import RemSoundRuntime

enum WebNativeTransport {
    private static let driverInterval:TimeInterval=0.02,maximumDriverLifetime:TimeInterval=45
    enum State {case ready,failed,cancelled}
    protocol Raw:AnyObject {
        func start(queue:DispatchQueue,state:@escaping (State)->Void)
        func receive(maximum:Int,completion:@escaping (Data?,Bool,Bool)->Void)
        func send(_ bytes:Data,completion:@escaping (Bool)->Void)
        func cancel()
    }
    // Called on the same serial owner as WebConnection. The returned transport owns a late factory result, too.
    static func make(queue:DispatchQueue,permitted:@escaping ()->Bool,factory:(()->Bool)->Raw?)->WebConnection.Transport? {
        guard permitted(),let raw=factory(permitted) else {return nil}
        let owner=Owner(queue:queue,permitted:permitted,raw:raw)
        owner.start();return Handle(owner)
    }
    static func accepted(_ connection:NWConnection,runtime:RuntimeConfiguration,queue:DispatchQueue,permitted:@escaping ()->Bool)->WebConnection.Transport? {
        guard !runtime.isIsolated,permitted(),isLoopback(connection.endpoint) else {return nil}
        return loopback(connection,queue:queue,permitted:{!runtime.isIsolated && permitted()})
    }
    // Caller transfers an already owned, unstarted numeric loopback connection. Refusal leaves ownership with caller.
    static func loopback(_ connection:NWConnection,queue:DispatchQueue,permitted:@escaping ()->Bool)->WebConnection.Transport? {
        guard permitted(),isLoopback(connection.endpoint) else {return nil}
        return make(queue:queue,permitted:permitted,factory:{gate in gate() ? Native(connection):nil})
    }
    static func schedule(permitted:@escaping ()->Bool,clock:@escaping ()->Double={ProcessInfo.processInfo.systemUptime})->WebConnection.Schedule {
        {queue,pulse in
            guard permitted() else {return nil}
            let start=clock(),deadline=start+maximumDriverLifetime
            guard start.isFinite,start>=0,deadline.isFinite,deadline>start,permitted() else {return nil}
            let timer=DispatchSource.makeTimerSource(queue:queue),stop=Stop()
            var last=start
            timer.schedule(deadline:.now()+driverInterval,repeating:driverInterval,leeway:.milliseconds(2))
            timer.setEventHandler {
                guard !stop.stopped else {return}
                let now=clock()
                let retire = !permitted() || !now.isFinite || now<last || now>=deadline
                last=now;pulse()
                if retire {stop.cancel(timer)}
            }
            timer.resume()
            return {stop.cancel(timer)}
        }
    }
    private final class Stop {
        private let lock=NSLock();private var done=false
        var stopped:Bool {lock.lock();defer {lock.unlock()};return done}
        func cancel(_ timer:DispatchSourceTimer) {
            lock.lock();guard !done else {lock.unlock();return};done=true;lock.unlock()
            timer.setEventHandler {};timer.cancel()
        }
    }
    private static func isLoopback(_ endpoint:NWEndpoint)->Bool {
        guard case let .hostPort(host,_)=endpoint else {return false}
        switch host {
        case .ipv4(let address):return address.rawValue.first==127
        case .ipv6(let address):return address == .loopback
        default:return false
        }
    }
    private final class Native:Raw {
        private let connection:NWConnection
        init(_ connection:NWConnection) {self.connection=connection}
        func start(queue:DispatchQueue,state:@escaping (State)->Void) {
            connection.stateUpdateHandler={value in
                switch value {case .ready:state(.ready);case .failed:state(.failed);case .cancelled:state(.cancelled);default:break}
            }
            connection.start(queue:queue)
        }
        func receive(maximum:Int,completion:@escaping (Data?,Bool,Bool)->Void) {
            connection.receive(minimumIncompleteLength:1,maximumLength:maximum) {data,_,complete,error in completion(data,complete,error != nil)}
        }
        func send(_ bytes:Data,completion:@escaping (Bool)->Void) {
            // contentProcessed is local stack processing, never browser delivery or an acknowledgement.
            connection.send(content:bytes,completion:.contentProcessed {completion($0 == nil)})
        }
        func cancel() {connection.cancel()}
        deinit {connection.stateUpdateHandler=nil}
    }
    private final class Once {
        private let lock=NSLock();private var taken=false
        func claim()->Bool {lock.lock();defer {lock.unlock()};guard !taken else {return false};taken=true;return true}
    }
    private final class Handle:WebConnection.Transport {
        private let owner:Owner
        init(_ owner:Owner) {self.owner=owner}
        func read(maximum:Int,completion:@escaping (WebConnection.Read)->Void) {guard maximum>0,maximum<=WebConnection.maximumIOBytes else {owner.queue.async {completion(.failed)};return};owner.queue.async {[owner] in owner.read(maximum,completion)}}
        func write(_ bytes:Data,completion:@escaping (Int?)->Void) {guard !bytes.isEmpty,bytes.count<=WebConnection.maximumIOBytes else {owner.queue.async {completion(nil)};return};owner.queue.async {[owner] in owner.write(bytes,completion)}}
        func close(completion:@escaping ()->Void) {owner.queue.async {[owner] in owner.close(completion)}}
        deinit {owner.queue.async {[owner] in owner.close(nil)}}
    }
    private final class Owner {
        let queue:DispatchQueue
        private var allowed:(()->Bool)?,raw:Raw?,keepAlive:Owner?
        private var ready=false,closing=false,cancelled=false,done=false,terminal:Bool?
        private var activeRead:UUID?,activeWrite:UUID?,pendingRead:(()->Void)?,pendingWrite:(()->Void)?
        private var readFailure:(()->Void)?,writeFailure:(()->Void)?,closeWaiters=[()->Void]()
        init(queue:DispatchQueue,permitted:@escaping ()->Bool,raw:Raw) {self.queue=queue;allowed=permitted;self.raw=raw}
        func start() {
            keepAlive=self
            raw?.start(queue:queue) {[weak self] state in guard let self else {return};queue.async {[weak self] in self?.changed(state)}}
            if allowed?() != true {close(nil)}
        }
        private func changed(_ state:State) {
            guard !done else {return}
            switch state {
            case .ready:
                guard !closing else {return}
                guard allowed?()==true else {close(nil);return}
                ready=true
                let read=pendingRead;pendingRead=nil;readFailure=nil;read?()
                let write=pendingWrite;pendingWrite=nil;writeFailure=nil;write?()
            case .failed:close(nil)
            case .cancelled:cancelled=true;close(nil);finishIfRetired()
            }
        }
        func read(_ maximum:Int,_ reply:@escaping (WebConnection.Read)->Void) {
            guard maximum>0,maximum<=WebConnection.maximumIOBytes,!closing,!done,activeRead==nil else {reply(.failed);return}
            guard allowed?()==true else {reply(.failed);close(nil);return}
            if let terminal {reply(terminal ? .failed:.end);return}
            let id=UUID();activeRead=id
            let work={ [weak self] in
                guard let self,!closing,activeRead==id,let raw else {return}
                guard allowed?()==true else {activeRead=nil;reply(.failed);close(nil);return}
                let once=Once()
                raw.receive(maximum:maximum) {[weak self] data,end,failed in
                    guard once.claim(),let self else {return}
                    // Validate before retaining/copying any supplied payload into the owner queue.
                    let oversized=(data?.count ?? 0)>maximum
                    let bytes=oversized ? nil:data
                    queue.async {[weak self] in self?.received(id,bytes,end,failed || oversized,maximum,reply)}
                }
            }
            if ready {work()} else {pendingRead=work;readFailure={reply(.failed)}}
        }
        private func received(_ id:UUID,_ data:Data?,_ end:Bool,_ failed:Bool,_ maximum:Int,_ reply:(WebConnection.Read)->Void) {
            guard activeRead==id,!done else {return};activeRead=nil
            if closing {reply(.failed);finishIfRetired();return}
            guard allowed?()==true else {reply(.failed);close(nil);return}
            if let data,!data.isEmpty,data.count<=maximum {
                if end || failed {terminal=failed;reply(.ending(data,failed:failed))} else {reply(.bytes(data))}
            } else if failed {terminal=true;reply(.failed);close(nil)}
            else if end {terminal=false;reply(.end)}
            else {terminal=true;reply(.failed);close(nil)}
        }
        func write(_ bytes:Data,_ reply:@escaping (Int?)->Void) {
            guard !bytes.isEmpty,bytes.count<=WebConnection.maximumIOBytes,!closing,!done,activeWrite==nil else {reply(nil);return}
            guard allowed?()==true,terminal != true else {reply(nil);close(nil);return}
            let id=UUID();activeWrite=id
            let work={ [weak self] in
                guard let self,!closing,activeWrite==id,let raw else {return}
                guard allowed?()==true else {activeWrite=nil;reply(nil);close(nil);return}
                let once=Once()
                raw.send(bytes) {[weak self] success in
                    guard once.claim(),let self else {return}
                    queue.async {[weak self] in self?.sent(id,success,bytes.count,reply)}
                }
            }
            if ready {work()} else {pendingWrite=work;writeFailure={reply(nil)}}
        }
        private func sent(_ id:UUID,_ success:Bool,_ count:Int,_ reply:(Int?)->Void) {
            guard activeWrite==id,!done else {return};activeWrite=nil
            if closing {reply(nil);finishIfRetired();return}
            guard success,allowed?()==true else {reply(nil);close(nil);return}
            reply(count)
        }
        func close(_ reply:(()->Void)?) {
            if done {reply?();return}
            if let reply {closeWaiters.append(reply)}
            guard !closing else {finishIfRetired();return}
            closing=true
            // Queued lanes have no native callbacks to retire. Complete both before cancelling.
            if pendingRead != nil {let fail=readFailure;pendingRead=nil;readFailure=nil;activeRead=nil;fail?()}
            if pendingWrite != nil {let fail=writeFailure;pendingWrite=nil;writeFailure=nil;activeWrite=nil;fail?()}
            raw?.cancel();finishIfRetired()
        }
        private func finishIfRetired() {
            guard closing,cancelled,activeRead==nil,activeWrite==nil,!done else {return}
            done=true;allowed=nil;raw=nil;pendingRead=nil;pendingWrite=nil;readFailure=nil;writeFailure=nil
            let callbacks=closeWaiters;closeWaiters.removeAll();keepAlive=nil
            for callback in callbacks {callback()}
        }
    }
}
