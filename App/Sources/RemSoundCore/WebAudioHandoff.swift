import Foundation
enum WebAudioHandoff {
    static let maximumBlocks=32,maximumQueuedSamples=WebAudioPackets.frameSamples*WebAudioPackets.channels*maximumBlocks,maximumWaiters=16
    struct Binding:Equatable,Sendable {let request:UUID,network:SessionNetworkBinding}
    struct Block {let lane:WebAudio.Lane,samples:[Float]}
    struct Snapshot {let binding:Binding?,queuedBlocks:Int,queuedSamples:Int,droppedBlocks:Int,inflight:Bool,closing:Bool,shutdown:Bool}
    protocol Sink:AnyObject {
        func consume(_ block:Block,discontinuity:Bool,completion:@escaping (Bool)->Void)
        func close(completion:@escaping ()->Void)
    }
    typealias Enqueue=(@escaping ()->Void)->Void
    final class Producer {
        let binding:Binding
        private let owner:Owner,id:UUID
        fileprivate init(_ owner:Owner,_ visit:Visit) {self.owner=owner;id=visit.id;binding=visit.binding}
        // Worker-only admission, not delivery/ACK. Copies bounded samples; never call from a realtime callback.
        func offer(_ samples:[Float],lane:WebAudio.Lane)->Bool {owner.offer(samples,lane,id)}
        func retire()->Bool {owner.request(false,id,nil)}
        // Structural admission only; does not invoke the owner-only lifetime permission or prove delivery.
        var isActive:Bool {owner.isActive(id)}
        deinit {_ = owner.request(false,id,nil)}
    }
    final class Service {
        private let owner:Owner
        init(queue:DispatchQueue,isolated:Bool=true,permitted:@escaping ()->Bool={false},enqueue:Enqueue?=nil,factory:@escaping (Binding,@escaping ()->Bool)->Sink?) {
            owner=Owner(queue,isolated,permitted,enqueue ?? {queue.async(execute:$0)},factory)
        }
        func open(_ binding:Binding,completion:@escaping (Producer?)->Void)->Bool {owner.open(binding,completion)}
        func stop(_ completion:(()->Void)?=nil)->Bool {owner.request(false,nil,completion)}
        func shutdown(_ completion:(()->Void)?=nil)->Bool {owner.request(true,nil,completion)}
        var snapshot:Snapshot? {owner.snapshot}
        deinit {_ = owner.request(true,nil,nil)}
    }
    private final class Once {
        private let lock=NSLock();private var taken=false
        func claim()->Bool {lock.lock();defer {lock.unlock()};guard !taken else {return false};taken=true;return true}
    }
    fileprivate final class Visit {
        let id=UUID(),binding:Binding
        // These admission/queue fields use the service lock even on its owner executor.
        var ready=false,closing=false,wake=false,closeQueued=false,blocks=[Block](),samples=0,gap=false,dropped=0,waiters=[()->Void]()
        // Sink ownership and receipt state use only the executor.
        var sink:Sink?,began=false,returned=false,closeSent=false,closeReceipt=false,inflight:UUID?,reply:((Producer?)->Void)?
        init(_ binding:Binding,_ reply:@escaping (Producer?)->Void) {self.binding=binding;self.reply=reply}
    }
    fileprivate final class Owner {
        private let queue:DispatchQueue,key=DispatchSpecificKey<UInt8>(),lock=NSLock(),isolated:Bool,allowed:()->Bool,enqueue:Enqueue,factory:(Binding,@escaping ()->Bool)->Sink?
        private var current:Visit?,permanent=false,reserved=0,keepAlive:Owner?
        init(_ queue:DispatchQueue,_ isolated:Bool,_ allowed:@escaping ()->Bool,_ enqueue:@escaping Enqueue,_ factory:@escaping (Binding,@escaping ()->Bool)->Sink?) {
            self.queue=queue;self.isolated=isolated;self.allowed=allowed;self.enqueue=enqueue;self.factory=factory;queue.setSpecific(key:key,value:1)
        }
        deinit {queue.setSpecific(key:key,value:nil)}
        private var onOwner:Bool {DispatchQueue.getSpecific(key:key)==1}
        private func submit(_ work:@escaping ()->Void) {enqueue {[self] in if onOwner {work()} else {queue.async(execute:work)}}}
        func isActive(_ id:UUID)->Bool {lock.lock();defer {lock.unlock()};return current.map {$0.id==id && $0.ready && !$0.closing && !permanent} ?? false}
        private func live(_ visit:Visit)->Bool {lock.lock();defer {lock.unlock()};return current === visit && !visit.closing && !permanent}
        private func permitted(_ visit:Visit)->Bool {onOwner && !isolated && live(visit) && allowed() && live(visit)}
        var snapshot:Snapshot? {
            guard onOwner else {return nil};lock.lock();defer {lock.unlock()}
            return Snapshot(binding:current?.binding,queuedBlocks:current?.blocks.count ?? 0,queuedSamples:current?.samples ?? 0,droppedBlocks:current?.dropped ?? 0,inflight:current?.inflight != nil,closing:current?.closing ?? false,shutdown:permanent)
        }
        func open(_ binding:Binding,_ reply:@escaping (Producer?)->Void)->Bool {
            guard onOwner,!isolated,binding.network.port>0,allowed() else {return false}
            lock.lock();guard current==nil,!permanent else {lock.unlock();return false}
            let visit=Visit(binding,reply);current=visit;keepAlive=self;lock.unlock()
            submit {[self] in begin(visit)};return true
        }
        private func begin(_ visit:Visit) {
            guard permitted(visit) else {retireAfterFactory(visit);return}
            visit.began=true
            visit.sink=factory(visit.binding,{[weak self,weak visit] in guard let self,let visit else {return false};return self.permitted(visit)})
            visit.returned=true
            guard permitted(visit),visit.sink != nil else {retireAfterFactory(visit);return}
            lock.lock();guard current === visit,!visit.closing,!permanent else {lock.unlock();retireAfterFactory(visit);return};visit.ready=true;lock.unlock()
            let reply=visit.reply;visit.reply=nil;reply?(Producer(self,visit))
        }
        private func retireAfterFactory(_ visit:Visit) {
            _ = request(false,visit.id,nil)
            // A synchronous injected executor may have tried close while the factory was still on its stack.
            close(visit)
        }
        func offer(_ samples:[Float],_ lane:WebAudio.Lane,_ id:UUID)->Bool {
            guard !samples.isEmpty,samples.count<=WebAudio.maximumInputSamples,samples.count.isMultiple(of:WebAudioPackets.channels),samples.allSatisfy(\.isFinite) else {return false}
            lock.lock();guard let visit=current,visit.id==id,visit.ready,!visit.closing,!permanent else {lock.unlock();return false}
            while visit.blocks.count>=maximumBlocks || visit.samples>maximumQueuedSamples-samples.count {
                let dropped=visit.blocks.removeFirst();visit.samples -= dropped.samples.count;visit.gap=true;if visit.dropped<Int.max {visit.dropped += 1}
            }
            // Array(array) may share an oversized reserved backing allocation. Always own a count-bounded copy.
            let copy=samples.withUnsafeBufferPointer { source in Array<Float>(unsafeUninitializedCapacity:source.count) { destination,count in
                destination.baseAddress!.initialize(from:source.baseAddress!,count:source.count);count=source.count
            } }
            visit.blocks.append(Block(lane:lane,samples:copy));visit.samples += copy.count
            let wake = !visit.wake;visit.wake=true;lock.unlock()
            if wake {submit {[self] in drain(visit)}};return true
        }
        private func drain(_ visit:Visit) {
            guard permitted(visit),let sink=visit.sink else {_ = request(false,visit.id,nil);return}
            lock.lock();guard current === visit,!visit.closing,visit.ready else {lock.unlock();return}
            guard visit.inflight==nil else {lock.unlock();return}
            guard !visit.blocks.isEmpty else {visit.wake=false;lock.unlock();return}
            let block=visit.blocks.removeFirst(),gap=visit.gap,id=UUID();visit.samples -= block.samples.count;visit.gap=false;visit.inflight=id;lock.unlock()
            let once=Once()
            sink.consume(block,discontinuity:gap) {[weak self,weak visit] accepted in
                guard once.claim(),let self,let visit else {return}
                // Always marshal receipts after the raw method returns, including injected synchronous executors.
                queue.async {[weak self,weak visit] in guard let self,let visit else {return};consumed(visit,id,accepted)}
            }
        }
        private func consumed(_ visit:Visit,_ id:UUID,_ accepted:Bool) {
            guard visit.inflight==id else {return};visit.inflight=nil
            lock.lock();guard current === visit else {lock.unlock();return};visit.wake=false;let closing=visit.closing;lock.unlock()
            if closing {finish(visit);return}
            guard accepted,permitted(visit) else {_ = request(false,visit.id,nil);return}
            lock.lock();let wake = !visit.blocks.isEmpty && !visit.wake && !visit.closing; if wake {visit.wake=true};lock.unlock()
            if wake {submit {[self] in drain(visit)}}
        }
        func request(_ shutdown:Bool,_ expected:UUID?,_ completion:(()->Void)?)->Bool {
            lock.lock()
            if let expected {guard current?.id==expected,current?.closing==false else {lock.unlock();return false}}
            if completion != nil {guard reserved<maximumWaiters else {lock.unlock();return false};reserved += 1}
            if shutdown {permanent=true}
            guard let visit=current else {lock.unlock();if let completion {submit {[self] in deliver(completion)}};return true}
            visit.closing=true;visit.ready=false;visit.blocks.removeAll();visit.samples=0
            if let completion {visit.waiters.append(completion)}
            let wake = !visit.closeQueued;visit.closeQueued=true;lock.unlock()
            if wake {submit {[self] in close(visit)}};return true
        }
        private func close(_ visit:Visit) {
            lock.lock();let matches=current === visit;lock.unlock();guard matches else {return}
            if !visit.began {visit.returned=true}
            guard visit.returned else {return}
            guard !visit.closeSent else {finish(visit);return};visit.closeSent=true
            guard let sink=visit.sink else {visit.closeReceipt=true;finish(visit);return}
            let once=Once()
            sink.close {[weak self,weak visit] in
                guard once.claim(),let self,let visit else {return}
                queue.async {[weak self,weak visit] in guard let self,let visit else {return};visit.closeReceipt=true;finish(visit)}
            }
        }
        private func finish(_ visit:Visit) {
            guard visit.returned,visit.closeReceipt,visit.inflight==nil else {return}
            lock.lock();guard current === visit,visit.closing else {lock.unlock();return}
            let callbacks=visit.waiters;visit.waiters.removeAll();current=nil;keepAlive=nil;lock.unlock()
            visit.sink=nil;let reply=visit.reply;visit.reply=nil;reply?(nil)
            for callback in callbacks {deliver(callback)}
        }
        private func deliver(_ callback:()->Void) {lock.lock();reserved -= 1;lock.unlock();callback()}
    }
    static func roomSink(_ room:WebRoom.Service,permitted:@escaping ()->Bool)->Sink? {
        guard permitted(),let ticket=room.audioGeneration,permitted() else {return nil};return RoomSink(room,ticket,permitted)
    }
    private final class RoomSink:Sink {
        private weak var room:WebRoom.Service?
        private var ticket:UUID,closed=false
        private let allowed:()->Bool
        init(_ room:WebRoom.Service,_ ticket:UUID,_ allowed:@escaping ()->Bool) {self.room=room;self.ticket=ticket;self.allowed=allowed}
        func consume(_ block:Block,discontinuity:Bool,completion:@escaping (Bool)->Void) {
            guard !closed,allowed(),let room,room.audioGeneration==ticket,allowed() else {completion(false);return}
            if discontinuity {guard let next=room.resetAudio() else {completion(false);return};ticket=next}
            completion(room.feed(block.samples,lane:block.lane,generation:ticket))
        }
        func close(completion:@escaping ()->Void) {
            if !closed {closed=true;if let room,room.audioGeneration==ticket {_ = room.resetAudio()}}
            completion()
        }
    }
}
