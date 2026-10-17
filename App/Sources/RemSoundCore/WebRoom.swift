import Foundation

enum WebRoom {
    static let maximumPending=8,maximumSeats=4
    protocol Incoming:AnyObject {
        // Nonnil transfers the resource; nil leaves it here until an exact close receipt.
        func transport(permitted:@escaping ()->Bool)->WebConnection.Transport?
        func close(completion:@escaping ()->Void)
    }
    protocol Listener:AnyObject {
        // False leaves ownership with the listener, which must retire the refused resource.
        // Failure requests retirement; only close completion proves quiescence.
        func start(offer:@escaping (Incoming)->Bool,failed:@escaping ()->Void)
        func close(completion:@escaping ()->Void)
    }
    struct Configuration {
        let credential:WebAuthentication.Credential,page:Data,policy:WebAdmission.Policy,source:String
    }
    enum State:Equatable {case off,running,stopping,closed}
    struct Snapshot {let state:State,pending:Int,seats:Int,welcomed:Int}
    final class Service {
        private let owner:Owner
        init(queue:DispatchQueue,isolated:Bool=true,permitted:@escaping ()->Bool={false},
             listener:@escaping (@escaping ()->Bool)->Listener?,clock:@escaping ()->Double,
             schedule:@escaping WebConnection.Schedule,peerSchedule:@escaping WebConnection.Schedule,random:@escaping (Int)->Data?=WebAuthentication.random,
             verify:((Data,Data)->Bool)?=nil,retiring:@escaping ()->Void={},audioEncoder:@escaping ()->WebAudio.Encoder?={WebAudio.nativeEncoder()}) {
            owner=Owner(queue:queue,isolated:isolated,permitted:permitted,listener:listener,clock:clock,schedule:schedule,peerSchedule:peerSchedule,random:random,verify:verify,retiring:retiring,audioEncoder:audioEncoder)
        }
        @discardableResult func start(configuration:()->Configuration?)->Bool {owner.start(configuration)}
        @discardableResult func stop(_ completion:(()->Void)?=nil)->Bool {owner.request(false,completion)}
        @discardableResult func shutdown(_ completion:(()->Void)?=nil)->Bool {owner.request(true,completion)}
        var snapshot:Snapshot? {owner.snapshot}
        var peers:[WebPeer.Snapshot]? {owner.peers}
        var browsers:[(number:Int,snapshot:WebPeer.Snapshot)]? {owner.browsers}
        @discardableResult func audioActivity()->Bool {owner.audioActivity()}
        var audioGeneration:UUID? {owner.audioGeneration}
        @discardableResult func feed(_ samples:[Float],lane:WebAudio.Lane,generation:UUID)->Bool {owner.feed(samples,lane,generation)}
        @discardableResult func setAudioMuted(_ value:Bool)->Bool {owner.setAudioMuted(value)}
        @discardableResult func resetAudio()->UUID? {owner.resetAudio()}
        deinit {_ = owner.request(true,nil)}
    }
    private final class Once {
        private let lock=NSLock();private var taken=false
        func claim()->Bool {lock.lock();defer {lock.unlock()};guard !taken else {return false};taken=true;return true}
    }
    private final class Pulse {
        private let lock=NSLock();private var queued=false
        func claim()->Bool {lock.lock();defer {lock.unlock()};guard !queued else {return false};queued=true;return true}
        func take() {lock.lock();queued=false;lock.unlock()}
    }
    private final class Entry {
        let id=UUID(),generation:UUID,pulse=Pulse()
        /// Its place in the order browsers joined, for "Browser 1", "Browser 2" (Windows numbers them so).
        var number=0
        var incoming:Incoming?,control:WebConnection.Control?,ready:WebConnection.Ready?,peer:WebPeer.Control?
        var transferred=false,closing=false,seat=false,welcomed=false
        var stop:(()->Void)?,bytes=Data(),offset=0,writeID:UUID?,target=0.0
        init(_ incoming:Incoming,_ generation:UUID) {self.incoming=incoming;self.generation=generation}
    }
    private final class Owner {
        private static let maximumWaiters=16,maximumSourceBytes=128,maximumTextBytes=1024
        private static let writeSeconds=3.0,frameMilliseconds=5,sourceIdleSeconds=2.0
        private let queue:DispatchQueue,key=DispatchSpecificKey<UInt8>(),lock=NSLock(),isolated:Bool
        private let allowed:()->Bool,makeListener:(@escaping ()->Bool)->Listener?,clock:()->Double,schedule:WebConnection.Schedule,peerSchedule:WebConnection.Schedule
        private let retiring:()->Void
        private var retirementNotified=false
        private let random:(Int)->Data?,verify:((Data,Data)->Bool)?,failures=WebAuthentication.Failures()
        // Request admission is locked; all resources, protocol state and receipts belong to queue.
        private var generation:UUID?,stopping=false,permanent=false,reserved=0,nextNumber=0
        private var configuration:Configuration?,listener:Listener?,listenerClosing=false,listenerClosed=false,previous:Double?
        private let audioEncoder:()->WebAudio.Encoder?
        private var audio:WebAudio.Engine?,audioEpoch=UUID(),sourceMuted=false,feeding=false,lastFed:Double?
        private var entries=[UUID:Entry](),waiters=[()->Void](),keepAlive:Owner?
        init(queue:DispatchQueue,isolated:Bool,permitted:@escaping ()->Bool,listener:@escaping (@escaping ()->Bool)->Listener?,
             clock:@escaping ()->Double,schedule:@escaping WebConnection.Schedule,peerSchedule:@escaping WebConnection.Schedule,random:@escaping (Int)->Data?,verify:((Data,Data)->Bool)?,retiring:@escaping ()->Void,audioEncoder:@escaping ()->WebAudio.Encoder?) {
            self.queue=queue;self.isolated=isolated;allowed=permitted;makeListener=listener;self.clock=clock
            self.schedule=schedule;self.peerSchedule=peerSchedule;self.random=random;self.verify=verify;self.retiring=retiring;self.audioEncoder=audioEncoder;queue.setSpecific(key:key,value:1)
        }
        deinit {queue.setSpecific(key:key,value:nil)}
        private var onOwner:Bool {DispatchQueue.getSpecific(key:key)==1}
        private func current(_ id:UUID)->Bool {lock.lock();defer {lock.unlock()};return generation==id && !stopping && !permanent}
        private func gate(_ id:UUID)->Bool {onOwner && !isolated && current(id) && allowed() && current(id)}
        private func live(_ entry:Entry)->Bool {entries[entry.id] === entry && !entry.closing && gate(entry.generation)}
        private func sample(_ id:UUID)->Double? {
            guard gate(id) else {return nil};let now=clock()
            guard now.isFinite,now>=0,previous.map({now >= $0}) ?? true,gate(id) else {beginStop(id);return nil}
            previous=now;return now
        }
        var snapshot:Snapshot? {
            guard onOwner else {return nil}
            lock.lock();let state:State=generation==nil ? (permanent ? .closed:.off):(stopping ? .stopping:.running);lock.unlock()
            return Snapshot(state:state,pending:entries.values.filter({!$0.seat}).count,seats:entries.values.filter(\.seat).count,welcomed:entries.values.filter({$0.welcomed && $0.peer?.snapshot?.retiring != true}).count)
        }
        var peers:[WebPeer.Snapshot]? {onOwner ? entries.values.compactMap({$0.peer?.snapshot}):nil}
        /// Each browser past sign-in, by its number, for the Web listener window's list.
        var browsers:[(number:Int,snapshot:WebPeer.Snapshot)]? {
            onOwner ? entries.values.compactMap({ e in e.peer?.snapshot.map { (e.number,$0) } }).sorted(by: { $0.number < $1.number }):nil
        }
        var audioGeneration:UUID? {
            guard onOwner else {return nil};lock.lock();let id=generation;lock.unlock()
            guard let id,gate(id) else {return nil};return audioEpoch
        }
        private func audioDemand(_ id:UUID)->WebAudio.Demand {
            guard gate(id) else {return .none}
            let ready=entries.values.filter {live($0) && $0.welcomed && $0.peer?.snapshot?.retiring == false}
            return .init(opus:ready.contains {$0.ready?.codec == .opus},pcm:ready.contains {$0.ready?.codec == .pcm})
        }
        private func flushAudio() {
            _ = audio?.flush();for entry in Array(entries.values) {_ = entry.peer?.flushAudio()}
        }
        func resetAudio()->UUID? {
            guard onOwner,let id=audioGeneration,id==audioEpoch else {return nil}
            audioEpoch=UUID();lastFed=nil;flushAudio();return audioGeneration
        }
        func setAudioMuted(_ value:Bool)->Bool {
            guard onOwner,audioGeneration != nil else {return false}
            if sourceMuted != value {sourceMuted=value;_ = resetAudio()};return true
        }
        func audioActivity()->Bool {
            guard onOwner else {return false};lock.lock();let id=generation;lock.unlock()
            guard let id,let now=sample(id) else {return false};lastFed=now
            guard !sourceMuted else {return true}
            for entry in Array(entries.values) where live(entry) {_ = entry.peer?.audioActivity()};return gate(id)
        }
        // The producer must retain its acknowledged source ticket; late blocks cannot adopt a new source generation.
        func feed(_ samples:[Float],_ lane:WebAudio.Lane,_ source:UUID)->Bool {
            guard onOwner,!feeding,source==audioEpoch else {return false}
            guard !samples.isEmpty,samples.count<=WebAudio.maximumInputSamples,samples.count.isMultiple(of:WebAudioPackets.channels),samples.allSatisfy(\.isFinite) else {return false}
            feeding=true;defer {feeding=false}
            lock.lock();let id=generation;lock.unlock();guard let id else {return false}
            guard gate(id),let now=sample(id),source==audioEpoch else {beginStop(id);return false}
            if lastFed.map({now-$0>=Self.sourceIdleSeconds}) ?? false {flushAudio()}
            lastFed=now
            guard !sourceMuted else {flushAudio();return false}
            for entry in Array(entries.values) where live(entry) {_ = entry.peer?.audioActivity()}
            guard gate(id),source==audioEpoch else {return false}
            guard audioDemand(id) != .none else {_ = audio?.flush();return true}
            if audio==nil {
                audio=WebAudio.Engine(queue:queue,isolated:isolated,permitted:{[weak self] in self?.gate(id) ?? false},muted:{[weak self] in self?.sourceMuted ?? true},demand:{[weak self] in self?.audioDemand(id) ?? .none},factory:audioEncoder,output:{[weak self] value in
                    guard let self,self.gate(id) else {return}
                    for entry in Array(self.entries.values) where self.live(entry) && entry.welcomed {_ = entry.peer?.audio(value)}
                })
            }
            guard let audio else {return false};let result=audio.feed(samples,lane:lane)
            if !gate(id) || (!result && source==audioEpoch && !sourceMuted) {beginStop(id)}
            return result && gate(id) && source==audioEpoch
        }
        func start(_ make:()->Configuration?)->Bool {
            guard onOwner,!isolated,allowed() else {return false}
            lock.lock();guard generation==nil,!permanent else {lock.unlock();return false}
            let id=UUID();generation=id;stopping=false;lock.unlock();keepAlive=self
            listenerClosed=false;listenerClosing=false;retirementNotified=false;audioEpoch=UUID();lastFed=nil
            guard sample(id) != nil,let value=make(),gate(id),valid(value) else {beginStop(id);return false}
            configuration=value
            guard visit(id) != nil,sample(id) != nil else {beginStop(id);return false}
            listener=makeListener({[weak self] in self?.gate(id) ?? false})
            guard gate(id),sample(id) != nil,let listener else {beginStop(id);return false}
            listener.start(offer:{[weak self] in self?.offer($0,id) ?? false},failed:{[weak self] in self?.beginStop(id)})
            guard gate(id) else {beginStop(id);return false}
            return true
        }
        private func valid(_ value:Configuration)->Bool {
            !value.source.isEmpty && value.source.utf8.count<=Self.maximumSourceBytes && !value.source.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) && !value.page.isEmpty && value.page.count<=WebAdmission.maximumPageBytes
        }
        private func visit(_ id:UUID)->WebAdmission.Visit? {
            guard gate(id),let configuration else {return nil}
            return WebAdmission.Visit.make(credential:configuration.credential,failures:failures,page:configuration.page,policy:configuration.policy,
                permitted:{[weak self] in self?.gate(id) ?? false},current:{[weak self] in self?.configuration?.credential},
                clock:{[weak self] in self?.sample(id) ?? .nan},random:random,verify:verify)
        }
        private func offer(_ incoming:Incoming,_ id:UUID)->Bool {
            guard gate(id),entries.values.filter({!$0.seat}).count<maximumPending,sample(id) != nil else {return false}
            let entry=Entry(incoming,id);nextNumber += 1;entry.number=nextNumber;entries[entry.id]=entry
            queue.async {[self] in begin(entry)}
            return true
        }
        private func begin(_ entry:Entry) {
            guard live(entry) else {close(entry);return}
            entry.control=WebConnection.start(queue:queue,permitted:{[weak self,weak entry] in guard let self,let entry else {return false};return self.live(entry)},admission:{[weak self,weak entry] in
                guard let self,let entry,self.live(entry) else {return nil};return self.visit(entry.generation)
            },transport:{[weak self,weak entry] lower in
                guard let self,let entry,self.live(entry),lower() else {return nil}
                // The lower construction gate expires at handoff; native lifetime permission must remain independent.
                let transport=entry.incoming?.transport(permitted:{[weak self,weak entry] in guard let self,let entry else {return false};return self.live(entry)})
                entry.transferred=transport != nil
                if transport != nil {entry.incoming=nil}
                return transport
            },schedule:schedule,completion:{[weak self,weak entry] result in guard let self,let entry else {return};self.admitted(entry,result)})
        }
        private func admitted(_ entry:Entry,_ result:WebConnection.Result) {
            guard entries[entry.id] === entry else {return};entry.control=nil
            switch result {
            case .ready(let ready):
                entry.ready=ready
                guard live(entry),let configuration else {close(entry);return}
                entry.seat=entries.values.filter(\.seat).count<maximumSeats
                let object:[String:Any]=entry.seat ? ["type":"welcome","frameMs":Self.frameMilliseconds,"source":configuration.source,"autoStart":configuration.policy.autoStart]:["type":"refused","reason":"\(maximumSeats) browsers are already listening.","retry":true]
                guard let body=try? JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]),body.count<=Self.maximumTextBytes,
                      let bytes=WebSocketPackets.serverFrame(kind:.text,payload:body),let now=sample(entry.generation),now+Self.writeSeconds>now,(now+Self.writeSeconds).isFinite else {close(entry);return}
                entry.bytes=bytes;entry.target=now+Self.writeSeconds
                entry.stop=schedule(queue,{[weak self,weak entry] in
                    guard let self,let entry,entry.pulse.claim() else {return}
                    queue.async {[weak self,weak entry] in guard let self,let entry else {return};entry.pulse.take();self.tick(entry)}
                })
                guard entry.stop != nil,live(entry) else {close(entry);return};write(entry)
            case .closed,.failed:
                if entry.transferred {retire(entry)} else {close(entry)}
            }
        }
        private func tick(_ entry:Entry) {
            guard entries[entry.id] === entry,!entry.closing,!entry.welcomed else {return}
            guard live(entry),let now=sample(entry.generation),now<entry.target else {close(entry);return}
        }
        private func write(_ entry:Entry) {
            guard live(entry),let now=sample(entry.generation),now<entry.target,entry.writeID==nil,let ready=entry.ready else {close(entry);return}
            let bytes=Data(entry.bytes.dropFirst(entry.offset)),id=UUID();entry.writeID=id
            guard ready.write(bytes,completion:{[weak self,weak entry] count in
                guard let self,let entry,self.entries[entry.id] === entry,entry.writeID==id else {return};entry.writeID=nil
                guard self.live(entry),let now=self.sample(entry.generation),now<entry.target,let count,count>0,count<=bytes.count else {self.close(entry);return}
                entry.offset += count
                if entry.offset<entry.bytes.count {self.write(entry);return}
                self.stopDriver(entry);entry.bytes.removeAll(keepingCapacity:false)
                if entry.seat {
                    entry.peer=WebPeer.start(queue:self.queue,ready:ready,permitted:{[weak self,weak entry] in guard let self,let entry else {return false};return self.live(entry)},clock:{[weak self,weak entry] in guard let self,let entry else {return .nan};return self.sample(entry.generation) ?? .nan},schedule:self.peerSchedule,sourceActivity:.observed(self.sourceMuted ? nil:self.lastFed),started:{[weak self,weak entry] in guard let self,let entry,self.live(entry) else {return};entry.welcomed=true},closed:{[weak self,weak entry] _ in guard let self,let entry else {return};self.retire(entry)})
                } else {self.close(entry)}
            }) else {entry.writeID=nil;close(entry);return}
        }
        private func stopDriver(_ entry:Entry) {let stop=entry.stop;entry.stop=nil;stop?()}
        private func close(_ entry:Entry) {
            guard entries[entry.id] === entry else {return};stopDriver(entry)
            guard !entry.closing else {return};entry.closing=true;entry.welcomed=false
            if let peer=entry.peer {_ = peer.cancel()}
            else if let ready=entry.ready {
                _ = ready.close {[weak self,weak entry] in guard let self,let entry else {return};self.retire(entry)}
            } else if let control=entry.control {_ = control.cancel()}
            else if let incoming=entry.incoming {
                let once=Once();incoming.close {[weak self,weak entry] in guard once.claim(),let self,let entry else {return};queue.async {[weak self,weak entry] in guard let self,let entry else {return};self.retire(entry)}}
            } else {retire(entry)}
        }
        private func retire(_ entry:Entry) {
            guard entries[entry.id] === entry else {return};stopDriver(entry);entries[entry.id]=nil
            entry.peer=nil;entry.ready=nil;entry.control=nil;entry.incoming=nil;entry.bytes.removeAll(keepingCapacity:false)
            finishIfRetired(entry.generation)
        }
        func request(_ shutdown:Bool,_ completion:(()->Void)?)->Bool {
            lock.lock()
            if completion != nil {guard reserved<Self.maximumWaiters else {lock.unlock();return false};reserved += 1}
            if shutdown {permanent=true}
            let id=generation;if id != nil {stopping=true};lock.unlock()
            queue.async {[self] in
                lock.lock();let matches=id != nil && generation==id;lock.unlock()
                guard matches,let id else {deliver(completion);return}
                if let completion {waiters.append(completion)}
                beginStop(id)
            }
            return true
        }
        private func deliver(_ callback:(()->Void)?) {
            if let callback {lock.lock();reserved -= 1;lock.unlock();callback()}
        }
        private func beginStop(_ id:UUID) {
            lock.lock();guard generation==id else {lock.unlock();return};stopping=true;lock.unlock()
            // This is an admission/failure notice, never a transport retirement receipt.
            if !retirementNotified {retirementNotified=true;retiring()}
            audio?.stop();audio=nil;lastFed=nil
            for entry in Array(entries.values) {close(entry)}
            if !listenerClosing {
                listenerClosing=true
                if let listener {
                    let once=Once();listener.close {[weak self] in guard once.claim(),let self else {return};queue.async {[weak self] in guard let self else {return};self.listenerClosed=true;self.finishIfRetired(id)}}
                } else {listenerClosed=true}
            }
            finishIfRetired(id)
        }
        private func finishIfRetired(_ id:UUID) {
            lock.lock();let match=generation==id && stopping;lock.unlock()
            guard match,listenerClosed,entries.isEmpty else {return}
            configuration=nil;listener=nil
            lock.lock();generation=nil;stopping=false;lock.unlock()
            let callbacks=waiters;waiters.removeAll();keepAlive=nil
            for callback in callbacks {deliver(callback)}
        }
    }
}
