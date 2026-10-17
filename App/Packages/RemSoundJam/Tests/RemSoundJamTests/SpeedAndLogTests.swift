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
        // An old file from three weeks ago, and somebody else's file.
        let old = dir.appendingPathComponent("RemSound-Mac-20260901-100000-1.log")
        FileManager.default.createFile(atPath: old.path, contents: Data("old".utf8))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-21 * 86_400)], ofItemAtPath: old.path)
        let theirs = dir.appendingPathComponent("notes.txt")
        FileManager.default.createFile(atPath: theirs.path, contents: Data("keep".utf8))

        let log = JamLog(directory: dir, prefix: "RemSound-Mac", maxBytes: 400)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "a log older than 14 days is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: theirs.path), "and nothing that is not ours")
        log.event("metronome: started\twith a tab\nand a new line")
        log.snapshot("streams: nothing received")
        log.flush()
        let first = try XCTUnwrap(log.currentFile)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("RemSound-Mac-") && first.lastPathComponent.hasSuffix("-1.log"))
        let text = try String(contentsOf: first, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "one line each, tabs and new lines taken out of the words")
        XCTAssertTrue(lines[0].hasPrefix("EVT\t") && lines[0].hasSuffix("\tmetronome: started with a tab and a new line"), String(lines[0]))
        XCTAssertTrue(lines[1].hasPrefix("SNAP\t"))
        for _ in 0..<20 { log.snapshot(String(repeating: "x", count: 40)) }
        log.close()
        XCTAssertFalse(log.currentFile!.lastPathComponent.hasSuffix("-1.log"),
                       "a full file goes on in the next part (\(log.currentFile!.lastPathComponent))")
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".log") {
            let size = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? Int ?? 0
            XCTAssertLessThanOrEqual(size, 400 + 200, "each part near its limit (\(name): \(size))")
        }
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
