import XCTest
import RemSoundJam

@testable import RemSoundCore

final class SessionTests: XCTestCase {
    func testTwoAsynchronousInputsSendOneAudioSecondPerSecond() {
        for packetFrames in [64, 120, 128, 240, 480] {
            let microphone = StereoRing(capacity: 4_096)
            let interface = StereoRing(capacity: 4_096)
            let mix = SystemAudioMix(sources: [microphone, interface])
            var pacer = CapturePacer()
            var packets = 0
            for tick in 0..<1_000 {
                if tick.isMultiple(of: 16) { microphone.write([Float](repeating: 0.1, count: 768 * 2)) }
                if tick % 16 == 8 { interface.write([Float](repeating: 0.2, count: 768 * 2)) }
                let count = pacer.packetCount(now: Double(tick) / 1_000,
                    bufferedFrames: mix.available, packetFrames: packetFrames, pushDriven: true,
                    sourceCount: mix.sources.count)
                for _ in 0..<count { _ = mix.read(packetFrames) }
                packets += count
            }
            let expected = Wire.sampleRate / packetFrames
            XCTAssertGreaterThanOrEqual(packets, expected - 5)
            XCTAssertLessThanOrEqual(packets, expected + 1,
                "Two 48 kHz inputs must not produce two seconds of packets in one second")
        }
    }

    func testPacedCaptureKeepsDeadlineAcrossBriefEmptyBuffers() {
        var pacer = CapturePacer()
        var sent = 0
        for tick in 0..<1_000 {
            sent += pacer.packetCount(now: Double(tick) / 1_000,
                bufferedFrames: tick.isMultiple(of: 2) ? 120 : 0, packetFrames: 120)
        }
        XCTAssertLessThanOrEqual(sent, 401,
            "An empty intervening tick must not reset the sample clock")
    }

    func testStartForServerJoinsAfterStartupAndKeepsDirectPeersSelected() throws {
        let relay = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: relay.boundPort)
        defer { session.shutdown() }
        let waiting = expectation(description: "startup sends server join")
        session.onJamChange = { view in
            if view.serverStatus.contains("waiting for") {
                XCTAssertFalse(view.connected)
                waiting.fulfill()
            }
        }
        let started = expectation(description: "direct selection is preserved")
        session.onChange = { view in
            guard view.running else { return }
            session.onChange = nil
            XCTAssertEqual(view.peers.first?.address, "127.0.0.1")
            XCTAssertEqual(view.peers.first?.selected, true)
            started.fulfill()
        }
        session.start(password: "isolated server test", peerAddress: "127.0.0.1",
            send: false, receive: false, plugins: false, name: "Test",
            serverAddress: "127.0.0.1:\(relay.boundPort)")
        wait(for: [started, waiting], timeout: 3)
        var helloReceived = false
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if let (data, _) = relay.receive(), data.count > 5,
                data[5] == JamWire.Kind.hello.rawValue { helloReceived = true; break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertTrue(helloReceived, "Connect must reach the server after starting the session")
    }

    func testFailedStartupReportsServerFailureAndSendsNoJoin() throws {
        let relay = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: relay.boundPort)
        defer { session.shutdown() }
        let failed = expectation(description: "startup failure is readable in Server")
        session.onJamChange = { view in
            guard view.serverStatus.hasPrefix("Could not start RemSound for the server:") else { return }
            XCTAssertFalse(view.connected)
            XCTAssertTrue(view.serverStatus.contains("password"))
            failed.fulfill()
        }
        session.start(password: "", peerAddress: "", send: false,
            receive: false, plugins: false, name: "Test",
            serverAddress: "127.0.0.1:\(relay.boundPort)")
        wait(for: [failed], timeout: 3)
        XCTAssertNil(relay.receive(), "A failed session must not contact the server")
    }

    func testServerConnectionWaitsForRosterAcknowledgement() throws {
        let relay = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: relay.boundPort)
        defer { session.shutdown() }
        let started = expectation(description: "session starts")
        let waiting = expectation(description: "join sent, awaiting server")
        let joined = expectation(description: "server acknowledged join")
        session.onChange = { view in
            guard view.running else { return }
            // State notifications can repeat before the waiter resumes.
            session.onChange = nil
            started.fulfill()
        }
        session.start(password: "isolated server test", peerAddress: "", send: false,
            receive: false, plugins: false, name: "Test")
        wait(for: [started], timeout: 3)
        var observedWaiting = false
        session.onJamChange = { view in
            if view.serverStatus.contains("waiting for") {
                XCTAssertFalse(view.connected, "Sending a join request is not a confirmed connection")
                if !observedWaiting {
                    observedWaiting = true
                    waiting.fulfill()
                }
            }
            if view.connected && view.serverStatus.hasPrefix("On ") {
                session.onJamChange = nil
                joined.fulfill()
            }
        }
        session.connectServer("127.0.0.1:\(relay.boundPort)")
        wait(for: [waiting], timeout: 3)
        var sender: Endpoint?
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let (data, endpoint) = relay.receive(), data.count > 5,
                data[5] == JamWire.Kind.hello.rawValue { sender = endpoint; break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        let endpoint = try XCTUnwrap(sender, "A join request must actually reach the relay")
        let roster = JamWire.header(JamWire.Kind.roster.rawValue, version: JamWire.groupVersion)
            + [UInt8](repeating: 0, count: JamWire.clientIdSize) + [0, 0]
        _ = relay.send(Data(roster), to: endpoint)
        wait(for: [joined], timeout: 3)
    }

    func testCapturePacerSpreadsBurstInputAcrossItsAudioDuration() {
        var pacer = CapturePacer()
        var available = 0
        var sentAt = [Double]()
        for tick in 0..<100 {
            let now = Double(tick) * 0.002
            if tick == 0 || tick == 50 { available += 4_800 }
            let packets = pacer.packetCount(
                now: now, bufferedFrames: available, packetFrames: SendCodec.opusLive.frames)
            available -= packets * SendCodec.opusLive.frames
            sentAt.append(contentsOf: repeatElement(now, count: packets))
        }
        XCTAssertGreaterThan(sentAt.count, 70)
        XCTAssertLessThanOrEqual(sentAt.count, 80)
        XCTAssertLessThan(sentAt.first.map { $0 } ?? 1, 0.01)
        XCTAssertLessThan(zip(sentAt, sentAt.dropFirst()).map { $1 - $0 }.max() ?? 1, 0.012,
            "A 100 ms input callback must not become a 90 ms packet gap")
    }

    func testCapturePacerCatchesUpAfterRepeatedDelayedTicks() {
        var pacer = CapturePacer()
        var available = 0
        for tick in 0..<500 {
            if tick.isMultiple(of: 50) { available += 4_800 }
            if tick % 50 > 0 && tick % 50 <= 10 { continue }
            let packets = pacer.packetCount(now: Double(tick) * 0.002,
                bufferedFrames: available, packetFrames: SendCodec.opusLive.frames)
            available -= packets * SendCodec.opusLive.frames
        }
        XCTAssertLessThan(available, 1_000,
            "Delayed ticks must not permanently turn captured audio into growing latency")
    }
    func testCapturePacerDropsStaleAudioOnlyAfterLatencyCap() {
        XCTAssertEqual(CapturePacer.staleFrames(bufferedFrames: 4_800,
            packetFrames: 120), 0)
        XCTAssertEqual(CapturePacer.staleFrames(bufferedFrames: 12_001,
            packetFrames: 120), 7_200)
    }

    func testDirectMicrophoneSendsEachHardwareBurstWithoutExtraPacing() {
        var pacer = CapturePacer()
        XCTAssertEqual(pacer.packetCount(now: 0, bufferedFrames: 512,
            packetFrames: 120, pushDriven: true), 4)
        XCTAssertEqual(pacer.packetCount(now: 0.002, bufferedFrames: 32,
            packetFrames: 120, pushDriven: true), 0)
        XCTAssertEqual(pacer.packetCount(now: 0.011, bufferedFrames: 544,
            packetFrames: 120, pushDriven: true), 4)
    }

    func testInputAndSystemFormatsUseSeparateWindowsReceiveLanes() {
        let format = StreamFormat.opus(Data(repeating: 0, count: 8), frames: 120)
        XCTAssertEqual(format.encode(lane: .wasapi)[32], 1)
        XCTAssertEqual(format.encode(lane: .asio)[32], 2,
            "Windows replaces concurrent streams that announce the same receive lane")
    }

    func testExtendedHeartbeatAnswersUsingKnownFields() throws {
        let peer = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        let started = expectation(description: "session starts")
        session.onChange = { if $0.running { started.fulfill() } }
        session.start(password: "isolated test", peerAddress: "127.0.0.1",
            send: false, receive: true, plugins: false, name: "Test")
        wait(for: [started], timeout: 3)

        var ping = Data([0])
        ping.put(Int64(1234))
        ping.append(0x80) // A future peer's optional flags byte.
        let sequence: UInt32 = 0x12345678
        let target = Endpoint("127.0.0.1", session.testPorts.audio)
        let deadline = Date().addingTimeInterval(2)
        var reply: Wire.Packet?
        while Date() < deadline && reply == nil {
            peer.send(Wire.packet(.heartbeat, stream: 7, sequence: sequence,
                payload: ping), to: target)
            if let (data, _) = peer.receive(), let packet = Wire.parse(data),
                packet.kind == .heartbeat, packet.sequence == sequence,
                packet.payload.first == 1 {
                reply = packet
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        var expected = Data([1])
        expected.append(ping.dropFirst().prefix(8))
        XCTAssertEqual(reply?.payload, expected,
            "Optional trailing heartbeat fields must not hide a selected peer")
    }

    func testOneAudioRoutePerRemoteInstancePrefersDirectSubnet() {
        let samePC = UUID()
        let anotherPC = UUID()
        let routes = [
            Session.SendRoute(address: "100.102.65.3", instanceID: samePC, onLink: false),
            Session.SendRoute(address: "192.168.200.2", instanceID: samePC, onLink: true),
            Session.SendRoute(address: "192.168.200.3", instanceID: anotherPC, onLink: true),
            Session.SendRoute(address: "203.0.113.4", instanceID: nil, onLink: false),
        ]
        XCTAssertEqual(Set(Session.preferredSendRoutes(routes)),
            Set(["192.168.200.2", "192.168.200.3", "203.0.113.4"]))
    }
    private func nextFormatStream(from peer: UDP) throws -> UInt16 {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let (data, _) = peer.receive(), let packet = Wire.parse(data), packet.kind == .format {
                return packet.stream
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        throw ProtocolError.invalid("No format packet arrived")
    }

    func testDeviceStreamChangesWhenSenderRestarts() throws {
        let peer = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        let firstStart = expectation(description: "first start")
        session.start(password: "isolated test", peerAddress: "127.0.0.1",
            send: true, receive: false, plugins: false, name: "Test") { receipt in
            XCTAssertEqual(receipt?.running, true)
            firstStart.fulfill()
        }
        wait(for: [firstStart], timeout: 3)
        session.testCapture([Float](repeating: 0.1, count: SendCodec.pcm.frames * 2))
        let first = try nextFormatStream(from: peer)
        session.shutdown()

        let secondStart = expectation(description: "second start")
        session.start(password: "isolated test", peerAddress: "127.0.0.1",
            send: true, receive: false, plugins: false, name: "Test") { receipt in
            XCTAssertEqual(receipt?.running, true)
            secondStart.fulfill()
        }
        wait(for: [secondStart], timeout: 3)
        session.testCapture([Float](repeating: 0.1, count: SendCodec.pcm.frames * 2))
        let second = try nextFormatStream(from: peer)
        XCTAssertNotEqual(first, second)
    }

    private func waitForPlayback(_ session: Session) -> [Float] {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let samples = session.testPlayback(960)
            if samples.contains(where: { $0 > 0.24 }) && samples.contains(where: { $0 < -0.24 }) {
                return samples
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return []
    }
    func testSavedPeerSelectionRestoresOnStart() throws {
        let peer = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        let started = expectation(description: "saved peer selected")
        session.onChange = { view in
            guard view.running else { return }
            XCTAssertEqual(view.peers.first?.address, "127.0.0.1")
            XCTAssertEqual(view.peers.first?.selected, true)
            started.fulfill()
        }
        session.start(password: "isolated test", peerAddress: "", savedPeerAddresses: ["127.0.0.1"],
            send: false, receive: true, plugins: true, name: "Test")
        wait(for: [started], timeout: 3)
    }
    func testSavedPeerNameRestoresAndCanBeCleared() throws {
        let peer = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        let named = expectation(description: "saved peer name")
        session.onChange = { view in
            if view.running && view.peers.first?.name == "Studio PC" { named.fulfill() }
        }
        session.start(password: "isolated test", peerAddress: "127.0.0.1",
            send: false, receive: true, plugins: false, name: "Test",
            peerAliases: ["127.0.0.1": "Studio PC"])
        wait(for: [named], timeout: 3)
        let restored = expectation(description: "advertised name restored")
        session.onChange = { view in
            if view.running && view.peers.first?.name == "127.0.0.1" { restored.fulfill() }
        }
        session.setPeerAlias(address: "127.0.0.1", alias: "")
        wait(for: [restored], timeout: 3)
    }
    func testSelectedWindowsPeerCanSendFromItsEphemeralSenderPort() throws {
        let receiver = try UDP(port: 0, loopback: true)
        let sender = try UDP(port: 0, loopback: true)
        XCTAssertNotEqual(receiver.boundPort, sender.boundPort)
        let credentials = try Credentials(password: "isolated test")
        let session = Session(testPeerPort: receiver.boundPort)
        defer { session.shutdown() }
        let started = expectation(description: "session starts")
        session.onChange = { if $0.running { started.fulfill() } }
        session.start(password: "isolated test", peerAddress: "127.0.0.1",
            send: false, receive: true, plugins: true, name: "Test")
        wait(for: [started], timeout: 3)
        let target = Endpoint("127.0.0.1", session.testPorts.audio)
        sender.send(Wire.packet(.format, stream: 7,
            payload: StreamFormat.pcm(credentials.fingerprint).encode()), to: target)
        var pcm = Data()
        for _ in 0..<233 { pcm.append(contentsOf: [0, 0, 32, 0, 0, 224]) }
        for frame in 1...16 {
            var payload = Data()
            payload.put(UInt32(frame))
            payload.append(contentsOf: [0, 1])
            payload.append(try credentials.seal(pcm))
            sender.send(Wire.packet(.audio, stream: 7, sequence: UInt32(frame), payload: payload),
                to: target)
            Thread.sleep(forTimeInterval: 0.005)
        }
        let output = waitForPlayback(session)
        XCTAssertTrue(output.contains { $0 > 0.24 },
            "Selected Windows peer must be received from its ephemeral sender port")
        XCTAssertTrue(output.contains { $0 < -0.24 })
    }
    func testAppMonitoringCanBeOffWhileDAWReceivesPeerAudio() throws {
        let peer = try UDP(port: 0, loopback: true)
        let plugin = try UDP(port: 0, loopback: true)
        let key = try Credentials(password: "isolated test")
        let session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        let started = expectation(description: "session starts")
        session.onChange = { if $0.running { started.fulfill() } }
        session.start(password: "isolated test", peerAddress: "127.0.0.1",
            send: false, receive: true, monitorInApp: false, plugins: true, name: "Test")
        wait(for: [started], timeout: 3)
        let ports = session.testPorts
        let remote = Endpoint("127.0.0.1", ports.audio)
        let local = Endpoint("127.0.0.1", ports.bridge)
        peer.send(Wire.packet(.format, stream: 7,
            payload: StreamFormat.pcm(key.fingerprint).encode()), to: remote)
        var pcm = Data()
        for _ in 0..<Wire.pcmFrames { pcm.append(contentsOf: [0, 0, 64, 0, 0, 192]) }
        for frame in 1...24 {
            var payload = Data()
            payload.put(UInt32(frame))
            payload.append(contentsOf: [0, 1])
            payload.append(try key.seal(pcm))
            peer.send(Wire.packet(.audio, stream: 7, sequence: UInt32(frame), payload: payload), to: remote)
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertTrue(session.testPlayback(960).allSatisfy { $0 == 0 },
            "App output must stay silent with monitoring off")
        var hello = Data()
        hello.put(UInt32(1234))
        plugin.send(Bridge.encode(.hello, instance: 99, payload: hello), to: local)
        var claim = Data()
        claim.put(Int32(240))
        claim.append(contentsOf: [1, 127, 0, 0, 1])
        claim.put(UInt32(1))
        let deadline = Date().addingTimeInterval(2)
        var gotAudio = false
        var replies = 0
        var peak: Float = 0
        var frame: UInt32 = 25
        func sendAudio() throws {
            var audioPayload = Data()
            audioPayload.put(frame)
            audioPayload.append(contentsOf: [0, 1])
            audioPayload.append(try key.seal(pcm))
            peer.send(Wire.packet(.audio, stream: 7, sequence: frame, payload: audioPayload), to: remote)
            frame += 1
        }
        while Date() < deadline {
            try sendAudio()
            plugin.send(Bridge.encode(.claimPeers, instance: 99, payload: claim), to: local)
            for _ in 0..<10 {
                try sendAudio()
                try sendAudio()
                if let (data, _) = plugin.receive(), let packet = Bridge.parse(data),
                    packet.kind == .peerAudioRound, packet.payload.count > Bridge.roundHeaderSize
                {
                    replies += 1
                    for offset in stride(from: Bridge.roundHeaderSize, to: packet.payload.count, by: 4) {
                        let amplitude = abs(Float(bitPattern: packet.payload.u32(offset)))
                        peak = max(peak, amplitude)
                        if amplitude > 0.1 {
                            gotAudio = true
                            break
                        }
                    }
                }
                if gotAudio { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            if gotAudio { break }
        }
        XCTAssertTrue(gotAudio, "Disabling app monitoring must not stop DAW receive audio; replies \(replies), peak \(peak)")
    }
    func testLiveAudioOptionsPreserveSessionAndPeerSelection() throws {
        let peer = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        let started = expectation(description: "started")
        session.onChange = { if $0.running { started.fulfill() } }
        session.start(password: "isolated test", peerAddress: "127.0.0.1",
            send: false, receive: true, plugins: true, name: "Test")
        wait(for: [started], timeout: 3)
        let originalPort = session.testPorts.audio
        for enabled in [false, true] {
            let updated = expectation(description: "audio options updated")
            session.onChange = { view in
                guard view.status.hasPrefix("Audio settings updated") else { return }
                XCTAssertTrue(view.running)
                XCTAssertEqual(view.sendingInput, enabled)
                XCTAssertTrue(view.sendingSystemAudio)
                XCTAssertEqual(view.receiving, enabled)
                XCTAssertEqual(view.allowingPlugins, enabled)
                XCTAssertEqual(view.peers.first?.address, "127.0.0.1")
                XCTAssertEqual(view.peers.first?.selected, true)
                XCTAssertEqual(view.inputChannelPairs, ["interface": [0, 2]])
                XCTAssertEqual(view.outputChannelPairs, ["output": [1]])
                XCTAssertEqual(view.outputDeviceUIDs, ["first-output", "second-output"])
                updated.fulfill()
            }
            session.setAudioOptions(send: enabled, receive: enabled, plugins: enabled,
                systemAudio: true, inputDeviceUIDs: ["interface"],
                inputChannelPairs: ["interface": [0, 2]],
                outputDeviceUIDs: ["first-output", "second-output"],
                outputChannelPairs: ["output": [1]])
            wait(for: [updated], timeout: 3)
            XCTAssertEqual(session.testPorts.audio, originalPort)
        }
        session.onChange = nil
    }
    func testRealSocketsPCMReceiveAndPluginSendWithoutMicrophone() throws {
        let peer = try UDP(port: 0, loopback: true)
        let plugin = try UDP(port: 0, loopback: true)
        // Derive the simulated peer's key before playback starts. Slow key derivation under Rosetta
        // otherwise fills the test-only, undrained playback ring with startup silence.
        let key = try Credentials(password: "isolated test")
        let session = Session(testPeerPort: peer.boundPort)
        let started = expectation(description: "session starts")
        var didStart = false
        session.onChange = { view in
            if view.running && !didStart {
                didStart = true
                started.fulfill()
            }
        }
        session.start(
            password: "isolated test", peerAddress: "127.0.0.1", send: false, receive: true, plugins: true,
            name: "Test")
        wait(for: [started], timeout: 3)
        defer { session.shutdown() }
        let ports = session.testPorts
        let remote = Endpoint("127.0.0.1", ports.audio)
        let local = Endpoint("127.0.0.1", ports.bridge)
        peer.send(
            Wire.packet(.format, stream: 7, payload: StreamFormat.pcm(key.fingerprint).encode()), to: remote)
        var pcm = Data()
        for _ in 0..<233 { pcm.append(contentsOf: [0, 0, 32, 0, 0, 224]) }
        for frame in 1...16 {
            var payload = Data()
            payload.put(UInt32(frame))
            payload.append(contentsOf: [0, 1])
            payload.append(try key.seal(pcm))
            peer.send(Wire.packet(.audio, stream: 7, sequence: UInt32(frame), payload: payload), to: remote)
            Thread.sleep(forTimeInterval: 0.005)
        }
        let played = waitForPlayback(session)
        XCTAssertTrue(played.contains { $0 > 0.24 })
        XCTAssertTrue(played.contains { $0 < -0.24 })
        var hello = Data()
        hello.put(UInt32(1234))
        plugin.send(Bridge.encode(.hello, instance: 99, payload: hello), to: local)
        let deadline = Date().addingTimeInterval(2)
        var gotList = false
        while Date() < deadline {
            if let (d, _) = plugin.receive(), let p = Bridge.parse(d), p.kind == .peerList {
                gotList = String(data: p.payload, encoding: .utf8)?.contains("127.0.0.1") == true
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertTrue(gotList)
        var samples = Data()
        for _ in 0..<480 {
            samples.put(Float(0.5).bitPattern)
            samples.put(Float(-0.5).bitPattern)
        }
        plugin.send(Bridge.encode(.trackAudio, instance: 99, payload: samples), to: local)
        var gotAudio = false
        var pluginStream: UInt16?
        let sendDeadline = Date().addingTimeInterval(2)
        while Date() < sendDeadline {
            if let (d, _) = peer.receive(), let p = Wire.parse(d) {
                if p.kind == .format, StreamFormat.parse(p.payload)?.codec == 1 {
                    pluginStream = p.stream
                }
                if p.kind == .audio, p.payload.count > 6,
                    let plain = try? key.open(Data(p.payload.dropFirst(6)))
                {
                    XCTAssertEqual(Array(plain.prefix(6)), [0, 0, 64, 0, 0, 192])
                    gotAudio = true
                }
            }
            if gotAudio && pluginStream != nil { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertNotNil(pluginStream)
        XCTAssertTrue(gotAudio, "DAW track sending must work with device sending off")
        plugin.send(Bridge.encode(.goodbye, instance: 99), to: local)
        plugin.send(Bridge.encode(.hello, instance: 99, payload: hello), to: local)
        plugin.send(Bridge.encode(.trackAudio, instance: 99, payload: samples), to: local)
        let restartedStream = try nextFormatStream(from: peer)
        XCTAssertNotEqual(pluginStream, restartedStream, "A restarted DAW sender needs a fresh stream ID")
    }

    func testInterleavedOpusStreamsHaveIndependentWireSequences() throws {
        let peer = try UDP(port: 0, loopback: true)
        let plugin = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        let started = expectation(description: "session starts")
        session.onChange = { if $0.running { started.fulfill() } }
        session.start(password: "isolated test", peerAddress: "127.0.0.1",
            send: false, receive: false, plugins: true, name: "Test", sendCodec: .opusLive)
        wait(for: [started], timeout: 3)

        let bridge = Endpoint("127.0.0.1", session.testPorts.bridge)
        var hello = Data()
        hello.put(UInt32(1234))
        for instance: UInt32 in [99, 100] {
            plugin.send(Bridge.encode(.hello, instance: instance, payload: hello), to: bridge)
        }
        var samples = Data()
        for frame in 0..<480 {
            let value = Float(sin(Double(frame) * 2 * .pi * 440 / 48000) * 0.2)
            samples.put(value.bitPattern)
            samples.put(value.bitPattern)
        }
        for _ in 0..<3 {
            for instance: UInt32 in [99, 100] {
                plugin.send(Bridge.encode(.trackAudio, instance: instance, payload: samples),
                    to: bridge)
            }
        }
        var byStream: [UInt16: [UInt32]] = [:]
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && byStream.values.reduce(0, { $0 + $1.count }) < 24 {
            if let (data, _) = peer.receive(), let packet = Wire.parse(data), packet.kind == .audio {
                byStream[packet.stream, default: []].append(packet.sequence)
            } else {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        XCTAssertEqual(byStream.count, 2)
        for sequences in byStream.values {
            XCTAssertGreaterThanOrEqual(sequences.count, 8)
            for (previous, next) in zip(sequences, sequences.dropFirst()) {
                XCTAssertEqual(next, previous &+ 1,
                    "Interleaving another stream must not look like packet loss to Windows")
            }
        }
    }
}
