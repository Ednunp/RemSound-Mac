import Foundation
import RemSoundJam
@_spi(NativeReplay) import RemSoundSim

/// Scalar report only. Native codec ownership stays in Core, before any App runtime or device.
public enum NativeReplaySimulation {
    public static func run(_ text: String, stream: Int = -1, seconds: Double = 10,
        oneWayMs: Double? = nil, date: Date = Date()) throws -> ReplaySimulation.Report {
        try ReplaySimulation.run(text, stream: stream, seconds: seconds, oneWayMs: oneWayMs, date: date) { scenario, codec, frames in
            try runRecorded(scenario, codec: codec, frames: frames)
        }
    }

    /// Fixed reference targets; the original recorded descriptor remains unchanged in the report.
    public static func compare(_ text: String, stream: Int = -1, seconds: Double = 10,
        oneWayMs: Double? = nil, date: Date = Date()) throws -> ReplaySimulation.Report {
        var recordedScenario: MacScenario?
        let recorded = try ReplaySimulation.run(text, stream: stream, seconds: seconds, oneWayMs: oneWayMs, date: date) { scenario, codec, frames in
            recordedScenario = scenario
            return try runRecorded(scenario, codec: codec, frames: frames)
        }
        guard let scenario = recordedScenario else { throw ReplaySimulation.Failure.invalidRecording }
        var results: [MacResult] = []
        // SimPath creates a fresh replay cursor for each run, including target-period rescaling.
        for frames in [64, 120, 480] {
            for buffer in [5, 8, 10, 15, 20, 30] {
                var target = scenario
                target.packetFrames = frames
                target.sendCard = SimCard(frames: frames, jitterMs: 0)
                target.bufferMs = buffer
                results.append(try runRecorded(target, codec: (frames == 64 ? StreamFormat.Codec.opusCustom : .opus).rawValue, frames: frames))
            }
        }
        return try recorded.withComparisons(results, bitrate: SendCodec.opusLive.bitrate)
    }

    private static func runRecorded(_ scenario: MacScenario, codec: Int, frames: Int) throws -> MacResult {
        if codec == StreamFormat.Codec.opusCustom.rawValue {
            guard [64, 128].contains(frames), scenario.packetFrames == frames,
                let sender = OpusCustomSender(frames: frames) else { throw ReplaySimulation.Failure.invalidRecording }
            return try runNative(scenario, frames: frames, channels: 2, codec: .opusCustom, encode: sender.encode)
        }
        guard codec == StreamFormat.Codec.opus.rawValue else { return MacSimulation.run(scenario) }
        guard [120, 240, 480, 960, 1920, 2880].contains(frames), scenario.packetFrames == frames,
            let sender = OpusSender(bitrate: SendCodec.opusLive.bitrate) else { throw ReplaySimulation.Failure.invalidRecording }
        return try runNative(scenario, frames: frames, channels: 2, encode: sender.encode)
    }

    // A fixed known-answer packet source can exercise genuine SILK FEC in the same pipeline.
    // Normal replay always calls the ordinary production sender above, which uses low-delay CELT.
    static func runNative(_ scenario: MacScenario, frames: Int, channels: Int, codec: StreamFormat.Codec = .opus,
        receiveTotals: ReceiveTotals? = nil,
        encode: @escaping ([Float]) -> Data?) throws -> MacResult {
        guard scenario.seconds.isFinite, (0.05...60).contains(scenario.seconds),
            scenario.packetFrames == frames,
            (codec == .opus && [120, 240, 480, 960, 1920, 2880].contains(frames) && (1...2).contains(channels))
                || (codec == .opusCustom && [64, 128].contains(frames) && channels == 2) else { throw ReplaySimulation.Failure.invalidRecording }
        let credentials = try Credentials(password: "synthetic native codec replay")
        var format = codec == .opusCustom ? StreamFormat.opusCustom(credentials.fingerprint, frames: frames)
            : StreamFormat.opus(credentials.fingerprint, frames: frames)
        format.channels = channels
        let queue = PlayoutQueue(jitterMs: scenario.bufferMs, packetFrames: frames, now: 0,
            smoothness: scenario.smoothness, artifact: scenario.artifact, concealmentSeed: scenario.seed)
        var now = 0.0
        let decoder = StreamDecoder(format, jitterMs: scenario.bufferMs, smoothness: scenario.smoothness,
            artifact: scenario.artifact, playoutQueue: queue, clock: { now })
        guard decoder.nativeCodecReady else { throw ReplaySimulation.Failure.invalidRecording }
        let totals = receiveTotals ?? ReceiveTotals(); decoder.receiveTotals = totals
        let result = MacSimulation.run(scenario, queue: queue, custom: codec == .opusCustom, encode: { sequence, samples in
            guard let plain = encode(samples) else { return nil }
            guard let sealed = try? credentials.seal(plain) else { return nil }
            return Wire.packet(.audio, stream: 7, sequence: sequence, payload: sealed)
        }, receive: { sequence, packet, at in
            now = at
            guard let parsed = Wire.parse(packet), parsed.kind == .audio, parsed.stream == 7,
                parsed.sequence == sequence else { return }
            _ = decoder.accept(parsed, credentials: credentials)
        }, totals: { (totals.lateOrDoubledDropped, totals.concealed, totals.gapsNotRepaired, totals.decodedAudioFrames) })
        guard result.codecFailures == 0, result.nativeDecodedFrames > 0 else { throw ReplaySimulation.Failure.invalidRecording }
        return result
    }
}
