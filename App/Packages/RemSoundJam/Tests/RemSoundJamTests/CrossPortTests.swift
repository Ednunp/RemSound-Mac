import Foundation
import XCTest

@testable import RemSoundJam

/// Windows' CROSS PORT step, for the Mac's shared code: the numbers every port and the relay must agree on, checked
/// against each other and against the relay's own source (the copy kept beside these tests, Tests/relay).
final class CrossPortTests: XCTestCase {
    static let relaySource = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("relay").appendingPathComponent("remsound-relay.py")

    /// A `NAME = value` line's value from the relay's source.
    func relay(_ name: String, in text: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix(name + " = ") {
            return String(line.dropFirst(name.count + 3).split(separator: "#")[0]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    func testTheWireSizesAreEveryPortsAndTheRelays() throws {
        XCTAssertEqual(JamWire.magic, Array("RMND".utf8))
        XCTAssertEqual(JamWire.headerSize, 12)
        XCTAssertEqual(JamWire.groupHeaderSize, 28, "the header and a 16-byte client id")
        XCTAssertEqual(RelayGroupClient.rosterEntryBytes, 49, "id, 32-byte name, flags")
        XCTAssertEqual(RemoteControl.sealedBytes, 38)
        XCTAssertEqual(RemoteControl.streamID, 0xFFFE)
        XCTAssertEqual(MetronomeMessage.streamId, 0xFFFF, "as the Windows MetronomeMessage")

        let text = try String(contentsOf: Self.relaySource, encoding: .utf8)
        XCTAssertEqual(relay("DEFAULT_PORT", in: text), String(JamWire.defaultPort))
        XCTAssertEqual(relay("LOBBY_NAME_BYTES", in: text), String(RelayGroupClient.nameBytes))
        XCTAssertEqual(relay("GROUP_TAG_BYTES", in: text), String(JamWire.fingerprintSize))
        XCTAssertEqual(relay("MAX_TICKED_IDS", in: text), String(RelayGroupClient.maxTickedIds))
        XCTAssertEqual(relay("ROSTER_MEMBER_FLAG_TICKS_YOU", in: text), "0x01")
        XCTAssertEqual(relay("TYPE_CONTROL", in: text), String(RemoteControl.packetType))
        XCTAssertEqual(relay("TYPE_METRONOME", in: text), String(JamWire.Kind.metronome.rawValue))
        XCTAssertEqual(relay("TYPE_LOBBY_HELLO", in: text), String(JamWire.Kind.hello.rawValue))
        XCTAssertEqual(relay("TYPE_LOBBY_ROSTER", in: text), String(JamWire.Kind.roster.rawValue))
        XCTAssertEqual(relay("TYPE_LOBBY_FULL", in: text), String(JamWire.Kind.full.rawValue))
        XCTAssertEqual(relay("TYPE_LOBBY_BYE", in: text), String(JamWire.Kind.bye.rawValue))
        XCTAssertEqual(relay("TYPE_ADDR_CHECK", in: text), "10")
        XCTAssertEqual(relay("TYPE_TIMING", in: text), String(JamWire.Kind.timing.rawValue))
        XCTAssertEqual(relay("FORMAT_FINGERPRINT_OFFSET", in: text), "36", "where a Format packet's fingerprint sits")
    }
}
