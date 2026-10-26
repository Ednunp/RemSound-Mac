import Foundation
import XCTest

@testable import RemSoundJam

/// The logging the Windows RemSound has had since 6.2.3 (its issue 35), on the Mac: the readings file and its rule, the
/// severity word and category on every line, runs of gaps, and peers connecting and dropping.
final class LoggingTests: XCTestCase {
    let schema = ReadingsSchema([
        ReadingColumn("connected", .last), ReadingColumn("packets", .sum, group: "stream"),
        ReadingColumn("longestGapMs", .max, group: "stream"), ReadingColumn("bufferLowMs", .min, group: "stream"),
        ReadingColumn("bufferMs", .mean, group: "stream"), ReadingColumn("sending", .last, group: "sending"),
        ReadingColumn("codec", .last, group: "stream", text: true), ReadingColumn("detail", .secondsOnly, text: true),
    ])
    let t0 = Date(timeIntervalSince1970: 1_790_000_040) // 2026-09-21 ... :14:00 UTC, a minute's start

    private func row(_ second: Int, stream: String = "", groups: [String] = ["stream"]) -> ReadingsRow {
        let r = ReadingsRow(schema, groupsInUse: groups, stream: stream)
        r.set("connected", true)
        r.set("packets", 100)
        r.set("longestGapMs", Double(second % 7))
        r.set("bufferLowMs", Double(20 - second % 5))
        r.set("bufferMs", Double(second))
        r.set("sending", true)
        r.text("codec", "Opus")
        r.text("detail", "second \(second)")
        return r
    }

    private func record(_ seconds: Int, every: Bool = false, capture: ((ReadingsRecorder, Date) -> Void)? = nil) -> [String] {
        var lines: [String] = []
        let recorder = ReadingsRecorder(schema: schema, everySecond: every) { lines.append($0) }
        for s in 0..<seconds {
            let now = t0.addingTimeInterval(TimeInterval(s))
            recorder.second(now, machine: row(s), rows: [row(s, stream: "Ed/7")])
            if let capture { capture(recorder, now) }
        }
        recorder.flush(t0.addingTimeInterval(TimeInterval(seconds)), closeMinute: true)
        return lines
    }

    func testMinuteRowsSumTheWholeMinuteAndSecondsOnlyComeAroundAProblem() {
        let lines = record(180)
        XCTAssertEqual(lines.first, schema.header(), "the header first")
        XCTAssertTrue(lines[0].hasPrefix("Time,Kind,Stream,Output,connected,packets"))
        let minutes = lines.filter { $0.contains(",minute,") }
        XCTAssertEqual(minutes.count, 6, "a minute row for the machine and the stream, each of three minutes")
        XCTAssertTrue(lines.dropFirst().allSatisfy { $0.contains(",minute,") }, "no second rows without a problem")
        let edFirst = minutes.first { $0.contains(",Ed/7,") }!
        let cells = edFirst.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        // Time,Kind,Stream,Output,connected,packets,longestGapMs,bufferLowMs,bufferMs,sending,codec,detail
        XCTAssertEqual(cells[5], "6000", "counts added up over the minute")
        XCTAssertEqual(cells[6], "6", "the peak")
        XCTAssertEqual(cells[7], "16", "the low point")
        XCTAssertEqual(cells[8], "29.5", "the average")
        XCTAssertEqual(cells[10], "Opus", "words as the minute ended")
        XCTAssertEqual(cells[11], "", "a seconds-only column is left out of minute rows")
    }

    func testACaptureKeepsTheSecondsBeforeAndAfterInTimeOrder() {
        let problem = t0.addingTimeInterval(200)
        var span: (Date, Date)?
        let lines = record(600) { recorder, now in if now == problem { span = recorder.capture(now, lookBack: 30) } }
        let seconds = lines.filter { $0.contains(",second,") && $0.contains(",Ed/7,") }
        XCTAssertEqual(seconds.count, 61, "30 seconds back, the problem's own second and the 30 after")
        XCTAssertEqual(span?.0, problem.addingTimeInterval(-30))
        XCTAssertEqual(span?.1, problem.addingTimeInterval(30))
        XCTAssertTrue(seconds.first!.contains("second 170"), "every second row says its own second: \(seconds.first!)")
        let times = lines.dropFirst().map { String($0.prefix(19)) }
        XCTAssertEqual(times, times.sorted(), "the file stays in time order")
        XCTAssertEqual(lines.filter { $0.contains(",minute,") }.count, 20, "and every minute is still summed up")
    }

    func testEverySecondWritesThemAll() {
        let lines = record(10, every: true)
        XCTAssertEqual(lines.filter { $0.contains(",second,") }.count, 20)
    }

    func testAReadingIsWrittenOnlyWhileWhatItMeasuresIsInUse() {
        let off = ReadingsRow(schema, groupsInUse: [])
        off.set("sending", true); off.set("packets", 0); off.set("connected", false)
        XCTAssertEqual(off.cell("sending"), "", "a send not in use leaves its cell empty")
        XCTAssertEqual(off.cell("packets"), "", "and so does a stream")
        XCTAssertEqual(off.cell("connected"), "0", "what is always in use writes its zero")
        let on = ReadingsRow(schema, groupsInUse: ["stream"])
        on.set("packets", 0)
        XCTAssertEqual(on.cell("packets"), "0", "a zero in use is still written")
        on.set("noSuchColumn", 1)
        XCTAssertEqual(on.unknown, ["noSuchColumn"])
        XCTAssertEqual(ReadingsSchema.csv("a, \"b\""), "\"a, \"\"b\"\"\"")
        XCTAssertEqual(ReadingsSchema.number(2.50), "2.5")
        XCTAssertEqual(ReadingsSchema.number(.nan), "")
    }

    func testEveryLineSaysItsSeverityAndCategory() {
        let error = LogLines.classify("capture: the input device crashed")
        XCTAssertEqual(error.level, .error); XCTAssertEqual(error.category, "Audio")
        XCTAssertEqual(LogLines.classify("security: 10.0.0.2 is on a different password - not connected").category, "Security")
        XCTAssertEqual(LogLines.classify("Server: disconnected.").level, .warn)
        XCTAssertEqual(LogLines.classify("server status [send input on]").category, "Server")
        XCTAssertEqual(LogLines.classify("gate copy: listening").category, "Gate copy", "an unknown start is its own category")
        XCTAssertEqual(LogLines.classify("hear myself components: stream 7").category, "Hear myself")
        let plain = LogLines.classify("something happened")
        XCTAssertEqual(plain.level, .info); XCTAssertEqual(plain.category, "App"); XCTAssertEqual(plain.text, "something happened")
        XCTAssertFalse(LogLines.classify("updater: error=\"none\"").level == .error, "mentioning an error is not one")
        let line = LogLines.format(.warn, t0, "Peer", "Ed\tgone\nfor good")
        XCTAssertTrue(line.hasPrefix("WARN\t") && line.hasSuffix("\tPeer: Ed gone for good"), line)
        XCTAssertEqual(line.split(separator: "\t").count, 3)
    }

    func testARunOfGapsIsOneLineWhenItStartsAndOneWhenItEnds() {
        let runs = GapEpisodes()
        var words: [GapEpisodes.Change] = []
        for s in 0..<600 {
            let gaps = (s >= 10 && s < 130 && s % 2 == 0) ? 3 : 0
            let longest = s == 100 ? 60 : 30
            words += runs.second(t0.addingTimeInterval(TimeInterval(s)), newGaps: gaps, longestGapMs: gaps > 0 ? longest : 0,
                                 byStream: gaps > 0 ? ["Ed on Opus": gaps] : [:])
        }
        XCTAssertEqual(words.map(\.kind), [.started, .worse, .ended])
        XCTAssertEqual(words[0].words, "gaps started: 3 gaps this second, the longest 30 ms, on Ed on Opus")
        XCTAssertEqual(words[1].words, "gaps got worse: a 60 ms gap, the longest in this run (it was 30 ms)")
        XCTAssertEqual(words[2].words, "gaps ended after 2 minutes: 180 gaps, the longest 60 ms, on Ed on Opus")
        XCTAssertEqual(GapEpisodes.duration(3_725), "62 minutes", "minutes until an hour and a half")
        XCTAssertEqual(GapEpisodes.duration(5_525), "1 hour 32 minutes")
        XCTAssertEqual(GapEpisodes.duration(1), "1 second")
        // Still going: said once an hour, not every second.
        let steady = GapEpisodes()
        var said: [GapEpisodes.Kind] = []
        for s in 0..<7_300 { said += steady.second(t0.addingTimeInterval(TimeInterval(s)), newGaps: 1).map(\.kind) }
        XCTAssertEqual(said, [.started, .stillGoing, .stillGoing])
    }

    func testADisconnectSaysWhyAndEveryConnectionEndsWithASummary() {
        let peers = ConnectionLog()
        func seen(_ state: ConnectionLog.State, selected: Bool = true, silentMs: UInt64? = nil, packets: Int = 100,
                  ping: Double? = 20) -> ConnectionLog.Seen {
            .init(key: "10.0.0.5", name: "Ed", selected: selected, state: state, pingMs: ping, silentMs: silentMs,
                  packets: packets, gaps: 1, filledIn: 2, lowestBufferMs: 12)
        }
        var lines = peers.second(t0, [seen(.pending)])
        XCTAssertTrue(lines.isEmpty, "nothing until it answers")
        lines = peers.second(t0.addingTimeInterval(1), [seen(.healthy)])
        XCTAssertEqual(lines, [.init(level: .info, text: "Ed connected", captureLookBack: nil)])
        for s in 2..<62 { XCTAssertTrue(peers.second(t0.addingTimeInterval(TimeInterval(s)), [seen(.healthy)]).isEmpty) }
        peers.networkChanged(t0.addingTimeInterval(55))
        for s in 62..<66 { _ = peers.second(t0.addingTimeInterval(TimeInterval(s)), [seen(.stale, packets: 0)]) }
        lines = peers.second(t0.addingTimeInterval(66), [seen(.unreachable, silentMs: 6_000, packets: 0)])
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].level, .warn)
        XCTAssertEqual(lines[0].captureLookBack, ConnectionLog.disconnectLookBack, "a disconnect keeps the five minutes before it")
        XCTAssertEqual(lines[0].text, "Ed disconnected: it stopped answering - no reply to its pings for 6 seconds, "
            + "and no sound for 5 seconds; this Mac's network changed 11 seconds before")
        XCTAssertTrue(lines[1].text.hasPrefix("Ed: connection ended (disconnected) after 65 seconds: 64 audible gaps, "
            + "6,000 packets, 128 filled in, "), lines[1].text)
        XCTAssertTrue(lines[1].text.contains("buffer at its lowest 12 ms") && lines[1].text.hasSuffix("ping 20 ms on average and 20 ms at worst"),
                      lines[1].text)
        lines = peers.second(t0.addingTimeInterval(96), [seen(.healthy)])
        XCTAssertEqual(lines.map(\.text), ["Ed connected, back after 30 seconds"])
        lines = peers.second(t0.addingTimeInterval(100), [seen(.healthy, selected: false)])
        XCTAssertEqual(lines.first?.text, "Ed disconnected: you unticked it")
        XCTAssertTrue(lines.last!.text.hasPrefix("Ed: connection ended (you unticked it) after 4 seconds"), lines.last!.text)
        _ = peers.second(t0.addingTimeInterval(110), [seen(.healthy)])
        XCTAssertEqual(peers.connectedCount, 1)
        let closing = peers.endAll("RemSound stopped", t0.addingTimeInterval(120))
        XCTAssertEqual(closing.count, 1)
        XCTAssertTrue(closing[0].text.hasPrefix("Ed: connection ended (RemSound stopped) after 10 seconds"), closing[0].text)
        XCTAssertEqual(peers.connectedCount, 0)
    }

    func testTheLogPointsAtTheSecondsItKept() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jamreadings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = JamLog(directory: dir, prefix: "RemSound-Mac", machine: "Andre", now: t0)
        XCTAssertNil(log.capture(lookBack: 30, at: t0), "nothing to keep before anything is measured")
        for s in 0..<120 { log.readings(row(s), [row(s, stream: "Ed/7")], at: t0.addingTimeInterval(TimeInterval(s))) }
        let words = try XCTUnwrap(log.capture(lookBack: 30, at: t0.addingTimeInterval(119)))
        XCTAssertTrue(words.hasPrefix("every second from ") && words.hasSuffix(" goes in \(log.readingsName)"), words)
        log.close(at: t0.addingTimeInterval(120))
        let readings = try String(contentsOf: try XCTUnwrap(log.currentReadingsFile), encoding: .utf8)
        XCTAssertEqual(log.currentReadingsFile?.lastPathComponent, log.readingsName)
        XCTAssertEqual(readings.split(separator: "\n").filter { $0.contains(",second,") }.count, 62,
                       "the 31 seconds kept, machine and stream")
        // Switched off: what waits is let go.
        let off = JamLog(directory: dir, prefix: "Off", now: t0)
        for s in 0..<30 { off.readings(row(s), at: t0.addingTimeInterval(TimeInterval(s))) }
        off.close(keepReadings: false)
        XCTAssertNil(off.currentReadingsFile, "nothing reaches the readings file once logging is switched off")
    }
}
