import Foundation
import RemSoundJam

/// One run of the Mac simulator: who sends what over which network into the Mac, at what buffer.
///
/// What is real - the Mac app's own code, from RemSoundJam: the stream's order (StreamOrder), its receive buffer
/// (PlayoutQueue: the start, keeping in time with the sender's clock, moving the target by hand or by the auto-tune,
/// the descent and snap, the click-trim, the 400 ms cap), the auto-tune (ReceiveAutoTune, the app's own), the session's mix timing
/// (a 1 ms timer that mixes every block that is due, at most four at a time, skipping lateness beyond four mix periods), and
/// each output card's clock keeper (OutputClock: measured cushion, bounded ring and resampling onto the card's clock). What is
/// simulated: the sending machine (a sound card on its own clock sending a packet a callback, cut at 233 frames, as the
/// Windows app sends PCM), the network, and the Mac's output card. The codec is not simulated: packets carry the sound as
/// it was, and a lost packet is a gap (as PCM's is; Opus would fill it in).
public struct MacScenario {
    public var name: String
    public var network: SimNetwork = .wired
    /// The receive buffer (jitter target) in ms.
    public var bufferMs = 20
    public var smoothness = BufferSmoothness.defaultLevel
    public var artifact = ConcealmentArtifact.defaultChoice
    public var seconds = 10.0
    /// The sender's capture card (10 ms blocks, as a Windows WASAPI capture, unless given).
    public var sendCard = SimCard(frames: 480, jitterMs: 1)
    /// Frames a packet; nil: the Windows app's PCM, a packet a callback cut at 233 frames.
    public var packetFrames: Int?
    /// The Mac's output card (512 frames, Andre's devices).
    public var receiveCard = SimCard(frames: 512, jitterMs: 0.2)
    /// The Mac's mix block: 240 frames, or 96 while playing Jamulus-style.
    public var mixFrames = 240
    /// How late the session's 1 ms timer can fire (ms).
    public var mixTickJitterMs = 1.5
    /// The session's timer stops once, from this second for this long (the Mac busy, or the app napping).
    public var mixStallAtSec = 0.0, mixStallMs = 0.0
    /// Jamming > Keep in Time with Other Sound Cards.
    public var keepsInTime = true
    /// The output card's clock keeper (PlaybackFanout for real cards); off, the mix is written straight to the card.
    public var outputClock = true
    public var autoTune = false
    public var autoTuneIntervalSec = 5
    /// The lowest-delay auto-tune, accepting a rare dropout, instead of the usual one.
    public var lowestDelay = false
    /// The buffer changed at a moment: by hand (the menu) or not (as the auto-tune does).
    public var bufferMoves: [(at: Double, ms: Int, byHand: Bool)] = []
    /// The music-like signal on the left in place of the tone.
    public var music = false
    public var delayClicks = true
    /// A click planted in the left channel at the sender, at this second (0: none).
    public var plantClickAtSecond = 0.0
    public var analyseFromSecond = 0.0
    /// The sender starts again at this second: its sequence numbers go back to 1 (0: never).
    public var senderRestartAtSecond = 0.0
    public var seed: UInt64 = 1
    public var keepAudio = false
    /// Keep the receiver's own network recording (the last minute), as the app's Save the Last Minute of the Network.
    public var recordNetwork = false
    /// Note the receive buffer's depth this often (seconds; 0: once a second only).
    public var traceEverySec = 0.0

    public init(_ name: String) { self.name = name }
}

/// What came out of one run.
public struct MacResult {
    public let scenario: MacScenario
    public let findings: SimAnalysis.Findings
    public let music: SimMusic.Findings?
    public let packetsSent: Int, packetsLost: Int, lateDropped: Int
    public let concealed: Int, gapsNotRepaired: Int, codecFailures: Int
    public let nativeCodec: Bool
    public let nativeDecodedFrames: UInt64
    /// The receive buffer: times it ran dry, the trim's cuts (times, ms), the hand-lowered skips (ms), the snaps (times,
    /// ms), times the 400 ms cap discarded oldest audio.
    public let underruns: Int, trims: Int, trimmedMs: Double, skippedMs: Double, snaps: Int, snappedMs: Double, overflows: Int
    /// The output card: times it found its queue empty, and its clock keeper's figures.
    public let cardShortReads: Int, cardRanDry: Int, cushionFrames: Int, cardCutFrames: Int, cardLaidFrames: Int
    /// Each second: the receive buffer's depth (ms), the sender's clock as measured (ppm, nil while measuring), the target.
    public let depthMsBySecond: [Double], clockPpmBySecond: [Double?], targetMsBySecond: [Int]
    /// With the auto-tune: its moves ("20>25@12s").
    public let tunerMoves: [String]
    public let finalTargetMs: Int
    public let audio: [Float]?
    public let recording: NetworkRecording?
    /// Lines the receive buffer logged (snaps, hand-lowered skips).
    public let events: [String]
    /// With traceEverySec: (time, depth ms, playing).
    public let trace: [(t: Double, depthMs: Double, playing: Bool)]

    public var describe: String {
        "\(scenario.name): \(findings.describe); \(underruns) underrun(s), \(trims) trim(s), \(snaps) snap(s), "
            + "\(cardShortReads) short card read(s); \(packetsLost) of \(packetsSent) lost, \(lateDropped) late"
            + (music.map { "; music: \($0.describe)" } ?? "")
            + (tunerMoves.isEmpty ? "" : "; tuner: " + tunerMoves.joined(separator: " "))
    }
}

/// An output card's queue (the playback ring the clock keeper feeds).
final class SimRing: OutputQueue {
    private var samples: [Float] = []
    private var offset = 0
    private(set) var writtenFrames = 0
    var pullTotals: (frames: UInt64, count: UInt64)? = (0, 0)
    var available: Int { (samples.count - offset) / 2 }
    func write(_ s: [Float]) {
        if offset > 1 << 16 {
            samples.removeFirst(offset)
            offset = 0
        }
        let accepted = s.count / 2 <= OutputClock.maximumQueueFrames - available ? s.count / 2 : 0
        samples.append(contentsOf: s.prefix(accepted * 2))
        writtenFrames += accepted
    }
    @discardableResult func discard(_ frames: Int) -> Int {
        let n = min(frames, available)
        offset += n * 2
        return n
    }
    func read(_ frames: Int) -> (samples: [Float], short: Bool) {
        if frames > 0 {
            pullTotals!.frames += UInt64(frames)
            pullTotals!.count += 1
        }
        let n = min(frames, available)
        var out = Array(samples[offset..<(offset + n * 2)])
        offset += n * 2
        if n < frames { out += [Float](repeating: 0, count: (frames - n) * 2) }
        return (out, n < frames)
    }
}

public enum MacSimulation {
    /// Events in time order (ties in the order they were scheduled).
    struct Queue {
        private var heap: [(t: Double, n: Int, a: () -> Void)] = []
        private var count = 0
        var isEmpty: Bool { heap.isEmpty }
        mutating func add(_ t: Double, _ a: @escaping () -> Void) {
            count += 1
            heap.append((t, count, a))
            var i = heap.count - 1
            while i > 0 {
                let p = (i - 1) / 2
                if before(heap[i], heap[p]) { heap.swapAt(i, p); i = p } else { break }
            }
        }
        private func before(_ a: (t: Double, n: Int, a: () -> Void), _ b: (t: Double, n: Int, a: () -> Void)) -> Bool {
            a.t < b.t || (a.t == b.t && a.n < b.n)
        }
        mutating func pop() -> (t: Double, a: () -> Void) {
            let top = heap[0]
            heap[0] = heap[heap.count - 1]
            heap.removeLast()
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < heap.count && before(heap[l], heap[m]) { m = l }
                if r < heap.count && before(heap[r], heap[m]) { m = r }
                if m == i { break }
                heap.swapAt(i, m)
                i = m
            }
            return (top.t, top.a)
        }
    }

    private struct CodecPath {
        let custom: Bool
        let queue: PlayoutQueue
        let encode: (UInt32, [Float]) -> Data?
        let receive: (UInt32, Data, Double) -> Void
        let totals: () -> (late: Int, concealed: Int, unrepaired: Int, decoded: UInt64)
    }
    // Only Core supplies the actual codec/receiver. The event loop, packet fates,
    // mixer, output model and production queue below remain one implementation.
    @_spi(NativeReplay) public static func run(_ s: MacScenario, queue: PlayoutQueue, custom: Bool = false,
        encode: @escaping (UInt32, [Float]) -> Data?, receive: @escaping (UInt32, Data, Double) -> Void,
        totals: @escaping () -> (late: Int, concealed: Int, unrepaired: Int, decoded: UInt64)) -> MacResult {
        run(s, codec: .init(custom: custom, queue: queue, encode: encode, receive: receive, totals: totals))
    }
    public static func run(_ s: MacScenario) -> MacResult { run(s, codec: nil) }
    private static func run(_ s: MacScenario, codec: CodecPath?) -> MacResult {
        var random = SimRandom(seed: s.seed)
        var events = Queue()
        let rate = Double(SimAnalysis.rate)
        let sendRate = s.sendCard.rate
        let packetFrames = s.packetFrames ?? min(s.sendCard.frames, 233)
        let streamId: UInt16 = 7

        // ---- the receiving Mac ----
        let queue = codec?.queue ?? PlayoutQueue(jitterMs: s.bufferMs, packetFrames: packetFrames, now: 0, smoothness: s.smoothness, artifact: s.artifact, concealmentSeed: s.seed)
        var log: [String] = []
        queue.onEvent = { log.append($0) }
        var order = StreamOrder()
        var lateDropped = 0, codecFailures = 0
        var recorder = NetworkRecorder()
        recorder.enabled = s.recordNetwork
        var audibleGaps = 0
        var tuner = ReceiveAutoTune()
        tuner.restart()
        var tunerMoves: [String] = []

        func arrive(sequence: UInt32, frames: [Float], encoded: Data?, at now: Double) {
            tuner.noteArrival(stream: "\(streamId)", now: now)
            recorder.note(from: "10.77.0.1:50123", streamId: streamId, sequence: sequence, bytes: encoded?.count ?? (frames.count * 3 + 34), now: now)
            if let codec, let encoded {
                codec.receive(sequence, encoded, now)
                lateDropped = codec.totals().late
                return
            }
            let admit = order.admit(sequence)
            switch admit {
            case .late:
                lateDropped += 1
                return
            case .restart:
                queue.reset(now: now)
                order.reset()
            case .next:
                break
            }
            queue.append(frames)
            let packets = order.packets(upTo: sequence)
            if packets > 0 && packets <= 1000 { queue.produced(packets * (frames.count / 2), now: now) }
            order.took(sequence)
        }

        // ---- the sender: a card on its own clock, a packet a callback cut at packetFrames ----
        var captured = 0
        let plantAt = s.plantClickAtSecond > 0 ? Int(s.plantClickAtSecond * rate) : -1
        func signal(_ frames: Int) -> [Float] {
            var block = [Float](repeating: 0, count: frames * 2)
            for i in 0..<frames {
                let n = captured + i
                let t = Double(n) / rate
                block[2 * i] = s.music ? SimMusic.sample(t) : SimAnalysis.toneLevel * Float(sin(2 * Double.pi * SimAnalysis.toneHz * t))
                if n == plantAt { block[2 * i] += 0.5 }
                block[2 * i + 1] = s.delayClicks && n % Int(SimAnalysis.clickEverySec * rate) == 0 ? SimAnalysis.clickLevel : 0
            }
            captured += frames
            return block
        }
        var sequence: UInt32 = 0
        var sent = 0
        var path = SimPath(s.network)
        var pending: [Float] = []
        let ownPeriod = Double(packetFrames) / rate
        var restarted = false
        for t in s.sendCard.callbacks(seconds: s.seconds, random: &random) {
            events.add(t) {
                if s.senderRestartAtSecond > 0, !restarted, t >= s.senderRestartAtSecond {
                    restarted = true
                    sequence = 0
                }
                pending += signal(s.sendCard.frames)
                while pending.count >= packetFrames * 2 {
                    let packet = Array(pending[0..<(packetFrames * 2)])
                    pending.removeFirst(packetFrames * 2)
                    sequence &+= 1
                    sent += 1
                    let number = sequence
                    let encoded = codec?.encode(number, packet)
                    if codec != nil && encoded == nil { codecFailures += 1; continue }
                    for at in path.arrivals(stream: streamId, sequence: number, now: t, ownPeriod: ownPeriod, random: &random) {
                        events.add(at) { arrive(sequence: number, frames: packet, encoded: encoded, at: at) }
                    }
                }
            }
        }

        // ---- the Mac's session: a 1 ms timer, mixing every block that is due ----
        let ring = SimRing()
        var outputClock = OutputClock()
        outputClock.cardFrames = s.receiveCard.frames
        var nextMix = 0.0
        var nextAutoTune = Double(s.autoTuneIntervalSec)
        let mixPeriod = Double(s.mixFrames) / rate
        var tick = 0.001
        while tick < s.seconds {
            let late = s.mixTickJitterMs > 0 ? random.unit() * s.mixTickJitterMs / 1000 : 0
            let at = tick + late
            if s.mixStallMs > 0, at >= s.mixStallAtSec, at < s.mixStallAtSec + s.mixStallMs / 1000 {
                tick += 0.001
                continue
            }
            events.add(at) {
                if at - nextMix > mixPeriod * Double(OutputClock.maximumCatchupBlocks) { nextMix = at }
                var work = 0
                while at >= nextMix && work < OutputClock.maximumCatchupBlocks {
                    let before = queue.underrunsTotal
                    let block = queue.read(s.mixFrames, now: at, keepsInTime: s.keepsInTime)
                    if queue.underrunsTotal > before { audibleGaps += 1 }
                    tuner.noteMix(now: at)
                    if queue.hasAudio { tuner.noteBuffer(ms: Double(queue.queuedFrames) * 1000 / rate) }
                    if s.outputClock && s.keepsInTime { outputClock.write(block, to: ring, now: at) } else { ring.write(block) }
                    nextMix += mixPeriod
                    work += 1
                }
                if s.autoTune, !s.lowestDelay, at >= nextAutoTune {
                    nextAutoTune = at + Double(s.autoTuneIntervalSec)
                    let frameMs = Int((Double(packetFrames) * 1000 / rate).rounded(.up))
                    if let change = tuner.tick(currentMs: queue.jitterMs, underruns: queue.takeUnderruns(),
                                               hasAudio: queue.hasAudio, frameMs: frameMs).change {
                        tunerMoves.append("\(queue.jitterMs)>\(change.targetMs)@\(Int(at))s")
                        queue.setJitterMs(change.targetMs, byHand: false, keepsInTime: s.keepsInTime)
                    }
                }
            }
            tick += 0.001
        }
        for move in s.bufferMoves {
            events.add(move.at) {
                queue.setJitterMs(move.ms, byHand: move.byHand, keepsInTime: s.keepsInTime)
                if move.byHand { tuner.youSetIt(now: move.at) }
            }
        }

        // ---- the Mac's output card, and what it plays ----
        var heard: [Float] = []
        heard.reserveCapacity(Int(s.seconds * rate) * 2 + 4096)
        var times: [(frame: Int, time: Double)] = []
        var shortReads = 0
        for t in s.receiveCard.callbacks(seconds: s.seconds, random: &random) {
            events.add(t) {
                let (block, short) = ring.read(s.receiveCard.frames)
                if short && ring.writtenFrames > 0 { shortReads += 1 }
                times.append((heard.count / 2, t))
                heard += block
            }
        }

        // ---- each second, and the network recorder's counts ----
        var depths: [Double] = [], ppms: [Double?] = [], targets: [Int] = []
        for second in 1...max(1, Int(s.seconds)) {
            events.add(Double(second)) {
                tuner.endSecond()
                if s.autoTune, s.lowestDelay,
                   let change = tuner.lowestDelaySecond(audibleGapsTotal: audibleGaps, currentMs: queue.jitterMs,
                       floorMs: Int((Double(s.mixFrames) * 1000 / rate).rounded(.up)), on: true, now: Double(second)) {
                    tunerMoves.append("\(queue.jitterMs)>\(change.targetMs)@\(second)s")
                    queue.setJitterMs(change.targetMs, byHand: false, keepsInTime: s.keepsInTime)
                }
                depths.append(Double(queue.queuedFrames) * 1000 / rate)
                ppms.append(queue.clockPpm)
                targets.append(queue.jitterMs)
                recorder.noteSecond(.init(at: Double(second), audibleGaps: audibleGaps, lateOrDoubledDropped: lateDropped,
                                          concealed: codec?.totals().concealed ?? 0, gapsNotRepaired: codec?.totals().unrepaired ?? 0))
            }
        }

        var trace: [(t: Double, depthMs: Double, playing: Bool)] = []
        if s.traceEverySec > 0 {
            var t = s.traceEverySec
            while t < s.seconds {
                let at = t
                events.add(at) { trace.append((at, Double(queue.queuedFrames) * 1000 / rate, queue.playing)) }
                t += s.traceEverySec
            }
        }
        while !events.isEmpty {
            let e = events.pop()
            e.a()
        }

        let from = Int(s.analyseFromSecond * rate)
        let listened = from <= 0 ? heard : Array(heard.dropFirst(from * 2))
        let listenedTimes = from <= 0 ? times : times.filter { $0.frame >= from }.map { ($0.frame - from, $0.time) }
        let findings = SimAnalysis.analyse(listened, listenedTimes, sendRate: sendRate, expectedToneRatio: sendRate / s.receiveCard.rate)
        let music = s.music ? SimMusic.analyse(listened, listenedTimes, sendRate: sendRate) : nil
        let recording = s.recordNetwork ? recorder.take(facts: [
            .init("machine", "Mac simulator"), .init("buffer ms", String(s.bufferMs)), .init("network", s.network.name),
        ]) { _, _ in .init(lane: "Mixed", format: codec == nil ? "PCM 24-bit" : (codec?.custom == true ? "Opus custom" : "Opus"), codec: codec == nil ? 1 : (codec?.custom == true ? 3 : 2), frameSamples: packetFrames) } : nil
        return MacResult(
            scenario: s, findings: findings, music: music, packetsSent: sent, packetsLost: path.lost, lateDropped: lateDropped,
            concealed: codec?.totals().concealed ?? 0, gapsNotRepaired: codec?.totals().unrepaired ?? 0, codecFailures: codecFailures, nativeCodec: codec != nil, nativeDecodedFrames: codec?.totals().decoded ?? 0,
            underruns: queue.underrunsTotal, trims: queue.trims, trimmedMs: Double(queue.trimmedFrames) * 1000 / rate,
            skippedMs: Double(queue.skippedFrames) * 1000 / rate, snaps: queue.snaps, snappedMs: Double(queue.snappedFrames) * 1000 / rate,
            overflows: queue.overflows, cardShortReads: shortReads, cardRanDry: outputClock.ranDry,
            cushionFrames: outputClock.cushionFrames, cardCutFrames: outputClock.cutFrames, cardLaidFrames: outputClock.laidFrames,
            depthMsBySecond: depths, clockPpmBySecond: ppms, targetMsBySecond: targets, tunerMoves: tunerMoves,
            finalTargetMs: queue.jitterMs, audio: s.keepAudio ? heard : nil, recording: recording, events: log, trace: trace)
    }
}

/// Does the simulator hear what a real receiver heard? (Windows' SIMULATOR CALIBRATION.) A recording carries its own
/// receiver's counts for that minute; replayed as it was made, the simulated receiver's must agree - per minute, within
/// 3 or half of the larger.
public enum MacCalibration {
    public static let floorPerMinute = 3.0
    public static let share = 0.5

    public struct Verdict {
        public let live: Double, simulated: Double, perMinuteLive: Double, perMinuteSimulated: Double
        public var agrees: Bool {
            abs(perMinuteLive - perMinuteSimulated) <= max(MacCalibration.floorPerMinute, MacCalibration.share * max(perMinuteLive, perMinuteSimulated))
        }
        public var describe: String {
            String(format: "audible gaps: %.0f live, %.0f simulated (%.1f and %.1f a minute) - %@", live, simulated,
                   perMinuteLive, perMinuteSimulated, agrees ? "agree" : "DISAGREE")
        }
    }

    /// nil when the recording carries no live figures to judge by.
    public static func judge(_ rec: NetworkRecording, simulatedGaps: Int) -> Verdict? {
        guard let seconds = rec.fact("live seconds").flatMap(Double.init), seconds > 0,
              let gaps = rec.fact("live audible gaps").flatMap(Double.init) else { return nil }
        return Verdict(live: gaps, simulated: Double(simulatedGaps), perMinuteLive: gaps * 60 / seconds,
                       perMinuteSimulated: Double(simulatedGaps) * 60 / seconds)
    }
}
