import Foundation
import RemSoundRuntime
import XCTest
@testable import RemSoundCore

final class CueProfileTests: XCTestCase {
    func testProfileCueRoundTripAndLegacyAbsenceRemainDistinctFromNewDefaults() throws {
        var profile = ConnectionProfile(title: "Test", displayName: "Test", manualPeerAddress: "",
            selectedPeerAddresses: [], sendInput: false, receiveAudio: false,
            allowPlugins: false, reconnectOnOpen: false)
        XCTAssertEqual(profile.audioCues, [:])
        XCTAssertEqual(profile.audioCueSchemaVersion, CuePreferences.schemaVersion)
        profile.audioCues = ["connect": CueConfiguration(enabled: false, customPath: "/private/connect.wav",
            builtInName: "connect 3.wav")]
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(ConnectionProfile.self, from: data), profile)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "audioCues")
        object.removeValue(forKey: "audioCueSchemaVersion")
        let legacy = try JSONDecoder().decode(ConnectionProfile.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.audioCues)
        XCTAssertEqual(legacy.audioCueSchemaVersion, 0)
        var changed = profile
        changed.audioCues?["connect"]?.enabled = true
        XCTAssertNotEqual(changed, profile)
        changed = profile
        changed.audioCues?["connect"]?.customPath = "/private/changed.wav"
        XCTAssertNotEqual(changed, profile)
        changed = profile
        changed.audioCues?["connect"]?.builtInName = "connect 2.wav"
        XCTAssertNotEqual(changed, profile)
    }

    func testLegacyCueMapHasVersionZeroAndFutureVersionsAreRejectedBeforeLossySaving() throws {
        let profile = ConnectionProfile(title: "Test", displayName: "Test", manualPeerAddress: "",
            selectedPeerAddresses: [], sendInput: false, receiveAudio: false,
            allowPlugins: false, reconnectOnOpen: false,
            audioCues: ["save": CueConfiguration(enabled: false), "connect": CueConfiguration(enabled: true)])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        object.removeValue(forKey: "audioCueSchemaVersion")
        let legacy = try JSONDecoder().decode(ConnectionProfile.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.audioCueSchemaVersion, 0)
        XCTAssertEqual(legacy.audioCues, profile.audioCues, "Decoding alone must not discard an old global entry")
        for unsupported in [-1, CuePreferences.schemaVersion + 1] {
            object["audioCueSchemaVersion"] = unsupported
            XCTAssertThrowsError(try JSONDecoder().decode(ConnectionProfile.self,
                from: JSONSerialization.data(withJSONObject: object)))
        }
    }
}
