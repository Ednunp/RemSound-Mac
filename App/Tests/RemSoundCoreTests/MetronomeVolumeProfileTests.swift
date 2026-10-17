import Foundation
import XCTest
import RemSoundRuntime
@testable import RemSoundCore

final class MetronomeVolumeProfileTests: XCTestCase {
    private func profile(_ volume: Int = ConnectionProfile.defaultMetronomeVolume) -> ConnectionProfile {
        ConnectionProfile(title: "Volume", displayName: "Test", manualPeerAddress: "", selectedPeerAddresses: [],
            sendInput: false, receiveAudio: false, allowPlugins: false, reconnectOnOpen: false, metronomeVolume: volume)
    }
    private func raw(_ profile: ConnectionProfile) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
    }
    private func decode(_ raw: [String: Any]) throws -> ConnectionProfile {
        try JSONDecoder().decode(ConnectionProfile.self, from: JSONSerialization.data(withJSONObject: raw))
    }
    func testNewAndLegacyProfilesDefaultToSeventyWithoutCurrentSettingMigration() throws {
        XCTAssertEqual(profile().metronomeVolume, 70)
        for value: Any? in [nil, NSNull()] {
            var data = try raw(profile()); data["metronomeVolume"] = value
            XCTAssertEqual(try decode(data).metronomeVolume, 70)
        }
    }
    func testEveryContinuousPercentRoundTripsAndMarksDirty() throws {
        let original = profile()
        for value in 0...100 {
            let current = profile(value)
            XCTAssertEqual(current.metronomeVolume, value)
            XCTAssertEqual(try decode(raw(current)), current)
            if value != 70 { XCTAssertNotEqual(current, original) }
        }
    }
    func testInitializerDecodeAndLaterAssignmentClampIntegerExtremes() throws {
        for (value, expected) in [(Int.min, 0), (-1, 0), (0, 0), (100, 100), (101, 100), (Int.max, 100)] {
            XCTAssertEqual(profile(value).metronomeVolume, expected)
            var data = try raw(profile()); data["metronomeVolume"] = value
            XCTAssertEqual(try decode(data).metronomeVolume, expected)
            var changed = profile(); changed.metronomeVolume = value
            XCTAssertEqual(changed.metronomeVolume, expected)
        }
    }
    func testMalformedKnownPercentIsRejected() throws {
        for value: Any in ["70", true, 70.5, [], [:]] {
            var data = try raw(profile()); data["metronomeVolume"] = value
            XCTAssertThrowsError(try decode(data))
        }
    }
    func testProfileFileRoundTripRetainsContinuousPercent() throws {
        let directory = try IsolatedTestDirectory.make("metronome-profile")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory), wanted = profile(37)
        try store.save(wanted)
        XCTAssertEqual(try store.load(id: wanted.id).metronomeVolume, 37)
    }
    func testActualStoppedWorkerAppliesEveryPercentAndClampsWithoutStartingAudio() throws {
        let directory = try IsolatedTestDirectory.make("metronome-worker")
        defer { try? FileManager.default.removeItem(at: directory) }
        let options = try LaunchOptions.parse(["--config-dir", directory.path, "--headless", "--silent"])
        let session = Session(configuration: try RuntimeConfiguration(options: options))
        for value in [Int.min, -1] + Array(0...100) + [101, Int.max] {
            session.setMetronomeVolume(value)
            XCTAssertEqual(session.testMetronomeVolume(), Float(min(100, max(0, value))) / 100)
        }
    }
}
