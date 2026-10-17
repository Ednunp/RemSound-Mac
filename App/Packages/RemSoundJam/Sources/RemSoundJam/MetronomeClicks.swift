import Foundation

/// What the outputs play clicks from: the timeline now, and the one before it (a tempo change lands at a bar line a moment
/// ahead, and the old beats carry on until then), and whether the clicks are heard at all (a follower can mute).
public struct MetronomeSchedule: Equatable, Sendable {
    public var current: MetronomeTimeline
    public var previous: MetronomeTimeline?
    public var audible: Bool
    public init(current: MetronomeTimeline, previous: MetronomeTimeline?, audible: Bool) {
        self.current = current
        self.previous = previous
        self.audible = audible
    }

    /// The beats falling in [fromUs, toUs), each with whether it is the bar's first - from the previous timeline before
    /// the current one's anchor, from the current one from its anchor on.
    public func beats(fromUs: Double, toUs: Double) -> [(timeUs: Double, accent: Bool)] {
        var result: [(Double, Bool)] = []
        let switchAt = current.running ? Double(current.anchorTimeUs) : Double.infinity
        if let previous, previous.running {
            var b = previous.beatAtOrAfter(fromUs)
            while true {
                let t = previous.beatTimeUs(b)
                if t >= toUs || t >= switchAt { break }
                result.append((t, previous.isAccent(b)))
                b += 1
            }
        }
        if current.running {
            var b = max(current.anchorBeat, current.beatAtOrAfter(fromUs))
            while true {
                let t = current.beatTimeUs(b)
                if t >= toUs { break }
                if t >= fromUs { result.append((t, current.isAccent(b))) }
                b += 1
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }
}

/// A click sound: the bar's first beat and the others, 48 kHz, each starting on its first sample. Mono when made here;
/// interleaved stereo when loaded from a WAV (the shipped sounds and a person's own, MetronomeSoundLibrary).
public struct MetronomeClickSound: Sendable {
    public var accent: [Float]
    public var normal: [Float]
    /// 1 (mono) or 2 (interleaved stereo).
    public let channels: Int
    public init(accent: [Float], normal: [Float]) {
        self.accent = accent
        self.normal = normal
        channels = 1
    }
    public init(stereoAccent: [Float], stereoNormal: [Float]) {
        accent = stereoAccent
        normal = stereoNormal
        channels = 2
    }

    /// A plain click made here, so nothing has to be shipped: a short tone that starts at once and dies away, higher for
    /// the bar's first beat.
    public static func synthesized() -> MetronomeClickSound {
        func click(_ hz: Double, _ level: Float) -> [Float] {
            let frames = Int(0.035 * CaptureTimeline.sampleRate)
            return (0..<frames).map { i in
                let t = Double(i) / CaptureTimeline.sampleRate
                return level * Float(sin(2 * Double.pi * hz * t) * exp(-t / 0.008))
            }
        }
        return MetronomeClickSound(accent: click(1_760, 0.9), normal: click(1_320, 0.6))
    }

    /// The sounds to choose from, all made here.
    public static let names = ["Click", "Woodblock", "Beep"]

    public static func named(_ name: String) -> MetronomeClickSound {
        func tone(_ hz: Double, _ level: Float, seconds: Double, decay: Double) -> [Float] {
            let frames = Int(seconds * CaptureTimeline.sampleRate)
            return (0..<frames).map { i in
                let t = Double(i) / CaptureTimeline.sampleRate
                return level * Float(sin(2 * Double.pi * hz * t) * exp(-t / decay))
            }
        }
        switch name {
        case "Woodblock":
            return MetronomeClickSound(accent: tone(1_050, 0.9, seconds: 0.06, decay: 0.012),
                                       normal: tone(800, 0.65, seconds: 0.06, decay: 0.012))
        case "Beep":
            return MetronomeClickSound(accent: tone(1_000, 0.7, seconds: 0.08, decay: 0.05),
                                       normal: tone(700, 0.5, seconds: 0.08, decay: 0.05))
        default:
            return synthesized()
        }
    }
}

/// Mixes clicks into an output block, each on its exact sample: the caller says when the block's first sample will be
/// HEARD (now, plus what is already queued ahead of it, plus the output's own delay) in the metronome clock, and a click
/// longer than a block carries on into the next. A beat is never played twice, even if the next block's time estimate
/// steps back a little.
public final class MetronomeClickPlayer {
    public var sound: MetronomeClickSound
    public var gain: Float
    private var playing: [(samples: [Float], channels: Int, position: Int)] = []
    private var lastTriggeredUs = -Double.infinity

    public init(sound: MetronomeClickSound = .synthesized(), gain: Float = 0.7) {
        self.sound = sound
        self.gain = gain
    }

    /// Mix into `stereo` (interleaved, 2 channels, `stereo.count / 2` frames) the clicks heard from `heardAtUs` on.
    /// Returns the times of the beats started here, for the tests and the log.
    @discardableResult
    public func render(into stereo: inout [Float], heardAtUs: Int64, schedule: MetronomeSchedule?) -> [Double] {
        let frames = stereo.count / 2
        var started: [Double] = []
        if let schedule, schedule.audible {
            let from = Double(heardAtUs)
            let to = from + Double(frames) * 1_000_000 / CaptureTimeline.sampleRate
            for beat in schedule.beats(fromUs: from, toUs: to) where beat.timeUs > lastTriggeredUs + 1_000 {
                lastTriggeredUs = beat.timeUs
                let offset = Int(((beat.timeUs - from) * CaptureTimeline.sampleRate / 1_000_000).rounded(.down))
                playing.append((beat.accent ? sound.accent : sound.normal, sound.channels, -offset))
                started.append(beat.timeUs)
            }
        } else {
            lastTriggeredUs = -Double.infinity
        }
        guard !playing.isEmpty else { return started }
        for i in playing.indices {
            let (samples, channels, position) = playing[i]
            let length = samples.count / channels
            for frame in 0..<frames {
                let at = position + frame
                if at < 0 { continue }
                if at >= length { break }
                stereo[2 * frame] += samples[channels * at] * gain
                stereo[2 * frame + 1] += samples[channels * at + channels - 1] * gain
            }
            playing[i].position += frames
        }
        playing.removeAll { $0.position >= $0.samples.count / $0.channels }
        return started
    }
}
