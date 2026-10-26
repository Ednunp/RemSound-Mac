import Foundation
import XCTest
@testable import RemSoundJam

/// The logs folder's warning and deleting (Windows Preferences, Logs).
final class LogFolderCareTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func file(_ name: String, daysOld: Double, megabytes: Double = 1) -> LogFolderCare.File {
        .init(name: name, modified: now.addingTimeInterval(-daysOld * 86_400), bytes: Int64(megabytes * 1_048_576))
    }

    func testTheWarningComesOnlyPastTheLimitAndSaysWhereToAct() {
        let files = [file("a.log", daysOld: 1, megabytes: 60), file("b.log", daysOld: 2, megabytes: 50)]
        XCTAssertNil(LogFolderCare.warning(files, megabytes: 250))
        XCTAssertEqual(LogFolderCare.warning(files, megabytes: 100),
                       "The logs folder is 110 megabytes, more than the 100 you set. You can delete old logs in Preferences, General.")
    }

    func testOldLogsGoButTheOnesInUseStay() {
        let files = [file("Latest.log", daysOld: 40), file("Session 1.log", daysOld: 20), file("Session 2.log", daysOld: 3),
                     file("Startup.log", daysOld: 90)]
        XCTAssertEqual(LogFolderCare.older(files, thanDays: 14, now: now).map(\.name), ["Session 1.log"])
        XCTAssertEqual(LogFolderCare.older(files, thanDays: 0, now: now).map(\.name), ["Session 1.log", "Session 2.log"],
                       "at least a day")
    }

    func testDeleteAllLeavesWhatIsBeingWrittenNow() {
        let files = [file("Latest.log", daysOld: 0), file("Session 1.log", daysOld: 2),
                     file("Session 2.log", daysOld: 0.001), file("Update.log", daysOld: 5)]
        XCTAssertEqual(LogFolderCare.all(files, now: now).map(\.name), ["Session 1.log"])
    }

    func testTheRunningLogAndItsReadingsAreKeptHoweverQuiet() {
        // A quiet log can go more than ten minutes without a line; its readings file and their parts go with it.
        let live = "RemSound-Mac-2026-10-26-0900-Andre"
        let files = [file("\(live).log", daysOld: 1), file("\(live)-readings.csv", daysOld: 1),
                     file("\(live)-part2.log", daysOld: 1), file("RemSound-Mac-2026-10-20-0900-Andre.log", daysOld: 6),
                     file("RemSound-Mac-2026-10-20-0900-Andre-readings.csv", daysOld: 6)]
        XCTAssertEqual(LogFolderCare.all(files, now: now, sparing: live).map(\.name),
                       ["RemSound-Mac-2026-10-20-0900-Andre.log", "RemSound-Mac-2026-10-20-0900-Andre-readings.csv"])
        XCTAssertEqual(LogFolderCare.older(files, thanDays: 5, now: now, sparing: live).count, 2)
        XCTAssertEqual(LogFolderCare.all(files, now: now).count, 5, "with nothing running, every one may go")
    }
}
