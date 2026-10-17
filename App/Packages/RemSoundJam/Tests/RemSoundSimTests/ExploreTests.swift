import Foundation
import XCTest

@testable import RemSoundJam
@testable import RemSoundSim

/// Prints runs (set REMSOUND_SIM_EXPLORE=1): for looking, not judging. `swift test --filter ExploreTests`.
final class ExploreTests: XCTestCase {
    func show(_ s: MacScenario) {
        let r = MacSimulation.run(s)
        print("SIM | " + r.describe + " | depth " + r.depthMsBySecond.map { String(format: "%.0f", $0) }.joined(separator: ",")
              + " | ppm end \(r.clockPpmBySecond.last.flatMap { $0 }.map { String(format: "%.0f", $0) } ?? "-")"
              + " | cushion \(r.cushionFrames) cut \(r.cardCutFrames) laid \(r.cardLaidFrames) dry \(r.cardRanDry)"
              + " | snaps \(r.snaps) \(String(format: "%.0f", r.snappedMs)) ms skipped \(String(format: "%.0f", r.skippedMs)) ms"
              + " | events \(r.events.joined(separator: " / "))")
    }

    func testExplore() throws {
        guard ProcessInfo.processInfo.environment["REMSOUND_SIM_EXPLORE"] != nil else { throw XCTSkip("set REMSOUND_SIM_EXPLORE=1") }
        let asio = SimCard(frames: 64, jitterMs: 0.05)
        for buffer in [3, 5, 10] {
            var s = MacScenario("jamming: perfect, 64-frame sender, \(buffer) ms, 96-frame mix")
            s.sendCard = asio; s.bufferMs = buffer; s.mixFrames = 96; s.seconds = 20
            s.receiveCard = SimCard(frames: 64, jitterMs: 0.05)
            show(s)
            s.name = "jamming: wired, 64-frame sender, \(buffer) ms"
            s.network = .wired
            show(s)
        }
        var d = MacScenario("clocks: sender +300, card -200, 20 ms, 60 s")
        d.sendCard.driftPpm = 300; d.receiveCard.driftPpm = -200; d.seconds = 60
        show(d)
        var lower = MacScenario("hand: 100 -> 20 at 12 s")
        lower.bufferMs = 100; lower.seconds = 20; lower.bufferMoves = [(12, 20, true)]
        show(lower)
        var raise = MacScenario("hand: 20 -> 120 at 12 s")
        raise.seconds = 25; raise.bufferMoves = [(12, 120, true)]
        show(raise)
        var auto = MacScenario("auto: 200 -> 40 at 12 s")
        auto.bufferMs = 200; auto.seconds = 50; auto.bufferMoves = [(12, 40, false)]
        show(auto)
        var tune = MacScenario("auto-tune on rough internet from 20 ms")
        tune.network = .rough; tune.autoTune = true; tune.seconds = 60; tune.autoTuneIntervalSec = 5
        show(tune)
        var calm = MacScenario("auto-tune on wired from 80 ms")
        calm.bufferMs = 80; calm.autoTune = true; calm.seconds = 90; calm.autoTuneIntervalSec = 3
        show(calm)
        var restart = MacScenario("sender restarts at 8 s")
        restart.seconds = 15; restart.senderRestartAtSecond = 8
        show(restart)
        var stall = MacScenario("Mac card stops 200 ms at 6 s")
        stall.seconds = 15; stall.receiveCard.stallAtSec = 6; stall.receiveCard.stallOnceMs = 200
        show(stall)
        var music = MacScenario("music, wired, 20 ms")
        music.music = true; music.seconds = 12
        show(music)
        music.name = "music, wifi, 20 ms"; music.network = .wifi
        show(music)
        var once = MacScenario("network stops 300 ms at 6 s, 20 ms")
        once.seconds = 15; once.network.stallAtSec = 6; once.network.stallOnceMs = 300
        show(once)
    }
}
