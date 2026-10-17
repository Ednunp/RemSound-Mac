import XCTest
@testable import RemSoundJam

/// The web listener's browsers in words (Windows WebListener.DescribeBrowsers).
final class WebBrowsersTextTests: XCTestCase {
    func testABrowserReadsAsOnWindows() {
        let report = WebBrowsersText.report(streams: [.init(id: 3, depthMs: 120, targetMs: 100, longestWaitMs: 45, gaps: 2, skips: 1)],
                                            outMs: 30, rate: 48_000)
        XCTAssertEqual(report, "stream 3: buffer 120 ms (aiming for 100), longest wait 45 ms, gaps 2, catch-ups 1; its sound card adds about 30 ms at 48000 Hz")
        let line = WebBrowsersText.line(number: 1, description: WebBrowsersText.describe(pcm: false, report: report,
            roundTrips: [40, 90, 55], dropped: 0, reconnects: 1))
        XCTAssertEqual(line, "Browser 1: Opus, " + report + "; round trip 55 ms, worst 90 ms in the last minute; dropped here 0; reconnected 1 time.")
    }

    func testANewBrowserAndNobody() {
        XCTAssertEqual(WebBrowsersText.line(number: 2, description: WebBrowsersText.describe(pcm: true, report: nil,
            roundTrips: [], dropped: 0, reconnects: 0)), "Browser 2: just joined.")
        XCTAssertEqual(WebBrowsersText.report(streams: [], outMs: 0, rate: 0), "no sound playing")
        XCTAssertEqual(WebBrowsersText.status([]), "No browser is listening.")
    }

    func testMovingFiguresDoNotMakeANewLogLineButCountsDo() {
        let a = "Browser 1: Opus, stream 3: buffer 120 ms (aiming for 100), longest wait 45 ms, gaps 2, catch-ups 1; round trip 55 ms, worst 90 ms in the last minute; dropped here 0"
        let b = "Browser 1: Opus, stream 3: buffer 98 ms (aiming for 90), longest wait 30 ms, gaps 2, catch-ups 1; round trip 60 ms, worst 61 ms in the last minute; dropped here 0"
        let c = b.replacingOccurrences(of: "gaps 2", with: "gaps 3")
        XCTAssertEqual(WebBrowsersText.logKey(a), WebBrowsersText.logKey(b))
        XCTAssertNotEqual(WebBrowsersText.logKey(b), WebBrowsersText.logKey(c))
    }
}
