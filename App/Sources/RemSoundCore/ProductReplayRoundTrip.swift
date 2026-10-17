import Foundation
import RemSoundJam
@_spi(NativeReplay) import RemSoundSim

extension ProductTestPack {
    struct ReplayRoundTripReceipt {
        let textRoundTrip: Bool, nativeFormat: Bool, framePeriod: Bool, recordedFates: Bool
        let packetSet: Bool, packetOrder: Bool, worstArrivalErrorMs: Double
        let delayDifferenceMs: Double, sameGlitches: Bool, sameLate: Bool, sameUnderruns: Bool
        let sameConcealment: Bool, sameUnrepaired: Bool, finiteOutput: Bool, sourceReleased: Bool
        let originalReorderWaits: UInt64, replayedReorderWaits: UInt64
    }
    static func nativeReplayHandmade() throws -> (native: Bool, stall: Bool, loss: Bool, late: Bool, order: Bool, ties: Bool, waits: UInt64) {
        var recording = NetworkRecording()
        recording.streams = [.init(index: 0, from: "192.0.2.1:1", streamId: 7, lane: "Mixed", format: "synthetic", codec: 2, frameSamples: 120)]
        for index in 0..<4000 where index != 2000 {
            let sent = Double(index) * 2.5
            var arrival = sent + 5
            if sent >= 3000 && sent < 3120 { arrival = 3125 }
            if index == 2800 { arrival += 4 }
            recording.packets.append(.init(ms: arrival, stream: 0, sequence: UInt32(index + 1000), bytes: 60))
            if index == 3200 { recording.packets.append(.init(ms: arrival + 0.5, stream: 0, sequence: UInt32(index + 1000), bytes: 60)) }
        }
        recording.packets.sort { $0.ms < $1.ms }
        var scenario = MacScenario("handmade native faults")
        scenario.seconds = 10; scenario.seed = 1; scenario.packetFrames = 120
        scenario.sendCard = SimCard(frames: 120, jitterMs: 0); scenario.bufferMs = 15; scenario.recordNetwork = true
        scenario.network = .replaying(try NetworkReplay.from(recording), oneWayMs: 5)
        guard let sender = OpusSender(bitrate: 320_000) else { throw ReplaySimulation.Failure.invalidRecording }
        let totals = ReceiveTotals()
        let result = try NativeReplaySimulation.runNative(scenario, frames: 120, channels: 2, receiveTotals: totals, encode: sender.encode)
        guard let packets = result.recording?.packets else { throw ReplaySimulation.Failure.invalidRecording }
        let sequences = packets.map(\.sequence)
        let lateIndex = sequences.firstIndex(of: 2801), earlyIndex = sequences.firstIndex(of: 2802)
        let order = !sequences.contains(2001) && sequences.filter { $0 == 3201 }.count == 2
            && lateIndex != nil && earlyIndex != nil && earlyIndex! < lateIndex!
        let stalled = packets.filter { (1201...1248).contains($0.sequence) }
        return (result.nativeCodec && result.nativeDecodedFrames > 0,
            result.findings.firstGlitchAt.map { abs($0 - 3) < 0.3 } ?? false,
            result.packetsLost == 1, result.lateDropped >= 1, order,
            stalled.count == 48 && Set(stalled.map(\.ms)).count == 1, totals.reorderWaits)
    }
    static func nativeReplaySelection() throws -> (defaultStream: Bool, explicitStream: Bool, places: Bool, invalidRefused: Bool) {
        var recording = NetworkRecording()
        recording.streams = [
            .init(index: 0, from: "192.0.2.1:1", streamId: 7, lane: "Mixed", format: "first", codec: 2, frameSamples: 120),
            .init(index: 1, from: "192.0.2.2:2", streamId: 8, lane: "Mixed", format: "second", codec: 2, frameSamples: 480)
        ]
        recording.packets = (0..<40).map { .init(ms: Double($0) * 2.5, stream: 0, sequence: UInt32($0), bytes: 60) }
            + (0..<80).map { .init(ms: Double($0) * 10, stream: 1, sequence: UInt32($0), bytes: 100) }
        recording.packets.sort { $0.ms < $1.ms }
        let text = recording.text()
        let chosen = try NativeReplaySimulation.run(text, seconds: 0.8)
        let explicit = try NativeReplaySimulation.run(text, stream: 0, seconds: 0.8)
        var invalid = false
        do { _ = try NativeReplaySimulation.run(text, stream: 2, seconds: 0.8) }
        catch ReplaySimulation.Failure.invalidRecording { invalid = true }
        return (chosen.stream == 1 && chosen.recordedFrameSamples == 480 && chosen.nativeCodec && chosen.nativeDecodedFrames > 0,
            explicit.stream == 0 && explicit.recordedFrameSamples == 120 && explicit.nativeCodec && explicit.nativeDecodedFrames > 0,
            chosen.places == 80 && explicit.places == 40, invalid)
    }
    static func nativeReplayRoundTrip() throws -> ReplayRoundTripReceipt {
        var scenario = MacScenario("native receiver recording roundtrip")
        scenario.seconds = 12; scenario.seed = 1; scenario.network = .internet
        scenario.packetFrames = 120; scenario.sendCard = SimCard(frames: 120, jitterMs: 0)
        scenario.bufferMs = 30; scenario.keepAudio = true; scenario.recordNetwork = true
        weak var source: OpusSender?
        var waits: UInt64 = 0
        func run(_ value: MacScenario) throws -> MacResult {
            guard let sender = OpusSender(bitrate: 320_000) else { throw ReplaySimulation.Failure.invalidRecording }
            source = sender
            let totals = ReceiveTotals()
            let result = try NativeReplaySimulation.runNative(value, frames: 120, channels: 2, receiveTotals: totals, encode: sender.encode)
            waits = totals.reorderWaits
            return result
        }
        let original = try run(scenario), firstReleased = source == nil, originalWaits = waits
        guard let recording = original.recording else { throw ReplaySimulation.Failure.invalidRecording }
        let loaded = try NetworkRecording.read(recording.text())
        let replay = try NetworkReplay.from(loaded)
        scenario.network = .replaying(replay, oneWayMs: 12)
        let repeated = try run(scenario)
        guard let twice = repeated.recording, let heard = original.audio, let reheard = repeated.audio,
            !heard.isEmpty, !reheard.isEmpty else { throw ReplaySimulation.Failure.invalidRecording }
        func first(_ record: NetworkRecording) -> [UInt32: Double] {
            var values: [UInt32: Double] = [:]
            for packet in record.packets where values[packet.sequence] == nil { values[packet.sequence] = packet.ms }
            return values
        }
        let was = first(recording), now = first(twice), shared = Set(was.keys).intersection(now.keys)
        guard !shared.isEmpty else { throw ReplaySimulation.Failure.invalidRecording }
        let offsets = shared.map { now[$0]! - was[$0]! }.sorted(), offset = offsets[offsets.count / 2]
        let worst = shared.map { abs(now[$0]! - was[$0]! - offset) }.max() ?? .infinity
        let distinct = Set(recording.packets.map(\.sequence)).count
        return .init(textRoundTrip: loaded.text() == recording.text()
            && loaded.streams == recording.streams && loaded.facts == recording.facts
            && loaded.packets.count == recording.packets.count,
            nativeFormat: original.nativeCodec && repeated.nativeCodec && loaded.streams.count == 1
                && loaded.streams[0].codec == 2 && loaded.streams[0].frameSamples == 120,
            framePeriod: abs(replay.period * 1000 - 2.5) < 0.01,
            recordedFates: replay.lost > 0 && original.packetsLost > 0
                && replay.lost == replay.places - distinct && replay.doubled == recording.packets.count - distinct,
            packetSet: shared.count >= was.count - 2 && now.count <= was.count + 2,
            packetOrder: recording.packets.map(\.sequence) == twice.packets.map(\.sequence), worstArrivalErrorMs: worst,
            delayDifferenceMs: abs(original.findings.delayMedianMs - repeated.findings.delayMedianMs),
            sameGlitches: original.findings.glitches == repeated.findings.glitches,
            sameLate: original.lateDropped == repeated.lateDropped,
            sameUnderruns: original.underruns == repeated.underruns,
            sameConcealment: original.concealed == repeated.concealed,
            sameUnrepaired: original.gapsNotRepaired == repeated.gapsNotRepaired,
            finiteOutput: heard.allSatisfy(\.isFinite) && reheard.allSatisfy(\.isFinite)
                && heard.contains { abs($0) > 0.1 } && reheard.contains { abs($0) > 0.1 },
            sourceReleased: firstReleased && source == nil, originalReorderWaits: originalWaits, replayedReorderWaits: waits)
    }
}
