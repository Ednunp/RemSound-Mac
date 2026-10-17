import Foundation
import XCTest

@testable import RemSoundJam

/// Per-peer EQ: Windows' three modes, their filters, and the words the controls speak.
final class PeerEqTests: XCTestCase {
    func total(_ filters: [Biquad], _ hz: Double) -> Double { filters.reduce(0) { $0 + $1.responseDb(hz: hz) } }

    func testTheThreeBandToneControlIsWindowsShelvesAndPeak() {
        let bass = PeerEqualizer.filters(for: PeerEq(simpleDb: [6, 0, 0]))
        XCTAssertEqual(bass.count, 1, "flat bands need no filter")
        XCTAssertEqual(bass[0].responseDb(hz: 1), 6, accuracy: 0.01, "a low shelf: the whole boost at the bottom")
        XCTAssertEqual(bass[0].responseDb(hz: 100), 3, accuracy: 0.3, "half of it at its 100 Hz corner")
        XCTAssertEqual(bass[0].responseDb(hz: 5000), 0, accuracy: 0.05)
        let mids = PeerEqualizer.filters(for: PeerEq(simpleDb: [0, -9, 0]))
        XCTAssertEqual(mids[0].responseDb(hz: 1000), -9, accuracy: 0.01, "a peak at 1 kHz")
        let treble = PeerEqualizer.filters(for: PeerEq(simpleDb: [0, 0, 4]))
        XCTAssertEqual(treble[0].responseDb(hz: 23_999), 4, accuracy: 0.05, "a high shelf: the whole boost at the top")
        XCTAssertEqual(treble[0].responseDb(hz: 8000), 2, accuracy: 0.3, "half at its 8 kHz corner")
        XCTAssertEqual(treble[0].responseDb(hz: 100), 0, accuracy: 0.05)
        // Their shapes, pinned against the Audio EQ Cookbook worked out separately (Python, 2026-09-30): slope 0.7, Q 0.9.
        XCTAssertEqual(bass[0].responseDb(hz: 200), 0.837, accuracy: 0.005)
        XCTAssertEqual(treble[0].responseDb(hz: 4000), 0.462, accuracy: 0.005)
        XCTAssertEqual(mids[0].responseDb(hz: 2000), -3.259, accuracy: 0.005)
    }

    func testTheTwelveBandGraphicEqPeaksAtItsCentres() {
        var gains = [Float](repeating: 0, count: 12)
        gains[6] = 12      // 1 kHz
        gains[9] = -6      // 6 kHz
        let filters = PeerEqualizer.filters(for: PeerEq(mode: .advanced12Band, advancedDb: gains))
        XCTAssertEqual(filters.count, 2)
        XCTAssertEqual(filters[0].responseDb(hz: 1000), 12, accuracy: 0.01)
        XCTAssertEqual(filters[1].responseDb(hz: 6000), -6, accuracy: 0.01)
        XCTAssertEqual(PeerEqBands.advanced.map(\.hz), [31, 63, 80, 125, 250, 500, 1000, 2000, 4000, 6000, 8000, 16000])
        // Q 1.4: an octave away from 1 kHz, the 12 dB peak is down to 2.53 dB (the Cookbook worked out separately).
        XCTAssertEqual(filters[0].responseDb(hz: 2000), 2.527, accuracy: 0.005)
    }

    func testAParametricBandSpansItsRange() {
        let (centre, q) = PeerEqBands.peaking(startHz: 200, endHz: 2000)
        XCTAssertEqual(centre, 632.456, accuracy: 0.01, "the geometric middle")
        XCTAssertEqual(q, Float(10.0.squareRoot() / 9), accuracy: 1e-4, "3.32 octaves wide")
        let filters = PeerEqualizer.filters(for: PeerEq(mode: .parametric16Band,
            parametric: [ParametricBand(startHz: 200, endHz: 2000, gainDb: 6)]))
        XCTAssertEqual(filters[0].responseDb(hz: 632.456), 6, accuracy: 0.01)
        XCTAssertEqual(filters[0].responseDb(hz: 200), 2.998, accuracy: 0.005, "half the boost at the range's edge")
        // Edges held to 20...20000; an end not above the start is 1% above it; Q held to 0.1...12.
        XCTAssertEqual(PeerEqBands.peaking(startHz: 5, endHz: 40).centreHz, (20 * 40 as Float).squareRoot(), accuracy: 0.01)
        XCTAssertEqual(PeerEqBands.peaking(startHz: 1000, endHz: 900).q, 12, "1000 to 1010 Hz is narrower than Q 12 allows")
        XCTAssertEqual(PeerEqBands.peaking(startHz: 20, endHz: 20000).q, 0.1, accuracy: 0.001)
    }

    func testOnlyTheActiveModeIsHeardAndEachKeepsItsOwn() {
        var eq = PeerEq(simpleDb: [3, 0, 0], advancedDb: [Float](repeating: 2, count: 12),
                        parametric: [ParametricBand(startHz: 100, endHz: 400, gainDb: 5)])
        XCTAssertEqual(PeerEqualizer.filters(for: eq).count, 1)
        eq.mode = .advanced12Band
        XCTAssertEqual(PeerEqualizer.filters(for: eq).count, 12)
        eq.mode = .parametric16Band
        XCTAssertEqual(PeerEqualizer.filters(for: eq).count, 1)
        XCTAssertEqual(eq.simpleDb, [3, 0, 0], "switching keeps the others")
        eq.reset()
        XCTAssertEqual(eq, PeerEq(mode: .parametric16Band), "Set peer EQ to default flattens all three, keeping the mode")
        XCTAssertEqual(PeerEqualizer.filters(for: eq).count, 0)
    }

    func testAGainFromAHandEditedProfileIsHeldToTwelveDecibels() {
        let wild = PeerEqualizer.filters(for: PeerEq(mode: .advanced12Band,
            advancedDb: [0, 0, 0, 0, 0, 0, 100, 0, 0, 0, 0, 0]))
        XCTAssertEqual(wild[0].responseDb(hz: 1000), 12, accuracy: 0.01)
        let tiny = PeerEq(simpleDb: [0.04, -0.04, 0.049])
        XCTAssertEqual(PeerEqualizer.filters(for: tiny).count, 0, "under 0.05 dB is flat")
        XCTAssertEqual(PeerEq(simpleDb: [1], advancedDb: [1, 2]).advancedDb.count, 12, "short lists are filled out")
        XCTAssertEqual(PeerEq(parametric: [ParametricBand](repeating: ParametricBand(startHz: 1, endHz: 2, gainDb: 1), count: 20)).parametric.count, 16)
    }

    func testTheEqualizerShapesASineAsItsFiltersSay() {
        let eq = PeerEqualizer()
        var gains = [Float](repeating: 0, count: 12)
        gains[6] = 12
        eq.configure(PeerEq(mode: .advanced12Band, advancedDb: gains))
        XCTAssertEqual(eq.bandCount, 1)
        let input = (0..<9600).flatMap { n -> [Float] in
            let v = Float(0.05 * sin(2 * Double.pi * 1000 * Double(n) / 48000))
            return [v, v]
        }
        let output = eq.process(input)
        func rms(_ s: ArraySlice<Float>) -> Double { (s.reduce(0) { $0 + Double($1 * $1) } / Double(s.count)).squareRoot() }
        XCTAssertEqual(20 * log10(rms(output[9600...]) / rms(input[9600...])), 12, accuracy: 0.1)
        eq.configure(PeerEq())
        XCTAssertEqual(eq.process(input), input, "flat passes the sound through untouched")
    }

    func testTheGraphicSlidersReadAsWindowsSpeaksThem() {
        XCTAssertEqual(PeerEqBands.db(slider: 50), 0)
        XCTAssertEqual(PeerEqBands.db(slider: 100), 12)
        XCTAssertEqual(PeerEqBands.db(slider: 0), -12)
        XCTAssertEqual(PeerEqBands.db(slider: 51), 0.24, accuracy: 1e-6)
        XCTAssertEqual(PeerEqBands.slider(db: 6), 75)
        XCTAssertEqual(PeerEqBands.slider(db: -40), 0)
        XCTAssertEqual(PeerEqBands.spoken(0.4), "flat")
        XCTAssertEqual(PeerEqBands.spoken(PeerEqBands.db(slider: 61)), "plus 3 dB", "2.64 dB, whole")
        XCTAssertEqual(PeerEqBands.spoken(-6), "minus 6 dB")
        XCTAssertEqual(PeerEqBands.spokenPrecise(1.5), "plus 1.5 dB")
        XCTAssertEqual(PeerEqBands.spokenPrecise(3), "plus 3 dB")
        XCTAssertEqual(PeerEqBands.spokenPrecise(-0.25), "minus 0.3 dB", "halves away from zero")
        XCTAssertEqual(PeerEqBands.spokenPrecise(0.04), "flat")
        XCTAssertEqual(PeerEqMode.allCases.map(\.title),
                       ["3 band simple EQ", "12 band advanced graphic EQ", "16 band parametric EQ"])
        XCTAssertEqual(PeerEqMode.advanced12Band.logName, "Advanced10Band", "the log keeps Windows' names")
    }

    func testTheBandsListReadsBassToTrebleAndArrowsNudgeHalfADecibel() {
        var eq = PeerEq(mode: .parametric16Band, parametric: [
            ParametricBand(startHz: 2000, endHz: 8000, gainDb: -2),
            ParametricBand(startHz: 200, endHz: 2000, gainDb: 3),
            ParametricBand(startHz: 200, endHz: 900, gainDb: 11.8),
        ])
        XCTAssertEqual(eq.parametricInOrder.map(\.band.row),
                       ["200 Hz to 900 Hz, plus 11.8 dB", "200 Hz to 2000 Hz, plus 3 dB", "2000 Hz to 8000 Hz, minus 2 dB"])
        XCTAssertEqual(eq.parametricInOrder.map(\.index), [2, 1, 0])
        eq.nudge([2, 1], by: 0.5)
        XCTAssertEqual(eq.parametric.map(\.gainDb), [-2, 3.5, 12], "held at +12")
        eq.nudge([0], by: -0.5)
        XCTAssertEqual(eq.parametric[0].gainDb, -2.5)
    }

    func testTheAddBandDialogWantsTwoFrequenciesTheEndAbove() {
        XCTAssertEqual(try? PeerEqBands.band(start: "200", end: "2000", gain: "3").get(),
                       ParametricBand(startHz: 200, endHz: 2000, gainDb: 3))
        XCTAssertEqual(try? PeerEqBands.band(start: " 200 ", end: "2000", gain: "40").get().gainDb, 12)
        XCTAssertEqual(try? PeerEqBands.band(start: "200", end: "2000", gain: "").get().gainDb, 0)
        guard case let .failure(blank) = PeerEqBands.band(start: "", end: "2000", gain: "3") else { return XCTFail() }
        XCTAssertEqual(blank.heading, "Enter both frequencies")
        XCTAssertFalse(blank.endField)
        guard case .failure = PeerEqBands.band(start: "10", end: "2000", gain: "3") else { return XCTFail("under 20 Hz") }
        guard case .failure = PeerEqBands.band(start: "200", end: "20001", gain: "3") else { return XCTFail("over 20 kHz") }
        guard case let .failure(backwards) = PeerEqBands.band(start: "2000", end: "200", gain: "3") else { return XCTFail() }
        XCTAssertEqual(backwards.heading, "End frequency must be higher than start")
        XCTAssertTrue(backwards.text.contains("(200 Hz) must be higher than the start frequency (2000 Hz)"))
        XCTAssertTrue(backwards.endField)
    }
}
