import Foundation
import XCTest

@testable import RemSoundJam
@testable import RemSoundSim

/// THE MAC SIMULATOR's runs (the Windows gate's SIMULATOR steps, as far as the Mac has what they check): the Mac's own
/// receive path - StreamOrder, PlayoutQueue, the auto-tune, the mix timing, OutputClock - fed by a simulated sender over a
/// simulated network, and listened to at a simulated output card.
final class MacSimulatorTests: XCTestCase {
    /// A jamming sender: a 64-frame card, as an ASIO interface or a Mac at 64 frames; the Mac playing Jamulus-style.
    func jamming(_ name: String, bufferMs: Int) -> MacScenario {
        var s = MacScenario(name)
        s.sendCard = SimCard(frames: 64, jitterMs: 0.05)
        s.receiveCard = SimCard(frames: 64, jitterMs: 0.05)
        s.mixFrames = 96
        s.bufferMs = bufferMs
        return s
    }

    func testTheSameRunTwiceIsTheSameToTheSample() {
        var s = MacScenario("determinism")
        s.network = .internet
        s.seconds = 6
        s.keepAudio = true
        let a = MacSimulation.run(s), b = MacSimulation.run(s)
        XCTAssertTrue(a.audio == b.audio, "the same seed reproduces every output sample")
        s.seed = 2
        XCTAssertTrue(MacSimulation.run(s).audio != a.audio, "and another seed is another run")
    }

    func testAPerfectOrWiredNetworkPlaysCleanAndTheDelayIsTheSumOfItsParts() {
        for network in [SimNetwork.perfect, .wired] {
            var s = MacScenario("everyday, \(network.name), 20 ms")
            s.network = network
            s.seconds = 20
            let r = MacSimulation.run(s)
            XCTAssertTrue(r.findings.clean, r.describe)
            XCTAssertEqual(r.underruns, 0, r.describe)
            // Capture block 10 ms (the tone is sent a callback late) + the buffer, which plays from its target up to a
            // packet pair over it + a mix block + the measured 12 ms output target + the card's own block.
            XCTAssertEqual(r.findings.delayMedianMs, 58, accuracy: 6, r.describe)
            XCTAssertEqual(r.cushionFrames, 12 * 48)
        }
    }

    func testJammingAtFiveAndTenMillisecondsOnAWiredNetwork() {
        let ten = MacSimulation.run({ var s = jamming("jamming, wired, 10 ms", bufferMs: 10); s.network = .wired; s.seconds = 20; return s }())
        XCTAssertTrue(ten.findings.clean, ten.describe)
        XCTAssertLessThan(ten.findings.delayMedianMs, 27, "a 64-frame chain at 10 ms with the 8 ms output floor: \(ten.describe)")
        let five = MacSimulation.run({ var s = jamming("jamming, wired, 5 ms", bufferMs: 5); s.network = .wired; s.seconds = 20; return s }())
        XCTAssertLessThanOrEqual(five.findings.glitches, 2, five.describe)
        XCTAssertLessThan(five.findings.delayMedianMs, 21, five.describe)
    }

    func testTwoClocksApartAreFollowedAndTheBufferHeldWithoutAClick() {
        var s = MacScenario("the sender's clock 300 ppm fast, the Mac's card 200 ppm slow")
        s.sendCard.driftPpm = 300
        s.receiveCard.driftPpm = -200
        s.seconds = 60
        let r = MacSimulation.run(s)
        XCTAssertTrue(r.findings.clean, r.describe)
        XCTAssertEqual(r.clockPpmBySecond.last??.rounded() ?? 0, 300, accuracy: 60, "the sender's clock as measured")
        XCTAssertLessThan(r.findings.worstPitchCents, 3, "in tune: the correction is a few hundredths of a percent")
        XCTAssertLessThan(r.findings.delayMaxMs - r.findings.delayMinMs, 25, "the delay held: \(r.describe)")
        XCTAssertEqual(r.cardRanDry, 0)

        // The control: the same without keeping in time, and the buffer creeps up (or the card runs dry) as before.
        var off = s
        off.keepsInTime = false
        let o = MacSimulation.run(off)
        XCTAssertGreaterThan((o.depthMsBySecond.suffix(5).reduce(0, +) / 5) - (r.depthMsBySecond.suffix(5).reduce(0, +) / 5), 10,
                             "untended, 500 ppm apart for a minute is 30 ms: \(o.depthMsBySecond.suffix(5)) against \(r.depthMsBySecond.suffix(5))")
    }

    func testLoweredByHandTheBufferIsThereAtOnceWithoutAClick() {
        var s = MacScenario("hand 100 -> 20")
        s.bufferMs = 100
        s.seconds = 20
        s.bufferMoves = [(12, 20, true)]
        let r = MacSimulation.run(s)
        XCTAssertEqual(r.findings.glitches, 0, r.describe)
        XCTAssertEqual(r.underruns, 0)
        XCTAssertEqual(r.skippedMs, 80, accuracy: 10, "the excess skipped with a crossfade")
        XCTAssertEqual(r.events.count, 1)
        XCTAssertLessThan(r.findings.delayLastMs, 70, r.describe)
    }

    func testRaisedByHandTheBufferGlidesUpWithoutAGap() {
        var s = MacScenario("hand 20 -> 120")
        s.seconds = 25
        s.bufferMoves = [(12, 120, true)]
        s.traceEverySec = 0.1
        let r = MacSimulation.run(s)
        XCTAssertEqual(r.findings.quietMs, 0, "never a gap: \(r.describe)")
        XCTAssertEqual(r.underruns, 0)
        let at18 = r.trace.filter { $0.t > 17.5 && $0.t <= 18 }.map(\.depthMs)
        XCTAssertGreaterThan(at18.reduce(0, +) / Double(max(1, at18.count)), 95, "most of the way in six seconds")
        XCTAssertLessThan(r.findings.worstPitchCents, 100, "a glide: at most 5 %, 85 cents")
    }

    func testTheAutoTuneComingDownSnapsOnceThenDrainsWithoutAGap() {
        var s = MacScenario("auto 200 -> 40")
        s.bufferMs = 200
        s.seconds = 50
        s.bufferMoves = [(12, 40, false)]
        let r = MacSimulation.run(s)
        XCTAssertEqual(r.snaps, 1, r.describe)
        XCTAssertEqual(r.underruns, 0)
        XCTAssertEqual(r.findings.quietMs, 0, r.describe)
        XCTAssertLessThan(r.depthMsBySecond.last ?? 999, 50, "down within about half a minute: \(r.depthMsBySecond)")
        XCTAssertLessThan(r.findings.pitchP95Cents, 10, "the drain is 0.4 % at most, 7 cents")
    }

    func testTheAutoTuneRaisesTheBufferOnARoughNetworkAndLowersItOnACleanOne() {
        var rough = MacScenario("auto-tune, rough")
        rough.network = .rough
        rough.autoTune = true
        rough.seconds = 40
        let r = MacSimulation.run(rough)
        XCTAssertGreaterThan(r.finalTargetMs, 20, "raised: \(r.tunerMoves)")
        var calm = MacScenario("auto-tune, wired, from 80")
        calm.bufferMs = 80
        calm.autoTune = true
        calm.autoTuneIntervalSec = 3
        calm.seconds = 45
        let c = MacSimulation.run(calm)
        XCTAssertLessThan(c.finalTargetMs, 80, "lowered on the evidence of a clean network: \(c.tunerMoves)")
        XCTAssertEqual(c.underruns, 0, c.describe)
        XCTAssertEqual(c.findings.quietMs, 0, "and never a gap on the way down: \(c.describe)")
    }

    /// The lowest-delay auto-tune (Windows DropoutTuner): from a big buffer on a wired network it comes well down, and on
    /// a rough one it climbs where the gaps are, accepting a rare one.
    func testTheLowestDelayAutoTuneComesDownOnAWiredNetworkAndClimbsOnARoughOne() {
        var wired = MacScenario("lowest-delay auto-tune, wired, from 80")
        wired.bufferMs = 80
        wired.autoTune = true
        wired.lowestDelay = true
        wired.seconds = 40
        let w = MacSimulation.run(wired)
        XCTAssertLessThan(w.finalTargetMs, 30, "halving toward the floor while no gap has been met: \(w.tunerMoves)")
        var rough = MacScenario("lowest-delay auto-tune, rough, from 5")
        rough.network = .rough
        rough.bufferMs = 5
        rough.autoTune = true
        rough.lowestDelay = true
        rough.seconds = 40
        let r = MacSimulation.run(rough)
        XCTAssertGreaterThan(r.finalTargetMs, 5, "raised where the gaps were: \(r.tunerMoves)")
    }

    func testASenderThatStartsCountingAgainKeepsPlaying() {
        var s = MacScenario("sender restart")
        s.seconds = 15
        s.senderRestartAtSecond = 8
        let r = MacSimulation.run(s)
        XCTAssertEqual(r.lateDropped, 0, "not one of its new packets thrown away as late")
        XCTAssertGreaterThan(r.findings.clicksHeard, 25, "heard on after the restart: \(r.describe)")
        XCTAssertLessThan(r.findings.delayLastMs - r.findings.delayFirstMs, 30, r.describe)
    }

    func testDoubledPacketsAreDroppedNotPlayedTwice() {
        var s = MacScenario("wired with 2 % of packets doubled")
        s.network.duplicatePercent = 2
        s.seconds = 20
        let r = MacSimulation.run(s)
        XCTAssertGreaterThan(r.lateDropped, 40, "premise: about 80 doubled")
        XCTAssertTrue(r.findings.clean, "a doubled packet must be dropped, not played again: \(r.describe)")
        XCTAssertEqual(r.underruns, 0)
    }

    func testTheNetworkStoppingOnceIsHeardOnceAndTheDelayComesBack() {
        var s = MacScenario("network stops 300 ms")
        s.seconds = 20
        s.network.stallAtSec = 6
        s.network.stallOnceMs = 300
        let r = MacSimulation.run(s)
        XCTAssertEqual(r.findings.glitches, 1, r.describe)
        XCTAssertLessThan(r.findings.delayLastMs, r.findings.delayFirstMs + 25, "no lasting delay from the backlog: \(r.describe)")
        XCTAssertEqual(r.clockPpmBySecond.last??.magnitude ?? 0, 0, accuracy: 250, "and the stall not read as a clock")
    }

    func testTheMacsOutputCardStoppingForAMomentIsNotTakenForASlowClock() {
        for ms in [20.0, 100.0, 450.0] {
            var s = MacScenario("output card stops \(Int(ms)) ms")
            s.seconds = 50
            s.receiveCard.stallAtSec = 35
            s.receiveCard.stallOnceMs = ms
            s.analyseFromSecond = 36
            let r = MacSimulation.run(s)
            XCTAssertEqual(r.findings.glitches, 0, "not one break-up a second after it: \(r.describe)")
            XCTAssertEqual(r.underruns, 0, r.describe)
        }
    }

    func testTheSessionTimerStoppingOnceLeavesNoLastingDelay() {
        var s = MacScenario("session timer stops 60 ms")
        s.seconds = 20
        s.mixStallAtSec = 8
        s.mixStallMs = 60
        for artifact in ConcealmentArtifact.allCases {
            s.artifact = artifact
            let r = MacSimulation.run(s)
            // Staying armed can expose several short reads while a stalled timer catches up. The detector also
            // counts each separate noise burst. Bound the interruption and verify the whole recovery tail instead
            // of assuming a single rebuffered silence; neither artifact may cause lasting delay or later breakup.
            XCTAssertGreaterThanOrEqual(r.findings.firstGlitchAt ?? 0, 8, r.describe)
            XCTAssertLessThan(r.findings.firstGlitchAt ?? 999, 8.1, r.describe)
            XCTAssertLessThan(r.findings.quietMs, 100, r.describe)
            XCTAssertLessThan(r.findings.delayLastMs, r.findings.delayFirstMs + 10, r.describe)
            s.analyseFromSecond = 9
            let recovered = MacSimulation.run(s)
            XCTAssertEqual(recovered.findings.glitches, 0, recovered.describe)
            XCTAssertEqual(recovered.findings.quietMs, 0, recovered.describe)
            XCTAssertLessThan(recovered.findings.delayMaxMs - recovered.findings.delayMinMs, 2, recovered.describe)
            s.analyseFromSecond = 0
        }
    }

    func testLossInBurstsAndAQueueThatBuildsAreRiddenOutByABufferAboveThem() {
        var s = MacScenario("a queue that builds to 30 ms, at 60 ms")
        s.network = .congested
        s.bufferMs = 60
        s.seconds = 30
        let r = MacSimulation.run(s)
        XCTAssertEqual(r.underruns, 0, r.describe)
        XCTAssertTrue(r.findings.clean, r.describe)
    }

    func testMusicOverAWiredNetworkComesThroughWhole() {
        var s = MacScenario("music, wired")
        s.music = true
        s.seconds = 13
        let r = MacSimulation.run(s)
        XCTAssertTrue(r.music?.clean ?? false, r.music?.describe ?? "-")
    }

    /// Windows' RESUME AND SOAK, the part the Mac has: over half an hour (REMSOUND_SIM_LONG=1; about a minute to run),
    /// two clocks 400 ppm apart on a wired network at 20 ms - the clock read and held, the buffer where it was set, not
    /// one break-up. (A lumpy laptop's long run is in MacSimulatorReport: its readings wander more.)
    func testHalfAnHourOfClocksApartStaysPut() throws {
        guard ProcessInfo.processInfo.environment["REMSOUND_SIM_LONG"] != nil else { throw XCTSkip("set REMSOUND_SIM_LONG=1") }
        var s = MacScenario("half an hour, 400 ppm apart, wired, 20 ms")
        s.sendCard.driftPpm = 250
        s.receiveCard.driftPpm = -150
        s.seconds = 1800
        let r = MacSimulation.run(s)
        let ppm = r.clockPpmBySecond.suffix(600).compactMap { $0 }
        XCTAssertEqual(ppm.reduce(0, +) / Double(max(1, ppm.count)), 250, accuracy: 10, "the sender's clock, read over the last ten minutes")
        XCTAssertLessThan((ppm.max() ?? 0) - (ppm.min() ?? 0), 60, "and held there")
        let early = r.depthMsBySecond[60..<120], late = r.depthMsBySecond.suffix(60)
        XCTAssertEqual(late.reduce(0, +) / 60, early.reduce(0, +) / 60, accuracy: 4, "the buffer where it was")
        XCTAssertEqual(r.cardRanDry, 0)
        XCTAssertEqual(r.underruns, 0, r.describe)
        XCTAssertTrue(r.findings.clean, r.describe)
    }

    func testAPlantedClickAtTheSenderIsHeardAsOneAndOnlyOne() {
        var s = MacScenario("planted click")
        s.seconds = 10
        s.plantClickAtSecond = 5
        let r = MacSimulation.run(s)
        XCTAssertEqual(r.findings.glitches, 1, "the simulator hears what it is sent: \(r.describe)")
    }
}
