import XCTest
@testable import RemSoundJam

/// One machine on your network and on the server at once: each row says so (Windows' duplicate-route note).
final class SameMachineTwiceTests: XCTestCase {
    func testEachRouteNamesTheOtherAndOthersAreLeftAlone() {
        let notes = SameMachineTwice.notes([
            (address: "192.168.1.20", name: "ED_DT", onServer: false),
            (address: "240.1.2.3", name: "ed_dt (on the server)", onServer: true),
            (address: "240.1.2.4", name: "Andre (on the server)", onServer: true),
            (address: "192.168.1.30", name: "Studio", onServer: false),
        ])
        XCTAssertEqual(notes, ["192.168.1.20": "same machine twice, also connected through the server",
                               "240.1.2.3": "same machine twice, also connected on your network"])
    }

    func testTwoNetworkRowsWithOneNameAreNotTwins() {
        XCTAssertTrue(SameMachineTwice.notes([(address: "10.0.0.1", name: "iPhone", onServer: false),
                                              (address: "10.0.0.2", name: "iPhone", onServer: false)]).isEmpty)
    }
}
