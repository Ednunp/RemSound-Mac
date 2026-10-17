import Foundation
import XCTest
import RemSoundJam
@testable import RemSoundCore

final class AudioPathMeasurementTests: XCTestCase {
    private struct Measurement {
        let captureReturn: Double, receiveQueue: Double, outputQueue: Double, total: Double
        init?(_ text: String) {
            let pattern = "back from server ([0-9.]+) milliseconds; receive queue ([0-9.]+) milliseconds, Mac output queue ([0-9.]+) milliseconds, output hardware [0-9.]+ milliseconds; estimated total ([0-9.]+) milliseconds"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            let values = (1...4).compactMap { index -> Double? in
                guard let range = Range(match.range(at: index), in: text) else { return nil }
                return Double(text[range])
            }
            guard values.count == 4 else { return nil }
            captureReturn = values[0]; receiveQueue = values[1]; outputQueue = values[2]; total = values[3]
        }
    }

    // A real relay, with a transparent loopback proxy. Only returning audio is delayed;
    // credentials, framing, capture pacing, decoder and mixing all remain the normal path.
    private final class Fixture {
        let folder: URL, relay: Process, proxy: UDP, session: Session
        private let upstream: Endpoint
        private var client: Endpoint?
        private var pending: [(data: Data, received: TimeInterval, due: TimeInterval)] = []
        var returnDelay = 0.0
        var observedDelays: [Double] = []
        var sentFrames = 0
        var formats: [UInt16: StreamFormat] = [:]
        var audioStreams = Set<UInt16>()
        var connected = false, enabled = false
        var measurements: [Measurement] = []
        var audibleSamples = 0
        private var previousStatus = ""

        init(pushDriven: Bool = false) throws {
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Packages/RemSoundJam/Tests/relay/remsound-relay.py")
            var reservation: UDP? = try UDP(port: 0, loopback: true)
            upstream = Endpoint("127.0.0.1", reservation!.boundPort)
            reservation = nil
            proxy = try UDP(port: 0, loopback: true)
            session = Session(testPeerPort: proxy.boundPort, testCapturePushDriven: pushDriven)
            let testRoot = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
            folder = testRoot.appendingPathComponent("audio-path-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            relay = Process()
            relay.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            relay.arguments = ["python3", script.path, "--host", "127.0.0.1", "--port", String(upstream.port),
                               "--log-path", folder.appendingPathComponent("relay.log").path]
            relay.standardOutput = FileHandle.nullDevice; relay.standardError = FileHandle.nullDevice
            do { try relay.run() } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
            session.onJamChange = { [weak self] view in
                guard let self else { return }
                connected = view.connected; enabled = view.selfMonitoring
                if previousStatus != view.selfMonitoringStatus, let measurement = Measurement(view.selfMonitoringStatus) {
                    measurements.append(measurement)
                }
                previousStatus = view.selfMonitoringStatus
            }
        }
        func close() {
            session.shutdown()
            if relay.isRunning { relay.terminate(); relay.waitUntilExit() }
            try? FileManager.default.removeItem(at: folder)
        }
        func pump() {
            for _ in 0..<256 {
                guard let (data, from) = proxy.receive() else { break }
                let groupAudio = data.count >= JamWire.groupHeaderSize && JamWire.hasHeader([UInt8](data))
                    && data[4] == JamWire.groupVersion && data[5] == JamWire.Kind.audio.rawValue
                if from == upstream {
                    if groupAudio {
                        let now = ProcessInfo.processInfo.systemUptime
                        pending.append((data, now, now + returnDelay))
                    } else if let client { proxy.send(data, to: client) }
                } else {
                    client = from
                    if data.count >= JamWire.groupHeaderSize, data[4] == JamWire.groupVersion {
                        let stream = data.u16(6)
                        if data[5] == JamWire.Kind.format.rawValue,
                           let format = StreamFormat.parse(Data(data.dropFirst(JamWire.groupHeaderSize))) {
                            formats[stream] = format
                        }
                        if groupAudio, let format = formats[stream] {
                            audioStreams.insert(stream)
                            if format.codec != StreamFormat.Codec.pcm.rawValue
                                || (data.count >= JamWire.groupHeaderSize + 6 && data[JamWire.groupHeaderSize + 4] == 0) {
                                sentFrames += format.frames
                            }
                        }
                    }
                    proxy.send(data, to: upstream)
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            if let client {
                while let first = pending.first, first.due <= now {
                    proxy.send(first.data, to: client)
                    observedDelays.append((now - first.received) * 1000)
                    if observedDelays.count > 512 { observedDelays.removeFirst() }
                    pending.removeFirst()
                }
            }
        }
        func until(_ seconds: Double, _ done: () -> Bool) -> Bool {
            let end = ProcessInfo.processInfo.systemUptime + seconds
            while ProcessInfo.processInfo.systemUptime < end {
                pump()
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
                if done() { return true }
            }
            return done()
        }
        func start(codec: SendCodec = .pcm, customFrames: Bool = false) {
            XCTAssertTrue(until(4) {
                let log = (try? String(contentsOf: folder.appendingPathComponent("relay.log"))) ?? ""
                return log.contains("event=startup") && !log.contains("event=bind_failed")
            })
            session.setJamulusStyle(customFrames)
            session.start(password: "isolated audio path", peerAddress: "", send: true, receive: true,
                          plugins: false, name: "Synthetic", sendCodec: codec, receiveJitterMs: 10,
                          serverAddress: "127.0.0.1:\(proxy.boundPort)")
            XCTAssertTrue(until(4) { connected })
            session.setSelfMonitoring(true)
            XCTAssertTrue(until(1) { enabled })
            // The hardware-free output has no consumer during connection startup.
            // Clear that initial silence before simulating a paced output callback.
            _ = session.testPlayback(Wire.sampleRate)
        }
        @discardableResult
        func feed(seconds: Double, framesPerSecond: Int = Wire.sampleRate, drainOutput: Bool = true) -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            var produced = 0, drained = 0
            _ = until(seconds) {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let wanted = Int(elapsed / 0.005) * (framesPerSecond / 200)
                if wanted > produced {
                    var samples: [Float] = []
                    for _ in produced..<wanted { samples.append(0.25); samples.append(-0.25) }
                    session.testCapture(samples)
                    produced = wanted
                }
                if drainOutput {
                    let wantedDrain = Int(elapsed / 0.005) * 240
                    if wantedDrain > drained {
                        let block = session.testPlayback(wantedDrain - drained)
                        audibleSamples += block.filter { abs($0) > 0.1 }.count
                        drained = wantedDrain
                    }
                }
                return false
            }
            return ProcessInfo.processInfo.systemUptime - start
        }
        func latest(after seconds: Double, drainOutput: Bool = true) throws -> Measurement {
            measurements.removeAll()
            feed(seconds: seconds, drainOutput: drainOutput)
            return try XCTUnwrap(measurements.last, "Real authenticated returns must publish their timing")
        }
    }

    func testRealCaptureReturnSeparatesNetworkReceiveAndOutputQueues() throws {
        // Queue attribution is independent of clock acquisition, whose ten-second window can reject wall-clock stalls.
        let wasKeepingInTime = ClockKeeping.on
        ClockKeeping.on = false
        defer { ClockKeeping.on = wasKeepingInTime }
        let fixture = try Fixture(); defer { fixture.close() }
        fixture.start()
        let baseline = try fixture.latest(after: 2.2)
        XCTAssertGreaterThan(fixture.audibleSamples, 1_000, "The synthetic input must survive real encryption, relay and playback")
        fixture.returnDelay = 0.020; fixture.observedDelays.removeAll()
        let delayed = try fixture.latest(after: 2.2)
        let deliveredDelay = try XCTUnwrap(fixture.observedDelays.sorted().dropFirst(fixture.observedDelays.count / 2).first)
        XCTAssertEqual(deliveredDelay, 20, accuracy: 5, "Measure the proxy's actual delay, not only its requested delay")
        XCTAssertEqual(delayed.captureReturn - baseline.captureReturn, deliveredDelay, accuracy: 8)
        fixture.session.setReceiveJitterMs(80)
        let buffered = try fixture.latest(after: 2.2)
        XCTAssertGreaterThan(buffered.receiveQueue - delayed.receiveQueue, 40)
        XCTAssertEqual(buffered.captureReturn, delayed.captureReturn, accuracy: 8,
                       "Changing the receive queue must not masquerade as network delay")
        let outputHeld = try fixture.latest(after: 2.2, drainOutput: false)
        XCTAssertGreaterThan(outputHeld.outputQueue - buffered.outputQueue, 50)
        XCTAssertGreaterThanOrEqual(outputHeld.outputQueue, 90, "the paused output reaches its capacity")
        XCTAssertLessThanOrEqual(outputHeld.outputQueue, Double(OutputClock.maximumQueueFrames) / 48,
                                 "the physical output stage cannot hold more than 100 ms")
        XCTAssertEqual(outputHeld.captureReturn, buffered.captureReturn, accuracy: 8)
        XCTAssertEqual(outputHeld.total - buffered.total,
                       outputHeld.outputQueue - buffered.outputQueue + outputHeld.receiveQueue - buffered.receiveQueue,
                       accuracy: 8)
        print("REAL-PATH delay: baseline=\(baseline.captureReturn)ms, delayed=\(delayed.captureReturn)ms, proxy=\(deliveredDelay)ms; receive=\(delayed.receiveQueue)->\(buffered.receiveQueue)ms; output=\(buffered.outputQueue)->\(outputHeld.outputQueue)ms")
    }

    func testActualCaptureCountersExposeExcessRateWhileWireStaysPaced() throws {
        for rate in [48_000, 72_000] {
            let fixture = try Fixture(); defer { fixture.close() }
            XCTAssertNil(fixture.session.testCaptureObservation(), "An unstarted isolated session has no capture source")
            fixture.start()
            fixture.feed(seconds: 0.3, framesPerSecond: rate)
            let before = try XCTUnwrap(fixture.session.testCaptureObservation())
            var meter = CaptureRateMeter()
            let start = ProcessInfo.processInfo.systemUptime
            _ = meter.take(before.counters, now: start)
            let sentBefore = fixture.sentFrames
            fixture.feed(seconds: rate == 72_000 ? 12.2 : 3.2, framesPerSecond: rate)
            let end = ProcessInfo.processInfo.systemUptime
            let after = try XCTUnwrap(fixture.session.testCaptureObservation())
            let measured = try XCTUnwrap(meter.take(after.counters, now: end).first)
            let wireRate = Double(fixture.sentFrames - sentBefore) / (end - start)
            XCTAssertEqual(measured.framesPerSecond, Double(rate), accuracy: 1_000)
            XCTAssertEqual(wireRate, 48_000, accuracy: 2_500, "Capture excess must not produce 72kHz worth of 48kHz wire frames")
            XCTAssertGreaterThan(fixture.audibleSamples, 1_000)
            if rate == 72_000 {
                XCTAssertGreaterThan(after.trimmedFrames, before.trimmedFrames)
                XCTAssertGreaterThan(try XCTUnwrap(after.counters.first).queuedFrames, 1_000)
                XCTAssertLessThan(try XCTUnwrap(after.counters.first).queuedFrames, Wire.sampleRate / 3)
                let drift = try XCTUnwrap(after.drift.first)
                XCTAssertGreaterThan(drift.rejectedWindows, 0, "A fifty-percent excess must be rejected as an implausible hardware clock")
                XCTAssertNil(drift.ppm)
            } else { XCTAssertEqual(after.trimmedFrames, before.trimmedFrames) }
            print("REAL-PATH rate: injected=\(rate), captured=\(measured.framesPerSecond), wire=\(wireRate), depth=\(after.counters.first!.queuedFrames), trimmed=\(after.trimmedFrames)")
        }
    }

    func testRealOpusAndCustomFramesReportTheMeasuredReturnDelay() throws {
        for custom in [false, true] {
            let fixture = try Fixture(); defer { fixture.close() }
            fixture.start(codec: .opusLive, customFrames: custom)
            let baseline = try fixture.latest(after: 2.2)
            let expectedCodec = custom ? StreamFormat.Codec.opusCustom : .opus
            let expectedFrames = custom ? JamulusStyle.frames : SendCodec.opusLive.frames
            XCTAssertTrue(fixture.audioStreams.contains { stream in
                guard let format = fixture.formats[stream] else { return false }
                return format.codec == expectedCodec.rawValue && format.frames == expectedFrames
            }, "Verify the actual advertised format, not merely the requested codec")
            XCTAssertGreaterThan(fixture.audibleSamples, 1_000)
            fixture.returnDelay = 0.020; fixture.observedDelays.removeAll()
            let delayed = try fixture.latest(after: 2.2)
            let actual = try XCTUnwrap(fixture.observedDelays.sorted().dropFirst(fixture.observedDelays.count / 2).first)
            XCTAssertEqual(actual, 20, accuracy: 5)
            XCTAssertEqual(delayed.captureReturn - baseline.captureReturn, actual, accuracy: 8)
            print("REAL-PATH codec: codec=\(expectedCodec.rawValue), frames=\(expectedFrames), baseline=\(baseline.captureReturn)ms, delayed=\(delayed.captureReturn)ms, measured proxy=\(actual)ms")
        }
    }
}
