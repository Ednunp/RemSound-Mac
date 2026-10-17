import XCTest
@testable import RemSoundJam

/// Accept connections (Windows MainForm.AcceptConnections): who is offered, accepted or left, and how often asked.
final class AcceptConnectionsTests: XCTestCase {
    private func policy(_ mode: AcceptConnections) -> AcceptPolicy {
        var p = AcceptPolicy()
        p.mode = mode
        return p
    }

    func testTheDefaultIsToAskAndTheChoicesReadAsOnWindows() {
        XCTAssertEqual(AcceptPolicy().mode, .ask)
        XCTAssertEqual(AcceptConnections.allCases.map(\.title),
                       ["Ask me each time", "Automatically - connect when someone ticks me", "Manual - I tick them myself"])
    }

    func testAutomaticTicksBackSomeoneWhoTicksUsNamingThem() {
        var p = policy(.automatic)
        let outcome = p.considerPeer(address: "192.168.1.20", name: "Studio", how: "has ticked us and proved our password",
                                     isSelected: false, isServer: false, now: 10)
        XCTAssertEqual(outcome.action, .accept(description: "Studio at 192.168.1.20"))
        XCTAssertEqual(outcome.log, ["accept connections: Studio at 192.168.1.20 has ticked us and proved our password and is not ticked (mode=automatic)"])
    }

    func testAskAsksOnceARunAndANoIsRememberedLikeAYes() {
        var p = policy(.ask)
        let first = p.considerPeer(address: "10.0.0.5", name: nil, how: "is sending to us", isSelected: false, isServer: false, now: 1)
        XCTAssertEqual(first.action, .ask(key: "peer:10.0.0.5", question: "10.0.0.5 would like to connect to you.", description: "10.0.0.5"))
        XCTAssertTrue(p.beginQuestion("peer:10.0.0.5"))
        p.endQuestion()   // answered No
        XCTAssertEqual(p.considerPeer(address: "10.0.0.5", name: nil, how: "is sending to us", isSelected: false, isServer: false, now: 50).action,
                       .nothing, "asked once a run, whatever the answer")
    }

    func testManualNeverOffersAnybodyOrLooksAtTheirPackets() {
        var p = policy(.manual)
        XCTAssertFalse(p.mayLook("10.0.0.5", now: 1))
        XCTAssertEqual(p.considerPeer(address: "10.0.0.5", name: "Studio", how: "x", isSelected: false, isServer: false, now: 1).action, .nothing)
        XCTAssertEqual(p.considerMember(id: UUID(), name: "Andre", isSelected: false).action, .nothing)
    }

    func testAlreadyTickedPeopleAreLeftAlone() {
        var p = policy(.automatic)
        XCTAssertEqual(p.considerPeer(address: "10.0.0.5", name: "Studio", how: "x", isSelected: true, isServer: false, now: 1).action, .nothing)
        XCTAssertEqual(p.considerMember(id: UUID(), name: "Andre", isSelected: true).action, .nothing)
    }

    func testSomebodyThePersonUntickedIsNotPutStraightBack() {
        var p = policy(.automatic)
        p.userChose(AcceptPolicy.peerKey("10.0.0.5"), selected: false)
        XCTAssertEqual(p.considerPeer(address: "10.0.0.5", name: "Studio", how: "x", isSelected: false, isServer: false, now: 1).action, .nothing)
        p.userChose(AcceptPolicy.peerKey("10.0.0.5"), selected: true)   // ticked again by hand, then unticked by the other side
        XCTAssertEqual(p.considerPeer(address: "10.0.0.5", name: "Studio", how: "x", isSelected: false, isServer: false, now: 2).action,
                       .accept(description: "Studio at 10.0.0.5"))
    }

    func testAnotherPasswordIsNeverOfferedForTwoMinutesAndSaidOnce() {
        var p = policy(.automatic)
        XCTAssertEqual(p.noteDifferentPassword("10.0.0.5", now: 100).count, 1)
        XCTAssertEqual(p.noteDifferentPassword("10.0.0.5", now: 101), [], "said once")
        let refused = p.considerPeer(address: "10.0.0.5", name: nil, how: "is sending to us", isSelected: false, isServer: false, now: 150)
        XCTAssertEqual(refused.action, .nothing)
        XCTAssertEqual(refused.log.count, 1)
        XCTAssertEqual(p.considerPeer(address: "10.0.0.5", name: nil, how: "is sending to us", isSelected: false, isServer: false, now: 160).log, [])
        // Two minutes on, a person who changed their password is accepted.
        XCTAssertEqual(p.considerPeer(address: "10.0.0.5", name: nil, how: "is sending to us", isSelected: false, isServer: false,
                                      now: 100 + AcceptPolicy.differentPasswordMemory + 1).action, .accept(description: "10.0.0.5"))
    }

    func testAServerIsNeverAcceptedAsAPerson() {
        var p = policy(.automatic)
        let outcome = p.considerPeer(address: "203.0.113.9", name: nil, how: "is sending to us", isSelected: false, isServer: true, now: 1)
        XCTAssertEqual(outcome.action, .nothing)
        XCTAssertEqual(outcome.log, ["accept connections: 203.0.113.9 is sending to us, but it's a server - not accepted as a peer"])
    }

    func testServerMembersAreAskedOnceByWhoTheyAre() {
        var p = policy(.ask)
        let andre = UUID()
        XCTAssertEqual(p.considerMember(id: andre, name: "Andre", isSelected: false).action,
                       .ask(key: "member:\(andre.uuidString)", question: "Andre on the server would like to connect to you.", description: "Andre"))
        XCTAssertEqual(p.considerMember(id: andre, name: "Andre", isSelected: false).action, .nothing)
        XCTAssertEqual(p.considerMember(id: UUID(), name: "", isSelected: false).action.description, "ask Someone")
    }

    func testOneQuestionAtATimeAndAPutOffQuestionComesBack() {
        var p = policy(.ask)
        _ = p.considerPeer(address: "10.0.0.1", name: nil, how: "x", isSelected: false, isServer: false, now: 1)
        _ = p.considerPeer(address: "10.0.0.2", name: nil, how: "x", isSelected: false, isServer: false, now: 1)
        XCTAssertTrue(p.beginQuestion("peer:10.0.0.1"))
        XCTAssertFalse(p.beginQuestion("peer:10.0.0.2"), "the second waits")
        p.endQuestion()
        if case .ask = p.considerPeer(address: "10.0.0.2", name: nil, how: "x", isSelected: false, isServer: false, now: 5).action {} else {
            XCTFail("a question put off is asked next time round")
        }
    }

    func testAFloodOfPacketsIsLookedAtOnceEveryTwoSeconds() {
        var p = policy(.ask)
        XCTAssertTrue(p.mayLook("10.0.0.5", now: 10))
        XCTAssertFalse(p.mayLook("10.0.0.5", now: 11.9))
        XCTAssertTrue(p.mayLook("10.0.0.6", now: 11.9), "per address")
        XCTAssertTrue(p.mayLook("10.0.0.5", now: 12.1))
    }
}

private extension AcceptPolicy.Action {
    var description: String {
        switch self {
        case .nothing: return "nothing"
        case .accept(let d): return "accept \(d)"
        case .ask(_, _, let d): return "ask \(d)"
        }
    }
}
