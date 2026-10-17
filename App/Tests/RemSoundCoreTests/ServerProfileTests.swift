import Foundation
import XCTest
import RemSoundRuntime
@testable import RemSoundCore

/// The profile keeps its server and whether to connect at start (Windows' RelayServer and RelayConnectOnStart).
final class ServerProfileTests: XCTestCase {
    private func profile(server: String = "", connect: Bool = false) -> ConnectionProfile {
        ConnectionProfile(title: "Server", displayName: "Test", manualPeerAddress: "", selectedPeerAddresses: [],
            sendInput: false, receiveAudio: false, allowPlugins: false, reconnectOnOpen: false,
            server: server, serverConnectOnStart: connect)
    }
    private func raw(_ profile: ConnectionProfile) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
    }
    private func decode(_ raw: [String: Any]) throws -> ConnectionProfile {
        try JSONDecoder().decode(ConnectionProfile.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    func testTheServerAndConnectAtStartRoundTripAndMarkTheProfileChanged() throws {
        let saved = profile(server: "server.example.com", connect: true)
        let back = try decode(raw(saved))
        XCTAssertEqual(back.server, "server.example.com")
        XCTAssertTrue(back.serverConnectOnStart)
        XCTAssertEqual(back, saved)
        XCTAssertNotEqual(saved, profile(), "a change of server is a change to the profile")
    }

    func testAProfileSavedBeforeServersWereKeptHasNone() throws {
        var data = try raw(profile(server: "server.example.com", connect: true))
        data["server"] = nil
        data["serverConnectOnStart"] = nil
        let old = try decode(data)
        XCTAssertEqual(old.server, "")
        XCTAssertFalse(old.serverConnectOnStart)
    }
}
