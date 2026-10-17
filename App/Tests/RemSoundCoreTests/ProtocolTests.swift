import CryptoKit
import RemSoundJam
import XCTest

@testable import RemSoundCore

final class ProtocolTests: XCTestCase {
    func testHeartbeatRoundTripUsesOnlyOwnRecentPingsAndExpires() {
        var timing = HeartbeatTiming()
        timing.sent(tickMs: 10_000)
        XCTAssertFalse(timing.receivedPong(from: "peer", echoTickMs: 9_000,
            nowTickMs: 10_012))
        XCTAssertTrue(timing.receivedPong(from: "peer", echoTickMs: 10_000,
            nowTickMs: 10_012))
        XCTAssertEqual(timing.range(selected: ["peer"], nowTickMs: 10_100), 12...12)
        timing.sent(tickMs: 11_000)
        XCTAssertTrue(timing.receivedPong(from: "peer", echoTickMs: 11_000,
            nowTickMs: 11_022))
        XCTAssertEqual(timing.range(selected: ["peer"], nowTickMs: 11_100), 15...15)
        XCTAssertNil(timing.range(selected: ["peer"], nowTickMs: 16_023))
    }
    func testReceiveBurstKeepsRecentAudioNearRequestedBuffer() throws {
        let key = try Credentials(password: "isolated receive burst")
        let decoder = StreamDecoder(StreamFormat.pcm(key.fingerprint), jitterMs: 10)
        for frame in 1...42 {
            let sample: [UInt8] = frame <= 34 ? [0, 0, 64] : [0, 0, 192]
            var pcm = Data()
            for _ in 0..<Wire.pcmFrames { pcm.append(contentsOf: sample + sample) }
            var payload = Data()
            payload.put(UInt32(frame))
            payload.append(contentsOf: [0, 1])
            payload.append(try key.seal(pcm))
            let packet = try XCTUnwrap(Wire.parse(Wire.packet(.audio, stream: 7,
                sequence: UInt32(frame), payload: payload)))
            decoder.accept(packet, credentials: key)
        }
        XCTAssertLessThan(decoder.read(240)[0], -0.4,
            "A short receive-queue stall should not replay old buffered sound.")
    }
    func testReceiveJitterTargetChangesWhenPCMStartsPlaying() throws {
        let key = try Credentials(password: "isolated jitter test")
        let decoder = StreamDecoder(StreamFormat.pcm(key.fingerprint), jitterMs: 40)
        var pcm = Data()
        for _ in 0..<Wire.pcmFrames { pcm.append(contentsOf: [0, 0, 64, 0, 0, 192]) }
        for frame in 1...8 {
            var payload = Data()
            payload.put(UInt32(frame))
            payload.append(contentsOf: [0, 1])
            payload.append(try key.seal(pcm))
            let packet = try XCTUnwrap(Wire.parse(Wire.packet(.audio, stream: 7,
                sequence: UInt32(frame), payload: payload)))
            decoder.accept(packet, credentials: key)
        }
        XCTAssertTrue(decoder.read(240).allSatisfy { $0 == 0 })
        var payload = Data()
        payload.put(UInt32(9))
        payload.append(contentsOf: [0, 1])
        payload.append(try key.seal(pcm))
        let ninth = try XCTUnwrap(Wire.parse(Wire.packet(.audio, stream: 7,
            sequence: 9, payload: payload)))
        decoder.accept(ninth, credentials: key)
        XCTAssertTrue(decoder.read(240).contains { $0 > 0.4 })
    }
    func testReceiveJitterTargetCanChangeWhileStreamIsBuffered() throws {
        let key = try Credentials(password: "isolated jitter test")
        let decoder = StreamDecoder(StreamFormat.pcm(key.fingerprint), jitterMs: 40)
        var pcm = Data()
        for _ in 0..<Wire.pcmFrames { pcm.append(contentsOf: [0, 0, 64, 0, 0, 192]) }
        for frame in 1...8 {
            var payload = Data()
            payload.put(UInt32(frame))
            payload.append(contentsOf: [0, 1])
            payload.append(try key.seal(pcm))
            let packet = try XCTUnwrap(Wire.parse(Wire.packet(.audio, stream: 7,
                sequence: UInt32(frame), payload: payload)))
            decoder.accept(packet, credentials: key)
        }
        decoder.setJitterMs(10)
        XCTAssertTrue(decoder.read(240).contains { $0 > 0.4 })
    }
    /// Lowered by hand, the excess goes at once, crossfaded (Windows' drain); lowered by the auto-tune, it stays for the
    /// descent to take down without a skip; raised, nothing is cut and nothing starts again while the clocks are kept.
    func testTheBufferLoweredByHandSkipsAtOnceAndByTheAutoTuneComesDownGently() throws {
        let key = try Credentials(password: "isolated jitter test")
        func filled(_ ms: Int) throws -> StreamDecoder {
            let decoder = StreamDecoder(StreamFormat.pcm(key.fingerprint), jitterMs: ms)
            var pcm = Data()
            for i in 0..<Wire.pcmFrames {
                let v = Int32(sin(Double(i) * 0.3) * 4_000_000)
                let b = [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16)]
                pcm.append(contentsOf: b + b)
            }
            for frame in 1...40 {
                var payload = Data()
                payload.put(UInt32(frame))
                payload.append(contentsOf: [0, 1])
                payload.append(try key.seal(pcm))
                decoder.accept(try XCTUnwrap(Wire.parse(Wire.packet(.audio, stream: 7, sequence: UInt32(frame),
                    payload: payload))), credentials: key)
            }
            _ = decoder.read(96)
            return decoder
        }
        let byHand = try filled(180)
        let before = byHand.queuedFrames
        byHand.setJitterMs(20, byHand: true)
        XCTAssertLessThanOrEqual(abs(byHand.queuedFrames - 20 * 48), 240, "there at once, give or take the 5 ms line-up")
        XCTAssertGreaterThan(before, 150 * 48)
        let gently = try filled(180)
        let held = gently.queuedFrames
        gently.setJitterMs(20)
        XCTAssertEqual(gently.queuedFrames, held, "the auto-tune's lowering is the descent's to take down")
        XCTAssertFalse(gently.read(96).allSatisfy { $0 == 0 }, "and it plays on meanwhile, nothing trimmed")
        let raised = try filled(100)
        let was = raised.queuedFrames
        raised.setJitterMs(160, byHand: true)
        XCTAssertEqual(raised.queuedFrames, was, "raised: nothing cut")
        XCTAssertFalse(raised.read(96).allSatisfy { $0 == 0 }, "and no gap while it fills")
    }
    func testOpusSenderInteroperatesWithWireDecoderAtBothFrameSizes() throws {
        let key = try Credentials(password: "test only")
        for codec in [SendCodec.opusBroadcast, .opusLive] {
            let sender = try XCTUnwrap(OpusSender(bitrate: codec.bitrate))
            let format = codec.format(key.fingerprint)
            XCTAssertEqual(StreamFormat.parse(format.encode()), format)
            let decoder = StreamDecoder(format)
            for sequence in 1...12 {
                let samples = (0..<(codec.frames * 2)).map { index in
                    Float(sin(Double(index / 2 + sequence * codec.frames) * 2 * .pi * 440 / 48000)) * 0.3
                }
                let encoded = try XCTUnwrap(sender.encode(samples))
                XCTAssertLessThan(encoded.count + 28 + Wire.headerSize, 1500)
                let packet = Wire.parse(Wire.packet(.audio, sequence: UInt32(sequence),
                    payload: try key.seal(encoded)))!
                decoder.accept(packet, credentials: key)
            }
            let output = decoder.read(codec.frames * 12)
            XCTAssertTrue(output.allSatisfy(\.isFinite))
            XCTAssertGreaterThan(output.map { abs($0) }.max() ?? 0, 0.15)
        }
    }
    func testEncryptedOpusAudioFixture() throws {
        let key = try Credentials(password: "test only")
        var format = StreamFormat.pcm(key.fingerprint)
        format.codec = StreamFormat.Codec.opus.rawValue
        format.frames = 480
        let decoder = StreamDecoder(format)
        let url = Bundle.module.url(
            forResource: "opus-vectors", withExtension: "bin", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: url)
        var offset = 0
        var sequence: UInt32 = 0
        while offset < data.count {
            let length = Int(data.u16(offset))
            offset += 2
            sequence += 1
            let sealed = try key.seal(Data(data[offset..<offset + length]))
            offset += length
            decoder.accept(
                Wire.parse(Wire.packet(.audio, sequence: sequence, payload: sealed))!, credentials: key)
        }
        let samples = decoder.read(2400)
        XCTAssertTrue(samples.allSatisfy { $0.isFinite })
        XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 0.1)
        XCTAssertLessThan(samples.map { abs($0) }.max() ?? 1, 0.5)
    }
    func testOpusDecoderRecoversFromAuthenticatedSenderRestart() throws {
        let key = try Credentials(password: "test only")
        var format = StreamFormat.pcm(key.fingerprint)
        format.codec = StreamFormat.Codec.opus.rawValue
        format.frames = 480
        let decoder = StreamDecoder(format)
        let url = Bundle.module.url(
            forResource: "opus-vectors", withExtension: "bin", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: url)
        func send(startingAt first: UInt32) throws {
            var offset = 0
            var sequence = first
            while offset < data.count {
                let length = Int(data.u16(offset))
                offset += 2
                let sealed = try key.seal(Data(data[offset..<offset + length]))
                offset += length
                decoder.accept(Wire.parse(Wire.packet(.audio, sequence: sequence, payload: sealed))!,
                    credentials: key)
                sequence += 1
            }
        }
        try send(startingAt: 2002)
        XCTAssertGreaterThan(decoder.read(5000).map { abs($0) }.max() ?? 0, 0.1)
        try send(startingAt: 1)
        XCTAssertGreaterThan(decoder.read(5000).map { abs($0) }.max() ?? 0, 0.1)
    }
    func testOriginalCSharpFixtures() throws {
        let url = Bundle.module.url(
            forResource: "windows-vectors", withExtension: "json", subdirectory: "Fixtures")!
        let values = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let c = try Credentials(password: values["password"] as! String)
        func bytes(_ key: String) -> Data {
            let s = values[key] as! String
            return Data(
                stride(from: 0, to: s.count, by: 2).map {
                    let a = s.index(s.startIndex, offsetBy: $0)
                    let b = s.index(a, offsetBy: 2)
                    return UInt8(s[a..<b], radix: 16)!
                })
        }
        XCTAssertEqual(StreamFormat.pcm(c.fingerprint).encode(), bytes("format"))
        XCTAssertEqual(try c.open(bytes("sealedAudio")), bytes("plain"))
        let tick = Wire.parse(bytes("tick"))!
        XCTAssertEqual(tick.kind, .tickProof)
        let plain = try c.open(tick.payload)
        XCTAssertEqual(plain.u64(1), 1_700_000_000)
        XCTAssertEqual(Data(plain.dropFirst(9)).hex, "00112233445566778899AABBCCDDEEFF")
    }
    func testGoldenPasswordContract() throws {
        let c = try Credentials(password: "remsound cross-port vector")
        XCTAssertEqual(
            c.key.withUnsafeBytes { Data($0).hex },
            "9CD07772496B22220FAC888EB0F5FBA005953FF2F71AABF391740FB1D9491B74")
        XCTAssertEqual(c.fingerprint.hex, "A77BF56B9EF1266B")
        XCTAssertNotEqual(c.fingerprint, c.key.withUnsafeBytes { Data($0.prefix(8)) })
    }
    /// Remote volume and mute: the sealed commands Windows makes (computed with a fixed nonce, checked independently with
    /// Python's AES-GCM), opened here with CryptoKit, and a command sealed here opened back.
    func testRemoteControlKnownAnswersOpen() throws {
        let nonce = "0102030405060708090A0B0C"
        func bytes(_ hex: String) -> Data {
            Data(stride(from: 0, to: hex.count, by: 2).map {
                UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)], radix: 16)!
            })
        }
        let a = try Credentials(password: "known answer")
        XCTAssertEqual(a.key.withUnsafeBytes { Data($0).hex },
            "B18D9451C3E4E3DC37153D8F5602905CAD900C1630833233EECA97398ED45CFB")
        let sealedA = bytes(nonce + "B18C0ADFE9A7B73F55626573A80418E3" + "1A6D60F65C34D89683A2")
        XCTAssertEqual(try a.open(sealedA).hex, "01FD803BB16A00000000", "VolumeDown -3 at 1790000000")
        let packet = Wire.packet(.control, stream: RemoteControl.streamID, sequence: 1, payload: sealedA)
        XCTAssertEqual(packet.count, 50)
        XCTAssertEqual(Data(packet.prefix(12)).hex, "524D4E440105FEFF01000000")
        let b = try Credentials(password: "remsound cross-port vector")
        XCTAssertEqual(try b.open(bytes(nonce + "DBF1B1F88D9C861333869D84B54D7F23" + "355A6712A8EDBE68C611")).hex,
            "0005803BB16A00000000", "VolumeUp +5")
        XCTAssertEqual(try b.open(bytes(nonce + "AAC6C7951C7EAAA16BCBEA061146F262" + "305F6712A8EDBE68C611")).hex,
            "0500803BB16A00000000", "SystemMuteToggle")
        XCTAssertThrowsError(try a.open(bytes(nonce + "DBF1B1F88D9C861333869D84B54D7F23" + "355A6712A8EDBE68C611")),
            "another password's command does not open")
        let plain = RemoteControl.plaintext(.muteToggle, delta: 0, unixSeconds: 1_790_000_000)
        let sealed = try a.seal(Data(plain))
        XCTAssertEqual(sealed.count, RemoteControl.sealedBytes)
        var guardian = ControlReceiveGuard()
        XCTAssertEqual(guardian.check(sealed: [UInt8](sealed), plain: [UInt8](try a.open(sealed)), now: 1_790_000_100),
            .accepted(.muteToggle, 0))
    }
    func testCryptoRejectsTamperingAndWrongPassword() throws {
        let c = try Credentials(password: "test only")
        let wrong = try Credentials(password: "wrong")
        let plain = Data([0, 1, 2, 255])
        let sealed = try c.seal(plain)
        XCTAssertEqual(sealed.count, plain.count + 28)
        XCTAssertEqual(try c.open(sealed), plain)
        XCTAssertThrowsError(try wrong.open(sealed))
        for i in [0, 12, 28] {
            var bad = sealed
            bad[i] ^= 1
            XCTAssertThrowsError(try c.open(bad))
        }
        XCTAssertThrowsError(try c.open(Data(repeating: 0, count: 27)))
        XCTAssertThrowsError(try Credentials(password: ""))
    }
    func testWireHeaderGoldenBytes() {
        let d = Wire.packet(.audio, stream: 0x1234, sequence: 0x1234_5678, payload: Data([9]))
        XCTAssertEqual(d.hex, "524D4E44010234127856341209")
        let parsed = Wire.parse(d)
        XCTAssertEqual(parsed?.stream, 0x1234)
        XCTAssertEqual(parsed?.sequence, 0x1234_5678)
        XCTAssertEqual(parsed?.payload, Data([9]))
        for n in 0..<12 { XCTAssertNil(Wire.parse(Data(d.prefix(n)))) }
        var bad = d
        bad[4] = 2
        XCTAssertNil(Wire.parse(bad))
        XCTAssertEqual(Wire.parse(Wire.packet(.audio, stream: 0, payload: Data()))?.stream, 1)
    }
    func testFormatContractAndMalformedInput() throws {
        let c = try Credentials(password: "remsound cross-port vector")
        let f = StreamFormat.pcm(c.fingerprint)
        let d = f.encode()
        XCTAssertEqual(d.count, 46)
        XCTAssertEqual(d.u32(0), 48000)
        XCTAssertEqual(d.u32(28), 233)
        XCTAssertEqual(StreamFormat.parse(d), f)
        XCTAssertNil(StreamFormat.parse(Data(d.prefix(31))))
        XCTAssertEqual(StreamFormat.parse(Data(d.prefix(43)))?.fingerprint,Data())
        for offset in [0, 4, 8, 12, 24, 28] {
            var bad = d
            bad.replaceSubrange(offset..<offset + 4, with: [255, 255, 255, 127])
            XCTAssertNil(StreamFormat.parse(bad))
        }
    }
    func testWindowsCodecIdentifiers() {
        // Codec identifiers remain compatible with Windows, including its lab custom mode.
        let pcm = StreamFormat.pcm(Data(repeating: 0, count: 8))
        XCTAssertEqual(pcm.codec, 1)
        var opus = pcm.encode()
        opus.replaceSubrange(24..<28, with: [2, 0, 0, 0])
        XCTAssertEqual(StreamFormat.parse(opus)?.codec, 2)
        var flagged = pcm.encode()
        flagged[33] = 0x80
        XCTAssertEqual(StreamFormat.parse(flagged), pcm.flagged(0x80))
        var unknownCodec = pcm.encode()
        unknownCodec.replaceSubrange(24..<28, with: [4, 0, 0, 0])
        XCTAssertNil(StreamFormat.parse(unknownCodec))
    }
    func testCustomOpusFormatRejectsUnsupportedFramesAndMono() {
        for frames in [64, 128] {
            let format = StreamFormat.opusCustom(Data(repeating: 0, count: 8), frames: frames)
            XCTAssertEqual(StreamFormat.parse(format.encode()), format)
        }
        for frames in [32, 233, 2880] {
            XCTAssertNil(StreamFormat.parse(StreamFormat.opusCustom(
                Data(repeating: 0, count: 8), frames: frames).encode()))
        }
        var mono = StreamFormat.opusCustom(Data(repeating: 0, count: 8), frames: 64)
        mono.channels = 1
        XCTAssertNil(StreamFormat.parse(mono.encode()))
    }
    func testTickProofUuidNetworkOrder() throws {
        let c = try Credentials(password: "test only")
        let id = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
        let p = Wire.parse(try c.tick(id: id, now: 123456, sequence: 7))!
        XCTAssertEqual(p.kind, .tickProof)
        XCTAssertEqual(p.stream, 65535)
        XCTAssertEqual(p.payload.count, 53)
        let plain = try c.open(p.payload)
        XCTAssertEqual(plain.count, 25)
        XCTAssertEqual(plain.u64(1), 123456)
        XCTAssertEqual(Data(plain.dropFirst(9)).hex, "00112233445566778899AABBCCDDEEFF")
    }
    func testBridgeRejectsRetiredMessagesAndOversizedClaims() {
        let d = Bridge.encode(.hello, instance: 0x1234_5678, payload: Data([1, 0, 0, 0]))
        XCTAssertEqual(d.hex, "5253425201010400785634120000000001000000")
        XCTAssertEqual(Bridge.parse(d)?.instance, 0x1234_5678)
        for type: UInt8 in [0, 2, 5, 11, 255] {
            var bad = d
            bad[5] = type
            XCTAssertNil(Bridge.parse(bad))
        }
        for n in 0..<d.count { XCTAssertNil(Bridge.parse(Data(d.prefix(n)))) }
        var claim = Data()
        claim.put(Int32(8192))
        claim.append(1)
        claim.append(contentsOf: [192, 168, 1, 4])
        claim.put(UInt32(19))
        XCTAssertEqual(Bridge.claim(claim)?.frames, 8192)
        XCTAssertEqual(Bridge.claim(claim)?.ask, 19)
        claim[4] = 33
        XCTAssertNil(Bridge.claim(claim))
    }
    func testDiscoveryKeysCaseAndPorts() throws {
        let a = Announcement(id: UUID(), name: "Test peer", send: true, receive: false)
        let d = try JSONEncoder().encode(a)
        let j = try JSONSerialization.jsonObject(with: d) as! [String: Any]
        XCTAssertEqual(Set(j.keys), Set(["InstanceId", "Name", "AudioPort", "CanSend", "CanReceive"]))
        XCTAssertEqual(Wire.audioPort, 47830)
        XCTAssertEqual(Wire.discoveryPort, 47821)
        XCTAssertEqual(Wire.bridgePort, 47831)
        XCTAssertEqual(Wire.discoveryInterval, 1.5)
        XCTAssertEqual(Wire.discoveryExpiry, 8)
        XCTAssertEqual(Wire.maxAudioPayload, 1454)
        XCTAssertEqual(Bridge.sampleRate, 48000)
        XCTAssertEqual(Bridge.maxAudioBytes, 32768)
    }
    func testRingWrapAndOverflowPreserveQueuedAudio() {
        let r = StereoRing(capacity: 4)
        r.write([1, 2, 3, 4, 5, 6])
        r.write([7, 8, 9, 10])
        XCTAssertEqual(r.available, 3)
        XCTAssertEqual(r.read(2), [1, 2, 3, 4])
        r.write([7, 8, 9, 10])
        XCTAssertEqual(r.read(4), [5, 6, 7, 8, 9, 10, 0, 0])
    }
    func testPCMDecodeFromEncryptedWindowsLayout() throws {
        let c = try Credentials(password: "test only")
        let decoder = StreamDecoder(.pcm(c.fingerprint))
        var raw = Data()
        for _ in 0..<1000 { raw.append(contentsOf: [0, 0, 64, 0, 0, 192]) }
        let encrypted = try c.seal(raw)
        let parts = (encrypted.count + 1453) / 1454
        // Deliberately deliver parts in reverse order, as UDP is allowed to do.
        for part in (0..<parts).reversed() {
            var d = Data()
            d.put(UInt32(1))
            d.append(UInt8(part))
            d.append(UInt8(parts))
            d.append(encrypted[(part * 1454)..<min(encrypted.count, (part + 1) * 1454)])
            decoder.accept(
                Wire.parse(Wire.packet(.audio, sequence: UInt32(part), payload: d))!, credentials: c)
        }
        let output = decoder.read(240)
        XCTAssertEqual(output.count, 480)
        XCTAssertEqual(output[0], 0.5)
        XCTAssertEqual(output[1], -0.5)
        let figures = decoder.takeLogFigures()
        XCTAssertEqual(figures.packets, 1, "Legacy stream logging also counts accepted PCM blocks")
        XCTAssertEqual(figures.interval.packets, 1, "PCM fragments become one authenticated audio block")
        XCTAssertEqual(figures.interval.queue?.count, 1, "Queue depth is sampled at the actual pull")
        XCTAssertGreaterThan(figures.interval.queue?.maximum ?? 0, 0)
        XCTAssertEqual(decoder.takeLogFigures().interval.packets, 0, "Reporting resets the interval")
    }
    func testPCMDecoderRecoversFromAuthenticatedSenderRestart() throws {
        let key = try Credentials(password: "test only")
        let decoder = StreamDecoder(.pcm(key.fingerprint))
        func send(frame: UInt32, sample: Int16, tampered: Bool = false) throws {
            var raw = Data()
            for _ in 0..<1000 {
                let value = UInt32(bitPattern: Int32(sample) << 8)
                for _ in 0..<2 {
                    raw.append(UInt8(truncatingIfNeeded: value))
                    raw.append(UInt8(truncatingIfNeeded: value >> 8))
                    raw.append(UInt8(truncatingIfNeeded: value >> 16))
                }
            }
            var encrypted = try key.seal(raw)
            if tampered { encrypted[encrypted.count - 1] ^= 1 }
            let parts = (encrypted.count + Wire.maxAudioPayload - 1) / Wire.maxAudioPayload
            for part in 0..<parts {
                var payload = Data()
                payload.put(frame)
                payload.append(UInt8(part))
                payload.append(UInt8(parts))
                payload.append(encrypted[(part * Wire.maxAudioPayload)..<min(encrypted.count, (part + 1) * Wire.maxAudioPayload)])
                let packet = Wire.parse(Wire.packet(.audio, sequence: frame, payload: payload))!
                decoder.accept(packet, credentials: key)
            }
        }
        try send(frame: 2002, sample: 16384)
        XCTAssertEqual(decoder.read(240)[0], 0.5)
        try send(frame: 2001, sample: -16384)
        XCTAssertEqual(decoder.read(240)[0], 0.5, "Small reordering must not reset playback")
        try send(frame: 1, sample: -16384, tampered: true)
        XCTAssertEqual(decoder.read(240)[0], 0.5, "Unauthenticated restart must not reset playback")
        try send(frame: 1, sample: -16384)
        XCTAssertEqual(decoder.read(240)[0], -0.5, "A restarted sender must resume on the same stream")
    }
    func testHistoryIndependentReadersAndBounds() {
        let h = AudioHistory()
        h.append([1, 2, 3, 4], at: 0)
        XCTAssertEqual(h.read(at: 0, frames: 2), [1, 2, 3, 4])
        XCTAssertEqual(h.read(at: 0, frames: 2), [1, 2, 3, 4])
        XCTAssertEqual(h.read(at: -1, frames: 4), [0, 0, 1, 2, 3, 4, 0, 0])
    }
}
extension Data { fileprivate var hex: String { map { String(format: "%02X", $0) }.joined() } }
