import Foundation
import RemSoundJam

// THE MAC SIMULATOR's world (the Windows RemSound's Simulator/Simulation.cs, ported 2026-09-30): fake sound cards, a
// fake network between the two machines, and a recorded network replayed. Everything happens at simulated moments on
// one thread, so a run is exact, the same every time, and far faster than real time.

/// A dice that gives the same throws for the same seed on every machine (SplitMix64).
public struct SimRandom {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// 0 up to (not including) 1.
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// A fake sound card: its buffer in frames, how late its callbacks can be (ms), how far its clock is off (parts per
/// million, + is fast), and stalls - every N seconds it stops for M ms then catches up (a late driver thread), or once,
/// when the callbacks it missed are gone (a device that stopped and came back). `phaseMs` starts its callbacks later.
public struct SimCard: Equatable {
    public var frames: Int
    public var jitterMs = 0.0
    public var driftPpm = 0.0
    public var stallEverySec = 0.0, stallMs = 0.0
    public var stallAtSec = 0.0, stallOnceMs = 0.0
    public var phaseMs = 0.0
    public init(frames: Int, jitterMs: Double = 0, driftPpm: Double = 0, stallEverySec: Double = 0, stallMs: Double = 0,
                stallAtSec: Double = 0, stallOnceMs: Double = 0, phaseMs: Double = 0) {
        self.frames = frames; self.jitterMs = jitterMs; self.driftPpm = driftPpm
        self.stallEverySec = stallEverySec; self.stallMs = stallMs; self.stallAtSec = stallAtSec
        self.stallOnceMs = stallOnceMs; self.phaseMs = phaseMs
    }
    /// Frames a second, by the true clock.
    public var rate: Double { 48_000 * (1 + driftPpm / 1_000_000) }

    /// Its callbacks up to `seconds` (Windows' ScheduleCard): one a period on its own clock, each up to `jitterMs` late
    /// (never before the one before it); in a recurring stall held back then fired together; in a one-off stall, dropped.
    public func callbacks(seconds: Double, random: inout SimRandom) -> [Double] {
        let period = Double(frames) / rate
        let count = Int(seconds / period)
        var times: [Double] = []
        times.reserveCapacity(count)
        var last = 0.0
        for k in 1...max(1, count) where count > 0 {
            var t = Double(k) * period + phaseMs / 1000 + (jitterMs > 0 ? random.unit() * jitterMs / 1000 : 0)
            if stallOnceMs > 0, t >= stallAtSec, t < stallAtSec + stallOnceMs / 1000 { continue }
            if stallEverySec > 0, stallMs > 0 {
                let into = t.truncatingRemainder(dividingBy: stallEverySec)
                if into >= stallEverySec - stallMs / 1000 { t += stallEverySec - into }
            }
            t = max(t, last)
            last = t
            times.append(t)
        }
        return times
    }
}

/// A fake network (Windows' SimNetwork, with its presets): one-way delay, random extra delay (mean), loss, doubling,
/// delivery in lumps, stalls, reordering, the receiving machine's own late wake-ups, loss in bursts, and a queue on the
/// path that builds and drains. Or a recorded network, replayed.
public struct SimNetwork {
    public var name: String
    public var baseMs: Double
    public var jitterMs = 0.0
    public var lossPercent = 0.0, duplicatePercent = 0.0
    public var lumpMs = 0.0
    public var stallEverySec = 0.0, stallMs = 0.0
    public var reorderPercent = 0.0
    public var hiccupPercent = 0.0, hiccupMs = 0.0
    public var stallAtSec = 0.0, stallOnceMs = 0.0
    public var burstLossPercent = 0.0, burstLossLength = 4.0
    public var queuePeakMs = 0.0, queueEverySec = 5.0, queueRiseMs = 200.0, queueFallMs = 600.0
    public var replay: NetworkReplay?

    public init(_ name: String, baseMs: Double, jitterMs: Double = 0, lossPercent: Double = 0, duplicatePercent: Double = 0,
                lumpMs: Double = 0, stallEverySec: Double = 0, stallMs: Double = 0, reorderPercent: Double = 0,
                hiccupPercent: Double = 0, hiccupMs: Double = 0, stallAtSec: Double = 0, stallOnceMs: Double = 0,
                burstLossPercent: Double = 0, burstLossLength: Double = 4, queuePeakMs: Double = 0, queueEverySec: Double = 5,
                queueRiseMs: Double = 200, queueFallMs: Double = 600) {
        self.name = name; self.baseMs = baseMs; self.jitterMs = jitterMs; self.lossPercent = lossPercent
        self.duplicatePercent = duplicatePercent; self.lumpMs = lumpMs; self.stallEverySec = stallEverySec
        self.stallMs = stallMs; self.reorderPercent = reorderPercent; self.hiccupPercent = hiccupPercent
        self.hiccupMs = hiccupMs; self.stallAtSec = stallAtSec; self.stallOnceMs = stallOnceMs
        self.burstLossPercent = burstLossPercent; self.burstLossLength = burstLossLength; self.queuePeakMs = queuePeakMs
        self.queueEverySec = queueEverySec; self.queueRiseMs = queueRiseMs; self.queueFallMs = queueFallMs
    }

    public static let perfect = SimNetwork("perfect (no jitter at all)", baseMs: 0.2)
    public static let wired = SimNetwork("wired LAN, two desktops", baseMs: 0.2, jitterMs: 0.1, hiccupPercent: 0.1, hiccupMs: 3)
    public static let wifi = SimNetwork("home wifi", baseMs: 2, jitterMs: 1.5, lossPercent: 0.2, lumpMs: 6, hiccupPercent: 0.2, hiccupMs: 5)
    public static let internet = SimNetwork("internet", baseMs: 12, jitterMs: 3, lossPercent: 0.5, reorderPercent: 0.05,
                                            hiccupPercent: 0.2, hiccupMs: 5)
    public static let rough = SimNetwork("rough internet", baseMs: 25, jitterMs: 8, lossPercent: 2, duplicatePercent: 0.5,
                                         reorderPercent: 0.5, hiccupPercent: 0.5, hiccupMs: 8)
    public static let lumpy = SimNetwork("lumpy receiver (Andre)", baseMs: 0.5, jitterMs: 0.2, lumpMs: 24, stallEverySec: 4, stallMs: 60)
    public static let laptopLumps = SimNetwork("Ed's laptop (packets arrive in lumps)", baseMs: 0.3, jitterMs: 0.2, lumpMs: 10,
                                               stallEverySec: 45, stallMs: 30, reorderPercent: 0.1, hiccupPercent: 0.1, hiccupMs: 20)
    public static let burstyInternet = SimNetwork("internet, loss in bursts", baseMs: 12, jitterMs: 3, reorderPercent: 0.05,
                                                  hiccupPercent: 0.2, hiccupMs: 5, burstLossPercent: 0.125, burstLossLength: 4)
    public static let congested = SimNetwork("internet, a queue that builds and drains", baseMs: 12, jitterMs: 2, hiccupPercent: 0.2,
                                             hiccupMs: 5, queuePeakMs: 30, queueEverySec: 4)
    public static let presets: [SimNetwork] = [perfect, wired, wifi, internet, rough, lumpy, laptopLumps, burstyInternet, congested]

    /// A recording replayed, with the one-way delay the network is taken to have.
    public static func replaying(_ replay: NetworkReplay, oneWayMs: Double) -> SimNetwork {
        var n = SimNetwork(replay.name, baseMs: oneWayMs)
        n.replay = replay
        return n
    }

    /// When a packet sent at `sent` arrives (Windows' Simulation.Arrival).
    func arrival(sent: Double, random: inout SimRandom) -> Double {
        var jitter = jitterMs > 0 ? min(-log(1 - random.unit()) * jitterMs, jitterMs * 6) : 0
        if hiccupPercent > 0, random.unit() * 100 < hiccupPercent { jitter += random.unit() * hiccupMs }
        var t = sent + (baseMs + jitter) / 1000
        if lumpMs > 0 {
            let lump = lumpMs / 1000
            t = (t / lump).rounded(.up) * lump
        }
        if stallEverySec > 0, stallMs > 0 {
            let into = t.truncatingRemainder(dividingBy: stallEverySec)
            if into >= stallEverySec - stallMs / 1000 { t += stallEverySec - into }
        }
        if stallOnceMs > 0, t >= stallAtSec, t < stallAtSec + stallOnceMs / 1000 { t = stallAtSec + stallOnceMs / 1000 }
        return t
    }
}

/// The packets' fate on a network: loss (single or in bursts), the queue that builds and drains, keeping order but for
/// the odd overtaking, doubling. One per run.
struct SimPath {
    let network: SimNetwork
    private var inLossBurst = false
    private var queueFrom = -1.0, queueDone = 0.0
    private var lastArrival = 0.0
    private var replay: NetworkReplay?
    private(set) var lost = 0

    init(_ network: SimNetwork) {
        self.network = network
        replay = network.replay?.fresh()
    }

    private mutating func queueDelay(now: Double, random: inout SimRandom) -> Double {
        let n = network
        guard n.queuePeakMs > 0 else { return 0 }
        let rise = n.queueRiseMs / 1000, fall = n.queueFallMs / 1000
        if queueFrom < 0 || now >= queueFrom + rise + fall {
            if queueFrom >= 0 { queueDone = queueFrom + rise + fall }
            if queueFrom < 0 || now >= queueDone {
                queueFrom = max(now, queueDone) + -log(1 - random.unit()) * n.queueEverySec
            }
        }
        let into = now - queueFrom
        guard into >= 0 else { return 0 }
        return (into < rise ? into / rise : max(0, 1 - (into - rise) / fall)) * n.queuePeakMs / 1000
    }

    /// When an audio packet (its stream and sequence) sent at `now` arrives: none if lost, two if doubled.
    mutating func arrivals(stream: UInt16, sequence: UInt32, now: Double, ownPeriod: Double, random: inout SimRandom) -> [Double] {
        if let replay {
            let times = replay.arrivals(stream: stream, sequence: sequence, sentAt: now, oneWay: network.baseMs / 1000, ownPeriod: ownPeriod)
            if times.isEmpty { lost += 1 }
            return times
        }
        if network.burstLossPercent > 0 {
            if !inLossBurst, random.unit() * 100 < network.burstLossPercent { inLossBurst = true }
            if inLossBurst {
                lost += 1
                if random.unit() < 1 / max(1, network.burstLossLength) { inLossBurst = false }
                return []
            }
        }
        if random.unit() * 100 < network.lossPercent {
            lost += 1
            return []
        }
        // Networks keep order (queues are first in, first out); now and then a packet is overtaken by the next.
        var arrival = max(network.arrival(sent: now, random: &random) + queueDelay(now: now, random: &random), lastArrival)
        if random.unit() * 100 < network.reorderPercent { arrival += 0.003 } else { lastArrival = arrival }
        var times = [arrival]
        if random.unit() * 100 < network.duplicatePercent { times.append(arrival + 0.0005) }
        return times
    }
}

/// A recorded network, replayed (Windows' NetworkReplay): from one stream of a NetworkRecording, when each packet
/// arrived, by its place in the stream (its sequence number) and the stream's own period - fitted along the fastest
/// packets, so the two machines' clocks drifting apart is folded in. Lost places never come; doubled ones come twice. A
/// simulated packet takes its place's fate: its sequence number at the recording's own packet rate, else the place
/// nominally nearest in time; it never arrives before its own send plus the one-way delay. No dice are drawn.
public final class NetworkReplay {
    private static let maximumPlaces = 1 << 18
    private static let maximumPackets = 1 << 18
    public let name: String
    /// The recorded stream's period between packets, in seconds.
    public let period: Double
    private let arrive: [Double]   // seconds after the fastest packet's line; .nan = never came
    private let again: [Double]
    private var streams: [UInt16: (first: UInt32, start: Double)] = [:]
    public var places: Int { arrive.count }
    public var lost: Int { arrive.filter(\.isNaN).count }
    public var doubled: Int { again.filter { !$0.isNaN }.count }

    private init(name: String, period: Double, arrive: [Double], again: [Double]) {
        self.name = name
        self.period = period
        self.arrive = arrive
        self.again = again
    }

    /// The same recording from the start again: a run keeps what it learns about its streams in its own copy.
    public func fresh() -> NetworkReplay { NetworkReplay(name: name, period: period, arrive: arrive, again: again) }

    /// How much later than the fastest packets each place arrived (seconds).
    public func delayOf(_ place: Int) -> Double { arrive[place] - Double(place) * period }

    public enum ReplayError: Error, Equatable { case tooFewPackets(stream: Int, count: Int), invalidRecording, invalidSpan, invalidClock }

    /// The stream with the most packets unless one is named.
    public static func from(_ rec: NetworkRecording, stream: Int = -1, name: String? = nil) throws -> NetworkReplay {
        guard rec.streams.count <= 64, rec.facts.count <= 256, rec.packets.count <= maximumPackets,
            stream >= -1, stream < 64 else { throw ReplayError.invalidRecording }
        var chosen = stream
        if chosen < 0 {
            var counts: [Int: Int] = [:]
            for p in rec.packets { counts[p.stream, default: 0] += 1 }
            chosen = counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? -1
        }
        let packets = rec.packets.filter { $0.stream == chosen }
        guard packets.count >= 8 else { throw ReplayError.tooFewPackets(stream: chosen, count: packets.count) }
        guard packets.allSatisfy({ $0.ms.isFinite && $0.ms >= 0 && $0.ms <= 120000 && $0.bytes >= 0 }),
            zip(packets, packets.dropFirst()).allSatisfy({ $0.ms <= $1.ms }) else { throw ReplayError.invalidClock }
        let first = packets[0].sequence
        var places = packets.map { Int64(Int32(bitPattern: $0.sequence &- first)) }
        let lowest = places.min()!
        places = places.map { $0 - lowest }
        let arrivals = packets.map { $0.ms / 1000 }
        guard let maximum = places.max(), maximum < Int64(maximumPlaces) else { throw ReplayError.invalidSpan }
        let count = Int(maximum) + 1

        let iMin = places.firstIndex(of: places.min()!)!, iMax = places.firstIndex(of: places.max()!)!
        var period = (arrivals[iMax] - arrivals[iMin]) / Double(max(1, places[iMax] - places[iMin]))
        guard period.isFinite, period >= 1.0 / 48000, period <= 1 else { throw ReplayError.invalidClock }
        func fastest(_ inPart: (Int64) -> Bool) -> (n: Int64, r: Double) {
            var best: (n: Int64, r: Double) = (-1, .greatestFiniteMagnitude)
            for i in places.indices where inPart(places[i]) && arrivals[i] - Double(places[i]) * period < best.r {
                best = (places[i], arrivals[i] - Double(places[i]) * period)
            }
            return best
        }
        let early = fastest { $0 < Int64(count / 4) }
        let late = fastest { $0 >= Int64(count - count / 4) }
        if early.n >= 0, late.n > early.n { period += (late.r - early.r) / Double(late.n - early.n) }

        guard period.isFinite, period >= 1.0 / 48000, period <= 1 else { throw ReplayError.invalidClock }
        var anchor = Double.greatestFiniteMagnitude
        for i in places.indices { anchor = min(anchor, arrivals[i] - Double(places[i]) * period) }
        var arrive = [Double](repeating: .nan, count: count)
        var again = [Double](repeating: .nan, count: count)
        for i in places.indices {
            let n = Int(places[i])
            if arrive[n].isNaN { arrive[n] = arrivals[i] - anchor } else if again[n].isNaN { again[n] = arrivals[i] - anchor }
        }
        return NetworkReplay(name: name ?? "replayed: \(rec.fact("machine") ?? "a recording") stream \(chosen)",
                             period: period, arrive: arrive, again: again)
    }

    /// When a packet of `stream` numbered `sequence`, sent at `sentAt`, arrives.
    public func arrivals(stream: UInt16, sequence: UInt32, sentAt: Double, oneWay: Double, ownPeriod: Double) -> [Double] {
        guard sentAt.isFinite, sentAt >= 0, oneWay.isFinite, oneWay >= 0,
            ownPeriod.isFinite, ownPeriod >= 1.0 / 48000, ownPeriod <= 1 else { return [] }
        let sameRate = abs(ownPeriod - period) <= period * 1e-3
        var st: (first: UInt32, start: Double)
        if let current = streams[stream] { st = current }
        else {
            // The whole offline trace is available. Fit its initial phase to every known
            // nominal send, so a tiny period-fit error does not shift later packets mid-run.
            // The existing update below still follows an actually slower target sender.
            var phaseLead = 0.0
            if sameRate {
                for index in arrive.indices where !arrive[index].isNaN {
                    phaseLead = max(phaseLead, Double(index) * ownPeriod - arrive[index])
                }
            }
            st = (sequence, sentAt + phaseLead)
        }
        let k = Int64(Int32(bitPattern: sequence &- st.first))
        let unwrapped = sameRate ? k : Int64((Double(k) * ownPeriod / period).rounded())
        var laps = unwrapped / Int64(arrive.count)
        var place = Int(unwrapped % Int64(arrive.count))
        if place < 0 {
            place += arrive.count
            laps -= 1
        }
        let shift = Double(laps) * Double(arrive.count) * period + (sameRate ? 0 : Double(k) * ownPeriod - Double(unwrapped) * period)
        let a = arrive[place]
        streams[stream] = st
        guard !a.isNaN else { return [] }
        if sentAt - (shift + a) > st.start {
            st.start = sentAt - (shift + a)
            streams[stream] = st
        }
        var at = max(sentAt, st.start + (shift + a)) + oneWay
        // At another packet rate, neighbouring packets take places the recording had apart, and a lump in it would put
        // them in the wrong order; networks keep order (queues are first in, first out), so they arrive in order. At the
        // recording's own rate its own order - overtaken packets and all - is kept.
        if !sameRate {
            at = max(at, lastArrival[stream] ?? 0)
            lastArrival[stream] = at
        }
        let twice = again[place]
        return twice.isNaN ? [at] : [at, max(at, max(sentAt, st.start + (shift + twice)) + oneWay)]
    }
    private var lastArrival: [UInt16: Double] = [:]
}
