import Foundation
import AudioSupport
enum WebAudio {
    // Pinned RenderRoute wire values; assigning Mac producers to them is a separate caller contract.
    enum Lane:UInt8,CaseIterable {case mixed=0,wasapi=1,asio=2}
    struct Demand:Equatable {let opus:Bool,pcm:Bool;static let none=Demand(opus:false,pcm:false)}
    struct Output {let bytes:Data,codec:WebAudioPackets.Codec}
    protocol Encoder:AnyObject {func encode(_ samples:[Float])->Data?;func close()}
    static let maximumInputSamples=8192,maximumQueuedFrames=32
    static func nativeEncoder()->Encoder? {NativeEncoder()}
    private final class NativeEncoder:Encoder {
        private var state:UnsafeMutableRawPointer?
        private var scratch=[UInt8](repeating:0,count:WebAudioPackets.maximumOpusPayload)
        init?() {guard let state=rs_opus_web_encoder() else {return nil};self.state=state}
        func encode(_ samples:[Float])->Data? {
            guard let state,samples.count==WebAudioPackets.frameSamples*WebAudioPackets.channels,samples.allSatisfy(\.isFinite) else {return nil}
            let count=samples.withUnsafeBufferPointer { source in scratch.withUnsafeMutableBufferPointer { destination in
                rs_opus_encode(state,source.baseAddress,Int32(WebAudioPackets.frameSamples),destination.baseAddress,Int32(destination.count))
            } }
            guard count>0,count<=scratch.count else {return nil};return Data(scratch.prefix(Int(count)))
        }
        func close() {let old=state;state=nil;if let old {rs_opus_encoder_destroy(old)}}
        deinit {close()}
    }
    private final class LaneState {
        var samples=[Float](repeating:0,count:WebAudioPackets.frameSamples*WebAudioPackets.channels),filled=0
        var sequence:UInt32,encoder:Encoder?
        init(_ sequence:UInt32) {self.sequence=sequence}
    }
    final class Engine {
        private let queue:DispatchQueue,key=DispatchSpecificKey<UInt8>(),isolated:Bool,allowed:()->Bool,muted:()->Bool,demand:()->Demand,factory:()->Encoder?,output:(Output)->Void
        private let lanes:[LaneState]
        private var epoch=UUID(),stopped=false,busy=false,lastDemand=Demand.none
        init(queue:DispatchQueue,isolated:Bool=true,permitted:@escaping ()->Bool={false},muted:@escaping ()->Bool={true},demand:@escaping ()->Demand={.none},initialSequence:UInt32=0,factory:@escaping ()->Encoder?={WebAudio.nativeEncoder()},output:@escaping (Output)->Void) {
            self.queue=queue;self.isolated=isolated;allowed=permitted;self.muted=muted;self.demand=demand;self.factory=factory;self.output=output
            lanes=Lane.allCases.map {_ in LaneState(initialSequence)};queue.setSpecific(key:key,value:1)
        }
        deinit {retire();queue.setSpecific(key:key,value:nil)}
        private var onOwner:Bool {DispatchQueue.getSpecific(key:key)==1}
        private func boundary(_ id:UUID,_ expected:Demand)->Bool {
            guard !stopped,!isolated,epoch==id else {return false}
            guard allowed() else {stop();return false}
            guard !stopped,epoch==id else {return false}
            guard !muted(),demand()==expected else {_ = flush();return false}
            return !stopped && epoch==id
        }
        // Synchronous worker-only memory work. False may follow earlier outputs: never retry the entire block.
        func feed(_ samples:[Float],lane:Lane)->Bool {
            guard onOwner,!busy,!stopped,!isolated else {return false}
            guard !samples.isEmpty,samples.count<=maximumInputSamples,samples.count.isMultiple(of:WebAudioPackets.channels),samples.allSatisfy(\.isFinite) else {return false}
            busy=true;defer {busy=false;if stopped {retire()}}
            guard allowed() else {stop();return false}
            let selected=demand()
            guard !stopped,!muted(),selected != .none else {_ = flush();return false}
            if selected != lastDemand {_ = flush();lastDemand=selected}
            let id=epoch,state=lanes[Int(lane.rawValue)]
            guard boundary(id,selected) else {return false}
            var offset=0
            while offset<samples.count {
                guard boundary(id,selected) else {return false}
                let count=min(samples.count-offset,state.samples.count-state.filled)
                state.samples.replaceSubrange(state.filled..<state.filled+count,with:samples[offset..<offset+count]);state.filled += count;offset += count
                guard state.filled==state.samples.count else {continue};state.filled=0
                let sequence=state.sequence;state.sequence &+= 1
                var opus:Data?
                if selected.opus {
                    if state.encoder==nil {
                        let encoder=factory()
                        guard boundary(id,selected) else {
                            encoder?.close()
                            // An explicit flush changed the epoch; its uninstalled encoder is retired, not a service failure.
                            if epoch==id {stop()};return false
                        }
                        guard let encoder else {stop();return false};state.encoder=encoder
                    }
                    opus=state.encoder?.encode(state.samples)
                    guard boundary(id,selected) else {return false}
                    guard let bytes=opus,!bytes.isEmpty,bytes.count<=WebAudioPackets.maximumOpusPayload else {stop();return false}
                }
                let pcm=selected.pcm ? WebAudioPackets.pcm(state.samples):nil
                guard boundary(id,selected) else {return false}
                if let opus,let bytes=WebAudioPackets.packet(stream:lane.rawValue,sequence:sequence,payload:opus,codec:.opus) {output(Output(bytes:bytes,codec:.opus))}
                guard boundary(id,selected) else {return false}
                if let pcm,let bytes=WebAudioPackets.packet(stream:lane.rawValue,sequence:sequence,payload:pcm,codec:.pcm16) {output(Output(bytes:bytes,codec:.pcm16))}
                guard boundary(id,selected) else {return false}
            }
            return true
        }
        @discardableResult func flush()->Bool {
            guard onOwner,!stopped else {return false};epoch=UUID();lastDemand = .none
            for lane in lanes {lane.filled=0};return true
        }
        func stop() {guard onOwner,!stopped else {return};stopped=true;epoch=UUID();for lane in lanes {lane.filled=0};if !busy {retire()}}
        private func retire() {for lane in lanes {let encoder=lane.encoder;lane.encoder=nil;encoder?.close()}}
    }
    // One browser's audio backlog across all lanes. The in-flight writer owns its popped frame separately.
    final class Outbox {
        private let codec:WebAudioPackets.Codec
        private var slots=[Data?](repeating:nil,count:maximumQueuedFrames),head=0
        private(set) var count=0,dropped=0
        init(codec:WebAudioPackets.Codec) {self.codec=codec}
        func append(_ bytes:Data)->Bool {
            guard bytes.count<=WebAudioPackets.headerSize+WebAudioPackets.maximumOpusPayload,let packet=WebAudioPackets.parse(bytes,codec:codec),Lane(rawValue:packet.stream) != nil else {return false}
            if count==maximumQueuedFrames {_ = pop();if dropped<Int.max {dropped += 1}}
            slots[(head+count)%maximumQueuedFrames]=Data(bytes);count += 1;return true
        }
        func pop()->Data? {guard count>0 else {return nil};let bytes=slots[head];slots[head]=nil;head=(head+1)%maximumQueuedFrames;count -= 1;return bytes}
        func clear() {for i in slots.indices {slots[i]=nil};head=0;count=0}
    }
}
