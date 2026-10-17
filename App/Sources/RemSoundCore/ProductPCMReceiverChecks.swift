import Darwin
import Foundation

extension ProductTestPack {
    static func checkPCMReassembly() -> Step {
        let name = "PCM frame reassembly (order, loss, discard counters)"
        var count = 0, failures: [String] = []
        func require(_ value: Bool, _ code: String) { count += 1; if !value { failures.append(code) } }
        do {
            let key = try Credentials(password: "synthetic assembly"), wrong = try Credentials(password: "wrong synthetic assembly")
            let frames = 480, channels = 2, pcmBytesPerSample = 3, envelopeBytes = 28
            let format = StreamFormat.pcm(key.fingerprint, frames: frames)
            var golden = Data()
            for _ in 0..<frames { golden.append(contentsOf: [0, 0, 64, 0, 0, 224]) }
            let cipher = try key.seal(golden), half = cipher.count / 2
            let parts = [Data(cipher.prefix(half)), Data(cipher.suffix(cipher.count - half))]
            func packet(_ bytes: Data, _ frame: UInt32, _ part: UInt8, _ total: UInt8) -> Wire.Packet {
                var payload = Data(); payload.put(frame); payload.append(contentsOf: [part, total]); payload.append(bytes)
                return .init(kind: .audio, stream: 9, sequence: UInt32(part), payload: payload)
            }
            func fixture() -> (StreamDecoder, ReceiveTotals) {
                let decoder = StreamDecoder(format, jitterMs: 2, smoothness: 10), totals = ReceiveTotals()
                decoder.receiveTotals = totals; return (decoder, totals)
            }
            let (ordered, orderedTotals) = fixture()
            require(!ordered.accept(packet(parts[0], 1, 0, 2), credentials: key), "pcm.first-part-pending")
            require(ordered.pendingPCMFrames == 1 && ordered.pendingPCMBytes == parts[0].count, "pcm.actual-bounded-pending-state")
            require(ordered.accept(packet(parts[1], 1, 1, 2), credentials: key), "pcm.second-part-completes")
            require(orderedTotals.decodedAudioFrames == UInt64(frames), "pcm.actual-production-decode")
            let samples = ordered.read(frames)
            require(samples.count == frames * channels && stride(from: 0, to: samples.count, by: channels).allSatisfy {
                samples[$0] == 0.5 && samples[$0 + 1] == -0.25
            }, "pcm.independent-byte-exact-stereo")
            require(ordered.pendingPCMFrames == 0 && ordered.pendingPCMBytes == 0, "pcm.complete-releases-cache")
            let (reverse, reverseTotals) = fixture()
            require(!reverse.accept(packet(parts[1], 2, 1, 2), credentials: key), "pcm.reverse-pending-not-audio")
            require(reverse.accept(packet(parts[0], 2, 0, 2), credentials: key), "pcm.reverse-completes-authenticated")
            require(reverseTotals.decodedAudioFrames == UInt64(frames) && reverse.read(frames) == samples, "pcm.reverse-same-production-output")
            let (duplicate, duplicateTotals) = fixture()
            _ = duplicate.accept(packet(parts[0], 3, 0, 2), credentials: key)
            require(!duplicate.accept(packet(parts[0], 3, 0, 2), credentials: key), "pcm.duplicate-not-complete")
            require(duplicateTotals.rejectedPCMFragments == 1 && duplicate.pendingPCMBytes == parts[0].count, "pcm.duplicate-counted-no-growth")
            require(duplicate.accept(packet(parts[1], 3, 1, 2), credentials: key), "pcm.duplicate-keeps-valid-original")
            _ = duplicate.accept(packet(parts[0], 3, 0, 2), credentials: key)
            require(!duplicate.accept(packet(parts[1], 3, 1, 2), credentials: key)
                && duplicateTotals.decodedAudioFrames == UInt64(frames), "pcm.old-complete-frame-not-replayed")
            let (conflict, conflictTotals) = fixture()
            _ = conflict.accept(packet(parts[0], 4, 0, 2), credentials: key)
            require(!conflict.accept(packet(parts[0], 4, 0, 3), credentials: key), "pcm.total-conflict-refuses")
            require(conflict.pendingPCMFrames == 0 && conflictTotals.discardedPCMPartials == 1 && conflictTotals.rejectedPCMFragments == 1, "pcm.total-conflict-counted-released")
            _ = conflict.accept(packet(parts[0], 5, 0, 2), credentials: key)
            var damaged = parts[0]; damaged[0] ^= 1
            require(!conflict.accept(packet(damaged, 5, 0, 2), credentials: key), "pcm.conflicting-duplicate-refuses")
            require(conflict.pendingPCMFrames == 0 && conflictTotals.discardedPCMPartials == 2 && conflictTotals.rejectedPCMFragments == 2, "pcm.conflicting-duplicate-counted-released")
            let (invalid, invalidTotals) = fixture()
            require(!invalid.accept(packet(parts[0], 6, 0, 0), credentials: key), "pcm.zero-total-refuses")
            require(!invalid.accept(packet(parts[0], 6, 2, 2), credentials: key), "pcm.outside-index-refuses")
            require(!invalid.accept(packet(Data(repeating: 0, count: Wire.maxAudioPayload + 1), 6, 0, 2), credentials: key), "pcm.oversize-datagram-refuses")
            require(invalidTotals.rejectedPCMFragments == 3 && invalid.pendingPCMFrames == 0, "pcm.invalid-parts-counted-without-cache")
            let (bounded, boundedTotals) = fixture()
            for frame: UInt32 in 10..<19 { _ = bounded.accept(packet(Data([1]), frame, 1, 2), credentials: key) }
            require(bounded.pendingPCMFrames == 1 && bounded.pendingPCMBytes == 1, "pcm.ninth-partial-reuses-existing-eight-frame-budget")
            require(boundedTotals.discardedPCMPartials == 8 && boundedTotals.rejectedAudioPayloads == 0, "pcm.capacity-discards-counted-not-auth-failures")
            let (oversize, oversizeTotals) = fixture()
            let maximum = 2880 * channels * pcmBytesPerSample + envelopeBytes
            let partsToOverflow = maximum / Wire.maxAudioPayload + 1
            for part in 0..<partsToOverflow {
                _ = oversize.accept(packet(Data(repeating: 0, count: Wire.maxAudioPayload), 20, UInt8(part), 32), credentials: key)
            }
            require(oversize.pendingPCMFrames == 0 && oversize.pendingPCMBytes == 0, "pcm.total-frame-cap-before-copy")
            require(oversizeTotals.rejectedPCMFragments == 1 && oversizeTotals.discardedPCMPartials == 1 && maximum < partsToOverflow * Wire.maxAudioPayload, "pcm.total-frame-overflow-counted")
            _ = invalid.accept(packet(parts[0], 30, 0, 2), credentials: wrong)
            require(!invalid.accept(packet(parts[1], 30, 1, 2), credentials: wrong)
                && invalidTotals.rejectedAudioPayloads == 1 && invalidTotals.decodedAudioFrames == 0, "pcm.authentication-after-assembly-mandatory")
            _ = invalid.accept(packet(parts[0], 31, 0, 2), credentials: key)
            require(invalid.accept(packet(parts[1], 31, 1, 2), credentials: key)
                && invalidTotals.decodedAudioFrames == UInt64(frames), "pcm.recovers-after-rejections")
            require(invalid.pendingPCMFrames == 0, "pcm.no-partial-left-after-recovery")
        } catch { require(false, "pcm.fixture-or-codec-error") }
        let status = failures.isEmpty ? "UNVERIFIED" : "FAIL"
        failures.append("windows-single-active-in-order-discard-policy-not-matched")
        return .init(name: name, status: status, assertions: count, failures: failures)
    }

    static func checkReceiverAllowList() -> Step {
        let name = "Receiver allow-list gate (stranger rejected, no session)"
        var count = 0, failures: [String] = []
        func require(_ value: Bool, _ code: String) { count += 1; if !value { failures.append(code) } }
        guard let raw = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"] else {
            return .init(name: name, status: "UNVERIFIED", assertions: 0, failures: ["isolated-receiver-fixture-root-required"])
        }
        let base = URL(fileURLWithPath: raw); var statValue = stat()
        guard base.path == raw, base.resolvingSymlinksInPath().path == raw,
            raw != FileManager.default.homeDirectoryForCurrentUser.path,
            lstat(raw, &statValue) == 0, statValue.st_mode & S_IFMT == S_IFDIR,
            statValue.st_uid == getuid(), statValue.st_mode & 0o077 == 0 else {
            return .init(name: name, status: "FAIL", assertions: 1, failures: ["receiver.fixture-root-refused"])
        }
        let root = base.appendingPathComponent("allow-product-" + UUID().uuidString)
        var session: Session?, retired = false
        do {
            let selected = try UDP(port: 0, loopback: true), alternate = try UDP(port: 0, loopback: true)
            let owner = try Session.isolatedAudioProductSession(peerPort: selected.boundPort, root: root); session = owner
            let password = "synthetic selected address", key = try Credentials(password: password), wrong = try Credentials(password: "synthetic other key")
            owner.start(password: password, peerAddress: "", send: false, receive: true, plugins: false, name: "Allow check")
            let ports = owner.testPorts, target = Endpoint("127.0.0.1", ports.audio)
            require(ports.audio > 0 && ports.discovery > 0 && ports.bridge == 0, "allow.actual-owned-receiver")
            owner.testSelectResolvedDirectPeer(name: "Selected", endpoint: Endpoint("127.0.0.1", selected.boundPort))
            // Like the exact Windows check's InjectExternalPacket, this uses the existing isolated
            // dispatch seam for the stranger. No loopback alias or fabricated native source is created.
            let format = StreamFormat.pcm(key.fingerprint, frames: 80).encode()
            owner.testPeerPacket(Wire.packet(.format, stream: 9, payload: format), from: Endpoint("127.0.0.2", selected.boundPort))
            require(owner.testProtocolObservation()?.notAllowed == 1, "allow.stranger-counted")
            require(owner.testProtocolObservation()?.streams == 0, "allow.stranger-opens-nothing")
            var marker: UInt32 = 0x71000000
            func send(_ data: Data) throws {
                guard alternate.send(data, to: target) else { throw ProtocolError.invalid("Fixture send failed") }
                marker &+= 1
                guard alternate.send(Wire.packet(.heartbeat, sequence: marker, payload: HeartbeatPayload.encode(.ping, tickMs: UInt64(marker))), to: target) else { throw ProtocolError.invalid("Fixture join failed") }
                let until = ProcessInfo.processInfo.systemUptime + 0.5
                repeat {
                    for _ in 0..<32 {
                        guard let (bytes, from) = alternate.receive() else { break }
                        if from == target, let reply = Wire.parse(bytes), reply.kind == .heartbeat, reply.sequence == marker { return }
                    }
                    Thread.sleep(forTimeInterval: 0.0005)
                } while ProcessInfo.processInfo.systemUptime < until
                throw ProtocolError.invalid("Fixture join timed out")
            }
            try send(Wire.packet(.format, stream: 9, payload: StreamFormat.pcm(wrong.fingerprint).encode()))
            require(owner.testProtocolObservation()?.streams == 0 && owner.testProtocolObservation()?.notAllowed == 1, "allow.selected-still-needs-password")
            try send(Wire.packet(.format, stream: 9, payload: format))
            require(owner.testProtocolObservation()?.notAllowed == 1, "allow.other-source-port-not-rejected")
            require(owner.testProtocolObservation()?.streams == 1 && alternate.boundPort != selected.boundPort, "allow.selected-address-opens-from-other-port")
            var clear = Data(); for _ in 0..<80 { clear.append(contentsOf: [0, 0, 64, 0, 0, 224]) }
            var payload = Data(); payload.put(UInt32(1)); payload.append(contentsOf: [0, 1]); payload.append(try key.seal(clear))
            try send(Wire.packet(.audio, stream: 9, payload: payload))
            require(owner.testProtocolObservation()?.decodedFrames == 80, "allow.actual-audio-from-other-port")
            require(owner.testProtocolObservation()?.notAllowed == 1, "allow.positive-path-no-fake-rejection")
            retired = owner.finishIsolatedProductSession()
            require(retired && owner.testPorts.audio == 0, "allow.actual-retirement")
            if retired {
                let rebound = try [ports.audio, ports.discovery].map { try UDP(port: $0, loopback: true) }
                require(rebound.allSatisfy { $0.boundPort > 0 }, "allow.actual-sockets-released")
            }
        } catch { require(false, "allow.fixture-or-protocol-error") }
        if let session { retired = session.finishIsolatedProductSession(); require(retired, "allow.final-retirement") }
        session = nil
        if retired {
            do { try FileManager.default.removeItem(at: root); require(!FileManager.default.fileExists(atPath: root.path), "allow.fixture-cleanup") }
            catch { require(false, "allow.fixture-cleanup") }
        }
        return .init(name: name, status: failures.isEmpty ? "PASS" : "FAIL", assertions: count, failures: failures)
    }
}
