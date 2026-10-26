import Foundation
import XCTest

@testable import RemSoundJam

final class SpeedAndLogTests: XCTestCase {
    let relay = JamEndpoint("192.168.1.82", 47830)
    let ed = UUID()
    let carol = UUID()

    func roster(_ entries: [(UUID, String, Bool)], v1Paired: Bool = false) -> [UInt8] {
        var p = JamWire.header(7, version: 2)
        p += [UInt8](repeating: 0, count: 16)
        p.append(UInt8(entries.count))
        for (id, name, ticks) in entries {
            p += JamWire.bytes(of: id)
            p += RelayGroupClient.encodeName(name)
            p.append(ticks ? 1 : 0)
        }
        p.append(v1Paired ? 1 : 0)
        return p
    }

    // MARK: Jamulus-style: who gets it

    func testJamulusStyleGoesToThoseWhoCanPlayItAndThroughAServerOnlyWhenEveryoneThereCan() {
        let direct = JamEndpoint("192.168.1.95", 47830)
        let other = JamEndpoint("192.168.1.15", 47830)
        var registry = CanDecodeRegistry()
        registry.note(direct.address, now: 10)
        XCTAssertEqual(JamulusStyle.targets([direct, other], group: nil) { registry.canDecode($0, now: 11) }, [direct],
                       "a direct peer that said so, and nobody else")
        XCTAssertTrue(JamulusStyle.targets([direct], group: nil) { registry.canDecode($0, now: 14) }.isEmpty,
                      "not said for 3 s: forgotten")

        let group = RelayGroupClient(clientId: UUID())
        group.send = { _, _ in }
        group.setIdentity(name: "Andre", fingerprint: [1, 2, 3, 4, 5, 6, 7, 8])
        group.connect(relay)
        _ = group.handleInbound(roster([(ed, "ED_DT", true), (carol, "Carol", true)]), from: relay, now: 1)
        group.setTicked([ed, carol])
        let edAt = group.members.first { $0.name == "ED_DT" }!.address.address
        let carolAt = group.members.first { $0.name == "Carol" }!.address.address
        var said = CanDecodeRegistry()
        said.note(edAt, now: 1)
        XCTAssertTrue(JamulusStyle.targets([relay], group: group) { said.canDecode($0, now: 1.5) }.isEmpty,
                      "EVERYONE OR NOBODY: Carol hears us through the server and cannot play it")
        said.note(carolAt, now: 1)
        XCTAssertEqual(JamulusStyle.targets([relay], group: group) { said.canDecode($0, now: 1.5) }, [relay],
                       "everyone there can: the server is sent it")
        _ = group.handleInbound(roster([(ed, "ED_DT", true), (carol, "Carol", true)], v1Paired: true), from: relay, now: 2)
        XCTAssertTrue(JamulusStyle.targets([relay], group: group) { said.canDecode($0, now: 2) }.isEmpty,
                      "A PHONE PAIRED there reads the same stream: nobody is sent it")
    }

    func testTheEncodersSettingsAreWindows() {
        XCTAssertEqual(JamulusStyle.bitrate(frames: 64), 320_000)
        XCTAssertEqual(JamulusStyle.bitrate(frames: 128), 256_000)
        XCTAssertEqual(JamulusStyle.maxBytes(frames: 64), 53, "320 kbps over 1.33 ms")
        XCTAssertEqual(JamulusStyle.codec, 3)
        XCTAssertEqual(JamulusStyle.formatLabFlagsOffset, 33)
    }

    // MARK: the log

    func testTheLogWritesDatedFilesInPartsAndForgetsOldOnes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jamlog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // An old log and an old readings file from three weeks ago, and somebody else's file.
        let old = dir.appendingPathComponent("RemSound-Mac-2026-09-01-1000-Andre.log")
        let oldReadings = dir.appendingPathComponent("RemSound-Mac-2026-09-01-1000-Andre-readings.csv")
        for file in [old, oldReadings] {
            FileManager.default.createFile(atPath: file.path, contents: Data("old".utf8))
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-21 * 86_400)], ofItemAtPath: file.path)
        }
        let theirs = dir.appendingPathComponent("notes.txt")
        FileManager.default.createFile(atPath: theirs.path, contents: Data("keep".utf8))

        let started = Date()
        let log = JamLog(directory: dir, prefix: "RemSound-Mac", machine: "Andre", about: "RemSound for Mac 6.2.4", maxBytes: 600,
                         now: started)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "a log older than 14 days is removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldReadings.path), "and an old readings file with it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: theirs.path), "and nothing that is not ours")
        log.event("metronome: started\twith a tab\nand a new line")
        log.event(.warn, "Peer", "Ed disconnected: it stopped answering")
        log.flush()
        let first = try XCTUnwrap(log.currentFile)
        let named = DateFormatter()
        named.locale = Locale(identifier: "en_GB"); named.dateFormat = "yyyy-MM-dd-HHmm"
        XCTAssertEqual(first.lastPathComponent, "RemSound-Mac-\(named.string(from: started))-Andre.log",
                       "named by when it started, date first, then whose")
        let lines = try String(contentsOf: first, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3, "the heading, then one line each")
        XCTAssertTrue(lines[0].hasPrefix("INFO\t") && lines[0].contains("\tLog: RemSound for Mac 6.2.4 log for Andre, started ")
                      && lines[0].contains("-readings.csv"), "the first line says what, whose, when and where the readings are: \(lines[0])")
        XCTAssertTrue(lines[1].hasPrefix("INFO\t") && lines[1].hasSuffix("\tMetronome: started with a tab and a new line"),
                      "tabs and new lines taken out of the words, the category from how the line starts: \(lines[1])")
        XCTAssertTrue(lines[2].hasPrefix("WARN\t") && lines[2].hasSuffix("\tPeer: Ed disconnected: it stopped answering"), lines[2])

        // A second run in the same minute gets a name of its own.
        let again = JamLog(directory: dir, prefix: "RemSound-Mac", machine: "Andre", now: started)
        XCTAssertNotEqual(again.stem, log.stem)
        XCTAssertTrue(again.stem.hasSuffix("-2"), again.stem)

        for i in 0..<40 { log.event("metronome: tick \(i) " + String(repeating: "x", count: 40)) }
        log.close()
        XCTAssertTrue(log.currentFile!.lastPathComponent.contains("-part"),
                      "a full file goes on in the next part (\(log.currentFile!.lastPathComponent))")
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".log") {
            let size = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? Int ?? 0
            XCTAssertLessThanOrEqual(size, 600 + 200, "each part near its limit (\(name): \(size))")
        }
        log.event("metronome: after closing")
        log.flush()
        let all = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(log.stem) }
            .map { try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }.joined()
        XCTAssertFalse(all.contains("after closing"), "nothing reaches a closed log")
    }

    func testTheSecondLinesReadLikeWindows() {
        let line = JamLogLines.streams([
            JamLogLines.Stream(peer: "ED_DT (on the server)", stream: 59828, codec: "Jamulus-style", frames: 64, packets: 750,
                               maxGapMs: 3.4, concealed: 2, underruns: 1, queuedMs: 5, targetMs: 5),
        ], sending: "sending Jamulus-style to 1, ordinary to 0")
        XCTAssertEqual(line, "streams: sending Jamulus-style to 1, ordinary to 0; ED_DT (on the server) stream=59828 Jamulus-style 64 frames "
                       + "pkts=750 gap-peak=3ms concealed=2 underruns=1 queued=5ms target=5ms")
        XCTAssertEqual(JamLogLines.streams([], sending: "not sending"), "streams: not sending; nothing received")
        let total = JamLogLines.totalLatencyMs(captureMs: 1.3, packetMs: 1.3, rttMs: 20, bufferMs: 5, outputMs: 1.5)
        XCTAssertEqual(total, 19.1, accuracy: 0.001)
        XCTAssertEqual(JamLogLines.peer("Ed", rttMs: 20, totalMs: total), "Ed: ping 20 ms, total latency about 19 ms")
        XCTAssertEqual(JamLogLines.peer("Ed", rttMs: nil, totalMs: nil), "Ed: not measured yet")
    }
}
