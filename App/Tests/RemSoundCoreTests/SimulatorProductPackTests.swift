import XCTest
@testable import RemSoundCore

final class SimulatorProductPackTests: XCTestCase {
    static let replay = "SIMULATOR REPLAY: a recorded network plays back packet for packet, and a hand-made minute's stall, loss, overtaking and doubling are each met where they were made"
    func testActualNamedReplayRowExecutesProductAssertionsWithoutPromotingMissingCodecBehavior() {
        let report=ProductTestPack.run(pack:.feature,only:Self.replay,budget:8)
        XCTAssertTrue(["completed", "deadline"].contains(report.termination))
        XCTAssertEqual(report.steps.count,1)
        XCTAssertGreaterThanOrEqual(report.steps.first?.assertions ?? 0,78)
        XCTAssertEqual(report.steps.first?.failures,["full-sweeps-and-driver-calibration-unverified"])
        XCTAssertEqual(report.steps.first?.status,"UNVERIFIED")
        XCTAssertEqual(report.exitCode,1)
    }
}
