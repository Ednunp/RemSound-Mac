import Foundation
import XCTest

@testable import RemSoundJam
@testable import RemSoundSim

/// Where the Mac's receive path does not yet do what the Windows one does (2026-09-30): each measured, for Ed and Andre
/// to decide on. Prints a report; judges nothing. `REMSOUND_SIM_REPORT=1 swift test --filter MacSimulatorReport`.
/// The long one (half an hour simulated) also needs REMSOUND_SIM_LONG=1.
final class MacSimulatorReport: XCTestCase {
    func line(_ what: String, _ r: MacResult) -> String {
        "- \(what)\n    \(r.describe)\n    quiet \(r.findings.quietMs) ms; cushion \(r.cushionFrames) frames, card ran dry \(r.cardRanDry)"
    }

    func testReport() throws {
        guard ProcessInfo.processInfo.environment["REMSOUND_SIM_REPORT"] != nil else { throw XCTSkip("set REMSOUND_SIM_REPORT=1") }
        var out: [String] = []

        // 1. PCM loss: no fill-in on the Mac; each lost packet is a jump in the sound, and a packet's worth less queued.
        var loss = MacScenario("home wifi (0.2 % loss) at 40 ms, PCM")
        loss.network = .wifi
        loss.bufferMs = 40
        loss.seconds = 30
        let l = MacSimulation.run(loss)
        out.append(line("1. PCM loss, no fill-in: \(l.packetsLost) lost -> \(l.findings.glitches) glitches (Windows fills a lost PCM packet in)", l))

        // 2. Overtaken packets are dropped as late (Windows waits a moment for the missing one).
        var reorder = MacScenario("wired, 1 % of packets overtaken by the next, 40 ms")
        reorder.network.reorderPercent = 1
        reorder.bufferMs = 40
        reorder.seconds = 30
        let o = MacSimulation.run(reorder)
        out.append(line("2. Overtaken packets dropped as late: \(o.lateDropped) dropped -> \(o.findings.glitches) glitches", o))

        // 3. A momentary empty starts the stream again from its target: a gap as long as the buffer (Windows plays on,
        //    and refills only after 100 ms of nothing).
        var lumps = MacScenario("Ed's laptop lumps at 20 ms")
        lumps.network = .laptopLumps
        lumps.seconds = 60
        let m = MacSimulation.run(lumps)
        out.append(line("3. Every underrun refills to the target: \(m.underruns) underruns, \(m.findings.quietMs) ms of silence in all", m))

        // 4. The target is where the queue starts, and its mean sits above it; once the clock is measured the pull
        //    steers the MEAN to the target, and a 10 ms sender at a 10 ms buffer starts running dry.
        var trough = MacScenario("10 ms sender, 10 ms buffer, wired, 40 s")
        trough.bufferMs = 10
        trough.seconds = 40
        trough.traceEverySec = 0.5
        let t = MacSimulation.run(trough)
        let before = t.trace.filter { $0.t < 10 }.map(\.depthMs), after = t.trace.filter { $0.t > 25 }.map(\.depthMs)
        out.append(line(String(format: "4. The pull steers the mean, not the start level: depth %.1f ms mean before the first clock reading, %.1f after",
                               before.reduce(0, +) / Double(max(1, before.count)), after.reduce(0, +) / Double(max(1, after.count))), t))

        // 5. An output card whose driver thread stalls now and then: each time it runs dry the cushion goes up a block,
        //    and it never comes down.
        var stalls = MacScenario("the Mac's card stalls 30 ms every 20 s")
        stalls.receiveCard.stallEverySec = 20
        stalls.receiveCard.stallMs = 30
        stalls.seconds = ProcessInfo.processInfo.environment["REMSOUND_SIM_LONG"] != nil ? 1800 : 200
        let c = MacSimulation.run(stalls)
        out.append(line(String(format: "5. The output cushion only rises: %.0f s -> cushion %d frames (starts at %d), ran dry %d times",
                               stalls.seconds, c.cushionFrames, 512 + 240 + 96, c.cardRanDry), c))

        // 6. Half an hour on Ed's laptop's lumps at 40 ms, clocks 400 ppm apart: the readings wander, and every overtaken
        //    packet dropped takes its frames out of the queue for good, so the depth sinks below the target.
        if ProcessInfo.processInfo.environment["REMSOUND_SIM_LONG"] != nil {
            var long = MacScenario("half an hour, laptop lumps (no stalls), 40 ms, 400 ppm apart")
            long.network = .laptopLumps
            long.network.stallEverySec = 0
            long.bufferMs = 40
            long.sendCard.driftPpm = 250
            long.receiveCard.driftPpm = -150
            long.seconds = 1800
            let h = MacSimulation.run(long)
            let ppm = h.clockPpmBySecond.suffix(600).compactMap { $0 }
            out.append(line(String(format: "6. Long run on lumps: clock read %.0f to %.0f ppm (truly 250) over the last ten minutes; depth %.1f ms mean in the second minute, %.1f in the last (target 40)",
                                   ppm.min() ?? .nan, ppm.max() ?? .nan, h.depthMsBySecond[60..<120].reduce(0, +) / 60,
                                   h.depthMsBySecond.suffix(60).reduce(0, +) / 60), h))
        }

        print("MAC SIMULATOR REPORT\n" + out.joined(separator: "\n"))
    }
}
