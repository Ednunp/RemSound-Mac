import XCTest
@testable import RemSoundJam

/// The updater's choices (Windows UpdateCheckFrequency, UpdateWindow and TruncateForDialog).
final class UpdateScheduleTests: XCTestCase {
    func testTheChecksAreWindowsFourAndDailyByDefault() {
        XCTAssertEqual(UpdateCheckFrequency.allCases.map(\.title), ["Never", "Every hour", "Every 6 hours", "Every 24 hours"])
        XCTAssertEqual(UpdateCheckFrequency.allCases.map(\.rawValue), [0, 1, 2, 3], "the numbers Windows stores")
        XCTAssertEqual(UpdateCheckFrequency.default, .every24Hours)
        XCTAssertNil(UpdateCheckFrequency.never.interval)
        XCTAssertEqual(UpdateCheckFrequency.every6Hours.interval, 21_600)
    }

    func testTheRangeKeepsToItsHoursAndWrapsPastMidnight() {
        XCTAssertTrue(UpdateWindow.isWithin(minutesOfDay: 60, start: 60, end: 360), "start inclusive")
        XCTAssertFalse(UpdateWindow.isWithin(minutesOfDay: 360, start: 60, end: 360), "end exclusive")
        XCTAssertFalse(UpdateWindow.isWithin(minutesOfDay: 720, start: 60, end: 360))
        XCTAssertTrue(UpdateWindow.isWithin(minutesOfDay: 23 * 60, start: 22 * 60, end: 360), "22:00 to 06:00")
        XCTAssertTrue(UpdateWindow.isWithin(minutesOfDay: 30, start: 22 * 60, end: 360))
        XCTAssertFalse(UpdateWindow.isWithin(minutesOfDay: 12 * 60, start: 22 * 60, end: 360))
        XCTAssertTrue(UpdateWindow.isWithin(minutesOfDay: 12 * 60, start: 120, end: 120), "the same start and end: no restriction")
        XCTAssertEqual(UpdateWindow.slotsPerDay, 96)
        XCTAssertEqual(UpdateWindow.format(75), "01:15")
        XCTAssertEqual(UpdateWindow.format(1_425), "23:45")
    }

    func testAnUpdateFoundOutsideTheRangeIsTriedWhenItNextOpens() {
        XCTAssertEqual(UpdateWindow.untilNextStart(secondsOfDay: 23 * 3_600, start: 60), 2 * 3_600)
        XCTAssertEqual(UpdateWindow.untilNextStart(secondsOfDay: 30 * 60, start: 60), 30 * 60)
        XCTAssertEqual(UpdateWindow.untilNextStart(secondsOfDay: 3_600, start: 60), 24 * 3_600, "just opened: the next day's")
    }

    func testTheQuestionCarriesTheNotesCutShort() {
        XCTAssertEqual(ReleaseNotesText.question(version: "1.2.0", notes: "  "), "RemSound Mac 1.2.0 is available. Install now?")
        XCTAssertEqual(ReleaseNotesText.question(version: "1.2.0", notes: "Fixed some bugs."),
                       "RemSound Mac 1.2.0 is available.\n\nFixed some bugs.\n\nInstall now?")
        let long = String(repeating: "a", count: 700)
        XCTAssertEqual(ReleaseNotesText.forDialog(long), String(repeating: "a", count: 600) + "\n…")
    }
}
