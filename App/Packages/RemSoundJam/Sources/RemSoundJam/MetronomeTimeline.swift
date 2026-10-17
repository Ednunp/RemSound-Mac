import Dispatch
import Foundation

/// The clock every metronome time on this machine is in: microseconds since the machine started, from the monotonic
/// clock. Capture times sent to the server and click times from it must share one clock; this is it.
public enum MetronomeClock {
    public static func nowUs() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1000) }
}

/// A time signature: beats in a bar (1-32) over the beat's note value (1, 2, 4, 8, 16 or 32).
public struct MetronomeSignature: Equatable, Sendable, CustomStringConvertible {
    public var beatsPerBar: UInt8
    public var beatUnit: UInt8
    public init(_ beatsPerBar: UInt8, _ beatUnit: UInt8) {
        self.beatsPerBar = beatsPerBar
        self.beatUnit = beatUnit
    }
    public static let `default` = MetronomeSignature(4, 4)
    public var isValid: Bool { (1...32).contains(beatsPerBar) && [1, 2, 4, 8, 16, 32].contains(beatUnit) }
    public var description: String { "\(beatsPerBar)/\(beatUnit)" }
}

/// The beat, as one timeline: beat number `anchorBeat` falls at `anchorTimeUs` (in this machine's metronome clock), and
/// the beats go on at the tempo from there. A copy of the Windows RemSound's MetronomeTimeline (the reference); the
/// server's beat grid arrives as one of these, already in this machine's clock.
public struct MetronomeTimeline: Equatable, Sendable, CustomStringConvertible {
    public static let minBpm: UInt32 = 30
    public static let maxBpm: UInt32 = 300
    public static let defaultBpm: UInt32 = 120

    public var version: UInt32
    public var running: Bool
    public var milliBpm: UInt32
    public var beatsPerBar: UInt8
    public var beatUnit: UInt8
    public var anchorBeat: Int64
    public var anchorTimeUs: Int64

    public init(version: UInt32, running: Bool, milliBpm: UInt32, beatsPerBar: UInt8, beatUnit: UInt8, anchorBeat: Int64, anchorTimeUs: Int64) {
        self.version = version
        self.running = running
        self.milliBpm = milliBpm
        self.beatsPerBar = beatsPerBar
        self.beatUnit = beatUnit
        self.anchorBeat = anchorBeat
        self.anchorTimeUs = anchorTimeUs
    }

    public static func stopped(milliBpm: UInt32 = defaultBpm * 1000, signature: MetronomeSignature = .default) -> MetronomeTimeline {
        MetronomeTimeline(version: 0, running: false, milliBpm: milliBpm, beatsPerBar: signature.beatsPerBar,
                          beatUnit: signature.beatUnit, anchorBeat: 0, anchorTimeUs: 0)
    }

    public var signature: MetronomeSignature { MetronomeSignature(beatsPerBar, beatUnit) }
    public var bpm: Double { Double(milliBpm) / 1000 }
    public var beatIntervalUs: Double { 60_000_000_000.0 / Double(milliBpm) }
    public var isValid: Bool { milliBpm >= Self.minBpm * 1000 && milliBpm <= Self.maxBpm * 1000 && signature.isValid }

    public func beatTimeUs(_ beat: Int64) -> Double { Double(anchorTimeUs) + Double(beat - anchorBeat) * beatIntervalUs }

    /// The first beat at or after a moment.
    public func beatAtOrAfter(_ timeUs: Double) -> Int64 {
        anchorBeat + Int64(((timeUs - Double(anchorTimeUs)) / beatIntervalUs - 1e-9).rounded(.up))
    }

    /// Where a beat falls in its bar, from 1; beat 1 is the accent.
    public func beatInBar(_ beat: Int64) -> Int {
        let n = Int64(beatsPerBar)
        return Int(((beat - anchorBeat) % n + n) % n) + 1
    }

    public func isAccent(_ beat: Int64) -> Bool { beatInBar(beat) == 1 }

    /// How far ahead a start or a change lands, so the first click can be placed before its moment comes.
    public static let leadUs: Int64 = 400_000

    /// Start: beat 0 `leadUs` from now. Already running, nothing changes.
    public func start(nowUs: Int64) -> MetronomeTimeline {
        guard !running else { return self }
        var t = self
        t.version &+= 1
        t.running = true
        t.anchorBeat = 0
        t.anchorTimeUs = nowUs + Self.leadUs
        return t
    }

    public func stop() -> MetronomeTimeline {
        guard running else { return self }
        var t = self
        t.version &+= 1
        t.running = false
        return t
    }

    /// A new tempo or signature. Stopped, it is kept for the next start. Running, it takes effect at the first bar line at
    /// least `leadUs` ahead, the beat count carrying on through it.
    public func change(nowUs: Int64, milliBpm: UInt32, signature: MetronomeSignature) -> MetronomeTimeline {
        if milliBpm == self.milliBpm && signature == self.signature { return self }
        var t = self
        t.version &+= 1
        t.milliBpm = milliBpm
        t.beatsPerBar = signature.beatsPerBar
        t.beatUnit = signature.beatUnit
        guard running else { return t }
        var beat = beatAtOrAfter(Double(nowUs + Self.leadUs))
        let n = Int64(beatsPerBar)
        let intoBar = ((beat - anchorBeat) % n + n) % n
        if intoBar != 0 { beat += n - intoBar }
        t.anchorBeat = beat
        t.anchorTimeUs = Int64(beatTimeUs(beat).rounded())
        return t
    }

    /// The tempo as the menus say it: whole beats a minute, or to three places when it has them.
    public var bpmText: String {
        milliBpm % 1000 == 0 ? "\(milliBpm / 1000)" : "\(milliBpm / 1000).\(String(format: "%03d", Int(milliBpm % 1000)))"
    }

    public var description: String {
        running
            ? "playing \(bpmText) bpm \(signature), beat \(anchorBeat) at \(anchorTimeUs / 1000) ms (version \(version))"
            : "stopped, \(bpmText) bpm \(signature) (version \(version))"
    }
}

/// The server's beat grid for this machine: whether it plays, whether this machine's delay has been measured yet,
/// whether we lead it, who does, and the timeline - early by exactly how long this machine's sound takes to reach the
/// server, so a note played on its click reaches the server on the beat.
public struct ServerGrid: Equatable, Sendable {
    public var running: Bool
    public var measured: Bool
    public var youLead: Bool
    public var master: UUID
    public var timeline: MetronomeTimeline
    public init(running: Bool, measured: Bool, youLead: Bool, master: UUID, timeline: MetronomeTimeline) {
        self.running = running
        self.measured = measured
        self.youLead = youLead
        self.master = master
        self.timeline = timeline
    }
}

/// The server's metronome on the wire (relay packet type 13, read by the relay itself and never passed on): a copy of
/// the Windows RemSound's ServerMetronomeWire (the reference). The body follows the relay's 28-byte group header.
public enum ServerMetronomeWire {
    public static let report: UInt8 = 1
    public static let claim: UInt8 = 2
    public static let release: UInt8 = 3
    public static let set: UInt8 = 4
    public static let grid: UInt8 = 20
    public static let maxReportEntries = 16
    public static let reportEntryBytes = 14
    public static let gridBytes = 40
    static let flagRunning: UInt8 = 1, flagMeasured: UInt8 = 2, flagYouLead: UInt8 = 4
    static let nobody = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// When packets were captured, in this machine's metronome clock: [kind][count] then each (stream u16, sequence u32,
    /// captured i64). The relay pairs each with when that packet reached it.
    public static func buildReport(_ entries: [CaptureReport]) -> [UInt8] {
        let count = min(entries.count, maxReportEntries)
        var body: [UInt8] = [report, UInt8(count)]
        for e in entries.prefix(count) {
            body.appendLE(e.stream)
            body.appendLE(e.sequence)
            body.appendLE(e.capturedUs)
        }
        return body
    }

    public static func buildClaim() -> [UInt8] { [claim] }
    public static func buildRelease() -> [UInt8] { [release] }

    /// The master's setting, for the server: playing or not, the tempo in thousandths of a beat a minute, the signature.
    public static func buildSet(running: Bool, milliBpm: UInt32, beatsPerBar: UInt8, beatUnit: UInt8) -> [UInt8] {
        var body: [UInt8] = [set, running ? 1 : 0]
        body.appendLE(milliBpm)
        body.append(beatsPerBar)
        body.append(beatUnit)
        return body
    }

    /// A grid as the relay writes it: [kind][flags][master id 16][version u32][milli-bpm u32][per bar u8][unit u8]
    /// [anchor beat u32][anchor time i64, in THIS machine's clock]. Nil for anything else, or one that cannot mean a beat.
    public static func readGrid(_ body: [UInt8]) -> ServerGrid? {
        guard body.count >= gridBytes, body[0] == grid else { return nil }
        let flags = body[1]
        let master = JamWire.uuid(from: body[2..<18])
        let timeline = MetronomeTimeline(
            version: body.readLE(UInt32.self, at: 18), running: flags & flagRunning != 0,
            milliBpm: body.readLE(UInt32.self, at: 22), beatsPerBar: body[26], beatUnit: body[27],
            anchorBeat: Int64(body.readLE(UInt32.self, at: 28)), anchorTimeUs: body.readLE(Int64.self, at: 32))
        guard timeline.isValid else { return nil }
        return ServerGrid(running: flags & flagRunning != 0, measured: flags & flagMeasured != 0,
                          youLead: flags & flagYouLead != 0, master: master, timeline: timeline)
    }

    /// A grid as the relay would send it - for the tests.
    public static func buildGrid(_ g: ServerGrid) -> [UInt8] {
        var body: [UInt8] = [grid, (g.running ? flagRunning : 0) | (g.measured ? flagMeasured : 0) | (g.youLead ? flagYouLead : 0)]
        body.append(contentsOf: JamWire.bytes(of: g.master))
        body.appendLE(g.timeline.version)
        body.appendLE(g.timeline.milliBpm)
        body.append(g.timeline.beatsPerBar)
        body.append(g.timeline.beatUnit)
        body.appendLE(UInt32(truncatingIfNeeded: g.timeline.anchorBeat))
        body.appendLE(g.timeline.anchorTimeUs)
        return body
    }
}
