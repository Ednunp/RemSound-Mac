import Foundation
import XCTest
import RemSoundJam
@testable import RemSoundCore

final class SelfMonitoringSessionTests: XCTestCase {
    private func until(_ seconds: Double, _ work: () -> Void = {}, _ done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            work()
            RunLoop.current.run(until: Date().addingTimeInterval(0.003))
            if done() { return true }
        }
        return done()
    }

    func testRealRelayReturnsTwoDAWStreamsWithoutPeersAndMuteStopsPlayback() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Packages/RemSoundJam/Tests/relay/remsound-relay.py")
        var probe: UDP? = try UDP(port: 0, loopback: true)
        let port = probe!.boundPort
        probe = nil
        let testRoot = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let folder = testRoot.appendingPathComponent("self-monitor-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let relay = Process()
        relay.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        relay.arguments = ["python3", script.path, "--host", "127.0.0.1", "--port", String(port),
                           "--log-path", folder.appendingPathComponent("relay.log").path]
        relay.standardOutput = FileHandle.nullDevice
        relay.standardError = FileHandle.nullDevice
        try relay.run()
        defer {
            if relay.isRunning { relay.terminate(); relay.waitUntilExit() }
            try? FileManager.default.removeItem(at: folder)
        }
        // A cold Python launch under Rosetta can outlast the client's first hello. Wait for its imports before joining.
        XCTAssertTrue(until(4) {
            let log = (try? String(contentsOf: folder.appendingPathComponent("relay.log"))) ?? ""
            return log.contains("event=startup") && !log.contains("event=bind_failed")
        }, "The isolated test relay must start before testing client connection")
        let session = Session(testPeerPort: port)
        defer { session.shutdown() }
        var connected = false, enabled = false, status = "", peers: [PeerView] = []
        session.onJamChange = { connected = $0.connected; enabled = $0.selfMonitoring; status = $0.selfMonitoringStatus }
        session.onChange = { peers = $0.peers }
        session.start(password: "isolated round trip", peerAddress: "", send: false,
                      receive: true, plugins: true, name: "Test", receiveJitterMs: 10,
                      serverAddress: "127.0.0.1:\(port)")
        XCTAssertTrue(until(4) { connected })
        let sender = try UDP(port: 0, loopback: true)
        let bridge = Endpoint("127.0.0.1", session.testPorts.bridge)
        var hello = Data(); hello.put(UInt32(1234))
        for id: UInt32 in [99, 100] { sender.send(Bridge.encode(.hello, instance: id, payload: hello), to: bridge) }
        var samples = Data()
        for _ in 0..<240 { samples.put(Float(0.25).bitPattern); samples.put(Float(-0.25).bitPattern) }
        func send() {
            for id: UInt32 in [99, 100] {
                sender.send(Bridge.encode(.trackAudio, instance: id, payload: samples), to: bridge)
            }
        }
        var ready = false
        send()
        XCTAssertTrue(until(1) {
            session.selfMonitoringReadiness { ready = $0 == nil }
            return ready
        }, "A DAW sending into the app can start a test while alone on the server")
        session.setSelfMonitoring(true)
        XCTAssertTrue(until(1, send) { enabled })
        var played: [Float] = []
        XCTAssertTrue(until(2, {
            send()
            played += session.testPlayback(240)
        }) {
            // Arrival measurements can precede primed playback; wait for both actual returned channels.
            status.components(separatedBy: "estimated total").count - 1 == 2
                && played.contains { $0 > 0.4 } && played.contains { $0 < -0.4 }
        })
        XCTAssertTrue(played.contains { $0 > 0.4 }, "Both returned streams must play, summed")
        XCTAssertTrue(played.contains { $0 < -0.4 })
        XCTAssertTrue(peers.isEmpty, "The self-echo must never appear as a peer")
        XCTAssertEqual(status.components(separatedBy: "estimated total").count - 1, 2, "Each sending lane is measured")
        session.setSelfMonitoring(false)
        XCTAssertTrue(until(1, send) { !enabled })
        _ = session.testPlayback(48_000)
        var muted: [Float] = []
        _ = until(0.1, { send(); muted += session.testPlayback(240) }) { false }
        XCTAssertFalse(muted.contains { abs($0) > 0.01 }, "Mute removes its receive streams without stopping normal sending")
        session.setSelfMonitoring(true)
        XCTAssertTrue(until(1, send) { enabled })
        XCTAssertTrue(until(2, send) { status.contains("estimated total") })
        relay.terminate()
        relay.waitUntilExit()
        XCTAssertTrue(until(6, send) { !enabled && status.contains("five seconds") },
                      "The safety timeout also applies after audio had returned successfully")
        session.disconnectServer()
        XCTAssertTrue(until(1) { !enabled && !connected })
    }

    func testNoEchoSafetyTimeoutAndRefusals() throws {
        let relay = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: relay.boundPort)
        defer { session.shutdown() }
        var connected = false, enabled = false, status = "", refusal: String?
        session.onJamChange = { connected = $0.connected; enabled = $0.selfMonitoring; status = $0.selfMonitoringStatus }
        session.selfMonitoringReadiness { refusal = $0 }
        XCTAssertTrue(until(1) { refusal?.contains("Connect") == true })
        session.start(password: "isolated no echo", peerAddress: "", send: false, receive: true,
                      plugins: false, name: "Test", serverAddress: "127.0.0.1:\(relay.boundPort)")
        var endpoint: Endpoint?
        XCTAssertTrue(until(3, {
            while let (data, sender) = relay.receive() {
                guard data.count > 5, data[5] == 6 else { continue }
                endpoint = sender
                relay.send(Data(JamWire.header(7, version: 2) + [UInt8](repeating: 0, count: 16) + [0, 0]), to: sender)
            }
        }) { connected })
        session.selfMonitoringReadiness { refusal = $0 }
        XCTAssertTrue(until(1) { refusal?.contains("sending") == true })
        session.setAudioOptions(send: true, receive: false, plugins: false)
        session.selfMonitoringReadiness { refusal = $0 }
        XCTAssertTrue(until(1) { refusal?.contains("Receive") == true })
        session.setAudioOptions(send: true, receive: true, plugins: false)
        session.setSelfMonitoring(true)
        XCTAssertTrue(until(1) { enabled })
        let roster = Data(JamWire.header(7, version: 2) + [UInt8](repeating: 0, count: 16) + [0, 0])
        XCTAssertTrue(until(6, { if let endpoint { relay.send(roster, to: endpoint) } }) {
            !enabled && status.contains("five seconds")
        }, "Receiving rosters is not receiving audio")
    }
}
