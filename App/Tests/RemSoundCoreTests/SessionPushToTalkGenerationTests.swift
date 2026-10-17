import RemSoundJam
import XCTest
@testable import RemSoundCore

final class SessionPushToTalkGenerationTests: XCTestCase {
    private let password = "isolated PTT generation"
    private func enabled() -> PushToTalkSettings { var s = PushToTalkSettings(); s.enabled = true; return s }
    private func collect(_ peer: UDP, seconds: Double = 0.08) -> [Wire.Packet] {
        var result: [Wire.Packet] = []; let end = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < end {
            while let (data, _) = peer.receive() { if let packet = Wire.parse(data) { result.append(packet) } }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return result
    }
    private func start(_ session: Session, system: Bool = false) throws -> UUID {
        let ready = expectation(description: "fresh PTT key epoch"), settings = enabled()
        var generation: UUID?, expected: UUID?
        session.onChange = { view in
            guard view.running, view.status.hasPrefix("Running."), view.pushToTalk == settings, view.pushToTalkKeyGeneration == expected else { return }
            generation = view.pushToTalkKeyGeneration; session.onChange = nil; ready.fulfill()
        }
        session.start(password: password, peerAddress: "127.0.0.1", send: true, receive: false,
            plugins: false, name: "Test", systemAudio: system, sendPacketSize: .small, pushToTalk: settings)
        expected = try XCTUnwrap(session.testPushToTalkGeneration())
        wait(for: [ready], timeout: 3)
        let value = try XCTUnwrap(generation)
        XCTAssertEqual(value, session.testPushToTalkGeneration())
        return value
    }
    private func lastSample(_ session: Session, _ peer: UDP, frames: Int = 480) throws -> Float {
        session.testCapture([Float](repeating: 0.25, count: frames * 2))
        let packet = try XCTUnwrap(collect(peer).last { $0.kind == .audio })
        let credentials = try Credentials(password: password)
        let pcm = try credentials.open(Data(packet.payload.dropFirst(6)))
        let offset = pcm.count - 3
        let bits = UInt32(pcm[offset]) | UInt32(pcm[offset + 1]) << 8 | UInt32(pcm[offset + 2]) << 16
        return Float(Int32(bitPattern: bits << 8) >> 8) / 8_388_608
    }
    func testChangedProfileRejectsOldPressAndOldReleaseAfterNewPress() throws {
        let peer = try UDP(port: 0, loopback: true), session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        let old = try start(session); _ = collect(peer)
        var settings = enabled(); settings.doubleTapSpeed = .slow
        session.setAudioOptions(send: true, receive: false, plugins: false, sendPacketSize: .small, pushToTalk: settings)
        let fresh = try XCTUnwrap(session.testPushToTalkGeneration()); XCTAssertNotEqual(old, fresh)
        session.setPushToTalkKeyTalking(true, generation: old)
        XCTAssertEqual(try lastSample(session, peer), 0)
        session.setPushToTalkKeyTalking(true, generation: fresh)
        XCTAssertEqual(try lastSample(session, peer), 0.25, accuracy: 0.00001)
        session.setPushToTalkKeyTalking(false, generation: old)
        XCTAssertEqual(try lastSample(session, peer), 0.25, accuracy: 0.00001)
    }
    func testRestartSameProfileRejectsPreviousSessionKey() throws {
        let peer = try UDP(port: 0, loopback: true), session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        let old = try start(session); _ = collect(peer)
        session.setPushToTalkKeyTalking(true, generation: old); _ = try lastSample(session, peer)
        session.shutdown()
        session.setPushToTalkKeyTalking(true, generation: old)
        let fresh = try start(session); XCTAssertNotEqual(old, fresh); _ = collect(peer)
        session.setPushToTalkKeyTalking(true, generation: old)
        XCTAssertEqual(try lastSample(session, peer), 0)
        session.setPushToTalkKeyTalking(true, generation: fresh)
        XCTAssertEqual(try lastSample(session, peer), 0.25, accuracy: 0.00001)
    }
    func testUnchangedOptionsKeepGenerationButSourceReplacementRetiresIt() throws {
        let peer = try UDP(port: 0, loopback: true), session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        let old = try start(session); _ = collect(peer)
        session.setAudioOptions(send: true, receive: false, plugins: false, sendPacketSize: .small, pushToTalk: enabled())
        XCTAssertEqual(old, session.testPushToTalkGeneration())
        session.setPushToTalkKeyTalking(true, generation: old)
        XCTAssertEqual(try lastSample(session, peer), 0.25, accuracy: 0.00001)
        session.setAudioOptions(send: true, receive: false, plugins: false, inputDeviceUIDs: ["synthetic changed source"], sendPacketSize: .small)
        let fresh = try XCTUnwrap(session.testPushToTalkGeneration()); XCTAssertNotEqual(old, fresh)
        session.setPushToTalkKeyTalking(true, generation: old)
        XCTAssertEqual(try lastSample(session, peer), 0)
    }
    func testApplicationCaptureReplacementPublishesFreshEpochWithoutPeerChanges() throws {
        let peer = try UDP(port: 0, loopback: true), session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        let old = try start(session, system: true); _ = collect(peer)
        var received: UUID?
        session.onChange = { view in
            guard view.pushToTalkKeyGeneration != old else { return }
            received = view.pushToTalkKeyGeneration; session.onChange = nil
        }
        session.setSendApplications(["synthetic.ptt.epoch.fixture"])
        let current = try XCTUnwrap(session.testPushToTalkGeneration())
        XCTAssertNotEqual(current, old)
        let delivered = expectation(description: "main queue delivered the worker's posted epoch")
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 3)
        XCTAssertEqual(received, current, "Source replacement posts its epoch before the worker barrier.")
        guard let received else { return }
        session.setPushToTalkKeyTalking(true, generation: received)
        XCTAssertEqual(try lastSample(session, peer), 0.25, accuracy: 0.00001)
        session.setSendApplications(["synthetic.ptt.epoch.fixture"])
        XCTAssertEqual(current, session.testPushToTalkGeneration())
    }
    func testFormatReplacementRejectsOldKeyWhileFreshKeyKeepsNewGeometry() throws {
        let peer = try UDP(port: 0, loopback: true), session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        let old = try start(session); _ = collect(peer)
        session.setAudioOptions(send: true, receive: false, plugins: false, sendPacketSize: .standard)
        let fresh = try XCTUnwrap(session.testPushToTalkGeneration()); XCTAssertNotEqual(old, fresh)
        session.setPushToTalkKeyTalking(true, generation: old)
        XCTAssertEqual(try lastSample(session, peer, frames: 233 * 3), 0)
        session.setPushToTalkKeyTalking(true, generation: fresh)
        XCTAssertEqual(try lastSample(session, peer, frames: 233 * 3), 0.25, accuracy: 0.00001)
    }
}
