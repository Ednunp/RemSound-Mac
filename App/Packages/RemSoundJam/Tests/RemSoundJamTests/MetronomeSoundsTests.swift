import Foundation
import XCTest
@testable import RemSoundJam

/// The click sounds (Windows MetronomeSoundLibrary and MetronomeSound.LoadStereo) and the profile's metronome settings.
final class MetronomeSoundsTests: XCTestCase {
    /// A WAV file: PCM `bits` (or float when `float`), the samples given per channel, interleaved.
    private func wav(rate: Int, channels: Int, bits: Int, float: Bool = false, _ samples: [Float]) -> Data {
        var body = [UInt8]()
        for s in samples {
            switch (float, bits) {
            case (true, _): withUnsafeBytes(of: s.bitPattern.littleEndian) { body += $0 }
            case (_, 16): withUnsafeBytes(of: Int16(max(-32_768, min(32_767, (s * 32_768).rounded()))).littleEndian) { body += $0 }
            default:
                let v = Int32(max(-8_388_608, min(8_388_607, (s * 8_388_608).rounded())))
                body += [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16)]
            }
        }
        func le32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(v).littleEndian) { Array($0) } }
        func le16(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt16(v).littleEndian) { Array($0) } }
        let block = channels * bits / 8
        var fmt = le16(float ? 3 : 1) + le16(channels) + le32(rate) + le32(rate * block) + le16(block) + le16(bits)
        fmt = Array("fmt ".utf8) + le32(fmt.count) + fmt
        let list = Array("LIST".utf8) + le32(3) + [1, 2, 3, 0]   // an odd-sized chunk before the data, padded
        let data = Array("data".utf8) + le32(body.count) + body
        let riff = Array("WAVE".utf8) + fmt + list + data
        return Data(Array("RIFF".utf8) + le32(riff.count) + riff)
    }

    func testAStereoWavAt48kOpensWithItsLeadingSilenceTakenOff() throws {
        let file = wav(rate: 48_000, channels: 2, bits: 16, [0, 0, 0, 0, 0.5, -0.25, 0.25, 0.125])
        let got = try XCTUnwrap(MetronomeWAV.stereo48k(file))
        XCTAssertEqual(got.count, 4, "two silent frames taken off")
        XCTAssertEqual(got[0], 0.5, accuracy: 1e-4)
        XCTAssertEqual(got[1], -0.25, accuracy: 1e-4)
        XCTAssertEqual(got[3], 0.125, accuracy: 1e-4)
    }

    func testMonoIsPlayedOnBothSidesAnd24BitAndFloatOpen() throws {
        let mono = try XCTUnwrap(MetronomeWAV.stereo48k(wav(rate: 48_000, channels: 1, bits: 24, [0.5, -0.5])))
        XCTAssertEqual(mono.count, 4)
        XCTAssertEqual(mono[0], 0.5, accuracy: 1e-5)
        XCTAssertEqual(mono[1], 0.5, accuracy: 1e-5)
        XCTAssertEqual(mono[2], -0.5, accuracy: 1e-5)
        let float = try XCTUnwrap(MetronomeWAV.stereo48k(wav(rate: 48_000, channels: 2, bits: 32, float: true, [0.75, -0.75])))
        XCTAssertEqual(float, [0.75, -0.75])
    }

    func testAnotherRateIsMadeFortyEightKilohertzAndItsFirstSampleStaysFirst() throws {
        let frames = 4_410
        let samples = (0..<frames).flatMap { i -> [Float] in let v: Float = i == 0 ? 0.9 : 0.1; return [v, v] }
        let got = try XCTUnwrap(MetronomeWAV.stereo48k(wav(rate: 44_100, channels: 2, bits: 16, samples)))
        XCTAssertEqual(got.count / 2, 4_800, "a tenth of a second either way")
        XCTAssertEqual(got[0], 0.9, accuracy: 1e-3, "no filter delay: the click starts on its first sample")
    }

    func testWhatWillNotOpenIsRefused() {
        XCTAssertNil(MetronomeWAV.stereo48k(Data("not a wav".utf8)))
        XCTAssertNil(MetronomeWAV.stereo48k(wav(rate: 48_000, channels: 2, bits: 16, [0, 0, 0, 0])), "all silence")
        var sixChannels = [UInt8](wav(rate: 48_000, channels: 2, bits: 16, [0.5, 0.5]))
        sixChannels[22] = 6
        XCTAssertNil(MetronomeWAV.stereo48k(Data(sixChannels)))
    }

    func testTheShippedSoundsAreTheWindowsFiveAndAllOpen() throws {
        let shipped = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/default sounds/metronome", isDirectory: true)
        XCTAssertEqual(MetronomeSoundLibrary.names(shipped: shipped, user: nil), ["Click", "Woodblock", "Beep", "Rim", "Cowbell"])
        for name in MetronomeSoundLibrary.shippedNames {
            let sound = try XCTUnwrap(MetronomeSoundLibrary.load(name, shipped: shipped, user: nil), name)
            XCTAssertEqual(sound.channels, 2)
            XCTAssertGreaterThan(sound.accent.count, 200, name)
            XCTAssertGreaterThanOrEqual(abs(sound.accent[0]) + abs(sound.accent[1]), 1e-3, "\(name) starts at once")
        }
    }

    func testYourOwnSoundsFollowTheShippedOnesAndCanReplaceOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("metronome-\(UUID().uuidString)")
        let shipped = root.appendingPathComponent("shipped"), user = root.appendingPathComponent("user")
        try FileManager.default.createDirectory(at: shipped, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let loud = wav(rate: 48_000, channels: 1, bits: 16, [0.5]), soft = wav(rate: 48_000, channels: 1, bits: 16, [0.25])
        try loud.write(to: shipped.appendingPathComponent("Click accent.wav"))
        try loud.write(to: shipped.appendingPathComponent("Click beat.wav"))
        try soft.write(to: user.appendingPathComponent("Shaker.wav"))
        try soft.write(to: user.appendingPathComponent("Bell accent.wav"))
        try loud.write(to: user.appendingPathComponent("Bell beat.wav"))
        try loud.write(to: user.appendingPathComponent("Half accent.wav"))   // no beat: not a sound
        try soft.write(to: user.appendingPathComponent("click.wav"))         // replaces the shipped Click
        XCTAssertEqual(MetronomeSoundLibrary.names(shipped: shipped, user: user), ["Click", "Bell", "Shaker"])
        let bell = try XCTUnwrap(MetronomeSoundLibrary.load("Bell", shipped: shipped, user: user))
        XCTAssertEqual(bell.accent[0], 0.25, accuracy: 1e-4)
        XCTAssertEqual(bell.normal[0], 0.5, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(MetronomeSoundLibrary.load("Click", shipped: shipped, user: user)).accent[0], 0.25,
                       accuracy: 1e-4, "a person's own first")
        XCTAssertNil(MetronomeSoundLibrary.load("Half", shipped: shipped, user: user))
    }

    func testAStereoClickPlaysEachSideOnItsSample() {
        let sound = MetronomeClickSound(stereoAccent: [1, -1, 0.5, -0.5], stereoNormal: [0.25, -0.25])
        let player = MetronomeClickPlayer(sound: sound, gain: 1)
        let t = MetronomeTimeline(version: 1, running: true, milliBpm: 120_000, beatsPerBar: 4, beatUnit: 4, anchorBeat: 0, anchorTimeUs: 1_000_000)
        var block = [Float](repeating: 0, count: 8)
        player.render(into: &block, heardAtUs: 1_000_000, schedule: MetronomeSchedule(current: t, previous: nil, audible: true))
        XCTAssertEqual(block, [1, -1, 0.5, -0.5, 0, 0, 0, 0])
    }

    func testTheProfilesSettingsStartAsWindowsDoesAndOldProfilesReadThem() throws {
        let fresh = MetronomeChoices()
        XCTAssertEqual(fresh.clampedBpm, 120)
        XCTAssertEqual(fresh.signature, .default)
        XCTAssertEqual(fresh.sound, "Click")
        XCTAssertEqual(fresh.hearIn, .remSound)
        XCTAssertFalse(fresh.includeInRecordings)
        XCTAssertEqual(fresh.whenAsked, .ask)
        XCTAssertEqual(try JSONDecoder().decode(MetronomeChoices.self, from: Data("{}".utf8)), fresh)
        var changed = fresh
        changed.bpm = 96; changed.beatsPerBar = 12; changed.beatUnit = 8; changed.sound = "Rim"
        changed.hearIn = .daw; changed.includeInRecordings = true; changed.acceptMasterAutomatically = true
        XCTAssertEqual(try JSONDecoder().decode(MetronomeChoices.self, from: JSONEncoder().encode(changed)), changed)
        XCTAssertFalse(changed.recorded, "heard in the DAW: the DAW records its own tracks")
        XCTAssertEqual(changed.describe(volume: 70),
                       "96 bpm 12/8, sound Rim, volume 70 %, heard in the DAW, recorded no, a master is accepted automatically")
        XCTAssertEqual(MetronomeSignature.offered.map(\.description), ["2/4", "3/4", "4/4", "5/4", "6/8", "7/8", "9/8", "12/8"])
    }
}
