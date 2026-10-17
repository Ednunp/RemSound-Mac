import Foundation

/// The Mac's detailed log (Ed, 2026-09-29: "build comprehensive logging into his mac app so we can test this stuff").
///
/// One file per run - `<prefix>-<yyyyMMdd-HHmmss>-1.log` - in a folder the person can choose (Andre can point it into
/// Dropbox for Ed to read), a new part when a file reaches `maxBytes`, and files older than `keepDays` removed. Lines are
/// tab-separated like the Windows RemSound's: a kind (`EVT` for an event, `SNAP` for the once-a-second figures), the time
/// to the millisecond, and the words. Written in batches from the caller's queue - never from an audio callback - and it
/// never holds passwords, keys or sound.
public final class JamLog {
    public let directory: URL
    public let prefix: String
    public let maxBytes: Int
    public let keepDays: Int
    public private(set) var currentFile: URL?
    private var handle: FileHandle?
    private var written = 0
    private var part = 1
    private let started: String
    private var pending: [String] = []
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone.current
        return f
    }()

    public init(directory: URL, prefix: String, maxBytes: Int = 20_000_000, keepDays: Int = 14, now: Date = Date()) {
        self.directory = directory
        self.prefix = prefix
        self.maxBytes = maxBytes
        self.keepDays = keepDays
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        started = f.string(from: now)
        prune(now: now)
    }

    public func event(_ text: String, at date: Date = Date()) { add("EVT", text, date) }
    public func snapshot(_ text: String, at date: Date = Date()) { add("SNAP", text, date) }

    private func add(_ kind: String, _ text: String, _ date: Date) {
        let clean = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        pending.append("\(kind)\t\(Self.stamp.string(from: date))\t\(clean)\n")
        if pending.count >= 64 { flush() }
    }

    /// Write what is waiting (call once a second, and when stopping).
    public func flush() {
        guard !pending.isEmpty else { return }
        var batch = Data()
        for line in pending {
            let data = Data(line.utf8)
            if handle == nil || (written + batch.count + data.count > maxBytes && written + batch.count > 0) {
                if let handle, !batch.isEmpty { handle.write(batch); written += batch.count }
                batch = Data()
                open(next: handle != nil)
            }
            batch.append(data)
        }
        pending = []
        guard let handle else { return }
        handle.write(batch)
        written += batch.count
    }

    public func close() {
        flush()
        try? handle?.close()
        handle = nil
    }

    private func open(next: Bool) {
        try? handle?.close()
        handle = nil
        if next { part += 1 }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(prefix)-\(started)-\(part).log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        written = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        currentFile = url
    }

    /// Remove this app's log files older than `keepDays`.
    public func prune(now: Date) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(prefix + "-") && name.hasSuffix(".log") {
            let url = directory.appendingPathComponent(name)
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { continue }
            if now.timeIntervalSince(modified) > Double(keepDays) * 86_400 { try? FileManager.default.removeItem(at: url) }
        }
    }
}

/// The once-a-second figures, worded as the Windows RemSound words its own ("streams [...]"), so one reading of either
/// log serves both.
public enum JamLogLines {
    /// One incoming stream this second.
    public struct Stream: Equatable {
        public var peer: String
        public var stream: UInt16
        public var codec: String
        public var frames: Int
        public var packets: Int
        public var maxGapMs: Double
        public var concealed: Int
        public var underruns: Int
        public var queuedMs: Int
        public var targetMs: Int
        /// The sender's clock against ours, while clocks are being kept (nil: they are not).
        public var clock: Clock?
        public init(peer: String, stream: UInt16, codec: String, frames: Int, packets: Int, maxGapMs: Double, concealed: Int,
                    underruns: Int, queuedMs: Int, targetMs: Int, clock: Clock? = nil) {
            self.peer = peer; self.stream = stream; self.codec = codec; self.frames = frames; self.packets = packets
            self.maxGapMs = maxGapMs; self.concealed = concealed; self.underruns = underruns; self.queuedMs = queuedMs
            self.targetMs = targetMs; self.clock = clock
        }
    }

    /// One clock against another: measured, in parts per million, or still being measured (the first ten seconds).
    public struct Clock: Equatable {
        public var ppm: Double?
        public init(ppm: Double?) { self.ppm = ppm }
        public var text: String { ppm.map { "clock=" + String(format: "%+d", Int($0.rounded())) + "ppm" } ?? "clock=measuring" }
    }

    /// An output card this second: its clock against the mix's, the cushion held for it, and what keeping it cost - the
    /// silence laid down, the sound cut, the times it ran dry (all since the output started).
    public static func outputCard(ppm: Double?, cushionFrames: Int, laidFrames: Int, cutFrames: Int, ranDry: Int) -> String {
        func ms(_ frames: Int) -> String { String(format: "%.1f", Double(frames) / 48) + "ms" }
        return "\(Clock(ppm: ppm).text) cushion=\(ms(cushionFrames)) laid=\(ms(laidFrames)) cut=\(ms(cutFrames)) ran-dry=\(ranDry)"
    }

    public static func streams(_ streams: [Stream], sending: String) -> String {
        let each = streams.map {
            "\($0.peer) stream=\($0.stream) \($0.codec) \($0.frames) frames pkts=\($0.packets) gap-peak=\(Int($0.maxGapMs.rounded()))ms "
                + "concealed=\($0.concealed) underruns=\($0.underruns) queued=\($0.queuedMs)ms target=\($0.targetMs)ms"
                + ($0.clock.map { " " + $0.text } ?? "")
        }
        return "streams: \(sending); " + (each.isEmpty ? "nothing received" : each.joined(separator: " | "))
    }

    /// A peer's total latency, as Windows says it in its status: how long from their input to your ears - their capture,
    /// the packet's filling, half the round trip, your buffer and your output.
    public static func totalLatencyMs(captureMs: Double, packetMs: Double, rttMs: Double, bufferMs: Double, outputMs: Double) -> Double {
        captureMs + packetMs + rttMs / 2 + bufferMs + outputMs
    }

    public static func peer(_ name: String, rttMs: Double?, totalMs: Double?) -> String {
        guard let rttMs else { return "\(name): not measured yet" }
        let total = totalMs.map { ", total latency about \(Int($0.rounded())) ms" } ?? ""
        return "\(name): ping \(Int(rttMs.rounded())) ms\(total)"
    }
}
