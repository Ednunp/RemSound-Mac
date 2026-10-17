import Foundation
import XCTest
import RemSoundRuntime
@testable import RemSoundApp

final class CueSoundsTests: XCTestCase {
    private final class Player: CueSoundPlayer {
        var isPlaying = false
        var plays = 0, stops = 0
        func play() -> Bool { plays += 1; isPlaying = true; return true }
        func stop() { stops += 1; isPlaying = false }
    }

    private func fixture(_ flags: [String]) throws -> (RuntimeConfiguration, URL) {
        guard let base = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"],
            (base as NSString).isAbsolutePath else {
            throw XCTSkip("Cue device spies require an isolated REMSOUND_TEST_ROOT")
        }
        let root = URL(fileURLWithPath: base).appendingPathComponent("cue-device-\(UUID())")
        let options = try LaunchOptions.parse(flags + ["--config-dir", root.path],
            environment: ["REMSOUND_ALLOW_VISIBLE_UI_TESTS": "1"])
        let configuration = try RuntimeConfiguration(options: options)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let sounds = root.appendingPathComponent("sounds")
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: false)
        for name in Set(CueEvent.allCases.map { $0.filenameBase + ".wav" }) {
            try Data().write(to: sounds.appendingPathComponent(name))
        }
        return (configuration, sounds)
    }

    func testSilentBootstrapStartupConnectDisconnectAndEveryCueNeverReachDevice() throws {
        for flags in [["--silent"], ["--headless"], ["--check-accessibility"], ["--headless", "--silent"]] {
            let (configuration, sounds) = try fixture(flags)
            var queued = 0, created = 0, completed = 0, beeps = 0
            let cues = CueSounds(configuration: configuration, directory: sounds,
                enqueue: { queued += 1; $0() }, makePlayer: { _ in created += 1; return Player() },
                beep: { beeps += 1 })
            for event in CueEvent.allCases {
                cues.play(event) { message in XCTAssertNil(message); completed += 1 }
                cues.play(event, preview: true) { message in XCTAssertNil(message); completed += 1 }
            }
            XCTAssertEqual(completed, CueEvent.allCases.count * 2)
            XCTAssertEqual(queued, 0, "Silent bootstrap must suppress work before dispatch")
            XCTAssertEqual(created, 0, "Startup and peer transitions must not open a sound device")
            cues.beep()
            XCTAssertEqual(beeps, 0, "Invalid shortcut feedback must also obey test silence")
            if flags.contains("--silent") || flags.contains("--check-accessibility") {
                configuration.handOverToGUI()
                for event in CueEvent.allCases { cues.play(event) }
                XCTAssertEqual(created, 0, "Explicit test silence survives GUI handover")
            }
        }
    }

    func testOrdinaryStartupConnectDisconnectExerciseTheSameDeviceBoundary() throws {
        let (configuration, sounds) = try fixture([])
        var pending: [() -> Void] = [], urls: [URL] = [], players: [Player] = [], beeps = 0
        let cues = CueSounds(configuration: configuration, directory: sounds,
            enqueue: { pending.append($0) }, makePlayer: {
                urls.append($0); let player = Player(); players.append(player); return player
            }, beep: { beeps += 1 })
        for event in [CueEvent.startup, .connect, .disconnect] { cues.play(event) }
        XCTAssertTrue(players.isEmpty, "A request must not create players on the UI thread")
        for work in pending { work() }
        XCTAssertEqual(urls.map(\.lastPathComponent), ["start up.wav", "connect.wav", "disconnect.wav"])
        XCTAssertEqual(players.map(\.plays), [1, 1, 1], "A vacuous always-silent spy cannot pass")
        cues.beep()
        XCTAssertEqual(beeps, 1)
    }

    func testPlayerLifetimeIsBoundedAndIdlePlayersAreDiscarded() throws {
        let (configuration, sounds) = try fixture([])
        var players: [Player] = []
        let cues = CueSounds(configuration: configuration, directory: sounds,
            enqueue: { $0() }, makePlayer: { _ in
                let player = Player(); players.append(player); return player
            })
        for _ in 0..<17 { cues.play(.connect) }
        XCTAssertEqual(players.first?.stops, 1)
        XCTAssertEqual(players.filter(\.isPlaying).count, 16)
        players[1].isPlaying = false
        cues.play(.disconnect)
        XCTAssertEqual(players[2].stops, 0, "Idle removal must precede the capacity limit")
    }

    func testMachineMuteSuppressesQueuedCueAndErrorFeedbackAtDeviceBoundary() throws {
        let (configuration, sounds) = try fixture([])
        var pending: [() -> Void] = [], created = 0, beeps = 0
        let cues = CueSounds(configuration: configuration, directory: sounds,
            enqueue: { pending.append($0) }, makePlayer: { _ in created += 1; return Player() },
            beep: { beeps += 1 })
        cues.play(.connect)
        cues.preferences.setMuteAllCues(true)
        for work in pending { work() }
        cues.play(.disconnect)
        cues.beep()
        XCTAssertEqual(created, 0, "Muting must also suppress work already waiting on the playback queue")
        XCTAssertEqual(beeps, 0)
    }

    func testMuteStopsOrdinaryPlayersPreservesPreviewsAndRestoresEveryCue() throws {
        let (configuration, sounds) = try fixture([])
        var players: [Player] = [], queued = 0
        let cues = CueSounds(configuration: configuration, directory: sounds,
            enqueue: { queued += 1; $0() }, makePlayer: { _ in
                let player = Player(); players.append(player); return player
            })
        cues.play(.connect)
        cues.play(.disconnect, preview: true)
        let before = cues.preferences.profileConfigurations
        cues.setMuteAllCues(true)
        XCTAssertEqual(players[0].stops, 1)
        XCTAssertTrue(players[1].isPlaying, "Muting does not interrupt a deliberate preview")
        for event in CueEvent.allCases { cues.play(event) }
        XCTAssertEqual(players.count, 2)
        XCTAssertEqual(queued, 3, "Muted ordinary cues should not dispatch work")
        cues.play(.helpOpen, preview: true)
        XCTAssertEqual(players.count, 3)
        cues.preferences.setEnabled(false, for: .helpClose)
        cues.play(.helpClose, preview: true)
        XCTAssertEqual(players.count, 3, "Off remains silent even for previews")
        cues.preferences.setEnabled(true, for: .helpClose)
        cues.setMuteAllCues(false)
        for event in CueEvent.allCases { cues.play(event) }
        XCTAssertEqual(players.count, 3 + CueEvent.allCases.count)
        XCTAssertEqual(cues.preferences.profileConfigurations, before)
        XCTAssertFalse(cues.preferences.muteAllCues)
    }

    func testStartupWaitsForFirstProfileUsesItsChoiceAndPlaysOnlyOnce() throws {
        let (configuration, sounds) = try fixture([])
        var urls: [URL] = []
        let cues = CueSounds(configuration: configuration, directory: sounds,
            enqueue: { $0() }, makePlayer: { urls.append($0); return Player() })
        XCTAssertTrue(urls.isEmpty, "The profile picker must not play a startup cue")
        cues.preferences.loadProfile(["startup": CueConfiguration(customPath: "/private/first-start.wav")])
        cues.profileOpened()
        XCTAssertEqual(urls.map(\.path), ["/private/first-start.wav"])
        cues.preferences.loadProfile(["startup": CueConfiguration(customPath: "/private/second-start.wav")])
        cues.profileOpened()
        XCTAssertEqual(urls.count, 1)
    }

    func testFirstProfileOffOrMutedDoesNotDeferStartupToAnotherProfile() throws {
        for muted in [false, true] {
            let (configuration, sounds) = try fixture([])
            var created = 0
            let cues = CueSounds(configuration: configuration, directory: sounds,
                enqueue: { $0() }, makePlayer: { _ in created += 1; return Player() })
            cues.preferences.loadProfile(["startup": CueConfiguration(enabled: muted)])
            cues.setMuteAllCues(muted)
            cues.profileOpened()
            cues.setMuteAllCues(false)
            cues.preferences.loadProfile([:])
            cues.profileOpened()
            XCTAssertEqual(created, 0)
        }
    }

    func testIsolatedMuteNeverNotifiesLivePluginsEvenWithoutTestSilence() throws {
        for flags in [[], ["--silent"], ["--headless"], ["--check-accessibility"]] {
            let (configuration, sounds) = try fixture(flags)
            var notifications = 0
            let cues = CueSounds(configuration: configuration, directory: sounds,
                enqueue: { $0() }, makePlayer: { _ in Player() }, notifyMute: { notifications += 1 })
            cues.setMuteAllCues(true)
            cues.setMuteAllCues(false)
            XCTAssertTrue(configuration.isIsolated)
            XCTAssertEqual(notifications, 0, "Private cue tests must not stop a normal host's Help sounds")
        }
    }
    func testPTTCuesUseDistinctAssetsAtTheExistingDeviceBoundary() throws {
        let on = try XCTUnwrap(CueEvent(rawValue: "pushToTalkOn")), off = try XCTUnwrap(CueEvent(rawValue: "pushToTalkOff"))
        let (config, sounds) = try fixture([]); var names = [String]()
        let cues = CueSounds(configuration: config, directory: sounds, enqueue: { $0() }, makePlayer: { url in names.append(url.lastPathComponent); return Player() })
        cues.play(on); cues.play(off)
        XCTAssertEqual(names, ["push talk on.wav", "push talk off.wav"])
    }
    func testPTTCuesRespectIndividualProfileOffAndQueuedMachineMute() throws {
        let on = try XCTUnwrap(CueEvent(rawValue: "pushToTalkOn")), off = try XCTUnwrap(CueEvent(rawValue: "pushToTalkOff"))
        let (config, sounds) = try fixture([]); var pending = [() -> Void](), created = 0
        let cues = CueSounds(configuration: config, directory: sounds, enqueue: { pending.append($0) }, makePlayer: { _ in created += 1; return Player() })
        cues.preferences.setEnabled(false, for: off); cues.play(off); XCTAssertTrue(pending.isEmpty)
        cues.play(on); cues.preferences.setMuteAllCues(true); pending.forEach { $0() }
        cues.play(on); XCTAssertEqual(created, 0)
        cues.preferences.setMuteAllCues(false); pending.removeAll(); cues.play(on); pending.forEach { $0() }
        XCTAssertEqual(created, 1, "The ordinary positive control must exercise playback")
    }
    func testNewPTTCuesNeverConstructPlayersInSilentHeadlessOrAXCopies() throws {
        let on = try XCTUnwrap(CueEvent(rawValue: "pushToTalkOn")), off = try XCTUnwrap(CueEvent(rawValue: "pushToTalkOff"))
        for flags in [["--silent"], ["--headless"], ["--check-accessibility"]] {
            let (config, sounds) = try fixture(flags); var created = 0, queued = 0
            let cues = CueSounds(configuration: config, directory: sounds, enqueue: { queued += 1; $0() }, makePlayer: { _ in created += 1; return Player() })
            cues.play(on); cues.play(off); XCTAssertEqual(created, 0); XCTAssertEqual(queued, 0)
        }
    }

}
