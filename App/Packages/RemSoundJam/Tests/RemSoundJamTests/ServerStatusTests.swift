import XCTest
@testable import RemSoundJam

final class ServerStatusTests: XCTestCase {
    private let address = JamEndpoint("203.0.113.90")
    private func info(gap: UInt32 = 12400, long: UInt16 = 0, packets: UInt32 = 4000) -> RelayGroupClient.ServerInfo {
        let version = Array("server-v2.16".utf8)
        var b: [UInt8] = [1, UInt8(version.count)] + version
        b.appendLE(UInt32(172800)); b.appendLE(UInt16(5)); b.appendLE(UInt16(3))
        b.appendLE(UInt16(59)); b.appendLE(UInt16(1)); b.appendLE(packets)
        b.appendLE(gap); b.appendLE(long); b.appendLE(UInt16(60))
        return RelayGroupClient.readServerInfo(b, receivedAt: 0)!
    }
    private func facts() -> ServerStatus.Facts {
        .init(entry: "remote.example.test", address: address, connectedFor: 720, roundTripMs: 34.4,
              info: info(), olderServer: false, sending: true,
              group: [.init(name: "Andre", ticksUs: true), .init(name: "MERJILLE", ticksUs: false)], phonePaired: true)
    }
    func testSevenLinesMatchWindowsInOrder() {
        XCTAssertEqual(ServerStatus.text(facts()).components(separatedBy: "\n"), [
            "On remote.example.test (203.0.113.90), connected for 12 minutes.",
            "Your round trip to the server: 34 ms.",
            "Your sound reaches the server steadily: longest gap 12 ms in the last minute.",
            "In your group: Andre and MERJILLE. Andre has ticked you; MERJILLE hasn't yet.",
            "On the server: 5 people in 3 groups, 59 places free.",
            "Server version server-v2.16.",
            "A phone or older app is paired with you here."])
    }
    func testOlderServerAndNoNamesFromOtherGroups() {
        let f = ServerStatus.Facts(entry: "203.0.113.90", address: address, connectedFor: 30,
                                  olderServer: true, sending: true, group: [], phonePaired: false)
        XCTAssertEqual(ServerStatus.text(f), "On 203.0.113.90, connected for less than a minute.\nNobody else from your group is on the server yet.\nThis server doesn't report its size, version or your round trip (it's older than server-v2.16).")
    }
    func testSendingStatesAndAudioStatisticsAreTruthful() {
        var f = facts(); f.sendOn = false
        XCTAssertTrue(ServerStatus.text(f).contains("Send my audio is off, so none of your sound goes to the server."))
        f.sendOn = true; f.sending = false
        XCTAssertTrue(ServerStatus.text(f).contains("once you tick somebody there, or unmute yourself"))
        f.sending = true; f.info = nil
        XCTAssertTrue(ServerStatus.text(f).contains("How steadily your sound reaches the server: measuring."))
        f.info = info(packets: 0)
        XCTAssertTrue(ServerStatus.text(f).contains("None of your sound has reached the server in the last minute."))
        f.info = info(gap: 85000, long: 1)
        XCTAssertTrue(ServerStatus.text(f).contains("longest gap 85 ms, and 1 gap over 20 ms"))
        f.info = info(gap: 85000, long: 14)
        XCTAssertTrue(ServerStatus.text(f).contains("and 14 gaps over 20 ms"))
    }
    func testGroupNamesAndMutualTicksHaveCorrectGrammar() {
        var f = facts(); f.group = [.init(name: " ", ticksUs: false)]
        XCTAssertTrue(ServerStatus.text(f).contains("In your group: someone not yet named, who hasn't ticked you yet."))
        f.group = [.init(name: "A", ticksUs: true)]
        XCTAssertTrue(ServerStatus.text(f).contains("In your group: A, who has ticked you."))
        f.group = [.init(name: "A", ticksUs: true), .init(name: "B", ticksUs: true)]
        XCTAssertTrue(ServerStatus.text(f).contains("All of them have ticked you."))
        f.group = [.init(name: "A", ticksUs: false), .init(name: "B", ticksUs: false)]
        XCTAssertTrue(ServerStatus.text(f).contains("None of them has ticked you yet."))
    }
    func testDurationAndCustomPortEntryRemainReadable() {
        for (seconds, text) in [(0.0,"less than a minute"),(60,"1 minute"),(3599,"59 minutes"),(3600,"1 hour"),(3900,"1 hour 5 minutes"),(86400,"1 day"),(183600,"2 days 3 hours")] {
            var f = facts(); f.connectedFor = seconds
            XCTAssertTrue(ServerStatus.text(f).contains("connected for \(text)."))
        }
        var f = facts(); f.entry = "example.test:49145"
        XCTAssertTrue(ServerStatus.text(f).hasPrefix("On example.test:49145 (203.0.113.90)"))
    }
    func testRoundTripSmoothingUsesTwoMsOrTenPercentInclusive() {
        var state = ServerStatus.State(), f = facts(); f.roundTripMs = 10
        XCTAssertTrue(state.render(f).contains("server: 10 ms."))
        f.roundTripMs = 11.99; XCTAssertTrue(state.render(f).contains("server: 10 ms."))
        f.roundTripMs = 12; XCTAssertTrue(state.render(f).contains("server: 12 ms."))
        f.roundTripMs = 100; _ = state.render(f)
        f.roundTripMs = 109.99; XCTAssertTrue(state.render(f).contains("server: 100 ms."))
        f.roundTripMs = 110; XCTAssertTrue(state.render(f).contains("server: 110 ms."))
        f.roundTripMs = nil; XCTAssertTrue(state.render(f).contains("server: measuring."))
        state.reset(); f.roundTripMs = 109; XCTAssertTrue(state.render(f).contains("server: 109 ms."))
    }
    func testGapSmoothingChangesAtThreeMsOrSteadinessTransition() {
        var state = ServerStatus.State(), f = facts(); _ = state.render(f)
        f.info = info(gap: 15399); XCTAssertTrue(state.render(f).contains("longest gap 12 ms"))
        f.info = info(gap: 15400); XCTAssertTrue(state.render(f).contains("longest gap 15 ms"))
        f.info = info(gap: 15500, long: 1); XCTAssertTrue(state.render(f).contains("unevenly: longest gap 16 ms, and 1 gap"))
        f.info = info(gap: 15600, long: 4); XCTAssertTrue(state.render(f).contains("and 1 gap"))
        f.info = info(gap: 15600, long: 0); XCTAssertTrue(state.render(f).contains("steadily: longest gap 16 ms"))
    }
    func testOlderDecisionRequiresEightSecondsWithNeitherMeasurement() {
        XCTAssertFalse(ServerStatus.isOlder(info: nil, roundTripMs: nil, inGroupSince: 10, now: 17.999))
        XCTAssertTrue(ServerStatus.isOlder(info: nil, roundTripMs: nil, inGroupSince: 10, now: 18))
        XCTAssertFalse(ServerStatus.isOlder(info: info(), roundTripMs: nil, inGroupSince: 10, now: 100))
        XCTAssertFalse(ServerStatus.isOlder(info: nil, roundTripMs: 0, inGroupSince: 10, now: 100))
        XCTAssertFalse(ServerStatus.isOlder(info: nil, roundTripMs: nil, inGroupSince: nil, now: 100))
        XCTAssertTrue(ServerStatus.isOlder(info: nil, roundTripMs: nil, inGroupSince: nil, now: 0, knownOlder: true))
    }
    func testMinuteLogHasImmediateFirstLineBoundedRefreshAndReset() {
        var state = ServerStatus.State()
        XCTAssertEqual(state.takeLog("one\ntwo", now: 10), "one | two")
        XCTAssertNil(state.takeLog("changed", now: 69.99))
        XCTAssertEqual(state.takeLog("changed", now: 70), "changed")
        XCTAssertNil(state.takeLog(nil, now: 71))
        XCTAssertEqual(state.takeLog("new visit", now: 72), "new visit")
    }
    func testFocusedShapeIgnoresFiguresButNotKindsOrPeerNames() {
        XCTAssertEqual(ServerStatus.shape("server: 21 ms."), ServerStatus.shape("server: 230 ms."))
        XCTAssertNotEqual(ServerStatus.shape("server: measuring."), ServerStatus.shape("server: 21 ms."))
        XCTAssertNotEqual(ServerStatus.shape("A has ticked you."), ServerStatus.shape("B has ticked you."))
    }
    func testRemoteControlCharactersCannotCreateAnotherStatusLine() {
        for name in ["A\nOn another server", "A\u{2028}On another server"] {
            var f = facts(); f.group = [.init(name: name, ticksUs: true)]
            let text = ServerStatus.text(f)
            XCTAssertTrue(text.contains("In your group: A On another server"))
            XCTAssertEqual(text.components(separatedBy: "\n").filter { $0.hasPrefix("On ") }.count, 2)
        }
    }
}
