import Foundation
import CoreFoundation

enum WebPeer {
    struct Stream:Equatable,Sendable {let id:Int,depthMs:Int,targetMs:Int,longestWaitMs:Int,gaps:Int,skips:Int}
    struct Report:Equatable,Sendable {let streams:[Stream],outMs:Int,rate:Int,reconnects:Int}
    enum Message:Equatable {case report(Report),pong(Int64),ignored}
    enum SourceActivity {case starting,observed(Double?)}
    struct Snapshot {let report:Report?,answersBack:Bool,roundTrips:[Int],idle:Bool,retiring:Bool,queuedAudio:Int,droppedAudio:Int;var pcm=false}
    enum Outcome:Equatable {case cancelled,permission,clock,scheduler,transport,protocolFailure,limit,deadline,peerEnded,silent}
    private static let maximumJSONBytes=8192,maximumJSONDepth=16,maximumStreams=4
    static func message(_ bytes:Data)->Message {
        guard !bytes.isEmpty,bytes.count<=maximumJSONBytes else {return .ignored}
        var depth=0,quoted=false,escaped=false
        for byte in bytes {
            if quoted {if escaped {escaped=false} else if byte==92 {escaped=true} else if byte==34 {quoted=false};continue}
            if byte==34 {quoted=true} else if byte==123 || byte==91 {depth += 1;if depth>maximumJSONDepth {return .ignored}}
            else if byte==125 || byte==93 {depth -= 1;if depth<0 {return .ignored}}
        }
        guard depth==0,!quoted,let value=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any],let type=value["type"] as? String else {return .ignored}
        func number(_ value:Any?)->NSNumber? {guard let value=value as? NSNumber,CFGetTypeID(value) != CFBooleanGetTypeID(),value.doubleValue.isFinite else {return nil};return value}
        func field(_ value:[String:Any],_ key:String)->Int {guard let number=number(value[key]) else {return 0};return Int(min(1000000,max(-1,number.doubleValue)).rounded(.toNearestOrEven))}
        if type=="pong",let number=number(value["t"]),let stamp=Int64(number.stringValue) {return .pong(stamp)}
        guard type=="report" else {return .ignored}
        let streams=(value["streams"] as? [Any] ?? []).prefix(maximumStreams).map {row -> Stream in
            let row=row as? [String:Any] ?? [:]
            return Stream(id:field(row,"id"),depthMs:field(row,"depthMs"),targetMs:field(row,"targetMs"),longestWaitMs:field(row,"longestWaitMs"),gaps:field(row,"gaps"),skips:field(row,"skips"))
        }
        return .report(Report(streams:streams,outMs:field(value,"outMs"),rate:field(value,"rate"),reconnects:max(0,field(value,"reconnects"))))
    }
    final class Control {
        private let owner:Owner
        fileprivate init(_ owner:Owner) {self.owner=owner}
        @discardableResult func cancel()->Bool {owner.cancel()}
        @discardableResult func audioActivity()->Bool {owner.audioActivity()}
        @discardableResult func audio(_ value:WebAudio.Output)->Bool {owner.audio(value)}
        @discardableResult func flushAudio()->Bool {owner.flushAudio()}
        var snapshot:Snapshot? {owner.snapshot}
        deinit {_ = owner.cancel()}
    }
    static func start(queue:DispatchQueue,ready:WebConnection.Ready,permitted:@escaping ()->Bool,clock:@escaping ()->Double,
                      schedule:@escaping WebConnection.Schedule,sourceActivity:SourceActivity = .starting,started:@escaping ()->Void,closed:@escaping (Outcome)->Void)->Control {
        let owner=Owner(queue:queue,ready:ready,permitted:permitted,clock:clock,schedule:schedule,sourceActivity:sourceActivity,started:started,closed:closed)
        let control=Control(owner);queue.async {owner.start()};return control
    }
    private final class Ticket {
        private let lock=NSLock();private var cancelled=false,finished=false,queued=false
        func cancel()->Bool {lock.lock();defer {lock.unlock()};guard !cancelled,!finished else {return false};cancelled=true;return true}
        var isCancelled:Bool {lock.lock();defer {lock.unlock()};return cancelled}
        func pulse()->Bool {lock.lock();defer {lock.unlock()};guard !finished,!queued else {return false};queued=true;return true}
        func take() {lock.lock();queued=false;lock.unlock()}
        func finish() {lock.lock();finished=true;lock.unlock()}
    }
    private final class Frame {
        let bytes:Data,deadline:Double,close:Bool,audio:Bool
        var offset=0
        init(_ bytes:Data,_ deadline:Double,_ close:Bool,audio:Bool=false) {self.bytes=bytes;self.deadline=deadline;self.close=close;self.audio=audio}
    }
    fileprivate final class Owner {
        private static let maximumEvents=32,maximumQueuedFrames=16,maximumQueuedBytes=16384,maximumSamples=32
        private static let idleSeconds=2.0,aliveSeconds=5.0,pingSeconds=15.0,silentSeconds=20.0,writeSeconds=3.0
        private let queue:DispatchQueue,key=DispatchSpecificKey<UInt8>(),ticket=Ticket(),reader=WebSocketPackets.Reader()
        private let allowed:()->Bool,clock:()->Double,schedule:WebConnection.Schedule
        private var ready:WebConnection.Ready?,started:(()->Void)?,closed:((Outcome)->Void)?,keepAlive:Owner?,stop:(()->Void)?
        private var previous:Double?,lastAudio=0.0,lastAlive=0.0,lastPing=0.0,lastHeard=0.0
        private var report:Report?,answersBack=false,idle=false,issued=[Int64:Double](),trips=[(Double,Int)]()
        private let sourceActivity:SourceActivity,codec:WebAudioPackets.Codec,audioBox:WebAudio.Outbox
        private var active:Frame?
        private var outgoing=[Frame](),writeID:UUID?,readPending=false,writeRefused=false,sentClose=false,closeTarget:Double?
        private var closing=false,closeReceived=false,outcome=Outcome.cancelled
        init(queue:DispatchQueue,ready:WebConnection.Ready,permitted:@escaping ()->Bool,clock:@escaping ()->Double,schedule:@escaping WebConnection.Schedule,sourceActivity:SourceActivity = .starting,started:@escaping ()->Void,closed:@escaping (Outcome)->Void) {
            self.queue=queue;self.ready=ready;allowed=permitted;self.clock=clock;self.schedule=schedule;self.started=started;self.closed=closed
            self.sourceActivity=sourceActivity;codec=ready.codec == .pcm ? .pcm16:.opus;audioBox=WebAudio.Outbox(codec:codec)
            queue.setSpecific(key:key,value:1)
        }
        deinit {queue.setSpecific(key:key,value:nil)}
        private var onOwner:Bool {DispatchQueue.getSpecific(key:key)==1}
        func cancel()->Bool {guard ticket.cancel() else {return false};pulse();return true}
        private func pulse() {
            guard ticket.pulse() else {return};queue.async {[weak self] in guard let self else {return};ticket.take();tick()}
        }
        private func sample()->Double? {
            guard !closing else {return nil}
            guard !ticket.isCancelled else {beginClose(.cancelled);return nil}
            guard allowed() else {beginClose(.permission);return nil}
            let now=clock()
            guard !closing,!ticket.isCancelled,allowed() else {beginClose(ticket.isCancelled ? .cancelled:.permission);return nil}
            guard now.isFinite,now>=0,previous.map({now >= $0}) ?? true else {beginClose(.clock);return nil}
            previous=now;return now
        }
        func start() {
            keepAlive=self
            guard let now=sample(),now+Self.writeSeconds>now,(now+Self.writeSeconds).isFinite else {beginClose(.clock);return}
            lastAudio=now;lastAlive=now;lastPing=now;lastHeard=now
            switch sourceActivity {
            case .starting:break
            case .observed(let stamp):
                if let stamp {guard stamp.isFinite,stamp>=0,stamp<=now else {beginClose(.clock);return};lastAudio=stamp;idle=now-stamp>=Self.idleSeconds}
                else {idle=true}
            }
            stop=schedule(queue,{[weak self] in self?.pulse()})
            guard sample() != nil,!closing else {stopDriver();return}
            guard stop != nil else {beginClose(.scheduler);return}
            read()
            guard sample() != nil,!closing else {return}
            if idle {text(["type":"idle"])}
            let reply=started;started=nil;reply?()
        }
        var snapshot:Snapshot? {onOwner ? Snapshot(report:report,answersBack:answersBack,roundTrips:trips.map(\.1),idle:idle,retiring:closing || sentClose || writeRefused,queuedAudio:audioBox.count,droppedAudio:audioBox.dropped,pcm:codec == .pcm16):nil}
        func audioActivity()->Bool {
            guard onOwner,!sentClose,let now=sample(),started==nil else {return false};lastAudio=now
            if idle {idle=false;text(["type":"active"])}
            return !closing
        }
        func audio(_ value:WebAudio.Output)->Bool {
            guard onOwner,!sentClose,!writeRefused,started==nil,sample() != nil else {return false}
            switch (value.codec,codec) {case (.opus,.opus),(.pcm16,.pcm16):break;default:return false}
            guard audioBox.append(value.bytes),audioActivity() else {return false};write();return !closing && !writeRefused
        }
        func flushAudio()->Bool {
            guard onOwner,!sentClose,sample() != nil else {return false};audioBox.clear();return true
        }
        private func tick() {
            guard let now=sample() else {return}
            trips.removeAll(where:{now-$0.0>60});issued=issued.filter({now-$0.value<=120})
            if let target=closeTarget,now>=target {beginClose(.deadline);return}
            if let frame=active,now>=frame.deadline {beginClose(.deadline);return}
            if let frame=outgoing.first,now>=frame.deadline {beginClose(.deadline);return}
            guard !sentClose else {return}
            if answersBack,now-lastHeard>Self.silentSeconds {beginClose(.silent);return}
            if !idle,now-lastAudio>=Self.idleSeconds {idle=true;audioBox.clear();text(["type":"idle"])}
            if now-lastAlive>=Self.aliveSeconds {
                let milliseconds=(now*1000).rounded(.down)
                guard milliseconds.isFinite,milliseconds>=0,milliseconds<Double(Int64.max) else {beginClose(.clock);return}
                let stamp=Int64(milliseconds);lastAlive=now
                if issued.count>=Self.maximumSamples,let oldest=issued.min(by:{$0.value<$1.value})?.key {issued[oldest]=nil}
                issued[stamp]=now;text(["type":"alive","t":stamp])
            }
            if now-lastPing>=Self.pingSeconds {lastPing=now;control(.ping,Data())}
        }
        private func read() {
            guard !readPending,!sentClose,sample() != nil,let ready else {return};readPending=true
            let policy=WebConnection.EndPolicy(clock:clock,schedule:schedule)
            guard ready.readRespondingToEnd(reader:reader,policy:policy,completion:{[weak self] value,end in self?.received(value,end)}) else {readPending=false;beginClose(.transport);return}
        }
        private func received(_ value:WebConnection.Read,_ end:WebConnection.EndOutcome) {
            guard readPending else {return};readPending=false
            if closing {finishIfRetired();return}
            guard let now=sample() else {return}
            switch value {
            case .bytes(let bytes):
                guard end == .notRequested else {beginClose(.protocolFailure);return}
                var input=bytes,events=0
                while !input.isEmpty,!closing,!sentClose,events<Self.maximumEvents {
                    let result=reader.feed(input);events += 1
                    guard result.consumedBytes>0,result.consumedBytes<=input.count else {beginClose(.protocolFailure);return}
                    input=Data(input.dropFirst(result.consumedBytes))
                    if result.event == .pending {break}
                    lastHeard=now
                    switch result.event {
                    case .text(let bytes):
                        switch message(bytes) {
                        case .report(let value):report=value;answersBack=true
                        case .pong(let stamp):
                            if let sent=issued.removeValue(forKey:stamp) {
                                let milliseconds=(now-sent)*1000
                                if milliseconds.isFinite,milliseconds>=0,milliseconds<=120000 {
                                    answersBack=true;trips.removeAll(where:{now-$0.0>60});if trips.count>=Self.maximumSamples {trips.removeFirst()};trips.append((now,Int(milliseconds.rounded(.toNearestOrEven))))
                                }
                            }
                        case .ignored:break
                        }
                    case .ping(let bytes):control(.pong,bytes)
                    case .pong,.binary:break
                    case .close:
                        guard let bytes=reader.takeCloseResponse()?.takeBytes() else {beginClose(.protocolFailure);return}
                        closeResponse(bytes,now)
                    default:beginClose(.protocolFailure)
                    }
                }
                guard !closing,!sentClose else {return}
                guard input.isEmpty else {beginClose(.limit);return}
                if writeRefused {beginClose(.transport);return}
                read()
            case .ending,.end:
                // Ready consumed terminal input with this same reader. Feeding it again would replay the final frame.
                beginClose(end == .processed || end == .notRequested ? .peerEnded:end == .deadline ? .deadline:.transport)
            case .failed:beginClose(.transport)
            }
        }
        private func text(_ value:[String:Any]) {
            guard let bytes=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),bytes.count<=1024 else {beginClose(.limit);return}
            control(.text,bytes)
        }
        private func control(_ kind:WebSocketPackets.Kind,_ bytes:Data) {
            guard !closing,!sentClose else {return}
            guard let bytes=WebSocketPackets.serverFrame(kind:kind,payload:bytes) else {beginClose(.limit);return}
            enqueue(bytes,false)
        }
        private func closeResponse(_ bytes:Data,_ now:Double) {
            guard !sentClose,!closing else {return};sentClose=true;closeTarget=now+Self.writeSeconds
            outgoing.removeAll();audioBox.clear()
            enqueue(bytes,true)
        }
        private func enqueue(_ bytes:Data,_ close:Bool) {
            guard !closing,let now=sample() else {return}
            let heldControl=active.flatMap {$0.audio ? nil:$0}
            guard bytes.count>0,bytes.count<=WebConnection.maximumIOBytes,outgoing.count+(heldControl == nil ? 0:1)<Self.maximumQueuedFrames,
                  outgoing.reduce(bytes.count,{$0+$1.bytes.count})+(heldControl?.bytes.count ?? 0)<=Self.maximumQueuedBytes,now+Self.writeSeconds>now,(now+Self.writeSeconds).isFinite else {beginClose(.limit);return}
            outgoing.append(Frame(bytes,min(now+Self.writeSeconds,closeTarget ?? .infinity),close));write()
        }
        private func write() {
            guard writeID==nil,!writeRefused,let now=sample(),let ready else {return}
            if active==nil {
                if !outgoing.isEmpty {active=outgoing.removeFirst()}
                else if !sentClose,let payload=audioBox.pop() {
                    guard now+Self.writeSeconds>now,(now+Self.writeSeconds).isFinite,let bytes=WebSocketPackets.serverFrame(kind:.binary,payload:payload) else {beginClose(.limit);return}
                    active=Frame(bytes,now+Self.writeSeconds,false,audio:true)
                }
            }
            guard let frame=active else {return}
            guard now<frame.deadline,closeTarget.map({now<$0}) ?? true else {beginClose(.deadline);return}
            let bytes=Data(frame.bytes.dropFirst(frame.offset)),id=UUID();writeID=id
            if !ready.write(bytes,completion:{[weak self,frame] count in guard let self else {return};self.written(id,frame,count,bytes.count)}) {
                writeID=nil
                // A final-read response can freeze Ready while its callback still owns retirement. Do not retry or cancel that proof speculatively.
                if readPending {writeRefused=true} else {beginClose(.transport)}
            }
        }
        private func written(_ id:UUID,_ frame:Frame,_ count:Int?,_ maximum:Int) {
            guard writeID==id else {return};writeID=nil
            if closing {finishIfRetired();return}
            guard active === frame,let now=sample(),now<frame.deadline,let count,count>0,count<=maximum else {beginClose(.transport);return}
            frame.offset += count
            if frame.offset==frame.bytes.count {
                active=nil
                if frame.close {beginClose(.peerEnded);return}
            }
            write()
        }
        private func stopDriver() {let cancel=stop;stop=nil;cancel?()}
        private func beginClose(_ reason:Outcome) {
            guard !closing else {return};closing=true;outcome=reason;started=nil;stopDriver();outgoing.removeAll();audioBox.clear();active=nil;reader.cancel()
            guard let ready else {closeReceived=true;finishIfRetired();return}
            _ = ready.close {[weak self] in guard let self else {return};closeReceived=true;finishIfRetired()}
        }
        private func finishIfRetired() {
            guard closing,closeReceived,!readPending,writeID==nil else {return}
            ticket.finish();ready=nil;issued.removeAll();outgoing.removeAll();stopDriver()
            let reply=closed;closed=nil;keepAlive=nil;reply?(outcome)
        }
    }
}
