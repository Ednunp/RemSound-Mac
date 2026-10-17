import XCTest
@testable import RemSoundCore

final class PeerAddressEntryTests: XCTestCase {
    func testTrimmedOriginalHostAndPort() {
        XCTAssertEqual(PeerAddressEntry.parse(" Studio.local:54321 \n", defaultPort: 12345),
                       .init(text: "Studio.local:54321", host: "Studio.local", port: 54321))
        XCTAssertEqual(PeerAddressEntry.parse("127.0.0.1", defaultPort: 12345)?.port, 12345)
        XCTAssertEqual(PeerAddressEntry.parse("host:65535", defaultPort: 12345)?.port, 65535)
        XCTAssertEqual(PeerAddressEntry.parse("host:1", defaultPort: 0)?.port, 1)
    }
    func testMalformedPortsIPv6URLsControlsAndEmptyHostsAreRejected() {
        for text in ["", " ", ":12", "host:", "host:0", "host:65536", "host:-1", "host:+1", "host: 1", "host:١", "host:1:2", "[::1]", "[host", "host]", "https://host", "host/path", "host\\path", "bad\u{0}.invalid", "a b"] {
            XCTAssertNil(PeerAddressEntry.parse(text, defaultPort: 12345), text)
        }
        XCTAssertNil(PeerAddressEntry.parse("host", defaultPort: 0))
    }
    func testHostLengthBoundaryIsInBytes() {
        XCTAssertNotNil(PeerAddressEntry.parse(String(repeating: "a", count: 253), defaultPort: 12345))
        XCTAssertNil(PeerAddressEntry.parse(String(repeating: "a", count: 254), defaultPort: 12345))
        XCTAssertNil(PeerAddressEntry.parse(String(repeating: "é", count: 127), defaultPort: 12345))
    }
}
