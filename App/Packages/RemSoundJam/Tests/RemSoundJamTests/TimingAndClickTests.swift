import XCTest

@testable import RemSoundJam

final class TimingAndClickTests: XCTestCase {
    // MARK: the server's messages, byte for byte as the relay reads and writes them

    func testReportClaimSetAndGridAreTheRelaysLayout() {
        let report = ServerMetronomeWire.buildReport([CaptureReport(stream: 0x0102, sequence: 0x0304_0506, capturedUs: -2)])
        XCTAssertEqual(report, [1, 1, 0x02, 0x01, 0x06, 0x05, 0x04, 0x03, 0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
                       "[1][count] then stream u16, sequence u32, captured i64, little-endian")
        XCTAssertEqual(ServerMetronomeWire.buildReport(Array(repeating: CaptureReport(stream: 1, sequence: 1, capturedUs: 1), count: 20)).count,
                       2 + 16 * 14, "at most 16 in a report")
        XCTAssertEqual(ServerMetronomeWire.buildClaim(), [2])
        XCTAssertEqual(ServerMetronomeWire.buildRelease(), [3])
        XCTAssertEqual(ServerMetronomeWire.buildSet(running: true, milliBpm: 120_000, beatsPerBar: 3, beatUnit: 8),
                       [4, 1, 0xC0, 0xD4, 0x01, 0x00, 3, 8])
        // A grid as the relay packs it: [20][flags] master(16) then <IIBBIq> version, milli-bpm, per bar, unit, anchor beat, anchor.
        let master = UUID(uuidString: "0033A815-0B74-4F47-9EF6-88E4C064FC20")!
        var bytes: [UInt8] = [20, 1 | 2]
        bytes += JamWire.bytes(of: master)
        bytes.appendLE(UInt32(9)); bytes.appendLE(UInt32(90_000)); bytes += [4, 4]; bytes.appendLE(UInt32(8)); bytes.appendLE(Int64(123_456_789))
        let g = ServerMetronomeWire.readGrid(bytes)
        XCTAssertEqual(g, ServerGrid(running: true, measured: true, youLead: false, master: master,
                                     timeline: MetronomeTimeline(version: 9, running: true, milliBpm: 90_000, beatsPerBar: 4, beatUnit: 4, anchorBeat: 8, anchorTimeUs: 123_456_789)))
        XCTAssertEqual(ServerMetronomeWire.buildGrid(g!), bytes)
        var nonsense = bytes
        nonsense[26] = 0
        XCTAssertNil(ServerMetronomeWire.readGrid(nonsense), "no beats in a bar: not a beat")
    }

    func testMetronomeMessagesAreTheWindowsLayout() {
        var offer = MetronomeMessage(.offer, sessionId: 0x0102_0304_0506_0708, masterName: "Ed")
        XCTAssertEqual(offer.plaintext(), [1, 1, 8, 7, 6, 5, 4, 3, 2, 1, 2] + Array("Ed".utf8))
        XCTAssertEqual(MetronomeMessage.parse(offer.plaintext()), offer)
        offer.masterName = String(repeating: "é", count: 40)
        XCTAssertEqual(MetronomeMessage.parse(offer.plaintext())?.masterName, String(repeating: "é", count: 32), "cut to 64 bytes, whole characters")
        for kind in [MetronomeKind.accept, .decline, .release, .leave] {
            let m = MetronomeMessage(kind, sessionId: 42)
            XCTAssertEqual(m.plaintext().count, 10)
            XCTAssertEqual(MetronomeMessage.parse(m.plaintext()), m)
        }
        var state = MetronomeMessage(.state, sessionId: 7)
        state.state = MetronomeTimeline(version: 3, running: true, milliBpm: 120_000, beatsPerBar: 4, beatUnit: 4, anchorBeat: 16, anchorTimeUs: 9_000_000)
        XCTAssertEqual(state.plaintext().count, 37)
        XCTAssertEqual(MetronomeMessage.parse(state.plaintext()), state)
        XCTAssertNil(MetronomeMessage.parse([2, 1, 0, 0, 0, 0, 0, 0, 0, 0]), "another version")
        XCTAssertNil(MetronomeMessage.parse([1, 99, 0, 0, 0, 0, 0, 0, 0, 0]), "an unknown kind")
        var guardian = MetronomeReplayGuard()
        let seal: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
        XCTAssertTrue(guardian.firstTime(sealedPayload: seal))
        XCTAssertFalse(guardian.firstTime(sealedPayload: seal), "a replayed seal does nothing")
    }

    /// Windows' tempo range, 30 to 300 beats a minute: asked for more or less, the metronome plays the nearest end, and a
    /// beat grid outside it is not a beat. A message cut short is nothing, never a guess.
    func testTheTempoStaysBetweenThirtyAndThreeHundredAndAShortMessageIsNothing() {
        var settings = ServerMetronome.Settings()
        for (asked, played) in [(10, 30), (30, 30), (120, 120), (300, 300), (999, 300)] {
            settings.bpm = asked
            XCTAssertEqual(settings.clampedBpm, played, "asked for \(asked)")
        }
        var grid = MetronomeTimeline.stopped()
        for (milliBpm, valid) in [(29_999, false), (30_000, true), (300_000, true), (300_001, false)] {
            grid.milliBpm = UInt32(milliBpm)
            XCTAssertEqual(grid.isValid, valid, "\(milliBpm) milli-beats a minute")
        }
        var state = MetronomeMessage(.state, sessionId: 7)
        state.state = MetronomeTimeline(version: 3, running: true, milliBpm: 120_000, beatsPerBar: 4, beatUnit: 4, anchorBeat: 16, anchorTimeUs: 9_000_000)
        let whole = state.plaintext()
        for cut in 0..<whole.count { XCTAssertNil(MetronomeMessage.parse(Array(whole.prefix(cut))), "\(cut) of \(whole.count) bytes") }
        let offer = MetronomeMessage(.offer, sessionId: 1, masterName: "Andre").plaintext()
        XCTAssertNil(MetronomeMessage.parse(Array(offer.dropLast())), "a name shorter than its length byte")
    }

    // MARK: capture times

    /// The send timer runs late by up to 4 ms most times; the capture times must be the input's all the same - exact -
    /// or the server would keep the latest-running reading as this machine's delay.
    func testCaptureTimesLeaveOutTheThreadsLateness() {
        var timeline = CaptureTimeline()
        var rng = SystemRandomNumberGenerator()
        let start: Int64 = 900_000_000, inputDelayUs: Int64 = 12_000
        var worst: Int64 = 0
        for block in 0..<600 {
            let frame = Int64(block) * 120                                   // 2.5 ms packets
            let trueCapture = start + frame * 1_000_000 / 48_000
            let late: Int64 = block % 9 == 0 ? 0 : Int64.random(in: 0..<4_000, using: &rng)
            let reading = trueCapture + late                                   // when our code saw it, less the input delay
            let got = timeline.captureTime(frameIndex: frame, readingUs: reading)
            if block > 10 { worst = max(worst, abs(got - trueCapture)) }
            _ = inputDelayUs
        }
        XCTAssertLessThanOrEqual(worst, 1, "within a microsecond however late the thread ran (worst \(worst) us)")
    }

    func testCaptureTimesFollowADriftingCardAndARestart() {
        var timeline = CaptureTimeline()
        // The card runs 100 ppm slow against this clock for 60 s: each reading's origin creeps later.
        var worst: Double = 0
        for block in 0..<24_000 {
            let frame = Int64(block) * 120
            let trueCapture = Double(1_000_000) + Double(frame) * 1_000_000 / 48_000 * 1.0001
            let got = timeline.captureTime(frameIndex: frame, readingUs: Int64(trueCapture.rounded()))
            worst = max(worst, abs(Double(got) - trueCapture))
        }
        XCTAssertLessThan(worst, 500, "the two-bucket reading follows the drift (worst \(worst) us)")
        // A capture that restarts (frames jump back while time goes on): the timeline starts again at once.
        let after = timeline.captureTime(frameIndex: 0, readingUs: 200_000_000)
        XCTAssertEqual(after, 200_000_000)
    }

    // MARK: clicks

    func testEachClickLandsOnItsSampleAcrossBlocksAndIsNeverPlayedTwice() {
        let sound = MetronomeClickSound(accent: [1, 0.5], normal: [0.25, 0.125])
        let player = MetronomeClickPlayer(sound: sound, gain: 1)
        // 120 bpm: beats every 500 ms from 1 s; blocks of 256 frames (5.333 ms).
        let t = MetronomeTimeline(version: 1, running: true, milliBpm: 120_000, beatsPerBar: 4, beatUnit: 4, anchorBeat: 0, anchorTimeUs: 1_000_000)
        let schedule = MetronomeSchedule(current: t, previous: nil, audible: true)
        var onsets: [(Double, Float)] = []
        var heard: Int64 = 900_000
        var frameAt: Int64 = 0
        var before: Float = 0
        for _ in 0..<500 {
            var block = [Float](repeating: 0, count: 512)
            player.render(into: &block, heardAtUs: heard, schedule: schedule)
            for f in 0..<256 {
                // A click's first sample: loud, after silence.
                if block[2 * f] > 0.2 && before == 0 {
                    onsets.append((Double(900_000) + Double(frameAt + Int64(f)) * 1_000_000 / 48_000, block[2 * f]))
                }
                before = block[2 * f]
            }
            frameAt += 256
            heard = 900_000 + frameAt * 1_000_000 / 48_000
        }
        XCTAssertEqual(onsets.count, 6, "500 blocks run to 3.57 s: beats at 1.0, 1.5, 2.0, 2.5, 3.0 and 3.5 s")
        for (i, (time, level)) in onsets.enumerated() {
            XCTAssertEqual(time, 1_000_000 + Double(i) * 500_000, accuracy: 21, "on its sample")
            XCTAssertEqual(level, i % 4 == 0 ? 1 : 0.25, "the bar's first beat accented")
        }
        // The next block's time estimate steps back 2 ms: the beat just played is not played again.
        let again = MetronomeClickPlayer(sound: sound, gain: 1)
        var a = [Float](repeating: 0, count: 512)
        XCTAssertEqual(again.render(into: &a, heardAtUs: 998_000, schedule: schedule).count, 1)
        var b = [Float](repeating: 0, count: 512)
        XCTAssertEqual(again.render(into: &b, heardAtUs: 998_500, schedule: schedule).count, 0)
    }

    func testATempoChangeWaitsForTheBarLine() {
        let old = MetronomeTimeline(version: 1, running: true, milliBpm: 120_000, beatsPerBar: 4, beatUnit: 4, anchorBeat: 0, anchorTimeUs: 1_000_000)
        // At 2.7 s the first beat 0.4 s ahead is 3.5 s, into a bar: the change waits for the bar line at 5.0 s.
        let changed = old.change(nowUs: 2_700_000, milliBpm: 60_000, signature: .default)
        XCTAssertEqual(changed.anchorBeat, 8, "at least 0.4 s ahead, on the bar line")
        XCTAssertEqual(changed.anchorTimeUs, 5_000_000)
        let beats = MetronomeSchedule(current: changed, previous: old, audible: true).beats(fromUs: 3_000_000, toUs: 7_100_000).map(\.timeUs)
        XCTAssertEqual(beats, [3_000_000, 3_500_000, 4_000_000, 4_500_000, 5_000_000, 6_000_000, 7_000_000],
                       "the old tempo until the bar line, the new after it")
    }
}
