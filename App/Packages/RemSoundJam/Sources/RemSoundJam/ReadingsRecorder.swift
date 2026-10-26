import Foundation

/// THE READINGS FILE, as the Windows RemSound has had it since 6.2.3 (its issue 35, Jonathan Schuster: the logs were
/// "still a lot"). The numbers RemSound measures every second go to a CSV file of their own beside the log, which opens
/// in a spreadsheet, and the log keeps what happened.
///
/// What reaches the file:
/// - A MINUTE row for every minute, summing the whole minute up as each column's `ReadingAgg` says, so a spike between
///   two minute rows is never lost.
/// - SECOND rows only around a problem (`capture`): seconds wait `memory` in memory, and a capture keeps the ones it
///   reaches back to and the next `after`. The rest are let go.
///
/// Rows go out when they are `memory` old, which keeps the file in time order while a capture can still reach back - so
/// the file runs that far behind until it is flushed (RemSound stopping, Write logs now). A minute row carries the time
/// the minute ended. Not thread-safe: the log calls it from its own queue.
public final class ReadingsRecorder {
    public static let defaultMemory: TimeInterval = 300
    public static let defaultAfter: TimeInterval = 30

    public let memory: TimeInterval
    public let after: TimeInterval
    /// Every second written, not only around a problem (a test's or a deep dive's choice).
    public let everySecond: Bool

    private let schema: ReadingsSchema
    private let writeLine: (String) -> Void
    private var pending: [Pending] = []
    private var minute: [Key: Summary] = [:]
    private var minuteOrder: [Key] = []
    private var minuteStart: Date?
    private var captureUntil = Date.distantPast
    private var headerWritten = false

    private struct Key: Hashable { let stream: String; let output: String }
    private final class Pending {
        let at: Date, line: String, isMinute: Bool
        var captured: Bool
        init(_ at: Date, _ line: String, isMinute: Bool, captured: Bool) {
            self.at = at; self.line = line; self.isMinute = isMinute; self.captured = captured
        }
    }

    public init(schema: ReadingsSchema, memory: TimeInterval = ReadingsRecorder.defaultMemory,
                after: TimeInterval = ReadingsRecorder.defaultAfter, everySecond: Bool = false,
                writeLine: @escaping (String) -> Void) {
        self.schema = schema
        self.memory = everySecond ? 0 : memory
        self.after = after
        self.everySecond = everySecond
        self.writeLine = writeLine
    }

    /// How many rows wait in memory.
    public var waiting: Int { pending.count }
    public var headerLine: String { schema.header() }

    private static func minuteOf(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    /// One second: the machine's row and a row for each stream (or output, or peer).
    public func second(_ now: Date, machine: ReadingsRow, rows: [ReadingsRow] = []) {
        let thisMinute = Self.minuteOf(now)
        if let open = minuteStart, open != thisMinute {
            // The minute ended when the next began - or now, if the clock went back, so the file stays in time order.
            let end = open.addingTimeInterval(60)
            closeMinute(now < end ? now : end)
        }
        if minuteStart == nil { minuteStart = thisMinute }
        let captured = everySecond || now <= captureUntil
        add(machine, now, captured)
        for row in rows { add(row, now, captured) }
        emit(upTo: now.addingTimeInterval(-memory))
    }

    private func add(_ row: ReadingsRow, _ now: Date, _ captured: Bool) {
        let key = Key(stream: row.stream, output: row.output)
        if minute[key] == nil { minute[key] = Summary(schema, row.stream, row.output); minuteOrder.append(key) }
        minute[key]!.add(row)
        pending.append(Pending(now, row.line(now, kind: "second"), isMinute: false, captured: captured))
    }

    private func closeMinute(_ end: Date) {
        for key in minuteOrder { if let s = minute[key] { pending.append(Pending(end, s.line(end), isMinute: true, captured: true)) } }
        minute = [:]
        minuteOrder = []
        minuteStart = nil
    }

    /// Keep the seconds from `lookBack` ago and the next `after`. Returns the span the file will hold, for the log line
    /// that points at it.
    @discardableResult
    public func capture(_ now: Date, lookBack: TimeInterval) -> (from: Date, to: Date) {
        var from = now
        for p in pending.reversed() {
            if p.at < now.addingTimeInterval(-lookBack) { break }
            if p.isMinute { continue }
            p.captured = true
            from = p.at
        }
        let until = now.addingTimeInterval(after)
        if until > captureUntil { captureUntil = until }
        return (from, captureUntil)
    }

    /// Write everything that is going to be written, now: every minute row so far and every captured second. With
    /// `closeMinute` (RemSound stopping) the minute still open is summed up too, as far as it got.
    public func flush(_ now: Date, closeMinute close: Bool = false) {
        if close && minuteStart != nil { closeMinute(now) }
        emit(upTo: .distantFuture)
    }

    /// Logging switched off: nothing waiting may reach the file later.
    public func forget() {
        pending = []
        minute = [:]
        minuteOrder = []
        minuteStart = nil
        captureUntil = .distantPast
    }

    private func emit(upTo: Date) {
        var taken = 0
        for p in pending {
            guard p.at <= upTo else { break }
            taken += 1
            guard p.isMinute || p.captured else { continue }
            if !headerWritten { writeLine(schema.header()); headerWritten = true }
            writeLine(p.line)
        }
        if taken > 0 { pending.removeFirst(taken) }
    }

    /// A file started again (a new part) needs its header again.
    public func headerNeeded() { headerWritten = false }

    /// One stream's (or the machine's) minute, as its seconds come in.
    private struct Summary {
        let schema: ReadingsSchema
        let stream: String, output: String
        var sum: [Double], value: [Double?], count: [Int], text: [String?]
        init(_ schema: ReadingsSchema, _ stream: String, _ output: String) {
            self.schema = schema; self.stream = stream; self.output = output
            let n = schema.columns.count
            sum = Array(repeating: 0, count: n); value = Array(repeating: nil, count: n)
            count = Array(repeating: 0, count: n); text = Array(repeating: nil, count: n)
        }
        mutating func add(_ row: ReadingsRow) {
            for (i, c) in schema.columns.enumerated() {
                if c.agg == .secondsOnly { continue }
                if c.text { if let t = row.texts[i] { text[i] = t }; continue }
                guard let n = row.numbers[i] else { continue }
                count[i] += 1
                switch c.agg {
                case .sum: value[i] = (value[i] ?? 0) + n
                case .max: value[i] = Swift.max(value[i] ?? n, n)
                case .min: value[i] = Swift.min(value[i] ?? n, n)
                case .mean: sum[i] += n; value[i] = sum[i] / Double(count[i])
                case .last: value[i] = n
                case .secondsOnly: break
                }
            }
        }
        func line(_ end: Date) -> String {
            let row = ReadingsRow(schema, groupsInUse: schema.columns.map(\.group), stream: stream, output: output)
            for i in 0..<schema.columns.count { row.numbers[i] = value[i]; row.texts[i] = text[i] }
            return row.line(end, kind: "minute")
        }
    }
}
