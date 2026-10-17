import Foundation

// PER-PEER EQ (the Mac's copy of the Windows RemSound's PeerShaping.cs and PeerDspChain.cs).
//
// Three EQs a peer can be shaped with, each keeping its own settings: the 3-band tone control (bass a low shelf at
// 100 Hz, mids a peak at 1 kHz, treble a high shelf at 8 kHz), the 12-band graphic EQ (peaks at fixed centres, Q 1.4),
// and up to 16 parametric bands (a boost or cut across a start-to-end range, a peak at the range's geometric middle
// as wide as the range). Only the active one is heard. Every band -12 to +12 dB; a band under 0.05 dB is left out.
// The filters are RBJ's cookbook biquads at 48 kHz, as NAudio builds them on Windows. Plain Swift: tested on Windows.

public enum PeerEqMode: Int, Codable, CaseIterable, Sendable {
    case simple3Band = 0, advanced12Band = 1, parametric16Band = 2

    /// What the EQ mode list says.
    public var title: String {
        switch self {
        case .simple3Band: "3 band simple EQ"
        case .advanced12Band: "12 band advanced graphic EQ"
        case .parametric16Band: "16 band parametric EQ"
        }
    }

    /// What the log says (Windows' enum names).
    public var logName: String {
        switch self {
        case .simple3Band: "Simple3Band"
        case .advanced12Band: "Advanced10Band"
        case .parametric16Band: "Parametric16Band"
        }
    }
}

/// One parametric band: a boost or cut across startHz...endHz.
public struct ParametricBand: Codable, Equatable, Sendable {
    public var startHz: Float, endHz: Float, gainDb: Float
    public init(startHz: Float, endHz: Float, gainDb: Float) {
        self.startHz = startHz
        self.endHz = endHz
        self.gainDb = gainDb
    }

    /// Its row in the bands list: "200 Hz to 2000 Hz, plus 3 dB".
    public var row: String {
        "\(Int(startHz.rounded())) Hz to \(Int(endHz.rounded())) Hz, \(PeerEqBands.spokenPrecise(gainDb))"
    }
}

/// A peer's EQ: which mode is heard, and each mode's own settings.
public struct PeerEq: Equatable, Sendable {
    public var mode: PeerEqMode
    public var simpleDb: [Float]
    public var advancedDb: [Float]
    public var parametric: [ParametricBand]

    public init(mode: PeerEqMode = .simple3Band, simpleDb: [Float] = [0, 0, 0],
                advancedDb: [Float] = [Float](repeating: 0, count: 12), parametric: [ParametricBand] = []) {
        self.mode = mode
        self.simpleDb = Self.sized(simpleDb, PeerEqBands.simple.count)
        self.advancedDb = Self.sized(advancedDb, PeerEqBands.advanced.count)
        self.parametric = Array(parametric.prefix(PeerEqBands.parametricMaxBands))
    }

    /// "Set peer EQ to default": every mode flat (the mode itself is kept).
    public mutating func reset() {
        simpleDb = [Float](repeating: 0, count: PeerEqBands.simple.count)
        advancedDb = [Float](repeating: 0, count: PeerEqBands.advanced.count)
        parametric = []
    }

    /// The bands the list shows, bass to treble (by start, then end), each with its index in `parametric`.
    public var parametricInOrder: [(index: Int, band: ParametricBand)] {
        parametric.enumerated().map { ($0.offset, $0.element) }
            .sorted { $0.band.startHz != $1.band.startHz ? $0.band.startHz < $1.band.startHz : $0.band.endHz < $1.band.endHz }
    }

    /// Nudge the given bands (indices into `parametric`) by `step` dB, kept within +/-12 (the list's Left and Right).
    public mutating func nudge(_ indices: [Int], by step: Float) {
        for i in indices where parametric.indices.contains(i) {
            parametric[i].gainDb = min(PeerEqBands.maxGainDb, max(-PeerEqBands.maxGainDb, parametric[i].gainDb + step))
        }
    }

    static func sized(_ values: [Float], _ count: Int) -> [Float] {
        Array((values + [Float](repeating: 0, count: count)).prefix(count))
    }
}

public enum PeerEqBands {
    public static let sampleRate = 48_000.0
    public static let maxGainDb: Float = 12
    public static let parametricMaxBands = 16
    public static let parametricMinHz: Float = 20
    public static let parametricMaxHz: Float = 20_000
    public static let simple: [(label: String, hz: Double)] = [("Bass", 100), ("Mids", 1000), ("Treble", 8000)]
    public static let advanced: [(label: String, hz: Double)] = [
        ("31 Hz", 31), ("63 Hz", 63), ("80 Hz", 80), ("125 Hz", 125), ("250 Hz", 250), ("500 Hz", 500),
        ("1 kHz", 1000), ("2 kHz", 2000), ("4 kHz", 4000), ("6 kHz", 6000), ("8 kHz", 8000), ("16 kHz", 16000),
    ]

    /// A parametric range as a peaking filter: centred on the edges' geometric mean, its Q from the width in octaves.
    public static func peaking(startHz: Float, endHz: Float) -> (centreHz: Float, q: Float) {
        let start = min(parametricMaxHz, max(parametricMinHz, startHz))
        var end = min(parametricMaxHz, max(parametricMinHz, endHz))
        if end <= start { end = min(start * 1.01, parametricMaxHz) }
        let octaves = max(0.01, log2(end / start))
        let twoPow = pow(2, octaves)
        return ((start * end).squareRoot(), min(12, max(0.1, twoPow.squareRoot() / (twoPow - 1))))
    }

    // The graphic sliders: 0...100, 50 flat, 100 is +12 dB (0.24 dB a step).
    public static func db(slider: Int) -> Float { Float(slider - 50) / 50 * maxGainDb }
    public static func slider(db: Float) -> Int { min(100, max(0, Int((db / maxGainDb * 50).rounded()) + 50)) }

    /// A graphic slider's gain in words (whole dB; screen readers with punctuation off would miss a "+").
    public static func spoken(_ db: Float) -> String {
        if abs(db) < 0.5 { return "flat" }
        return (db > 0 ? "plus " : "minus ") + "\(Int(abs(db).rounded())) dB"
    }

    /// A parametric band's gain in words, to one decimal where it has one.
    public static func spokenPrecise(_ db: Float) -> String {
        if abs(db) < 0.05 { return "flat" }
        return (db > 0 ? "plus " : "minus ") + oneDecimal(abs(db)) + " dB"
    }

    /// Windows' "0.#": up to one decimal, none if it would be .0, halves away from zero.
    public static func oneDecimal(_ value: Float) -> String {
        let tenths = Int((value * 10).rounded())
        return tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths < 0 ? "-" : "")\(abs(tenths) / 10).\(abs(tenths) % 10)"
    }

    /// The Add EQ band dialog's check (Windows' AddBandDialog): both frequencies 20 to 20000 Hz, the end above the
    /// start, the gain clamped to +/-12 (blank or unreadable is 0). The refusal is a heading and a sentence.
    public static func band(start: String, end: String, gain: String) -> Result<ParametricBand, BandRefusal> {
        func hz(_ text: String) -> Float? {
            guard let v = Float(text.trimmingCharacters(in: .whitespaces)), v >= parametricMinHz, v <= parametricMaxHz
            else { return nil }
            return v
        }
        guard let s = hz(start), let e = hz(end) else {
            return .failure(BandRefusal(heading: "Enter both frequencies",
                text: "Enter a start and an end frequency, each between 20 and 20000 Hz.", endField: false))
        }
        guard e > s else {
            return .failure(BandRefusal(heading: "End frequency must be higher than start",
                text: "The end frequency (\(Int(e.rounded())) Hz) must be higher than the start frequency (\(Int(s.rounded())) Hz). Adjust one of them and try again.",
                endField: true))
        }
        let g = Float(gain.trimmingCharacters(in: .whitespaces)) ?? 0
        return .success(ParametricBand(startHz: s, endHz: e, gainDb: min(maxGainDb, max(-maxGainDb, g))))
    }

    public struct BandRefusal: Error, Equatable {
        public let heading: String, text: String
        /// Whether to put the cursor in the end frequency (else the start).
        public let endField: Bool
    }
}

/// One RBJ biquad, direct form 1, both channels.
public struct Biquad {
    let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var x1 = [0.0, 0.0], x2 = [0.0, 0.0], y1 = [0.0, 0.0], y2 = [0.0, 0.0]

    init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    public static func peaking(hz: Double, q: Double, db: Double) -> Biquad {
        let w = 2 * Double.pi * hz / PeerEqBands.sampleRate, c = cos(w), alpha = sin(w) / (2 * q)
        let a = pow(10, db / 40)
        return Biquad(b0: 1 + alpha * a, b1: -2 * c, b2: 1 - alpha * a, a0: 1 + alpha / a, a1: -2 * c, a2: 1 - alpha / a)
    }

    public static func lowShelf(hz: Double, slope: Double, db: Double) -> Biquad {
        let (a, c, root) = shelf(hz: hz, slope: slope, db: db)
        return Biquad(b0: a * ((a + 1) - (a - 1) * c + root), b1: 2 * a * ((a - 1) - (a + 1) * c),
                      b2: a * ((a + 1) - (a - 1) * c - root), a0: (a + 1) + (a - 1) * c + root,
                      a1: -2 * ((a - 1) + (a + 1) * c), a2: (a + 1) + (a - 1) * c - root)
    }

    public static func highShelf(hz: Double, slope: Double, db: Double) -> Biquad {
        let (a, c, root) = shelf(hz: hz, slope: slope, db: db)
        return Biquad(b0: a * ((a + 1) + (a - 1) * c + root), b1: -2 * a * ((a - 1) + (a + 1) * c),
                      b2: a * ((a + 1) + (a - 1) * c - root), a0: (a + 1) - (a - 1) * c + root,
                      a1: 2 * ((a - 1) - (a + 1) * c), a2: (a + 1) - (a - 1) * c - root)
    }

    private static func shelf(hz: Double, slope: Double, db: Double) -> (a: Double, c: Double, root: Double) {
        let w = 2 * Double.pi * hz / PeerEqBands.sampleRate
        let a = pow(10, db / 40)
        let alpha = sin(w) / 2 * ((a + 1 / a) * (1 / slope - 1) + 2).squareRoot()
        return (a, cos(w), 2 * a.squareRoot() * alpha)
    }

    /// The filter's gain at a frequency, in dB (from its coefficients, for tests).
    func responseDb(hz: Double) -> Double {
        let w = 2 * Double.pi * hz / PeerEqBands.sampleRate
        func mag(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
            let re = c0 + c1 * cos(w) + c2 * cos(2 * w), im = -(c1 * sin(w) + c2 * sin(2 * w))
            return (re * re + im * im).squareRoot()
        }
        return 20 * log10(mag(b0, b1, b2) / mag(1, a1, a2))
    }

    public mutating func process(_ x: Double, channel: Int) -> Double {
        let y = b0 * x + b1 * x1[channel] + b2 * x2[channel] - a1 * y1[channel] - a2 * y2[channel]
        x2[channel] = x1[channel]
        x1[channel] = x
        y2[channel] = y1[channel]
        y1[channel] = y.isFinite ? y : 0
        return y1[channel]
    }
}

/// A peer's EQ as filters, rebuilt only when its settings change. Interleaved stereo at 48 kHz.
public final class PeerEqualizer {
    private var built: PeerEq?
    private var filters: [Biquad] = []
    public init() {}

    /// How many filters the active mode needs (flat bands need none).
    public var bandCount: Int { filters.count }

    public func configure(_ eq: PeerEq) {
        guard eq != built else { return }
        built = eq
        filters = Self.filters(for: eq)
    }

    static func filters(for eq: PeerEq) -> [Biquad] {
        let clamp = { (db: Float) in Double(min(PeerEqBands.maxGainDb, max(-PeerEqBands.maxGainDb, db))) }
        switch eq.mode {
        case .parametric16Band:
            return eq.parametric.compactMap { band in
                guard abs(band.gainDb) >= 0.05 else { return nil }
                let (centre, q) = PeerEqBands.peaking(startHz: band.startHz, endHz: band.endHz)
                guard centre > 0, Double(centre) < PeerEqBands.sampleRate / 2 else { return nil }
                return Biquad.peaking(hz: Double(centre), q: Double(q), db: clamp(band.gainDb))
            }
        case .advanced12Band:
            return zip(PeerEqBands.advanced, eq.advancedDb).compactMap { band, db in
                abs(db) < 0.05 ? nil : Biquad.peaking(hz: band.hz, q: 1.4, db: clamp(db))
            }
        case .simple3Band:
            return zip(PeerEqBands.simple.indices, eq.simpleDb).compactMap { i, db in
                guard abs(db) >= 0.05 else { return nil }
                let hz = PeerEqBands.simple[i].hz
                switch i {
                case 0: return Biquad.lowShelf(hz: hz, slope: 0.7, db: clamp(db))
                case PeerEqBands.simple.count - 1: return Biquad.highShelf(hz: hz, slope: 0.7, db: clamp(db))
                default: return Biquad.peaking(hz: hz, q: 0.9, db: clamp(db))
                }
            }
        }
    }

    public func process(_ samples: [Float]) -> [Float] {
        guard !filters.isEmpty else { return samples }
        var output = samples
        for i in output.indices {
            var v = Double(output[i].isFinite ? output[i] : 0)
            for b in filters.indices { v = filters[b].process(v, channel: i % 2) }
            output[i] = Float(v.isFinite ? v : 0)
        }
        return output
    }
}
