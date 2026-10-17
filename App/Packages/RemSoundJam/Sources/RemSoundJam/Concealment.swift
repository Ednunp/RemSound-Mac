import Foundation

/// Receiver-local choices whose raw numbers retain Windows profile compatibility.
public enum ConcealmentArtifact: Int, Codable, CaseIterable, Sendable {
    case noiseBurst = 2
    case click = 3

    public static let defaultChoice: Self = .noiseBurst
    public static func migrated(_ raw: Int) -> Self { Self(rawValue: raw) ?? .noiseBurst }
    public var label: String { self == .noiseBurst ? "Noise burst" : "Click" }

    public init(from decoder: Decoder) throws {
        self = Self.migrated(try decoder.singleValueContainer().decode(Int.self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A short gap cue, not packet-loss decoding. Owned by the playout worker, including its random state.
struct UnderrunConcealment {
    private static let fadeFrames = 32
    private static let maximumEmptyReads = 8
    private var random: UInt64
    private var lastLeft: Float = 0, lastRight: Float = 0
    private var emptyReads = 0, pendingFade = false

    init(seed: UInt64 = UInt64.random(in: 1...UInt64.max)) { random = seed == 0 ? 1 : seed }

    mutating func reset() {
        lastLeft = 0; lastRight = 0
        emptyReads = 0; pendingFade = false
    }

    private mutating func whiteNoise() -> Float {
        // A per-stream xorshift generator avoids an OS random request for every noise sample.
        random ^= random << 13
        random ^= random >> 7
        random ^= random << 17
        return Float(random >> 40) / Float(1 << 24) * 2 - 1
    }

    mutating func empty(frames: Int, artifact: ConcealmentArtifact) -> [Float] {
        guard frames > 0 else { return [] }
        var output = [Float](repeating: 0, count: frames * 2)
        emptyReads = min(Self.maximumEmptyReads + 1, emptyReads + 1)
        pendingFade = true
        guard artifact == .noiseBurst, emptyReads <= Self.maximumEmptyReads else { return output }
        let peak = min(1, max(abs(lastLeft), abs(lastRight)))
        let length = min(Self.fadeFrames, frames)
        for frame in 0..<length {
            let gain = Float((cos(.pi * Double(frame + 1) / Double(length)) + 1) * 0.5)
            output[frame * 2] = whiteNoise() * peak * gain
            output[frame * 2 + 1] = whiteNoise() * peak * gain
        }
        return output
    }

    mutating func real(_ output: inout [Float], lastFrame: (Float, Float)?, artifact: ConcealmentArtifact) {
        guard output.count >= 2 else { return }
        emptyReads = 0
        if pendingFade, artifact == .noiseBurst {
            let length = min(Self.fadeFrames, output.count / 2)
            for frame in 0..<length {
                let gain = Float((1 - cos(.pi * Double(frame) / Double(length))) * 0.5)
                output[frame * 2] *= gain
                output[frame * 2 + 1] *= gain
            }
        }
        pendingFade = false
        // Use the real input tail, not synthesized noise, faded output or a zero-padded partial tail.
        if let lastFrame {
            lastLeft = lastFrame.0.isFinite ? lastFrame.0 : 0
            lastRight = lastFrame.1.isFinite ? lastFrame.1 : 0
        }
    }
}
