import AVFoundation
import RemSoundJam
import XCTest
@testable import RemSoundCore

final class SessionPushToTalkTests: XCTestCase {
    private let password = "isolated PTT route"
    private func collect(_ peer: UDP, seconds: Double = 0.08) -> [Wire.Packet] {
        var result: [Wire.Packet] = []
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < end {
            while let (data, _) = peer.receive() {
                if let packet = Wire.parse(data) { result.append(packet) }
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return result
    }
    private func start(_ session: Session, settings: PushToTalkSettings, send: Bool = true,
                       system: Bool = false, plugin: Bool = false) {
        let ready = expectation(description: "isolated PTT sender")
        session.onChange = { view in
            guard view.running, view.status.hasPrefix("Running."), view.pushToTalk == settings else { return }
            XCTAssertEqual(view.pushToTalk, settings)
            session.onChange = nil; ready.fulfill()
        }
        session.start(password: password, peerAddress: "127.0.0.1", send: send,
            receive: false, plugins: plugin, name: "Test", systemAudio: system,
            sendPacketSize: .small, pushToTalk: settings)
        wait(for: [ready], timeout: 3)
    }
    private func decodedPCM(_ packets: [Wire.Packet]) throws -> [Float] {
        let credentials = try Credentials(password: password)
        var result: [Float] = []
        for packet in packets where packet.kind == .audio {
            XCTAssertEqual(packet.payload[5], 1)
            let pcm = try credentials.open(Data(packet.payload.dropFirst(6)))
            for index in stride(from: 0, to: pcm.count, by: 3) {
                let bits = UInt32(pcm[index]) | UInt32(pcm[index + 1]) << 8 | UInt32(pcm[index + 2]) << 16
                result.append(Float(Int32(bitPattern: bits << 8) >> 8) / 8_388_608)
            }
        }
        return result
    }
    private func key(_ session: Session, _ talking: Bool) throws {
        let generation = try XCTUnwrap(session.testPushToTalkGeneration())
        session.setPushToTalkKeyTalking(talking, generation: generation)
    }
    private func enabled() -> PushToTalkSettings { var s = PushToTalkSettings(); s.enabled = true; return s }
    private func push(_ session: Session, system: Bool = false, frames: Int = 480, value: Float = 0.25) {
        let samples = [Float](repeating: value, count: frames * 2)
        if system { session.testSystemCapture(samples) } else { session.testCapture(samples) }
    }
    func testInputKeyGateFadesButPreservesRealPCMGeometryAndSequence() throws {
        let peer = try UDP(port: 0, loopback: true), session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        start(session, settings: enabled()); _ = collect(peer)
        push(session); let closedPackets = collect(peer)
        let closed = try decodedPCM(closedPackets)
        XCTAssertEqual(closed.count, 960)
        XCTAssertEqual(closed.first ?? -1, 0.25 * 239 / 240, accuracy: 0.00001)
        XCTAssertEqual(closed.suffix(480).map(abs).max(), 0)
        try key(session, true); push(session)
        let openPackets = collect(peer), open = try decodedPCM(openPackets)
        XCTAssertEqual(open.last ?? -1, 0.25, accuracy: 0.00001)
        let audio = (closedPackets + openPackets).filter { $0.kind == .audio }
        XCTAssertEqual(Set(audio.map(\.stream)).count, 1)
        XCTAssertEqual(audio.map(\.sequence), Array(1...UInt32(audio.count)))
        XCTAssertTrue(closedPackets.contains { $0.kind == .format && StreamFormat.parse($0.payload)?.frames == 120 })
    }
    func testInputAndSystemSelectionHaveIndependentFades() throws {
        for path in PushToTalkCapturePath.allCases {
            let peer = try UDP(port: 0, loopback: true), session = Session(testPeerPort: peer.boundPort)
            defer { session.shutdown() }
            var settings = enabled(); settings.capturePath = path
            start(session, settings: settings, system: true); _ = collect(peer)
            push(session); let input = try decodedPCM(collect(peer))
            push(session, system: true); let system = try decodedPCM(collect(peer))
            XCTAssertEqual(input.last ?? -1, path == .systemAudio ? 0.25 : 0, accuracy: 0.00001)
            XCTAssertEqual(system.first ?? -1, path == .input ? 0.25 : 0.25 * 239 / 240, accuracy: 0.00001)
            XCTAssertEqual(system.last ?? -1, path == .input ? 0.25 : 0, accuracy: 0.00001)
        }
    }
    func testLevelTriggerIgnoresKeyAndClosesAfterHangAcrossWorkerTicks() throws {
        let peer = try UDP(port: 0, loopback: true), session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        var settings = enabled(); settings.trigger = .level
        start(session, settings: settings); _ = collect(peer)
        push(session, value: 0.001); XCTAssertEqual(try decodedPCM(collect(peer)).last, 0)
        push(session); XCTAssertEqual(try decodedPCM(collect(peer)).last ?? -1, 0.25, accuracy: 0.00001)
        push(session, value: 0.001); XCTAssertEqual(try decodedPCM(collect(peer)).last ?? -1, 0.001, accuracy: 0.00001)
        Thread.sleep(forTimeInterval: 0.55)
        try key(session, true); push(session, value: 0.001)
        XCTAssertEqual(try decodedPCM(collect(peer)).last, 0)
    }
    func testPluginBypassDoesNotOpenCaptureAndNewPluginsHaveIndependentFades() throws {
        for bypass in [false, true] {
            let peer = try UDP(port: 0, loopback: true), plugin = try UDP(port: 0, loopback: true)
            let session = Session(testPeerPort: peer.boundPort)
            defer { session.shutdown() }
            var settings = enabled(); settings.bypassForPlugin = bypass
            start(session, settings: settings, plugin: true); _ = collect(peer)
            let bridge = Endpoint("127.0.0.1", session.testPorts.bridge)
            for instance: UInt32 in [31, 32] {
                var pid = Data(); pid.put(UInt32(1))
                plugin.send(Bridge.encode(.hello, instance: instance, payload: pid), to: bridge); _ = collect(peer)
                var samples = Data(); for _ in 0..<480 * 2 { samples.put(Float(0.25).bitPattern) }
                plugin.send(Bridge.encode(.trackAudio, instance: instance, payload: samples), to: bridge)
                let audio = try decodedPCM(collect(peer))
                XCTAssertEqual(audio.first ?? -1, bypass ? 0.25 : 0.25 * 239 / 240, accuracy: 0.00001)
                XCTAssertEqual(audio.last ?? -1, bypass ? 0.25 : 0, accuracy: 0.00001)
            }
            push(session); XCTAssertEqual(try decodedPCM(collect(peer)).last, 0)
        }
    }
    func testUnchangedOptionsPreserveHeldKeyButChangedProfileAndRestartRetireIt() throws {
        let peer = try UDP(port: 0, loopback: true), session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        var settings = enabled(); start(session, settings: settings); _ = collect(peer)
        try key(session, true); push(session); _ = collect(peer)
        session.setAudioOptions(send: true, receive: false, plugins: false, sendPacketSize: .small, pushToTalk: settings)
        push(session); XCTAssertEqual(try decodedPCM(collect(peer)).last ?? -1, 0.25, accuracy: 0.00001)
        settings.doubleTapSpeed = .slow
        session.setAudioOptions(send: true, receive: false, plugins: false, sendPacketSize: .small, pushToTalk: settings)
        push(session); XCTAssertEqual(try decodedPCM(collect(peer)).last, 0)
        try key(session, true); push(session); _ = collect(peer)
        start(session, settings: settings); _ = collect(peer)
        push(session); XCTAssertEqual(try decodedPCM(collect(peer)).last, 0)
    }
    func testApplicationCaptureReplacementRetiresHeldKeyAndKeepsFixtureDeviceFree() throws {
        let peer = try UDP(port: 0, loopback: true), session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        start(session, settings: enabled(), system: true); _ = collect(peer)
        try key(session, true); push(session, system: true); _ = collect(peer)
        session.setSendApplications(["synthetic.ptt.fixture"])
        push(session, system: true)
        XCTAssertEqual(try decodedPCM(collect(peer)).last, 0)
        try key(session, true); push(session, system: true)
        XCTAssertEqual(try decodedPCM(collect(peer)).last ?? -1, 0.25, accuracy: 0.00001)
    }
    func testEnabledGateNeverOptsIntoInputSending() throws {
        let peer = try UDP(port: 0, loopback: true), session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        start(session, settings: enabled(), send: false); _ = collect(peer)
        try key(session, true); push(session)
        XCTAssertFalse(collect(peer).contains { $0.kind == .audio })
    }
    func testCustomOnlyRouteIsGatedAndStillRecordsOriginalOnce() throws {
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let url = URL(fileURLWithPath: root).appendingPathComponent("ptt-custom-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let peer = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: peer.boundPort, testCapturePushDriven: true)
        defer { session.shutdown() }
        var settings = enabled(); settings.bypassForRecording = true
        session.setJamulusStyle(true); start(session, settings: settings)
        var capable = Data([0]); capable.put(UInt64(1)); capable.append(JamulusStyle.labFlagCanDecode)
        peer.send(Wire.packet(.heartbeat, payload: capable), to: Endpoint("127.0.0.1", session.testPorts.audio))
        _ = collect(peer)
        let recording = expectation(description: "custom recording"), finished = expectation(description: "custom finished")
        var began = false, ended = false
        session.onChange = { view in
            if !began && view.recording { began = true; recording.fulfill() }
            if !ended && view.status.hasPrefix("Recording finished.") { ended = true; finished.fulfill() }
        }
        session.startRecording(url: url, source: .sent, format: .wavFloat)
        wait(for: [recording], timeout: 3)
        var packets: [Wire.Packet] = []
        for block in 0..<20 {
            let samples = (0..<JamulusStyle.frames).flatMap { frame -> [Float] in
                let value = Float(sin(Double(block * JamulusStyle.frames + frame) * 0.07) * 0.25)
                return [value, value]
            }
            session.testCapture(samples); packets += collect(peer, seconds: 0.015)
        }
        session.stopRecording(); wait(for: [finished], timeout: 3)
        let first = try XCTUnwrap(packets.first { $0.kind == .format })
        let format = try XCTUnwrap(StreamFormat.parse(first.payload))
        XCTAssertEqual(format.codec, StreamFormat.Codec.opusCustom.rawValue)
        XCTAssertFalse(packets.contains { $0.kind == .format && $0.stream != first.stream })
        let decoder = StreamDecoder(format, jitterMs: 2), credentials = try Credentials(password: password)
        let audio = packets.filter { $0.kind == .audio }
        XCTAssertEqual(audio.count, 20)
        XCTAssertEqual(audio.map(\.sequence), Array(1...20))
        for packet in audio { XCTAssertTrue(decoder.accept(packet, credentials: credentials)) }
        let decoded = decoder.read(20 * JamulusStyle.frames)
        XCTAssertLessThan(decoded.suffix(10 * JamulusStyle.frames * 2).map(abs).max() ?? 1, 0.001)
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let values = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        XCTAssertGreaterThan(values.map(abs).max() ?? 0, 0.24, "Custom-only input reaches the recording tap")
        XCTAssertEqual(values.filter { abs($0) > 0.000001 }.count, 20 * JamulusStyle.frames - 1,
                       "Capture is recorded once, without ordinary packetization or duplicate copies")
    }
    func testRecordingBypassUsesOriginalWhileWireRemainsGated() throws {
        for bypass in [false, true] {
            let root = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
            let url = URL(fileURLWithPath: root).appendingPathComponent("ptt-\(UUID()).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let peer = try UDP(port: 0, loopback: true), session = Session(testPeerPort: peer.boundPort)
            defer { session.shutdown() }
            var settings = enabled(); settings.bypassForRecording = bypass
            start(session, settings: settings); _ = collect(peer)
            // Retire the initial fade before beginning the actual file assertion.
            push(session); _ = collect(peer)
            let recording = expectation(description: "recording"), finished = expectation(description: "finished")
            var began = false, ended = false
            session.onChange = { view in
                if !began && view.recording { began = true; recording.fulfill() }
                if !ended && view.status.hasPrefix("Recording finished.") { ended = true; finished.fulfill() }
            }
            session.startRecording(url: url, source: .sent, format: .wavFloat)
            wait(for: [recording], timeout: 3)
            push(session); XCTAssertEqual(try decodedPCM(collect(peer)).last, 0)
            session.stopRecording(); wait(for: [finished], timeout: 3)
            let file = try AVAudioFile(forReading: url)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let values = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            XCTAssertGreaterThan(values.count, 0)
            XCTAssertEqual(values.map(abs).max() ?? -1, bypass ? 0.25 : 0, accuracy: 0.00001)
        }
    }
}
