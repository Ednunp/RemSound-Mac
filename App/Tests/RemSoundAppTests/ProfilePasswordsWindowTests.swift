import AppKit
import XCTest
@testable import RemSoundApp

/// Profile passwords (Windows ProfilePasswordManagerDialog): one plain box per profile, only changes saved, failures named.
@MainActor
final class ProfilePasswordsWindowTests: XCTestCase {
    func testEachProfileHasANamedBoxAndOnlyChangesAreKept() {
        let a = UUID(), b = UUID()
        let (alert, rows) = ProfilePasswordsWindow.make([(id: a, title: "Studio", password: "one"), (id: b, title: "Gig", password: "")])
        XCTAssertEqual(alert.informativeText, ProfilePasswordsWindow.intro)
        XCTAssertEqual(rows.map { $0.field.accessibilityLabel() }, ["Password for profile Studio", "Password for profile Gig"])
        rows[1].field.stringValue = "  two  "
        let changes = ProfilePasswordsWindow.changes(rows)
        XCTAssertEqual(changes.map(\.row.id), [b])
        XCTAssertEqual(changes.first?.password, "two", "trimmed")
    }

    func testNoProfilesSaysHowToMakeOneAndFailuresAreNamed() {
        let (alert, rows) = ProfilePasswordsWindow.make([])
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(alert.informativeText, ProfilePasswordsWindow.noProfiles)
        XCTAssertNil(ProfilePasswordsWindow.report(failed: [], changed: 2))
        XCTAssertEqual(ProfilePasswordsWindow.report(failed: ["Gig"], changed: 2),
                       "These passwords were not saved: Gig. The others were saved.")
        XCTAssertEqual(ProfilePasswordsWindow.report(failed: ["Gig"], changed: 1),
                       "These passwords were not saved: Gig. Nothing was changed.")
    }
}
