import Foundation
import RemSoundJam

/// Offline CLI support uses the existing Mac receiver simulation, not a second receive implementation.
public enum ReplaySimulation {
    public static let maximumRecordingBytes = 16 * 1024 * 1024
    public enum Failure: Error, LocalizedError {
        case invalidRecording
        public var errorDescription: String? { "The recording cannot be replayed within the supported offline network/receive scope." }
    }
    public struct Comparison: Codable, Equatable, Sendable {
        public let codec: String
        public let packetFrames: Int
        public let bufferMs: Int
        public let encoderBitrate: Int
        public let seed: UInt64
        public let seconds: Double
        public let nativeDecodedFrames: UInt64
        public let packetsSent: Int
        public let packetsLost: Int
        public let lateDropped: Int
        public let concealed: Int
        public let gapsNotRepaired: Int
        public let underruns: Int
        public let cardShortReads: Int
    }
    public struct Report: Codable, Equatable, Sendable {
        public let schema: Int
        public let startedUTC: String
        public let scope: String
        public let seed: UInt64
        public let stream: Int
        public let recordedCodec: Int
        public let recordedFrameSamples: Int
        public let seconds: Double
        public let oneWayMs: Double
        public let packetFrames: Int
        public let bufferMs: Int
        public let outputFrames: Int
        public let places: Int
        public let lost: Int
        public let doubled: Int
        public let packetsSent: Int
        public let packetsLost: Int
        public let lateDropped: Int
        public let underruns: Int
        public let cardShortReads: Int
        public let nativeCodec: Bool
        public let nativeDecodedFrames: UInt64
        public let concealed: Int
        public let gapsNotRepaired: Int
        public let unverified: [String]
        public let comparisons: [Comparison]

        @_spi(NativeReplay) public func withComparisons(_ results: [MacResult], bitrate: Int) throws -> Report {
            let frames = [64, 120, 480], buffers = [5, 8, 10, 15, 20, 30]
            guard results.count == frames.count * buffers.count, bitrate == 320000 else { throw Failure.invalidRecording }
            var rows: [Comparison] = []
            for (index, result) in results.enumerated() {
                let target = result.scenario
                guard let targetFrames = target.packetFrames, targetFrames == frames[index / buffers.count], target.bufferMs == buffers[index % buffers.count],
                    target.seed == seed, target.seconds == seconds, result.nativeCodec,
                    result.nativeDecodedFrames > 0, result.codecFailures == 0 else { throw Failure.invalidRecording }
                rows.append(.init(codec: targetFrames == 64 ? "custom-opus-celt" : "ordinary-opus-lowdelay", packetFrames: targetFrames,
                    bufferMs: target.bufferMs, encoderBitrate: bitrate, seed: target.seed, seconds: target.seconds,
                    nativeDecodedFrames: result.nativeDecodedFrames, packetsSent: result.packetsSent,
                    packetsLost: result.packetsLost, lateDropped: result.lateDropped, concealed: result.concealed,
                    gapsNotRepaired: result.gapsNotRepaired, underruns: result.underruns, cardShortReads: result.cardShortReads))
            }
            return .init(schema: schema, startedUTC: startedUTC, scope: scope, seed: seed, stream: stream,
                recordedCodec: recordedCodec, recordedFrameSamples: recordedFrameSamples, seconds: seconds,
                oneWayMs: oneWayMs, packetFrames: packetFrames, bufferMs: bufferMs, outputFrames: outputFrames,
                places: places, lost: lost, doubled: doubled, packetsSent: packetsSent, packetsLost: packetsLost,
                lateDropped: lateDropped, underruns: underruns, cardShortReads: cardShortReads, nativeCodec: nativeCodec,
                nativeDecodedFrames: nativeDecodedFrames, concealed: concealed, gapsNotRepaired: gapsNotRepaired,
                unverified: (nativeCodec ? [] : ["recorded codec uses pure receive model"]) + ["complete reference sweeps and other codec modes", "recorded-driver and physical output acceptance", "full simulator product parity"],
                comparisons: rows)
        }
    }
    // Bound rows and line storage before NetworkRecording's Foundation split/map allocations.
    static func validateRecordingText(_ text: String) throws {
        guard text.utf8.count <= maximumRecordingBytes else { throw Failure.invalidRecording }
        var rows = 0, lineBytes = 0
        for byte in text.utf8 {
            if byte == 10 { rows += 1; lineBytes = 0 }
            else { lineBytes += 1 }
            guard rows <= (1 << 18) + 64 + 256 + 2, lineBytes <= 4096 else { throw Failure.invalidRecording }
        }
    }
    public static func run(_ text: String, stream: Int = -1, seconds: Double = 10,
        oneWayMs: Double? = nil, date: Date = Date()) throws -> Report {
        try run(text, stream: stream, seconds: seconds, oneWayMs: oneWayMs, date: date, simulate: { scenario, _, _ in MacSimulation.run(scenario) })
    }
    @_spi(NativeReplay) public static func run(_ text: String, stream: Int = -1, seconds: Double = 10,
        oneWayMs: Double? = nil, date: Date = Date(),
        simulate: (MacScenario, Int, Int) throws -> MacResult) throws -> Report {
        guard text.utf8.count <= maximumRecordingBytes, seconds.isFinite, seconds >= 0.05, seconds <= 60,
            stream >= -1, stream < 64 else { throw Failure.invalidRecording }
        do {
            try validateRecordingText(text)
            let recording = try NetworkRecording.read(text)
            guard recording.streams.count <= 64, recording.facts.count <= 256,
                recording.packets.count <= 1 << 18 else { throw Failure.invalidRecording }
            let counts = Dictionary(grouping: recording.packets, by: \.stream).mapValues(\.count)
            let chosen = stream >= 0 ? stream : (recording.streams.sorted {
                let a = counts[$0.index, default: 0], b = counts[$1.index, default: 0]
                return a == b ? $0.index < $1.index : a > b
            }.first?.index ?? -1)
            guard let descriptor = recording.streams.first(where: { $0.index == chosen }) else { throw Failure.invalidRecording }
            guard (1...16384).contains(descriptor.frameSamples), (0...255).contains(descriptor.codec),
                recording.packets.allSatisfy({ $0.ms.isFinite && $0.ms >= 0 && $0.ms <= 60000 }) else { throw Failure.invalidRecording }
            let replay = try NetworkReplay.from(recording, stream: chosen, name: "explicit recording replay")
            let duration = recording.packets.map(\.ms).max()! / 1000
            guard duration.isFinite, duration >= 0, duration <= 60 else { throw Failure.invalidRecording }
            let way: Double
            if let oneWayMs { way = oneWayMs }
            else if let raw = recording.fact("one-way ms") {
                guard let value = Double(raw) else { throw Failure.invalidRecording }; way = value
            } else { way = 0 }
            guard way.isFinite, way >= 0, way <= 2000 else { throw Failure.invalidRecording }
            let frames = Int((replay.period * 48000).rounded())
            guard (16...4096).contains(frames) else { throw Failure.invalidRecording }
            func integerFact(_ key: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
                guard let value = recording.fact(key) else { return fallback }
                guard let number = Double(value), number.isFinite, number.rounded() == number,
                    number >= Double(range.lowerBound), number <= Double(range.upperBound) else { throw Failure.invalidRecording }
                return Int(number)
            }
            let buffer = try integerFact("buffer ms", fallback: 20, range: 1...1000)
            let output = try integerFact("receive card frames", fallback: 512, range: 16...4096)
            var scenario = MacScenario("offline network replay")
            scenario.seed = 1
            scenario.seconds = max(seconds, floor(duration))
            scenario.network = .replaying(replay, oneWayMs: way)
            scenario.sendCard = SimCard(frames: frames, jitterMs: 0)
            scenario.packetFrames = frames
            scenario.receiveCard = SimCard(frames: output, jitterMs: 0)
            scenario.bufferMs = buffer
            let result = try simulate(scenario, descriptor.codec, descriptor.frameSamples)
            guard result.codecFailures == 0 else { throw Failure.invalidRecording }
            return .init(schema: 1, startedUTC: ISO8601DateFormatter().string(from: date), scope: result.nativeCodec ? "offline-native-Opus-and-Mac-receive" : "offline-network-and-Mac-receive-model",
                seed: 1, stream: chosen, recordedCodec: descriptor.codec, recordedFrameSamples: descriptor.frameSamples,
                seconds: scenario.seconds, oneWayMs: way, packetFrames: frames, bufferMs: buffer, outputFrames: output,
                places: replay.places, lost: replay.lost, doubled: replay.doubled, packetsSent: result.packetsSent,
                packetsLost: result.packetsLost, lateDropped: result.lateDropped, underruns: result.underruns,
                cardShortReads: result.cardShortReads, nativeCodec: result.nativeCodec, nativeDecodedFrames: result.nativeDecodedFrames, concealed: result.concealed, gapsNotRepaired: result.gapsNotRepaired,
                unverified: (result.nativeCodec ? ["Windows comparison sweeps and other codec modes"] : ["native codec/FEC behavior and Windows comparison sweeps"]) + ["recorded-driver and physical output acceptance", "full simulator product parity"], comparisons: [])
        } catch { throw Failure.invalidRecording }
    }
}
