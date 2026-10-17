import Darwin
import Foundation

extension ProductTestPack {
    // The Windows named check also captures a real output clock. This completes its isolated
    // transport/codec subcases without granting hardware permission or claiming that acceptance.
    static func checkAudioRoundTrip(opus: Bool) -> Step {
        let name = opus ? "Audio round-trip (Opus)" : "Audio round-trip (PCM)"
        var count = 0, failures: [String] = []
        func require(_ value: Bool, _ code: String) { count += 1; if !value { failures.append(code) } }
        func result() -> Step {
            let status = failures.isEmpty ? "UNVERIFIED" : "FAIL"
            failures.append("native-output-capture-and-device-clock-acceptance-unverified")
            return .init(name: name, status: status, assertions: count, failures: failures)
        }
        // Explicit owned fixture permission precedes sockets, Session, settings and native codecs.
        guard let raw = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"] else {
            return .init(name: name, status: "UNVERIFIED", assertions: 0,
                failures: ["isolated-audio-fixture-root-required", "native-output-capture-and-device-clock-acceptance-unverified"])
        }
        let base = URL(fileURLWithPath: raw)
        var state = stat()
        guard base.path == raw, base.resolvingSymlinksInPath().path == raw,
            raw != FileManager.default.homeDirectoryForCurrentUser.path,
            lstat(raw, &state) == 0, state.st_mode & S_IFMT == S_IFDIR,
            state.st_uid == getuid(), state.st_mode & 0o077 == 0 else {
            require(false, "audio.fixture-root-refused"); return result()
        }
        var source: Session?, root: URL?
        do {
            // This socket is both the real UDP peer and the independent packet observer; every
            // producer packet must cross it before the production authenticated decoder sees it.
            let peer = try UDP(port: 0, loopback: true)
            let sessionRoot = base.appendingPathComponent("audio-product-" + UUID().uuidString)
            root = sessionRoot
            let session = try Session.isolatedAudioProductSession(peerPort: peer.boundPort, root: sessionRoot)
            source = session
            require(root?.deletingLastPathComponent().path == raw, "audio.isolated-session-root")
            let password = "owned synthetic audio round trip"
            let key = try Credentials(password: password), wrong = try Credentials(password: "wrong synthetic audio key")
            let codec: SendCodec = opus ? .opusLive : .pcm
            session.start(password: password, peerAddress: "127.0.0.1", send: true,
                receive: false, plugins: false, name: "Audio check", sendCodec: codec)
            let ports = session.testPorts
            require(ports.audio > 0 && ports.bridge == 0 && ports.discovery > 0
                && session.testWebBoundAddresses().allSatisfy { $0 == "127.0.0.1" }, "audio.owned-loopback-bind")
            let frames = codec.frames, rate = Double(Wire.sampleRate)
            let format = codec.format(key.fingerprint)
            let decoder = StreamDecoder(format, jitterMs: 2, smoothness: 10)
            var observedFormat: StreamFormat?, first: Wire.Packet?
            var packets = 0, bytes = 0, decodedFrames = 0, blocks = 0
            var decoded: [Float] = [], original: [Float] = []
            var firstAt: Double?, firstFrames = 0
            let sustainedSeconds = 0.65, maximumBlocks = 400, maximumDatagramsPerDrain = 32
            let start = ProcessInfo.processInfo.systemUptime
            let finish = start + sustainedSeconds
            var next = start
            func drain() {
                for _ in 0..<maximumDatagramsPerDrain {
                    guard let (data, endpoint) = peer.receive() else { break }
                    guard endpoint.address == "127.0.0.1", endpoint.port == ports.audio,
                        let packet = Wire.parse(data) else { continue }
                    if packet.kind == .format { observedFormat = StreamFormat.parse(packet.payload) }
                    guard packet.kind == .audio else { continue }
                    packets += 1; bytes += data.count
                    if first == nil { first = packet }
                    if decoder.accept(packet, credentials: key) {
                        let available = decoder.queuedFrames
                        decodedFrames += available
                        decoded += decoder.read(available)
                        if firstAt == nil { firstAt = ProcessInfo.processInfo.systemUptime; firstFrames = decodedFrames }
                    }
                }
            }
            while ProcessInfo.processInfo.systemUptime < finish && blocks < maximumBlocks {
                let now = ProcessInfo.processInfo.systemUptime
                if now >= next {
                    let offset = blocks * frames
                    let samples = (0..<frames).flatMap { frame -> [Float] in
                        let position = Double(offset + frame)
                        return [Float(0.35 * sin(2 * .pi * position / 100)),
                            Float(0.20 * sin(2 * .pi * position / 50))]
                    }
                    original += samples; session.testCapture(samples); blocks += 1
                    next = start + Double(blocks * frames) / rate
                }
                drain(); Thread.sleep(forTimeInterval: 0.0005)
            }
            // Join only the final owned block, bounded separately from the sustained-rate sample.
            let drainUntil = ProcessInfo.processInfo.systemUptime + 0.1
            while decodedFrames < blocks * frames && ProcessInfo.processInfo.systemUptime < drainUntil {
                drain(); Thread.sleep(forTimeInterval: 0.0005)
            }
            let end = ProcessInfo.processInfo.systemUptime
            require(observedFormat != nil, "audio.actual-format-crossed-udp")
            require(observedFormat?.codec == format.codec && observedFormat?.fingerprint == key.fingerprint
                && observedFormat?.frames == frames, "audio.actual-format-codec-and-password")
            require(packets > 0, "audio.packets-crossed-udp")
            require(decodedFrames == blocks * frames && decodedFrames > 24_000, "audio.sustained-native-decoding")
            let average = bytes / max(1, packets)
            require(opus ? average < 400 : average > 500, "audio.real-codec-packet-size")
            let duration = end - (firstAt ?? end)
            let decodedRate = duration > 0 ? Double(decodedFrames - firstFrames) / duration : 0
            require(decodedRate > 43_200 && decodedRate < 52_800 && duration >= 0.5, "audio.actual-decoded-frame-rate")
            require(!decoded.isEmpty && decoded.allSatisfy { $0.isFinite && abs($0) < 1 }, "audio.finite-decoded-waveform")
            if opus {
                // Opus has coding look-ahead. Compare a fixed independent tone over all possible
                // delays in one packet, rather than comparing the decoder to another copy of itself.
                var correlations: [Double] = []
                for lane in 0..<2 {
                    var best = 0.0
                    for delay in 0...frames {
                        var xy = 0.0, xx = 0.0, yy = 0.0
                        for frame in stride(from: min(4 * frames, decodedFrames), to: min(decodedFrames, min(original.count / 2, 16 * frames)), by: 4) {
                            let expected = Double(original[(frame - delay) * 2 + lane])
                            let actual = Double(decoded[frame * 2 + lane])
                            xy += expected * actual; xx += expected * expected; yy += actual * actual
                        }
                        if xx > 0 && yy > 0 { best = max(best, xy / sqrt(xx * yy)) }
                    }
                    correlations.append(best)
                }
                require(correlations.allSatisfy { $0 > 0.98 }, "audio.opus-golden-stereo-tones")
            } else {
                require(decoded.count == original.count && zip(decoded, original).allSatisfy {
                    abs($0 - $1) <= 1 / 8_388_608
                }, "audio.pcm-independent-golden-waveform")
            }
            require(stride(from: 0, to: decoded.count, by: 2).contains {
                abs(decoded[$0] - decoded[$0 + 1]) > 0.1
            }, "audio.independent-stereo-lanes")
            if let first {
                let refusal = StreamDecoder(format, jitterMs: 2, smoothness: 10)
                require(!refusal.accept(first, credentials: wrong) && refusal.queuedFrames == 0, "audio.wrong-password-silence")
                var damaged = first.payload; damaged[damaged.count - 1] ^= 1
                let packet = Wire.Packet(kind: first.kind, stream: first.stream, sequence: first.sequence, payload: damaged)
                require(!refusal.accept(packet, credentials: key) && refusal.queuedFrames == 0, "audio.tampered-cipher-silence")
                let once = StreamDecoder(format, jitterMs: 2, smoothness: 10)
                let accepted = once.accept(first, credentials: key), queued = once.queuedFrames
                require(accepted && !once.accept(first, credentials: key) && once.queuedFrames == queued, "audio.duplicate-not-played-twice")
            } else { require(false, "audio.missing-authentication-fixture") }
            var invalid = try key.seal(Data([0xff]))
            if !opus { var payload = Data(); payload.put(UInt32(1)); payload.append(contentsOf: [0, 1]); payload.append(invalid); invalid = payload }
            let invalidPacket = Wire.Packet(kind: .audio, stream: 0, sequence: 1, payload: invalid)
            let invalidDecoder = StreamDecoder(format, jitterMs: 2, smoothness: 10)
            require(!invalidDecoder.accept(invalidPacket, credentials: key) && invalidDecoder.queuedFrames == 0, "audio.authenticated-malformed-codec-refused")
            let retired = session.finishIsolatedProductSession()
            require(retired && session.testPorts.audio == 0, "audio.actual-source-native-retirement")
            if retired {
                let rebound = try [ports.audio, ports.bridge, ports.discovery].filter { $0 > 0 }.map { try UDP(port: $0, loopback: true) }
                require(rebound.allSatisfy { $0.boundPort > 0 }, "audio.actual-owned-sockets-closed")
            } else { require(false, "audio.socket-retirement-unproved") }
        } catch { require(false, "audio.fixture-or-transport-error") }
        let retired = source?.finishIsolatedProductSession() ?? true
        require(retired, "audio.final-retirement")
        source = nil
        if retired, let root, root.deletingLastPathComponent().path == raw {
            do { try FileManager.default.removeItem(at: root); require(!FileManager.default.fileExists(atPath: root.path), "audio.fixture-cleanup") }
            catch { require(false, "audio.fixture-cleanup") }
        }
        return result()
    }
}
