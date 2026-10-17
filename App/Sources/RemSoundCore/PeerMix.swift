import Foundation
import RemSoundJam

/// One peer's volume, pan and EQ (Windows' PeerShaping), saved in the profile. `enabled` is the peer's own tick: it is
/// heard only while the profile's "Enable volume, pan and EQ for all peers" is on as well. A newly seen peer is ticked,
/// so turning that switch on covers everyone at once (as on Windows).
public struct PeerMix: Codable, Equatable {
    public var enabled: Bool
    public var volume: Int
    public var pan: Int
    /// The three EQs (RemSoundJam's PeerEq): which is heard, and each one's own settings.
    public var eq: PeerEq

    public init(enabled: Bool = true, volume: Int = 100, pan: Int = 0, eq: PeerEq = PeerEq()) {
        self.enabled = enabled
        self.volume = min(100, max(0, volume))
        self.pan = min(100, max(-100, pan))
        self.eq = eq
    }
    private enum CodingKeys: String, CodingKey {
        case enabled, volume, pan
        case eqMode, simpleBandsDb, advancedBandsDb, parametricBands
        // Before the three EQs, the Mac saved whole decibels for bass, mids and treble; read once, never written.
        case bass, mids, treble
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try [CodingKeys.bass, .mids, .treble].map { Float(try values.decodeIfPresent(Int.self, forKey: $0) ?? 0) }
        let eq = PeerEq(
            mode: PeerEqMode(rawValue: try values.decodeIfPresent(Int.self, forKey: .eqMode) ?? 0) ?? .simple3Band,
            simpleDb: try values.decodeIfPresent([Float].self, forKey: .simpleBandsDb) ?? legacy,
            advancedDb: try values.decodeIfPresent([Float].self, forKey: .advancedBandsDb) ?? [],
            parametric: try values.decodeIfPresent([ParametricBand].self, forKey: .parametricBands) ?? [])
        self.init(enabled: try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            volume: try values.decodeIfPresent(Int.self, forKey: .volume) ?? 100,
            pan: try values.decodeIfPresent(Int.self, forKey: .pan) ?? 0, eq: eq)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(volume, forKey: .volume)
        try values.encode(pan, forKey: .pan)
        try values.encode(eq.mode.rawValue, forKey: .eqMode)
        try values.encode(eq.simpleDb, forKey: .simpleBandsDb)
        try values.encode(eq.advancedDb, forKey: .advancedBandsDb)
        try values.encode(eq.parametric, forKey: .parametricBands)
    }
    /// Volume and pan (a balance: panning one way lowers the other side, never folding the stereo to mono).
    public func apply(_ samples: [Float]) -> [Float] {
        guard enabled else { return samples }
        let level = Float(volume) / 100
        let left = level * Float(min(100, 100 - pan)) / 100
        let right = level * Float(min(100, 100 + pan)) / 100
        var output = samples
        for index in stride(from: 0, to: output.count - output.count % 2, by: 2) {
            output[index] *= left
            output[index + 1] *= right
        }
        return output
    }
    /// Profiles saved before the master switch: it starts on if any peer was being shaped, so nobody's sound changes.
    public static func masterSwitchForOldProfile(_ mixes: [String: PeerMix]) -> Bool {
        mixes.values.contains { $0.enabled }
    }
}
