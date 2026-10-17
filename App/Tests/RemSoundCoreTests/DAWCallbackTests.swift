import XCTest
import RemSoundRuntime
@testable import RemSoundCore

final class DAWCallbackTests: XCTestCase {
    private func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined() }
    private func body(rate: Double = 48000, frames: UInt32 = 128) -> Data {
        var body = Data(); body.put(rate.bitPattern); body.put(frames); return body
    }
    func testOptionalHostCallbackMessagePreservesGoldenHelloAndExactDoubleRate() {
        let hello = Bridge.encode(.hello, instance: 0x12345678, payload: Data([1,0,0,0]))
        XCTAssertEqual(hex(hello), "5253425201010400785634120000000001000000")
        let packet = Bridge.encode(.hostCallback, instance: 0x12345678, payload: body())
        XCTAssertEqual(hex(packet), "52534252010A0C007856341200000000000000000070E74080000000")
        XCTAssertEqual(Bridge.parse(packet)?.kind, .hostCallback)
        XCTAssertEqual(DAWCallbackGeometry(payload: body(rate: 48000.125))?.sampleRate, 48000.125)
        XCTAssertEqual(DAWCallbackGeometry(payload: body())?.frames, 128)
    }
    func testInvalidGeometryAndPayloadSizesAreRefused() {
        for rate in [Double.nan, .infinity, -.infinity, 0, 7999, 768001] {
            XCTAssertNil(DAWCallbackGeometry(payload: body(rate: rate)))
        }
        for frames: UInt32 in [0, 1048577, .max] {
            XCTAssertNil(DAWCallbackGeometry(payload: body(frames: frames)))
        }
        for length in 0..<12 { XCTAssertNil(DAWCallbackGeometry(payload: body().prefix(length))) }
        XCTAssertNil(DAWCallbackGeometry(payload: body() + Data([0])))
    }
    func testMissingExpiredInvalidOrFutureObservationsNeverUseTheWorkerRequestAsHostGeometry() {
        var observation = DAWCallbackObservation()
        XCTAssertNil(observation.geometry(now: 0))
        observation.observe(body(), now: 10)
        XCTAssertEqual(observation.geometry(now: 12.999)?.frames, 128)
        XCTAssertNil(observation.geometry(now: 13))
        XCTAssertNil(observation.geometry(now: 9))
        observation.observe(body(rate: .nan), now: 12)
        observation.observe(body(frames: 256), now: .infinity)
        XCTAssertNil(observation.geometry(now: 13))
        observation.observe(body(rate: 96000, frames: 32), now: 14)
        XCTAssertEqual(observation.geometry(now: 14)?.frames, 32)
        let fresh = observation.logDescription(now: 14, workerRequestFrames: 240)
        XCTAssertTrue(fresh.contains("host callback 32 frames; nominal host rate 96000.000 Hz"))
        XCTAssertTrue(fresh.contains("bridge worker request 240 frames"))
        XCTAssertTrue(fresh.contains("derived block duration 0.333 ms"))
        XCTAssertTrue(observation.logDescription(now: 17, workerRequestFrames: 240).contains("not measured or stale"))
    }
    func testRegisteredEndpointTelemetryReachesBoundedLogWithoutChangingClaims() throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]))
            .appendingPathComponent(UUID().uuidString)
        let configuration = try RuntimeConfiguration(options: LaunchOptions.parse(["--config-dir", root.path]))
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(configuration: configuration)
        defer { session.shutdown() }
        let ready = expectation(description: "all hardware directions off")
        session.onChange = { view in if view.running { session.onChange = nil; ready.fulfill() } }
        session.start(password: "isolated telemetry", peerAddress: "", send: false,
            receive: false, plugins: true, name: "Test")
        wait(for: [ready], timeout: 3)
        let endpoint = Endpoint("127.0.0.1", session.testPorts.bridge)
        let plugin = try UDP(port: 0, loopback: true), impostor = try UDP(port: 0, loopback: true)
        var pid = Data(); pid.put(UInt32(12345))
        for instance: UInt32 in [17,18] { plugin.send(Bridge.encode(.hello, instance: instance, payload: pid), to: endpoint) }
        plugin.send(Bridge.encode(.hostCallback, instance: 17, payload: body()), to: endpoint)
        impostor.send(Bridge.encode(.hostCallback, instance: 17, payload: body(rate: 96000, frames: 64)), to: endpoint)
        plugin.send(Bridge.encode(.hostCallback, instance: 19, payload: body(rate: 96000, frames: 64)), to: endpoint)
        var claim = Data(); claim.put(UInt32(240)); claim.append(0); claim.put(UInt32(1))
        plugin.send(Bridge.encode(.claimPeers, instance: 17, payload: claim), to: endpoint)
        let snapshot = expectation(description: "worker emitted telemetry snapshot")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { snapshot.fulfill() }
        wait(for: [snapshot], timeout: 3)
        session.shutdown()
        let files = try FileManager.default.contentsOfDirectory(at: configuration.logsDirectory,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "log" }
        let text = try files.map { try String(contentsOf: $0) }.joined()
        XCTAssertTrue(text.contains("DAW callback observation: instance 17, host callback 128 frames; nominal host rate 48000.000 Hz"))
        XCTAssertTrue(text.contains("bridge worker request 240 frames"))
        XCTAssertTrue(text.contains("instance 18, host callback geometry not measured or stale"))
        XCTAssertFalse(text.contains("host callback 64 frames; nominal host rate 96000.000 Hz"))
        XCTAssertFalse(text.contains("DAW callback observation: instance 19"))
    }
}
