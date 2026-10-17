import XCTest
import RemSoundJam
@testable import RemSoundCore

final class SessionServerStatusTests: XCTestCase {
    private func packet(_ kind: UInt8, _ body: [UInt8]) -> Data {
        Data(JamWire.header(kind, version: JamWire.groupVersion) + [UInt8](repeating: 0, count: 16) + body)
    }
    private func info() -> Data {
        func le<T: FixedWidthInteger>(_ n: T) -> [UInt8] { withUnsafeBytes(of: n.littleEndian) { Array($0) } }
        let version = Array("server-v2.16".utf8)
        var b: [UInt8] = [1, UInt8(version.count)] + version
        b += le(UInt32(1234)) + le(UInt16(5)) + le(UInt16(3)) + le(UInt16(59)) + le(UInt16(1))
        b += le(UInt32(4000)) + le(UInt32(12000)) + le(UInt16(0)) + le(UInt16(60))
        return packet(14, b)
    }
    private func fixture(send: Bool = false) throws -> (Session, UDP, Endpoint) {
        let relay = try UDP(port: 0, loopback: true), s = Session(testPeerPort: relay.boundPort)
        addTeardownBlock { s.shutdown() }
        let started = expectation(description: "matching start receipt")
        s.start(password: "isolated status secret", peerAddress: "", send: send, receive: false,
                plugins: false, name: "Test", completion: { receipt in XCTAssertEqual(receipt?.running, true); started.fulfill() })
        wait(for: [started], timeout: 3)
        s.connectServer("127.0.0.1:\(relay.boundPort)")
        var from: Endpoint?
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let (data, ep) = relay.receive(), data.count > 5, data[5] == 6 { from = ep; break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return (s, relay, try XCTUnwrap(from))
    }
    func testActualWireTelemetryReachesSeparateDetailsAndDepartureClearsIt() throws {
        let (s, relay, ep) = try fixture()
        let updated = expectation(description: "status packet and echoed ping reach the public view")
        var latest: JamView?, fulfilled = false
        s.onJamChange = { view in
            latest = view
            if !fulfilled, let text = view.serverDetails, text.contains("Server version server-v2.16."), !text.contains("round trip to the server: measuring.") {
                fulfilled = true; updated.fulfill()
            }
        }
        _ = relay.send(packet(7, [0, 0]), to: ep); _ = relay.send(info(), to: ep)
        var ping: Data?
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let (data, _) = relay.receive(), data.count > 5, data[5] == 15 { ping = data; break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        _ = relay.send(try XCTUnwrap(ping, "actual group ping"), to: ep)
        wait(for: [updated], timeout: 3)
        XCTAssertEqual(latest?.connected, true)
        XCTAssertTrue(latest?.serverDetails?.contains("5 people in 3 groups, 59 places free") == true)
        XCTAssertTrue(latest?.serverDetails?.contains("Send my audio is off") == true)
        XCTAssertFalse(latest?.serverStatus.contains("round trip") == true, "dynamic details must not become connection announcements")
        let left = expectation(description: "departure retires details")
        s.onJamChange = { view in if !view.connected, view.server.isEmpty { XCTAssertNil(view.serverDetails); s.onJamChange = nil; left.fulfill() } }
        s.disconnectServer(); wait(for: [left], timeout: 3)
    }
    func testSendOnWithoutSelectedServerPeerIsExplainedAndMinuteLogUsesExistingFile() throws {
        let (s, relay, ep) = try fixture(send: true)
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let folder = URL(fileURLWithPath: base).appendingPathComponent("server-status-\(UUID())")
        let file = JamLog(directory: folder, prefix: "status")
        s.testServerStatusLog(file)
        let updated = expectation(description: "sending intent reaches status")
        var fulfilled = false
        s.onJamChange = { view in
            guard !fulfilled, view.serverDetails?.contains("once you tick somebody there") == true else { return }
            fulfilled = true; updated.fulfill()
        }
        _ = relay.send(packet(7, [0, 0]), to: ep)
        wait(for: [updated], timeout: 3)
        s.testFlushServerStatusLog()
        let path = try XCTUnwrap(file.currentFile), text = try String(contentsOf: path)
        XCTAssertEqual(text.components(separatedBy: "server status [").count - 1, 1)
        XCTAssertTrue(text.contains("send input on")); XCTAssertTrue(text.contains(" | "))
        XCTAssertFalse(text.contains("isolated status secret"))
    }
    func testLegacyJamViewInitializerDefaultsDetailsToNil() {
        let v = JamView(connected: false, server: "", serverStatus: "Not connected.", metronomeRole: .solo,
                        metronomePlaying: false, metronomeLine: "stopped", metronomeBpm: 120, whenAsked: .ask)
        XCTAssertNil(v.serverDetails)
    }
}
