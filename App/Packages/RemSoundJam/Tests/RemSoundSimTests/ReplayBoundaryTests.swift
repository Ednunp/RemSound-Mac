import Foundation
import XCTest
import RemSoundJam
@testable import RemSoundSim

final class ReplayBoundaryTests: XCTestCase {
    func recording() -> NetworkRecording {
        var r=NetworkRecording()
        r.streams=[.init(index:0,from:"10.0.0.1:1",streamId:7,lane:"Mixed",format:"fixture",codec:1,frameSamples:120)]
        r.packets=(0..<8).map { .init(ms:Double($0)*2.5,stream:0,sequence:UInt32($0),bytes:60) }
        return r
    }
    func testNonfiniteArrivalRefusesBeforeReplayArithmetic() {
        var r=recording();r.packets[3].ms = .nan
        XCTAssertThrowsError(try NetworkReplay.from(r)) { XCTAssertEqual($0 as? NetworkReplay.ReplayError,.invalidClock) }
    }
    func testExcessiveSequenceSpanRefusesBeforePlaceAllocation() {
        var r=recording();r.packets[7].sequence=1<<18
        XCTAssertThrowsError(try NetworkReplay.from(r)) { XCTAssertEqual($0 as? NetworkReplay.ReplayError,.invalidSpan) }
    }
    func testValidSmallRecordingRetainsExactPeriodAndNoLoss() throws {
        let replay=try NetworkReplay.from(recording())
        XCTAssertEqual(replay.places,8);XCTAssertEqual(replay.lost,0);XCTAssertEqual(replay.period,0.0025,accuracy:0.000001)
    }
}
