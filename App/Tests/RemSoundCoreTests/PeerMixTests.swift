import RemSoundJam
import XCTest
@testable import RemSoundCore

final class PeerMixTests: XCTestCase {
    func testVolumeAndPanKeepStereoAndBypassWhenDisabled() throws {
        let stereo: [Float] = [0.8, -0.4, 0.3, 0.9]
        XCTAssertEqual(PeerMix(enabled: false, volume: 0, pan: -100).apply(stereo), stereo)
        XCTAssertEqual(PeerMix(enabled: true, volume: 50, pan: -100).apply(stereo),
            [0.4, 0, 0.15, 0])
        XCTAssertEqual(PeerMix(enabled: true, volume: 100, pan: 100).apply(stereo),
            [0, -0.4, 0, 0.9])
        XCTAssertEqual(PeerMix(enabled: true).apply(stereo), stereo)
        XCTAssertTrue(PeerMix().enabled, "a newly seen peer is ticked, as on Windows")
    }
    func testProfilePersistsPeerMixWithAllThreeEqs() throws {
        var eq = PeerEq(mode: .parametric16Band, simpleDb: [3, 0, -2])
        eq.advancedDb[6] = 4.5
        eq.parametric = [ParametricBand(startHz: 200, endHz: 2000, gainDb: 3)]
        let original = PeerMix(enabled: true, volume: 73, pan: -20, eq: eq)
        let data = try JSONEncoder().encode(["192.0.2.1": original])
        let restored = try JSONDecoder().decode([String: PeerMix].self, from: data)
        XCTAssertEqual(restored["192.0.2.1"], original)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("bass"), "the old fields are not written")
    }
    func testAnOldProfilesThreeBandsBecomeTheSimpleEqAndItsMasterSwitchFollowsWhoWasShaped() throws {
        let old = #"{"a":{"enabled":true,"volume":80,"pan":10,"bass":6,"mids":-3,"treble":2},"b":{"enabled":false,"volume":100,"pan":0,"bass":0,"mids":0,"treble":0}}"#
        let mixes = try JSONDecoder().decode([String: PeerMix].self, from: Data(old.utf8))
        XCTAssertEqual(mixes["a"]?.eq.simpleDb, [6, -3, 2])
        XCTAssertEqual(mixes["a"]?.eq.mode, .simple3Band)
        XCTAssertEqual(mixes["a"]?.eq.advancedDb.count, 12)
        XCTAssertEqual(mixes["b"]?.enabled, false, "a peer that was off stays off")
        XCTAssertTrue(PeerMix.masterSwitchForOldProfile(mixes))
        XCTAssertFalse(PeerMix.masterSwitchForOldProfile(["b": mixes["b"]!]))
        XCTAssertFalse(PeerMix.masterSwitchForOldProfile([:]))
    }
}
