import AVFoundation
import AppKit
import Foundation

import RemSoundRuntime

protocol CueSoundPlayer: AnyObject {
    var isPlaying: Bool { get }
    func play() -> Bool
    func stop()
}

extension AVAudioPlayer: CueSoundPlayer {}

final class CueSounds {
    private static let muteNotification = Notification.Name("org.remsound.mac.audioCueMute")
    static let shared: CueSounds = {
        let playback = DispatchQueue(label: "org.remsound.cues", qos: .utility)
        return CueSounds(configuration: AppRuntime.configuration,
            directory: Bundle.main.resourceURL?.appendingPathComponent("default sounds", isDirectory: true),
            enqueue: { playback.async(execute: $0) },
            makePlayer: { try AVAudioPlayer(contentsOf: $0) }, beep: { NSSound.beep() },
            notifyMute: {
                DistributedNotificationCenter.default().postNotificationName(
                    muteNotification, object: nil,
                    userInfo: nil, deliverImmediately: true)
            })
    }()
    let preferences: CuePreferences
    private let configuration: RuntimeConfiguration
    private let enqueue: (@escaping () -> Void) -> Void
    private let makePlayer: (URL) throws -> CueSoundPlayer
    private let beepDevice: () -> Void
    private let notifyMute: () -> Void
    private struct PlayingCue {
        var player: CueSoundPlayer
        var preview: Bool
    }
    private var players = [PlayingCue]()
    private var hasOpenedProfile = false
    private static let maximumPlayers = 16
    private let directory: URL?
    // Keep the actual device boundary replaceable so silent tests never construct an audio player.
    init(configuration: RuntimeConfiguration, directory: URL?,
        enqueue: @escaping (@escaping () -> Void) -> Void,
        makePlayer: @escaping (URL) throws -> CueSoundPlayer, beep: @escaping () -> Void = {},
        notifyMute: @escaping () -> Void = {}) {
        self.configuration = configuration
        preferences = CuePreferences(settings: configuration.settings)
        self.directory = directory
        self.enqueue = enqueue
        self.makePlayer = makePlayer
        beepDevice = beep
        self.notifyMute = notifyMute
    }
    private lazy var bundledNames = directory.flatMap {
        try? FileManager.default.contentsOfDirectory(atPath: $0.path)
    } ?? []

    func variants(for event: CueEvent) -> [String] {
        let names = bundledNames
        let base = event.filenameBase.lowercased()
        let numbered = names.compactMap { name -> (number: Int, name: String)? in
            let stem = (name as NSString).deletingPathExtension.lowercased()
            guard (name as NSString).pathExtension.lowercased() == "wav",
                stem.hasPrefix(base + " "),
                let number = Int(stem.dropFirst(base.count + 1)), number > 0 else { return nil }
            return (number, name)
        }.sorted { $0.number < $1.number }.map(\.name)
        if !numbered.isEmpty { return numbered }
        return names.filter { $0.lowercased() == base + ".wav" }
    }

    /// The cues that are on but have no sound file that can be found - a custom WAV deleted, or a chosen sound gone.
    func missingEnabledEvents() -> [CueEvent] {
        CueEvent.allCases.filter { event in
            preferences.configuration(for: event).enabled
                && !preferences.playbackCandidates(for: event, variants: variants(for: event), directory: directory)
                    .contains { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    func builtInName(for url: URL, event: CueEvent) -> String? {
        guard let directory,
            url.deletingLastPathComponent().resolvingSymlinksInPath()
                == directory.resolvingSymlinksInPath() else { return nil }
        return variants(for: event).first { $0 == url.lastPathComponent }
    }

    func setMuteAllCues(_ muted: Bool) {
        preferences.setMuteAllCues(muted)
        guard muted else { return }
        // A disposable app must never silence the user's live plugin through a distributed notification.
        if !configuration.isIsolated && !configuration.silent { notifyMute() }
        enqueue { [self] in
            for cue in players where !cue.preview { cue.player.stop() }
            players.removeAll { !$0.preview || !$0.player.isPlaying }
        }
    }

    func profileOpened() {
        guard !hasOpenedProfile else { return }
        hasOpenedProfile = true
        play(.startup)
    }

    func play(_ event: CueEvent, preview: Bool = false, completion: ((String?) -> Void)? = nil) {
        guard !configuration.silent, preview || !preferences.muteAllCues else { completion?(nil); return }
        let candidates = preferences.playbackCandidates(for: event,
            variants: variants(for: event), directory: directory)
        guard !candidates.isEmpty else {
            completion?("No sound is enabled for \(event.title). Choose a sound in Preferences.")
            return
        }
        enqueue { [self] in
            // The mute may change while this ordinary cue is waiting in the playback queue.
            guard !configuration.silent, preview || !preferences.muteAllCues else {
                if let completion { DispatchQueue.main.async { completion(nil) } }
                return
            }
            var played = false
            // Try the built-in sound if a custom path is missing or its audio cannot be decoded.
            for url in candidates {
                guard let player = try? makePlayer(url), player.play() else { continue }
                players.removeAll { !$0.player.isPlaying }
                while players.count >= Self.maximumPlayers { players.removeFirst().player.stop() }
                players.append(PlayingCue(player: player, preview: preview))
                played = true
                break
            }
            if let completion {
                let message = played ? nil : "The sound for \(event.title) could not be played. Choose another WAV file."
                DispatchQueue.main.async { completion(message) }
            }
        }
    }

    func beep() {
        guard !configuration.silent, !preferences.muteAllCues else { return }
        beepDevice()
    }
}
