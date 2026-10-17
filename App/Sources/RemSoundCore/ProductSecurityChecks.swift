import CryptoKit
import Darwin
import Foundation
import RemSoundJam

extension ProductTestPack {
    static func checkEncryption() -> Step {
        let nonceBytes = 12, tagBytes = 16
        let envelopeBytes = nonceBytes + tagBytes
        var count = 0, failures: [String] = []
        func require(_ value: Bool, _ code: String) { count += 1; if !value { failures.append(code) } }
        do {
            let key = try Credentials(password: "synthetic security α🙂"), same = try Credentials(password: "synthetic security α🙂")
            let wrong = try Credentials(password: "different synthetic security")
            let message = Data("RemSound product encryption 0123456789".utf8)
            let cipher = try key.seal(message)
            require(try key.open(cipher) == message, "encryption.right-key")
            require((try? wrong.open(cipher)) == nil, "encryption.wrong-key")
            require(key.fingerprint == same.fingerprint, "encryption.same-fingerprint")
            require(key.fingerprint != wrong.fingerprint && key.fingerprint.count == Wire.fingerprintSize, "encryption.distinct-fingerprint")
            require((try? Credentials(password: "")) == nil, "encryption.password-required")
            require(cipher.count == message.count + envelopeBytes, "encryption.envelope-size")
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: cipher.prefix(nonceBytes)), ciphertext: cipher.dropFirst(envelopeBytes), tag: cipher[nonceBytes..<envelopeBytes])
            require(try AES.GCM.open(box, using: key.key) == message, "encryption.nonce-tag-cipher-layout")
            require(try key.seal(message).prefix(nonceBytes) != cipher.prefix(nonceBytes), "encryption.fresh-nonce")
            for index in [0, nonceBytes, envelopeBytes] {
                var damaged = cipher; damaged[index] ^= 1
                require((try? key.open(damaged)) == nil, "encryption.tamper-" + String(index))
            }
            require((0..<envelopeBytes).allSatisfy { (try? key.open(Data(cipher.prefix($0)))) == nil }, "encryption.every-short-envelope")
            let storage = PasswordStore(ephemeral: true)
            require(try storage.load() == nil, "encryption.isolated-store-empty")
            try storage.save("synthetic memory-only password")
            require(try storage.load() == "synthetic memory-only password", "encryption.isolated-store-roundtrip")
            try storage.delete(); require(try storage.load() == nil, "encryption.isolated-store-delete")
            require(try PasswordStore(ephemeral: true).load() == nil, "encryption.no-isolated-persistence")
        } catch { require(false, "encryption.operation-error") }
        let status = failures.isEmpty ? "UNVERIFIED" : "FAIL"
        // Mac intentionally uses Keychain, not Windows' reversible JSON scramble. Memory storage
        // cannot establish normal Keychain persistence and never opens that store here.
        failures.append("normal-keychain-persistence-acceptance-unverified")
        return .init(name: "Encryption round-trip", status: status, assertions: count, failures: failures)
    }

    static func checkPacketFraming() -> Step { protocolCheck(decryptorOnly: false) }
    static func checkReceiverDecryptor() -> Step { protocolCheck(decryptorOnly: true) }

    private static func protocolCheck(decryptorOnly: Bool) -> Step {
        let legacyFormatBytes = 32, pcmSubheaderBytes = 6, envelopeBytes = 28, fixtureFrames = 80
        let name = decryptorOnly ? "Receiver decryptor: wrong key yields silence, not noise"
            : "Packet framing and rejection (unknown types and cut-short payloads too)"
        var count = 0, failures: [String] = []
        func require(_ value: Bool, _ code: String) { count += 1; if !value { failures.append(code) } }
        if !decryptorOnly {
            for kind in [Wire.Kind.format, .audio, .heartbeat, .control] {
                let packet = Wire.parse(Wire.packet(kind, stream: 7, sequence: 42, payload: Data()))
                require(packet?.kind == kind && packet?.stream == 7 && packet?.sequence == 42, "framing.header-" + String(kind.rawValue))
            }
            require((0..<Wire.headerSize).allSatisfy { Wire.parse(Data(repeating: 0, count: $0)) == nil }, "framing.all-short-headers")
            require(Wire.parse(Data(repeating: 0, count: Wire.headerSize)) == nil, "framing.bad-magic")
            var bad = Wire.packet(.audio, payload: Data()); bad[4] = 99
            require(Wire.parse(bad) == nil, "framing.bad-version")
            require(StreamFormat.parse(Data(repeating: 0, count: legacyFormatBytes - 1)) == nil, "framing.short-format-parser")
            require(HeartbeatPayload.parse(Data(repeating: 0, count: Wire.heartbeatPayloadSize - 1)) == nil, "framing.short-heartbeat-parser")
            var sub = Data(); sub.put(UInt32(12345)); sub.append(contentsOf: [1, 3])
            require(sub.count == pcmSubheaderBytes && sub.u32(0) == 12345 && sub[4] == 1 && sub[5] == 3, "framing.actual-pcm-subheader-layout")
        }
        guard let raw = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"] else {
            let status = failures.isEmpty ? "UNVERIFIED" : "FAIL"
            failures.append("isolated-receiver-fixture-root-required")
            return .init(name: name, status: status, assertions: count, failures: failures)
        }
        let base = URL(fileURLWithPath: raw); var statValue = stat()
        guard base.path == raw, base.resolvingSymlinksInPath().path == raw,
            raw != FileManager.default.homeDirectoryForCurrentUser.path,
            lstat(raw, &statValue) == 0, statValue.st_mode & S_IFMT == S_IFDIR,
            statValue.st_uid == getuid(), statValue.st_mode & 0o077 == 0 else {
            return .init(name: name, status: "FAIL", assertions: count + 1, failures: ["receiver.fixture-root-refused"])
        }
        let root = base.appendingPathComponent("security-product-" + UUID().uuidString)
        var session: Session?, retired = false
        do {
            let peer = try UDP(port: 0, loopback: true)
            let owner = try Session.isolatedAudioProductSession(peerPort: peer.boundPort, root: root); session = owner
            let password = "synthetic receiver security", key = try Credentials(password: password)
            let wrong = try Credentials(password: "synthetic wrong receiver key")
            if decryptorOnly {
                owner.start(password: "", peerAddress: "", send: false, receive: true, plugins: false, name: "Receiver check")
                require(owner.testPorts.audio == 0 && owner.testProtocolObservation()?.decodedFrames == 0, "decryptor.no-key-no-receiver")
            }
            owner.start(password: password, peerAddress: "", send: false, receive: true, plugins: false, name: "Receiver check")
            let ports = owner.testPorts, target = Endpoint("127.0.0.1", ports.audio), remote = Endpoint("127.0.0.1", peer.boundPort)
            require(ports.audio > 0 && ports.discovery > 0 && ports.bridge == 0, "receiver.actual-isolated-bind")
            let format = StreamFormat.pcm(key.fingerprint, frames: fixtureFrames).encode()
            owner.testPeerPacket(Wire.packet(.format, stream: 9, payload: format), from: remote)
            require(owner.testProtocolObservation()?.streams == 0, "receiver.unselected-format-refused")
            owner.testSelectResolvedDirectPeer(name: "Synthetic peer", endpoint: remote)
            var marker: UInt32 = 0x70000000
            func send(_ data: Data) throws {
                guard peer.send(data, to: target) else { throw ProtocolError.invalid("Fixture send failed") }
                marker &+= 1
                let ping = Wire.packet(.heartbeat, stream: 7, sequence: marker, payload: HeartbeatPayload.encode(.ping, tickMs: UInt64(marker)))
                guard peer.send(ping, to: target) else { throw ProtocolError.invalid("Fixture barrier failed") }
                let until = ProcessInfo.processInfo.systemUptime + 0.5
                repeat {
                    for _ in 0..<32 {
                        guard let (bytes, from) = peer.receive() else { break }
                        if from == target, let reply = Wire.parse(bytes), reply.kind == .heartbeat,
                            reply.sequence == marker, HeartbeatPayload.parse(reply.payload)?.kind == .pong { return }
                    }
                    Thread.sleep(forTimeInterval: 0.0005)
                } while ProcessInfo.processInfo.systemUptime < until
                throw ProtocolError.invalid("Fixture receiver did not join")
            }
            if !decryptorOnly {
                for type: UInt8 in [0, 6, 7, 8, 9, 13, 255] {
                    let before = owner.testProtocolObservation()?.malformed ?? 0
                    var packet = Wire.packet(.format, stream: 9, payload: Data(repeating: 0, count: 40)); packet[5] = type
                    try send(packet)
                    require(owner.testProtocolObservation()?.malformed == before + 1 && owner.testProtocolObservation()?.streams == 0, "framing.unknown-counted-" + String(type))
                }
                for (kind, length) in [(Wire.Kind.format, legacyFormatBytes - 1), (.heartbeat, Wire.heartbeatPayloadSize - 1), (.control, 1), (.control, RemoteControl.sealedBytes - 1), (.tickProof, TickProofPayload.sealedBytes - 1)] {
                    let before = owner.testProtocolObservation()?.malformed ?? 0
                    try send(Wire.packet(kind, stream: 9, payload: Data(repeating: 0, count: length)))
                    require(owner.testProtocolObservation()?.malformed == before + 1 && owner.testProtocolObservation()?.streams == 0, "framing.short-counted-" + String(kind.rawValue) + "-" + String(length))
                }
            }
            for bytes in [Data(format.prefix(legacyFormatBytes)), Data(format.prefix(36)), StreamFormat.pcm(wrong.fingerprint).encode()] {
                try send(Wire.packet(.format, stream: 9, payload: bytes))
                require(owner.testProtocolObservation()?.streams == 0, "receiver.fingerprint-required")
            }
            try send(Wire.packet(.format, stream: 9, payload: format))
            require(owner.testProtocolObservation()?.streams == 1, "receiver.authenticated-format-opens-stream")
            var clear = Data()
            for _ in 0..<fixtureFrames { clear.append(contentsOf: [0, 0, 64, 0, 0, 224]) }
            var frame: UInt32 = 1
            func audio(_ encrypted: Data) -> Data {
                var payload = Data(); payload.put(frame); payload.append(contentsOf: [0, 1]); payload.append(encrypted); frame &+= 1
                return Wire.packet(.audio, stream: 9, sequence: frame, payload: payload)
            }
            let wrongCipher = try wrong.seal(clear), correctCipher = try key.seal(clear)
            let rejected = owner.testProtocolObservation()?.rejectedAudio ?? 0
            try send(audio(wrongCipher))
            require(owner.testProtocolObservation()?.decodedFrames == 0 && owner.testProtocolObservation()?.rejectedAudio == rejected + 1, "receiver.wrong-key-silent-counted")
            var tampered = correctCipher; tampered[tampered.count - 1] ^= 1
            try send(audio(tampered))
            require(owner.testProtocolObservation()?.decodedFrames == 0 && owner.testProtocolObservation()?.rejectedAudio == rejected + 2, "receiver.tampered-silent-counted")
            try send(audio(Data(repeating: 0, count: envelopeBytes - 1)))
            require(owner.testProtocolObservation()?.decodedFrames == 0 && owner.testProtocolObservation()?.rejectedAudio == rejected + 3
                && owner.testProtocolObservation()?.streams == 1, "receiver.short-envelope-counted-stream-retained")
            try send(audio(correctCipher))
            require(owner.testProtocolObservation()?.decodedFrames == UInt64(fixtureFrames), "receiver.actual-session-decoded-frames")
            require(try key.open(correctCipher) == clear, "decryptor.correct-key-byte-exact")
            if !decryptorOnly {
                owner.setAcceptRemoteCommands(true)
                let shortBefore = owner.testProtocolObservation()?.malformed
                // The Mac authenticates in Session rather than forwarding raw ciphertext to App.
                // A real listening-volume command changes only this isolated Session, never system volume.
                let control = Data(RemoteControl.plaintext(.volumeDown, delta: -5, unixSeconds: Int64(Date().timeIntervalSince1970)))
                try send(Wire.packet(.control, stream: RemoteControl.streamID, payload: try key.seal(control)))
                require(owner.testProtocolObservation()?.volume == 95 && owner.testProtocolObservation()?.malformed == shortBefore, "framing.valid-control-reaches-owned-state")
                let id = UUID(); try send(try key.tick(id: id, now: Int64(Date().timeIntervalSince1970), sequence: 42))
                require(owner.testVerifiedPeerIdentities()[remote.address] == id, "framing.valid-tick-reaches-owned-state")
            }
            retired = owner.finishIsolatedProductSession()
            require(retired && owner.testPorts.audio == 0, "receiver.actual-retirement")
            if retired {
                let rebound = try [ports.audio, ports.discovery].map { try UDP(port: $0, loopback: true) }
                require(rebound.allSatisfy { $0.boundPort > 0 }, "receiver.actual-sockets-released")
            }
        } catch { require(false, "receiver.fixture-or-protocol-error") }
        if let session { retired = session.finishIsolatedProductSession(); require(retired, "receiver.final-retirement") }
        session = nil
        if retired {
            do { try FileManager.default.removeItem(at: root); require(!FileManager.default.fileExists(atPath: root.path), "receiver.fixture-cleanup") }
            catch { require(false, "receiver.fixture-cleanup") }
        }
        return .init(name: name, status: failures.isEmpty ? "PASS" : "FAIL", assertions: count, failures: failures)
    }
}
