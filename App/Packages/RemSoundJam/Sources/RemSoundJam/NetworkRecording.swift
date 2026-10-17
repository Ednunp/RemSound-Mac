import Foundation

// THE LAST MINUTE OF THE NETWORK, SAVED (the Mac's copy of the Windows RemSound's NetworkRecording.cs and
// NetworkRecorder.cs, 30 September 2026).
//
// Every audio packet's arrival - when, which stream, its sequence number and its size - is kept for a minute. When a
// moment sounds wrong, the minute is saved as a plain text file, and Ed's simulator plays that very network back,
// packet for packet, into the real Windows receiver: what the Mac met on the wire can be heard again, measured, and
// tried at other buffers and codecs. The file is the SAME format the Windows app writes, line for line, so either
// port's recordings load in the simulator. It holds no sound, no password and no key: times, numbers and sizes only.

/// A minute of the network as a receiver met it. Saved as text: a first line, facts, streams, then a line a packet.
public struct NetworkRecording: Equatable {
    public static let firstLine = "# RemSound network recording 1"

    public struct Fact: Equatable {
        public var key: String, value: String
        public init(_ key: String, _ value: String) {
            self.key = key
            // A fact is one line.
            self.value = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        }
    }

    /// One stream heard: where from, its stream id, and what its Format packet said.
    public struct Stream: Equatable {
        public var index: Int
        public var from: String
        public var streamId: UInt16
        public var lane: String
        public var format: String
        public var codec: Int
        public var frameSamples: Int
        public init(index: Int, from: String, streamId: UInt16, lane: String, format: String, codec: Int, frameSamples: Int) {
            self.index = index; self.from = from; self.streamId = streamId; self.lane = lane; self.format = format
            self.codec = codec; self.frameSamples = frameSamples
        }
    }

    /// One packet: milliseconds after the recording's first packet, which stream (by index), its sequence and size.
    public struct Packet: Equatable {
        public var ms: Double
        public var stream: Int
        public var sequence: UInt32
        public var bytes: Int
        public init(ms: Double, stream: Int, sequence: UInt32, bytes: Int) {
            self.ms = ms; self.stream = stream; self.sequence = sequence; self.bytes = bytes
        }
    }

    public var facts: [Fact] = []
    public var streams: [Stream] = []
    public var packets: [Packet] = []

    public init() {}

    public func fact(_ key: String) -> String? {
        facts.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    /// The file's text, as the Windows app writes it.
    public func text() -> String {
        var lines = [Self.firstLine]
        for f in facts { lines.append("\(f.key): \(f.value)") }
        for s in streams {
            lines.append("stream \(s.index): from \(s.from) id \(s.streamId) lane \(s.lane) codec \(s.codec) frame \(s.frameSamples) format \(s.format)")
        }
        lines.append("packets: ms stream sequence bytes")
        for p in packets {
            lines.append(String(format: "%.3f", p.ms) + " \(p.stream) \(p.sequence) \(p.bytes)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public enum ReadError: Error, Equatable {
        case notARecording
        case badLine(Int, String)
        case noPackets
    }

    /// Read a recording back, by the Windows reader's rules: anything that is not one throws, saying which line.
    public static func read(_ text: String) throws -> NetworkRecording {
        var rec = NetworkRecording()
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == firstLine else { throw ReadError.notARecording }
        var inPackets = false
        for (offset, line) in lines.enumerated().dropFirst() {
            let n = offset + 1
            if line.isEmpty { continue }
            if inPackets {
                let p = line.split(separator: " ", omittingEmptySubsequences: false)
                guard p.count == 4, let ms = Double(p[0]), let stream = Int(p[1]), let sequence = UInt32(p[2]), let bytes = Int(p[3]),
                      stream >= 0, stream < rec.streams.count
                else { throw ReadError.badLine(n, line) }
                rec.packets.append(Packet(ms: ms, stream: stream, sequence: sequence, bytes: bytes))
                continue
            }
            if line.hasPrefix("packets:") {
                inPackets = true
                continue
            }
            if line.hasPrefix("stream "), let s = parseStream(line) {
                guard s.index == rec.streams.count else { throw ReadError.badLine(n, line) }
                rec.streams.append(s)
                continue
            }
            guard let colon = line.range(of: ": "), colon.lowerBound > line.startIndex else { throw ReadError.badLine(n, line) }
            var fact = Fact("", "")
            fact.key = String(line[..<colon.lowerBound])
            fact.value = String(line[colon.upperBound...])
            rec.facts.append(fact)
        }
        guard inPackets else { throw ReadError.noPackets }
        return rec
    }

    private static func parseStream(_ line: String) -> Stream? {
        // stream 0: from 10.77.0.1:50123 id 4282 lane Mixed codec 1 frame 120 format 48000 Hz, ...
        guard let colon = line.range(of: ": "),
              let index = Int(line[line.index(line.startIndex, offsetBy: 7)..<colon.lowerBound]) else { return nil }
        let rest = String(line[colon.upperBound...])
        func word(_ name: String) -> String? {
            guard let at = rest.range(of: name + " ") else { return nil }
            let tail = rest[at.upperBound...]
            return String(tail.prefix { $0 != " " })
        }
        guard let from = word("from"), let id = word("id").flatMap({ UInt16($0) }), let lane = word("lane"),
              let codec = word("codec").flatMap({ Int($0) }), let frame = word("frame").flatMap({ Int($0) }),
              let format = rest.range(of: "format ")
        else { return nil }
        return Stream(index: index, from: from, streamId: id, lane: lane, format: String(rest[format.upperBound...]), codec: codec, frameSamples: frame)
    }
}

/// The last minute of audio-packet arrivals, kept in memory. One note a packet, taken as it comes off the socket, before
/// any decision about it. Once a second the owner adds the receiver's own counts, so a saved minute says what the
/// receiver itself heard go wrong in it. Nothing is kept, or allocated, while it is off.
public struct NetworkRecorder {
    public static let keepSeconds = 60.0
    static let firstCapacity = 4096
    static let maxCapacity = 1 << 18   // a minute of 4,000 and more packets a second

    /// What a stream is, for its line in the file.
    public struct StreamDescription: Equatable {
        public var lane: String, format: String, codec: Int, frameSamples: Int
        public init(lane: String, format: String, codec: Int, frameSamples: Int) {
            self.lane = lane; self.format = format; self.codec = codec; self.frameSamples = frameSamples
        }
    }

    /// The receiver's counts at one moment, each a total since it started: breaks in the sound (a stream ran dry),
    /// packets thrown away as late or doubled, packets the decoder filled in, and gaps too long to fill.
    public struct Counters: Equatable {
        public var at: Double
        public var audibleGaps: Int, lateOrDoubledDropped: Int, concealed: Int, gapsNotRepaired: Int
        public init(at: Double, audibleGaps: Int, lateOrDoubledDropped: Int, concealed: Int, gapsNotRepaired: Int) {
            self.at = at; self.audibleGaps = audibleGaps; self.lateOrDoubledDropped = lateOrDoubledDropped
            self.concealed = concealed; self.gapsNotRepaired = gapsNotRepaired
        }
    }

    private struct Entry {
        var at: Double
        var sequence: UInt32
        var bytes: UInt16
        var stream: UInt16
    }

    public var enabled = false
    private var ring: [Entry] = []
    private var next = 0, count = 0
    private var streams: [(from: String, streamId: UInt16)] = []
    private var lastStream = -1
    private var seconds: [Counters] = []

    public init() {}

    /// How many packets are held, and how much room there is (for tests).
    public var held: Int { count }
    public var capacity: Int { ring.count }

    /// A packet came in.
    public mutating func note(from: String, streamId: UInt16, sequence: UInt32, bytes: Int, now: Double) {
        guard enabled else { return }
        var stream = lastStream
        if stream < 0 || streams[stream].streamId != streamId || streams[stream].from != from {
            if let known = streams.firstIndex(where: { $0.streamId == streamId && $0.from == from }) {
                stream = known
            } else {
                guard streams.count < Int(UInt16.max) else { return }
                stream = streams.count
                streams.append((from, streamId))
            }
            lastStream = stream
        }
        if ring.isEmpty { ring = [Entry](repeating: Entry(at: 0, sequence: 0, bytes: 0, stream: 0), count: Self.firstCapacity) }
        if count == ring.count {
            // Full: grow while the oldest entry is still inside the minute, else overwrite it.
            if ring.count < Self.maxCapacity, now - ring[next].at < Self.keepSeconds { grow() } else { count -= 1 }
        }
        ring[next] = Entry(at: now, sequence: sequence, bytes: UInt16(min(bytes, Int(UInt16.max))), stream: UInt16(stream))
        next = (next + 1) % ring.count
        count += 1
    }

    private mutating func grow() {
        var bigger = [Entry](repeating: Entry(at: 0, sequence: 0, bytes: 0, stream: 0), count: ring.count * 2)
        // Oldest first: the ring being full, that is from `next` round to `next - 1`.
        for i in 0..<count { bigger[i] = ring[(next + i) % ring.count] }
        ring = bigger
        next = count
    }

    /// Once a second: the receiver's counts now. Two minutes of them are kept, so the saved minute's start is among them.
    public mutating func noteSecond(_ counters: Counters) {
        guard enabled else { return }
        seconds.append(counters)
        if seconds.count > Int(2 * Self.keepSeconds) + 10 { seconds.removeFirst(seconds.count - Int(2 * Self.keepSeconds) - 10) }
    }

    /// The last minute as a recording. `facts` come first in the file (the machine, the buffers); `describe` says what
    /// each stream is, when the receiver knows. The live figures are the counts' change across the packets' own span.
    public func take(facts: [NetworkRecording.Fact], describe: (String, UInt16) -> StreamDescription?) -> NetworkRecording {
        var rec = NetworkRecording()
        rec.facts = facts
        guard count > 0 else { return rec }
        let first = (next - count + ring.count) % ring.count
        let heldEntries = (0..<count).map { ring[(first + $0) % ring.count] }
        let newest = heldEntries[heldEntries.count - 1].at
        let kept = Array(heldEntries.drop { newest - $0.at > Self.keepSeconds })
        let start = kept[0].at
        // Streams renumbered from 0, in the order they first appear in the kept minute.
        var renumber: [UInt16: Int] = [:]
        for e in kept where renumber[e.stream] == nil {
            let index = renumber.count
            renumber[e.stream] = index
            let (from, id) = streams[Int(e.stream)]
            let d = describe(from, id)
            rec.streams.append(NetworkRecording.Stream(index: index, from: from, streamId: id, lane: d?.lane ?? "unknown",
                format: d?.format ?? "no Format packet seen", codec: d?.codec ?? -1, frameSamples: d?.frameSamples ?? 0))
        }
        for e in kept {
            rec.packets.append(NetworkRecording.Packet(ms: (e.at - start) * 1000, stream: renumber[e.stream]!, sequence: e.sequence, bytes: Int(e.bytes)))
        }
        // What the receiver heard go wrong over the same span: the change between the counts nearest its start and the
        // newest ones.
        if seconds.count >= 2, let last = seconds.last {
            let spanFrom = seconds.last { $0.at <= start } ?? seconds[0]
            rec.facts.append(NetworkRecording.Fact("live seconds", String(format: "%.1f", last.at - spanFrom.at)))
            rec.facts.append(NetworkRecording.Fact("live audible gaps", String(last.audibleGaps - spanFrom.audibleGaps)))
            rec.facts.append(NetworkRecording.Fact("live late or doubled dropped", String(last.lateOrDoubledDropped - spanFrom.lateOrDoubledDropped)))
            rec.facts.append(NetworkRecording.Fact("live gaps not repaired", String(last.gapsNotRepaired - spanFrom.gapsNotRepaired)))
            rec.facts.append(NetworkRecording.Fact("live concealed", String(last.concealed - spanFrom.concealed)))
        }
        return rec
    }

    /// The file's name: RemSound-network-<machine>-<yyyyMMdd-HHmmss>.txt, as the Windows app names its own.
    public static func fileName(machine: String, at date: Date, timeZone: TimeZone = .current) -> String {
        let safe = machine.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "RemSound-network-\(safe.isEmpty ? "Mac" : safe)-\(f.string(from: date)).txt"
    }
}
