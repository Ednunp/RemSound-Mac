import XCTest
@testable import RemSoundCore

final class ProfileDefaultsTests: XCTestCase {
    private func profile(codec: SendCodec? = nil) -> ConnectionProfile {
        if let codec {
            return ConnectionProfile(title: "Saved", displayName: "Test", manualPeerAddress: "",
                selectedPeerAddresses: [], sendInput: false, receiveAudio: false,
                allowPlugins: false, reconnectOnOpen: false, sendCodec: codec)
        }
        return ConnectionProfile(title: "New", displayName: "Test", manualPeerAddress: "",
            selectedPeerAddresses: [], sendInput: false, receiveAudio: false,
            allowPlugins: false, reconnectOnOpen: false)
    }

    func testNewProfilesUseWindows61LiveOpusAndStandardPackets() {
        let value = profile()
        XCTAssertEqual(value.sendCodec, .opusLive)
        XCTAssertEqual(value.sendPacketSize, .standard)
        XCTAssertEqual(value.sendPacketSize.frames(for: value.sendCodec), 120)
    }

    func testSavedCodecChoicesStayExactlyAsSaved() throws {
        for codec in SendCodec.allCases {
            var value = profile(codec: codec)
            value.sendPacketSize = .small
            let restored = try JSONDecoder().decode(ConnectionProfile.self,
                from: JSONEncoder().encode(value))
            XCTAssertEqual(restored, value)
        }
    }

    func testOlderProfilesWithoutCodecRetainTheirLegacyPCMDefault() throws {
        let data = try JSONEncoder().encode(profile(codec: .pcm))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "sendCodec")
        legacy.removeValue(forKey: "sendPacketSize")
        let restored = try JSONDecoder().decode(ConnectionProfile.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(restored.sendCodec, .pcm)
        XCTAssertEqual(restored.sendPacketSize, .standard)
    }
}
