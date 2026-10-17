import XCTest
import RemSoundJam
@testable import RemSoundCore

final class DirectPeerStartupTests: XCTestCase {
    func testStoppingRelayKeepsPendingSavedNamesInOutgoingRunningSnapshot() throws {
        let relay = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: relay.boundPort)
        defer { session.shutdown() }
        let started = expectation(description: "started with pending name")
        session.onChange = { view in
            guard view.running else { return }
            session.onChange = nil
            started.fulfill()
        }
        session.start(password: "private relay names fixture", peerAddress: "remsound-retry.invalid",
            savedPeerAddresses: ["127.0.0.1"], send: false, receive: false,
            plugins: false, name: "Private relay names fixture")
        wait(for: [started], timeout: 3)
        let member = expectation(description: "relay member visible")
        session.onChange = { view in
            guard view.peers.contains(where: { JamWire.isMemberAddress($0.address) }) else { return }
            session.onChange = nil
            member.fulfill()
        }
        session.connectServer("127.0.0.1:\(relay.boundPort)")
        let hello = Data(JamWire.header(JamWire.Kind.hello.rawValue, version: JamWire.groupVersion))
        var sender: Endpoint?
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let (data, endpoint) = relay.receive(), data.starts(with: hello) {
                sender = endpoint
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        let target = try XCTUnwrap(sender)
        var roster = JamWire.header(JamWire.Kind.roster.rawValue, version: JamWire.groupVersion)
            + [UInt8](repeating: 0, count: JamWire.clientIdSize) + [1]
        roster += JamWire.bytes(of: UUID())
            + [UInt8](repeating: 0, count: RelayGroupClient.nameBytes) + [0, 0]
        _ = relay.send(Data(roster), to: target)
        wait(for: [member], timeout: 3)
        let stopped = expectation(description: "stopped after relay teardown")
        session.onChange = { view in
            if view.running {
                XCTAssertTrue(view.selectedPeerAddresses.contains("remsound-retry.invalid"),
                    "Relay teardown must not erase saved names through an outgoing running snapshot")
            } else if view.status == "Stopped" {
                session.onChange = nil
                stopped.fulfill()
            }
        }
        session.stop()
        wait(for: [stopped], timeout: 3)
    }

    func testUnresolvableNameDoesNotPreventStartupOrOtherSavedPeers() throws {
        let listener = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: listener.boundPort)
        defer { session.shutdown() }
        let started = expectation(description: "startup remains active")
        session.onChange = { view in
            guard view.status != "Stopped" else { return }
            session.onChange = nil
            XCTAssertTrue(view.running, "An unavailable DNS name must not stop the entire audio session: \(view.status)")
            XCTAssertTrue(view.peers.contains { $0.address == "127.0.0.1" && $0.selected },
                "Other saved peers must still be selected while a name is unavailable")
            XCTAssertEqual(Set(view.selectedPeerAddresses), ["remsound-retry.invalid", "127.0.0.1"],
                "An unavailable name must survive the next settings/profile save")
            started.fulfill()
        }
        session.start(password: "private DNS fixture", peerAddress: "remsound-retry.invalid",
            savedPeerAddresses: ["127.0.0.1"], send: false, receive: false,
            plugins: false, name: "Private DNS fixture")
        wait(for: [started], timeout: 6)
    }
}
