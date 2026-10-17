import Foundation
import Network
import RemSoundRuntime

enum WebNativeListener {
    static let maximumChildren=WebRoom.maximumPending+WebRoom.maximumSeats
    enum State {case ready(UInt16),failed,cancelled}
    protocol Child:WebNativeTransport.Raw {var isLoopback:Bool {get}}
    protocol Raw:AnyObject {
        func start(queue:DispatchQueue,state:@escaping (State)->Void,accepted:@escaping (Child)->Bool)
        func grantOne()
        func cancel()
    }
    protocol Timer:AnyObject {
        func start(queue:DispatchQueue,pulse:@escaping ()->Void)
        func cancel()
    }
    static let defaultPort:UInt16=47840
    static func make(queue:DispatchQueue,isolated:Bool=true,permitted:@escaping ()->Bool={false},bound:@escaping (UInt16)->Void={_ in},factory:(()->Bool)->Raw?)->WebRoom.Listener? {
        guard !isolated,permitted(),let raw=factory({!isolated && permitted()}) else {return nil}
        return Handle(Owner(queue,raw,{!isolated && permitted()},bound))
    }
    static func activeSchedule(permitted:@escaping ()->Bool={false},clock:@escaping ()->Double,factory:@escaping ()->Timer?)->WebConnection.Schedule {
        {queue,pulse in
            guard permitted() else {return nil};let began=clock()
            guard began.isFinite,began>=0,began+1>began,permitted(),let timer=factory() else {return nil}
            let driver=Active(queue,timer,permitted,clock,pulse,began)
            guard driver.start() else {return nil}
            return {driver.cancel()}
        }
    }
    static func nativeSchedule(permitted:@escaping ()->Bool,clock:@escaping ()->Double={ProcessInfo.processInfo.systemUptime})->WebConnection.Schedule {
        activeSchedule(permitted:permitted,clock:clock,factory:{NativeTimer()})
    }
    static func ownedLoopback(queue:DispatchQueue,port:UInt16=0,permitted:@escaping ()->Bool,bound:@escaping (UInt16)->Void={_ in})->WebRoom.Listener? {
        make(queue:queue,isolated:false,permitted:permitted,bound:bound,factory:{gate in
            guard gate() else {return nil};return try? Native(port)
        })
    }
    static func native(queue:DispatchQueue,runtime:RuntimeConfiguration,port:UInt16=defaultPort,permitted:@escaping ()->Bool,bound:@escaping (UInt16)->Void={_ in})->WebRoom.Listener? {
        guard !runtime.isIsolated,port>0,permitted() else {return nil}
        return ownedLoopback(queue:queue,port:port,permitted:{!runtime.isIsolated && permitted()},bound:bound)
    }
    static func service(queue:DispatchQueue,runtime:RuntimeConfiguration,permitted:@escaping ()->Bool={false},bound:@escaping (UInt16)->Void={_ in},retiring:@escaping ()->Void={})->WebRoom.Service {
        let allowed={!runtime.isIsolated && permitted()}
        return WebRoom.Service(queue:queue,isolated:runtime.isIsolated,permitted:permitted,listener:{gate in native(queue:queue,runtime:runtime,permitted:gate,bound:bound)},clock:{ProcessInfo.processInfo.systemUptime},schedule:WebNativeTransport.schedule(permitted:allowed),peerSchedule:nativeSchedule(permitted:allowed),retiring:retiring)
    }
    private final class Once {
        private let lock=NSLock();private var taken=false
        func claim()->Bool {lock.lock();defer {lock.unlock()};guard !taken else {return false};taken=true;return true}
    }
    private final class Handle:WebRoom.Listener {
        private let owner:Owner
        init(_ owner:Owner) {self.owner=owner}
        func start(offer:@escaping (WebRoom.Incoming)->Bool,failed:@escaping ()->Void) {owner.queue.async {[owner] in owner.start(offer,failed)}}
        func close(completion:@escaping ()->Void) {owner.request(completion)}
        deinit {owner.request(nil)}
    }
    private final class Owner {
        let queue:DispatchQueue
        private let raw:Raw,allowed:()->Bool,bound:(UInt16)->Void,key=DispatchSpecificKey<UInt8>(),lock=NSLock()
        private var closing=false,credit=false,reserved=0
        private var started=false,ready=false,cancelled=false,done=false,keepAlive:Owner?,offer:((WebRoom.Incoming)->Bool)?,readyPort:UInt16?
        private var children=[UUID:Incoming](),waiters=[()->Void](),failure:(()->Void)?
        init(_ queue:DispatchQueue,_ raw:Raw,_ allowed:@escaping ()->Bool,_ bound:@escaping (UInt16)->Void) {
            self.queue=queue;self.raw=raw;self.allowed=allowed;self.bound=bound;queue.setSpecific(key:key,value:1)
        }
        deinit {queue.setSpecific(key:key,value:nil)}
        private var isClosing:Bool {lock.lock();defer {lock.unlock()};return closing}
        private var onOwner:Bool {DispatchQueue.getSpecific(key:key)==1}
        func start(_ offer:@escaping (WebRoom.Incoming)->Bool,_ failed:@escaping ()->Void) {
            guard !started else {return};self.offer=offer;failure=failed;startRaw()
            if isClosing {request(nil)} else if !allowed() {fail()}
        }
        private func startRaw() {
            guard !started else {return};started=true;keepAlive=self
            raw.start(queue:queue,state:{[weak self] state in guard let self else {return};queue.async {[weak self] in self?.changed(state)}},accepted:{[weak self] child in self?.admit(child) ?? false})
        }
        private func changed(_ state:State) {
            guard !done else {return}
            switch state {
            case .ready(let port):
                guard !isClosing else {return}
                guard allowed(),port>0 else {fail();return}
                if let readyPort {if readyPort != port {fail()};return}
                readyPort=port
                ready=true;bound(port);grant()
            case .failed:fail()
            case .cancelled:cancelled=true;request(nil);finishIfRetired()
            }
        }
        private func grant() {
            guard ready,!done,!isClosing else {return}
            guard allowed() else {fail();return}
            lock.lock();guard !closing,!credit,reserved<maximumChildren else {lock.unlock();return};credit=true;lock.unlock()
            // Exactly one consumed native credit, never a read-modify-write of the kernel's remaining count.
            raw.grantOne()
            if !allowed() {fail()}
        }
        private func admit(_ child:Child)->Bool {
            lock.lock();guard credit,reserved<maximumChildren,!done else {lock.unlock();return false}
            credit=false;reserved += 1;lock.unlock()
            queue.async {[self] in
                let incoming=Incoming(queue,child,{[weak self] in self?.onOwner ?? false},{[weak self] in guard let self else {return false};return !isClosing && allowed()})
                children[incoming.id]=incoming
                incoming.retired={[weak self,weak incoming] in guard let self,let incoming else {return};retired(incoming)}
                if isClosing || !allowed() || !child.isLoopback || offer?(incoming) != true {incoming.close(completion:{})}
                if !isClosing,!allowed() {fail()} else {grant()}
            }
            return true
        }
        private func retired(_ incoming:Incoming) {
            guard children[incoming.id] === incoming else {return};children[incoming.id]=nil
            lock.lock();reserved -= 1;lock.unlock();grant();finishIfRetired()
        }
        private func fail() {
            guard !done,!isClosing else {request(nil);return}
            let notify=failure;failure=nil;notify?();request(nil)
        }
        func request(_ completion:(()->Void)?) {
            lock.lock();closing=true;lock.unlock()
            queue.async {[self] in
                if done {completion?();return}
                if let completion {waiters.append(completion)}
                keepAlive=self
                let wasStarted=started;startRaw()
                for incoming in Array(children.values) {incoming.close(completion:{})}
                if !wasStarted || !cancelRequested {cancelRequested=true;raw.cancel()}
                finishIfRetired()
            }
        }
        private var cancelRequested=false
        private func finishIfRetired() {
            lock.lock();let retired=reserved==0;lock.unlock()
            guard isClosing,cancelled,retired,!done else {return};done=true;offer=nil;failure=nil
            let callbacks=waiters;waiters.removeAll();keepAlive=nil
            for callback in callbacks {callback()}
        }
    }
    private final class Incoming:WebRoom.Incoming {
        let id=UUID()
        var retired:(()->Void)?
        private let queue:DispatchQueue,onOwner:()->Bool,allowed:()->Bool
        private var raw:Child?,bridge:Bridge?,closing=false,done=false,waiters=[()->Void](),cancelling=false
        init(_ queue:DispatchQueue,_ raw:Child,_ onOwner:@escaping ()->Bool,_ allowed:@escaping ()->Bool) {self.queue=queue;self.raw=raw;self.onOwner=onOwner;self.allowed=allowed}
        func transport(permitted:@escaping ()->Bool)->WebConnection.Transport? {
            guard onOwner(),!closing,!done,bridge==nil,allowed(),permitted(),let raw,raw.isLoopback else {return nil}
            guard let transport=WebNativeTransport.make(queue:queue,permitted:{[weak self] in guard let self else {return false};return !closing && !done && allowed() && permitted()},factory:{_ in raw}) else {return nil}
            let bridge=Bridge(queue,transport,{[weak self] in self?.finished()});self.bridge=bridge;self.raw=nil
            return bridge
        }
        func close(completion:@escaping ()->Void) {
            queue.async {[self] in
                if done {completion();return};waiters.append(completion)
                guard !closing else {return};closing=true
                if let bridge {bridge.close(completion:{})}
                else if let raw {
                    guard !cancelling else {return};cancelling=true;let once=Once()
                    // Already accepted unstarted resources are started only to own exact cancellation, with no IO.
                    raw.start(queue:queue) {[weak self] state in
                        guard case .cancelled=state,once.claim(),let self else {return};queue.async {[weak self] in self?.finished()}
                    }
                    raw.cancel()
                } else {finished()}
            }
        }
        private func finished() {
            guard !done else {return};done=true;raw=nil;bridge=nil
            let callbacks=waiters,notify=retired;waiters.removeAll();retired=nil;notify?()
            for callback in callbacks {callback()}
        }
    }
    private final class Bridge:WebConnection.Transport {
        private let queue:DispatchQueue
        private var transport:WebConnection.Transport?,retired:(()->Void)?,closing=false,done=false,waiters=[()->Void]()
        init(_ queue:DispatchQueue,_ transport:WebConnection.Transport,_ retired:@escaping ()->Void) {self.queue=queue;self.transport=transport;self.retired=retired}
        func read(maximum:Int,completion:@escaping (WebConnection.Read)->Void) {guard !closing,let transport else {queue.async {completion(.failed)};return};transport.read(maximum:maximum,completion:completion)}
        func write(_ bytes:Data,completion:@escaping (Int?)->Void) {guard !closing,let transport else {queue.async {completion(nil)};return};transport.write(bytes,completion:completion)}
        func close(completion:@escaping ()->Void) {
            if done {queue.async(execute:completion);return};waiters.append(completion)
            guard !closing else {return};closing=true
            transport?.close {[self] in
                guard !done else {return};done=true;transport=nil
                let callbacks=waiters,notify=retired;waiters.removeAll();retired=nil;notify?()
                for callback in callbacks {callback()}
            }
        }
    }
    private final class NativeChild:Child {
        private let connection:NWConnection
        init(_ connection:NWConnection) {self.connection=connection}
        var isLoopback:Bool {
            guard case let .hostPort(host,_)=connection.endpoint else {return false}
            switch host {case .ipv4(let address):return address.rawValue.first==127;case .ipv6(let address):return address == .loopback;default:return false}
        }
        func start(queue:DispatchQueue,state:@escaping (WebNativeTransport.State)->Void) {
            connection.stateUpdateHandler={value in switch value {case .ready:state(.ready);case .failed:state(.failed);case .cancelled:state(.cancelled);default:break}}
            connection.start(queue:queue)
        }
        func receive(maximum:Int,completion:@escaping (Data?,Bool,Bool)->Void) {connection.receive(minimumIncompleteLength:1,maximumLength:maximum) {data,_,end,error in completion(data,end,error != nil)}}
        func send(_ bytes:Data,completion:@escaping (Bool)->Void) {connection.send(content:bytes,completion:.contentProcessed {completion($0 == nil)})}
        func cancel() {connection.cancel()}
        deinit {connection.stateUpdateHandler=nil}
    }
    private final class Native:Raw {
        private let listener:NWListener
        private let requestedPort:UInt16
        private var refused=[UUID:NativeChild](),cancelled=false,state:((State)->Void)?
        init(_ port:UInt16) throws {
            requestedPort=port
            let parameters=NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:NWEndpoint.Port(rawValue:port) ?? .any)
            parameters.allowLocalEndpointReuse=false;parameters.acceptLocalOnly=true;parameters.includePeerToPeer=false
            listener=try NWListener(using:parameters);listener.newConnectionLimit=0
        }
        func start(queue:DispatchQueue,state:@escaping (State)->Void,accepted:@escaping (Child)->Bool) {
            self.state=state
            listener.stateUpdateHandler={[weak self] value in
                guard let self else {return}
                switch value {
                case .ready:
                    let port=listener.port?.rawValue ?? 0
                    if port==0 || (requestedPort>0 && requestedPort != port) {state(.failed)} else {state(.ready(port))}
                case .failed:state(.failed)
                case .cancelled:cancelled=true;finished()
                default:break
                }
            }
            listener.newConnectionHandler={[weak self] connection in
                guard let self else {return};let child=NativeChild(connection)
                guard !accepted(child) else {return}
                let id=UUID();refused[id]=child;cancel()
                child.start(queue:queue) {[weak self] value in guard case .cancelled=value,let self else {return};queue.async {[weak self] in guard let self else {return};refused[id]=nil;finished()}}
                child.cancel()
            }
            listener.start(queue:queue)
        }
        func grantOne() {listener.newConnectionLimit=1}
        func cancel() {listener.newConnectionLimit=0;listener.cancel()}
        private func finished() {guard cancelled,refused.isEmpty else {return};let reply=state;state=nil;reply?(.cancelled)}
        deinit {listener.stateUpdateHandler=nil;listener.newConnectionHandler=nil}
    }
    private final class NativeTimer:Timer {
        private var source:DispatchSourceTimer?
        func start(queue:DispatchQueue,pulse:@escaping ()->Void) {
            let timer=DispatchSource.makeTimerSource(queue:queue);source=timer
            timer.schedule(deadline:.now()+0.02,repeating:0.02,leeway:.milliseconds(2));timer.setEventHandler(handler:pulse);timer.resume()
        }
        func cancel() {let timer=source;source=nil;timer?.setEventHandler {};timer?.cancel()}
    }
    private final class Active {
        private let queue:DispatchQueue,timer:Timer,allowed:()->Bool,clock:()->Double,pulse:()->Void,lock=NSLock(),key=DispatchSpecificKey<UInt8>()
        private var previous:Double,done=false,queued=false
        init(_ queue:DispatchQueue,_ timer:Timer,_ allowed:@escaping ()->Bool,_ clock:@escaping ()->Double,_ pulse:@escaping ()->Void,_ previous:Double) {self.queue=queue;self.timer=timer;self.allowed=allowed;self.clock=clock;self.pulse=pulse;self.previous=previous;queue.setSpecific(key:key,value:1)}
        deinit {queue.setSpecific(key:key,value:nil)}
        func start()->Bool {
            guard boundary() else {cancel();return false}
            timer.start(queue:queue,pulse:{[weak self] in self?.enqueue()})
            guard boundary() else {cancel();return false};return true
        }
        private func boundary()->Bool {
            lock.lock();let stopped=done;lock.unlock();guard !stopped,allowed() else {return false}
            let now=clock();lock.lock();let after=done;lock.unlock()
            guard !after,now.isFinite,now>=previous,allowed() else {return false};previous=now;return true
        }
        private func enqueue() {
            lock.lock();guard !done,!queued else {lock.unlock();return};queued=true;lock.unlock()
            queue.async {[weak self] in
                guard let self else {return};lock.lock();queued=false;let stopped=done;lock.unlock();guard !stopped else {return}
                let valid=boundary();lock.lock();let cancelled=done;lock.unlock();guard !cancelled else {return}
                pulse();if !valid {cancel()}
            }
        }
        func cancel() {
            lock.lock();guard !done else {lock.unlock();return};done=true;lock.unlock()
            if DispatchQueue.getSpecific(key:key)==1 {timer.cancel()} else {queue.async {[timer] in timer.cancel()}}
        }
    }
}
