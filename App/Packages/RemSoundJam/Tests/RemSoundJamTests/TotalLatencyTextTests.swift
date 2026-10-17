import XCTest
@testable import RemSoundJam

/// The Total latency box (Windows FormatMeasuredLatency).
final class TotalLatencyTextTests: XCTestCase {
    func testTheQuickestCompletePathIsShownOneWay() {
        let f = TotalLatencyText.figures(setMs: 20, journeys: [
            .init(bufferMs: 18, totalMs: 48), .init(bufferMs: 25, totalMs: 70), .init(bufferMs: 10, totalMs: nil),
        ])
        XCTAssertEqual(f, .init(bufferMs: 18, hardwareMs: 30, totalMs: 48))
        XCTAssertEqual(TotalLatencyText.text(setMs: 20, receiving: true, figures: f),
                       "Jitter buffer 18 ms. Sound card and hardware add 30 ms. Total latency approximately 48 ms one way.")
    }

    func testTheBufferIsTheSettingWhenTheSoundSitsDeeper() {
        XCTAssertEqual(TotalLatencyText.figures(setMs: 10, journeys: [.init(bufferMs: 16, totalMs: 46)]),
                       .init(bufferMs: 10, hardwareMs: 30, totalMs: 40))
    }

    func testNotReceivingAndNotKnownYetSaySo() {
        XCTAssertEqual(TotalLatencyText.text(setMs: 20, receiving: false, figures: nil), "Jitter buffer 20 ms, not receiving.")
        XCTAssertTrue(TotalLatencyText.text(setMs: 20, receiving: true, figures: nil).hasPrefix("Jitter buffer 20 ms. The sound card"))
        XCTAssertNil(TotalLatencyText.figures(setMs: 20, journeys: [.init(bufferMs: 10, totalMs: nil)]))
    }

    func testAFigureMovesOnlyOnceItHasMovedThreeMilliseconds() {
        let shown = TotalLatencyText.Figures(bufferMs: 18, hardwareMs: 30, totalMs: 48)
        XCTAssertEqual(TotalLatencyText.steady(shown: shown, new: .init(bufferMs: 18, hardwareMs: 32, totalMs: 50)), shown)
        let moved = TotalLatencyText.Figures(bufferMs: 18, hardwareMs: 34, totalMs: 52)
        XCTAssertEqual(TotalLatencyText.steady(shown: shown, new: moved), moved)
        XCTAssertNil(TotalLatencyText.steady(shown: shown, new: nil))
    }
}
