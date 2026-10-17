import XCTest

@testable import RemSoundJam

/// The metronome through a server, on a stand-in clock with the server played by the test - the same rules the Windows
/// RemSound's step METRONOME SERVER RULES checks, plus asking, answering and handing over between two of these.
final class ServerMetronomeTests: XCTestCase {
    var now: Int64 = 80_000_000
    let edAt = JamEndpoint("240.1.1.1", 47830)
    let andreAt = JamEndpoint("240.2.2.2", 47830)
    let edId = UUID()
    let otherId = UUID()

    struct Rig {
        let engine: ServerMetronome
        var toServer: [(Int64, [UInt8])] = []
        var messages: [(MetronomeMessage, JamEndpoint)] = []
        var notices: [String] = []
    }

    func makeEngine(onServer: @escaping () -> Bool = { true }, peers: [(JamEndpoint, String)] = []) -> (ServerMetronome, Box) {
        let box = Box()
        let e = ServerMetronome(clock: { [unowned self] in now })
        e.onServerNow = onServer
        e.peers = { peers }
        e.toServer = { [unowned self] body in box.toServer.append((now, body)) }
        e.sendMessage = { m, to in box.messages.append((m, to)) }
        e.notice = { box.notices.append($0) }
        e.memberName = { [unowned self] id in id == otherId ? "Ed" : nil }
        return (e, box)
    }

    final class Box {
        var toServer: [(Int64, [UInt8])] = []
        var messages: [(MetronomeMessage, JamEndpoint)] = []
        var notices: [String] = []
        func count(_ kind: UInt8, since: Int64) -> Int { toServer.filter { $0.0 >= since && $0.1.first == kind }.count }
    }

    func run(_ seconds: Double, _ engines: [ServerMetronome], grids: [(ServerMetronome, () -> ServerGrid?)] = []) {
        let end = now + Int64(seconds * 1_000_000)
        var nextGrid = now
        while now < end {
            if now >= nextGrid {
                for (e, g) in grids { if let grid = g() { e.onGrid(grid) } }
                nextGrid += 1_000_000
            }
            for e in engines { e.tick() }
            now += 50_000
        }
    }

    func grid(youLead: Bool, master: UUID, measured: Bool = true, anchorUs: Int64, running: Bool = true, bpm: UInt32 = 120) -> ServerGrid {
        ServerGrid(running: running, measured: measured, youLead: youLead, master: master,
                   timeline: MetronomeTimeline(version: 2, running: running, milliBpm: bpm * 1000, beatsPerBar: 4, beatUnit: 4,
                                               anchorBeat: 0, anchorTimeUs: anchorUs))
    }

    func testLeadingClaimsTheServerAndPlaysOnlyItsGrid() {
        let (e, box) = makeEngine(peers: [(edAt, "Ed")])
        let t0 = now
        XCTAssertTrue(e.becomeMaster(name: "Andre"))
        XCTAssertEqual(box.count(ServerMetronomeWire.claim, since: t0), 1, "claimed at once")
        XCTAssertEqual(box.messages.first?.0.kind, .offer, "and everyone on the server is asked")
        XCTAssertEqual(box.messages.first?.1, edAt)
        XCTAssertTrue(e.describe().contains("waiting for the server"), e.describe())
        let started = now
        e.startStop()
        XCTAssertTrue(box.toServer.contains { $0.0 >= started && $0.1 == ServerMetronomeWire.buildSet(running: true, milliBpm: 120_000, beatsPerBar: 4, beatUnit: 4) },
                      "the start goes to the server as the setting")
        XCTAssertNil(e.schedule, "ONE BEAT FOR ALL: nothing clicks before the server's grid")
        let g = grid(youLead: true, master: UUID(), anchorUs: now + 400_000)
        e.onGrid(g)
        XCTAssertEqual(e.schedule?.current, g.timeline, "THE GRID: played as the server gave it, in this machine's clock")
        XCTAssertFalse(e.describe().contains("waiting"), e.describe())
        e.onGrid(ServerGrid(running: true, measured: false, youLead: true, master: g.master, timeline: g.timeline))
        XCTAssertNil(e.schedule, "NOT MEASURED: nothing until the server has timed this computer's sound")
        e.onGrid(g)
        now += 100_000
        let from = now
        run(3, [e], grids: [(e, { g })])
        let sets = box.count(ServerMetronomeWire.set, since: from)
        XCTAssertTrue((2...4).contains(sets), "REPEAT: the setting about once a second (\(sets))")
        XCTAssertEqual(box.count(ServerMetronomeWire.claim, since: from), 0, "and no more claims")
        let changed = now
        var s = e.settings
        s.bpm = 90
        e.configure(s)
        XCTAssertTrue(box.toServer.contains { $0.0 >= changed && $0.1 == ServerMetronomeWire.buildSet(running: true, milliBpm: 90_000, beatsPerBar: 4, beatUnit: 4) },
                      "TEMPO: a change goes at once")
        let released = now
        e.releaseMaster()
        XCTAssertEqual(box.count(ServerMetronomeWire.release, since: released), 1, "RELEASE")
        XCTAssertEqual(e.role, .solo)
    }

    func testNoServerNoMasterButYourOwnStillClicks() {
        let (e, _) = makeEngine(onServer: { false })
        XCTAssertFalse(e.becomeMaster(name: "Andre"), "being the master needs a server")
        XCTAssertEqual(e.role, .solo)
        e.startStop()
        XCTAssertEqual(e.schedule?.current.running, true, "your own clicks for you alone")
    }

    func testARefusedMasterGivesWayAndAnOlderServerIsWaitedFor() {
        let (e, box) = makeEngine()
        let g = grid(youLead: false, master: otherId, anchorUs: 0, running: false)
        let t0 = now
        e.becomeMaster(name: "Andre")
        run(5.5, [e], grids: [(e, { g })])
        let claims = box.count(ServerMetronomeWire.claim, since: t0)
        XCTAssertTrue(e.role == .master && (5...7).contains(claims), "keeps claiming about once a second (\(claims))")
        run(1.5, [e], grids: [(e, { g })])
        XCTAssertEqual(e.role, .solo, "GIVE WAY after six seconds")
        XCTAssertTrue(box.notices.contains("Ed leads the server's metronome"), "\(box.notices)")
        XCTAssertEqual(box.toServer.last?.1, ServerMetronomeWire.buildRelease())
        let (old, _) = makeEngine()
        old.becomeMaster(name: "Andre")
        run(8, [old])
        XCTAssertEqual(old.role, .master, "AN OLDER SERVER: nothing answers - the master stays and waits")
        XCTAssertTrue(old.describe().contains("waiting for the server"))
    }

    func testAskedFollowedTimedOutAndHandedOver() {
        // Two of these, their messages passed straight across (the relay passes them between members).
        let (andre, andreBox) = makeEngine(peers: [(edAt, "Ed")])
        let (ed, edBox) = makeEngine(peers: [(andreAt, "Andre")])
        var s = ed.settings
        s.whenAsked = .acceptAutomatically
        ed.configure(s)
        func deliver() {
            while !andreBox.messages.isEmpty || !edBox.messages.isEmpty {
                let a = andreBox.messages; andreBox.messages = []
                for (m, to) in a where to == edAt { ed.handle(m, from: andreAt) }
                let b = edBox.messages; edBox.messages = []
                for (m, to) in b where to == andreAt { andre.handle(m, from: edAt) }
            }
        }
        andre.becomeMaster(name: "Andre")
        deliver()
        XCTAssertEqual(ed.role, .follower, "set to accept, Ed follows")
        XCTAssertEqual(ed.masterName, "Andre")
        XCTAssertEqual(andre.followerCount, 1)
        XCTAssertTrue(andreBox.notices.contains("Ed is following your metronome"))
        // Ed plays his own grid; the server goes quiet for him: after 5 s he stops following, and says so.
        var edGrid: ServerGrid? = grid(youLead: false, master: UUID(), anchorUs: now + 400_000)
        run(2, [ed], grids: [(ed, { edGrid })])
        XCTAssertNotNil(ed.schedule)
        edGrid = nil
        run(3.5, [ed])
        XCTAssertEqual(ed.role, .follower, "under 5 s: still following")
        run(2, [ed])
        XCTAssertEqual(ed.role, .solo, "TIMEOUT")
        XCTAssertTrue(edBox.notices.contains { $0.contains("nothing heard from the server's metronome for 5 seconds") })
        deliver()
        // Ed asks to take over: Andre, leading, is asked - and says yes: he follows Ed, and Ed leads.
        var asked: String?
        andre.askAboutOffer = { name, leading, answer in
            asked = "\(name) \(leading)"
            answer(true)
        }
        ed.becomeMaster(name: "Ed")
        deliver()
        XCTAssertEqual(asked, "Ed true", "the leader is asked before handing over")
        XCTAssertEqual(andre.role, .follower)
        XCTAssertEqual(ed.role, .master)
        XCTAssertEqual(ed.followerCount, 1)
    }

    func testAFollowerCanMuteAndTheLeadersReleaseEndsIt() {
        let (andre, andreBox) = makeEngine(peers: [(edAt, "Ed")])
        let (ed, _) = makeEngine()
        var s = ed.settings
        s.whenAsked = .acceptAutomatically
        ed.configure(s)
        andre.becomeMaster(name: "Andre")
        for (m, _) in andreBox.messages { ed.handle(m, from: andreAt) }
        let g = grid(youLead: false, master: UUID(), anchorUs: now + 400_000)
        ed.onGrid(g)
        ed.startStop()
        XCTAssertEqual(ed.schedule?.audible, false, "muted")
        ed.startStop()
        XCTAssertEqual(ed.schedule?.audible, true)
        ed.handle(MetronomeMessage(.release, sessionId: andreBox.messages[0].0.sessionId), from: andreAt)
        XCTAssertEqual(ed.role, .solo, "the leader let go")
    }
}
