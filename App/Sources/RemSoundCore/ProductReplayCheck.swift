import Foundation
import RemSoundJam
import RemSoundSim
import AudioSupport

extension ProductTestPack {
    static let simulatorReplay = "SIMULATOR REPLAY: a recorded network plays back packet for packet, and a hand-made minute's stall, loss, overtaking and doubling are each met where they were made"
    static func checkSimulatorReplay() -> Step {
        var assertions = 0, failures: [String] = []
        func require(_ value: Bool, _ code: String) { assertions += 1; if !value { failures.append(code) } }
        do {
            var recording = NetworkRecording()
            recording.streams = [.init(index: 0, from: "10.0.0.9:50000", streamId: 7,
                lane: "Mixed", format: "product fixture", codec: 1, frameSamples: 120)]
            recording.facts = [.init("buffer ms", "15")]
            for n in 0..<4000 where n != 2000 {
                let sent = Double(n) * 2.5
                var at = sent + 5
                if sent >= 3000 && sent < 3120 { at = 3125 }
                if n == 2800 { at += 4 }
                recording.packets.append(.init(ms: at, stream: 0, sequence: UInt32(n + 1000), bytes: 60))
                if n == 3200 { recording.packets.append(.init(ms: at + 0.5, stream: 0, sequence: UInt32(n + 1000), bytes: 60)) }
            }
            recording.packets.sort { $0.ms < $1.ms }
            let read = try NetworkRecording.read(recording.text())
            require(read == recording, "replay.file-roundtrip")
            let replay = try NetworkReplay.from(read)
            require(replay.places == 4000, "replay.sequence-places")
            require(replay.lost == 1, "replay.one-loss")
            require(replay.doubled == 1, "replay.one-double")
            require(abs(replay.period - 0.0025) < 0.000001, "replay.own-period")
            var arrivals: [Int: [Double]] = [:]
            for n in 0..<4000 {
                arrivals[n] = replay.arrivals(stream: 7, sequence: UInt32(n), sentAt: Double(n) * 0.0025,
                    oneWay: 0.005, ownPeriod: 0.0025)
            }
            require(arrivals[2000]?.isEmpty == true, "replay.loss-never-arrives")
            require(arrivals[3200]?.count == 2, "replay.duplicate-arrives-twice")
            require(abs((arrivals[1200]?.first ?? 0) - 3.125) < 0.000002, "replay.stall-where-recorded")
            require((arrivals[2800]?.first ?? 0) > (arrivals[2801]?.first ?? 0), "replay.overtaken-order-preserved")
            let fresh = replay.fresh()
            require(fresh.arrivals(stream: 7, sequence: 0, sentAt: 0, oneWay: 0.005, ownPeriod: 0.0025) == arrivals[0], "replay.fresh-independent-state")
            let date = Date(timeIntervalSince1970: 0)
            let one = try ReplaySimulation.run(read.text(), seconds: 0.25, oneWayMs: 5, date: date)
            let two = try ReplaySimulation.run(read.text(), seconds: 0.25, oneWayMs: 5, date: date)
            require(one == two, "replay.actual-model-deterministic")
            require(one.packetsSent > 0 && one.packetFrames == 120, "replay.actual-production-receive-path")
            require(one.lost == 1 && one.doubled == 1, "replay.report-fates")
            require(one.lateDropped > 0, "replay.actual-receiver-refuses-late-duplicates")
            require(one.underruns > 0, "replay.actual-receiver-meets-stall")
            require(one.unverified.contains(where: { $0.contains("codec") }), "replay.pure-model-codec-gap-not-hidden")
            let native=try NativeReplaySimulation.run(opusRecording(read).text(),seconds:0.25,oneWayMs:5,date:date)
            let repeated=try NativeReplaySimulation.run(opusRecording(read).text(),seconds:0.25,oneWayMs:5,date:date)
            require(native.nativeCodec && native.nativeDecodedFrames>0 && native.scope=="offline-native-Opus-and-Mac-receive", "replay.actual-native-codec")
            require(native==repeated,"replay.native-deterministic")
            require(native.lost==1 && native.doubled==1,"replay.native-fates")
            require(native.lateDropped>0 && native.concealed>0,"replay.native-late-and-single-loss")
            require(native.packetsLost==1 && native.packetsSent>0,"replay.native-wire-packets")
            require(native.unverified.contains(where: { $0.contains("comparison") }),"replay.native-sweep-gap-not-hidden")
            var short = NetworkRecording()
            short.streams = recording.streams
            short.facts = [.init("buffer ms", "15")]
            short.packets = (0..<80).filter { $0 != 20 }.map {
                .init(ms: Double($0) * 2.5 + 5, stream: 0, sequence: UInt32($0), bytes: 60)
            }
            short.packets.append(.init(ms: 155.5, stream: 0, sequence: 60, bytes: 60))
            short.packets.sort { $0.ms < $1.ms }
            let comparison = try NativeReplaySimulation.compare(short.text(), seconds: 0.25, oneWayMs: 5, date: date)
            let comparisonAgain = try NativeReplaySimulation.compare(short.text(), seconds: 0.25, oneWayMs: 5, date: date)
            let rows = comparison.comparisons
            require(rows.count == 18, "replay.fixed-comparison-count")
            require(rows.map(\.packetFrames) == Array(repeating: 64, count: 6) + Array(repeating: 120, count: 6) + Array(repeating: 480, count: 6)
                && rows.map(\.bufferMs) == [5,8,10,15,20,30,5,8,10,15,20,30,5,8,10,15,20,30], "replay.fixed-reference-targets")
            require(rows.allSatisfy { $0.nativeDecodedFrames > 0 && $0.codec == ($0.packetFrames == 64 ? "custom-opus-celt" : "ordinary-opus-lowdelay") && $0.encoderBitrate == 320000 }, "replay.comparison-real-codecs")
            require(rows.allSatisfy { $0.seed == 1 && $0.seconds == 0.25 }, "replay.comparison-clock-seed")
            require(comparison.recordedCodec == 1 && comparison.recordedFrameSamples == 120 && comparison.bufferMs == 15 && !comparison.nativeCodec
                && comparison.unverified.contains("recorded codec uses pure receive model"), "replay.recorded-descriptor-preserved")
            require(rows.prefix(6).allSatisfy { $0.packetsSent == rows[0].packetsSent && $0.packetsLost > 0 }
                && rows.dropFirst(6).prefix(6).allSatisfy { $0.packetsSent == rows[6].packetsSent && $0.packetsLost > 0 }
                && rows.suffix(6).allSatisfy { $0.packetsSent == rows[12].packetsSent && $0.packetsLost > 0 }
                && rows[0].packetsSent > rows[6].packetsSent && rows[6].packetsSent > rows[12].packetsSent, "replay.target-period-fates")
            require(comparison == comparisonAgain, "replay.comparisons-fresh-deterministic")
            require(comparison.unverified.contains("complete reference sweeps and other codec modes"), "replay.remaining-sweep-gap-not-hidden")
            let comparisonData = try JSONEncoder().encode(comparison)
            require(comparisonData.count < 16384 && !String(decoding: comparisonData, as: UTF8.self).contains("10.0.0.9"), "replay.comparison-bounded-private-report")
            let custom = try customReplayWaveform()
            require(custom.native, "replay.custom-native-frames")
            require(custom.finite, "replay.custom-finite-output")
            require(custom.tone, "replay.custom-known-tone")
            require(custom.stereo, "replay.custom-right-remains-quiet")
            require(custom.wire, "replay.custom-recorder-tag-and-cbr-wire")
            require(custom.deterministic, "replay.custom-output-deterministic")
            require(custom.released, "replay.custom-source-released")
            let custom128 = try customReplayWaveform(frames: 128)
            require(custom128.native, "replay.custom128-native-frames")
            require(custom128.finite, "replay.custom128-finite-output")
            require(custom128.tone, "replay.custom128-known-tone")
            require(custom128.stereo, "replay.custom128-right-remains-quiet")
            require(custom128.wire, "replay.custom128-recorder-tag-and-cbr-wire")
            require(custom128.deterministic, "replay.custom128-output-deterministic")
            require(custom128.released, "replay.custom128-source-released")
            let roundTrip = try nativeReplayRoundTrip()
            require(roundTrip.textRoundTrip, "replay.receiver-recording-text-roundtrip")
            require(roundTrip.nativeFormat, "replay.receiver-recording-native-format")
            require(roundTrip.framePeriod, "replay.receiver-recording-period")
            require(roundTrip.recordedFates, "replay.receiver-recording-fates")
            require(roundTrip.packetSet, "replay.receiver-replayed-packet-set")
            require(roundTrip.packetOrder, "replay.receiver-replayed-packet-order")
            require(roundTrip.worstArrivalErrorMs < 0.002, "replay.receiver-replayed-two-microsecond-times")
            require(roundTrip.delayDifferenceMs < 1, "replay.receiver-replayed-output-delay")
            require(roundTrip.sameGlitches, "replay.receiver-replayed-glitches")
            require(roundTrip.sameLate, "replay.receiver-replayed-late")
            require(roundTrip.sameUnderruns, "replay.receiver-replayed-underruns")
            require(roundTrip.sameConcealment, "replay.receiver-replayed-concealment")
            require(roundTrip.sameUnrepaired, "replay.receiver-replayed-unrepaired")
            require(roundTrip.finiteOutput, "replay.receiver-replayed-audible-finite-output")
            require(roundTrip.sourceReleased, "replay.receiver-replayed-source-release")
            require(roundTrip.originalReorderWaits > 0, "replay.receiver-original-observed-waits")
            require(roundTrip.replayedReorderWaits == roundTrip.originalReorderWaits, "replay.receiver-replayed-waits")
            let handmade = try nativeReplayHandmade()
            require(handmade.native, "replay.handmade-native-output")
            require(handmade.stall, "replay.handmade-stall-time")
            require(handmade.loss, "replay.handmade-lost-packet")
            require(handmade.late, "replay.handmade-late-refusal")
            require(handmade.order, "replay.handmade-receiver-order")
            require(handmade.ties, "replay.handmade-stall-ties")
            require(handmade.waits > 0, "replay.handmade-observed-reorder-wait")
            let selection = try nativeReplaySelection()
            require(selection.defaultStream, "replay.default-most-packets-native-source")
            require(selection.explicitStream, "replay.explicit-native-source")
            require(selection.places, "replay.selected-source-fates")
            require(selection.invalidRefused, "replay.unknown-source-refused")
            let fec=try nativeReplayFEC()
            require(fec.genuine,"replay.genuine-fec-not-plc")
            require(fec.repaired==1,"replay.actual-fec-count")
            require(fec.unrepaired==0,"replay.single-loss-no-unrepaired-gap")
            require(fec.exactSamples,"replay.actual-fec-samples-on-output")
            require(fec.deterministic,"replay.fec-output-deterministic")
        } catch { assertions += 1; failures.append("replay.product-path-error") }
        let status = failures.isEmpty ? "UNVERIFIED" : "FAIL"
        failures.append("full-sweeps-and-driver-calibration-unverified")
        return .init(name: simulatorReplay, status: status, assertions: assertions, failures: failures)
    }
}

extension ProductTestPack {
    private static func opusRecording(_ recording: NetworkRecording) -> NetworkRecording {
        var value=recording
        value.streams[0] = .init(index:0,from:"10.0.0.9:50000",streamId:7,lane:"Mixed",format:"synthetic native Opus",codec:2,frameSamples:120)
        return value
    }
    static func customReplayWaveform(frames: Int = 64) throws -> (native: Bool, finite: Bool, tone: Bool, stereo: Bool, wire: Bool, deterministic: Bool, released: Bool) {
        guard [64, 128].contains(frames) else { throw ReplaySimulation.Failure.invalidRecording }
        var scenario = MacScenario("synthetic custom waveform")
        scenario.seconds = 0.4; scenario.seed = 1; scenario.packetFrames = frames
        scenario.sendCard = SimCard(frames: frames); scenario.receiveCard = SimCard(frames: frames)
        scenario.bufferMs = 5; scenario.mixFrames = 96; scenario.mixTickJitterMs = 0
        scenario.keepsInTime = false; scenario.outputClock = false
        scenario.keepAudio = true; scenario.recordNetwork = true; scenario.delayClicks = false
        weak var source: OpusCustomSender?
        func run() throws -> MacResult {
            guard let sender = OpusCustomSender(frames: frames) else { throw ReplaySimulation.Failure.invalidRecording }
            source = sender
            return try NativeReplaySimulation.runNative(scenario, frames: frames, channels: 2, codec: .opusCustom, encode: sender.encode)
        }
        let one = try run(), firstReleased = source == nil, two = try run()
        guard let audio = one.audio, audio.count >= 4800 * 2 else { throw ReplaySimulation.Failure.invalidRecording }
        let left = stride(from: 4800 * 2, to: audio.count, by: 2).map { Double(audio[$0]) }
        let right = stride(from: 4800 * 2 + 1, to: audio.count, by: 2).map { abs(audio[$0]) }
        let knownToneHz = 1000.0, knownSampleRate = 48000.0
        let referenceCustomPayloadBytes = frames == 64 ? 53 : 85, authenticatedEnvelopeBytes = 28
        var cosine = 0.0, sine = 0.0, power = 0.0
        for (index, sample) in left.enumerated() {
            let angle = 2 * Double.pi * knownToneHz * Double(index) / knownSampleRate
            cosine += sample * cos(angle); sine += sample * sin(angle); power += sample * sample
        }
        let tonePower = 2 * (cosine * cosine + sine * sine) / Double(left.count)
        let wire = one.recording?.streams.first?.codec == 3 && one.recording?.streams.first?.frameSamples == frames
            && one.recording?.packets.isEmpty == false
            && one.recording?.packets.allSatisfy { $0.bytes == referenceCustomPayloadBytes + authenticatedEnvelopeBytes + Wire.headerSize } == true
        return (one.nativeCodec && one.nativeDecodedFrames > 0, audio.allSatisfy(\.isFinite),
            power / Double(left.count) > 0.05 && tonePower / max(power, 0.000001) > 0.9,
            (right.max() ?? 1) < 0.02, wire, one.audio == two.audio, firstReleased && source == nil)
    }
    static func nativeReplayFEC() throws -> (genuine:Bool,repaired:Int,unrepaired:Int,exactSamples:Bool,deterministic:Bool) {
        struct Fixture: Decodable { let frames:Int; let channels:Int; let packets:[String] }
        let data=Data("""
        {"frames":960,"channels":1,"packets":[
        "488288d2344088990ac86877ca20e6ebb5ce2ec77b255cf2c7fa1c961f71cc9d79977e2c6d627b202ddbb8f68476708b8cdb8a548bb7916d529f55689603d4b6420c5e5f2623f40e069e50",
        "48c3cb2602cb23fc06358d37dda06f02409afb1d965d72d7470e1c8902850ac77654860a850b6d834cf78beb7d8f3acaaedfd28de22b54a16d9c",
        "48ede4a87d9a1d8af08dcd3ade69d6699934d28fae1d180963cb8ec46169949176bcbd96df45ea7405b6ea411cb33ee46aea56cd90d36834b332b0",
        "48e51b3710e233742351b44287160aa1c4f122b59f0d79c5e6b3bced357a4594b10804445167131b040c7e1c15a5c217a5bb65d0",
        "48e51b3710e233742351b4b866615500d2a908420960ec7374defcd63a184d5c984744b8881f51fb43aa0b58d93c7fe56287c0",
        "48e51b396687169243f79eb3cb08f7e22a1740140f23160277b7e0f0cd0aaf4e715b34c66ef31ad9b8c468968c76db840c7cfc0a57f174be580a75478408",
        "48e151450c2d0dec368c6229fe8b8cdfa24e8eb633731c02c150377625d3611f2d0001f5486692f37b3a3a96e3a9e8c701b5e162b68ac79d76ef0ee760de5fe4b41e20a06c7323ec0f45a26390f2602fc8f3f2bfae516d2766140136208da0e9c9f312b991a00d78e0",
        "48e15145765b44929055a776cb4acaa4c153983408f15c3cddb3a7831bb5904fe85df24d53c0917e895af8f4d2fdd5035a5a8b3128a17e7236f98b920cc0c1910615a97fdf96489f80e7cb62177f3337",
        "48e7ef60771729c03f631f84dc7ee08c20a449968d6217d9715880179c9dceca9a4d9ee8c8e1ada3d62e2136340400ae99f4f200f57c24a1875bcf3da9d36e8848f8079e5b5f1862cbd67ddfaf88c03596",
        "48e52a2c44361d869158aacc9dc4aa7fec66bd99283012647ec85e0e4d08b1b4f544bb2a1438f7cae113928abac54902ae17fc0655d2517d31f0c3518843127ba985d9fe08",
        "48e7efad07d9fecfb924d8c4e6d8dfb5c770095caa9bd5d438d686916a50e38bb01388dabc93060d313a230bbf9b0a9df475abe4f6f19e9c4eeaa12b7d30d9d5024dc406083641",
        "48e52a2c44361d869152f4cde2f0559810afe3793a53323f2d3b920492ca7be2c042321465a4097355b4c6a7c4ba2faf3037e0278db771a6f4979a30583070f2927aaa7818795f71c73af0"
        ]}
        """.utf8)
        guard data.count<=4096 else { throw ReplaySimulation.Failure.invalidRecording }
        let fixture=try JSONDecoder().decode(Fixture.self,from:data)
        guard fixture.frames==960,fixture.channels==1,fixture.packets.count==12 else { throw ReplaySimulation.Failure.invalidRecording }
        let packets=try fixture.packets.map { hex -> Data in
            guard hex.utf8.count<=2550,hex.utf8.count.isMultiple(of:2) else { throw ReplaySimulation.Failure.invalidRecording }
            let chars=Array(hex);var result=Data()
            for i in stride(from:0,to:chars.count,by:2) {
                guard let byte=UInt8(String(chars[i...i+1]),radix:16) else { throw ReplaySimulation.Failure.invalidRecording };result.append(byte)
            }
            return result
        }
        guard let reference=rs_opus_decoder(1) else { throw ReplaySimulation.Failure.invalidRecording }
        defer { rs_opus_destroy(reference) }
        guard let plc=rs_opus_decoder(1) else { throw ReplaySimulation.Failure.invalidRecording }
        defer { rs_opus_destroy(plc) }
        func decode(_ decoder:UnsafeMutableRawPointer,_ packet:Data?,_ fec:Bool=false) throws -> [Float] {
            var samples=[Float](repeating:0,count:960)
            let n=packet.map { bytes in bytes.withUnsafeBytes { productReplayOpusDecode(decoder,$0.bindMemory(to:UInt8.self).baseAddress,Int32(bytes.count),&samples,960,fec ? 1 : 0) } }
                ?? productReplayOpusDecode(decoder,nil,0,&samples,960,0)
            guard n==960 else { throw ReplaySimulation.Failure.invalidRecording };return samples
        }
        for i in 0..<10 { _=try decode(reference,packets[i]);_=try decode(plc,packets[i]) }
        let expected=try decode(reference,packets[11],true),fallback=try decode(plc,nil)
        let genuine=(zip(expected,fallback).map { abs($0-$1) }.max() ?? 0)>0.01
        var recording=NetworkRecording();recording.streams=[.init(index:0,from:"10.0.0.1:1",streamId:7,lane:"Mixed",format:"synthetic FEC",codec:2,frameSamples:960)]
        recording.packets=(0..<12).filter { $0 != 10 }.map { .init(ms:Double($0)*20+5,stream:0,sequence:UInt32($0),bytes:60) }
        let replay=try NetworkReplay.from(recording)
        func run() throws -> MacResult {
            var scenario=MacScenario("fixed native FEC vector")
            scenario.seconds=0.4;scenario.seed=1;scenario.network = .replaying(replay,oneWayMs:5)
            scenario.packetFrames=960;scenario.bufferMs=2;scenario.smoothness=10
            scenario.sendCard = SimCard(frames:960,stallAtSec:0.241,stallOnceMs:1000)
            scenario.receiveCard = SimCard(frames:960);scenario.mixFrames=960;scenario.mixTickJitterMs=0
            scenario.keepsInTime=false;scenario.outputClock=false;scenario.keepAudio=true
            var index=0
            return try NativeReplaySimulation.runNative(scenario,frames:960,channels:1,encode:{ _ in
                guard index<packets.count else { return nil };defer { index += 1 };return packets[index]
            })
        }
        let one=try run(),two=try run(),heard=one.audio ?? []
        let probe=Array(expected[128..<160]);var exact=false
        if heard.count>=probe.count*2 {
            for frame in 0...(heard.count/2-probe.count) {
                if probe.indices.allSatisfy({ abs(heard[(frame+$0)*2]-probe[$0])<0.0001 && abs(heard[(frame+$0)*2+1]-probe[$0])<0.0001 }) { exact=true;break }
            }
        }
        return (genuine,one.concealed,one.gapsNotRepaired,exact,one.audio==two.audio)
    }
}

// Independent libopus mode oracle; does not call StreamDecoder's FEC wrapper.
@_silgen_name("opus_decode_float")
private func productReplayOpusDecode(_ decoder:UnsafeMutableRawPointer,_ bytes:UnsafePointer<UInt8>?,
    _ length:Int32,_ samples:UnsafeMutablePointer<Float>,_ frames:Int32,_ fec:Int32) -> Int32
