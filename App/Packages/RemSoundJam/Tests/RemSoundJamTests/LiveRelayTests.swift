import Foundation
import XCTest

@testable import RemSoundJam

/// THE REAL SERVER: the relay itself (Ed's server/remsound-relay.py, the one his Pi runs), started here on a spare port on
/// this machine, and two stand-in Macs on real sockets, each sending sound as the app does. They join its group, tick
/// each other, one asks to lead and the other (set to accept) follows; the server's metronome is claimed and started;
/// each gets its own measured beat grid from the server - and, on one machine with one clock and one path, the two beats
/// fall together. Then the other takes over, asked and answered.
///
/// Needs Python 3 and the relay script: set REMSOUND_RELAY_PY to its path (and REMSOUND_PYTHON to the Python to use, if
/// not `python3`). Skipped without them. Never uses the real ports.
final class LiveRelayTests: XCTestCase {
    /// A stand-in Mac: the app's own pieces (the server connection, the metronome, the capture report ring) on a socket.
    final class StandIn {
        let name: String
        let socket = TestUDP()
        let group: RelayGroupClient
        let metronome = ServerMetronome()
        var reports = CaptureReportRing()
        var sequence: UInt32 = 0
        let stream: UInt16
        var nextReport: Int64 = 0
        var log: [String] = []

        init(_ name: String, fingerprint: [UInt8], relay: JamEndpoint) {
            self.name = name
            stream = UInt16.random(in: 1...60000)
            group = RelayGroupClient(clientId: UUID())
            group.send = { [socket] bytes, to in socket.send(bytes, to: to) }
            group.log = { [unowned self] in log.append("group: \($0)") }
            group.setIdentity(name: name, fingerprint: fingerprint)
            group.timingReceived = { [unowned self] body, _ in
                if let g = ServerMetronomeWire.readGrid(body) { metronome.onGrid(g) }
            }
            metronome.onServerNow = { [unowned self] in group.connectedRelay.map(group.isInGroup) ?? false }
            metronome.toServer = { [unowned self] body in group.sendTiming(body) }
            metronome.peers = { [unowned self] in group.members.map { ($0.address, $0.name) } }
            metronome.memberName = { [unowned self] id in group.members.first { $0.id == id }?.name }
            // The Mac seals these with the password; the relay never looks inside, so the test sends the plaintext.
            metronome.sendMessage = { [unowned self] m, to in
                _ = group.route(JamWire.header(JamWire.Kind.metronome.rawValue, stream: MetronomeMessage.streamId) + m.plaintext(), to: to)
            }
            metronome.log = { [unowned self] in log.append($0) }
            group.connect(relay)
        }

        /// One turn of the app's loop: the socket, the clocks, a packet of sound, and the once-a-second report.
        func pump() {
            let now = Double(MetronomeClock.nowUs()) / 1_000_000
            while let (packet, from) = socket.receive() {
                if JamWire.isAddressCheck(packet) { socket.send(packet, to: from); continue }   // the relay's address check
                switch group.handleInbound(packet, from: from, now: now) {
                case let .delivered(inner, member):
                    if inner[5] == JamWire.Kind.metronome.rawValue, let m = MetronomeMessage.parse(Array(inner[JamWire.headerSize...])) {
                        metronome.handle(m, from: member)
                    }
                default: break
                }
            }
            group.tick(now: now)
            metronome.tick()
            // Sound: one 2.5 ms packet to everyone ticked, noted with when it was captured.
            let targets = group.sendTargets(for: group.members.map(\.address))
            if !targets.isEmpty {
                sequence &+= 1
                let packet = JamWire.header(JamWire.Kind.audio.rawValue, stream: stream, sequence: sequence) + [UInt8](repeating: 0, count: 64)
                reports.note(CaptureReport(stream: stream, sequence: sequence, capturedUs: MetronomeClock.nowUs()))
                for t in targets { _ = group.route(packet, to: t) }
            }
            let nowUs = MetronomeClock.nowUs()
            if nowUs >= nextReport {
                nextReport = nowUs + 1_000_000
                let taken = reports.take()
                if !taken.isEmpty { group.sendTiming(ServerMetronomeWire.buildReport(taken)) }
            }
        }
    }

    func testTwoMacsThroughTheRealServer() throws {
        // The relay: REMSOUND_RELAY_PY, or the copy of Ed's kept beside these tests (Tests/relay/remsound-relay.py).
        let bundled = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("relay").appendingPathComponent("remsound-relay.py").path
        let script = ProcessInfo.processInfo.environment["REMSOUND_RELAY_PY"] ?? bundled
        guard FileManager.default.fileExists(atPath: script) else {
            throw XCTSkip("no relay script at \(script): set REMSOUND_RELAY_PY to Ed's server/remsound-relay.py")
        }
        // Python 3: REMSOUND_PYTHON (a full path), or python3 found through /usr/bin/env on a Mac.
        let python = ProcessInfo.processInfo.environment["REMSOUND_PYTHON"] ?? "/usr/bin/env"
        let pythonArguments = ProcessInfo.processInfo.environment["REMSOUND_PYTHON"] == nil ? ["python3"] : []
        let probe = TestUDP()
        let port = probe.port
        probe.close()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remsound-jam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logPath = dir.appendingPathComponent("relay.log").path
        let relayProcess = Process()
        relayProcess.executableURL = URL(fileURLWithPath: python)
        relayProcess.arguments = pythonArguments + [script, "--host", "127.0.0.1", "--port", "\(port)", "--log-path", logPath, "--max-per-ip", "16"]
        relayProcess.standardOutput = FileHandle.nullDevice
        relayProcess.standardError = FileHandle.nullDevice
        try relayProcess.run()
        defer {
            relayProcess.terminate()
            try? FileManager.default.removeItem(at: dir)
        }
        func relayLog() -> String { (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "" }
        func wait(_ seconds: Double, _ everyone: [StandIn], until done: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                for s in everyone { s.pump() }
                if done() { return true }
                Thread.sleep(forTimeInterval: 0.002)
            }
            return done()
        }
        XCTAssertTrue(wait(10, []) { relayLog().contains("event=startup") }, "the relay must start (\(python) \(script))")

        let relay = JamEndpoint("127.0.0.1", port)
        let fingerprint: [UInt8] = (0..<8).map { _ in UInt8.random(in: 0...255) }
        let ed = StandIn("Ed", fingerprint: fingerprint, relay: relay)
        let andre = StandIn("Andre", fingerprint: fingerprint, relay: relay)
        let both = [ed, andre]
        defer { for s in both { s.group.disconnect(); s.socket.close() } }
        XCTAssertTrue(wait(10, both) { ed.group.members.count == 1 && andre.group.members.count == 1 },
                      "both must join the group and see each other (Ed: \(ed.log.suffix(3)); Andre: \(andre.log.suffix(3)))")
        XCTAssertEqual(ed.group.members.first?.name, "Andre")
        ed.group.setTicked([ed.group.members[0].id])
        andre.group.setTicked([andre.group.members[0].id])
        XCTAssertTrue(wait(5, both) { ed.group.members[0].ticksUs && andre.group.members[0].ticksUs }, "each must tick the other")

        var s = andre.metronome.settings
        s.whenAsked = .acceptAutomatically
        andre.metronome.configure(s)
        XCTAssertTrue(ed.metronome.becomeMaster(name: "Ed"))
        XCTAssertTrue(wait(8, both) { andre.metronome.role == .follower }, "asked through the server, Andre follows (\(ed.log.suffix(4)))")
        ed.metronome.startStop()
        XCTAssertTrue(wait(15, both) {
            ed.metronome.serverGridNow.map { $0.running && $0.measured && $0.youLead } == true
                && andre.metronome.serverGridNow.map { $0.running && $0.measured && !$0.youLead } == true
        }, "THE GRIDS: each its own, measured from its own sound (Ed: \(ed.log.suffix(3)); Andre: \(andre.log.suffix(3)))")
        let gridEd = ed.metronome.serverGridNow!.timeline
        let gridAndre = andre.metronome.serverGridNow!.timeline
        XCTAssertEqual(gridEd.milliBpm, 120_000)
        let beat = gridEd.beatAtOrAfter(Double(MetronomeClock.nowUs() + 1_000_000))
        let apartMs = abs(gridEd.beatTimeUs(beat) - gridAndre.beatTimeUs(beat)) / 1000
        XCTAssertLessThan(apartMs, 3, "ONE MACHINE: one clock and one path, so the two beats fall together (\(apartMs) ms)")
        XCTAssertNotNil(ed.metronome.schedule)
        XCTAssertNotNil(andre.metronome.schedule)

        // Andre asks to take over: Ed, leading, is asked and says yes.
        var asked = false
        ed.metronome.askAboutOffer = { _, leading, answer in
            asked = leading
            answer(true)
        }
        andre.metronome.becomeMaster(name: "Andre")
        XCTAssertTrue(wait(10, both) { andre.metronome.serverGridNow?.youLead == true && ed.metronome.role == .follower },
                      "TAKE OVER: the server's metronome passes to Andre, Ed following (\(andre.log.suffix(4)))")
        XCTAssertTrue(asked, "Ed, leading, was asked")
        XCTAssertTrue(relayLog().contains("event=metronome_master"), "and the server's log says who leads it")
    }
}
