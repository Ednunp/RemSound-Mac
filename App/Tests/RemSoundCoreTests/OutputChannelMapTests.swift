import XCTest
@testable import RemSoundCore

final class OutputChannelMapTests: XCTestCase {
    func testStereoCanPlayOnSelectedPairsOfSixChannelDevice() throws {
        XCTAssertEqual(try OutputChannelMap.make(channelCount: 6, pairs: [1]),
            [-1, -1, 0, 1, -1, -1])
        XCTAssertEqual(try OutputChannelMap.make(channelCount: 6, pairs: [0, 2]),
            [0, 1, -1, -1, 0, 1])
    }

    func testRejectsMissingAndOutOfRangePairs() {
        XCTAssertThrowsError(try OutputChannelMap.make(channelCount: 4, pairs: []))
        XCTAssertThrowsError(try OutputChannelMap.make(channelCount: 4, pairs: [2]))
        XCTAssertThrowsError(try OutputChannelMap.make(channelCount: 1, pairs: [0]))
    }
}
