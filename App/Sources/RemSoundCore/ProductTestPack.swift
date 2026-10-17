import AudioSupport
import CryptoKit
import Foundation
import RemSoundJam

/// Named checks run production paths; audio transport requires an explicit private isolated fixture root.
public enum ProductTestPack {
    public enum Pack: String, Sendable { case full, feature }
    public struct Step: Codable, Equatable, Sendable {
        public let name: String, status: String
        public let assertions: Int
        public let failures: [String]
    }
    public struct Report: Codable, Sendable {
        public let schema: Int
        public let pack: String, startedUTC: String, termination: String
        public let selection: String?
        public let catalogSteps: Int
        public let steps: [Step]
        public var exitCode: Int {
            guard schema == 1, Pack(rawValue:pack) != nil, catalogSteps == ProductTestPack.names.count,
                termination == "completed", !steps.isEmpty,
                selection.map({ steps.count == 1 && steps[0].name == $0 && ProductTestPack.names.contains($0) }) ?? (steps.count == catalogSteps && zip(steps,ProductTestPack.names).allSatisfy { $0.name == $1 }),
                steps.allSatisfy({ $0.status == "PASS" && $0.assertions > 0 && $0.failures.isEmpty }) else { return 1 }
            return 0
        }
    }
    public static let knownAnswers = "CROSS-PORT KNOWN ANSWERS: the exact bytes of the header, format, heartbeat and sealed payloads, both ways"
    public static let pcm24="24-bit PCM pack/unpack (sign, clamp, 1-LSB accuracy)"
    public static let ringIntegrity="Audio ring buffer integrity (wrap, drop-oldest, underrun fill)"
    public static var names: [String] { ProductTestCatalog.names }
    public static func run(pack: Pack, only: String? = nil, budget: Double = 3) -> Report {
        run(pack:pack,only:only,budget:budget,clock:{ ProcessInfo.processInfo.systemUptime })
    }
    // Packaged builds have no reliable source-change/release comparison. As Windows does in that case,
    // feature conservatively selects every entry; it must never silently omit an unimplemented Core guard.
    static func run(pack: Pack, only: String?, budget: Double, clock: () -> Double) -> Report {
        run(pack: pack, only: only, budget: budget, clock: clock, nativeProfileLogging: nil)
    }
    @_spi(NativeProductChecks) public static func run(pack: Pack, only: String? = nil, budget: Double = 3,
        nativeProfileLogging: @escaping () -> (assertions: Int, failures: [String])?,
        nativeControlSpecifications: (() -> (assertions: Int, failures: [String])?)? = nil,
        nativeDialogs: ((Bool) -> (assertions: Int, failures: [String])?)? = nil,
        nativeEventClaims: (() -> (assertions: Int, failures: [String])?)? = nil, nativeAudioAxis: (() -> (assertions: Int, failures: [String])?)? = nil, nativeContextHelp: (() -> (assertions: Int, failures: [String])?)? = nil) -> Report {
        run(pack: pack, only: only, budget: budget, clock: { ProcessInfo.processInfo.systemUptime }, nativeProfileLogging: nativeProfileLogging, nativeControlSpecifications: nativeControlSpecifications, nativeDialogs: nativeDialogs, nativeEventClaims: nativeEventClaims, nativeAudioAxis: nativeAudioAxis, nativeContextHelp: nativeContextHelp)
    }
    private static func run(pack: Pack, only: String?, budget: Double, clock: () -> Double,
        nativeProfileLogging: (() -> (assertions: Int, failures: [String])?)?,
        nativeControlSpecifications: (() -> (assertions: Int, failures: [String])?)? = nil,
        nativeDialogs: ((Bool) -> (assertions: Int, failures: [String])?)? = nil,
        nativeEventClaims: (() -> (assertions: Int, failures: [String])?)? = nil, nativeAudioAxis: (() -> (assertions: Int, failures: [String])?)? = nil, nativeContextHelp: (() -> (assertions: Int, failures: [String])?)? = nil) -> Report {
        let stamp=ISO8601DateFormatter().string(from:Date())
        var steps:[Step]=[]
        func report(_ reason:String) -> Report { .init(schema:1,pack:pack.rawValue,startedUTC:stamp,termination:reason,selection:only,catalogSteps:names.count,steps:steps) }
        guard budget.isFinite, budget > 0, budget <= 8 else { return report("invalidBudget") }
        if let only, !names.contains(only) { return report("invalidSelection") }
        let start=clock();guard start.isFinite, start >= 0 else { return report("invalidClock") }
        var previous=start
        func boundary() -> String? {
            let now=clock();guard now.isFinite, now >= previous else { return "invalidClock" }
            previous=now;return now-start >= budget ? "deadline" : nil
        }
        for name in names where only == nil || name == only {
            if let reason=boundary() { return report(reason) }
            if name == knownAnswers { steps.append(checkKnownAnswers()) }
            else if name == pcm24 { steps.append(checkPCM24()) }
            else if name == "PCM frame reassembly (order, loss, discard counters)" { steps.append(checkPCMReassembly()) }
            else if name == "Receiver allow-list gate (stranger rejected, no session)" { steps.append(checkReceiverAllowList()) }
            else if name == "Heartbeat wire round-trip + ping→pong echo" { steps.append(checkHeartbeat()) }
            else if name == "Encryption round-trip" { steps.append(checkEncryption()) }
            else if name == "Packet framing and rejection (unknown types and cut-short payloads too)" { steps.append(checkPacketFraming()) }
            else if name == "Receiver decryptor: wrong key yields silence, not noise" { steps.append(checkReceiverDecryptor()) }
            else if name == "Audio round-trip (PCM)" { steps.append(checkAudioRoundTrip(opus: false)) }
            else if name == "Audio round-trip (Opus)" { steps.append(checkAudioRoundTrip(opus: true)) }
            else if name == ringIntegrity { steps.append(checkAudioRings()) }
            else if name == latencyStages { steps.append(checkLatencyStages()) }
            else if name == laneCapture { steps.append(checkLaneCapture()) }
            else if name == peerStatus { steps.append(checkPeerStatus()) }
            else if name == simulatorReplay { steps.append(checkSimulatorReplay()) }
            else if name == pluginInstall { steps.append(checkPluginInstallation()) }
            else if name == logsPerProfile { steps.append(checkProfileLogging(native: nativeProfileLogging)) }
            else if name == eventClaims { steps.append(checkEventClaims(native: nativeEventClaims)) }
            else if name == audioConfigurations { steps.append(checkAudioConfigurations(native: nativeAudioAxis)) }
            else if name == contextHelpAll { steps.append(checkContextHelp(native: nativeContextHelp)) }
            else if name == everyDialog || name == dialogControls { steps.append(checkDialogs(controls: name == dialogControls, native: nativeDialogs)) }
            else if name == controlSpecifications { steps.append(checkControlSpecifications(native: nativeControlSpecifications)) }
            else if name == "v5 settings and shaping round-trip" { steps.append(checkNamedPeerSettings()) }
            else { steps.append(.init(name:name,status:"UNVERIFIED",assertions:0,failures:["missing-product-check"])) }
            // A synchronous crypto call owns its credit until return; elapsed time never fabricates cancellation.
            if let reason=boundary() { return report(reason) }
        }
        return report("completed")
    }
    static let latencyStages="Latency estimate counts every stage (no silently-missing term)"
    static let laneCapture="CAPTURE DELAY PER LANE: each lane's format says its own capture, and the far end's readout counts the right one per output"
    static let peerStatus="PEER LATENCY: each connected peer's total latency beside its ping in the status, from its own stream, in all three configurations"
    private static func checkPeerStatus() -> Step {
        var count=0,failures:[String]=[]
        func require(_ condition:Bool,_ code:String) { count += 1;if !condition { failures.append(code) } }
        let format=StreamFormat.opus(Data(repeating:1,count:8),frames:120).capturing(milliseconds:3)
        func summary(_ inputs:[PeerLatencyReport.Input],_ outputs:[Double?]=[5],_ rtt:Double?=20) -> PeerLatencyReport.Summary {
            .init(inputs:inputs,outputs:outputs,rttMs:rtt)
        }
        func input(_ capture:Double=3,_ queue:Int=480) -> PeerLatencyReport.Input {
            .init(stream:"current",format:format.capturing(milliseconds:capture),queuedFrames:queue)
        }
        let base=summary([input()])
        require(base.status=="ping 20 ms, total latency about 30 ms","peer.status-components")
        require(base.maximumCompleteMs==30.5,"peer.complete-unrounded")
        require(summary([]).status=="ping 20 ms","peer.quiet-ping-only")
        require(summary([],[],nil).status=="ping unknown","peer.quiet-unknown")
        require(summary([input()], [5],40).status.contains("ping 40 ms, total latency about 40 ms"),"peer.own-ping")
        let both=summary([input()],[5,25]).status
        require(both.contains("30 ms on Core Audio output 1"),"peer.first-output")
        require(both.contains("50 ms on Core Audio output 2"),"peer.second-output")
        require(!both.contains("ASIO") && !both.contains("WASAPI"),"peer.mac-output-roles")
        require(summary([input(3.1)]).status==summary([input(3.2)]).status,"peer.stable-rounded-values")
        require(summary([input(8)]).status != base.status,"peer.changed-rounded-value")
        let unknown=summary([input(0)],[],nil).status
        require(unknown.contains("capture not stated"),"peer.unknown-capture")
        require(unknown.contains("output not measured"),"peer.unknown-output")
        require(unknown.contains("round trip not measured"),"peer.unknown-round-trip")
        require(!unknown.contains("total latency about"),"peer.no-guessed-total")
        require(summary([input(20),input(1,0)]).maximumCompleteMs==47.5,"peer.correlated-current-streams")
        let bounded=summary(Array(repeating:input(),count:65))
        require(bounded.journeys.count==64 && bounded.truncated && bounded.maximumCompleteMs==nil,"peer.bounded-summary")
        require(bounded.status.contains("additional journeys omitted"),"peer.truncation-truthful")
        let passed=failures.isEmpty
        failures.append("native-peer-status-product-runner-and-source-output-acceptance-unverified")
        return .init(name:peerStatus,status:passed ? "UNVERIFIED" : "FAIL",assertions:count,failures:failures)
    }
    private static func checkLatencyStages() -> Step {
        var count=0,failures:[String]=[]
        func require(_ condition:Bool,_ code:String) { count += 1;if !condition { failures.append(code) } }
        let fingerprint=Data(repeating:1,count:8)
        let format=StreamFormat.opus(fingerprint,frames:120).capturing(milliseconds:3)
        func report(_ f:StreamFormat?=nil,_ queue:Int=480,_ rtt:Double?=20,_ output:Double?=5) -> PeerLatencyReport {
            PeerLatencyReport(format:f ?? format,queuedFrames:queue,rttMs:rtt,outputMs:output)
        }
        let base=report()
        require(base.totalMs==30.5,"latency.all-stages")
        require(report(format.capturing(milliseconds:7)).totalMs==34.5,"latency.capture-term")
        require(report(.opus(fingerprint,frames:240).capturing(milliseconds:3)).totalMs==33,"latency.packet-term")
        require(report(nil,720).totalMs==35.5,"latency.queue-term")
        require(report(nil,480,40).totalMs==40.5,"latency.half-own-ping")
        require(report(nil,480,20,7).totalMs==32.5,"latency.output-term")
        require(report(nil,480,20,25).totalMs==50.5,"latency.separate-output")
        let absent=report(format.capturing(milliseconds:0))
        require(absent.totalMs==nil && absent.knownSubtotalMs==27.5,"latency.capture-not-stated")
        require(absent.logDescription.contains("capture component not stated") && absent.logDescription.contains("complete sum unavailable"),"latency.unknown-words")
        require(report(nil,480,nil).totalMs==nil,"latency.unmeasured-ping")
        require(report(nil,480,20,nil).totalMs==nil,"latency.unmeasured-output")
        require(report(nil,480,20,.nan).totalMs==nil,"latency.invalid-output")
        require(report(nil,480,20,0).totalMs==25.5,"latency.reported-zero-output")
        require(PeerLatencyReport.maximumComplete([])==nil,"latency.quiet-peer")
        require(PeerLatencyReport.maximumComplete([base,absent])==nil,"latency.incomplete-peer")
        let slower=report(format.capturing(milliseconds:20))
        let shortQueue=report(.opus(fingerprint,frames:960).capturing(milliseconds:1),0)
        require(PeerLatencyReport.maximumComplete([slower,shortQueue])==47.5,"latency.correlated-stream-total")
        let passed=failures.isEmpty
        failures.append("native-output-estimate-and-visible-readout-acceptance-unverified")
        return .init(name:latencyStages,status:passed ? "UNVERIFIED" : "FAIL",assertions:count,failures:failures)
    }
    private static func checkLaneCapture() -> Step {
        var count=0,failures:[String]=[]
        func require(_ condition:Bool,_ code:String) { count += 1;if !condition { failures.append(code) } }
        let fingerprint=Data(repeating:1,count:8)
        let input=StreamFormat.pcm(fingerprint).capturing(milliseconds:3.5)
        let system=StreamFormat.pcm(fingerprint)
        require(StreamFormat.parse(input.encode(lane:.wasapi))?.captureLatencyMs==3.5,"lane.input-component")
        require(StreamFormat.parse(system.encode(lane:.asio))?.captureLatencyMs==0,"lane.unmeasured-source")
        var bytes=Data();bytes.put(Double(48_000).bitPattern);bytes.put(UInt32(256))
        let geometry=DAWCallbackGeometry(payload:bytes)
        require(geometry?.nominalBlockDurationMs==Double(256)*1000/48_000,"lane.host-block-component")
        let plugin=StreamFormat.pcm(fingerprint).capturing(milliseconds:geometry?.nominalBlockDurationMs ?? 0)
        require(StreamFormat.parse(plugin.encode())?.captureLatencyMs==5.3,"lane.plugin-wire-component")
        require(plugin.captureLatencyMs != input.captureLatencyMs,"lane.no-input-borrow")
        var observation=DAWCallbackObservation();observation.observe(bytes,now:10)
        require(observation.geometry(now:10) != nil,"lane.fresh-host-block")
        require(observation.geometry(now:13)==nil,"lane.stale-host-block")
        require(observation.geometry(now:9)==nil,"lane.clock-regression")
        bytes=Data();bytes.put(Double(44_100).bitPattern);bytes.put(UInt32(256))
        require(DAWCallbackGeometry(payload:bytes)?.nominalBlockDurationMs==Double(256)*1000/44_100,"lane.host-rate-units")
        let first=PeerLatencyReport(format:input,queuedFrames:240,rttMs:20,outputMs:5)
        let second=PeerLatencyReport(format:input.capturing(milliseconds:12),queuedFrames:240,rttMs:20,outputMs:5)
        require(first.captureMs==3.5 && second.captureMs==12,"lane.received-components-separate")
        require(abs((second.totalMs ?? 0)-(first.totalMs ?? 0)-8.5)<0.000001,"lane.component-reaches-report")
        require(PeerLatencyReport(format:system,queuedFrames:240,rttMs:20,outputMs:5).totalMs==nil,"lane.unmeasured-not-zero-total")
        let passed=failures.isEmpty
        failures.append("input-system-custom-lane-and-native-output-visible-acceptance-unverified")
        return .init(name:laneCapture,status:passed ? "UNVERIFIED" : "FAIL",assertions:count,failures:failures)
    }
    private static func checkKnownAnswers() -> Step {
        var count=0,failures:[String]=[]
        func require(_ condition:Bool,_ code:String) { count += 1;if !condition { failures.append(code) } }
        func hex(_ value:String) -> Data {
            let bytes=Array(value.utf8);var result=Data()
            for i in stride(from:0,to:bytes.count,by:2) {
                result.append(UInt8(String(decoding:bytes[i..<i+2],as:UTF8.self),radix:16)!)
            }
            return result
        }
        do {
            require(Wire.packet(.audio,stream:0x1234,sequence:0x0a0b0c0d,payload:Data()) == hex("524d4e44010234120d0c0b0a"),"header.bytes")
            require(Wire.packet(.audio,stream:0,sequence:1,payload:Data()) == hex("524d4e440102010001000000"),"header.zero-stream")
            let beat=Wire.parse(hex("524d4e440104ffff07000000"))
            require(beat?.kind == .heartbeat && beat?.stream == 0xffff && beat?.sequence == 7,"header.heartbeat")
            let fingerprint=hex("a0a1a2a3a4a5a6a7")
            let expected=hex("80bb00000200000010000000010000000400000000ee0200020000007800000002000000a0a1a2a3a4a5a6a72300")
            let format=StreamFormat.opus(fingerprint,frames:120).capturing(milliseconds:3.5)
            let encoded=format.encode(lane:.asio)
            require(encoded.prefix(44) == expected.prefix(44),"format.fields")
            require(encoded == expected,"format.capture-latency")
            let decoded=StreamFormat.parse(expected)
            require(decoded?.channels == 2 && decoded?.codec == 2 && decoded?.frames == 120 && decoded?.fingerprint == fingerprint && decoded?.lane == .asio && decoded?.captureLatencyMs == 3.5,"format.read")
            require(StreamFormat.parse(Data(expected.prefix(32))) != nil,"format.legacy32")
            let credential=try Credentials(password:"known answer")
            let plain=hex("00112233445566778899")
            let sealed=try credential.seal(plain)
            require(sealed.count == plain.count+28,"envelope.size")
            let box=try AES.GCM.SealedBox(nonce:AES.GCM.Nonce(data:sealed.prefix(12)),ciphertext:sealed.dropFirst(28),tag:sealed[12..<28])
            require(try AES.GCM.open(box,using:credential.key) == plain,"envelope.write-layout")
            let nonce=try AES.GCM.Nonce(data:hex("0102030405060708090a0b0c"))
            func independentSeal(_ bytes:Data) throws -> Data {
                let box=try AES.GCM.seal(bytes,using:credential.key,nonce:nonce)
                return nonce.withUnsafeBytes { Data($0) }+box.tag+box.ciphertext
            }
            require(try credential.open(independentSeal(plain)) == plain,"envelope.read-layout")
            var diagnostics=SendWorkDiagnostics(enabled:false)
            let audio=try credential.sealAudio(plain,diagnostics:&diagnostics)
            let audioBox=try AES.GCM.SealedBox(nonce:AES.GCM.Nonce(data:audio.prefix(12)),ciphertext:audio.dropFirst(28),tag:audio[12..<28])
            require(try AES.GCM.open(audioBox,using:credential.key) == plain,"audio.envelope")
            let id=UUID(uuidString:"00112233-4455-6677-8899-aabbccddeeff")!
            let tick=try credential.tick(id:id,now:1_790_000_000,sequence:7)
            let tickPacket=Wire.parse(tick)
            require(tickPacket?.kind == .tickProof && tickPacket?.stream == 0xffff && tickPacket?.sequence == 7,"tick.header")
            require(try credential.open(Data(tick.dropFirst(Wire.headerSize))) == hex("01803bb16a0000000000112233445566778899aabbccddeeff"),"tick.plaintext")
            let control=Data(RemoteControl.plaintext(.volumeDown,delta:-3,unixSeconds:1_790_000_000))
            require(control == hex("01fd803bb16a00000000"),"control.write")
            let received=RemoteControl.parse(Array(try credential.open(independentSeal(control))))
            require(received?.kind == .volumeDown && received?.delta == -3 && received?.unixSeconds == 1_790_000_000,"control.read")
            let pong=HeartbeatPayload.encode(.pong,tickMs:0x0102030405060708)
            require(pong == hex("010807060504030201"),"heartbeat.write")
            let ping=HeartbeatPayload.parse(hex("000807060504030201"))
            require(ping?.kind == .ping && ping?.tickMs == 0x0102030405060708 && ping?.flags == 0,"heartbeat.read")
            require(HeartbeatPayload.parse(Data(repeating:0,count:8)) == nil,"heartbeat.truncated")
            let otherTick=try credential.open(independentSeal(hex("01803bb16a0000000000112233445566778899aabbccddeeff")))
            let tickRead=TickProofPayload.parse(otherTick)
            require(tickRead?.id == id && tickRead?.unixSeconds == 1_790_000_000,"tick.read")
            var invalidTick=otherTick;invalidTick[0]=2
            require(TickProofPayload.parse(invalidTick) == nil && TickProofPayload.parse(Data(otherTick.dropLast())) == nil,"tick.invalid")
        } catch { failures.append("crypto-operation-failed") }
        return .init(name:knownAnswers,status:failures.isEmpty ? "PASS" : "FAIL",assertions:count,failures:failures)
    }
    private static func checkPCM24() -> Step {
        let lsb:Float=1/8_388_607
        let samples:[Float]=[-1,-0.5,-0.001,-2*lsb,0,2*lsb,0.001,0.25,0.5,0.99999,1]
        guard let bytes=PCM24.encode(samples),let back=PCM24.decode(bytes),back.count == samples.count,
            let loud=PCM24.encode([2,-2]),let clamped=PCM24.decode(loud) else {
            return .init(name:pcm24,status:"FAIL",assertions:0,failures:["pcm24.conversion-refused"])
        }
        var count=0,failures:[String]=[]
        func require(_ condition:Bool,_ code:String) { count += 1;if !condition { failures.append(code) } }
        for i in samples.indices {
            require(abs(samples[i]-back[i]) <= 1.5*lsb,"pcm24.accuracy")
            require(samples[i] == 0 || samples[i].sign == back[i].sign || abs(samples[i]) <= lsb,"pcm24.sign")
        }
        require(abs(clamped[0]-1) < 0.000001 && abs(clamped[1]+1) < 0.000001,"pcm24.clamp")
        return .init(name:pcm24,status:failures.isEmpty ? "PASS" : "FAIL",assertions:count,failures:failures)
    }
    private static func checkAudioRings() -> Step {
        guard let ring=rs_ring_create(128) else { return .init(name:ringIntegrity,status:"FAIL",assertions:0,failures:["ring.allocation"]) }
        defer { rs_ring_destroy(ring) }
        var count=0,failures:[String]=[]
        func require(_ condition:Bool,_ code:String) { count += 1;if !condition { failures.append(code) } }
        func write(_ values:[Float]) -> Int {
            let stereo=values.flatMap { [$0,-$0] }
            return stereo.withUnsafeBufferPointer { rs_ring_write_interleaved(ring,$0.baseAddress,values.count) }
        }
        func read(_ frames:Int) -> (Int,[Float],[Float]) {
            var left=[Float](repeating:9,count:frames),right=left
            let got=left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { rs_ring_read(ring,l.baseAddress,$0.baseAddress,frames) } }
            return (got,left,right)
        }
        let source=(0..<100).map { Float($0)/100 }
        for _ in 0..<2 {
            require(write(source)==100,"ring.write")
            require(rs_ring_available(ring)==100,"ring.available")
            let got=read(100)
            require(got.0==100 && got.1==source && got.2==source.map { -$0 },"ring.wrap-order")
        }
        require(rs_ring_dropped_frames(ring)==0,"ring.clean-drop-count")
        require(write(Array(repeating:1,count:128))==128,"ring.fill")
        require(write(Array(repeating:0.5,count:64))==0,"ring.capture-overflow-policy")
        require(rs_ring_dropped_frames(ring)==64,"ring.capture-drop-count")
        let full=read(128)
        require(full.0==128 && full.1.allSatisfy { $0==1 } && full.2.allSatisfy { $0 == -1 },"ring.consumer-not-overwritten")
        require(write(Array(repeating:0.25,count:10))==10,"ring.short-write")
        let few=read(20)
        require(few.0==10 && few.1==Array(repeating:0.25,count:10)+Array(repeating:0,count:10) && few.2==Array(repeating:-0.25,count:10)+Array(repeating:0,count:10),"ring.underrun-fill")
        require(write(source)==100,"ring.discard-setup")
        require(rs_ring_discard(ring,5)==5 && rs_ring_available(ring)==95,"ring.consumer-discard")
        let tail=read(95)
        require(tail.1==Array(source.dropFirst(5)),"ring.discard-oldest")
        require(write(source)==100,"ring.overask-setup")
        require(rs_ring_discard(ring,1000)==100 && rs_ring_available(ring)==0,"ring.discard-bounds")
        require(rs_ring_discard(ring,10)==0,"ring.empty-discard")
        require(write(Array(repeating:0.25,count:300))==0 && rs_ring_available(ring)==0,"ring.oversize-capture-policy")
        require(rs_ring_dropped_frames(ring)==364,"ring.oversize-drop-count")
        // Capture wrap/discard and receive/playout retention have different thread ownership.
        // The actual worker-owned playout queue supplies the oldest-trim and underrun counters.
        let capacity=PlayoutQueue.maximumBufferedMs*PlayoutQueue.rate/1000
        func queue(_ target:Int=0,_ smoothness:Int=10) -> PlayoutQueue {
            PlayoutQueue(jitterMs:target,packetFrames:233,now:0,smoothness:smoothness,artifact:.click)
        }
        let q=queue()
        let stereo=source.flatMap { [$0,-$0] }
        for _ in 0..<3 {
            q.append(stereo)
            require(q.queuedFrames==100,"playout.buffered-count")
            require(q.read(100,now:0,keepsInTime:false)==stereo,"playout.compaction-order")
        }
        require(q.overflows==0 && q.overflowDroppedFrames==0 && q.underrunsTotal==0,"playout.clean-counters")
        q.append(Array(repeating:0.25,count:capacity*2))
        q.append(Array(repeating:-0.5,count:64*2))
        require(q.queuedFrames==capacity,"playout.capacity-bound")
        require(q.overflows==1 && q.overflowDroppedFrames==64,"playout.overflow-count")
        let expected=Array(repeating:Float(0.25),count:(capacity-64)*2)+Array(repeating:Float(-0.5),count:64*2)
        require(q.read(capacity,now:0,keepsInTime:false)==expected,"playout.overflow-newest-order")
        q.append(Array(repeating:0.25,count:10*2))
        let partial=q.read(20,now:0,keepsInTime:false)
        require(partial==Array(repeating:Float(0.25),count:20)+Array(repeating:Float(0),count:20),"playout.underrun-silence")
        require(q.queuedFrames==0 && q.underrunsTotal==1,"playout.underrun-once")
        require(q.takeUnderruns()==1 && q.takeUnderruns()==0,"playout.interval-underruns")
        let oversized=(0..<capacity+17).flatMap { i in [Float(i%97)/100,-Float(i%97)/100] }
        q.append(oversized)
        require(q.queuedFrames==capacity,"playout.oversize-bound")
        require(q.overflowDroppedFrames==81 && q.overflows==2,"playout.oversize-count")
        require(q.read(capacity,now:0,keepsInTime:false)==Array(oversized.suffix(capacity*2)),"playout.oversize-newest-order")
        let filled=queue()
        filled.append(Array(repeating:0.25,count:capacity*2))
        filled.appendConcealment(Array(repeating:-0.5,count:20*2))
        require(filled.queuedFrames==capacity && filled.overflowDroppedFrames==20,"playout.fill-capacity")
        require(filled.read(capacity,now:0,keepsInTime:false)==Array(repeating:Float(0.25),count:(capacity-20)*2)+Array(repeating:Float(-0.5),count:40),"playout.fill-newest-order")
        let trimmed=queue(10,3)
        for part in 0..<42 { trimmed.append(Array(repeating:part<34 ? 0.25 : -0.5,count:233*2)) }
        let destination=PlayoutQueue.trimDestinationFrames(targetMs:10,packetFrames:233)
        let got=trimmed.read(240,now:0,keepsInTime:false)
        require(trimmed.trimmedFrames==42*233-destination && trimmed.trims==1,"playout.oldest-trim-count")
        require(trimmed.queuedFrames==destination-240 && got.allSatisfy { $0 == -0.5 },"playout.oldest-trim-content")
        require(trimmed.overflowDroppedFrames==0 && trimmed.underrunsTotal==0,"playout.cause-counters-separate")
        let lowered=queue(4)
        lowered.append(Array(repeating:0.25,count:100*2))
        lowered.setJitterMs(2,byHand:true,keepsInTime:false)
        require(lowered.skippedFrames>0 && lowered.skippedFrames<=7,"playout.consumer-skip-count")
        require(lowered.queuedFrames+lowered.skippedFrames==100,"playout.consumer-skip-exact")
        let remaining=lowered.queuedFrames
        require(lowered.read(remaining,now:0,keepsInTime:false).allSatisfy { abs($0-0.25)<0.000001 },"playout.consumer-skip-content")
        return .init(name:ringIntegrity,status:failures.isEmpty ? "PASS" : "FAIL",assertions:count,failures:failures)
    }
}
