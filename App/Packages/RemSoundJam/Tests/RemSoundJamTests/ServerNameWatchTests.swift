import XCTest
@testable import RemSoundJam

/// A server by name (Windows MainForm.NameLookups): the profile's server tried again until found, and a moved one followed.
final class ServerNameWatchTests: XCTestCase {
    func testAnAddressCannotMoveButANameCan() {
        XCTAssertTrue(ServerNameWatch.isAddress("192.0.2.10"))
        XCTAssertTrue(ServerNameWatch.isAddress("192.0.2.10:47830"))
        XCTAssertFalse(ServerNameWatch.isAddress("server.example.com"))
        XCTAssertFalse(ServerNameWatch.isAddress("server.example.com:47830"))
        XCTAssertFalse(ServerNameWatch.isAddress("300.1.1.1"))
    }

    func testTheProfilesServerIsTriedAgainEveryThirtySecondsAndSaidOnce() {
        var w = ServerNameWatch()
        XCTAssertEqual(w.notFound("server.example.com", userAsked: false, now: 100),
                       ["could not resolve \"server.example.com\" - trying again every 30 s and when the network changes"])
        XCTAssertNil(w.retryDue(now: 129, networkChanged: false, connected: false))
        XCTAssertEqual(w.retryDue(now: 130, networkChanged: false, connected: false), "server.example.com")
        XCTAssertEqual(w.notFound("server.example.com", userAsked: false, now: 130), [], "said once")
        XCTAssertNil(w.retryDue(now: 140, networkChanged: false, connected: false))
        XCTAssertEqual(w.retryDue(now: 141, networkChanged: true, connected: false), "server.example.com",
                       "a network change tries at once")
    }

    func testAServerThePersonTypedIsNotKeptWhenItCannotBeFound() {
        var w = ServerNameWatch()
        XCTAssertEqual(w.notFound("typo.example.com", userAsked: true, now: 1), ["could not resolve \"typo.example.com\""])
        XCTAssertNil(w.pending)
        XCTAssertNil(w.retryDue(now: 1000, networkChanged: true, connected: false))
    }

    func testChoosingAnotherServerEndsTheWaitAndFindingItSaysSo() {
        var w = ServerNameWatch()
        _ = w.notFound("server.example.com", userAsked: false, now: 1)
        XCTAssertEqual(w.found("server.example.com"), ["\"server.example.com\" found at last"])
        XCTAssertNil(w.pending)
        _ = w.notFound("server.example.com", userAsked: false, now: 1)
        w.userChose()
        XCTAssertNil(w.retryDue(now: 1000, networkChanged: true, connected: false))
    }

    func testSavingWhileWaitingKeepsConnectAtStart() {
        var w = ServerNameWatch()
        XCTAssertFalse(w.connectOnStart(server: "server.example.com", connected: false))
        _ = w.notFound("server.example.com", userAsked: false, now: 1)
        XCTAssertTrue(w.connectOnStart(server: "Server.Example.com", connected: false))
        XCTAssertFalse(w.connectOnStart(server: "", connected: true))
        XCTAssertTrue(w.connectOnStart(server: "192.0.2.10", connected: true))
    }

    func testASilentServerByNameIsLookedUpAgainAfterThirtySecondsAndFollowed() {
        var w = ServerNameWatch()
        w.noteAnswering(false, now: 10)
        XCTAssertFalse(w.recheckDue(entry: "server.example.com", connected: true, now: 39, networkChanged: false))
        XCTAssertTrue(w.recheckDue(entry: "server.example.com", connected: true, now: 40, networkChanged: false))
        XCTAssertFalse(w.recheckDue(entry: "server.example.com", connected: true, now: 41, networkChanged: true),
                       "one look-up at a time")
        XCTAssertEqual(w.recheckFinished(entry: "server.example.com", current: "192.0.2.10", found: "198.51.100.7"),
                       "\"server.example.com\" now looks up to 198.51.100.7, not 192.0.2.10 - it has moved; following it")
        XCTAssertFalse(w.recheckDue(entry: "server.example.com", connected: true, now: 50, networkChanged: false),
                       "not again for thirty seconds")
        XCTAssertTrue(w.recheckDue(entry: "server.example.com", connected: true, now: 70, networkChanged: false))
        XCTAssertNil(w.recheckFinished(entry: "server.example.com", current: "198.51.100.7", found: "198.51.100.7"),
                     "same address: stay")
        XCTAssertNil(w.recheckFinished(entry: "server.example.com", current: "198.51.100.7", found: nil),
                     "not found: stay")
    }

    func testAnAnsweringServerOrOneByAddressIsLeftAlone() {
        var w = ServerNameWatch()
        w.noteAnswering(false, now: 10)
        w.noteAnswering(true, now: 20)
        XCTAssertFalse(w.recheckDue(entry: "server.example.com", connected: true, now: 100, networkChanged: false))
        w.noteAnswering(false, now: 100)
        XCTAssertFalse(w.recheckDue(entry: "192.0.2.10", connected: true, now: 200, networkChanged: true))
        XCTAssertFalse(w.recheckDue(entry: "server.example.com", connected: false, now: 200, networkChanged: true))
        XCTAssertTrue(w.recheckDue(entry: "server.example.com", connected: true, now: 101, networkChanged: true),
                      "a network change looks again at once")
    }
}
