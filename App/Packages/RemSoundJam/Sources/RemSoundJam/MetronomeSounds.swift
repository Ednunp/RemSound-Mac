import Foundation

/// The time signatures the Metronome settings window offers (Windows MetronomeSignature.Offered).
extension MetronomeSignature {
    public static let offered: [MetronomeSignature] = [
        .init(2, 4), .init(3, 4), .init(4, 4), .init(5, 4), .init(6, 8), .init(7, 8), .init(9, 8), .init(12, 8),
    ]
}

/// Where you hear your own metronome (Windows MetronomeHearIn).
public enum MetronomeHearIn: String, Codable, CaseIterable, Sendable {
    /// In RemSound's own outputs (the default).
    case remSound
    /// In the DAW: a track whose RemSound plugin chooses "Metronome" in its peer list.
    case daw

    public var title: String {
        switch self {
        case .remSound: return "In RemSound (your outputs)"
        case .daw: return "In the DAW (choose Metronome on a track's RemSound plugin)"
        }
    }
    public var spoken: String { self == .daw ? "in the DAW" : "in RemSound" }
}

/// THE METRONOME IN THE DAW (Windows MetronomeDaw): with "In the DAW" chosen, "Metronome" is one more entry in the
/// RemSound plugin's peer list, at an address no peer can have - 0.0.0.1, in 0.0.0.0/8, which nothing routes. A track that
/// claims it gets the clicks in its blocks. A plugin that knows nothing of it sees one more name in its list.
public enum MetronomeDAW {
    public static let address = "0.0.0.1"
    public static let name = "Metronome"
    /// From a block being asked for by a DAW track to it being played: the plugin's lead, in blocks (Windows' 3).
    public static let leadBlocks = 3
    public static func isPseudoPeer(_ address: String) -> Bool { address == Self.address }
}

/// THE METRONOME'S SETTINGS, per profile (Windows MetronomeSettings, Ed 2026-09-28): they belong with the session's setup.
/// The volume is the profile's metronomeVolume, kept where it already was. Anything that does something on its own is off
/// in a new profile: the click stays out of recordings and a master is asked about.
public struct MetronomeChoices: Codable, Equatable, Sendable {
    public var bpm = Int(MetronomeTimeline.defaultBpm)
    public var beatsPerBar = 4
    public var beatUnit = 4
    public var sound = MetronomeSoundLibrary.defaultName
    public var hearIn = MetronomeHearIn.remSound
    /// With "In RemSound": the click is recorded too. Off unless chosen.
    public var includeInRecordings = false
    /// "ask" or "accept" (Windows' two answers).
    public var acceptMasterAutomatically = false

    public init() {}

    public var signature: MetronomeSignature {
        let unit = [1, 2, 4, 8, 16, 32].contains(beatUnit) ? beatUnit : 4
        return MetronomeSignature(UInt8(min(max(beatsPerBar, 1), 32)), UInt8(unit))
    }
    public var clampedBpm: Int { min(max(bpm, Int(MetronomeTimeline.minBpm)), Int(MetronomeTimeline.maxBpm)) }
    public var whenAsked: ServerMetronome.WhenAsked { acceptMasterAutomatically ? .acceptAutomatically : .ask }
    /// The click goes into RemSound's recordings: heard in RemSound and chosen. A DAW records its own tracks.
    public var recorded: Bool { includeInRecordings && hearIn == .remSound }

    public func describe(volume: Int) -> String {
        "\(clampedBpm) bpm \(signature), sound \(sound), volume \(min(max(volume, 0), 100)) %, heard \(hearIn.spoken), "
            + "recorded \(recorded ? "yes" : "no"), a master is \(acceptMasterAutomatically ? "accepted automatically" : "asked about")"
    }

    private enum CodingKeys: String, CodingKey {
        case bpm, beatsPerBar, beatUnit, sound, hearIn, includeInRecordings, acceptMasterAutomatically
    }
    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        bpm = try v.decodeIfPresent(Int.self, forKey: .bpm) ?? Int(MetronomeTimeline.defaultBpm)
        beatsPerBar = try v.decodeIfPresent(Int.self, forKey: .beatsPerBar) ?? 4
        beatUnit = try v.decodeIfPresent(Int.self, forKey: .beatUnit) ?? 4
        sound = try v.decodeIfPresent(String.self, forKey: .sound) ?? MetronomeSoundLibrary.defaultName
        hearIn = (try? v.decodeIfPresent(MetronomeHearIn.self, forKey: .hearIn)) ?? .remSound
        includeInRecordings = try v.decodeIfPresent(Bool.self, forKey: .includeInRecordings) ?? false
        acceptMasterAutomatically = try v.decodeIfPresent(Bool.self, forKey: .acceptMasterAutomatically) ?? false
    }
}

/// A WAV file as interleaved stereo at 48 kHz, its leading silence taken off so the click starts on its first sample -
/// the moment the metronome places (Windows MetronomeSound.LoadStereo). PCM 8, 16, 24 or 32 bit, or 32-bit float; mono
/// or stereo; at most four seconds. Nil when it will not open.
public enum MetronomeWAV {
    public static let sampleRate = 48_000
    static let maximumSeconds = 4

    public static func stereo48k(_ data: Data) -> [Float]? {
        let b = [UInt8](data)
        guard b.count >= 12, b[0..<4] == [0x52, 0x49, 0x46, 0x46], b[8..<12] == [0x57, 0x41, 0x56, 0x45] else { return nil }
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        var format = 0, channels = 0, rate = 0, bits = 0
        var dataRange: Range<Int>?
        var at = 12
        while at + 8 <= b.count {
            let id = String(decoding: b[at..<(at + 4)], as: UTF8.self), size = u32(at + 4), body = at + 8
            guard size >= 0, body + size <= b.count || id == "data" else { return nil }
            if id == "fmt ", size >= 16 {
                format = u16(body); channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
                if format == 0xFFFE, size >= 26 { format = u16(body + 24) }   // WAVE_FORMAT_EXTENSIBLE: the subformat's tag
            } else if id == "data" {
                dataRange = body..<min(b.count, body + size)
                break
            }
            at = body + size + (size & 1)
        }
        guard let range = dataRange, (1...2).contains(channels), rate >= 8_000, rate <= 384_000 else { return nil }
        let bytes = bits / 8
        guard (format == 1 && [1, 2, 3, 4].contains(bytes)) || (format == 3 && bytes == 4) else { return nil }
        let frameBytes = bytes * channels
        let frames = min(range.count / frameBytes, rate * maximumSeconds)
        var stereo = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            for c in 0..<channels {
                let i = range.lowerBound + f * frameBytes + c * bytes
                let v: Float
                switch (format, bytes) {
                case (3, _): v = Float(bitPattern: UInt32(u32(i)))
                case (_, 1): v = (Float(b[i]) - 128) / 128
                case (_, 2): v = Float(Int16(bitPattern: UInt16(u16(i)))) / 32_768
                case (_, 3): v = Float(Int32(bitPattern: UInt32(u16(i) << 8 | Int(b[i + 2]) << 24)) >> 8) / 8_388_608
                default: v = Float(Int32(bitPattern: UInt32(truncatingIfNeeded: u32(i)))) / 2_147_483_648
                }
                stereo[2 * f + c] = v
                if channels == 1 { stereo[2 * f + 1] = v }
            }
        }
        var first = 0
        while first + 1 < stereo.count && abs(stereo[first]) < 1e-3 && abs(stereo[first + 1]) < 1e-3 { first += 2 }
        guard first < stereo.count else { return nil }
        return resample(Array(stereo[first...]), from: rate, to: sampleRate)
    }

    /// Linear interpolation: no filter, so no delay - the click's first sample stays its first sample.
    public static func resample(_ stereo: [Float], from: Int, to: Int) -> [Float] {
        guard from != to, !stereo.isEmpty else { return stereo }
        let frames = stereo.count / 2
        let outFrames = Int(Int64(frames) * Int64(to) / Int64(from))
        var result = [Float](repeating: 0, count: outFrames * 2)
        for f in 0..<outFrames {
            let pos = Double(f) * Double(from) / Double(to)
            let i = Int(pos), frac = Float(pos - Double(i))
            for c in 0..<2 {
                let a = stereo[min(i, frames - 1) * 2 + c], b = stereo[min(i + 1, frames - 1) * 2 + c]
                result[f * 2 + c] = a + (b - a) * frac
            }
        }
        return result
    }
}

/// The click sounds on offer (Windows MetronomeSoundLibrary): the shipped ones in "default sounds/metronome", and a
/// person's own in a "Metronome sounds" folder beside their profiles - "<name> accent.wav" with "<name> beat.wav", or one
/// "<name>.wav" for both. Listed by name, shipped first in the order Ed's list gives them.
public enum MetronomeSoundLibrary {
    public static let userFolderName = "Metronome sounds"
    public static let shippedNames = ["Click", "Woodblock", "Beep", "Rim", "Cowbell"]
    public static let defaultName = shippedNames[0]

    /// Every sound name on offer: the shipped ones, then a person's own (a name already shipped is not offered twice).
    public static func names(shipped: URL?, user: URL?) -> [String] {
        var names = shippedNames.filter { name in shipped.map { paths(in: $0, for: name) != nil } ?? false }
        for name in pairNames(user) where !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            names.append(name)
        }
        return names
    }

    /// The names a folder holds a sound for, sorted.
    static func pairNames(_ directory: URL?) -> [String] {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var seen = Set<String>(), result: [String] = []
        for file in files where file.lowercased().hasSuffix(".wav") {
            var stem = String(file.dropLast(4))
            if stem.lowercased().hasSuffix(" accent") { stem = String(stem.dropLast(7)) }
            else if stem.lowercased().hasSuffix(" beat") { stem = String(stem.dropLast(5)) }
            guard !stem.isEmpty, paths(in: directory, for: stem) != nil, seen.insert(stem.lowercased()).inserted else { continue }
            result.append(stem)
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The two files for a name in a folder: the accent and the beat, or the one file for both.
    static func paths(in directory: URL, for name: String) -> (accent: URL, beat: URL)? {
        let fm = FileManager.default
        let accent = directory.appendingPathComponent(name + " accent.wav"), beat = directory.appendingPathComponent(name + " beat.wav")
        if fm.fileExists(atPath: accent.path) && fm.fileExists(atPath: beat.path) { return (accent, beat) }
        let single = directory.appendingPathComponent(name + ".wav")
        return fm.fileExists(atPath: single.path) ? (single, single) : nil
    }

    /// Load a sound by name - a person's own first, so they can replace a shipped one. Nil when there is none.
    public static func load(_ name: String, shipped: URL?, user: URL?) -> MetronomeClickSound? {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              let p = user.flatMap({ paths(in: $0, for: name) }) ?? shipped.flatMap({ paths(in: $0, for: name) }),
              let accentData = try? Data(contentsOf: p.accent), let accent = MetronomeWAV.stereo48k(accentData) else { return nil }
        let beat: [Float]
        if p.beat == p.accent { beat = accent } else {
            guard let beatData = try? Data(contentsOf: p.beat), let loaded = MetronomeWAV.stereo48k(beatData) else { return nil }
            beat = loaded
        }
        return MetronomeClickSound(stereoAccent: accent, stereoNormal: beat)
    }
}
