import Foundation
import XCTest
import RemSoundJam
import RemSoundRuntime
@testable import RemSoundCore

/// The metronome's settings belong to the profile (Windows MetronomeSettings): kept, changed, and absent from old profiles.
final class MetronomeChoicesProfileTests: XCTestCase {
    private func profile(_ metronome: MetronomeChoices? = MetronomeChoices()) -> ConnectionProfile {
        ConnectionProfile(title: "Metronome", displayName: "Test", manualPeerAddress: "", selectedPeerAddresses: [],
            sendInput: false, receiveAudio: false, allowPlugins: false, reconnectOnOpen: false, metronome: metronome)
    }

    func testTheSettingsRoundTripAndAChangeIsAChangeToTheProfile() throws {
        var choices = MetronomeChoices()
        choices.bpm = 96; choices.beatsPerBar = 9; choices.beatUnit = 8; choices.sound = "Cowbell"
        choices.hearIn = .daw; choices.acceptMasterAutomatically = true
        let saved = profile(choices)
        let back = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(back.metronome, choices)
        XCTAssertNotEqual(saved, profile())
    }

    func testAProfileSavedBeforeTheSettingsWereKeptHasNone() throws {
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile())) as! [String: Any]
        raw["metronome"] = nil
        let old = try JSONDecoder().decode(ConnectionProfile.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertNil(old.metronome, "the app then starts it from this Mac's old signature and sound")
        XCTAssertEqual(profile().metronome, MetronomeChoices(), "a new profile starts from the defaults")
    }
}
