import XCTest
import RemSoundJam
@testable import RemSoundSim

final class ReplayPhaseTests: XCTestCase {
    func testActuallySlowerSenderStillMeetsAlternatingRecordedDelayAfterInitialPhaseFit() throws {
        var recording = NetworkRecording()
        recording.streams = [.init(index: 0, from: "192.0.2.1:1", streamId: 7, lane: "Mixed", format: "synthetic", codec: 2, frameSamples: 120)]
        recording.packets = (0..<6000).map {
            .init(ms: Double($0) * 2.5 + ($0.isMultiple(of: 2) ? 0 : 4), stream: 0, sequence: UInt32($0), bytes: 60)
        }
        recording.packets.sort { $0.ms < $1.ms }
        let replay = try NetworkReplay.from(recording)
        let period = 0.0025, oneWay = 0.005, clockRatio = 1.001
        for index in 0..<6000 {
            let sent = 1 + Double(index) * period * clockRatio
            let arrivals = replay.arrivals(stream: 7, sequence: UInt32(index), sentAt: sent, oneWay: oneWay, ownPeriod: period)
            XCTAssertEqual(arrivals.count, 1)
            if index >= 4000 {
                XCTAssertEqual((arrivals[0] - sent - oneWay) * 1000, index.isMultiple(of: 2) ? 0 : 4, accuracy: 0.02)
            }
        }
    }
}
