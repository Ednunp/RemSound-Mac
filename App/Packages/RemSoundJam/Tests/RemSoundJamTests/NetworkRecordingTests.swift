import Foundation
import XCTest

@testable import RemSoundJam

/// The last minute of the network, saved in the Windows app's own format.
final class NetworkRecordingTests: XCTestCase {
    /// A small recording as the Mac writes it. The Windows gate loads this same text (SIMULATOR REPLAY, "a recording made
    /// by the Mac port"), so the two ports are pinned to one format from both sides: change it in neither.
    static let crossPortText = """
        # RemSound network recording 1
        machine: Andres-Mac
        saved: 2026-09-30 18:00:00
        RemSound: Mac 0.1.47
        configuration: Mac, Core Audio
        receive card frames: 64
        buffer ms: 5
        buffer ASIO ms: 5
        one-way ms: 4.5
        live seconds: 2.0
        live audible gaps: 1
        live late or doubled dropped: 0
        live gaps not repaired: 0
        live concealed: 2
        stream 0: from 192.168.1.82:50123 id 59828 lane unknown codec 3 frame 64 format 48000 Hz, 2 channels, Jamulus-style, 64 frames
        stream 1: from 192.168.1.82:50123 id 4282 lane unknown codec 2 frame 120 format 48000 Hz, 2 channels, Opus, 120 frames
        packets: ms stream sequence bytes
        0.000 0 100 60
        1.333 0 101 60
        2.500 1 7 148
        2.667 0 102 60
        4.125 0 104 61

        """

    func recorded() -> NetworkRecording {
        var recorder = NetworkRecorder()
        recorder.enabled = true
        recorder.noteSecond(.init(at: 9.5, audibleGaps: 3, lateOrDoubledDropped: 1, concealed: 10, gapsNotRepaired: 0))
        let from = "192.168.1.82:50123"
        recorder.note(from: from, streamId: 59828, sequence: 100, bytes: 60, now: 10.0)
        recorder.note(from: from, streamId: 59828, sequence: 101, bytes: 60, now: 10.001333)
        recorder.note(from: from, streamId: 4282, sequence: 7, bytes: 148, now: 10.0025)
        recorder.note(from: from, streamId: 59828, sequence: 102, bytes: 60, now: 10.002667)
        recorder.note(from: from, streamId: 59828, sequence: 104, bytes: 61, now: 10.004125)
        recorder.noteSecond(.init(at: 10.5, audibleGaps: 3, lateOrDoubledDropped: 1, concealed: 11, gapsNotRepaired: 0))
        recorder.noteSecond(.init(at: 11.5, audibleGaps: 4, lateOrDoubledDropped: 1, concealed: 12, gapsNotRepaired: 0))
        let facts = [
            NetworkRecording.Fact("machine", "Andres-Mac"), .init("saved", "2026-09-30 18:00:00"), .init("RemSound", "Mac 0.1.47"),
            .init("configuration", "Mac, Core Audio"), .init("receive card frames", "64"), .init("buffer ms", "5"),
            .init("buffer ASIO ms", "5"), .init("one-way ms", "4.5"),
        ]
        return recorder.take(facts: facts) { _, id in
            id == 59828
                ? .init(lane: "unknown", format: "48000 Hz, 2 channels, Jamulus-style, 64 frames", codec: 3, frameSamples: 64)
                : .init(lane: "unknown", format: "48000 Hz, 2 channels, Opus, 120 frames", codec: 2, frameSamples: 120)
        }
    }

    func testTheFileIsTheWindowsAppsFormatLineForLine() {
        XCTAssertEqual(recorded().text(), Self.crossPortText)
    }

    func testWhatIsWrittenReadsBackTheSame() throws {
        let rec = recorded()
        let back = try NetworkRecording.read(rec.text())
        XCTAssertEqual(back.streams, rec.streams)
        XCTAssertEqual(back.facts, rec.facts)
        XCTAssertEqual(back.packets.count, rec.packets.count)
        for (a, b) in zip(back.packets, rec.packets) {
            XCTAssertEqual(a.ms, b.ms, accuracy: 0.0005)
            XCTAssertEqual(a.stream, b.stream)
            XCTAssertEqual(a.sequence, b.sequence)
            XCTAssertEqual(a.bytes, b.bytes)
        }
        XCTAssertEqual(back.fact("LIVE CONCEALED"), "2", "a fact is found whatever its case")
        XCTAssertEqual(back.streams[0].format, "48000 Hz, 2 channels, Jamulus-style, 64 frames", "a format keeps its spaces and commas")
        // And a file with Windows line endings reads the same.
        XCTAssertEqual(try NetworkRecording.read(rec.text().replacingOccurrences(of: "\n", with: "\r\n")).packets.count, 5)
    }

    func testTheLiveFiguresAreTheCountsChangeAcrossThePacketsOwnSpan() {
        let rec = recorded()
        // From the counts at 9.5 s (the last before the first packet at 10.0) to the newest at 11.5 s.
        XCTAssertEqual(rec.fact("live seconds"), "2.0")
        XCTAssertEqual(rec.fact("live audible gaps"), "1")
        XCTAssertEqual(rec.fact("live concealed"), "2")
        XCTAssertEqual(rec.fact("live late or doubled dropped"), "0")
        // With fewer than two counts there is nothing to say, and nothing is said.
        var recorder = NetworkRecorder()
        recorder.enabled = true
        recorder.note(from: "a:1", streamId: 1, sequence: 1, bytes: 10, now: 1)
        recorder.noteSecond(.init(at: 1.5, audibleGaps: 0, lateOrDoubledDropped: 0, concealed: 0, gapsNotRepaired: 0))
        XCTAssertNil(recorder.take(facts: []) { _, _ in nil }.fact("live seconds"))
    }

    func testAnythingThatIsNotARecordingIsRefusedWithItsLine() {
        XCTAssertThrowsError(try NetworkRecording.read("# some other file\npackets: ms stream sequence bytes\n")) {
            XCTAssertEqual($0 as? NetworkRecording.ReadError, .notARecording)
        }
        let good = recorded().text()
        XCTAssertThrowsError(try NetworkRecording.read(good.replacingOccurrences(of: "2.500 1 7 148", with: "2.500 5 7 148"))) {
            XCTAssertEqual($0 as? NetworkRecording.ReadError, .badLine(20, "2.500 5 7 148"), "a packet on a stream that was never listed")
        }
        XCTAssertThrowsError(try NetworkRecording.read(good.replacingOccurrences(of: "1.333 0 101 60", with: "1.333 0 101"))) {
            XCTAssertEqual($0 as? NetworkRecording.ReadError, .badLine(19, "1.333 0 101"))
        }
        XCTAssertThrowsError(try NetworkRecording.read(good.replacingOccurrences(of: "stream 1: from", with: "stream 3: from"))) {
            guard case .badLine(16, _)? = $0 as? NetworkRecording.ReadError else { return XCTFail("streams must be numbered from 0 in order: \($0)") }
        }
        XCTAssertThrowsError(try NetworkRecording.read("# RemSound network recording 1\nmachine: x\n")) {
            XCTAssertEqual($0 as? NetworkRecording.ReadError, .noPackets)
        }
        XCTAssertThrowsError(try NetworkRecording.read("# RemSound network recording 1\nno colon here\npackets: ms stream sequence bytes\n")) {
            XCTAssertEqual($0 as? NetworkRecording.ReadError, .badLine(2, "no colon here"))
        }
    }

    func testOffNothingIsKeptAndNothingAllocated() {
        var recorder = NetworkRecorder()
        recorder.note(from: "a:1", streamId: 1, sequence: 1, bytes: 10, now: 1)
        recorder.noteSecond(.init(at: 1, audibleGaps: 0, lateOrDoubledDropped: 0, concealed: 0, gapsNotRepaired: 0))
        XCTAssertEqual(recorder.held, 0)
        XCTAssertEqual(recorder.capacity, 0)
        XCTAssertTrue(recorder.take(facts: [.init("machine", "x")]) { _, _ in nil }.packets.isEmpty)
    }

    func testAMinuteIsKeptHoweverFastThePacketsCome() {
        // 750 packets a second (Jamulus-style) for 100 seconds: the store grows to hold a minute and no more.
        var recorder = NetworkRecorder()
        recorder.enabled = true
        var sequence: UInt32 = 0
        var t = 0.0
        while t < 100 {
            recorder.note(from: "10.0.0.1:5000", streamId: 9, sequence: sequence, bytes: 60, now: t)
            sequence += 1
            t += 1.0 / 750
        }
        XCTAssertGreaterThanOrEqual(recorder.held, 45_000, "a minute at 750 a second is 45,000 packets")
        XCTAssertLessThanOrEqual(recorder.capacity, 65_536, "and the store stops growing once it holds a minute")
        let rec = recorder.take(facts: []) { _, _ in nil }
        XCTAssertEqual(rec.packets.count, 45_000, accuracy: 2)
        XCTAssertEqual(rec.packets[0].ms, 0, "times count from the first packet kept")
        XCTAssertEqual(rec.packets.last!.ms, 60_000, accuracy: 2)
        XCTAssertEqual(rec.packets.last!.sequence, sequence - 1, "the newest packet is the last line")
        XCTAssertEqual(rec.packets[1].sequence, rec.packets[0].sequence + 1, "in the order they came")
        XCTAssertEqual(rec.streams.count, 1)
        XCTAssertEqual(rec.streams[0].format, "no Format packet seen", "a stream nothing is known of says so")
        XCTAssertEqual(rec.streams[0].codec, -1)
    }

    func testAFewPacketsAMinuteApartKeepOnlyTheLastMinute() {
        var recorder = NetworkRecorder()
        recorder.enabled = true
        recorder.note(from: "a:1", streamId: 1, sequence: 1, bytes: 10, now: 0)
        recorder.note(from: "b:2", streamId: 2, sequence: 5, bytes: 10, now: 100)
        recorder.note(from: "b:2", streamId: 2, sequence: 6, bytes: 10, now: 130)
        let rec = recorder.take(facts: []) { _, _ in nil }
        XCTAssertEqual(rec.packets.map(\.sequence), [5, 6], "the packet from 130 seconds ago is not in the last minute")
        XCTAssertEqual(rec.streams.map(\.from), ["b:2"], "and nor is its stream: streams are numbered from 0 as they first appear in the minute")
        XCTAssertEqual(rec.packets.map(\.stream), [0, 0])
        XCTAssertEqual(rec.packets[1].ms, 30_000, accuracy: 0.001)
    }

    func testTwoStreamsWithOneIdFromTwoPlacesAreTwoStreams() {
        var recorder = NetworkRecorder()
        recorder.enabled = true
        recorder.note(from: "a:1", streamId: 7, sequence: 1, bytes: 10, now: 1)
        recorder.note(from: "b:1", streamId: 7, sequence: 1, bytes: 10, now: 1.001)
        recorder.note(from: "a:1", streamId: 7, sequence: 2, bytes: 10, now: 1.002)
        let rec = recorder.take(facts: []) { _, _ in nil }
        XCTAssertEqual(rec.streams.map(\.from), ["a:1", "b:1"])
        XCTAssertEqual(rec.packets.map(\.stream), [0, 1, 0])
    }

    func testAFactIsOneLineAndTheFileIsNamedAsTheWindowsAppNamesIts() {
        XCTAssertEqual(NetworkRecording.Fact("machine", "Andre's\nMac").value, "Andre's Mac")
        let date = Date(timeIntervalSince1970: 1_790_791_200)   // 2026-09-30 18:00:00 UTC
        XCTAssertEqual(NetworkRecorder.fileName(machine: "Andre's Mac", at: date, timeZone: TimeZone(secondsFromGMT: 0)!),
                       "RemSound-network-AndresMac-20260930-180000.txt")
        XCTAssertEqual(NetworkRecorder.fileName(machine: "", at: date, timeZone: TimeZone(secondsFromGMT: 0)!),
                       "RemSound-network-Mac-20260930-180000.txt")
    }
}
