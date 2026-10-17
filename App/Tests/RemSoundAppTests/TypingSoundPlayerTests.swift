import XCTest
import RemSoundRuntime
@testable import RemSoundApp

final class TypingSoundPlayerTests: XCTestCase {
    private final class Output: TypingSoundOutput {
        var isRunning = false
        var failStart = false
        var starts = 0, stops = 0
        var duringStart: (() -> Void)?
        var enabled = false
        var played: [(Int, Bool)] = []
        func start() throws {
            starts += 1
            if failStart { throw NSError(domain: "test route unavailable", code: 1) }
            isRunning = true
            duringStart?()
        }
        func setEnabled(_ value: Bool) { enabled = value }
        func enqueue(key: Int, password: Bool) { if enabled { played.append((key, password)) } }
        func stop() { stops += 1; enabled = false; isRunning = false }
    }
    private final class Fixture {
        let configuration: RuntimeConfiguration
        let preferences: CuePreferences
        var queued: [() -> Void] = []
        var loads = 0, builds = 0
        var now: TimeInterval = 100
        var outputs: [Output] = []
        var empty = false, fail = false
        var choices: [Int] = []
        var duringBuild: (() -> Void)?
        var duringStart: (() -> Void)?
        var duringLoad: (() -> Void)?
        lazy var player = TypingSoundPlayer(configuration: configuration, preferences: preferences,
            enqueue: { [unowned self] in queued.append($0) },
            load: { [unowned self] in loads += 1; duringLoad?(); return TypingAudioCache(assets: empty ? [:] : [0: [0.1, 0.2], 3: [0.3, 0.4], 8: [0.5, 0.6]]) },
            makeOutput: { [unowned self] _ in
                builds += 1; let output = Output(); output.failStart = fail; outputs.append(output)
                output.duringStart = duringStart
                duringBuild?(); return output
            }, clock: { [unowned self] in now },
            choose: { [unowned self] count in choices.isEmpty ? 0 : choices.removeFirst() % count },
            flush: { [unowned self] in drain() })
        init(arguments: [String] = []) throws {
            let base = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
            let root = URL(fileURLWithPath: base).appendingPathComponent("typing-output-\(UUID())")
            let options = try LaunchOptions.parse(arguments + ["--config-dir", root.path],
                environment: ["REMSOUND_ALLOW_VISIBLE_UI_TESTS": "1"])
            configuration = try RuntimeConfiguration(options: options)
            preferences = CuePreferences(settings: configuration.settings)
        }
        func drain() { while !queued.isEmpty { queued.removeFirst()() } }
        deinit {
            if let root = configuration.root { try? FileManager.default.removeItem(at: root) }
        }
    }
    func testCachesOnceUsesOneOutputAndSelectsExistingKeysWithRepeats() throws {
        let f = try Fixture(); f.choices = [1, 1, 0]; f.player.start()
        f.player.play(password: false); f.player.play(password: true); f.player.play(password: false); f.drain()
        XCTAssertEqual(f.loads, 1); XCTAssertEqual(f.builds, 1)
        XCTAssertEqual(f.outputs.first?.starts, 1)
        XCTAssertEqual(f.outputs.first?.played.map { $0.0 }, [3, 3, 0])
        XCTAssertEqual(f.outputs.first?.played.map { $0.1 }, [false, true, false])
        f.player.stop(); f.drain(); XCTAssertEqual(f.outputs.first?.stops, 1)
    }
    func testSilentHeadlessDisabledAndMutedNeverLoadOrConstruct() throws {
        for arguments in [["--silent"], ["--headless"], []] {
            let f = try Fixture(arguments: arguments)
            if arguments.isEmpty { f.preferences.setKeyboardClicksEnabled(false) }
            f.player.start(); f.player.play(password: true); f.drain()
            XCTAssertEqual(f.loads, 0); XCTAssertEqual(f.builds, 0)
        }
        let f = try Fixture(); f.preferences.setMuteAllCues(true)
        f.player.start(); f.player.play(password: true); f.drain()
        XCTAssertEqual(f.loads, 0); XCTAssertEqual(f.builds, 0)
    }
    func testQueuedWorkRetiresWhenPolicyChangesBeforeDrain() throws {
        let f = try Fixture(); f.player.start(); f.player.play(password: false)
        f.preferences.setMuteAllCues(true); f.player.refresh()
        f.preferences.setMuteAllCues(false); f.player.refresh(); f.drain()
        XCTAssertEqual(f.builds, 1) // Only the new eligible generation warms its output.
        XCTAssertEqual(f.outputs.first?.played.count, 0)
        f.player.play(password: true); f.drain()
        XCTAssertEqual(f.builds, 1); XCTAssertEqual(f.outputs.first?.played.count, 1)
        f.player.stop(); f.drain()
    }
    func testMuteImmediatelyDisablesExistingOutputBeforeQueuedStop() throws {
        let f = try Fixture(); f.player.start(); f.player.play(password: false); f.drain()
        let output = try XCTUnwrap(f.outputs.first)
        XCTAssertTrue(output.enabled)
        f.player.play(password: true)
        f.preferences.setMuteAllCues(true); f.player.refresh()
        XCTAssertFalse(output.enabled); XCTAssertEqual(output.stops, 0)
        f.drain(); XCTAssertEqual(output.stops, 1); XCTAssertEqual(output.played.count, 1)
        f.player.stop(); f.drain(); XCTAssertEqual(output.stops, 1)
    }
    func testFailedRouteRetriesOnlyOnKeyAfterFiveMonotonicSeconds() throws {
        let f = try Fixture(); f.fail = true; f.player.start(); f.player.play(password: false); f.drain()
        XCTAssertEqual(f.builds, 1); XCTAssertEqual(f.outputs.first?.stops, 1)
        f.now = 104.999; f.player.play(password: false); f.drain(); XCTAssertEqual(f.builds, 1)
        f.now = 105; f.fail = false; f.player.play(password: true); f.drain()
        XCTAssertEqual(f.loads, 1); XCTAssertEqual(f.builds, 2); XCTAssertEqual(f.outputs.last?.played.count, 1)
        f.player.stop(); f.drain()
    }
    func testLostOutputIsRetiredAndCannotRebuildMoreThanOnceInFiveSeconds() throws {
        let f = try Fixture(); f.player.start(); f.player.play(password: false); f.drain()
        let old = try XCTUnwrap(f.outputs.first); old.isRunning = false
        f.now = 101; f.player.play(password: false); f.drain()
        XCTAssertEqual(old.stops, 1); XCTAssertEqual(f.builds, 1)
        f.now = 105; f.player.play(password: false); f.drain(); XCTAssertEqual(f.builds, 2)
        f.player.stop(); f.drain()
    }
    func testEmptyAssetsAreCachedAndInertWithoutDeviceConstruction() throws {
        let f = try Fixture(); f.empty = true; f.player.start()
        for _ in 0..<20 { f.player.play(password: true) }; f.drain()
        XCTAssertEqual(f.loads, 1); XCTAssertEqual(f.builds, 0)
        f.player.stop(); f.drain()
    }
    func testMuteDuringConstructionPreventsStartAndRetiresNewOutput() throws {
        let f = try Fixture(); f.player.start()
        f.duringBuild = { f.preferences.setMuteAllCues(true); f.player.refresh() }
        f.player.play(password: false); f.drain()
        XCTAssertEqual(f.builds, 1); XCTAssertEqual(f.outputs.first?.starts, 0)
        XCTAssertEqual(f.outputs.first?.stops, 1); XCTAssertEqual(f.outputs.first?.played.count, 0)
        f.player.stop(); f.drain()
    }
    func testEligibleStartWarmsOutputWithoutPlayingAndShutdownDrainsRetirement() throws {
        let f = try Fixture(); f.player.start(); f.drain()
        let output = try XCTUnwrap(f.outputs.first)
        XCTAssertEqual(f.loads, 1); XCTAssertEqual(output.starts, 1); XCTAssertTrue(output.played.isEmpty)
        f.player.play(password: false)
        f.player.shutdown()
        XCTAssertEqual(output.stops, 1); XCTAssertEqual(output.played.count, 0); XCTAssertTrue(f.queued.isEmpty)
    }
    func testMuteDuringDecodeCannotConstructAndMuteDuringStartCannotPlay() throws {
        let f = try Fixture(); f.duringLoad = { f.preferences.setMuteAllCues(true); f.player.refresh() }
        f.player.start(); f.player.play(password: true); f.drain(); XCTAssertEqual(f.builds, 0)
        f.player.shutdown()
        let g = try Fixture(); g.duringStart = { g.preferences.setMuteAllCues(true); g.player.refresh() }
        g.player.start(); g.player.play(password: true); g.drain()
        XCTAssertEqual(g.outputs.first?.starts, 1); XCTAssertEqual(g.outputs.first?.stops, 1)
        XCTAssertEqual(g.outputs.first?.played.count, 0); XCTAssertFalse(g.outputs.first?.enabled ?? true)
        g.player.shutdown()
    }
    func testHeadlessHandoverEnablesWarmupUnlessExplicitSilentRemains() throws {
        for flags in [["--headless"], ["--headless", "--silent"]] {
            let f = try Fixture(arguments: flags); f.player.start(); f.drain(); XCTAssertEqual(f.loads, 0)
            f.configuration.handOverToGUI(); f.player.refresh(); f.drain()
            XCTAssertEqual(f.builds, flags.contains("--silent") ? 0 : 1)
            f.player.shutdown()
        }
    }
    func testFiveHundredPolicyCyclesDecodeOnceAndStopEveryOutputOnce() throws {
        let f = try Fixture(); f.player.start()
        for _ in 0..<500 {
            f.preferences.setKeyboardClicksEnabled(true); f.player.refresh(); f.drain()
            f.player.play(password: true); f.drain()
            f.preferences.setKeyboardClicksEnabled(false); f.player.refresh(); f.drain()
        }
        f.player.shutdown()
        XCTAssertEqual(f.loads, 1); XCTAssertEqual(f.builds, 500)
        XCTAssertTrue(f.outputs.allSatisfy { $0.starts == 1 && $0.stops == 1 && $0.played.count == 1 && !$0.enabled })
    }
    func testAbandonedOwnerDoesNotConstructFromQueuedClosures() throws {
        let f = try Fixture()
        var tasks: [() -> Void] = [], builds = 0
        var player: TypingSoundPlayer? = TypingSoundPlayer(configuration: f.configuration, preferences: f.preferences,
            enqueue: { tasks.append($0) }, load: { TypingAudioCache(assets: [0: [0.1, 0.1]]) },
            makeOutput: { _ in builds += 1; return Output() })
        weak var owner = player
        player?.start(); player?.play(password: true); player = nil
        XCTAssertNil(owner)
        while !tasks.isEmpty { tasks.removeFirst()() }
        XCTAssertEqual(builds, 0)
    }
}
