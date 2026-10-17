import Foundation
import XCTest

@testable import RemSoundJam
@testable import RemSoundSim

/// Recorded networks, replayed through the Mac's receive path (Windows' SIMULATOR REPLAY and CALIBRATION): the Windows
/// simulator's own seed recording, and a Mac run recorded and replayed, which must hear what it heard.
final class ReplayTests: XCTestCase {
    static let recordings = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Recordings")

    func lumpyLaptop(_ name: String) -> MacScenario {
        var s = MacScenario(name)
        s.network = .laptopLumps
        s.sendCard = SimCard(frames: 120, jitterMs: 0.05)   // 2.5 ms packets, as the recording's
        s.receiveCard = SimCard(frames: 32, jitterMs: 0.05)
        s.mixFrames = 96
        s.bufferMs = 10
        s.seconds = 60
        return s
    }

    func testTheWindowsSimulatorsSeedRecordingReplaysThroughTheMac() throws {
        let text = try String(contentsOf: Self.recordings.appendingPathComponent("simulated-laptop-lumps-asio-10ms.txt"), encoding: .utf8)
        let rec = try NetworkRecording.read(text)
        let replay = try NetworkReplay.from(rec)
        XCTAssertEqual(replay.period, 0.0025, accuracy: 0.0001, "2.5 ms packets")
        XCTAssertGreaterThan(replay.places, 20_000)
        var s = lumpyLaptop("the Windows seed, replayed at 10 ms")
        s.network = .replaying(replay, oneWayMs: 0.3)
        let tight = MacSimulation.run(s)
        XCTAssertGreaterThan(tight.underruns, 0, "a lumpy laptop at 10 ms breaks up, as it did on Windows: \(tight.describe)")
        s.name = "the same at 60 ms"
        s.bufferMs = 60
        let roomy = MacSimulation.run(s)
        XCTAssertLessThan(roomy.underruns, tight.underruns, "and less with room for the lumps: \(roomy.describe)")
        XCTAssertLessThan(roomy.packetsLost, 10)
    }

    func testAMacRunRecordedAndReplayedHearsWhatItHeard() throws {
        var s = lumpyLaptop("lumps at 10 ms, recorded")
        s.recordNetwork = true
        let live = MacSimulation.run(s)
        let rec = try XCTUnwrap(live.recording)
        XCTAssertGreaterThan(Int(rec.fact("live audible gaps") ?? "0") ?? 0, 2, "premise: break-ups to agree about: \(live.describe)")
        // The file round trip, as it would go through Dropbox.
        let back = try NetworkRecording.read(rec.text())
        var again = s
        again.recordNetwork = false
        again.network = .replaying(try NetworkReplay.from(back), oneWayMs: s.network.baseMs)
        let replayed = MacSimulation.run(again)
        let verdict = try XCTUnwrap(MacCalibration.judge(back, simulatedGaps: replayed.underruns))
        XCTAssertTrue(verdict.agrees, verdict.describe)

        // The same recording saying its receiver heard far more is a disagreement.
        var doctored = back
        let at = try XCTUnwrap(doctored.facts.firstIndex { $0.key == "live audible gaps" })
        doctored.facts[at].value = String(Int(verdict.live) * 4 + 20)
        XCTAssertFalse(try XCTUnwrap(MacCalibration.judge(doctored, simulatedGaps: replayed.underruns)).agrees)
        // One with no live figures is not judged.
        var bare = back
        bare.facts.removeAll { $0.key.hasPrefix("live") }
        XCTAssertNil(MacCalibration.judge(bare, simulatedGaps: 0))
    }

    func testAReplayAtAnotherPacketRateKeepsTheBurstsInTime() throws {
        var s = lumpyLaptop("lumps, recorded")
        s.seconds = 20
        s.recordNetwork = true
        let rec = try XCTUnwrap(MacSimulation.run(s).recording)
        var other = s
        other.recordNetwork = false
        other.sendCard = SimCard(frames: 480, jitterMs: 0.05)   // 10 ms packets
        other.packetFrames = 233
        other.bufferMs = 40
        other.network = .replaying(try NetworkReplay.from(rec), oneWayMs: 0.3)
        let r = MacSimulation.run(other)
        XCTAssertGreaterThan(r.findings.clicksHeard, 30, "played at another packet rate: \(r.describe)")
    }
}
